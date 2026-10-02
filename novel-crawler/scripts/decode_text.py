#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
decode_text.py — 应用字符映射表解码正文 + 清洗 + 质检

用法：
    python decode_text.py <输入.txt|.html> <char_map.json> [--out 输出.txt] \
        [--strip-html] [--header "《书名》\n作者：XX\n"] [--contexts]

功能：
    - 把正文中 U+E000~U+F8FF 的 PUA 字符按映射表替换为真实字符
    - 未在映射表中的字符输出为 <xxxx> 占位符并统计
    - --strip-html 时去掉 <p> 等标签并按段落换行
    - --contexts 时打印每个未解码字符的前后 15 字上下文（供人工定字）
"""
import argparse
import json
import re
import sys
from collections import Counter


def decode(text: str, num_map: dict) -> tuple:
    out = []
    unknown = Counter()
    for ch in text:
        cp = ord(ch)
        if 0xE000 <= cp <= 0xF8FF:
            if cp in num_map:
                out.append(num_map[cp])
            else:
                out.append("<%x>" % cp)
                unknown[cp] += 1
        else:
            out.append(ch)
    return "".join(out), unknown


def contexts(text: str, unknown: Counter):
    for cp in sorted(unknown):
        tag = "<%x>" % cp
        start = 0
        shown = 0
        while shown < 3:
            i = text.find(tag, start)
            if i < 0:
                break
            s = max(0, i - 15)
            e = min(len(text), i + 16)
            print("U+%04X: %s" % (cp, text[s:e].replace("\n", "\\n")))
            start = i + 1
            shown += 1


def main():
    ap = argparse.ArgumentParser(description="应用映射表解码小说正文")
    ap.add_argument("input")
    ap.add_argument("map", help="font_decoder.py 输出的 char_map.json")
    ap.add_argument("--out", default=None)
    ap.add_argument("--strip-html", action="store_true")
    ap.add_argument("--header", default="")
    ap.add_argument("--contexts", action="store_true")
    args = ap.parse_args()

    with open(args.map, encoding="utf-8") as f:
        m = json.load(f)
    num_map = {int(k, 16): v for k, v in m.items()}

    with open(args.input, encoding="utf-8", errors="replace") as f:
        text = f.read()

    if args.strip_html:
        text = re.sub(r"</p>", "\n", text)
        text = re.sub(r"<p>", "", text)
        text = re.sub(r"<br\s*/?>", "\n", text)
        text = re.sub(r"<[^>]+>", "", text)

    decoded, unknown = decode(text, num_map)
    decoded = args.header + decoded
    decoded = re.sub(r"\n{3,}", "\n\n", decoded)

    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(decoded)
        print("已写出:", args.out)
    else:
        print(decoded)

    cjk = len(re.findall(r"[\u4e00-\u9fff]", decoded))
    print("总字符:", len(decoded), "| 汉字:", cjk,
          "| 未解码字符数:", sum(unknown.values()), "| 未解码种类:", len(unknown))
    if unknown:
        print("未解码码位:", " ".join("U+%04Xx%d" % (cp, n) for cp, n in unknown.most_common(20)))
        if args.contexts:
            contexts(decoded, unknown)
        sys.exit(2)  # 质检门禁：有占位符即失败


if __name__ == "__main__":
    main()
