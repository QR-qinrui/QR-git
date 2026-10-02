#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
font_decoder.py — 通用小说自定义字体混淆解密器

原理：
    部分小说站点/软件把正文常见字符映射到 Unicode 私有区(PUA, U+E000~U+F8FF)，
    并用一个裁剪过的自定义字体(wOFF2/OTF/TTF)渲染这些码位——字形本身仍是
    开源字体(如思源黑体)的原样轮廓，只是 cmap 被改写。
    因此：取混淆字体的 cmap 得到全部 PUA 码位 → 用参考字体逐字渲染做像素匹配
    → 还原 PUA → 真实字符映射表。

用法：
    python font_decoder.py <混淆字体> [--ref 参考字体A 参考字体B ...] \
        [--size 96] [--out char_map.json] [--scores scores.json] \
        [--weak weak.json] [--min-d 100]

输出：
    char_map.json : {"0xe521": "我", ...}  直接喂给 decode_text.py
    scores.json   : 每个 PUA 码位在每套参考字体下的候选分数(调试用)
    weak.json     : 低置信字符及其候选(供人工上下文修复)

依赖：pip install fonttools brotli Pillow
"""
import argparse
import json
import sys
from collections import defaultdict

from fontTools.ttLib import TTFont
from PIL import Image, ImageDraw, ImageFont

SIZE = 96          # 渲染字号
CANVAS = 128       # 画布
OFFSET = 16        # 绘制起点
BUCKET = 24        # 墨水桶宽
SAME_SHAPE = 30    # 同形判定阈值

# 不参与候选的码位：兼容表意字、康熙部首、CJK部首补充、PUA
def _excluded_cp(cp: int) -> bool:
    return ((0xF900 <= cp <= 0xFAFF) or (0x2F800 <= cp <= 0x2FA1F)
            or (0x2F00 <= cp <= 0x2FDF) or (0x2E80 <= cp <= 0x2EFF)
            or (0xE000 <= cp <= 0xF8FF))

def _is_unified(cp: int) -> bool:
    return 0x4E00 <= cp <= 0x9FFF

_ASCII = set(range(0x21, 0x7F))


def load_font(path: str) -> TTFont:
    return TTFont(path)


def pua_codepoints(font: TTFont):
    """从 cmap 提取全部 PUA 码位，升序返回。"""
    best = font.getBestCmap()
    return sorted(cp for cp in best if 0xE000 <= cp <= 0xF8FF)


def _render(font: ImageFont.FreeTypeFont, ch: str, size: int = SIZE):
    canvas = size + 32
    img = Image.new("L", (canvas, canvas), 0)
    d = ImageDraw.Draw(img)
    d.text((16, 16), ch, font=font, fill=255)
    bmp = bytes(1 if v > 127 else 0 for v in img.getdata())
    # 位图转大整数：hamming 距离用异或+bit_count，C 实现快两个数量级
    packed = int.from_bytes(bmp, "big")
    return (packed, packed.bit_count())


def _hamming(a: int, b: int) -> int:
    return (a ^ b).bit_count()


def build_index(ref_path: str, size: int):
    """为参考字体建立 墨水桶 -> [(codepoint,char,bitmap,ink)] 索引。"""
    ttf = TTFont(ref_path)
    best = ttf.getBestCmap()
    pil_font = ImageFont.truetype(ref_path, size)
    buckets = defaultdict(list)
    chars = []
    for cp in best:
        if _excluded_cp(cp) or 0xD800 <= cp <= 0xDFFF:
            continue
        chars.append((cp, chr(cp)))
    for cp, ch in chars:
        bmp, ink = _render(pil_font, ch, size)
        if ink:
            buckets[ink // BUCKET].append((cp, ch, bmp, ink))
    return buckets, len(chars)


def score_pua(font_path: str, size: int, pua_chars: list, buckets: dict):
    """对每个 PUA 码位返回 [ (hamming, hex(cp), char), ... ] top6。"""
    font = ImageFont.truetype(font_path, size)
    scores = {}
    for idx, cp in enumerate(pua_chars):
        ch = chr(cp)
        bmp, ink = _render(font, ch, size)
        cands = []
        for b in range(ink // BUCKET - 3, ink // BUCKET + 4):
            for (ccp, cch, cbmp, cink) in buckets.get(b, []):
                cands.append((_hamming(bmp, cbmp), ccp, cch))
        cands.sort()
        scores[hex(cp)] = {"ink": ink, "top": [[d, hex(c), ch] for d, c, ch in cands[:6]]}
    return scores


def decide(src: dict, ink: int):
    """单套参考字体的判定：返回 (d0, char, kind)。"""
    top = [t for t in src["top"] if not _excluded_cp(int(t[1], 16))]
    if not top:
        return None
    d0, c0, ch0 = top[0]
    same = [t for t in top if t[0] - d0 <= SAME_SHAPE]
    ascii_c = [t for t in same if int(t[1], 16) in _ASCII]
    if ascii_c:
        return (d0, ascii_c[0][2], "ascii")
    uni = [t for t in same if _is_unified(int(t[1], 16))]
    chosen = uni[0][2] if uni else ch0
    rest = [t for t in top if t[0] - d0 > SAME_SHAPE]
    d1 = rest[0][0] if rest else 1e9
    gap = d1 - d0
    if d0 <= max(120, int(0.18 * ink)) and gap >= max(250, int(1.5 * d0)):
        return (d0, chosen, "strong")
    if d0 <= max(60, int(0.08 * ink)) and gap >= 100:
        return (d0, chosen, "strong2")
    return (d0, chosen, "weak")


def main():
    ap = argparse.ArgumentParser(description="通用小说字体混淆解密器")
    ap.add_argument("font", help="混淆字体文件 (woff2/woff/otf/ttf)")
    ap.add_argument("--ref", nargs="+", default=None,
                    help="参考字体路径（默认 scripts/ref_fonts 下的思源黑体SC + NotoSansCJKsc）")
    ap.add_argument("--size", type=int, default=SIZE)
    ap.add_argument("--out", default="char_map.json")
    ap.add_argument("--scores", default=None)
    ap.add_argument("--weak", default="weak.json")
    args = ap.parse_args()

    if args.ref is None:
        import os
        base = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ref_fonts")
        args.ref = [os.path.join(base, "SourceHanSansSC-Normal.otf"),
                    os.path.join(base, "NotoSansCJKsc-Regular.otf")]
        missing = [r for r in args.ref if not os.path.exists(r)]
        if missing:
            sys.exit("缺少参考字体：%s\n请先运行 scripts/ref_fonts.py 下载" % missing)

    ttf = load_font(args.font)
    pua = pua_codepoints(ttf)
    print("PUA 码位数:", len(pua), flush=True)
    if not pua:
        print("该字体没有 PUA 映射，正文可能未被字体混淆。")
        return

    all_scores = {}
    decisions = []
    for ref in args.ref:
        print("索引参考字体:", ref, flush=True)
        buckets, n = build_index(ref, args.size)
        print("  候选字符:", n, flush=True)
        sc = score_pua(args.font, args.size, pua, buckets)
        all_scores[ref] = sc
        for key in sc:
            r = decide(sc[key], sc[key]["ink"])
            if r is not None:
                decisions.append((key, r))

    decode = {}
    weak = {}
    for key in all_scores[args.ref[0]]:
        rs = [d for d in decisions if d[0] == key]
        strongs = [d[1] for d in rs if d[1][2] in ("ascii", "strong", "strong2")]
        if strongs:
            strongs.sort(key=lambda r: r[0])
            decode[key] = strongs[0][1]
        else:
            tops = [all_scores[r][key]["top"] for r in args.ref]
            weak[key] = tops

    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(decode, f, ensure_ascii=False, indent=1)
    with open(args.weak, "w", encoding="utf-8") as f:
        json.dump(weak, f, ensure_ascii=False, indent=1)
    if args.scores:
        with open(args.scores, "w", encoding="utf-8") as f:
            json.dump(all_scores, f, ensure_ascii=False)
    print("解码字符数:", len(decode), "低置信:", len(weak))
    print("映射表:", args.out, "| 低置信:", args.weak)
    if weak:
        print("提示: 低置信字符请用 decode_text.py 输出上下文后人工定字，再补入映射表。")


if __name__ == "__main__":
    main()
