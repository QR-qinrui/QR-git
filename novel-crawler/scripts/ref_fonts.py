#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ref_fonts.py — 下载字体解密所需的开源参考字体

来源（均为 SIL OFL 开源许可）：
  - SourceHanSansSC-Normal.otf  Adobe 思源黑体 简体 常规
  - NotoSansCJKsc-Regular.otf   Google Noto Sans CJK SC 常规
下载后保存在本脚本同级的 ref_fonts/ 目录，已存在则跳过。
"""
import os
import sys
import urllib.request

URLS = {
    "SourceHanSansSC-Normal.otf": [
        "https://cdn.jsdelivr.net/gh/adobe-fonts/source-han-sans@release/OTF/SimplifiedChinese/SourceHanSansSC-Normal.otf",
        "https://github.com/adobe-fonts/source-han-sans/raw/release/OTF/SimplifiedChinese/SourceHanSansSC-Normal.otf",
    ],
    "NotoSansCJKsc-Regular.otf": [
        "https://cdn.jsdelivr.net/gh/notofonts/noto-cjk@main/Sans/OTF/SimplifiedChinese/NotoSansCJKsc-Regular.otf",
        "https://github.com/notofonts/noto-cjk/raw/main/Sans/OTF/SimplifiedChinese/NotoSansCJKsc-Regular.otf",
    ],
}

UA = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) novel-crawler/1.0"}


def download(name: str, urls, dest_dir: str) -> str:
    dest = os.path.join(dest_dir, name)
    if os.path.exists(dest) and os.path.getsize(dest) > 1_000_000:
        print("已存在:", dest)
        return dest
    for url in urls:
        try:
            print("下载:", url)
            req = urllib.request.Request(url, headers=UA)
            with urllib.request.urlopen(req, timeout=120) as resp:
                data = resp.read()
            if len(data) < 1_000_000:
                print("  文件异常(%d字节)，尝试下一源" % len(data))
                continue
            with open(dest, "wb") as f:
                f.write(data)
            print("完成:", dest, len(data), "字节")
            return dest
        except Exception as e:  # noqa: BLE001
            print("  失败:", e)
    sys.exit("下载失败: %s（请手动下载后放入 %s）" % (name, dest_dir))


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    dest_dir = os.path.join(here, "ref_fonts")
    os.makedirs(dest_dir, exist_ok=True)
    for name, urls in URLS.items():
        download(name, urls, dest_dir)
    print("参考字体就绪:", dest_dir)


if __name__ == "__main__":
    main()
