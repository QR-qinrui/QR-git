#!/usr/bin/env python
"""
scripts/build_kb_index.py - 重建知识库索引

用法：
  python scripts/build_kb_index.py
  python scripts/build_kb_index.py --kb-root /custom/path
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

SKILL_ROOT = Path(__file__).resolve().parent.parent
if str(SKILL_ROOT) not in sys.path:
    sys.path.insert(0, str(SKILL_ROOT))

from knowledge.storage import KnowledgeStorage  # noqa: E402
from knowledge.indexer import KnowledgeIndexer  # noqa: E402


def main() -> int:
    p = argparse.ArgumentParser(description="重建知识库索引")
    p.add_argument("--kb-root", default="", help="知识库根目录（默认 ~/.workbuddy/knowledge）")
    args = p.parse_args()

    storage = KnowledgeStorage(args.kb_root or None)
    indexer = KnowledgeIndexer(storage)
    index_path = indexer.rebuild()
    print(f"[OK] 索引重建完成: {index_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())