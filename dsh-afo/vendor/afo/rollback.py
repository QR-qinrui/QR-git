"""按迁移清单回滚（模式 P4 的逆向操作）。

回滚策略：
- link 模式：删除原路径处的链接 → .bak 备份改名还原；
- move 模式：目标复制回源路径（目标保留，不二次破坏）；
- copy 模式：无原件变更，仅提示。
任何一步失败记录错误并继续其余项。
"""

from __future__ import annotations

import os
import shutil
from dataclasses import dataclass, field

from . import linker
from .manifest import Manifest, load_json


@dataclass
class RollbackRecord:
    source: str
    status: str  # restored / skipped / error
    detail: str = ""


@dataclass
class RollbackResult:
    records: list[RollbackRecord] = field(default_factory=list)

    @property
    def restored(self) -> int:
        return sum(1 for r in self.records if r.status == "restored")


def rollback_item(record: dict) -> RollbackRecord:
    source = record["source"]
    backup = record.get("backup", "")
    mode = record.get("mode", "")
    out = RollbackRecord(source=source, status="skipped")
    try:
        if record["status"] != "done":
            out.detail = "迁移未成功项无需回滚"
            return out

        if mode == "link" and backup:
            # 1) 删除链接（仅当确实是链接；硬链接通过与目标 samefile 判定；
            #    与目标无关的普通文件/目录拒绝覆盖）
            if os.path.lexists(source):
                if linker.is_link(source):
                    linker.remove_dir_link(source)
                elif os.path.isfile(source) and os.path.lexists(record["target"]) \
                        and os.path.samefile(source, record["target"]):
                    os.remove(source)  # 我方创建的硬链接
                else:
                    out.status = "error"
                    out.detail = "原路径现存普通文件/目录，非链接，拒绝覆盖；请人工处理"
                    return out
            # 2) 备份还原
            if not os.path.lexists(backup):
                out.status = "error"
                out.detail = f"备份不存在: {backup}"
                return out
            os.rename(backup, source)
            out.status = "restored"
            out.detail = f"已从 {backup} 还原"
        elif mode == "move":
            target = record["target"]
            if os.path.lexists(source):
                out.detail = "源路径已存在内容，跳过"
                return out
            if not os.path.lexists(target):
                out.status = "error"
                out.detail = f"目标不存在，无法回滚: {target}"
                return out
            os.makedirs(os.path.dirname(source), exist_ok=True)
            if os.path.isdir(target):
                shutil.copytree(target, source)
            else:
                shutil.copy2(target, source)
            out.status = "restored"
            out.detail = "已从目标复制还原（目标保留未删）"
        else:
            out.detail = "copy 模式未改动原件，无需回滚"
    except Exception as exc:
        out.status = "error"
        out.detail = str(exc)
    return out


def rollback(manifest_path: str, only: set[str] | None = None) -> RollbackResult:
    """按清单回滚。only 非空时只回滚指定类别。"""
    manifest: Manifest = load_json(manifest_path)
    result = RollbackResult()
    for record in manifest.records:
        if only and record.get("category") not in only:
            continue
        result.records.append(rollback_item(record))
    return result
