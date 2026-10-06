"""
ingestor - 项目完成后的自动归纳引擎

输入：项目路径（或项目元信息 dict）
输出：写入知识库的 .md 文件路径

策略：
  1. 接收项目路径 + 完成状态
  2. 自动扫描目录识别"项目类型"（基于存在的文件特征）
  3. 从 references/evolution_log.md 抽取本次项目相关条目
  4. 调用 templates 渲染总结 markdown
  5. 写入 ~/.workbuddy/knowledge/projects/YYYY-MM/YYYY-MM-DD-slug.md
  6. 触发 indexer 重建 INDEX.md
  7. 返回写入路径 + 文件内容预览

支持两种调用方式：
  - 程序内：from knowledge.ingestor import ProjectIngestor
    ingestor = ProjectIngestor()
    ingestor.ingest_path("/path/to/project", goal="...", notes="...")
  - CLI：python scripts/ingest_project.py --path /path --goal "..." --notes "..."
"""
from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any

from .templates import ProjectSummaryTemplate, PatternTemplate, LessonTemplate
from .storage import KnowledgeStorage


# ============================================================
# 项目类型识别（基于文件特征）
# ============================================================
PROJECT_SIGNATURES = {
    "python": ["setup.py", "pyproject.toml", "requirements.txt", "Pipfile"],
    "node": ["package.json", "yarn.lock", "pnpm-lock.yaml"],
    "web": ["index.html", "vite.config.js", "next.config.js"],
    "skill": ["SKILL.md"],
    "scanner_project": ["config.yaml", "scanner/", "team/"],
}

# 标签识别：根据文件名/扩展名推断技术栈
TAG_SIGNATURES = {
    "python": [".py"],
    "typescript": [".ts", ".tsx"],
    "javascript": [".js", ".jsx"],
    "react": ["package.json"],
    "yaml": [".yaml", ".yml"],
    "markdown": [".md"],
    "github": [".github/", ".gitignore"],
    "mcp": ["mcp"],
    "skill": ["SKILL.md"],
}


@dataclass
class IngestResult:
    """归纳引擎返回值。"""
    success: bool
    entry_path: str = ""
    entry_type: str = "project_summary"
    project_id: str = ""
    detected_type: str = ""
    detected_tags: list = field(default_factory=list)
    message: str = ""


class ProjectIngestor:
    """项目归纳引擎主类。"""

    def __init__(
        self,
        kb_root: Path | str | None = None,
        skill_root: Path | str | None = None,
    ) -> None:
        self.storage = KnowledgeStorage(kb_root)
        # skill_root 用于查找 evolution_log.md；默认为本模块的上两级
        if skill_root:
            self.skill_root = Path(skill_root).expanduser()
        else:
            self.skill_root = Path(__file__).resolve().parent.parent

    # ---------- 公共入口 ----------
    def ingest_path(
        self,
        project_path: str | Path,
        *,
        goal: str = "",
        notes: str = "",
        status: str = "completed",
        tags: list | None = None,
        title: str | None = None,
        extra_body: dict | None = None,
    ) -> IngestResult:
        """对项目目录执行归纳总结并入库。"""
        path = Path(project_path).expanduser().resolve()
        if not path.exists():
            return IngestResult(success=False, message=f"路径不存在: {path}")

        # 1. 检测项目类型与标签
        detected_type = self._detect_project_type(path)
        detected_tags = self._detect_tags(path)
        if tags:
            detected_tags = list(set(detected_tags + tags))

        # 2. 生成 project_id
        project_id = self._gen_project_id(path, goal or path.name)

        # 3. 从 evolution_log 抽取相关条目
        evolution_extracts = self._extract_evolution_for_project(path.name)

        # 4. 自动扫描关键文件
        key_artifacts = self._scan_key_artifacts(path)

        # 5. 标题
        title = title or f"{path.name} - {datetime.now().strftime('%Y-%m-%d')} 项目总结"

        # 6. 渲染模板
        body = {
            "scope": self._infer_scope(path, detected_type),
            "deliverables": self._infer_deliverables(path, key_artifacts),
            "key_decisions": notes or "（用户未补充，可参考 evolution_log）",
            "technical_approach": self._infer_technical_approach(detected_type, key_artifacts),
            "key_artifacts": key_artifacts,
            "problems_and_solutions": evolution_extracts.get("problems", "（无）"),
            "reusable_patterns": evolution_extracts.get("patterns", "（待提炼）"),
            "lessons": evolution_extracts.get("lessons", "（待提炼）"),
            "next_steps": "建议运行 `python scripts/build_kb_index.py` 刷新索引；后续从本总结中提炼可复用模式。",
            "related_projects": "",
        }
        if extra_body:
            body.update(extra_body)

        content = ProjectSummaryTemplate.render_with_meta(
            title=title,
            project_id=project_id,
            goal=goal or f"自动归纳 - 项目位于 {path}",
            status=status,
            tags=detected_tags,
            related_skills=["ai-github-scanner"],
            source_path=str(path),
            **body,
        )

        # 7. 写入知识库
        kb_path = self.storage.resolve(
            title=title,
            entry_type="project_summary",
            project_id=project_id,
        )
        kb_path.entry_file.write_text(content, encoding="utf-8")

        # 8. 触发 indexer
        try:
            from .indexer import KnowledgeIndexer
            KnowledgeIndexer(self.storage).rebuild()
        except Exception as e:
            # 索引失败不阻塞入库
            return IngestResult(
                success=True,
                entry_path=str(kb_path.entry_file),
                entry_type="project_summary",
                project_id=project_id,
                detected_type=detected_type,
                detected_tags=detected_tags,
                message=f"入库成功，但索引重建失败: {e}",
            )

        return IngestResult(
            success=True,
            entry_path=str(kb_path.entry_file),
            entry_type="project_summary",
            project_id=project_id,
            detected_type=detected_type,
            detected_tags=detected_tags,
            message=f"项目总结已入库：{kb_path.relative_path}",
        )

    def ingest_summary(
        self,
        *,
        title: str,
        goal: str,
        body: dict,
        tags: list | None = None,
        status: str = "completed",
        source_path: str = "",
    ) -> IngestResult:
        """对已具备结构化内容的项目直接归纳（无需扫描目录）。"""
        project_id = self._gen_project_id(Path(source_path) if source_path else Path(title), goal)

        content = ProjectSummaryTemplate.render_with_meta(
            title=title,
            project_id=project_id,
            goal=goal,
            status=status,
            tags=tags or [],
            related_skills=["ai-github-scanner"],
            source_path=source_path,
            **body,
        )

        kb_path = self.storage.resolve(
            title=title,
            entry_type="project_summary",
            project_id=project_id,
        )
        kb_path.entry_file.write_text(content, encoding="utf-8")

        try:
            from .indexer import KnowledgeIndexer
            KnowledgeIndexer(self.storage).rebuild()
        except Exception:
            pass

        return IngestResult(
            success=True,
            entry_path=str(kb_path.entry_file),
            entry_type="project_summary",
            project_id=project_id,
            detected_tags=tags or [],
            message=f"项目总结已入库：{kb_path.relative_path}",
        )

    # ---------- 私有方法 ----------
    def _detect_project_type(self, path: Path) -> str:
        for ptype, signatures in PROJECT_SIGNATURES.items():
            for sig in signatures:
                if sig.endswith("/"):
                    if (path / sig).is_dir():
                        return ptype
                else:
                    if (path / sig).exists():
                        return ptype
        return "unknown"

    def _detect_tags(self, path: Path) -> list:
        tags = set()
        for tag, sigs in TAG_SIGNATURES.items():
            for sig in sigs:
                if sig.startswith(".") and list(path.glob(f"*{sig}")):
                    tags.add(tag)
                elif sig.endswith("/") and (path / sig).is_dir():
                    tags.add(tag)
                elif (path / sig).exists():
                    tags.add(tag)
        return sorted(tags)

    def _gen_project_id(self, path: Path, salt: str) -> str:
        date = datetime.now().strftime("%Y%m%d")
        # 用路径 + salt 哈希 8 位作为唯一标识
        h = hashlib.md5(f"{path}|{salt}".encode()).hexdigest()[:8]
        return f"proj-{date}-{h}"

    def _extract_evolution_for_project(self, project_name: str) -> dict:
        """从 references/evolution_log.md 抽取与本次项目相关的条目。"""
        log_path = self.skill_root / "references" / "evolution_log.md"
        if not log_path.exists():
            return {"problems": "（无 evolution_log）", "patterns": "（无）", "lessons": "（无）"}

        text = log_path.read_text(encoding="utf-8")
        # 简单按 ## 分段
        sections = re.split(r"\n## ", text)
        matches = [s for s in sections if project_name.lower() in s.lower()]
        if not matches:
            # 没匹配就取最近 2 段
            matches = sections[-3:-1] if len(sections) >= 3 else sections

        joined = "\n\n---\n\n".join(f"## {s.strip()}" for s in matches[-2:])
        return {
            "problems": joined or "（无）",
            "patterns": "（自动归纳阶段，可复用模式将在 indexer 第二轮分析后提取）",
            "lessons": "（同上）",
        }

    def _scan_key_artifacts(self, path: Path, max_files: int = 20) -> str:
        """扫描项目根目录，识别关键文件并格式化为 markdown 列表。"""
        lines = []
        try:
            for entry in sorted(path.iterdir(), key=lambda p: (p.is_file(), p.name.lower())):
                if entry.name.startswith(".") and entry.name not in (".gitignore", ".env.example"):
                    continue
                kind = "📁" if entry.is_dir() else "📄"
                size = ""
                if entry.is_file():
                    sz = entry.stat().st_size
                    size = f" ({sz} bytes)"
                lines.append(f"- {kind} `{entry.name}`{size}")
                if len(lines) >= max_files:
                    lines.append(f"- ... 共 {len(list(path.iterdir()))} 项")
                    break
        except PermissionError:
            lines.append("- （权限不足，无法列目录）")
        return "\n".join(lines) if lines else "（空目录）"

    def _infer_scope(self, path: Path, ptype: str) -> str:
        if ptype == "skill":
            return "Skill 模块（含 SKILL.md / references / scripts / assets）"
        if ptype == "scanner_project":
            return "Scanner 部署实例（含 config.yaml + scanner/ + team/ + data/）"
        if ptype == "python":
            return "Python 项目"
        if ptype == "node":
            return "Node.js 项目"
        return "通用项目"

    def _infer_deliverables(self, path: Path, key_artifacts: str) -> str:
        # 简单从 key_artifacts 中提取文件名清单
        return "见下方「项目关键文件」小节"

    def _infer_technical_approach(self, ptype: str, key_artifacts: str) -> str:
        return (
            f"项目类型自动识别为 **{ptype}**。技术栈与关键文件如下：\n\n{key_artifacts}\n\n"
            "（更详细的方案描述可由用户在 ingest 时通过 extra_body 提供）"
        )


# ============================================================
# 模式 / 教训 入库的便捷入口
# ============================================================
def ingest_pattern(
    storage: KnowledgeStorage,
    *,
    title: str,
    category: str,
    when_to_use: str,
    solution: str,
    code_sample: str = "",
    tags: list | None = None,
    source_projects: list | None = None,
    verified_in: list | None = None,
) -> Path:
    pid = f"pat-{datetime.now().strftime('%Y%m%d')}-{hashlib.md5(title.encode()).hexdigest()[:6]}"
    content = PatternTemplate.render_with_meta(
        title=title,
        pattern_id=pid,
        category=category,
        when_to_use=when_to_use,
        solution=solution,
        code_sample=code_sample,
        tags=tags or [],
        source_projects=source_projects or [],
        verified_in=verified_in or [],
    )
    kb_path = storage.resolve(title=title, entry_type="pattern", project_id=pid)
    kb_path.entry_file.write_text(content, encoding="utf-8")
    return kb_path.entry_file


def ingest_lesson(
    storage: KnowledgeStorage,
    *,
    title: str,
    severity: str,
    symptom: str,
    root_cause: str,
    fix: str,
    prevention: str = "",
    tags: list | None = None,
    source_projects: list | None = None,
) -> Path:
    lid = f"lsn-{datetime.now().strftime('%Y%m%d')}-{hashlib.md5(title.encode()).hexdigest()[:6]}"
    content = LessonTemplate.render_with_meta(
        title=title,
        lesson_id=lid,
        severity=severity,
        symptom=symptom,
        root_cause=root_cause,
        fix=fix,
        prevention=prevention,
        tags=tags or [],
        source_projects=source_projects or [],
    )
    kb_path = storage.resolve(title=title, entry_type="lesson", project_id=lid)
    kb_path.entry_file.write_text(content, encoding="utf-8")
    return kb_path.entry_file