"""OpenNote 的固定 Flutter 工具入口；运行程序只使用独立开发资料库。"""

from __future__ import annotations

import argparse
from collections import deque
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
from toolchain import resolve_flutter_sdk

LOCK = json.loads((ROOT / "tools/toolchain-lock.json").read_text(encoding="utf-8"))
SDK = resolve_flutter_sdk(ROOT)
DART = SDK / "bin/cache/dart-sdk/bin/dart.exe"
FLUTTER = [str(DART), str(SDK / "bin/cache/flutter_tools.snapshot")]


def environment() -> dict[str, str]:
    result = os.environ.copy()
    result["FLUTTER_ROOT"] = str(SDK)
    result["CMAKE_BUILD_PARALLEL_LEVEL"] = "1"
    result["PYTHONUTF8"] = "1"
    # 只改变子进程，避免影响其他项目使用的 Flutter 版本。
    result["PATH"] = os.pathsep.join([
        str(SDK / "bin"), str(SDK / "bin/cache/dart-sdk/bin"),
        str(ROOT / "native/build/Release"), result.get("PATH", ""),
    ])
    return result


def run(command: list[str]) -> int:
    print("执行：" + subprocess.list2cmdline(command), flush=True)
    return subprocess.call(command, cwd=ROOT, env=environment())


def run_logged(command: list[str], log_dir: Path) -> tuple[int, str]:
    print("执行：" + subprocess.list2cmdline(command), flush=True)
    recent = deque(maxlen=200)
    with (log_dir / "preview.log").open("a", encoding="utf-8") as log:
        process = subprocess.Popen(
            command, cwd=ROOT, env=environment(), stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, text=True, encoding="utf-8", errors="replace",
        )
        for line in process.stdout:
            print(line, end="", flush=True)
            log.write(line)
            log.flush()
            recent.append(line)
        return process.wait(), "".join(recent)


def run_preview() -> int:
    log_dir = ROOT / ".local/flutter-dev"
    log_dir.mkdir(parents=True, exist_ok=True)
    scaffold = ROOT / ".widget_preview"
    for attempt, delay in enumerate((0, 0, 2, 5, 10), start=1):
        if delay:
            time.sleep(delay)
        # 首次离线 pub add 中断会保留只含宿主的脚手架。只失效生成
        # 清单中的 pubspec 哈希，让官方工具完整重建自己的依赖。
        package_config = scaffold / ".dart_tool/package_config.json"
        preview_manifest = scaffold / "preview_manifest.json"
        if package_config.is_file() and preview_manifest.is_file():
            packages = {item["name"] for item in json.loads(package_config.read_text(encoding="utf-8"))["packages"]}
            required = {"dtd", "google_fonts", "json_rpc_2", "webview_flutter", "webview_flutter_web"}
            if not required.issubset(packages):
                manifest = json.loads(preview_manifest.read_text(encoding="utf-8"))
                manifest["pubspec-hashes"] = {}
                pending = preview_manifest.with_suffix(".pending.json")
                pending.write_text(json.dumps(manifest) + "\n", encoding="utf-8")
                pending.replace(preview_manifest)
                print("预览依赖不完整；已请求官方工具重新生成脚手架依赖。", flush=True)
        command = FLUTTER + ["widget-preview", "start", "--web-server"]
        if attempt == 1:
            command.append("--offline")
        result, output = run_logged(command, log_dir)
        if result == 0:
            return 0
        with (log_dir / "preview-failures.jsonl").open("a", encoding="utf-8") as log:
            log.write(json.dumps({
                "time": datetime.now(timezone.utc).isoformat(), "attempt": attempt,
                "offline": attempt == 1, "exitCode": result, "output": output,
            }, ensure_ascii=False) + "\n")
        retryable = any(value in output.lower() for value in (
            "could not find package", "socketexception", "connection reset", "connection refused", "timed out",
            "timeout", "handshakeexception", "429", "502", "503", "504",
        ))
        if not retryable or attempt == 5:
            return result
        print("预览准备失败已记录；重新尝试取得官方依赖。", flush=True)
    return 1


def install_extensions() -> int:
    code = shutil.which("code.cmd") or shutil.which("code")
    if not code:
        raise FileNotFoundError("没有找到 VS Code 的 code.cmd。")
    log_path = ROOT / ".local/flutter-dev/extension-install.jsonl"
    log_path.parent.mkdir(parents=True, exist_ok=True)
    for extension in ("Dart-Code.dart-code", "Dart-Code.flutter"):
        for attempt, delay in enumerate((0, 2, 5, 10), start=1):
            if delay:
                time.sleep(delay)
            command = [code, "--install-extension", extension]
            try:
                result = subprocess.run(
                    command, cwd=ROOT, env=environment(), text=True,
                    encoding="utf-8", errors="replace", capture_output=True, timeout=180,
                )
                output = result.stdout + result.stderr
                code_result = result.returncode
            except (OSError, subprocess.TimeoutExpired) as error:
                output = f"{type(error).__name__}: {error}"
                code_result = -1
            print(output, flush=True)
            with log_path.open("a", encoding="utf-8") as stream:
                stream.write(json.dumps({
                    "time": datetime.now(timezone.utc).isoformat(),
                    "extension": extension, "attempt": attempt,
                    "exitCode": code_result, "output": output,
                }, ensure_ascii=False) + "\n")
            if code_result == 0:
                break
            # 参数、版本及权限错误不是网络故障，保留原因并停止。
            if any(text in output.lower() for text in (
                "not compatible", "not found", "permission denied", "unknown option",
            )) or attempt == 4:
                return code_result or 1
    return run([code, "--list-extensions", "--show-versions"])


def update_golden_assets() -> None:
    """按基线环境清单登记全部自产 UI 截图，状态与尺寸保持一致。"""
    manifest_path = ROOT / "packaging/source-assets.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    baseline = json.loads((ROOT / "test/goldens/baseline-environment.json").read_text(encoding="utf-8"))
    expected = [
        f"test/goldens/baselines/{state}-{profile['label']}.png"
        for state in baseline["states"]
        for profile in baseline["profiles"]
    ]
    existing = {item["path"]: item for item in manifest["files"]}
    for relative in expected:
        if relative in existing and existing[relative]["origin"] != "generated":
            raise ValueError(f"拒绝替换非自产资产声明：{relative}")
        asset = ROOT / relative
        data = asset.read_bytes()
        existing[relative] = {
            "path": relative, "size": len(data), "sha256": hashlib.sha256(data).hexdigest(),
            "origin": "generated", "license": "Apache-2.0",
            "sourceStatement": "正式 OpenNote 工作台与项目自产 PDF 样例生成的 UI 截图回归基线；不含用户资料或外部书页，不分发字体文件。",
            "sourceReferences": [
                "test/goldens/workbench_golden_test.dart",
                "test/goldens/baseline-environment.json",
            ],
            "derivedFrom": [baseline["pdfPath"]],
        }
    manifest["files"] = list(existing.values())
    pending = manifest_path.with_suffix(".pending.json")
    pending.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    pending.replace(manifest_path)
    print(f"{len(expected)} 张自产 Golden 基线已登记到源码资产清单。", flush=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=(
        "run", "profile", "preview", "devtools", "analyze", "golden",
        "update-goldens", "doctor", "setup-ide", "mcp-check", "check",
    ))
    parser.add_argument("--data-dir", type=Path)
    parser.add_argument("--vm-service-uri")
    parser.add_argument("--scope", default="quick")
    parser.add_argument("--test", action="append", default=[])
    parser.add_argument("--plain-name")
    parser.add_argument("--skip-analyze", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--golden-profile", choices=("1920x1080", "1280x720", "1920x1080-at150", "all"), default="1920x1080")
    options = parser.parse_args()
    if options.action == "check":
        from verify import main as verify_main
        arguments = ["--scope", options.scope]
        for path in options.test:
            arguments += ["--test", path]
        if options.plain_name is not None:
            arguments += ["--plain-name", options.plain_name]
        if options.skip_analyze:
            arguments.append("--skip-analyze")
        if options.dry_run:
            arguments.append("--dry-run")
        return verify_main(arguments)
    if not DART.is_file() or not Path(FLUTTER[1]).is_file():
        raise FileNotFoundError(f"项目锁定的 SDK 不完整：{SDK}")
    if options.action == "setup-ide":
        return install_extensions()
    if options.action == "mcp-check":
        return run([sys.executable, "-X", "utf8", str(ROOT / "tools/dev/check_dart_mcp.py")])
    if options.action == "devtools":
        command = [str(DART), "devtools", "--host=127.0.0.1", "--port=0", "--no-launch-browser"]
        if options.vm_service_uri:
            command.append(options.vm_service_uri)
        return run(command)
    if options.action in ("run", "profile"):
        default_data = Path(os.environ["LOCALAPPDATA"]) / "OpenNote-Development" / options.action
        data_dir = (options.data_dir or default_data).resolve()
        if data_dir == (Path(os.environ["LOCALAPPDATA"]) / "OpenNote").resolve():
            raise ValueError("开发入口不能使用正式 OpenNote 资料库。")
        print(f"独立开发资料库：{data_dir}", flush=True)
        command = FLUTTER + [
            "run", "-d", "windows", "--no-pub", "--print-dtd",
            "--debug" if options.action == "run" else "--profile",
            f"--dart-entrypoint-args=--data-dir={data_dir}",
        ]
        if options.action == "run":
            command.append("--track-widget-creation")
        return run(command)
    if options.action == "preview":
        return run_preview()
    if options.action in ("golden", "update-goldens"):
        command = FLUTTER + [
            "test", "--no-pub", "--concurrency=1", "--reporter=expanded",
            "test/goldens/workbench_golden_test.dart",
        ]
        if options.golden_profile != "all":
            # 使用完整名称边界，避免 1920x1080 误匹配 1920x1080-at150。
            command += ["--name", f" · {options.golden_profile}$"]
        if options.action == "update-goldens":
            command.append("--update-goldens")
        result = run(command)
        if result == 0 and options.action == "update-goldens":
            update_golden_assets()
        return result
    if options.action == "analyze":
        return run(FLUTTER + ["analyze", "--no-pub"])
    return run(FLUTTER + ["doctor", "--verbose"])


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print(f"开发工具失败：{error}", file=sys.stderr)
        raise SystemExit(1)
