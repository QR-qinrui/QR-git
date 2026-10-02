#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
fanqie_crawler.py — 番茄小说适配器模板（站点示例，供 agent 浏览器端参考）

说明：
    番茄的正文/目录接口必须带浏览器 cookie 且在 fanqienovel.com 页面上下文内
    调用才稳定。本脚本给出三个关键端点和完整管线示例；实际批量抓取时建议由
    agent 在 ego 浏览器页面内用 fetch 并发抓取（自动携带 cookie），再交回
    node/python 落盘。本文件也可作为其他小说站的 adapter 模板。

端点（bookId 见书籍页 URL /page/<bookId>）：
    目录   GET https://fanqienovel.com/api/reader/directory/detail?bookId=<bookId>
          返回 data.allItemIds（章节 itemId 列表，顺序即章节顺序）
    正文   GET https://fanqienovel.com/api/reader/full?itemId=<itemId>
          返回 data.chapterData.{title,content}，content 为 <p> 包裹的 HTML
    混淆字体 阅读页 <style> @font-face src 中的 woff2（全书通用，只解一次）

管线（与 SKILL.md 对应）：
    1. 页面内 fetch 目录 → 取前 N 个 itemId
    2. 并发 5 fetch 正文（失败重试 3 次、间隔 400ms）
    3. content 保存为原始 txt（保留 PUA 字符）
    4. python scripts/font_decoder.py <font.woff2> --out char_map.json
    5. python scripts/decode_text.py 原文.txt char_map.json --strip-html --out 成品.txt
    6. 弱置信字符：decode_text.py --contexts 打印上下文 → 人工定字补入映射 → 重跑

若直接在本机 Python 下抓取（需先手工导出 cookie）：
    python fanqie_crawler.py --book-id <bookId> --chapters 100 --cookie "<novel_web_id=...>"
"""
import argparse
import json
import re
import time
import urllib.request


def fetch(url: str, cookie: str) -> dict:
    req = urllib.request.Request(url, headers={
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
        "Referer": "https://fanqienovel.com/",
        "Cookie": cookie,
    })
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode("utf-8"))


def main():
    ap = argparse.ArgumentParser(description="番茄小说抓取模板")
    ap.add_argument("--book-id", required=True)
    ap.add_argument("--chapters", type=int, default=100)
    ap.add_argument("--cookie", default="", help="从浏览器开发者工具复制的 Cookie")
    ap.add_argument("--out", default="raw.txt")
    args = ap.parse_args()

    if not args.cookie:
        print("提示: 未提供 --cookie，本机直连大概率失败。建议在 ego 浏览器页面内用 fetch 抓取。")
        print("（接口与管线见本文件 docstring）")

    d = fetch("https://fanqienovel.com/api/reader/directory/detail?bookId=%s" % args.book_id,
              args.cookie)
    ids = d["data"]["allItemIds"][: args.chapters]
    print("章节数:", len(ids))

    parts = []
    fails = []
    for i, item_id in enumerate(ids):
        ok = False
        for _ in range(3):
            try:
                j = fetch("https://fanqienovel.com/api/reader/full?itemId=%s" % item_id,
                          args.cookie)
                cd = j["data"]["chapterData"]
                parts.append(cd["title"] + "\n\n" + cd["content"] + "\n\n")
                ok = True
                break
            except Exception:  # noqa: BLE001
                time.sleep(0.4)
        if not ok:
            fails.append(item_id)
        if i % 10 == 0:
            print("进度:", i + 1, "/", len(ids))
        time.sleep(0.3)

    with open(args.out, "w", encoding="utf-8") as f:
        f.write("\n".join(parts))
    print("完成:", args.out, "失败:", fails)


if __name__ == "__main__":
    main()
