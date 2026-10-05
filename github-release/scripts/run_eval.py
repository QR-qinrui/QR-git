#!/usr/bin/env python
"""
scripts/run_eval.py - 独立评分脚本

对一组项目（从stdin或参数传入）执行评分，输出JSON。
不依赖完整scanner项目，可独立调用。

用法：
  python run_eval.py --repo "owner/repo" --stars 1000 --forks 100 ...
  echo '{"repos":[...]}' | python run_eval.py --stdin
"""
from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass, asdict
from pathlib import Path


@dataclass
class EvalInput:
    full_name: str
    stars: int
    forks: int
    watchers: int = 0
    open_issues: int = 0
    license: str | None = None
    pushed_at: str = ""
    archived: bool = False


def score(input_data: EvalInput) -> dict:
    """简化版评分（无API调用，仅基于输入字段）"""
    # code_quality简化：stars + license + forks比
    star_score = min(100, (input_data.stars / 1000) * 30 + 10)
    fork_ratio = (input_data.forks / max(1, input_data.stars))
    ratio_score = 100 if 0.05 <= fork_ratio <= 0.5 else (60 if fork_ratio > 0.5 else 30)
    lic_score = 100 if input_data.license else 0
    code_quality = star_score * 0.4 + ratio_score * 0.3 + lic_score * 0.3

    # activity简化：用pushed_at
    from datetime import datetime, timezone
    push_score = 50
    if input_data.pushed_at:
        try:
            pushed = datetime.fromisoformat(
                input_data.pushed_at.replace("Z", "+00:00"))
            days = (datetime.now(timezone.utc) - pushed).days
            push_score = min(100, max(10, 100 - days // 3))
        except Exception:
            pass
    activity = push_score

    # safety：扣分制
    safety = 100
    if not input_data.license:
        safety -= 30
    if input_data.archived:
        safety -= 50

    total = (code_quality * 0.25 + activity * 0.25 +
             70 * 0.20 + 70 * 0.20 + safety * 0.10)  # community/practicality默认70
    decision = ("auto_install" if total >= 85
                else "recommend" if total >= 70
                else "record" if total >= 50 else "drop")
    return {
        "input": asdict(input_data),
        "scores": {
            "code_quality": round(code_quality, 2),
            "activity": round(activity, 2),
            "community": 70.0,
            "practicality": 70.0,
            "safety": safety,
        },
        "total": round(total, 2),
        "decision": decision,
    }


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--stdin", action="store_true", help="从stdin读取JSON")
    p.add_argument("--repo", help="owner/repo")
    p.add_argument("--stars", type=int, default=0)
    p.add_argument("--forks", type=int, default=0)
    p.add_argument("--watchers", type=int, default=0)
    p.add_argument("--open-issues", type=int, default=0)
    p.add_argument("--license", default=None)
    p.add_argument("--pushed-at", default="")
    p.add_argument("--archived", action="store_true")
    args = p.parse_args()

    if args.stdin:
        data = json.loads(sys.stdin.read())
        for repo in data.get("repos", []):
            print(json.dumps(score(EvalInput(**repo)),
                             ensure_ascii=False, indent=2))
    else:
        result = score(EvalInput(
            full_name=args.repo or "",
            stars=args.stars,
            forks=args.forks,
            watchers=args.watchers,
            open_issues=args.open_issues,
            license=args.license,
            pushed_at=args.pushed_at,
            archived=args.archived,
        ))
        print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()