#!/usr/bin/env python
"""
scripts/ingest_project.py - 项目归纳入库 CLI

用法（推荐路径）：
  python scripts/ingest_project.py --path /path/to/project --goal "目标" --notes "用户补充"

不指定 --path 时（仅元信息入库）：
  python scripts/ingest_project.py --title "项目名" --goal "目标" --tags python,github
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

# 让脚本独立可执行：把 skill 根目录加入 sys.path
SKILL_ROOT = Path(__file__).resolve().parent.parent
if str(SKILL_ROOT) not in sys.path:
    sys.path.insert(0, str(SKILL_ROOT))

from knowledge.ingestor import ProjectIngestor  # noqa: E402


def main() -> int:
    p = argparse.ArgumentParser(description="项目归纳入库")
    p.add_argument("--path", help="项目目录路径")
    p.add_argument("--title", help="标题（无 --path 时必填）")
    p.add_argument("--goal", default="", help="项目目标")
    p.add_argument("--notes", default="", help="用户补充的关键决策/特殊说明")
    p.add_argument("--status", default="completed", help="状态 completed/abandoned/paused")
    p.add_argument("--tags", default="", help="标签，逗号分隔")
    p.add_argument("--kb-root", default="", help="知识库根目录（默认 ~/.workbuddy/knowledge）")
    p.add_argument("--json", action="store_true", help="以 JSON 输出结果")
    args = p.parse_args()

    tags = [t.strip() for t in args.tags.split(",") if t.strip()]

    ingestor = ProjectIngestor(
        kb_root=args.kb_root or None,
        skill_root=SKILL_ROOT,
    )

    if args.path:
        result = ingestor.ingest_path(
            args.path,
            goal=args.goal,
            notes=args.notes,
            status=args.status,
            tags=tags,
        )
    elif args.title:
        result = ingestor.ingest_summary(
            title=args.title,
            goal=args.goal,
            body={
                "scope": "（用户直接元信息入库，无目录扫描）",
                "deliverables": "",
                "key_decisions": args.notes,
                "technical_approach": "",
                "key_artifacts": "",
                "problems_and_solutions": "（无）",
                "reusable_patterns": "（待提炼）",
                "lessons": "（待提炼）",
                "next_steps": "",
            },
            tags=tags,
            status=args.status,
        )
    else:
        print("错误：必须提供 --path 或 --title", file=sys.stderr)
        return 2

    if args.json:
        print(json.dumps({
            "success": result.success,
            "entry_path": result.entry_path,
            "project_id": result.project_id,
            "entry_type": result.entry_type,
            "detected_type": result.detected_type,
            "detected_tags": result.detected_tags,
            "message": result.message,
        }, ensure_ascii=False, indent=2))
    else:
        if result.success:
            print(f"[OK] {result.message}")
            print(f"      路径: {result.entry_path}")
            if result.detected_type:
                print(f"      类型: {result.detected_type}")
            if result.detected_tags:
                print(f"      标签: {', '.join(result.detected_tags)}")
        else:
            print(f"[FAIL] {result.message}", file=sys.stderr)
            return 1
    return 0 if result.success else 1


if __name__ == "__main__":
    sys.exit(main())