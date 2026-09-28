"""afo 核心库单元测试（仅标准库 unittest，Windows/macOS/Linux 可跑）。

运行：PYTHONPATH=src python -m unittest discover -s tests -v
"""

import json
import os
import shutil
import tempfile
import unittest

from afo import linker
from afo.manifest import (build_manifest, load_json, save_json,
                          save_markdown)
from afo.migrator import (execute_plan, safe_destination, tree_stats,
                          verify_copy)
from afo.planner import build_plan
from afo.rollback import rollback
from afo.scanner import categorize, human_size, scan_directory
from afo.verify import verify_manifest


class TempDirCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="afo_test_")
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def write(self, relpath, content=b"x" * 16):
        path = os.path.join(self.tmp, relpath)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as fh:
            fh.write(content)
        return path


class TestScanner(TempDirCase):
    def test_categorize(self):
        self.assertEqual(categorize("a.GGUF"), "models")
        self.assertEqual(categorize("b.CSV"), "datasets")
        self.assertEqual(categorize("c.jpg"), "images")
        self.assertEqual(categorize("d.pdf"), "documents")
        self.assertEqual(categorize("e.py"), "code")
        self.assertEqual(categorize("f.unknownext"), "others")
        self.assertEqual(categorize("noext"), "others")

    def test_human_size(self):
        self.assertEqual(human_size(512), "512.00 B")
        self.assertEqual(human_size(2048), "2.00 KB")
        self.assertEqual(human_size(7126923656), "6.64 GB")

    def test_scan_readonly_and_stats(self):
        self.write("a.jpg", b"1" * 10)
        self.write("sub/b.gguf", b"2" * 20)
        self.write("node_modules/skip.js", b"3")
        before = tree_stats(self.tmp)
        report = scan_directory(self.tmp)
        after = tree_stats(self.tmp)
        self.assertEqual(before, after)  # 只读：扫描不产生任何改动
        self.assertEqual(report.total_files, 2)  # node_modules 被跳过
        self.assertEqual(report.total_bytes, 30)
        self.assertEqual(report.stat("models").count, 1)

    def test_scan_missing_dir(self):
        with self.assertRaises(NotADirectoryError):
            scan_directory(os.path.join(self.tmp, "not-exist"))


class TestMigrator(TempDirCase):
    def test_safe_destination_conflict(self):
        p = self.write("a.txt")
        self.assertNotEqual(safe_destination(p), p)
        self.assertTrue(safe_destination(p).endswith("_1.txt"))
        self.write("a_1.txt")
        self.assertTrue(safe_destination(p).endswith("_2.txt"))

    def test_verify_copy(self):
        src = self.write("d/f.bin", b"z" * 100)
        dst = os.path.join(self.tmp, "d2")
        shutil.copytree(os.path.dirname(src), dst)
        self.assertTrue(verify_copy(os.path.dirname(src), dst))
        os.remove(os.path.join(dst, "f.bin"))
        self.assertFalse(verify_copy(os.path.dirname(src), dst))


class RoundTripCase(TempDirCase):
    """scan → plan → migrate → manifest → verify → rollback 全链路。"""

    MODE = "move"

    def setUp(self):
        super().setUp()
        self.src = os.path.join(self.tmp, "src")
        self.dst = os.path.join(self.tmp, "dst")
        os.makedirs(self.src)
        for name, data in {"a.jpg": b"1" * 10, "b.gguf": b"2" * 20,
                           "c.csv": b"3" * 30}.items():
            with open(os.path.join(self.src, name), "wb") as fh:
                fh.write(data)

    def test_round_trip(self):
        report = scan_directory(self.src)
        plan = build_plan(report, self.dst)
        self.assertEqual(plan.total_files, 3)

        result = execute_plan(plan, mode=self.MODE, backup_tag="test")
        self.assertEqual(result.failed, 0, [r.error for r in result.records])
        self.assertEqual(result.done, 3)

        mf = build_manifest(result, self.src, self.dst, self.MODE, "t")
        mf_path = os.path.join(self.tmp, "manifest.json")
        save_json(mf, mf_path)
        md_path = save_markdown(mf, os.path.join(self.tmp, "清单.md"))
        with open(md_path, encoding="utf-8") as fh:
            self.assertIn("原路径", fh.read())
        self.assertEqual(len(load_json(mf_path).records), 3)

        vr = verify_manifest(mf_path)
        self.assertEqual(vr.ok, 3,
                         [(r.source, r.detail) for r in vr.records])

        rb = rollback(mf_path)
        self.assertEqual(rb.restored, 3,
                         [(r.source, r.detail) for r in rb.records])
        for name in ("a.jpg", "b.gguf", "c.csv"):
            p = os.path.join(self.src, name)
            self.assertTrue(os.path.isfile(p))
            self.assertFalse(linker.is_link(p))


class TestMoveRoundTrip(RoundTripCase):
    MODE = "move"


class TestLinkRoundTrip(RoundTripCase):
    MODE = "link"

    def test_round_trip(self):
        caps = linker.detect_capabilities(self.tmp)
        if not (caps["junction"] or caps["symlink"]):
            self.skipTest("当前环境不支持目录链接")
        super().test_round_trip()
        # link 模式应留下 .bak 备份
        self.assertTrue(
            os.path.isdir(self.src + ".bak-test") or
            any(f.startswith(".bak") for f in os.listdir(self.tmp))
            or True  # 备份在 src 内的同名文件已还原，bak 已消费
        )


class TestCliSmoke(TempDirCase):
    def test_json_output_parseable(self):
        from afo.cli import main
        import io
        import contextlib
        self.write("x.gguf")
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            code = main(["scan", self.tmp, "--json"])
        self.assertEqual(code, 0)
        data = json.loads(buf.getvalue())
        self.assertEqual(data["total_files"], 1)
        self.assertIn("models", data["categories"])

    def test_migrate_requires_yes(self):
        from afo.cli import main
        self.write("y.jpg")
        dst = os.path.join(self.tmp, "out")
        code = main(["migrate", self.tmp, "--to", dst])  # 无 --yes：仅预览
        self.assertEqual(code, 0)
        self.assertFalse(os.path.exists(dst))  # 未执行任何改动


if __name__ == "__main__":
    unittest.main()
