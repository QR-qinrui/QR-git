"""
scanner/installer.py - 自动安装器 + 安全门检查

流程：
  1. 安全门检查（block_patterns命中即阻止，warn_patterns命中即警告）
  2. 通过则clone到skills_cache并复制到~/.workbuddy/skills/
  3. 记录安装日志到data/installed/install_log.json

安全约束：本模块仅为本地代码包安装，不执行任意远程脚本。
"""
from __future__ import annotations

import json
import re
import shutil
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from dataclasses import dataclass, field

from .github_client import RepoCandidate


@dataclass
class SafetyReport:
    """安全门检查报告"""
    passed: bool = True
    blocked: bool = False
    warnings: list[str] = field(default_factory=list)
    blocks: list[str] = field(default_factory=list)
    suspicious_score: int = 0


class SafetyGate:
    """安全门 - 安装前强制静态检查"""

    def __init__(self, config: dict):
        gate = config.get("safety_gate", {})
        self.enabled = gate.get("enabled", True)
        self.block_patterns = [re.compile(p, re.I)
                                for p in gate.get("block_patterns", [])]
        self.warn_patterns = [re.compile(p, re.I)
                               for p in gate.get("warn_patterns", [])]
        self.require_license = gate.get("require_license", True)
        self.max_suspicious = gate.get("max_suspicious_score", 30)

    def check(self, repo: RepoCandidate,
              files: dict[str, str]) -> SafetyReport:
        """对项目文件进行静态扫描"""
        report = SafetyReport()
        if not self.enabled:
            return report

        suspicious = 0
        for fname, content in files.items():
            for pat in self.block_patterns:
                if pat.search(content):
                    report.blocks.append(
                        f"{fname}: 命中阻断模式 {pat.pattern}")
                    report.blocked = True
                    report.passed = False
                    suspicious += 25
            for pat in self.warn_patterns:
                if pat.search(content):
                    report.warnings.append(
                        f"{fname}: 命中警告模式 {pat.pattern}")
                    suspicious += 5

        if self.require_license and not repo.license:
            report.warnings.append("缺少license声明")
            suspicious += 10

        report.suspicious_score = min(100, suspicious)
        if report.suspicious_score > self.max_suspicious:
            report.passed = False
            report.blocked = True
            report.blocks.append(
                f"可疑分数 {report.suspicious_score} 超过上限 {self.max_suspicious}")

        return report


class Installer:
    """自动安装器 - 通过安全门后安装到skills目录"""

    def __init__(self, config: dict):
        self.config = config
        sys_cfg = config.get("system", {})
        self.skills_dir = Path(sys_cfg.get(
            "skills_install_dir", "~/.workbuddy/skills")).expanduser()
        self.cache_dir = Path("./data/installed")
        self.cache_dir.mkdir(parents=True, exist_ok=True)
        self.log_file = self.cache_dir / "install_log.json"
        self.gate = SafetyGate(config)

    def install(self, repo: RepoCandidate,
                files: dict[str, str]) -> dict:
        """安装流程：安全门 → 下载 → 部署 → 记录"""
        record = {
            "repo": repo.full_name,
            "url": repo.url,
            "stars": repo.stars,
            "license": repo.license,
            "attempted_at": datetime.now(timezone.utc).isoformat(),
            "status": "pending",
        }

        # 1. 安全门检查
        report = self.gate.check(repo, files)
        record["safety"] = {
            "passed": report.passed,
            "warnings": report.warnings,
            "blocks": report.blocks,
            "suspicious_score": report.suspicious_score,
        }
        if not report.passed:
            record["status"] = "blocked"
            self._append_log(record)
            return record

        # 2. 克隆到缓存目录
        cache_path = self.cache_dir / repo.name
        if cache_path.exists():
            shutil.rmtree(cache_path, ignore_errors=True)
        try:
            subprocess.run(
                ["git", "clone", "--depth", "1", repo.url, str(cache_path)],
                capture_output=True, timeout=60, check=True,
            )
        except (subprocess.SubprocessError,
                subprocess.TimeoutExpired) as e:
            record["status"] = "clone_failed"
            record["error"] = str(e)
            self._append_log(record)
            return record

        # 3. 部署到skills目录
        self.skills_dir.mkdir(parents=True, exist_ok=True)
        dest = self.skills_dir / repo.name
        if dest.exists():
            shutil.rmtree(dest, ignore_errors=True)
        try:
            shutil.copytree(cache_path, dest, dirs_exist_ok=True)
            record["status"] = "installed"
            record["installed_to"] = str(dest)
        except (shutil.Error, OSError) as e:
            record["status"] = "deploy_failed"
            record["error"] = str(e)

        self._append_log(record)
        return record

    def _append_log(self, record: dict) -> None:
        """追加安装记录到日志文件"""
        logs: list[dict] = []
        if self.log_file.exists():
            try:
                logs = json.loads(self.log_file.read_text(encoding="utf-8"))
            except json.JSONDecodeError:
                logs = []
        logs.append(record)
        self.log_file.write_text(
            json.dumps(logs, ensure_ascii=False, indent=2),
            encoding="utf-8")