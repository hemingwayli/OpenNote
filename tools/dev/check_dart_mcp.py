"""验证项目配置的官方 Dart MCP，保存握手、工具和实际诊断结果。"""

from __future__ import annotations

import argparse
import base64
from datetime import datetime, timezone
import json
from pathlib import Path
import queue
import subprocess
import threading
import tempfile
import time
import tomllib

from flutter_dev import ROOT, environment


class McpClient:
    def __init__(self, stderr_path: Path):
        configuration = tomllib.loads((ROOT / ".codex/config.toml").read_text(encoding="utf-8"))
        server = configuration["mcp_servers"]["dart-flutter"]
        child_environment = environment()
        child_environment.update(server.get("env", {}))
        self.stderr = stderr_path.open("w", encoding="utf-8")
        self.process = subprocess.Popen(
            [server["command"], *server["args"]], cwd=server["cwd"], env=child_environment,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.stderr,
            text=True, encoding="utf-8", creationflags=subprocess.CREATE_NO_WINDOW,
        )
        self.messages: queue.Queue = queue.Queue()
        self.next_id = 0
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.process.stdout:
            try:
                self.messages.put(json.loads(line))
            except json.JSONDecodeError:
                self.messages.put({"invalidProtocolLine": line.strip()})
        self.messages.put({"processEnded": self.process.poll()})

    def send(self, message: dict):
        self.process.stdin.write(json.dumps(message) + "\n")
        self.process.stdin.flush()

    def request(self, method: str, params: dict | None = None, timeout: int = 180):
        self.next_id += 1
        request_id = self.next_id
        self.send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params or {}})
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                message = self.messages.get(timeout=max(0.1, deadline - time.monotonic()))
            except queue.Empty as error:
                name = (params or {}).get("name", method)
                raise TimeoutError(f"MCP 请求超时：{name}，等待 {timeout} 秒") from error
            if message.get("method") == "roots/list" and "id" in message:
                self.send({"jsonrpc": "2.0", "id": message["id"], "result": {
                    "roots": [{"uri": ROOT.as_uri(), "name": "OpenNote"}],
                }})
                continue
            if "processEnded" in message or "invalidProtocolLine" in message:
                raise RuntimeError(message)
            if message.get("id") == request_id and "method" not in message:
                if "error" in message:
                    raise RuntimeError(message["error"])
                return message["result"]
        raise TimeoutError(f"MCP 请求超时：{method}")

    def initialize(self):
        result = self.request("initialize", {
            "protocolVersion": "2024-11-05",
            "capabilities": {"roots": {"listChanged": True}},
            "clientInfo": {"name": "opennote-dev-check", "version": "1.0.0"},
        })
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        return result

    def call(self, name: str, arguments: dict | None = None, timeout: int = 180):
        result = self.request("tools/call", {"name": name, "arguments": arguments or {}}, timeout=timeout)
        if result.get("isError"):
            raise RuntimeError(f"{name}: {result}")
        return result

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            # 只结束此客户端创建的服务器进程；不搜索或结束其他 Dart 进程。
            self.process.terminate()
            self.process.wait(timeout=10)
        self.stderr.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report-dir", type=Path, default=ROOT / ".local/flutter-dev/mcp")
    parser.add_argument("--vm-service-uri")
    parser.add_argument("--dtd-uri")
    parser.add_argument("--run-tests", action="store_true")
    parser.add_argument("--full-tests", action="store_true", help="经官方 MCP 串行执行全量 Flutter 测试")
    parser.add_argument("--launch", action="store_true", help="启动并验证独立资料库的 Windows Debug 程序")
    parser.add_argument("--screenshot", action="store_true", help="经 Flutter Inspector 保存真实项目首页截图")
    parser.add_argument("--navigation", action="store_true", help="通过开发 Driver 入口验证首页新建、返回和再次打开")
    options = parser.parse_args()
    options.report_dir.mkdir(parents=True, exist_ok=True)
    started = datetime.now(timezone.utc)
    report = {"time": started.isoformat(), "root": str(ROOT), "checks": {}}
    client = McpClient(options.report_dir / "server-stderr.log")
    launched_pid = None
    data_dir = None
    report["serverPid"] = client.process.pid

    def save_report():
        (options.report_dir / "report.json").write_text(
            json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8",
        )
    try:
        report["initialize"] = client.initialize()
        tools = client.request("tools/list")["tools"]
        report["tools"] = tools
        names = {tool["name"] for tool in tools}
        print("官方 Dart MCP 工具：" + ", ".join(sorted(names)), flush=True)
        report["checks"]["roots"] = client.call("roots", {
            "command": "add", "uris": [ROOT.as_uri()],
        })
        report["checks"]["list_devices"] = client.call("list_devices")
        report["checks"]["analyze_files"] = client.call("analyze_files", {
            "roots": [{"root": ROOT.as_uri(), "paths": ["lib/dev/component_previews.dart"]}],
        })
        if "No errors" not in json.dumps(report["checks"]["analyze_files"]):
            raise RuntimeError("Dart MCP 静态分析没有返回 No errors，请检查报告。")
        if options.run_tests or options.full_tests:
            print("通过官方 MCP 执行全量 Flutter 测试…" if options.full_tests else "通过官方 MCP 执行组件预览测试…", flush=True)
            test_root = {"root": ROOT.as_uri()}
            if not options.full_tests:
                test_root["paths"] = ["test/dev/component_previews_test.dart"]
            report["checks"]["run_tests"] = client.call("run_tests", {
                "roots": [test_root],
                "arguments": {
                    "concurrency": "1", "reporter": "expanded",
                    "file-reporter": "json:" + (options.report_dir / "tests.jsonl").resolve().relative_to(ROOT).as_posix(),
                },
            }, timeout=900)
            save_report()
            events = [json.loads(line) for line in (options.report_dir / "tests.jsonl").read_text(encoding="utf-8").splitlines()]
            if not events or events[-1].get("type") != "done" or not events[-1].get("success"):
                raise RuntimeError("官方 MCP 测试没有完整通过，请检查 tests.jsonl。")
        if options.launch:
            data_dir = Path(tempfile.mkdtemp(prefix="opennote-mcp-runtime-"))
            report["dataDirectory"] = str(data_dir)
            print(f"通过官方 MCP 启动 Windows Debug；独立资料库：{data_dir}", flush=True)
            launch = client.call("launch_app", {
                "root": ROOT.as_uri(), "device": "windows", "target": "test_driver/project_home_app.dart" if options.navigation else "lib/main.dart",
                "args": ["--debug", f"--dart-entrypoint-args=--data-dir={data_dir}"],
                "timeout": 300000,
            }, timeout=330)
            report["checks"]["launch_app"] = launch
            save_report()
            print(json.dumps(launch, ensure_ascii=False), flush=True)
            launch_data = launch.get("structuredContent")
            if launch_data is None:
                launch_data = json.loads(next(item["text"] for item in launch["content"] if item["type"] == "text"))
            launched_pid = launch_data["pid"]
            options.dtd_uri = launch_data["dtdUri"]
            options.vm_service_uri = launch_data["appUri"]
        if options.dtd_uri:
            report["checks"]["dtd_connect"] = client.call("dtd", {
                "command": "connect", "uri": options.dtd_uri,
            })
            report["checks"]["connected_apps"] = client.call("dtd", {"command": "listConnectedApps"})
            print(json.dumps(report["checks"]["connected_apps"], ensure_ascii=False), flush=True)
        if options.vm_service_uri:
            report["checks"]["vm_connect"] = client.call("vm_service", {
                "command": "connect", "appUri": options.vm_service_uri,
            })
            report["checks"]["getVM"] = client.call("vm_service", {
                "command": "callMethod", "method": "getVM", "appUri": options.vm_service_uri,
            })
            ready_deadline = time.monotonic() + 90
            while True:
                report["checks"]["widget_tree"] = client.call("widget_inspector", {
                    "command": "get_widget_tree", "summaryOnly": True,
                    "appUri": options.vm_service_uri,
                })
                if "ProjectHome" in json.dumps(report["checks"]["widget_tree"]):
                    break
                if time.monotonic() >= ready_deadline:
                    report["checks"]["startup_logs"] = client.call("get_app_logs", {"appUri": options.vm_service_uri})
                    raise RuntimeError("Windows 应用未进入项目首页；请检查组件树和启动日志。")
                time.sleep(1)
            report["checks"]["runtime_errors"] = client.call("get_runtime_errors", {
                "appUri": options.vm_service_uri,
            })
            if options.screenshot:
                def payload(result):
                    return json.loads(next(item["text"] for item in result["content"] if item["type"] == "text"))

                vm = payload(report["checks"]["getVM"])
                isolate_id = next(item["id"] for item in vm["isolates"] if item["name"] == "main")
                pending = [payload(report["checks"]["widget_tree"])]
                workbench = None
                while pending:
                    node = pending.pop()
                    if node.get("widgetRuntimeType") == "ProjectHome":
                        workbench = node
                        break
                    pending.extend(node.get("children", []))
                if workbench is None:
                    raise RuntimeError("Inspector 组件树没有项目首页对象。")
                screenshot = payload(client.call("vm_service", {
                    "command": "callMethod", "method": "ext.flutter.inspector.screenshot",
                    "appUri": options.vm_service_uri, "isolateId": isolate_id,
                    "arguments": {"id": workbench["valueId"], "width": "1920", "height": "1080", "maxPixelRatio": "1"},
                }))
                png = base64.b64decode(screenshot["result"], validate=True)
                if not png.startswith(b"\x89PNG\r\n\x1a\n"):
                    raise RuntimeError("Inspector 没有返回有效 PNG。")
                screenshot_path = options.report_dir / "home-runtime.png"
                screenshot_path.write_bytes(png)
                report["checks"]["screenshot"] = {"path": str(screenshot_path), "bytes": len(png), "source": "ext.flutter.inspector.screenshot"}
            if options.navigation:
                # 输入光标持续重绘，不以全局动画静止作为操作条件；下方逐步等待目标组件。
                report["checks"]["driver_frame_sync"] = client.call("flutter_driver_command", {
                    "command": "set_frame_sync", "enabled": "false", "appUri": options.vm_service_uri,
                })
                def inspect(name):
                    result = client.call("widget_inspector", {"command": "get_widget_tree", "summaryOnly": False, "appUri": options.vm_service_uri})
                    report["checks"][name] = result
                    save_report()
                    return json.dumps(result, ensure_ascii=False)

                def tap_text(text, name):
                    tree = inspect(name + "_tree")
                    if text not in tree:
                        raise RuntimeError(f"组件树未找到可见文字：{text}")
                    report["checks"][name] = client.call("flutter_driver_command", {
                        "command": "tap", "finderType": "ByText", "text": text,
                        "appUri": options.vm_service_uri, "timeout": "15000",
                    })

                def wait_type(widget_type):
                    client.call("flutter_driver_command", {"command": "waitFor", "finderType": "ByType", "type": widget_type, "appUri": options.vm_service_uri, "timeout": "15000"})

                tap_text("新建项目", "create_project")
                tree = inspect("naming_tree")
                if "TextInputDialog" not in tree or "TextField" not in tree:
                    raise RuntimeError("未找到真实命名输入框")
                client.call("flutter_driver_command", {"command": "enter_text", "text": "MCP 导航验收", "appUri": options.vm_service_uri})
                tap_text("创建", "confirm_create")
                wait_type("Workbench")
                report["checks"]["created_workbench"] = inspect("created_workbench_tree")
                tap_text("返回项目主页", "return_home")
                client.call("flutter_driver_command", {"command": "waitForAbsent", "finderType": "ByType", "type": "Workbench", "appUri": options.vm_service_uri, "timeout": "15000"})
                wait_type("ProjectHome")
                tap_text("MCP 导航验收", "reopen_project")
                wait_type("Workbench")
                tap_text("返回项目主页", "return_home_again")
                client.call("flutter_driver_command", {"command": "waitForAbsent", "finderType": "ByType", "type": "Workbench", "appUri": options.vm_service_uri, "timeout": "15000"})
                inspect("final_home_tree")
                print("真实 Windows 首页 → 新建项目 → 工作台 → 首页 → 再次打开 → 首页通过。", flush=True)
            report["checks"]["hot_reload"] = client.call("hot_reload", {
                "appUri": options.vm_service_uri,
            })
            if "Hot reload succeeded" not in json.dumps(report["checks"]["hot_reload"]):
                raise RuntimeError("官方 MCP 没有确认热重载成功。")
            report["checks"]["runtime_errors_after_reload"] = client.call("get_runtime_errors", {
                "appUri": options.vm_service_uri,
            })
            for name in ("runtime_errors", "runtime_errors_after_reload"):
                if "No runtime errors found" not in json.dumps(report["checks"][name]):
                    raise RuntimeError("官方 MCP 返回了运行异常，请检查报告。")
            save_report()
        report["passed"] = True
        print("MCP 握手、分析与所选测试／运行时检查完成。", flush=True)
    except Exception as error:
        report["passed"] = False
        report["error"] = f"{type(error).__name__}: {error}"
        print(report["error"], flush=True)
    finally:
        if launched_pid is not None:
            try:
                report["checks"]["stop_app"] = client.call("stop_app", {"pid": launched_pid})
                if not report["checks"]["stop_app"].get("structuredContent", {}).get("success"):
                    raise RuntimeError("官方 stop_app 没有确认成功，请检查应用清理结果。")
            except Exception as error:
                report["passed"] = False
                report["stopError"] = f"{type(error).__name__}: {error}"
        if data_dir is not None:
            # Windows 的官方 stop_app 可能只结束 flutter.bat 的 cmd 父进程。
            # 只核验并结束本次唯一临时资料库标记对应的运行子进程。
            cleanup = subprocess.run([
                "C:/Program Files/PowerShell/7/pwsh.exe", "-NoProfile", "-NonInteractive",
                "-File", str(ROOT / "tools/dev/stop_mcp_runtime.ps1"),
                "-DataDirectory", str(data_dir),
            ], cwd=ROOT, env=environment(), text=True, encoding="utf-8", capture_output=True)
            report["checks"]["owned_runtime_cleanup"] = {
                "exitCode": cleanup.returncode, "output": cleanup.stdout + cleanup.stderr,
            }
            if cleanup.returncode != 0:
                report["passed"] = False
        client.close()
        save_report()
        (options.report_dir / f"report-{started.strftime('%Y%m%dT%H%M%S%fZ')}.json").write_text(
            json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8",
        )
    return 0 if report.get("passed") else 1


if __name__ == "__main__":
    raise SystemExit(main())
