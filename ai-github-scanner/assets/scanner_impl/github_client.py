"""
scanner/github_client.py - GitHub API客户端封装

优先使用gh CLI（已认证），降级到REST API。
支持多领域关键词扫描、trending获取、缓存与限流保护。
"""
from __future__ import annotations

import json
import os
import subprocess
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

import requests


@dataclass
class RepoCandidate:
    """扫描候选项目 - 标准化数据结构"""
    full_name: str
    name: str
    owner: str
    url: str
    description: str
    language: str
    stars: int
    forks: int
    watchers: int
    open_issues: int
    topics: list[str]
    license: str | None
    created_at: str
    updated_at: str
    pushed_at: str
    homepage: str
    has_wiki: bool
    archived: bool
    domain: str            # 来源扫描领域
    scanned_at: str = field(default_factory=lambda: datetime.now(timezone.utc).isoformat())

    @classmethod
    def from_api(cls, item: dict, domain: str) -> "RepoCandidate":
        lic = item.get("license") or {}
        return cls(
            full_name=item.get("full_name", ""),
            name=item.get("name", ""),
            owner=(item.get("owner") or {}).get("login", ""),
            url=item.get("html_url", ""),
            description=item.get("description") or "",
            language=item.get("language") or "",
            stars=item.get("stargazers_count", 0),
            forks=item.get("forks_count", 0),
            watchers=item.get("subscribers_count", item.get("watchers_count", 0)),
            open_issues=item.get("open_issues_count", 0),
            topics=item.get("topics", []) or [],
            license=lic.get("spdx_id") if lic else None,
            created_at=item.get("created_at", ""),
            updated_at=item.get("updated_at", ""),
            pushed_at=item.get("pushed_at", ""),
            homepage=item.get("homepage") or "",
            has_wiki=item.get("has_wiki", False),
            archived=item.get("archived", False),
            domain=domain,
        )

    @classmethod
    def from_dict(cls, d: dict) -> "RepoCandidate":
        """从字典重建（用于缓存反序列化）"""
        return cls(**d)


class GitHubClient:
    """GitHub扫描客户端 - gh CLI优先 + REST降级"""

    def __init__(self, config: dict):
        self.config = config
        self.gh = config.get("github", {})
        self.api_base = self.gh.get("api_base", "https://api.github.com")
        self.use_gh_cli = self.gh.get("use_gh_cli", True)
        self.per_page = self.gh.get("per_page", 50)
        self.rate_buffer = self.gh.get("rate_limit_buffer", 100)
        self.cache_dir = Path("./data/scanned")
        self.cache_dir.mkdir(parents=True, exist_ok=True)
        self.cache_ttl = self.gh.get("cache_ttl_hours", 6) * 3600
        # 从环境变量或.env文件读取token，限流从60/hr提升到5000/hr
        self.token = os.environ.get("GITHUB_TOKEN") or self._load_env_token()
        if self.token:
            self._auth_headers = {"Authorization": f"token {self.token}",
                                   "Accept": "application/vnd.github+json"}
        else:
            self._auth_headers = {}

    @staticmethod
    def _load_env_token() -> str | None:
        """从项目根的.env文件读取GITHUB_TOKEN"""
        env_path = Path(".env")
        if not env_path.exists():
            return None
        for line in env_path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line.startswith("GITHUB_TOKEN=") and not line.startswith("#"):
                return line.split("=", 1)[1].strip().strip('"').strip("'")
        return None

    # ----- 公共入口 -----
    def scan_domains(self, domains: list[dict]) -> list[RepoCandidate]:
        """扫描多个领域，返回去重后的候选列表"""
        seen: set[str] = set()
        candidates: list[RepoCandidate] = []
        for dom in domains:
            if not dom.get("enabled", True):
                continue
            results = self._scan_one_domain(dom)
            for r in results:
                if r.full_name not in seen and not r.archived:
                    seen.add(r.full_name)
                    candidates.append(r)
        return candidates

    # ----- 单领域扫描 -----
    def _scan_one_domain(self, domain: dict) -> list[RepoCandidate]:
        name = domain["name"]
        cache_file = self.cache_dir / f"{name}.json"
        # 缓存命中检查
        if cache_file.exists():
            age = time.time() - cache_file.stat().st_mtime
            if age < self.cache_ttl:
                with cache_file.open("r", encoding="utf-8") as f:
                    return [RepoCandidate.from_dict(  # type: ignore
                        c) for c in json.load(f)]

        # trending模式 vs 关键词模式
        if domain.get("use_trending"):
            items = self._fetch_trending(domain)
        else:
            items = self._fetch_by_keywords(domain)

        # 持久化缓存（空结果通常由限流/网络失败引起，不写入缓存避免污染）
        if items:
            with cache_file.open("w", encoding="utf-8") as f:
                json.dump([i.__dict__ for i in items], f, ensure_ascii=False, indent=2)
        return items

    def _fetch_by_keywords(self, domain: dict) -> list[RepoCandidate]:
        keywords: list[str] = domain.get("keywords", [])
        min_stars = domain.get("min_stars", 100)
        langs = domain.get("languages", [])
        all_items: list[RepoCandidate] = []

        for kw in keywords:
            q = f"{kw} stars:>={min_stars} sort:stars-desc"
            if langs:
                q += f" language:{langs[0]}"
            page = 1
            while page <= 3:  # 每关键词最多3页
                items = self._search_repos(q, page)
                if not items:
                    break
                all_items.extend(
                    RepoCandidate.from_api(i, domain["name"]) for i in items)
                page += 1
        return all_items

    def _fetch_trending(self, domain: dict) -> list[RepoCandidate]:
        """trending广撒网：使用search API按近期stars增长排序"""
        min_stars = domain.get("min_stars", 1000)
        max_n = domain.get("max_candidates", 50)
        created_since = "2024-01-01"
        q = f"stars:>={min_stars} created:>={created_since} sort:stars-desc"
        items = self._search_repos(q, 1)
        items = items[:max_n]
        return [RepoCandidate.from_api(i, domain["name"]) for i in items]

    # ----- API 调用层 -----
    def _search_repos(self, query: str, page: int = 1) -> list[dict]:
        # 限流保护
        if not self._check_rate_limit():
            return []
        # 优先gh CLI
        if self.use_gh_cli and self._gh_available():
            return self._search_via_gh(query, page)
        return self._search_via_rest(query, page)

    def _search_via_gh(self, query: str, page: int) -> list[dict]:
        cmd = [
            self._gh_cmd(), "api",
            "-X", "GET",
            "/search/repositories",
            "-f", f"q={query}",
            "-f", f"per_page={self.per_page}",
            "-f", f"page={page}",
            "--jq", ".items[]",
        ]
        try:
            out = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
            if out.returncode != 0:
                return self._search_via_rest(query, page)
            # gh --jq每行一个JSON对象
            items = []
            for line in out.stdout.strip().split("\n"):
                line = line.strip()
                if line:
                    items.append(json.loads(line))
            return items
        except (subprocess.SubprocessError, json.JSONDecodeError):
            return self._search_via_rest(query, page)

    def _search_via_rest(self, query: str, page: int) -> list[dict]:
        params = {
            "q": query,
            "per_page": self.per_page,
            "page": page,
            "sort": "stars",
            "order": "desc",
        }
        try:
            r = requests.get(f"{self.api_base}/search/repositories",
                             params=params, headers=self._auth_headers, timeout=20)
            r.raise_for_status()
            return r.json().get("items", [])
        except requests.RequestException:
            return []

    def _rest_get(self, path: str, params: dict | None = None,
                  raw: bool = False) -> tuple[str, Any]:
        """
        REST GET兜底通道（gh CLI不可用/失败时使用，凭GITHUB_TOKEN走core池）。
        返回 (status, data) 三态：
          - ("ok", data)        请求成功（data可能为空list/空str，属真实值）
          - ("not_found", None) 资源不存在（如仓库无README，属真实缺失而非获取失败）
          - ("error", None)     获取失败（网络/限流/认证问题，数据缺失）
        """
        headers = dict(self._auth_headers)
        if raw:
            headers["Accept"] = "application/vnd.github.raw"
        try:
            r = requests.get(f"{self.api_base}{path}", params=params,
                             headers=headers, timeout=20)
            if r.status_code == 202:
                # GitHub stats接口首次请求时返回202（后台计算中），稍后重试一次
                time.sleep(2)
                r = requests.get(f"{self.api_base}{path}", params=params,
                                 headers=headers, timeout=20)
            if r.status_code == 204:
                return "ok", []          # 成功但无内容（如空仓库无contributors）
            if r.status_code == 200:
                try:
                    return "ok", (r.text if raw else r.json())
                except ValueError:
                    return "error", None
            if r.status_code in (404, 451):
                return "not_found", None
            return "error", None
        except requests.RequestException:
            return "error", None

    def _gh_cmd(self) -> str:
        """返回gh可执行文件路径，支持PATH和Windows默认安装位置"""
        # PATH中查找
        from shutil import which
        found = which("gh") or which("gh.exe")
        if found:
            return found
        # Windows默认安装位置fallback
        win_paths = [
            "C:/Program Files/GitHub CLI/gh.exe",
            "C:/Program Files (x86)/GitHub CLI/gh.exe",
            "C:/Users/QR/AppData/Local/Programs/GitHub CLI/gh.exe",
        ]
        for p in win_paths:
            if Path(p).exists():
                return p
        return "gh"  # fallback到PATH查找

    def _gh_available(self) -> bool:
        try:
            r = subprocess.run([self._gh_cmd(), "--version"],
                               capture_output=True, text=True, timeout=5)
            return r.returncode == 0
        except (subprocess.SubprocessError, OSError, FileNotFoundError):
            # FileNotFoundError/OSError: gh 不在 PATH（Windows 上未安装）
            # SubprocessError: gh 调用超时或异常
            return False

    def _check_rate_limit(self, resource: str = "search") -> bool:
        """
        检查指定资源池剩余配量。
        - search: 30/min（认证后）- 用于 /search/repositories
        - core: 5000/hr（认证后）- 用于 /repos/{owner}/{repo} /users/{user}/repos 等
        阈值按池limit百分比计算，避免固定值不适用不同limit。
        """
        try:
            r = requests.get(f"{self.api_base}/rate_limit",
                              headers=self._auth_headers, timeout=10)
            r.raise_for_status()
            res = r.json().get("resources", {})
            remaining = res.get(resource, {}).get("remaining", 0)
            limit = res.get(resource, {}).get("limit", 0)
            if limit == 0:
                return True
            # 阈值策略：保留 limit 的 20% 作为缓冲（search保留6次，core保留1000次）
            threshold = int(limit * 0.20)
            if remaining < threshold:
                print(f"  [WARN] {resource}池剩余配量低: {remaining}/{limit} "
                      f"(阈值{threshold})")
                return False
            return True
        except requests.RequestException:
            return True  # 检查失败不阻塞

    def _fetch_via_core_pool(self, owner: str) -> list[RepoCandidate]:
        """
        search池配量低时的轻度抓取fallback：用core池查询某owner的所有repos。
        core池5000/hr配量充裕，可承载多owner批量抓取。
        返回RepoCandidate列表，domain标记为 core_fallback。
        """
        if not self._check_rate_limit("core"):
            return []
        items: list[RepoCandidate] = []
        # 用core池查询某user/org的所有public repos
        url = f"{self.api_base}/users/{owner}/repos"
        params = {"per_page": 100, "sort": "updated", "type": "public"}
        try:
            r = requests.get(url, params=params,
                              headers=self._auth_headers, timeout=20)
            r.raise_for_status()
            for item in r.json():
                items.append(RepoCandidate.from_api(item, "core_fallback"))
        except requests.RequestException:
            pass
        return items

    def scan_domains_with_fallback(self, domains: list[dict],
                                    fallback_owners: list[str] | None = None
                                    ) -> list[RepoCandidate]:
        """
        扫描多领域，search池耗尽时自动切换core池做轻度抓取。
        fallback_owners: 当search池耗尽时，查询这些owner的repos作为兜底候选。
        """
        # 先尝试正常search扫描
        candidates = self.scan_domains(domains)
        # search池耗尽且候选不足时，启动core池fallback
        if (not candidates or len(candidates) < 10) and fallback_owners:
            if not self._check_rate_limit("search"):
                print("  [INFO] search池配量低，切换到core池做轻度抓取...")
                for owner in fallback_owners:
                    if self._check_rate_limit("core"):
                        items = self._fetch_via_core_pool(owner)
                        candidates.extend(items)
                        print(f"    + {owner}: 获取 {len(items)} 个repos")
        return candidates

    # ----- 增量数据获取（评估时使用）-----
    # 语义约定（v1.2.1）：成功→真实值（空list/空str/0均为真实值）；
    # gh与REST均失败→None（数据缺失，评分层不按0分计）
    def get_commit_activity(self, owner: str, repo: str) -> list[dict] | None:
        """获取近52周commit活跃度。None=获取失败（数据缺失）"""
        cmd = [
            self._gh_cmd(), "api",
            f"/repos/{owner}/{repo}/stats/commit_activity",
            "--jq", ".",
        ]
        try:
            out = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
            if out.returncode == 0 and out.stdout.strip():
                data = json.loads(out.stdout)
                if isinstance(data, list):
                    return data
        except (subprocess.SubprocessError, OSError, FileNotFoundError, json.JSONDecodeError):
            pass
        # REST兜底
        status, data = self._rest_get(
            f"/repos/{owner}/{repo}/stats/commit_activity")
        if status == "ok" and isinstance(data, list):
            return data
        return None

    def get_recent_releases(self, owner: str, repo: str, limit: int = 5) -> list[dict] | None:
        """获取最近releases。空list=真实无release；None=获取失败（数据缺失）"""
        cmd = [
            self._gh_cmd(), "api",
            f"/repos/{owner}/{repo}/releases",
            "--jq", f".[:{limit}]",
        ]
        try:
            out = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
            if out.returncode == 0 and out.stdout.strip():
                data = json.loads(out.stdout)
                if isinstance(data, list):
                    return data
        except (subprocess.SubprocessError, OSError, FileNotFoundError, json.JSONDecodeError):
            pass
        # REST兜底
        status, data = self._rest_get(f"/repos/{owner}/{repo}/releases",
                                      params={"per_page": limit})
        if status == "ok" and isinstance(data, list):
            return data[:limit]
        return None

    def get_contributors_count(self, owner: str, repo: str) -> int | None:
        """获取贡献者数量。0=真实无贡献者；None=获取失败（数据缺失）"""
        cmd = [
            self._gh_cmd(), "api",
            f"/repos/{owner}/{repo}/contributors",
            "--jq", "length",
        ]
        try:
            out = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
            if out.returncode == 0 and out.stdout.strip().isdigit():
                return int(out.stdout.strip())
        except (subprocess.SubprocessError, OSError, FileNotFoundError):
            pass
        # REST兜底
        status, data = self._rest_get(f"/repos/{owner}/{repo}/contributors",
                                      params={"per_page": 100})
        if status == "ok" and isinstance(data, list):
            return len(data)
        return None

    def get_readme_content(self, owner: str, repo: str) -> str | None:
        """获取README内容（截断8000字符）。""=真实无README；None=获取失败（数据缺失）"""
        cmd = [
            self._gh_cmd(), "api",
            f"/repos/{owner}/{repo}/readme",
            "-H", "Accept: application/vnd.github.raw",
        ]
        try:
            out = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
            if out.returncode == 0:
                return out.stdout[:8000]  # 截断
        except (subprocess.SubprocessError, OSError, FileNotFoundError):
            pass
        # REST兜底
        status, data = self._rest_get(f"/repos/{owner}/{repo}/readme", raw=True)
        if status == "ok" and isinstance(data, str):
            return data[:8000]
        if status == "not_found":
            return ""  # 仓库确实没有README（真实值，不是获取失败）
        return None