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
IMPL_SRC = SCANNER_SRC / "scanner_impl"  # v1.2.1: 内置参考实现


def init(target: Path) -> None:
    target.mkdir(parents=True, exist_ok=True)
    (target / "scanner").mkdir(exist_ok=True)
    (target / "team").mkdir(exist_ok=True)
    (target / "knowledge").mkdir(exist_ok=True)  # v1.2.0 知识库模块
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

    # 复制参考实现（v1.2.1：含REST兜底与缺失数据语义，已不存在的文件才复制）
    if IMPL_SRC.exists():
        for fname in ["github_client.py", "evaluator.py", "installer.py",
                      "report.py", "seed_data.py"]:
            src, dst = IMPL_SRC / fname, target / "scanner" / fname
            if src.exists() and not dst.exists():
                shutil.copy(src, dst)
                print(f"  [+] scanner/{fname}（参考实现）")
        for fname in ["run_scan.py", "requirements.txt"]:
            src, dst = IMPL_SRC / fname, target / fname
            if src.exists() and not dst.exists():
                shutil.copy(src, dst)
                print(f"  [+] {fname}（参考实现）")

    # 创建 __init__.py
    for pkg in ["scanner", "team", "knowledge"]:
        init_file = target / pkg / "__init__.py"
        if not init_file.exists():
            init_file.write_text(
                f'"""{pkg} package"""\n__version__ = "1.2.1"\n', encoding="utf-8")

    print(f"\n[OK] scanner项目已初始化: {target}")
    print("\n下一步：")
    print(f"  1. 编辑 {cfg_dst} 调整扫描领域与评分权重")
    print(f"  2. 参考实现已内置（scanner/*.py + run_scan.py），可直接运行；如需定制请修改")
    print(f"  3. 实现knowledge/{{__init__,templates,storage,ingestor,indexer}}.py（知识库模块）")
    print(f"  4. 运行: python scripts/ingest_project.py --path . --goal '初始化'")
    print(f"  5. 运行: python scripts/build_kb_index.py  # 重建索引")


def main():
    if len(sys.argv) > 1:
        target = Path(sys.argv[1]).resolve()
    else:
        target = Path.cwd() / "ai-github-scanner"
    print(f"初始化 AI GitHub Scanner 项目到: {target}")
    init(target)


if __name__ == "__main__":
    main()