#!/usr/bin/env python
"""
scripts/init_scanner.py - 在指定目录初始化一个新scanner项目

用法：
  python init_scanner.py [target_dir]

不指定 target_dir 则在当前目录下创建 ai-github-scanner/
"""
from __future__ import annotations

import shutil
import sys
from pathlib import Path

# skill根目录（本脚本所在目录的父目录）
SKILL_ROOT = Path(__file__).resolve().parent.parent
SCANNER_SRC = SKILL_ROOT / "assets"  # 模板源
TEMPLATE_CONFIG = SCANNER_SRC / "config_template.yaml"


def init(target: Path) -> None:
    target.mkdir(parents=True, exist_ok=True)
    (target / "scanner").mkdir(exist_ok=True)
    (target / "team").mkdir(exist_ok=True)
    (target / "data" / "scanned").mkdir(parents=True, exist_ok=True)
    (target / "data" / "evaluated").mkdir(parents=True, exist_ok=True)
    (target / "data" / "reports").mkdir(parents=True, exist_ok=True)
    (target / "data" / "installed").mkdir(parents=True, exist_ok=True)
    (target / "docs").mkdir(exist_ok=True)

    # 复制配置模板
    cfg_dst = target / "config.yaml"
    if not cfg_dst.exists():
        shutil.copy(TEMPLATE_CONFIG, cfg_dst)
        print(f"  [+] 创建 config.yaml（来自模板）")
    else:
        print(f"  [=] config.yaml 已存在，跳过")

    # 创建 __init__.py
    for pkg in ["scanner", "team"]:
        init_file = target / pkg / "__init__.py"
        if not init_file.exists():
            init_file.write_text(
                f'"""{pkg} package"""\n__version__ = "1.0.0"\n', encoding="utf-8")

    print(f"\n[OK] scanner项目已初始化: {target}")
    print("\n下一步：")
    print(f"  1. 编辑 {cfg_dst} 调整扫描领域与评分权重")
    print("  2. 实现scanner/{github_client,evaluator,installer,report,seed_data}.py")
    print("  3. 运行: python run_scan.py")


def main():
    if len(sys.argv) > 1:
        target = Path(sys.argv[1]).resolve()
    else:
        target = Path.cwd() / "ai-github-scanner"
    print(f"初始化 AI GitHub Scanner 项目到: {target}")
    init(target)


if __name__ == "__main__":
    main()