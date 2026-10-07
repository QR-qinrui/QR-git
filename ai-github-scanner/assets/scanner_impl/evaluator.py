"""
scanner/evaluator.py - 多维度评估引擎

评分维度（与config.yaml权重对齐）：
  - code_quality    (25%)  代码质量：stars/forks比、contributors、license、topics
  - activity        (25%)  活跃度：近30天commit、最近push、release频率
  - community       (20%)  社区评价：watchers、issues处理、stars量级
  - practicality    (20%)  实用性：README完整度、与现有体系兼容度、topics契合
  - safety          (10%)  安全信号：license、archived、可疑描述

缺失数据语义（v1.2.1）：
  - 子项数据获取失败(None) → 剔除该子项，其余子项权重按比例归一化（不按0分计）
  - 子项真实值为0/空 → 仍计0分（如仓库确实无release）
  - 核心证据（contributors/commits/releases/readme）缺失时禁止auto_install，
    降级为recommend（危险动作需完整证据；可通过thresholds.require_full_data_for_auto_install关闭）

输出：EvaluationResult（含总分、各维度分、决策:auto_install/recommend/record/drop）
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any

from .github_client import GitHubClient, RepoCandidate


@dataclass
class DimensionScore:
    name: str
    score: float           # 0-100
    weight: float          # 0-1
    weighted: float        # score * weight
    details: dict[str, Any] = field(default_factory=dict)


@dataclass
class EvaluationResult:
    repo: RepoCandidate
    dimensions: list[DimensionScore]
    total_score: float
    decision: str          # auto_install | recommend | record | drop
    summary: str
    evaluated_at: str = field(
        default_factory=lambda: datetime.now(timezone.utc).isoformat())

    @property
    def missing_data(self) -> list[str]:
        """汇总所有维度的数据缺失项，如 ['activity.commits_last_4w', ...]"""
        out: list[str] = []
        for d in self.dimensions:
            out.extend(f"{d.name}.{m}" for m in d.details.get("missing_data", []))
        return out

    def to_dict(self) -> dict:
        return {
            "repo": self.repo.__dict__,
            "dimensions": [{"name": d.name, "score": d.score,
                            "weight": d.weight, "weighted": d.weighted,
                            "details": d.details} for d in self.dimensions],
            "total_score": round(self.total_score, 2),
            "decision": self.decision,
            "summary": self.summary,
            "missing_data": self.missing_data,
            "evaluated_at": self.evaluated_at,
        }


class Evaluator:
    """多维评分引擎"""

    # 关键词匹配 - 与现有WorkBuddy体系兼容度
    COMPAT_KEYWORDS = [
        "skill", "plugin", "mcp", "agent", "automation", "workflow",
        "claude", "cursor", "workbuddy", "ai-tool", "llm",
    ]

    def __init__(self, config: dict, client: GitHubClient | None = None):
        self.config = config
        self.weights = config.get("scoring_weights", {})
        self.thresholds = config.get("thresholds", {})
        self.client = client or GitHubClient(config)

    def evaluate(self, repo: RepoCandidate) -> EvaluationResult:
        """评估单个项目，返回带决策的结果"""
        dims: list[DimensionScore] = []
        dims.append(self._score_code_quality(repo))
        dims.append(self._score_activity(repo))
        dims.append(self._score_community(repo))
        dims.append(self._score_practicality(repo))
        dims.append(self._score_safety(repo))
        total = sum(d.weighted for d in dims)
        missing = [f"{d.name}.{m}" for d in dims
                   for m in d.details.get("missing_data", [])]
        decision = self._decide(total, missing)
        summary = self._build_summary(repo, total, decision, missing)
        return EvaluationResult(repo=repo, dimensions=dims,
                                total_score=total,
                                decision=decision, summary=summary)

    def evaluate_batch(self, repos: list[RepoCandidate]) -> list[EvaluationResult]:
        return [self.evaluate(r) for r in repos]

    # ----- 维度1：代码质量 (25%) -----
    def _score_code_quality(self, repo: RepoCandidate) -> DimensionScore:
        w = self.weights.get("code_quality", 0.25)
        # 子项打分（每项0-100）
        # stars量级（对数缩放）
        star_score = min(100, (repo.stars / 1000) * 30 + 10) if repo.stars > 0 else 0
        # forks/stars 比（健康项目通常0.05-0.3）
        fork_ratio = (repo.forks / repo.stars) if repo.stars > 0 else 0
        ratio_score = 100 if 0.05 <= fork_ratio <= 0.5 else (60 if fork_ratio > 0 else 30)
        # contributors数量（None=获取失败，不按0分计）
        contrib_count = self.client.get_contributors_count(repo.owner, repo.name)
        contrib_score = (min(100, contrib_count * 5)
                         if contrib_count is not None else None)
        # license
        lic_score = 100 if repo.license else 0
        # topics丰富度
        topic_score = min(100, len(repo.topics) * 15)

        score, missing = self._combine([
            ("stars", star_score, 0.25),
            ("fork_ratio", ratio_score, 0.20),
            ("contributors", contrib_score, 0.25),
            ("license", lic_score, 0.15),
            ("topics", topic_score, 0.15),
        ])
        return DimensionScore(
            name="code_quality", score=round(score, 2), weight=w,
            weighted=round(score * w, 2),
            details={
                "stars": repo.stars, "forks": repo.forks,
                "fork_ratio": round(fork_ratio, 4),
                "contributors": contrib_count,
                "license": repo.license, "topics_count": len(repo.topics),
                "missing_data": missing,
            },
        )

    # ----- 维度2：活跃度 (25%) -----
    def _score_activity(self, repo: RepoCandidate) -> DimensionScore:
        w = self.weights.get("activity", 0.25)
        # 最近push时间
        push_score = 0
        if repo.pushed_at:
            try:
                pushed = datetime.fromisoformat(
                    repo.pushed_at.replace("Z", "+00:00"))
                days_ago = (datetime.now(timezone.utc) - pushed).days
                if days_ago <= 7:
                    push_score = 100
                elif days_ago <= 30:
                    push_score = 80
                elif days_ago <= 90:
                    push_score = 60
                elif days_ago <= 180:
                    push_score = 40
                else:
                    push_score = 10
            except (ValueError, TypeError):
                push_score = 30

        # commit活跃度（近52周；None=获取失败，不按0分计）
        activity = self.client.get_commit_activity(repo.owner, repo.name)
        if activity is not None:
            recent_4w = sum(wk.get("total", 0) for wk in activity[-4:]) if activity else 0
            commit_score = min(100, recent_4w * 4)
        else:
            recent_4w = None
            commit_score = None

        # release频率（None=获取失败，不按0分计）
        releases = self.client.get_recent_releases(repo.owner, repo.name, 5)
        if releases is not None:
            release_count = len(releases)
            release_score = min(100, release_count * 20)
        else:
            release_count = None
            release_score = None

        score, missing = self._combine([
            ("push_recency", push_score, 0.40),
            ("commits_last_4w", commit_score, 0.40),
            ("releases", release_score, 0.20),
        ])
        return DimensionScore(
            name="activity", score=round(score, 2), weight=w,
            weighted=round(score * w, 2),
            details={
                "last_push_days_ago": self._days_since(repo.pushed_at),
                "commits_last_4w": recent_4w,
                "recent_releases": release_count,
                "missing_data": missing,
            },
        )

    # ----- 维度3：社区评价 (20%) -----
    def _score_community(self, repo: RepoCandidate) -> DimensionScore:
        w = self.weights.get("community", 0.20)
        # watchers量级
        watch_score = min(100, (repo.watchers / 100) * 30 + 10) if repo.watchers > 0 else 0
        # stars量级
        star_score = min(100, (repo.stars / 500) * 50) if repo.stars > 0 else 0
        # issues处理（open issues越少相对越好，但要有一定数量体现讨论热度）
        if repo.open_issues == 0:
            issue_score = 70   # 可能是项目小或维护好
        elif repo.open_issues < 50:
            issue_score = 90
        elif repo.open_issues < 200:
            issue_score = 70
        else:
            issue_score = 40
        # 有homepage说明有完整文档站
        home_score = 100 if repo.homepage else 50

        score = (watch_score * 0.30 + star_score * 0.30 +
                 issue_score * 0.25 + home_score * 0.15)
        return DimensionScore(
            name="community", score=round(score, 2), weight=w,
            weighted=round(score * w, 2),
            details={
                "watchers": repo.watchers, "stars": repo.stars,
                "open_issues": repo.open_issues, "has_homepage": bool(repo.homepage),
            },
        )

    # ----- 维度4：实用性 (20%) -----
    def _score_practicality(self, repo: RepoCandidate) -> DimensionScore:
        w = self.weights.get("practicality", 0.20)
        # README完整度（None=获取失败，不按0分计；""=真实无README，计0分）
        readme = self.client.get_readme_content(repo.owner, repo.name)
        if readme is None:
            readme_len = None
            readme_score = None
        else:
            readme_len = len(readme)
            readme_score = 0
            if readme:
                readme_score = 50  # 有README基础分
                if readme_len > 2000:
                    readme_score += 20
                if re.search(r"##\s+(install|usage|getting started)", readme, re.I):
                    readme_score += 20
                if re.search(r"##\s+(example|demo)", readme, re.I):
                    readme_score += 10
            readme_score = min(100, readme_score)

        # 与现有体系兼容度（关键词匹配）
        text = f"{repo.name} {repo.description} {' '.join(repo.topics)}".lower()
        matches = sum(1 for kw in self.COMPAT_KEYWORDS if kw in text)
        compat_score = min(100, matches * 25)

        # 描述完整度
        desc_score = 80 if repo.description and len(repo.description) > 30 else 30

        score, missing = self._combine([
            ("readme", readme_score, 0.40),
            ("compat_keywords", compat_score, 0.40),
            ("description", desc_score, 0.20),
        ])
        return DimensionScore(
            name="practicality", score=round(score, 2), weight=w,
            weighted=round(score * w, 2),
            details={
                "readme_length": readme_len,
                "compat_matches": matches,
                "matched_keywords": [kw for kw in self.COMPAT_KEYWORDS if kw in text],
                "has_description": bool(repo.description),
                "missing_data": missing,
            },
        )

    # ----- 维度5：安全信号 (10%) -----
    def _score_safety(self, repo:RepoCandidate) -> DimensionScore:
        w = self.weights.get("safety", 0.10)
        score = 100
        if not repo.license:
            score -= 30   # 无license扣分
        if repo.archived:
            score -= 50   # 已归档严重扣分
        # 描述中含可疑关键词
        suspicious = ["crypto miner", "free money", "hack tool"]
        desc = (repo.description or "").lower()
        for s in suspicious:
            if s in desc:
                score -= 40
        # 仓库创建时间过短（<30天）需谨慎
        if repo.created_at:
            try:
                created = datetime.fromisoformat(
                    repo.created_at.replace("Z", "+00:00"))
                age_days = (datetime.now(timezone.utc) - created).days
                if age_days < 30:
                    score -= 20
            except (ValueError, TypeError):
                pass
        score = max(0, score)
        return DimensionScore(
            name="safety", score=score, weight=w,
            weighted=round(score * w, 2),
            details={
                "has_license": bool(repo.license), "archived": repo.archived,
                "repo_age_days": self._days_since(repo.created_at),
            },
        )

    # ----- 通用：缺失数据感知的加权合并 -----
    @staticmethod
    def _combine(parts: list[tuple[str, float | None, float]]
                 ) -> tuple[float, list[str]]:
        """
        按权重合并子项得分，支持数据缺失语义：
          - score=None  → 数据缺失：剔除该项，其余子项权重按比例归一化（不按0分计）
          - score=数值  → 真实得分（0也是真实值，正常参与计算）
        返回 (合并得分, 缺失项名称列表)。全部缺失时返回中性分50。
        """
        available = [(name, s, wt) for name, s, wt in parts if s is not None]
        missing = [name for name, s, _ in parts if s is None]
        if not available:
            return 50.0, missing
        total_w = sum(wt for _, _, wt in available)
        score = sum(s * wt for _, s, wt in available) / total_w
        return score, missing

    # ----- 决策 -----
    def _decide(self, total: float, missing: list[str] | None = None) -> str:
        t = self.thresholds
        missing = missing or []
        if total >= t.get("auto_install", 85):
            # 数据完备性门：核心证据缺失时禁止自动安装（危险动作需完整证据）
            if missing and t.get("require_full_data_for_auto_install", True):
                return "recommend"
            return "auto_install"
        if total >= t.get("recommend", 70):
            return "recommend"
        if total >= t.get("record_only", 50):
            return "record"
        return "drop"

    def _build_summary(self, repo: RepoCandidate, total: float,
                       decision: str, missing: list[str] | None = None) -> str:
        labels = {
            "auto_install": "【自动安装】通过安全门后自动并入体系",
            "recommend": "【推荐】已生成推荐报告，待人工确认",
            "record": "【记录】达到记录阈值，暂不推荐",
            "drop": "【丢弃】未达阈值",
        }
        summary = f"{repo.full_name} | 总分 {total:.1f} | {labels[decision]}"
        if missing:
            summary += f" | 数据不完整({', '.join(missing)})"
        return summary

    def _days_since(self, iso_str: str) -> int | None:
        if not iso_str:
            return None
        try:
            dt = datetime.fromisoformat(iso_str.replace("Z", "+00:00"))
            return (datetime.now(timezone.utc) - dt).days
        except (ValueError, TypeError):
            return None