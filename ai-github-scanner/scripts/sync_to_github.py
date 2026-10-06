#!/usr/bin/env python
"""
scripts/sync_to_github.py - 把 ai-github-scanner skill + 知识库同步到 GitHub

策略A（首选）：使用 GitHub Git Database API（blobs → tree → commit → ref），一次提交所有文件
策略B（fallback）：尝试 git push（需要直接网络）

用法：
  python scripts/sync_to_github.py --repo https://github.com/QR-qinrui/QR-git

认证：优先 GITHUB_TOKEN 环境变量，其次 gh auth token。
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import subprocess
import sys
from datetime import datetime
from pathlib import Path
from urllib.request import Request, urlopen

SKILL_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_KB_ROOT = Path.home() / ".workbuddy" / "knowledge"

# 同步时排除的文件名/扩展名
EXCLUDE_NAMES = {"__pycache__", ".pytest_cache", ".venv", "venv", "node_modules"}
EXCLUDE_EXTS = {".pyc", ".pyo", ".pyd", ".log"}
EXCLUDE_FILE_PATTERNS = (".env",)  # 任何 .env / .env.* 都不同步


# ============================================================
# token & HTTP
# ============================================================
def _resolve_token() -> str:
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if token:
        return token
    try:
        r = subprocess.run(
            ["gh", "auth", "token"],
            capture_output=True,
            text=True,
            encoding="utf-8",
        )
        if r.returncode == 0:
            return r.stdout.strip()
    except FileNotFoundError:
        pass
    return ""


def _api(method: str, url: str, token: str, body: dict | None = None) -> dict:
    """同步 GitHub REST API 调用"""
    data = json.dumps(body).encode("utf-8") if body else None
    req = Request(url, data=data, method=method)
    req.add_header("Authorization", f"token {token}")
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    if body is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urlopen(req, timeout=30) as resp:
            text = resp.read().decode("utf-8")
            return json.loads(text) if text else {}
    except Exception as e:
        return {"_error": str(e)}


# ============================================================
# 文件收集
# ============================================================
def _should_skip(p: Path) -> bool:
    name = p.name
    if name in EXCLUDE_NAMES:
        return True
    if any(name.startswith(pat) for pat in EXCLUDE_FILE_PATTERNS):
        return True
    if p.suffix in EXCLUDE_EXTS:
        return True
    return False


def _collect_files(root: Path, prefix_in_repo: str) -> list[dict]:
    """递归收集 root 下所有文件，返回 [{path, content_b64, size}]。"""
    results = []
    for p in root.rglob("*"):
        if not p.is_file():
            continue
        if any(part in EXCLUDE_NAMES for part in p.parts):
            continue
        if _should_skip(p):
            continue
        rel = p.relative_to(root).as_posix()
        repo_path = f"{prefix_in_repo}/{rel}" if prefix_in_repo else rel
        try:
            content = p.read_bytes()
        except Exception:
            continue
        results.append({
            "path": repo_path,
            "content_b64": base64.b64encode(content).decode("ascii"),
            "size": len(content),
        })
    return results


# ============================================================
# Git Database API 工作流
# ============================================================
def _parse_repo_url(repo_url: str) -> tuple[str, str]:
    """https://github.com/owner/repo → (owner, repo)"""
    s = repo_url.rstrip("/").replace("https://github.com/", "").replace("http://github.com/", "")
    if s.endswith(".git"):
        s = s[:-4]
    parts = s.split("/")
    if len(parts) != 2:
        raise ValueError(f"无法解析仓库 URL: {repo_url}")
    return parts[0], parts[1]


def _get_default_branch_sha(owner: str, repo: str, branch: str, token: str) -> dict:
    """获取分支当前的 commit sha，如果分支不存在则创建一次空提交。"""
    url = f"https://api.github.com/repos/{owner}/{repo}/git/refs/heads/{branch}"
    resp = _api("GET", url, token)
    if "_error" not in resp and "object" in resp:
        commit_sha = resp["object"]["sha"]
        # 获取 commit 的 tree sha
        url2 = f"https://api.github.com/repos/{owner}/{repo}/git/commits/{commit_sha}"
        resp2 = _api("GET", url2, token)
        return {
            "commit_sha": commit_sha,
            "tree_sha": resp2.get("tree", {}).get("sha", ""),
        }
    # 分支不存在，从默认分支拉取 + 创建新分支（简化处理：直接基于默认分支）
    url3 = f"https://api.github.com/repos/{owner}/{repo}"
    info = _api("GET", url3, token)
    default_branch = info.get("default_branch", "main")
    if default_branch == branch:
        # 完全空仓库，创建空初始提交
        tree_resp = _api("POST",
            f"https://api.github.com/repos/{owner}/{repo}/git/trees",
            token,
            {"tree": [], "message": "init"},
        )
        tree_sha = tree_resp.get("sha", "")
        commit_resp = _api("POST",
            f"https://api.github.com/repos/{owner}/{repo}/git/commits",
            token,
            {"message": f"init: empty repo", "tree": tree_sha},
        )
        commit_sha = commit_resp.get("sha", "")
        _api("POST",
            f"https://api.github.com/repos/{owner}/{repo}/git/refs",
            token,
            {"ref": f"refs/heads/{branch}", "sha": commit_sha},
        )
        return {"commit_sha": commit_sha, "tree_sha": tree_sha}

    # 从默认分支创建新分支
    url4 = f"https://api.github.com/repos/{owner}{repo}/git/refs/heads/{default_branch}"
    r = _api("GET", url4, token)
    parent_sha = r.get("object", {}).get("sha", "")
    _api("POST",
        f"https://api.github.com/repos/{owner}/{repo}/git/refs",
        token,
        {"ref": f"refs/heads/{branch}", "sha": parent_sha},
    )
    url5 = f"https://api.github.com/repos/{owner}/{repo}/git/commits/{parent_sha}"
    r2 = _api("GET", url5, token)
    return {
        "commit_sha": parent_sha,
        "tree_sha": r2.get("tree", {}).get("sha", ""),
    }


def _create_blobs(owner: str, repo: str, files: list[dict], token: str) -> list[dict]:
    """为每个文件创建 blob，返回 [{path, mode, type, sha}]。"""
    tree_entries = []
    print(f"[3/5] 创建 {len(files)} 个 blob...")
    for i, f in enumerate(files, 1):
        blob_url = f"https://api.github.com/repos/{owner}/{repo}/git/blobs"
        resp = _api("POST", blob_url, token, {
            "content": f["content_b64"],
            "encoding": "base64",
        })
        sha = resp.get("sha")
        if not sha:
            print(f"  [FAIL] blob 创建失败 ({f['path']}): {resp}")
            continue
        tree_entries.append({
            "path": f["path"],
            "mode": "100644",
            "type": "blob",
            "sha": sha,
        })
        if i % 5 == 0 or i == len(files):
            print(f"  [{i}/{len(files)}] {f['path']}")
    return tree_entries


def _create_tree(owner: str, str_repo: str, base_tree: str, entries: list[dict], token: str) -> str:
    """创建新 tree（基于 base_tree 增量覆盖）。"""
    url = f"https://api.github.com/repos/{owner}/{str_repo}/git/trees"
    resp = _api("POST", url, token, {
        "base_tree": base_tree,
        "tree": entries,
    })
    return resp.get("sha", "")


def _create_commit(owner: str, repo: str, tree_sha: str, parent_sha: str,
                   message: str, token: str) -> str:
    url = f"https://api.github.com/repos/{owner}/{repo}/git/commits"
    resp = _api("POST", url, token, {
        "message": message,
        "tree": tree_sha,
        "parents": [parent_sha],
    })
    return resp.get("sha", "")


def _update_ref(owner: str, repo: str, branch: str, commit_sha: str, token: str) -> bool:
    url = f"https://api.github.com/repos/{owner}/{repo}/git/refs/heads/{branch}"
    resp = _api("PATCH", url, token, {"sha": commit_sha, "force": True})
    return "object" in resp


# ============================================================
# 主同步函数
# ============================================================
def sync(
    repo_url: str,
    *,
    include_knowledge: bool = True,
    knowledge_only: bool = False,
    branch: str = "main",
    commit_msg: str = "",
) -> int:
    token = _resolve_token()
    if not token:
        print("[FAIL] 未找到 GITHUB_TOKEN 或 gh CLI 登录态", file=sys.stderr)
        return 3

    owner, repo = _parse_repo_url(repo_url)

    # 1. 收集文件
    files = []
    if not knowledge_only:
        files.extend(_collect_files(SKILL_ROOT, prefix_in_repo="ai-github-scanner"))
    if include_knowledge and DEFAULT_KB_ROOT.exists():
        files.extend(_collect_files(DEFAULT_KB_ROOT, prefix_in_repo="knowledge"))

    if not files:
        print("[FAIL] 没有可同步的文件", file=sys.stderr)
        return 1

    print(f"[1/5] 收集到 {len(files)} 个文件")
    total_kb = sum(f["size"] for f in files) / 1024
    print(f"      总大小: {total_kb:.1f} KB")

    # 2. 获取分支当前 commit + tree
    print(f"[2/5] 获取 {owner}/{repo} 的 {branch} 分支...")
    branch_info = _get_default_branch_sha(owner, repo, branch, token)
    if not branch_info.get("commit_sha"):
        print(f"[FAIL] 无法获取分支信息: {branch_info}", file=sys.stderr)
        return 1
    print(f"      当前 commit: {branch_info['commit_sha'][:7]}")

    # 3. 创建 blobs
    tree_entries = _create_blobs(owner, repo, files, token)
    if len(tree_entries) != len(files):
        print(f"[WARN] 部分文件 blob 创建失败 ({len(tree_entries)}/{len(files)})")

    # 4. 创建 tree + commit
    print(f"[4/5] 创建 tree + commit...")
    tree_sha = _create_tree(owner, repo, branch_info["tree_sha"], tree_entries, token)
    if not tree_sha:
        print("[FAIL] tree 创建失败", file=sys.stderr)
        return 1
    commit_sha = _create_commit(
        owner, repo, tree_sha, branch_info["commit_sha"],
        commit_msg or f"chore(skill): sync ai-github-scanner + knowledge base ({datetime.now().strftime('%Y-%m-%d %H:%M')})",
        token,
    )
    if not commit_sha:
        print("[FAIL] commit 创建失败", file=sys.stderr)
        return 1

    # 5. 更新 ref
    if not _update_ref(owner, repo, branch, commit_sha, token):
        print("[FAIL] 分支 ref 更新失败", file=sys.stderr)
        return 1

    commit_url = f"https://github.com/{owner}/{repo}/commit/{commit_sha}"
    print(f"\n[OK] 同步完成")
    print(f"     commit: {commit_url}")
    print(f"     文件数: {len(files)}")
    return 0


def main() -> int:
    p = argparse.ArgumentParser(description="同步 ai-github-scanner + 知识库到 GitHub")
    p.add_argument("--repo", required=True, help="GitHub 仓库 URL")
    p.add_argument("--branch", default="main", help="目标分支")
    p.add_argument("--include-knowledge", action="store_true", default=True,
                   help="包含知识库（默认开启）")
    p.add_argument("--knowledge-only", action="store_true",
                   help="仅同步知识库（不包含 skill 代码）")
    p.add_argument("--no-knowledge", action="store_true",
                   help="不同步知识库（仅 skill 代码）")
    p.add_argument("--message", default="", help="自定义提交信息")
    args = p.parse_args()

    return sync(
        args.repo,
        include_knowledge=not args.no_knowledge,
        knowledge_only=args.knowledge_only,
        branch=args.branch,
        commit_msg=args.message,
    )


if __name__ == "__main__":
    sys.exit(main())