"""迁移方案生成（模式 P1 的"确认门"输入：方案先行，批准后才执行）。"""

from __future__ import annotations

import os
from dataclasses import dataclass, field

from .scanner import FileEntry, ScanReport

# 各类别默认目标子目录名（英文名，跨平台最稳；可用 --dir-prefix 定制）。
DEFAULT_TARGET_DIRS: dict[str, str] = {
    "models": "models",
    "datasets": "datasets",
    "images": "images",
    "documents": "documents",
    "code": "code",
    "videos": "videos",
    "audio": "audio",
    "archives": "archives",
    "others": "others",
}


@dataclass
class PlanItem:
    """单个迁移项：源文件 -> 目标路径。"""

    source: str
    target: str
    category: str
    size: int


@dataclass
class Plan:
    """迁移方案：纯数据描述，本身不落盘、不改文件。"""

    source_root: str
    target_root: str
    items: list[PlanItem] = field(default_factory=list)
    dirs_to_create: list[str] = field(default_factory=list)

    @property
    def total_files(self) -> int:
        return len(self.items)

    @property
    def total_bytes(self) -> int:
        return sum(i.size for i in self.items)

    def to_dict(self) -> dict:
        return {
            "source_root": self.source_root,
            "target_root": self.target_root,
            "total_files": self.total_files,
            "total_bytes": self.total_bytes,
            "dirs_to_create": self.dirs_to_create,
            "items": [
                {"source": i.source, "target": i.target,
                 "category": i.category, "size": i.size}
                for i in self.items
            ],
        }


def build_plan(
    report: ScanReport,
    target_root: str,
    target_dirs: dict[str, str] | None = None,
    categories: set[str] | None = None,
) -> Plan:
    """根据扫描报告生成分类迁移方案。

    - target_dirs：类别 -> 子目录名映射，缺省用 DEFAULT_TARGET_DIRS。
    - categories：只纳入指定类别；None 表示全部。
    - 已位于 target_root 内的文件自动排除（避免自我迁移）。
    """
    dirs_map = dict(DEFAULT_TARGET_DIRS)
    if target_dirs:
        dirs_map.update(target_dirs)

    target_root_abs = os.path.abspath(target_root)
    plan = Plan(source_root=report.root, target_root=target_root_abs)
    planned_dirs: set[str] = set()

    for entry in report.files:
        if categories and entry.category not in categories:
            continue
        if os.path.abspath(entry.path).startswith(target_root_abs + os.sep):
            continue  # 已在目标结构内
        sub = dirs_map.get(entry.category, dirs_map["others"])
        target_dir = os.path.join(target_root_abs, sub)
        planned_dirs.add(target_dir)
        plan.items.append(PlanItem(
            source=entry.path,
            target=os.path.join(target_dir, entry.name),
            category=entry.category,
            size=entry.size,
        ))

    plan.dirs_to_create = sorted(planned_dirs)
    return plan


def format_plan_text(plan: Plan, size_fmt=None) -> str:
    """渲染方案摘要（确认门展示用）。"""
    if size_fmt is None:
        from .scanner import human_size
        size_fmt = human_size
    by_cat: dict[str, int] = {}
    for item in plan.items:
        by_cat[item.category] = by_cat.get(item.category, 0) + 1
    lines = [
        f"📋 迁移方案：{plan.source_root} -> {plan.target_root}",
        f"预计移动文件：{plan.total_files} 个（{size_fmt(plan.total_bytes)}）",
        "将创建子目录：",
    ]
    lines += [f"  {d}" for d in plan.dirs_to_create]
    lines.append("各类别文件数：")
    lines += [f"  {k}: {v} 个" for k, v in sorted(by_cat.items())]
    return "\n".join(lines)
