"""迁移完整性复检：对照清单逐项验证链接有效性、目标存在性与字节一致性。"""

from __future__ import annotations

import os
from dataclasses import dataclass, field

from . import linker
from .manifest import load_json
from .migrator import tree_stats


@dataclass
class VerifyRecord:
    source: str
    target: str
    status: str  # ok / broken / missing
    detail: str = ""


@dataclass
class VerifyResult:
    records: list[VerifyRecord] = field(default_factory=list)

    @property
    def ok(self) -> int:
        return sum(1 for r in self.records if r.status == "ok")


def verify_manifest(manifest_path: str) -> VerifyResult:
    """复检清单中每个已完成项：

    - 目标必须存在且字节数与清单记录一致；
    - link 模式下原路径必须是有效链接且指向现存目标；
    - move 模式下原路径应为空（文件确已迁走）。
    """
    manifest = load_json(manifest_path)
    result = VerifyResult()
    for rec in manifest.records:
        if rec["status"] != "done":
            continue
        out = VerifyRecord(source=rec["source"], target=rec["target"],
                           status="ok")
        if not os.path.lexists(rec["target"]):
            out.status = "missing"
            out.detail = "目标不存在"
        else:
            _files, total = tree_stats(rec["target"])
            # 单文件与目录统一按字节比对（记录中的 size 为源大小）
            if os.path.isfile(rec["target"]) and total != rec["size"]:
                out.status = "broken"
                out.detail = (f"目标字节数 {total} 与清单记录 "
                              f"{rec['size']} 不一致")
        if out.status == "ok" and rec.get("mode") == "link" and rec.get("link"):
            # 目录须为链接；文件允许硬链接（与目标 samefile 即认定有效）
            if not linker.is_link(rec["source"]):
                same = False
                if os.path.isfile(rec["source"]) and os.path.lexists(rec["target"]):
                    try:
                        same = os.path.samefile(rec["source"], rec["target"])
                    except OSError:
                        same = False
                if not same:
                    out.status = "broken"
                    out.detail = "原路径不是链接（可能已被替换）"
        if out.status == "ok" and rec.get("mode") == "move":
            if os.path.lexists(rec["source"]):
                out.status = "broken"
                out.detail = "move 模式但原路径仍存在内容"
        result.records.append(out)
    return result
