"""内置自检：环境兼容性检测 + 临时沙盒全链路实测。

自检在系统临时目录下创建独立沙盒，真实跑一遍
"扫描→方案→迁移→复检→回滚"全流程，全程不触碰用户任何真实文件。
输出逐项 ✅/❌ 检测报告，进程退出码 0=全部通过，1=存在失败项。
"""

from __future__ import annotations

import os
import platform
import shutil
import sys
import tempfile
from dataclasses import dataclass, field

from . import __version__, linker
from .manifest import load_json, save_json, save_markdown, build_manifest
from .migrator import execute_plan
from .planner import build_plan
from .rollback import rollback
from .scanner import scan_directory
from .verify import verify_manifest

MIN_PYTHON = (3, 8)


@dataclass
class Check:
    name: str
    passed: bool
    detail: str = ""


@dataclass
class SelfcheckReport:
    checks: list[Check] = field(default_factory=list)

    def add(self, name: str, passed: bool, detail: str = "") -> bool:
        self.checks.append(Check(name=name, passed=passed, detail=detail))
        return passed

    @property
    def ok(self) -> bool:
        return all(c.passed for c in self.checks)


def _build_sandbox(root: str) -> str:
    """在沙盒内构造样例文件树，返回源目录。"""
    src = os.path.join(root, "src")
    os.makedirs(src, exist_ok=True)
    samples = {
        "photo.jpg": b"\xff\xd8\xff" + b"0" * 100,
        "notes.md": "# hello\n".encode("utf-8") * 20,
        "model.gguf": b"GGUF" + b"x" * 2048,
        "data.csv": b"a,b\n1,2\n" * 50,
        "app.py": b"print('hi')\n",
        "pack.zip": b"PK\x03\x04" + b"z" * 64,
    }
    for name, content in samples.items():
        with open(os.path.join(src, name), "wb") as fh:
            fh.write(content)
    return src


def run_selfcheck(verbose: bool = True) -> SelfcheckReport:
    """执行全部自检项并返回报告。"""
    report = SelfcheckReport()

    # 1) Python 版本
    vi = sys.version_info
    report.add(
        f"Python 版本 >= {MIN_PYTHON[0]}.{MIN_PYTHON[1]}（当前 "
        f"{vi.major}.{vi.minor}.{vi.micro}）",
        vi >= MIN_PYTHON,
    )

    # 2) 平台信息（仅报告，不判定）
    report.add(f"平台识别：{platform.system()} {platform.release()} "
               f"（{sys.platform}）", True)

    # 3) 临时目录可写 + 链接能力实测
    sandbox = tempfile.mkdtemp(prefix="afo_selfcheck_")
    try:
        caps = linker.detect_capabilities(sandbox)
        report.add("临时目录可写", True, sandbox)
        if linker.IS_WINDOWS:
            report.add("目录联接（Junction）可用", caps["junction"],
                       "不可用时 link 模式将自动降级/报错")
        report.add("符号链接可用", caps["symlink"],
                   "Windows 无开发者模式/管理员权限时可能不可用")

        # 4) 沙盒全链路：scan → plan → migrate(link/move) → verify → rollback
        src = _build_sandbox(sandbox)
        dst = os.path.join(sandbox, "dst")

        scan = scan_directory(src)
        report.add("扫描：识别 6 个样例文件", scan.total_files == 6,
                   f"实际 {scan.total_files}")
        cats = set(scan.categories)
        report.add("扫描：类别覆盖 models/datasets/images/documents/code/archives",
                   {"models", "datasets", "images", "documents",
                    "code", "archives"} <= cats,
                   f"实际 {sorted(cats)}")

        plan = build_plan(scan, dst)
        report.add("方案：生成 6 个迁移项", plan.total_files == 6,
                   f"实际 {plan.total_files}")

        can_link = caps["junction"] or caps["symlink"]
        mode = "link" if can_link else "move"
        result = execute_plan(plan, mode=mode, backup_tag="selfcheck")
        report.add(f"迁移（{mode} 模式）：6 项全部成功",
                   result.done == 6 and result.failed == 0,
                   f"成功 {result.done} 失败 {result.failed}")

        mf_path = os.path.join(sandbox, "manifest.json")
        mf = build_manifest(result, src, dst, mode, "selfcheck-run")
        save_json(mf, mf_path)
        save_markdown(mf, os.path.join(sandbox, "迁移清单_selfcheck.md"))
        loaded = load_json(mf_path)
        report.add("清单：manifest.json 写入并可回读",
                   len(loaded.records) == 6)

        vr = verify_manifest(mf_path)
        report.add("复检：6 项全部 ok", vr.ok == 6,
                   f"实际 ok={vr.ok}")

        rb = rollback(mf_path)
        expect_restored = 6
        report.add("回滚：6 项全部还原", rb.restored == expect_restored,
                   f"实际 restored={rb.restored}")

        restored_ok = (
            os.path.isfile(os.path.join(src, "model.gguf"))
            and not linker.is_link(os.path.join(src, "model.gguf"))
        )
        report.add("回滚后源目录恢复原状（实体文件、无残留链接）",
                   restored_ok)
    finally:
        shutil.rmtree(sandbox, ignore_errors=True)

    report.add("沙盒清理完成", not os.path.exists(sandbox))

    if verbose:
        print(format_selfcheck_text(report))
    return report


def format_selfcheck_text(report: SelfcheckReport) -> str:
    lines = [f"afo selfcheck（版本 {__version__}）", ""]
    for c in report.checks:
        mark = "✅" if c.passed else "❌"
        suffix = f" — {c.detail}" if c.detail else ""
        lines.append(f"{mark} {c.name}{suffix}")
    passed = sum(1 for c in report.checks if c.passed)
    lines += ["", f"结果：{passed}/{len(report.checks)} 项通过"
              + ("，核心功能正常。" if report.ok else "，存在失败项！")]
    return "\n".join(lines)
