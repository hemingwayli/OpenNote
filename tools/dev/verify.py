"""按影响范围验证；默认轻量组件检查，不启动应用、构建或运行全量截图。"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import sys
import time

from flutter_dev import FLUTTER, ROOT, run


# 显式选择实际改动范围；当前仓库尚无 Git 提交基线，不能把全部未跟踪文件当成本轮改动。
SCOPES = {
    "quick": ["test/dev/component_previews_test.dart"],
    "home": ["test/ui/project_home_test.dart"],
    "map": ["test/ui/map_pane_test.dart", "test/ui/map_outline_pane_test.dart",
            "test/ui/map_editing_test.dart", "test/ui/map_outline_editing_test.dart",
            "test/ui/map_marquee_test.dart", "test/ui/map_structure_test.dart",
            "test/domain/map_layout_test.dart", "test/domain/relationship_test.dart",
            "test/ui/relationship_editing_test.dart", "test/domain/boundary_test.dart",
            "test/ui/boundary_editing_test.dart", "test/domain/summary_test.dart",
            "test/ui/summary_editing_test.dart", "test/domain/topic_style_test.dart",
            "test/ui/topic_style_editing_test.dart", "test/domain/mixed_structure_test.dart",
            "test/ui/mixed_structure_editing_test.dart", "test/domain/extended_structure_test.dart",
            "test/ui/extended_structure_editing_test.dart"],
    "reader": ["test/pdf/reader_pane_test.dart", "test/pdf/reader_interaction_test.dart"],
    "pdf": ["test/pdf"],
    "epub": ["test/epub"],
    "data": ["test/data"],
    "controller": ["test/application"],
    "workspace": ["test/workspace/workbench_test.dart"],
    "ocr": ["test/ocr"],
    "tools": [],
    "full": ["test"],
}


def commands(scope: str, tests: list[str], name: str | None,
             skip_analyze: bool, report_dir: Path) -> list[list[str]]:
    if scope not in SCOPES:
        raise ValueError(f"未知验证范围：{scope}")
    if scope in ("full", "tools") and (tests or name):
        raise ValueError("full/tools 不接受用例过滤；请选择其他范围或直接指定 --test。")
    if name is not None and not name.strip():
        raise ValueError("--plain-name 不能为空。")
    selected = tests or SCOPES[scope]
    for relative in selected:
        path = (ROOT / relative).resolve()
        if not path.is_relative_to((ROOT / "test").resolve()) or not path.exists():
            raise ValueError(f"测试路径必须存在且位于项目 test 内：{relative}")
        if path.is_file() and not path.name.endswith("_test.dart"):
            raise ValueError(f"Flutter 用例应为 *_test.dart：{relative}")
    result = []
    if not skip_analyze and scope != "tools":
        result.append(FLUTTER + ["analyze", "--no-pub"])
    if scope != "tools":
        command = FLUTTER + [
            "test", "--no-pub", "--concurrency=1", "--reporter=expanded",
            f"--file-reporter=json:{(report_dir / 'tests.jsonl').as_posix()}",
            *selected,
        ]
        if name is not None:
            command += ["--plain-name", name]
        result.append(command)
    if scope in ("tools", "full"):
        result.append([sys.executable, "-X", "utf8", "-m", "unittest", "discover",
                       "-s", "test/tools", "-p", "*_test.py"])
    return result


def main(arguments: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scope", choices=SCOPES, default="quick")
    parser.add_argument("--test", action="append", default=[], help="指定测试文件／目录，可重复；替代 scope 的测试列表")
    parser.add_argument("--plain-name", help="按测试名称字面子串筛选，未匹配时 Flutter 返回失败")
    parser.add_argument("--skip-analyze", action="store_true", help="本轮源码未再变更且已分析通过时使用")
    parser.add_argument("--dry-run", action="store_true", help="只显示范围与命令，不执行、不写报告")
    options = parser.parse_args(arguments)
    started = datetime.now(timezone.utc)
    report_dir = ROOT / ".local/verification" / started.strftime("%Y%m%dT%H%M%S%fZ")
    plan = commands(options.scope, options.test, options.plain_name, options.skip_analyze, report_dir)
    print(f"验证范围：{options.scope}；测试：{options.test or SCOPES[options.scope] or ['Python 开发工具']}。", flush=True)
    print("不自动启动 MCP、Profile 或 Release 构建；局部通过不代表全量验收。", flush=True)
    if options.dry_run:
        print(json.dumps(plan, ensure_ascii=False, indent=2))
        return 0
    report_dir.mkdir(parents=True)
    report = {"startedAt": started.isoformat(), "scope": options.scope,
              "tests": options.test or SCOPES[options.scope], "plainName": options.plain_name,
              "analysisSkipped": options.skip_analyze, "steps": [], "passed": False}
    start_time = time.monotonic()
    exit_code = 1
    try:
        for command in plan:
            step_start = time.monotonic()
            code = run(command)
            report["steps"].append({"command": command, "exitCode": code,
                                    "seconds": round(time.monotonic() - step_start, 2)})
            if code != 0:
                exit_code = code
                break
        else:
            exit_code = 0
            report["passed"] = True
        return exit_code
    except (OSError, KeyboardInterrupt) as error:
        report["error"] = f"{type(error).__name__}: {error}"
        raise
    finally:
        report["seconds"] = round(time.monotonic() - start_time, 2)
        (report_dir / "report.json").write_text(
            json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(f"本次耗时 {report['seconds']} 秒；报告：{report_dir / 'report.json'}", flush=True)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print(f"验证失败：{error}", file=sys.stderr)
        raise SystemExit(1)
