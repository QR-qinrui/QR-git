"""
indexer - 知识库索引构建器

每次有新 entry 入库后调用 rebuild()，重新生成：
  ~/.workbuddy/knowledge/INDEX.md           # 总索引
  ~/.workbuddy/knowledge/tags/{tag}.md      # 标签索引（按 tag 列出条目）
"""
from __future__ import annotations

import re
from collections import defaultdict
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Iterable

from .storage import KnowledgeStorage


FRONT_MATTER_RE = re.compile(r"^---\s*\n(.*?)\n---\s*\n", re.DOTALL)


@dataclass
class EntryMeta:
    """单条知识库条目的解析结果。"""
    file: Path
    relative_path: str
    title: str
    entry_type: str
    tags: list
    created_at: str
    summary: str  # 首段非空非标题文本


class KnowledgeIndexer:
    """扫描知识库 → 重建 INDEX.md 与 tags/{tag}.md。"""

    def __init__(self, storage: KnowledgeStorage) -> None:
        self.storage = storage

    # ---------- 公共入口 ----------
    def rebuild(self) -> Path:
        """扫描所有 entry → 生成 INDEX.md + tags/。返回 INDEX.md 路径。"""
        entries = list(self._iter_entries())
        index_md = self._render_index(entries)
        index_path = self.storage.index_path()
        index_path.write_text(index_md, encoding="utf-8")
        self._render_tags_index(entries)
        return index_path

    # ---------- 解析 ----------
    def _iter_entries(self) -> Iterable[EntryMeta]:
        for file in self.storage.list_entries():
            meta = self._parse_file(file)
            if meta:
                yield meta

    def _parse_file(self, file: Path) -> EntryMeta | None:
        try:
            text = file.read_text(encoding="utf-8")
        except Exception:
            return None
        m = FRONT_MATTER_RE.match(text)
        if not m:
            return None
        fm = m.group(1)
        body = text[m.end():]

        title = self._extract_yaml_field(fm, "title") or file.stem
        entry_type = self._extract_yaml_field(fm, "entry_type") or "project_summary"
        created_at = self._extract_yaml_field(fm, "created_at") or datetime.now().isoformat()
        tags = self._extract_yaml_list(fm, "tags")

        summary = self._extract_summary(body)
        rel = file.relative_to(self.storage.root).as_posix()
        return EntryMeta(
            file=file,
            relative_path=rel,
            title=title,
            entry_type=entry_type,
            tags=tags,
            created_at=created_at,
            summary=summary,
        )

    @staticmethod
    def _extract_yaml_field(fm: str, field: str) -> str:
        m = re.search(rf"^{field}:\s*(.+?)\s*$", fm, re.MULTILINE)
        if m:
            val = m.group(1).strip().strip('"').strip("'")
            # 列表型字段如 tags: [a, b]，返回首项前给出空
            if val.startswith("["):
                return ""
            return val
        return ""

    @staticmethod
    def _extract_yaml_list(fm: str, field: str) -> list:
        m = re.search(rf"^{field}:\s*\[(.*?)\]\s*$", fm, re.MULTILINE)
        if not m:
            return []
        items = [s.strip().strip('"').strip("'") for s in m.group(1).split(",") if s.strip()]
        return items

    @staticmethod
    def _extract_summary(body: str, max_chars: int = 200) -> str:
        # 找第一段非空、非标题、非分隔符的文本
        for line in body.splitlines():
            s = line.strip()
            if not s or s.startswith("#") or s.startswith("---") or s.startswith("```"):
                continue
            return s[:max_chars]
        return ""

    # ---------- 渲染 INDEX.md ----------
    def _render_index(self, entries: list[EntryMeta]) -> str:
        lines = [
            "# AI 知识库总索引",
            "",
            f"> 自动生成于 {datetime.now().isoformat(timespec='seconds')}  |  共 {len(entries)} 条",
            "> 请勿手编，运行 `python scripts/build_kb_index.py` 自动刷新。",
            "",
        ]

        # 按类型分组
        by_type: dict[str, list[EntryMeta]] = defaultdict(list)
        for e in entries:
            by_type[e.entry_type].append(e)

        type_labels = {
            "project_summary": "项目完成总结",
            "pattern": "可复用模式",
            "lesson": "经验教训",
        }

        for etype, label in type_labels.items():
            items = by_type.get(etype, [])
            if not items:
                continue
            lines.append(f"## {label} ({len(items)})")
            lines.append("")
            lines.append("| 日期 | 标题 | 标签 | 摘要 |")
            lines.append("|------|------|------|------|")
            for e in sorted(items, key=lambda x: x.created_at, reverse=True):
                tags_str = ", ".join(e.tags) if e.tags else "-"
                title_link = f"[{e.title}]({e.relative_path})"
                lines.append(
                    f"| {e.created_at[:10]} | {title_link} | {tags_str} | {e.summary[:60]} |"
                )
            lines.append("")

        # 标签云
        all_tags: dict[str, int] = defaultdict(int)
        for e in entries:
            for t in e.tags:
                all_tags[t] += 1
        if all_tags:
            lines.append("## 标签索引")
            lines.append("")
            for t, n in sorted(all_tags.items(), key=lambda x: -x[1]):
                lines.append(f"- [{t}](tags/{t}.md) ({n})")
            lines.append("")

        return "\n".join(lines)

    # ---------- 渲染 tags/{tag}.md ----------
    def _render_tags_index(self, entries: list[EntryMeta]) -> None:
        tags_dir = self.storage.tags_dir()
        # 清空旧文件
        for old in tags_dir.glob("*.md"):
            old.unlink()

        by_tag: dict[str, list[EntryMeta]] = defaultdict(list)
        for e in entries:
            for t in e.tags:
                by_tag[t].append(e)

        for tag, items in by_tag.items():
            lines = [
                f"# 标签：{tag}",
                "",
                f"共 {len(items)} 条目",
                "",
                "| 日期 | 标题 | 类型 | 摘要 |",
                "|------|------|------|------|",
            ]
            for e in sorted(items, key=lambda x: x.created_at, reverse=True):
                title_link = f"[{e.title}](../{e.relative_path})"
                lines.append(
                    f"| {e.created_at[:10]} | {title_link} | {e.entry_type} | {e.summary[:60]} |"
                )
            (tags_dir / f"{tag}.md").write_text("\n".join(lines) + "\n", encoding="utf-8")