#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
text_repair.py — 常见文本编码/乱码修复探测

对拿到手但"读不通"的文本自动尝试常见修复，按可读性打分输出最优结果。
支持：base64、UTF-16/GBK 字节序还原、字符串倒序、简单 XOR、全角还原等。

用法：
    python text_repair.py probe <文件>
    python text_repair.py probe -        # 从 stdin 读
    python text_repair.py fix <文件> --method base64 --out 输出.txt
"""
import argparse
import base64
import re
import sys

CJK = re.compile(r"[\u4e00-\u9fff]")


def readability(s: str) -> float:
    """可读性打分：汉字占比高且无异常字符则高分。"""
    if not s:
        return 0.0
    cjk = len(CJK.findall(s))
    weird = len(re.findall(r"[\ufffd\x00-\x08\x0b\x0c\x0e-\x1f]", s))
    return (cjk / max(len(s), 1)) * 100 - weird * 10


def repairs(raw: bytes):
    yield "原文(UTF-8)", raw.decode("utf-8", errors="replace")
    yield "原文(GBK)", raw.decode("gbk", errors="replace")
    yield "原文(UTF-16LE)", raw.decode("utf-16-le", errors="replace")
    try:
        yield "base64", base64.b64decode(raw, validate=True).decode("utf-8", errors="replace")
    except Exception:  # noqa: BLE001
        pass
    s = raw.decode("utf-8", errors="replace")
    yield "倒序", s[::-1]
    for k in (1, 3, 5, 7, 0x10, 0x20, 0x40):
        yield "XOR%02x" % k, "".join(chr(ord(c) ^ k) for c in s)
    yield "全角还原", full_to_half(s)


def full_to_half(s: str) -> str:
    out = []
    for ch in s:
        cp = ord(ch)
        if cp == 0x3000:
            out.append(" ")
        elif 0xFF01 <= cp <= 0xFF5E:
            out.append(chr(cp - 0xFEE0))
        else:
            out.append(ch)
    return "".join(out)


def probe(data: bytes, top: int = 5):
    scored = sorted(((readability(v), k, v) for k, v in repairs(data)), reverse=True)
    for score, name, text in scored[:top]:
        print("== %-12s 可读性 %.1f ==" % (name, score))
        print(text[:160].replace("\n", "\\n"))
    return scored[0]


def main():
    ap = argparse.ArgumentParser(description="文本编码修复探测")
    ap.add_argument("cmd", choices=["probe", "fix"])
    ap.add_argument("file", help="文件路径，- 表示 stdin")
    ap.add_argument("--method", default=None, help="fix 时指定修复方法（probe 输出的方法名）")
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    if args.file == "-":
        data = sys.stdin.buffer.read()
    else:
        with open(args.file, "rb") as f:
            data = f.read()

    if args.cmd == "probe":
        best = probe(data)
        print("推荐:", best[1])
        return

    for name, text in repairs(data):
        if name == args.method:
            if args.out:
                with open(args.out, "w", encoding="utf-8") as f:
                    f.write(text)
                print("已写出:", args.out)
            else:
                print(text)
            return
    sys.exit("未找到方法: %s（先运行 probe 查看可用方法）" % args.method)


if __name__ == "__main__":
    main()
