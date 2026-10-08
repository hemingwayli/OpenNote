"""验证范围不能悄悄扩大、漏跑或把失败报告为成功。"""

import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools/dev"))
import flutter_dev
import verify


class VerifyTest(unittest.TestCase):
    def test_default_is_lightweight_and_full_is_explicit(self):
        quick = verify.commands("quick", [], None, False, Path("report"))
        self.assertEqual(len(quick), 2)
        self.assertEqual(quick[0][-2:], ["analyze", "--no-pub"])
        self.assertEqual(quick[1][-1], "test/dev/component_previews_test.dart")
        full = verify.commands("full", [], None, False, Path("report"))
        self.assertEqual(len(full), 3)
        self.assertEqual(full[1][-1], "test")
        self.assertIn("unittest", full[2])

    def test_explicit_file_replaces_scope_and_name_stays_literal(self):
        commands = verify.commands("home", ["test/ui/map_pane_test.dart"], "中文 [状态]", True, Path("report"))
        self.assertEqual(len(commands), 1)
        self.assertNotIn("test/ui/project_home_test.dart", commands[0])
        self.assertEqual(commands[0][-3:], ["test/ui/map_pane_test.dart", "--plain-name", "中文 [状态]"])

    def test_invalid_or_misleading_selection_is_rejected(self):
        for scope, tests, name in [
            ("full", [], "部分"), ("tools", ["test/ui/map_pane_test.dart"], None),
            ("quick", ["README.md"], None), ("quick", ["test/missing_test.dart"], None),
            ("quick", [], ""),
        ]:
            with self.subTest(scope=scope, tests=tests, name=name), self.assertRaises(ValueError):
                verify.commands(scope, tests, name, False, Path("report"))

    def test_dry_run_starts_no_process_and_writes_no_report(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(verify, "ROOT", Path(folder)), \
                patch.object(verify, "run") as run, contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(verify.main(["--scope", "tools", "--dry-run"]), 0)
            run.assert_not_called()
            self.assertEqual(list(Path(folder).iterdir()), [])

    def test_failure_stops_before_tests_and_is_recorded(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "test/dev").mkdir(parents=True)
            (root / "test/dev/component_previews_test.dart").touch()
            with patch.object(verify, "ROOT", root), patch.object(verify, "run", return_value=7) as run, \
                    contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(verify.main([]), 7)
                self.assertEqual(run.call_count, 1)
            report = json.loads(next(root.glob(".local/verification/*/report.json")).read_text(encoding="utf-8"))
            self.assertFalse(report["passed"])
            self.assertEqual(report["steps"][0]["exitCode"], 7)

    def test_golden_default_matches_one_profile_without_dpi_suffix(self):
        with patch.object(sys, "argv", ["flutter_dev.py", "golden"]), patch.object(flutter_dev, "run", return_value=0) as run:
            self.assertEqual(flutter_dev.main(), 0)
            self.assertEqual(run.call_args.args[0][-2:], ["--name", " · 1920x1080$"])
        with patch.object(sys, "argv", ["flutter_dev.py", "golden", "--golden-profile", "all"]), \
                patch.object(flutter_dev, "run", return_value=0) as run:
            self.assertEqual(flutter_dev.main(), 0)
            self.assertNotIn("--name", run.call_args.args[0])


if __name__ == "__main__":
    unittest.main()
