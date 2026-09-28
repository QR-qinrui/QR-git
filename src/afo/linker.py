"""跨平台路径透明化（模式 P3）：Windows 目录联接 / POSIX 符号链接。

兼容性策略：
- Windows 目录优先 Junction（`mklink /J`，无需管理员权限）；
- POSIX 或 Windows 文件用 os.symlink（Windows 上可能需要开发者模式/管理员）；
- 不支持时明确抛出 LinkUnsupportedError，由上层给出可读提示，绝不静默失败。
"""

from __future__ import annotations

import os
import subprocess
import sys

IS_WINDOWS = sys.platform.startswith("win")


class LinkUnsupportedError(RuntimeError):
    """当前平台/权限不支持所需链接方式。"""


def is_link(path: str) -> bool:
    """判断路径是否为符号链接或 Junction（Windows）。

    注：os.path.islink 对部分 Windows Junction 返回 False，
    因此增补 readlink 探测（Python 3.8+ 对 Junction 可用）。
    """
    if os.path.islink(path):
        return True
    if IS_WINDOWS and os.path.isdir(path):
        try:
            os.readlink(path)
            return True
        except OSError:
            return False
    return False


def _run_mklink(link: str, target: str) -> tuple[int, str]:
    """执行 cmd /c mklink /J，返回 (退出码, 合并输出)。

    输出按字节捕获后容错解码：中文 Windows 的 cmd 输出为 GBK，
    直接 text=True 在 PYTHONUTF8 环境下会抛 UnicodeDecodeError。
    注意：路径整体作为单个 argv 元素传入，避免 shell 对中文/空格路径误解析
    （踩坑记录：Git Bash 内拼 `cmd //c mklink //J` 会报"无效开关"）。
    """
    proc = subprocess.run(
        ["cmd", "/c", "mklink", "/J", link, target],
        capture_output=True,
    )
    out = (proc.stdout or b"") + (proc.stderr or b"")
    return proc.returncode, out.decode("gbk", errors="replace").strip()


def create_dir_link(link: str, target: str) -> str:
    """创建目录链接，返回实际使用的方式（"junction" / "symlink"）。

    Windows 优先 Junction；失败则尝试符号链接；均失败抛 LinkUnsupportedError。
    """
    target_abs = os.path.abspath(target)
    if not os.path.isdir(target_abs):
        raise NotADirectoryError(f"链接目标不是目录: {target_abs}")
    if os.path.lexists(link):
        raise FileExistsError(f"链接路径已存在: {link}")

    if IS_WINDOWS:
        returncode, junction_err = _run_mklink(link, target_abs)
        if returncode == 0:
            return "junction"
        try:
            os.symlink(target_abs, link, target_is_directory=True)
            return "symlink"
        except OSError as exc:
            raise LinkUnsupportedError(
                f"无法创建目录链接 {link} -> {target_abs}。\n"
                f"Junction 失败: {junction_err}\n"
                f"符号链接失败: {exc}\n"
                "建议：确认目标在本地磁盘（Junction 不支持网络路径），"
                "或以管理员身份运行 / 开启 Windows 开发者模式后重试。"
            ) from exc
    try:
        os.symlink(target_abs, link, target_is_directory=True)
        return "symlink"
    except OSError as exc:
        raise LinkUnsupportedError(
            f"无法创建符号链接 {link} -> {target_abs}: {exc}"
        ) from exc


def remove_dir_link(link: str) -> None:
    """移除目录链接（Junction 用 rmdir，只删链接不删目标数据）。

    安全约束：路径必须是链接；普通目录直接拒绝，防止误删真实数据。
    """
    if not is_link(link):
        raise ValueError(f"拒绝删除非链接路径（防误删真实数据）: {link}")
    if os.path.isdir(link):
        os.rmdir(link)  # 对 Junction/symlink 只移除链接本身
    else:
        os.unlink(link)


def detect_capabilities(workdir: str) -> dict:
    """探测当前环境链接能力，返回 {"junction": bool, "symlink": bool}。

    在 workdir 内真实试建试删，结果可靠（不做静态猜测）。
    """
    caps = {"junction": False, "symlink": False}
    target = os.path.join(workdir, ".afo_cap_target")
    os.makedirs(target, exist_ok=True)

    if IS_WINDOWS:
        link = os.path.join(workdir, ".afo_cap_junction")
        returncode, _msg = _run_mklink(link, target)
        if returncode == 0:
            caps["junction"] = True
            try:
                os.rmdir(link)
            except OSError:
                pass

    link = os.path.join(workdir, ".afo_cap_symlink")
    try:
        os.symlink(target, link, target_is_directory=True)
        caps["symlink"] = True
        try:
            os.rmdir(link) if os.path.isdir(link) else os.unlink(link)
        except OSError:
            pass
    except OSError:
        pass

    try:
        os.rmdir(target)
    except OSError:
        pass
    return caps
