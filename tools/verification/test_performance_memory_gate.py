"""用实测报告裁剪夹具验证退出策略；后续副本变异不代表性能实测，不启动应用。"""

from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest

import run_performance


FIXTURE_DIRECTORY = Path(__file__).resolve().parent / "fixtures"
REPORT_PATHS: tuple[Path, Path] = (
    FIXTURE_DIRECTORY / "performance-006.json",
    FIXTURE_DIRECTORY / "performance-005.json",
)


class PerformanceMemoryGateTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.original_bytes = {path: path.read_bytes() for path in REPORT_PATHS}
        cls.over_limit, cls.within_limit = (
            json.loads(cls.original_bytes[path].decode("utf-8")) for path in REPORT_PATHS
        )

    @classmethod
    def tearDownClass(cls) -> None:
        for path, original in cls.original_bytes.items():
            if path.read_bytes() != original:
                raise AssertionError(f"不得修改原始性能报告：{path}")

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="opennote-memory-gate-")
        self.addCleanup(self.temp.cleanup)

    def _policy_report(self, report: dict, name: str, require_group: bool) -> dict:
        # 只在独立临时副本中调用正式策略，不复制或重写退出条件。
        path = Path(self.temp.name) / name
        path.write_text(json.dumps(report, ensure_ascii=False) + "\n", encoding="utf-8")
        result = json.loads(path.read_text(encoding="utf-8"))
        memory_failures = run_performance.memory_acceptance_failures(
            result["application"], result["memory"]
        )
        result["memoryAcceptance"] = {
            "passed": not memory_failures,
            "failures": memory_failures,
        }
        if require_group:
            failures = run_performance.group_acceptance_failures(result["application"])
            result["groupAcceptance"] = {
                "required": True,
                "passed": not failures,
                "failures": failures,
            }
        path.write_text(json.dumps(result, ensure_ascii=False) + "\n", encoding="utf-8")
        return json.loads(path.read_text(encoding="utf-8"))

    def test_actual_006_over_limit_is_rejected_even_when_ordinary_graph_passes(self) -> None:
        report = copy.deepcopy(self.over_limit)
        self.assertIs(report["application"]["success"], True)
        self.assertIs(report["memory"]["completeCapacityWorkloadMeasured"], True)
        self.assertEqual(report["memory"]["peakCommitBytes"], 2_810_568_704)
        # 仅为隔离门禁的策略夹具：不把此修改当作真实ordinary帧达标。
        report["application"]["graph"]["p95TotalSpanMs"] = 33.0
        result = self._policy_report(report, "006-ordinary-pass-memory-fail.json", True)
        self.assertIs(result["groupAcceptance"]["passed"], True)
        self.assertIs(result["memoryAcceptance"]["passed"], False)
        self.assertTrue(any("peakCommitBytes" in failure for failure in result["memoryAcceptance"]["failures"]))
        self.assertEqual(run_performance.performance_exit_code(result, True), 1)
        self.assertEqual(run_performance.performance_exit_code(result, False), 1)

    def test_actual_005_memory_passes_without_hiding_failed_group(self) -> None:
        result = self._policy_report(self.within_limit, "005-memory-pass-group-fail.json", True)
        self.assertIs(result["memoryAcceptance"]["passed"], True)
        self.assertEqual(result["memoryAcceptance"]["failures"], [])
        self.assertIs(result["groupAcceptance"]["passed"], False)
        self.assertEqual(run_performance.performance_exit_code(result, True), 1)

    def test_capacity_flags_cannot_replace_actual_counts(self) -> None:
        for field in ("actualPdfPages", "persistedNativeTextPages", "actualCards", "graphNodes"):
            with self.subTest(field=field):
                report = copy.deepcopy(self.within_limit)
                report["memory"]["within2GiB"] = True
                report["memory"]["completeCapacityWorkloadMeasured"] = True
                report["application"]["dataset"][field] -= 1
                result = self._policy_report(report, f"missing-{field}.json", False)
                self.assertIs(result["memoryAcceptance"]["passed"], False)
                self.assertTrue(any(f"dataset.{field}" in failure for failure in result["memoryAcceptance"]["failures"]))
                self.assertEqual(run_performance.performance_exit_code(result, False), 1)

    def test_samples_and_complete_measurement_cannot_be_missing(self) -> None:
        for field, value in (("samples", 0), ("samples", True), ("peakCommitBytes", None), ("completeCapacityWorkloadMeasured", False)):
            with self.subTest(field=field, value=value):
                report = copy.deepcopy(self.within_limit)
                report["memory"][field] = value
                report["memory"]["within2GiB"] = True
                result = self._policy_report(report, "missing-measurement.json", False)
                self.assertIs(result["memoryAcceptance"]["passed"], False)
                self.assertTrue(any(f"memory.{field}" in failure for failure in result["memoryAcceptance"]["failures"]))
                self.assertEqual(run_performance.performance_exit_code(result, False), 1)

    def test_original_2gib_byte_boundary_and_forged_within_flag(self) -> None:
        for field in ("peakWorkingSetBytes", "peakCommitBytes"):
            with self.subTest(field=field):
                report = copy.deepcopy(self.within_limit)
                report["memory"][field] = 2_147_483_648
                report["memory"]["within2GiB"] = True
                exact = self._policy_report(report, f"exact-{field}.json", False)
                self.assertIs(exact["memoryAcceptance"]["passed"], True)
                self.assertEqual(run_performance.performance_exit_code(exact, False), 0)
                report["memory"][field] = 2_147_483_649
                exceeded = self._policy_report(report, f"exceeded-{field}.json", False)
                self.assertIs(exceeded["memoryAcceptance"]["passed"], False)
                self.assertEqual(run_performance.performance_exit_code(exceeded, False), 1)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--over-limit-report", type=Path, default=REPORT_PATHS[0], help="默认使用随源码保存的006实测裁剪夹具，也可传入完整原始报告")
    parser.add_argument("--within-limit-report", type=Path, default=REPORT_PATHS[1], help="默认使用随源码保存的005实测裁剪夹具，也可传入完整原始报告")
    arguments, unittest_arguments = parser.parse_known_args()
    REPORT_PATHS = (
        arguments.over_limit_report.resolve(strict=True),
        arguments.within_limit_report.resolve(strict=True),
    )
    unittest.main(argv=[sys.argv[0], *unittest_arguments], verbosity=2)
