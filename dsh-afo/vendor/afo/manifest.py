"""可追溯迁移清单（模式 P4）：manifest.json（机读）+ 迁移清单.md（人读）。"""

from __future__ import annotations

import json
import os
from dataclasses import asdict, dataclass, field

from . import __version__
from .migrator import MigrationResult
from .scanner import human_size

MANIFEST_VERSION = 1


@dataclass
class Manifest:
    """一次迁移的完整档案。"""

    tool_version: str
    created_at: str  # ISO 8601
    source_root: str
    target_root: str
    mode: str
    records: list[dict] = field(default_factory=list)
    manifest_version: int = MANIFEST_VERSION

    def to_dict(self) -> dict:
        return asdict(self)

    @classmethod
    def from_dict(cls, data: dict) -> "Manifest":
        return cls(
            tool_version=data.get("tool_version", "unknown"),
            created_at=data.get("created_at", ""),
            source_root=data.get("source_root", ""),
            target_root=data.get("target_root", ""),
            mode=data.get("mode", ""),
            records=data.get("records", []),
            manifest_version=data.get("manifest_version", MANIFEST_VERSION),
        )


def build_manifest(result: MigrationResult, source_root: str,
                   target_root: str, mode: str, created_at: str) -> Manifest:
    return Manifest(
        tool_version=__version__,
        created_at=created_at,
        source_root=source_root,
        target_root=target_root,
        mode=mode,
        records=[asdict(r) for r in result.records],
    )


def save_json(manifest: Manifest, path: str) -> str:
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(manifest.to_dict(), fh, ensure_ascii=False, indent=2)
    return path


def load_json(path: str) -> Manifest:
    with open(path, "r", encoding="utf-8-sig") as fh:
        data = json.load(fh)
    if not isinstance(data, dict) or "records" not in data:
        raise ValueError(f"不是有效的迁移清单文件: {path}")
    return Manifest.from_dict(data)


def save_markdown(manifest: Manifest, path: str) -> str:
    """生成人读迁移清单（原路径↔新路径+回滚方法），对齐实战清单格式。"""
    done = [r for r in manifest.records if r["status"] == "done"]
    failed = [r for r in manifest.records if r["status"] == "error"]
    lines = [
        f"# 迁移清单（{manifest.created_at[:10]}）",
        "",
        f"- 工具版本：afo {manifest.tool_version}",
        f"- 源目录：`{manifest.source_root}`",
        f"- 目标目录：`{manifest.target_root}`",
        f"- 迁移模式：{manifest.mode}",
        f"- 成功 {len(done)} 项 / 失败 {len(failed)} 项",
        "",
        "## 一、原路径 → 新路径",
        "",
        "| # | 类别 | 原路径 | 新路径 | 大小 | 状态 |",
        "|---|---|---|---|---|---|",
    ]
    for i, r in enumerate(manifest.records, 1):
        mark = {"done": "✅", "error": "❌", "skipped": "⏭️"}.get(r["status"], "?")
        lines.append(
            f"| {i} | {r['category']} | {r['source']} | {r['target']} "
            f"| {human_size(r['size'])} | {mark} |"
        )
    backups = [r for r in done if r.get("backup")]
    if backups:
        lines += ["", "## 二、回滚备份（未删除，核对后可自行清理）", ""]
        lines += [f"- `{r['backup']}` → 还原为 `{r['source']}`" for r in backups]
        lines += [
            "",
            "回滚方法：删除原路径处的链接（`afo rollback <manifest.json>` 可自动完成），"
            "或将 .bak 目录改名回原路径。",
        ]
    if failed:
        lines += ["", "## 三、失败明细", ""]
        lines += [f"- `{r['source']}`：{r['error']}" for r in failed]
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines) + "\n")
    return path
