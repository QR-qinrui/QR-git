"""只读目录扫描与统计（模式 P1：扫描阶段绝不修改任何文件）。"""

from __future__ import annotations

import os
from dataclasses import dataclass, field

# 文件类型映射表：类别 -> 扩展名集合（小写、含点）。
# models / datasets 为 AI 资产专用类别，置于通用类别之前优先匹配。
FILE_TYPES: dict[str, frozenset[str]] = {
    "models": frozenset({
        ".gguf", ".safetensors", ".ckpt", ".pt", ".pth", ".onnx",
        ".bin", ".h5", ".pb", ".tflite", ".mlmodel", ".mlpackage",
        ".lora", ".vae", ".ema",
    }),
    "datasets": frozenset({
        ".csv", ".tsv", ".parquet", ".jsonl", ".arrow", ".feather",
        ".npy", ".npz", ".hdf5", ".tfrecord",
    }),
    "images": frozenset({
        ".jpg", ".jpeg", ".png", ".gif", ".bmp", ".webp", ".svg",
        ".ico", ".tiff",
    }),
    "documents": frozenset({
        ".doc", ".docx", ".pdf", ".txt", ".md", ".xls", ".xlsx",
        ".ppt", ".pptx", ".odt", ".rtf", ".ini", ".log",
    }),
    "code": frozenset({
        ".js", ".ts", ".jsx", ".tsx", ".py", ".java", ".cpp", ".c",
        ".h", ".html", ".css", ".scss", ".json", ".xml", ".yaml",
        ".yml", ".go", ".rs", ".php", ".rb", ".swift", ".kt",
    }),
    "videos": frozenset({
        ".mp4", ".avi", ".mov", ".wmv", ".flv", ".mkv", ".webm", ".m4v",
    }),
    "audio": frozenset({
        ".mp3", ".wav", ".flac", ".aac", ".ogg", ".wma", ".m4a",
    }),
    "archives": frozenset({
        ".zip", ".rar", ".7z", ".tar", ".gz", ".bz2", ".xz",
    }),
}

OTHER = "others"

_EXT_TO_CATEGORY: dict[str, str] = {
    ext: category for category, exts in FILE_TYPES.items() for ext in exts
}

# 扫描时默认跳过的目录名（系统/版本控制/依赖目录，避免噪声与误迁）。
DEFAULT_SKIP_DIRS: frozenset[str] = frozenset({
    ".git", ".svn", ".hg", "node_modules", "__pycache__", ".venv",
    "venv", "$RECYCLE.BIN", "System Volume Information",
})


def categorize(filename: str) -> str:
    """按扩展名归类，未命中返回 others。"""
    ext = os.path.splitext(filename)[1].lower()
    return _EXT_TO_CATEGORY.get(ext, OTHER)


def human_size(num_bytes: float) -> str:
    """字节数格式化为 B/KB/MB/GB/TB，保留两位小数。"""
    size = float(num_bytes)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if size < 1024.0 or unit == "TB":
            return f"{size:.2f} {unit}"
        size /= 1024.0
    return f"{size:.2f} TB"  # pragma: no cover - 理论不可达


@dataclass
class FileEntry:
    """单个文件的扫描记录。"""

    path: str
    name: str
    category: str
    size: int
    mtime: float


@dataclass
class CategoryStat:
    """单类别统计。"""

    count: int = 0
    bytes: int = 0


@dataclass
class ScanReport:
    """扫描报告（纯数据，可 JSON 序列化为 dict）。"""

    root: str
    total_files: int = 0
    total_bytes: int = 0
    categories: dict[str, CategoryStat] = field(default_factory=dict)
    files: list[FileEntry] = field(default_factory=list)
    skipped_dirs: list[str] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)

    def stat(self, category: str) -> CategoryStat:
        return self.categories.setdefault(category, CategoryStat())

    def to_dict(self) -> dict:
        return {
            "root": self.root,
            "total_files": self.total_files,
            "total_bytes": self.total_bytes,
            "total_size_human": human_size(self.total_bytes),
            "categories": {
                name: {"count": s.count, "bytes": s.bytes,
                       "size_human": human_size(s.bytes)}
                for name, s in sorted(self.categories.items())
            },
            "files": [
                {"path": f.path, "name": f.name, "category": f.category,
                 "size": f.size, "size_human": human_size(f.size),
                 "mtime": f.mtime}
                for f in self.files
            ],
            "skipped_dirs": self.skipped_dirs,
            "errors": self.errors,
        }


def scan_directory(
    root: str,
    recursive: bool = True,
    skip_dirs: frozenset[str] = DEFAULT_SKIP_DIRS,
) -> ScanReport:
    """只读扫描目录，返回统计报告。不创建/修改/删除任何文件。

    - root 不存在或不是目录：抛 NotADirectoryError（由调用方转为明确提示）。
    - 无权限/被占用条目：记入 errors，不中断整体扫描。
    - 符号链接目录不跟随，避免环路。
    """
    if not os.path.isdir(root):
        raise NotADirectoryError(f"目录不存在或不可访问: {root}")

    report = ScanReport(root=os.path.abspath(root))
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        # 就地过滤子目录：跳过名单 + （非递归时）只允许顶层
        kept = []
        for d in dirnames:
            full = os.path.join(dirpath, d)
            if d in skip_dirs or os.path.islink(full):
                report.skipped_dirs.append(full)
            elif recursive or os.path.abspath(dirpath) == report.root:
                kept.append(d)
            else:
                report.skipped_dirs.append(full)
        dirnames[:] = kept

        for name in filenames:
            full = os.path.join(dirpath, name)
            try:
                st = os.stat(full, follow_symlinks=False)
            except OSError as exc:
                report.errors.append(f"{full}: {exc}")
                continue
            category = categorize(name)
            entry = FileEntry(
                path=full, name=name, category=category,
                size=st.st_size, mtime=st.st_mtime,
            )
            report.files.append(entry)
            report.total_files += 1
            report.total_bytes += st.st_size
            stat = report.stat(category)
            stat.count += 1
            stat.bytes += st.st_size
    return report


def format_report_text(report: ScanReport) -> str:
    """渲染人类可读的统计报告文本。"""
    lines = [
        f"📊 文件统计：{report.root}",
        f"总文件数：{report.total_files}",
        f"总大小：{human_size(report.total_bytes)}",
        "",
    ]
    icons = {
        "models": "🧠", "datasets": "🗃️", "images": "📷",
        "documents": "📄", "code": "💻", "videos": "🎬",
        "audio": "🎵", "archives": "📦", "others": "📁",
    }
    for name, stat in sorted(report.categories.items()):
        icon = icons.get(name, "📁")
        lines.append(f"{icon} {name}: {stat.count} 个 ({human_size(stat.bytes)})")
    if report.skipped_dirs:
        lines.append(f"\n已跳过目录：{len(report.skipped_dirs)} 个")
    if report.errors:
        lines.append(f"\n⚠️ 读取失败：{len(report.errors)} 个（详见 JSON 输出 errors）")
    return "\n".join(lines)
