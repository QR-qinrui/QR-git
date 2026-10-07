#!/usr/bin/env python
"""
scripts/ingest_lesson.py - 教训入库 CLI

用法（短文本直接传参）：
  python scripts/ingest_lesson.py --title "..." --severity high \
      --symptom "..." --root-cause "..." --fix "..." [--prevention "..."]

长文本推荐用 --json-file（避免shell转义问题）：
  python scripts/ingest_lesson.py --json-file lesson.json
  lesson.json 字段：title/severity/symptom/root_cause/fix/prevention/tags/source_projects
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

from knowledge.storage import KnowledgeStorage  # noqa: E402
from knowledge.ingestor import ingest_lesson  # noqa: E402
from knowledge.indexer import KnowledgeIndexer  # noqa: E402


def main() -> int:
    p = argparse.ArgumentParser(description="教训入库")
    p.add_argument("--json-file", help="从JSON文件读取全部字段（推荐用于长文本）")
    p.add_argument("--title", help="教训标题")
    p.add_argument("--severity", default="medium", help="严重级：high/medium/low")
    p.add_argument("--symptom", default="", help="现象")
    p.add_argument("--root-cause", default="", help="根因")
    p.add_argument("--fix", default="", help="解决方案")
    p.add_argument("--prevention", default="", help="防止复发")
    p.add_argument("--tags", default="", help="标签，逗号分隔")
    p.add_argument("--source-projects", default="", help="来源项目，逗号分隔")
    p.add_argument("--kb-root", default="", help="知识库根目录（默认 ~/.workbuddy/knowledge）")
    args = p.parse_args()

    if args.json_file:
        data = json.loads(Path(args.json_file).read_text(encoding="utf-8"))
    else:
        data = {
            "title": args.title or "",
            "severity": args.severity,
            "symptom": args.symptom,
            "root_cause": args.root_cause,
            "fix": args.fix,
            "prevention": args.prevention,
            "tags": [t.strip() for t in args.tags.split(",") if t.strip()],
            "source_projects": [t.strip() for t in args.source_projects.split(",")
                                if t.strip()],
        }

    if not all(data.get(k) for k in ("title", "symptom", "root_cause", "fix")):
        print("错误：title/symptom/root_cause/fix 为必填", file=sys.stderr)
        return 2

    storage = KnowledgeStorage(args.kb_root or None)
    path = ingest_lesson(
        storage,
        title=data["title"],
        severity=data.get("severity", "medium"),
        symptom=data["symptom"],
        root_cause=data["root_cause"],
        fix=data["fix"],
        prevention=data.get("prevention", ""),
        tags=data.get("tags", []),
        source_projects=data.get("source_projects", []),
    )
    print(f"[OK] 教训已入库: {path}")
    idx = KnowledgeIndexer(storage).rebuild()
    print(f"[OK] 索引已重建: {idx}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
