"""
scanner/report.py - 评估报告生成器

输出 HTML + JSON 双格式报告：
  - HTML：可视化看板，含 Top20 项目卡片、维度雷达图、决策分布
  - JSON：结构化数据，供下游自动化消费
"""
from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path

from .evaluator import EvaluationResult


HTML_TEMPLATE = """<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<title>AI GitHub Skill Scanner Report - {generated_at}</title>
<style>
  * {{ box-sizing: border-box; margin: 0; padding: 0; }}
  body {{ font-family: -apple-system, "Segoe UI", "PingFang SC", "Microsoft YaHei", sans-serif;
         background: #f5f7fa; color: #1a202c; padding: 24px; line-height: 1.6; }}
  .container {{ max-width: 1280px; margin: 0 auto; }}
  h1 {{ font-size: 28px; margin-bottom: 8px; color: #1a202c; }}
  .meta {{ color: #718096; font-size: 14px; margin-bottom: 32px; }}
  .stats {{ display: grid; grid-template-columns: repeat(4, 1fr); gap: 16px; margin-bottom: 32px; }}
  .stat-card {{ background: white; padding: 20px; border-radius: 8px;
                box-shadow: 0 1px 3px rgba(0,0,0,0.08); }}
  .stat-card .label {{ font-size: 13px; color: #718096; margin-bottom: 4px; }}
  .stat-card .value {{ font-size: 28px; font-weight: 600; color: #2d3748; }}
  .section-title {{ font-size: 20px; margin: 32px 0 16px; color: #2d3748; }}
  .repo-list {{ display: grid; gap: 12px; }}
  .repo-card {{ background: white; padding: 16px 20px; border-radius: 8px;
                box-shadow: 0 1px 3px rgba(0,0,0,0.06); display: grid;
                grid-template-columns: 60px 1fr 120px 100px; gap: 16px; align-items: center; }}
  .rank {{ font-size: 24px; font-weight: 700; color: #cbd5e0; text-align: center; }}
  .rank.top {{ color: #d69e2e; }}
  .repo-info .name {{ font-size: 15px; font-weight: 600; }}
  .repo-info .name a {{ color: #2b6cb0; text-decoration: none; }}
  .repo-info .desc {{ font-size: 13px; color: #718096; margin-top: 2px;
                      overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }}
  .repo-info .meta {{ font-size: 12px; color: #a0aec0; margin-top: 4px; }}
  .score {{ font-size: 22px; font-weight: 700; text-align: center; }}
  .score.high {{ color: #38a169; }}
  .score.mid {{ color: #d69e2e; }}
  .score.low {{ color: #e53e3e; }}
  .decision {{ font-size: 12px; padding: 4px 10px; border-radius: 12px; text-align: center; font-weight: 500; }}
  .decision.auto_install {{ background: #c6f6d5; color: #22543d; }}
  .decision.recommend {{ background: #feebc8; color: #7b341e; }}
  .decision.record {{ background: #e2e8f0; color: #4a5568; }}
  .decision.drop {{ background: #fed7d7; color: #742a2a; }}
  .dim-bar {{ display: flex; gap: 4px; margin-top: 6px; }}
  .dim-bar span {{ flex: 1; height: 4px; border-radius: 2px; background: #e2e8f0; }}
  .dim-bar span.on {{ background: #4299e1; }}
  .empty {{ padding: 40px; text-align: center; color: #a0aec0; }}
</style>
</head>
<body>
<div class="container">
  <h1>AI GitHub Skill Scanner 评估报告</h1>
  <div class="meta">生成时间：{generated_at} | 扫描候选：{total} 个 | 数据来源：GitHub API</div>

  <div class="stats">
    <div class="stat-card"><div class="label">自动安装</div><div class="value" style="color:#38a169">{auto_install}</div></div>
    <div class="stat-card"><div class="label">推荐待确认</div><div class="value" style="color:#d69e2e">{recommend}</div></div>
    <div class="stat-card"><div class="label">仅记录</div><div class="value" style="color:#718096">{record}</div></div>
    <div class="stat-card"><div class="label">丢弃</div><div class="value" style="color:#e53e3e">{drop}</div></div>
  </div>

  <div class="section-title">Top {top_n} 优质项目</div>
  <div class="repo-list">
    {repo_cards}
  </div>
</div>
</body>
</html>"""


REPO_CARD_TEMPLATE = """<div class="repo-card">
  <div class="rank {rank_class}">{rank}</div>
  <div class="repo-info">
    <div class="name"><a href="{url}" target="_blank">{name}</a></div>
    <div class="desc">{desc}</div>
    <div class="meta">★ {stars} · 🍴 {forks} · 👁 {watchers} · {language} · {license}</div>
    <div class="dim-bar">{dim_bars}</div>
  </div>
  <div class="score {score_class}">{score}</div>
  <div class="decision {decision}">{decision_label}</div>
</div>"""


DECISION_LABELS = {
    "auto_install": "自动安装",
    "recommend": "推荐",
    "record": "记录",
    "drop": "丢弃",
}


class ReportGenerator:
    """报告生成器"""

    def __init__(self, config: dict):
        rep_cfg = config.get("report", {})
        self.output_dir = Path(rep_cfg.get("output_dir", "./data/reports"))
        self.output_dir.mkdir(parents=True, exist_ok=True)
        self.top_n = rep_cfg.get("top_n", 20)

    def generate(self, results: list[EvaluationResult]) -> dict[str, str]:
        """生成HTML+JSON报告，返回文件路径"""
        timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%d_%H-%M-%S")

        # 决策分布
        decision_counts = {"auto_install": 0, "recommend": 0, "record": 0, "drop": 0}
        for r in results:
            decision_counts[r.decision] = decision_counts.get(r.decision, 0) + 1

        # Top N 排序
        sorted_results = sorted(results, key=lambda r: r.total_score, reverse=True)
        top_results = sorted_results[:self.top_n]

        # 生成HTML
        repo_cards_html = ""
        for i, r in enumerate(top_results, 1):
            repo_cards_html += self._render_repo_card(r, i)

        html = HTML_TEMPLATE.format(
            generated_at=datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC"),
            total=len(results),
            auto_install=decision_counts["auto_install"],
            recommend=decision_counts["recommend"],
            record=decision_counts["record"],
            drop=decision_counts["drop"],
            top_n=self.top_n,
            repo_cards=repo_cards_html or '<div class="empty">本轮无符合条件的项目</div>',
        )

        html_path = self.output_dir / f"report_{timestamp}.html"
        html_path.write_text(html, encoding="utf-8")

        # 生成JSON
        json_data = {
            "generated_at": datetime.now(timezone.utc).isoformat(),
            "total_candidates": len(results),
            "decision_counts": decision_counts,
            "results": [r.to_dict() for r in sorted_results],
        }
        json_path = self.output_dir / f"report_{timestamp}.json"
        json_path.write_text(
            json.dumps(json_data, ensure_ascii=False, indent=2), encoding="utf-8")

        return {"html": str(html_path), "json": str(json_path)}

    def _render_repo_card(self, result: EvaluationResult, rank: int) -> str:
        repo = result.repo
        rank_class = "top" if rank <= 3 else ""
        score_class = ("high" if result.total_score >= 85
                       else "mid" if result.total_score >= 70 else "low")
        # 维度条（5个维度，每个满分20）
        dim_bars = ""
        for d in result.dimensions:
            filled = "on" if d.score >= 60 else ""
            dim_bars += f'<span class="{filled}" title="{d.name}: {d.score}"></span>'
        # HTML转义描述
        desc = (repo.description or "无描述")[:100]
        desc = desc.replace("<", "&lt;").replace(">", "&gt;")
        return REPO_CARD_TEMPLATE.format(
            rank=rank, rank_class=rank_class,
            url=repo.url, name=repo.full_name,
            desc=desc,
            stars=repo.stars, forks=repo.forks, watchers=repo.watchers,
            language=repo.language or "N/A",
            license=repo.license or "无",
            dim_bars=dim_bars,
            score=f"{result.total_score:.1f}",
            score_class=score_class,
            decision=result.decision,
            decision_label=DECISION_LABELS.get(result.decision, result.decision),
        )