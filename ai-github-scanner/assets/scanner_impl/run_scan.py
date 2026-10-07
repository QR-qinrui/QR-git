"""
run_scan.py - AI GitHub Skill Scanner 主入口

用法：
  python run_scan.py                # 全领域扫描+评估+安装+报告
  python run_scan.py --domain mcp_skill_plugin   # 指定领域
  python run_scan.py --dry-run      # 仅扫描评估，不自动安装

数据流：
  config.yaml → GitHubClient.scan_domains → Evaluator.evaluate_batch
              → Installer.install (auto_install决策) → ReportGenerator.generate
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import yaml

from scanner.github_client import GitHubClient
from scanner.evaluator import Evaluator
from scanner.installer import Installer
from scanner.report import ReportGenerator


def load_config(path: str = "config.yaml") -> dict:
    cfg_path = Path(path)
    if not cfg_path.exists():
        print(f"[ERROR] 配置文件不存在: {path}", file=sys.stderr)
        sys.exit(1)
    with cfg_path.open("r", encoding="utf-8") as f:
        return yaml.safe_load(f)


def load_last_report() -> dict | None:
    """加载上一轮的报告作为0候选兜底"""
    reports_dir = Path("./data/reports")
    if not reports_dir.exists():
        return None
    json_files = sorted(reports_dir.glob("report_*.json"),
                        key=lambda p: p.stat().st_mtime, reverse=True)
    if not json_files:
        return None
    try:
        return json.loads(json_files[0].read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return None


# 兜底用的高质量owner清单（search池耗尽时用core池查这些owner的repos）
FALLBACK_OWNERS = [
    "modelcontextprotocol", "anthropics", "langchain-ai",
    "microsoft", "crewAIInc", "punkpeye",
    "browsermcp", "getcursor",
]


def run_scan(config: dict, domain_filter: str | None = None,
             dry_run: bool = False) -> dict:
    """执行完整扫描-评估-安装-报告流程"""
    print("=" * 72)
    print(f"  AI GitHub Skill Scanner v{config.get('system', {}).get('version', '1.0.0')}")
    print("=" * 72)

    # 阶段1：扫描（含分池fallback）
    print("\n[1/4] 扫描GitHub项目...")
    client = GitHubClient(config)
    domains = config.get("scan_domains", [])
    if domain_filter:
        domains = [d for d in domains if d["name"] == domain_filter]
    candidates = client.scan_domains_with_fallback(domains, FALLBACK_OWNERS)
    print(f"  发现候选项目: {len(candidates)} 个")

    if not candidates:
        # 0候选兜底：复用上一轮报告，避免日报告断档
        print("  [INFO] 本轮0候选，复用上一轮报告作为兜底...")
        last = load_last_report()
        if last:
            print(f"  [FALLBACK] 已加载上一轮报告: "
                  f"{last.get('generated_at', 'unknown')}, "
                  f"含 {last.get('total_candidates', 0)} 个项目")
            return {
                "candidates": 0,
                "fallback_used": True,
                "fallback_report": last,
                "results": last.get("results", []),
            }
        print("  [WARN] 无上一轮报告可复用，结束本轮扫描")
        return {"candidates": 0, "fallback_used": False, "results": []}

    # 阶段2：评估
    print("\n[2/4] 评估项目质量...")
    evaluator = Evaluator(config, client)
    results = evaluator.evaluate_batch(candidates)
    # 决策分布
    decisions = {"auto_install": 0, "recommend": 0, "record": 0, "drop": 0}
    for r in results:
        decisions[r.decision] = decisions.get(r.decision, 0) + 1
    print(f"  评估完成: 自动安装 {decisions['auto_install']} | "
          f"推荐 {decisions['recommend']} | 记录 {decisions['record']} | "
          f"丢弃 {decisions['drop']}")
    # 数据完备性提示（v1.2.1：缺失项不按0分计；核心证据缺失时禁止自动安装）
    incomplete = [r for r in results if r.missing_data]
    if incomplete:
        missing_kinds: dict[str, int] = {}
        for r in incomplete:
            for m in r.missing_data:
                missing_kinds[m] = missing_kinds.get(m, 0) + 1
        kinds_str = ", ".join(f"{k}×{v}" for k, v in
                              sorted(missing_kinds.items(), key=lambda x: -x[1]))
        print(f"  [WARN] {len(incomplete)}/{len(results)} 个项目存在数据缺失"
              f"（{kinds_str}）；缺失项不按0分计，缺失时自动安装已降级")

    # 阶段3：自动安装（非dry-run）
    installed: list[dict] = []
    if not dry_run:
        print("\n[3/4] 执行自动安装（≥85分项目）...")
        installer = Installer(config)
        for r in results:
            if r.decision == "auto_install":
                files = {"README.md": client.get_readme_content(
                    r.repo.owner, r.repo.name) or ""}
                rec = installer.install(r.repo, files)
                installed.append(rec)
                status_icon = "✓" if rec["status"] == "installed" else "✗"
                print(f"  {status_icon} {r.repo.full_name} → {rec['status']}")
    else:
        print("\n[3/4] dry-run模式，跳过安装")

    # 阶段4：生成报告
    print("\n[4/4] 生成评估报告...")
    reporter = ReportGenerator(config)
    paths = reporter.generate(results)
    print(f"  HTML: {paths['html']}")
    print(f"  JSON: {paths['json']}")

    # 持久化评估结果
    eval_path = Path("./data/evaluated")
    eval_path.mkdir(parents=True, exist_ok=True)
    from datetime import datetime, timezone
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%d_%H-%M-%S")
    eval_file = eval_path / f"eval_{ts}.json"
    eval_file.write_text(
        json.dumps([r.to_dict() for r in results],
                   ensure_ascii=False, indent=2), encoding="utf-8")

    print("\n" + "=" * 72)
    print("  扫描完成")
    print("=" * 72)

    return {
        "candidates": len(candidates),
        "decisions": decisions,
        "installed": installed,
        "report_paths": paths,
        "results": [r.to_dict() for r in results],
    }


def main():
    parser = argparse.ArgumentParser(
        description="AI GitHub Skill Scanner")
    parser.add_argument("--config", default="config.yaml", help="配置文件路径")
    parser.add_argument("--domain", default=None,
                        help="指定扫描领域（不指定则全领域）")
    parser.add_argument("--dry-run", action="store_true",
                        help="仅扫描评估，不自动安装")
    args = parser.parse_args()

    config = load_config(args.config)
    run_scan(config, domain_filter=args.domain, dry_run=args.dry_run)


if __name__ == "__main__":
    main()