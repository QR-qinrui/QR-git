"""命令行入口：scan / plan / migrate / verify / rollback / selfcheck。

全局约定：
- --json 输出机读 JSON（供 dsh 插件等程序调用），默认输出人类可读文本；
- migrate 无 --yes 时只打印方案并退出（模式 P1 确认门），
  显式 --yes 才实际执行；
- 所有写操作错误以非零退出码结束，信息写 stderr。
"""

from __future__ import annotations

import argparse
import datetime
import json
import sys

from . import __version__
from .manifest import build_manifest, save_json, save_markdown
from .migrator import execute_plan
from .planner import build_plan, format_plan_text
from .rollback import rollback
from .scanner import format_report_text, scan_directory
from .selfcheck import run_selfcheck
from .verify import verify_manifest


def _print_json(data: dict) -> None:
    print(json.dumps(data, ensure_ascii=False, indent=2))


def _cmd_scan(args: argparse.Namespace) -> int:
    report = scan_directory(args.directory, recursive=not args.no_recursive)
    if args.json:
        _print_json(report.to_dict())
    else:
        print(format_report_text(report))
    return 0


def _cmd_plan(args: argparse.Namespace) -> int:
    report = scan_directory(args.directory, recursive=not args.no_recursive)
    cats = set(args.categories.split(",")) if args.categories else None
    plan = build_plan(report, args.to, categories=cats)
    if args.json:
        _print_json(plan.to_dict())
    else:
        print(format_plan_text(plan))
    return 0


def _cmd_migrate(args: argparse.Namespace) -> int:
    report = scan_directory(args.directory, recursive=not args.no_recursive)
    cats = set(args.categories.split(",")) if args.categories else None
    plan = build_plan(report, args.to, categories=cats)

    if not args.yes:
        # 确认门：默认只展示方案，不执行
        print(format_plan_text(plan))
        print("\n未执行任何改动。确认无误后追加 --yes 实际迁移。")
        return 0

    stamp = datetime.datetime.now().strftime("%Y%m%d")
    iso_now = datetime.datetime.now().astimezone().isoformat()

    def _progress(done: int, total: int, batch_failed: int) -> None:
        if not args.json:
            print(f"  进度 {done}/{total}（本批失败 {batch_failed}）",
                  file=sys.stderr)

    result = execute_plan(plan, mode=args.mode, backup_tag=stamp,
                          batch_size=args.batch_size, progress=_progress)

    manifest = build_manifest(result, report.root, plan.target_root,
                              args.mode, iso_now)
    out_dir = args.manifest_dir or plan.target_root
    json_path = save_json(manifest, _join(out_dir, "manifest.json"))
    md_path = save_markdown(manifest, _join(out_dir, f"迁移清单_{stamp}.md"))

    summary = {
        "total": len(result.records), "done": result.done,
        "failed": result.failed,
        "manifest_json": json_path, "manifest_md": md_path,
        "errors": [{"source": r.source, "error": r.error}
                   for r in result.records if r.status == "error"],
    }
    if args.json:
        _print_json(summary)
    else:
        print(f"\n✅ 迁移完成：成功 {result.done} / 失败 {result.failed} "
              f"/ 共 {len(result.records)}")
        print(f"机读清单：{json_path}")
        print(f"人读清单：{md_path}")
        for err in summary["errors"]:
            print(f"  ❌ {err['source']}: {err['error']}")
    return 1 if result.failed else 0


def _join(directory: str, name: str) -> str:
    import os
    return os.path.join(directory, name)


def _cmd_verify(args: argparse.Namespace) -> int:
    result = verify_manifest(args.manifest)
    if args.json:
        _print_json({
            "ok": result.ok, "total": len(result.records),
            "records": [r.__dict__ for r in result.records],
        })
    else:
        print(f"复检结果：{result.ok}/{len(result.records)} 项正常")
        for r in result.records:
            if r.status != "ok":
                print(f"  ❌ {r.source}: {r.status} — {r.detail}")
    return 0 if result.ok == len(result.records) else 1


def _cmd_rollback(args: argparse.Namespace) -> int:
    if not args.yes:
        print("回滚将改动文件系统。确认后追加 --yes 执行。")
        return 0
    only = set(args.categories.split(",")) if args.categories else None
    result = rollback(args.manifest, only=only)
    if args.json:
        _print_json({
            "restored": result.restored, "total": len(result.records),
            "records": [r.__dict__ for r in result.records],
        })
    else:
        print(f"回滚结果：还原 {result.restored}/{len(result.records)} 项")
        for r in result.records:
            if r.status == "error":
                print(f"  ❌ {r.source}: {r.detail}")
    return 0 if all(r.status != "error" for r in result.records) else 1


def _cmd_selfcheck(args: argparse.Namespace) -> int:
    report = run_selfcheck(verbose=not args.json)
    if args.json:
        _print_json({
            "ok": report.ok,
            "checks": [c.__dict__ for c in report.checks],
        })
    return 0 if report.ok else 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="afo",
        description="AI 资产文件扫描、归类与安全迁移工具"
                    "（只读扫描 → 方案确认 → 原子迁移 → 可追溯清单 → 可回滚）",
    )
    parser.add_argument("--version", action="version",
                        version=f"afo {__version__}")
    sub = parser.add_subparsers(dest="command", required=True)

    def _common(p: argparse.ArgumentParser) -> None:
        p.add_argument("--json", action="store_true", help="输出机读 JSON")

    p = sub.add_parser("scan", help="只读扫描目录并输出统计报告")
    p.add_argument("directory", help="待扫描目录")
    p.add_argument("--no-recursive", action="store_true",
                   help="只扫描顶层文件，不递归子目录")
    _common(p)
    p.set_defaults(func=_cmd_scan)

    p = sub.add_parser("plan", help="生成分类迁移方案（不改动文件）")
    p.add_argument("directory", help="待整理目录")
    p.add_argument("--to", required=True, help="目标根目录")
    p.add_argument("--categories", help="只迁移指定类别，逗号分隔")
    p.add_argument("--no-recursive", action="store_true")
    _common(p)
    p.set_defaults(func=_cmd_plan)

    p = sub.add_parser("migrate", help="执行迁移（默认仅预览，--yes 才执行）")
    p.add_argument("directory", help="待整理目录")
    p.add_argument("--to", required=True, help="目标根目录")
    p.add_argument("--mode", choices=["copy", "move", "link"], default="move",
                   help="copy=仅复制；move=校验后删原件；"
                        "link=原件留.bak+原位建链接（默认 move）")
    p.add_argument("--categories", help="只迁移指定类别，逗号分隔")
    p.add_argument("--batch-size", type=int, default=10, help="批大小（默认 10）")
    p.add_argument("--manifest-dir", help="清单输出目录（默认目标根目录）")
    p.add_argument("--no-recursive", action="store_true")
    p.add_argument("--yes", action="store_true", help="确认执行（无此项只预览）")
    _common(p)
    p.set_defaults(func=_cmd_migrate)

    p = sub.add_parser("verify", help="按清单复检迁移完整性")
    p.add_argument("manifest", help="manifest.json 路径")
    _common(p)
    p.set_defaults(func=_cmd_verify)

    p = sub.add_parser("rollback", help="按清单回滚（默认仅预览，--yes 才执行）")
    p.add_argument("manifest", help="manifest.json 路径")
    p.add_argument("--categories", help="只回滚指定类别，逗号分隔")
    p.add_argument("--yes", action="store_true", help="确认执行")
    _common(p)
    p.set_defaults(func=_cmd_rollback)

    p = sub.add_parser("selfcheck", help="沙盒全链路自检与环境兼容性报告")
    _common(p)
    p.set_defaults(func=_cmd_selfcheck)

    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except (NotADirectoryError, FileNotFoundError, ValueError) as exc:
        print(f"错误：{exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
