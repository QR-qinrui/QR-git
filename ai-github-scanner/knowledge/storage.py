"""
storage - 知识库存储路径管理

布局（默认 ~/.workbuddy/knowledge/）：
  knowledge/
  ├── README.md
  ├── INDEX.md              # 自动生成总索引
  ├── projects/YYYY-MM/      # 按月分目录
  ├── patterns/              # 跨项目提炼
  ├── lessons/               # 教训
  └── tags/                  # 标签索引

文件命名约定：
  YYYY-MM-DD-{slug}.md
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path


DEFAULT_KB_ROOT = Path.home() / ".workbuddy" / "knowledge"


@dataclass
class KBPath:
    """知识库一次写入需要的所有路径。"""
    root: Path
    entry_file: Path       # 实际写入的 .md 文件
    entry_type: str       # project_summary / pattern / lesson
    relative_path: str     # 相对 root 的路径，用于 INDEX.md 中链接


class KnowledgeStorage:
    """统一管理知识库目录布局与文件命名。"""

    def __init__(self, root: Path | str | None = None) -> None:
        self.root = Path(root).expanduser() if root else DEFAULT_KB_ROOT
        self._ensure_layout()

    def _ensure_layout(self) -> None:
        for sub in ("projects", "patterns", "lessons", "tags"):
            (self.root / sub).mkdir(parents=True, exist_ok=True)
        readme = self.root / "README.md"
        if not readme.exists():
            readme.write_text(
                "# AI 知识库\n\n"
                "本知识库由 `ai-github-scanner` skill 的 `knowledge` 模块自动维护。\n\n"
                "- `projects/YYYY-MM/` 项目完成总结\n"
                "- `patterns/` 跨项目可复用模式\n"
                "- `lessons/` 经验教训\n"
                "- `tags/` 标签索引（自动生成）\n"
                "- `INDEX.md` 总索引（自动生成，请勿手编）\n",
                encoding="utf-8",
            )

    # ---------- 文件命名 ----------
    @staticmethod
    def slugify(text: str, max_len: int = 60) -> str:
        text = re.sub(r"[^\w\u4e00-\u9fa5\s-]", "", text).strip().lower()
        text = re.sub(r"[\s_]+", "-", text)
        text = re.sub(r"-+", "-", text)
        return text[:max_len].strip("-") or "untitled"

    @staticmethod
    def today_stamp() -> str:
        return datetime.now().strftime("%Y-%m-%d")

    @staticmethod
    def month_stamp() -> str:
        return datetime.now().strftime("%Y-%m")

    # ---------- 路径计算 ----------
    def resolve(
        self,
        *,
        title: str,
        entry_type: str = "project_summary",
        project_id: str | None = None,
    ) -> KBPath:
        """根据 entry_type 返回写入路径。"""
        slug = self.slugify(title)
        date = self.today_stamp()
        month = self.month_stamp()

        if entry_type == "project_summary":
            subdir = self.root / "projects" / month
            prefix = project_id or date
            filename = f"{date}-{slug}.md"
            entry_file = subdir / filename
        elif entry_type == "pattern":
            subdir = self.root / "patterns"
            prefix = date
            filename = f"{date}-{slug}.md"
            entry_file = subdir / filename
        elif entry_type == "lesson":
            subdir = self.root / "lessons"
            prefix = date
            filename = f"{date}-{slug}.md"
            entry_file = subdir / filename
        else:
            raise ValueError(f"未知 entry_type: {entry_type}")

        subdir.mkdir(parents=True, exist_ok=True)
        # 重名加序号
        counter = 2
        while entry_file.exists():
            stem = entry_file.stem
            entry_file = entry_file.with_name(f"{stem}-{counter}.md")
            counter += 1

        rel = entry_file.relative_to(self.root).as_posix()
        return KBPath(
            root=self.root,
            entry_file=entry_file,
            entry_type=entry_type,
            relative_path=rel,
        )

    # ---------- 列举 ----------
    def list_entries(self, entry_type: str | None = None) -> list[Path]:
        """列举知识库中的所有 entry 文件。"""
        results: list[Path] = []
        types = [entry_type] if entry_type else ["projects", "patterns", "lessons"]
        for t in types:
            base = self.root / t
            if not base.exists():
                continue
            results.extend(sorted(base.rglob("*.md"), reverse=True))
        return results

    def index_path(self) -> Path:
        return self.root / "INDEX.md"

    def tags_dir(self) -> Path:
        return self.root / "tags"