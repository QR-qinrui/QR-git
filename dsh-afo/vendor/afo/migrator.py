"""原子迁移执行（模式 P2/P5/P6）：复制→校验→切换→验证→留备份。

三种迁移模式：
- copy：仅复制到目标，原件保留（最保守）；
- move：复制+校验后删除原件（常规整理）；
- link：复制+校验后原件改名 .bak，原位置建链接指向新位置（路径透明化）。

每个迁移项独立成"事务"：单项失败记录错误并继续其余项，不中断整体。
"""

from __future__ import annotations

import os
import shutil
from dataclasses import dataclass, field

from . import linker
from .planner import Plan, PlanItem


class MigrationError(RuntimeError):
    """迁移项失败。"""


def tree_stats(root: str) -> tuple[int, int]:
    """统计目录树 (文件数, 总字节数)。文件级校验的确定性依据。"""
    if os.path.isfile(root):
        return 1, os.path.getsize(root)
    count, total = 0, 0
    for dirpath, _dirnames, filenames in os.walk(root):
        for name in filenames:
            full = os.path.join(dirpath, name)
            try:
                count += 1
                total += os.path.getsize(full)
            except OSError:
                continue
    return count, total


def verify_copy(source: str, target: str) -> bool:
    """校验复制完整性：文件数与总字节数双侧一致才通过。"""
    return tree_stats(source) == tree_stats(target)


def safe_destination(path: str) -> str:
    """模式 P5：目标已存在时追加 _1/_2 递增后缀，绝不覆盖。"""
    if not os.path.lexists(path):
        return path
    base, ext = os.path.splitext(path)
    n = 1
    while os.path.lexists(f"{base}_{n}{ext}"):
        n += 1
    return f"{base}_{n}{ext}"


@dataclass
class ItemRecord:
    """单个迁移项的执行记录（写入迁移清单）。"""

    source: str
    target: str
    category: str
    size: int
    mode: str
    status: str = "pending"  # done / error / skipped
    backup: str = ""
    link: str = ""
    link_type: str = ""
    error: str = ""


@dataclass
class MigrationResult:
    """整体执行结果。"""

    records: list[ItemRecord] = field(default_factory=list)

    @property
    def done(self) -> int:
        return sum(1 for r in self.records if r.status == "done")

    @property
    def failed(self) -> int:
        return sum(1 for r in self.records if r.status == "error")


def migrate_item(item: PlanItem, mode: str, backup_tag: str) -> ItemRecord:
    """执行单个迁移项的五段式原子流程。"""
    record = ItemRecord(
        source=item.source, target=item.target,
        category=item.category, size=item.size, mode=mode,
    )
    try:
        if not os.path.lexists(item.source):
            record.status = "skipped"
            record.error = "源文件不存在（可能已被移动）"
            return record

        target = safe_destination(item.target)
        record.target = target
        os.makedirs(os.path.dirname(target), exist_ok=True)

        # 1) 复制（目录用 copytree，文件用 copy2 保留元数据）
        if os.path.isdir(item.source):
            shutil.copytree(item.source, target)
        else:
            shutil.copy2(item.source, target)

        # 2) 校验：不一致即清理半成品并报错，绝不动原件
        if not verify_copy(item.source, target):
            if os.path.isdir(target):
                shutil.rmtree(target, ignore_errors=True)
            else:
                os.remove(target)
            raise MigrationError("复制校验失败：源/目标文件数或字节数不一致")

        # 3) 切换：按模式处理原件
        if mode == "copy":
            pass  # 原件保留
        elif mode == "move":
            if os.path.isdir(item.source) and not linker.is_link(item.source):
                shutil.rmtree(item.source)
            else:
                os.remove(item.source)
        elif mode == "link":
            backup = item.source + ".bak-" + backup_tag
            backup = safe_destination(backup)
            os.rename(item.source, backup)
            record.backup = backup
            try:
                if os.path.isdir(backup):
                    record.link_type = linker.create_dir_link(item.source, target)
                else:
                    # 文件优先硬链接（同盘零拷贝），跨盘/不支持时退化为符号链接
                    try:
                        os.link(target, item.source)
                        record.link_type = "hardlink"
                    except OSError:
                        os.symlink(os.path.abspath(target), item.source)
                        record.link_type = "symlink"
                record.link = item.source
            except Exception:
                # 链接失败：还原原件，保持迁移前状态
                os.rename(backup, item.source)
                record.backup = ""
                raise
        else:
            raise ValueError(f"未知迁移模式: {mode}")

        record.status = "done"
    except Exception as exc:  # 单项失败不中断整体
        record.status = "error"
        record.error = str(exc)
    return record


def execute_plan(
    plan: Plan,
    mode: str = "move",
    backup_tag: str = "",
    batch_size: int = 10,
    progress=None,
) -> MigrationResult:
    """按方案批量执行（模式 P6：分批执行、批间汇报）。"""
    result = MigrationResult()
    items = plan.items
    for start in range(0, len(items), max(1, batch_size)):
        batch = items[start:start + max(1, batch_size)]
        for item in batch:
            record = migrate_item(item, mode=mode, backup_tag=backup_tag)
            result.records.append(record)
        if progress:
            progress(done=len(result.records), total=len(items),
                     batch_failed=sum(1 for r in result.records[-len(batch):]
                                      if r.status == "error"))
    return result
