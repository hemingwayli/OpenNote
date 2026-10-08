"""启动实际Release诊断，采Windows进程峰值内存和本机硬件；不修改正式资料库。"""

from __future__ import annotations

import argparse
import ctypes
from ctypes import wintypes
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import struct
import subprocess
import sys
import time
import winreg


MEMORY_LIMIT_BYTES = 2 * 1024**3
CAPACITY_COUNTS = {
    "actualPdfPages": 1000,
    "persistedNativeTextPages": 1000,
    "actualCards": 5000,
    "graphNodes": 500,
}


class MemoryCounters(ctypes.Structure):
    _fields_ = [("cb", wintypes.DWORD), ("PageFaultCount", wintypes.DWORD)] + [
        (name, ctypes.c_size_t) for name in (
            "PeakWorkingSetSize", "WorkingSetSize", "QuotaPeakPagedPoolUsage", "QuotaPagedPoolUsage",
            "QuotaPeakNonPagedPoolUsage", "QuotaNonPagedPoolUsage", "PagefileUsage", "PeakPagefileUsage", "PrivateUsage",
        )
    ]


def registry_values(path: str, names: tuple[str, ...]) -> dict:
    result = {}
    try:
        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, path) as key:
            for name in names:
                try:
                    result[name] = winreg.QueryValueEx(key, name)[0]
                except OSError:
                    result[name] = None
    except OSError as error:
        result["error"] = str(error)
    return result


def physical_core_count(kernel) -> int:
    kernel.GetLogicalProcessorInformationEx.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.POINTER(wintypes.DWORD)]
    kernel.GetLogicalProcessorInformationEx.restype = wintypes.BOOL
    length = wintypes.DWORD()
    kernel.GetLogicalProcessorInformationEx(0, None, ctypes.byref(length))
    if not length.value:
        raise ctypes.WinError(ctypes.get_last_error())
    buffer = ctypes.create_string_buffer(length.value)
    if not kernel.GetLogicalProcessorInformationEx(0, buffer, ctypes.byref(length)):
        raise ctypes.WinError(ctypes.get_last_error())
    offset = count = 0
    while offset + 8 <= length.value:
        relationship, size = struct.unpack_from("<II", buffer.raw, offset)
        if size < 8 or offset + size > length.value:
            raise ValueError("Windows CPU 核心结构长度无效")
        count += relationship == 0
        offset += size
    return count


def storage_devices(kernel) -> list[dict]:
    # 常量与结构来自本机 Windows SDK 10.0.26100.0 ntddstor.h；只读查询。
    kernel.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
    kernel.CreateFileW.restype = wintypes.HANDLE
    kernel.DeviceIoControl.argtypes = [wintypes.HANDLE, wintypes.DWORD, ctypes.c_void_p, wintypes.DWORD, ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(wintypes.DWORD), ctypes.c_void_p]
    kernel.DeviceIoControl.restype = wintypes.BOOL
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    invalid = ctypes.c_void_p(-1).value
    devices = []
    for number in range(16):
        handle = kernel.CreateFileW(rf"\\.\PhysicalDrive{number}", 0, 3, None, 3, 0, None)
        if handle == invalid:
            error = ctypes.get_last_error()
            if error not in (2, 3):
                devices.append({"physicalDrive": number, "queryError": str(ctypes.WinError(error))})
            continue
        entry = {"physicalDrive": number}
        try:
            for property_id in (0, 7):
                query = ctypes.create_string_buffer(struct.pack("<III", property_id, 0, 0))
                output = ctypes.create_string_buffer(4096)
                returned = wintypes.DWORD()
                if not kernel.DeviceIoControl(handle, 0x2D1400, query, 12, output, len(output), ctypes.byref(returned), None):
                    entry[f"property{property_id}Error"] = str(ctypes.WinError(ctypes.get_last_error()))
                    continue
                raw = output.raw[:returned.value]
                if property_id == 7 and len(raw) >= 9:
                    entry["incursSeekPenalty"] = bool(raw[8])
                    entry["mediaInference"] = "solid-state (no seek penalty)" if not raw[8] else "rotating or seek-penalty device"
                elif property_id == 0 and len(raw) >= 36:
                    for label, position in (("vendor", 12), ("model", 16), ("revision", 20)):
                        offset = struct.unpack_from("<I", raw, position)[0]
                        entry[label] = raw[offset:].split(b"\0", 1)[0].decode("ascii", errors="replace").strip() if 0 < offset < len(raw) else None
                    entry["busTypeCode"] = struct.unpack_from("<I", raw, 28)[0]
        finally:
            kernel.CloseHandle(handle)
        devices.append(entry)
    return devices


def hardware() -> dict:
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.GetActiveProcessorCount.argtypes = [wintypes.WORD]
    kernel.GetActiveProcessorCount.restype = wintypes.DWORD

    class MemoryStatus(ctypes.Structure):
        _fields_ = [("dwLength", wintypes.DWORD), ("dwMemoryLoad", wintypes.DWORD)] + [(name, ctypes.c_ulonglong) for name in (
            "totalPhysical", "availablePhysical", "totalCommitLimit", "availableCommit", "totalVirtual", "availableVirtual", "availableExtendedVirtual")]

    status = MemoryStatus()
    status.dwLength = ctypes.sizeof(status)
    kernel.GlobalMemoryStatusEx.argtypes = [ctypes.POINTER(MemoryStatus)]
    if not kernel.GlobalMemoryStatusEx(ctypes.byref(status)):
        raise ctypes.WinError(ctypes.get_last_error())
    cpu = registry_values(r"HARDWARE\DESCRIPTION\System\CentralProcessor\0", ("ProcessorNameString", "~MHz"))
    cpu.update(physicalCores=physical_core_count(kernel), logicalProcessors=kernel.GetActiveProcessorCount(0xFFFF))
    gpu = []
    gpu_path = r"SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}"
    try:
        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, gpu_path) as key:
            for index in range(winreg.QueryInfoKey(key)[0]):
                subkey = winreg.EnumKey(key, index)
                if subkey.isdigit():
                    gpu.append(registry_values(gpu_path + "\\" + subkey, ("DriverDesc", "DriverVersion")))
    except OSError as error:
        gpu.append({"error": str(error)})
    return {
        "method": "只读 Windows native API/registry，无 PowerShell 子进程",
        "cpu": cpu,
        "computer": registry_values(r"HARDWARE\DESCRIPTION\System\BIOS", ("SystemManufacturer", "SystemProductName")),
        "os": registry_values(r"SOFTWARE\Microsoft\Windows NT\CurrentVersion", ("ProductName", "DisplayVersion", "CurrentBuildNumber", "UBR", "EditionID")),
        "memory": {name: getattr(status, name) for name in ("totalPhysical", "availablePhysical", "totalCommitLimit", "availableCommit")},
        "disks": storage_devices(kernel), "installedDisplayDrivers": gpu,
        "actualRendererGpuMeasured": False,
    }


def process_memory_api():
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    psapi = ctypes.WinDLL("psapi", use_last_error=True)
    kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel.OpenProcess.restype = wintypes.HANDLE
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    psapi.GetProcessMemoryInfo.argtypes = [wintypes.HANDLE, ctypes.POINTER(MemoryCounters), wintypes.DWORD]
    psapi.GetProcessMemoryInfo.restype = wintypes.BOOL
    return kernel, psapi


def process_windows(pid: int) -> list[dict]:
    user = ctypes.WinDLL("user32", use_last_error=True)
    callback_type = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    user.EnumWindows.argtypes = [callback_type, wintypes.LPARAM]
    user.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
    user.IsWindowVisible.argtypes = [wintypes.HWND]
    user.IsIconic.argtypes = [wintypes.HWND]
    user.GetWindowTextW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
    windows = []

    @callback_type
    def collect(handle, _):
        owner = wintypes.DWORD()
        user.GetWindowThreadProcessId(handle, ctypes.byref(owner))
        if owner.value == pid:
            title = ctypes.create_unicode_buffer(256)
            user.GetWindowTextW(handle, title, len(title))
            windows.append({"title": title.value, "visible": bool(user.IsWindowVisible(handle)), "minimized": bool(user.IsIconic(handle))})
        return True

    if not user.EnumWindows(collect, 0):
        raise ctypes.WinError(ctypes.get_last_error())
    return windows


def binary_identity(executable: Path) -> list[dict]:
    files = [executable, executable.parent / "data" / "app.so", executable.parent / "flutter_windows.dll", executable.parent / "pdfium.dll"]
    identities = []
    for path in files:
        before = path.stat()
        with path.open("rb") as stream:
            digest = hashlib.file_digest(stream, "sha256").hexdigest()
        after = path.stat()
        if before.st_mtime_ns != after.st_mtime_ns or before.st_size != after.st_size:
            raise ValueError(f"二进制在采集身份时变化：{path}")
        identities.append({"path": str(path), "length": after.st_size, "modifiedUtc": datetime.fromtimestamp(after.st_mtime, timezone.utc).isoformat(), "sha256": digest})
    return identities


def group_acceptance_failures(app: dict) -> list[str]:
    """独立核验组拖报告，旧画布报告或只有成功标志不能替代新验收。"""
    failures = []
    if app.get("mode") != "release":
        failures.append("组拖验收必须运行真实Release二进制")
    group = app.get("graphGroup")
    if not isinstance(group, dict):
        return failures + ["缺少graphGroup，旧平移/缩放报告不能证明组拖"]
    expected = {
        "selectedNodes": 500, "selectedRoots": 100, "unionNodes": 500,
        "changedNodes": 500, "bankNodes": 4500, "layoutCalls": 1,
        "singleMoveCalls": 0, "relationCalls": 0,
        "visibleNodesBeforeInteraction": 500, "visibleNodesAfterInteraction": 500,
        "visibleNodesAfterUndo": 500, "selectedNodesAfterInteraction": 500,
        "inputFrameCount": 180, "inputFramesWith500VisibleNodes": 180,
        "minVisibleNodesDuringInput": 500, "maxVisibleNodesDuringInput": 500,
        "inputFramesWithAllNodesInsideViewport": 180,
        "redoEntriesBefore": 0, "redoEntriesAfterCommit": 0, "redoEntriesAfterUndo": 1,
    }
    for field, value in expected.items():
        actual = group.get(field)
        if isinstance(actual, bool) or actual != value:
            failures.append(f"graphGroup.{field}预期{value}，实际{actual}")
    for field in (
        "selectionUsesProductionController", "submittedExact500Nodes",
        "coordinateDeltaMatchesActualGesture",
        "all500CoordinatesHaveSameDelta", "identitiesCardsParentsMapFoldEdgesAndAnchorsUnchanged",
        "other4500NodesAndCardsUnchanged", "singleUndoEntry",
        "undoRestoredAll500CoordinatesAndRelations", "undoPreservedOther4500",
        "undoRestoredHistoryCounts", "contractPassed", "within33ms",
    ):
        if group.get(field) is not True:
            failures.append(f"graphGroup.{field}未通过")
    for field in ("engineFrameSamples", "inputFramesWithActualNodeMotion"):
        actual = group.get(field)
        if not isinstance(actual, int) or isinstance(actual, bool) or actual < 175:
            failures.append(f"graphGroup.{field}需要至少175个实际样本，实际{actual}")
    raw_frames = group.get("rawEngineFrames")
    if not isinstance(raw_frames, list) or len(raw_frames) != group.get("engineFrameSamples"):
        failures.append("graphGroup原始FrameTiming数量与统计不符")
    elif any(not isinstance(frame, dict) or not isinstance(frame.get("frameNumber"), int) or isinstance(frame.get("frameNumber"), bool) for frame in raw_frames):
        failures.append("graphGroup原始FrameTiming缺少实际frameNumber")
    elif len({frame["frameNumber"] for frame in raw_frames}) != len(raw_frames):
        failures.append("graphGroup原始FrameTiming缺失或重复")
    for name in ("graph", "graphGroup"):
        metrics = app.get(name)
        value = metrics.get("p95TotalSpanMs") if isinstance(metrics, dict) else None
        if not isinstance(value, (int, float)) or isinstance(value, bool) or not math.isfinite(value) or not 0 <= value <= 33:
            failures.append(f"{name}.p95TotalSpanMs未达到原33ms门槛，实际{value}")
    for field in ("commitMs", "undoMs"):
        value = group.get(field)
        if not isinstance(value, (int, float)) or isinstance(value, bool) or not math.isfinite(value) or value < 0:
            failures.append(f"graphGroup.{field}缺少真实独立耗时")
    distance = group.get("actualDraggedNodeDistancePixels")
    if not isinstance(distance, (int, float)) or isinstance(distance, bool) or not math.isfinite(distance) or distance <= 5:
        failures.append(f"graphGroup没有超过5px的实际节点位移，实际{distance}")
    undo_before = group.get("undoEntriesBefore")
    if not isinstance(undo_before, int) or isinstance(undo_before, bool) or undo_before < 5000:
        failures.append("graphGroup没有保留5000卡片的实际会话历史")
    elif group.get("undoEntriesAfterCommit") != undo_before + 1 or group.get("undoEntriesAfterUndo") != undo_before:
        failures.append("graphGroup实际undo计数不满足一次提交/一次恢复")
    return failures


def memory_acceptance_failures(app: dict, memory: dict) -> list[str]:
    """按真实容量计数和累计峰值验收，成功或within标志不能替代测量。"""
    failures = []
    if app.get("success") is not True:
        failures.append("应用未完成完整容量测量")
    dataset = app.get("dataset")
    if not isinstance(dataset, dict):
        failures.append("缺少实际容量计数dataset")
    else:
        for field, expected in CAPACITY_COUNTS.items():
            actual = dataset.get(field)
            if type(actual) is not int or actual != expected:
                failures.append(f"dataset.{field}预期{expected}，实际{actual}")
    if memory.get("completeCapacityWorkloadMeasured") is not True:
        failures.append("memory.completeCapacityWorkloadMeasured未通过")
    samples = memory.get("samples")
    if type(samples) is not int or samples <= 0:
        failures.append(f"memory.samples缺少实际成功采样，实际{samples}")
    for field in ("peakWorkingSetBytes", "peakCommitBytes"):
        value = memory.get(field)
        if type(value) is not int or value <= 0:
            failures.append(f"memory.{field}缺少实际累计峰值，实际{value}")
        elif value > MEMORY_LIMIT_BYTES:
            failures.append(f"memory.{field}超过原2GiB门槛{MEMORY_LIMIT_BYTES}字节，实际{value}")
    return failures


def performance_exit_code(report: dict, require_group: bool) -> int:
    """正式CLI直接使用此退出判定，独立保留内存与组拖的失败结果。"""
    return 0 if (
        report["application"].get("success") is True
        and not report["runnerFailure"]
        and report["processExitCode"] == 0
        and report["memoryAcceptance"]["passed"] is True
        and (not require_group or report["groupAcceptance"]["passed"] is True)
    ) else 1


def run(executable: Path, fixtures: Path, data: Path, output: Path, timeout: int, visible_application: bool = False, require_group: bool = False) -> dict:
    if data.exists() and any(data.iterdir()):
        raise ValueError("验证资料目录必须为空；拒绝复用或清空已有目录")
    if output.exists() and any(output.iterdir()):
        raise ValueError("输出目录必须为空；拒绝覆盖成功或失败诊断证据")
    data.mkdir(parents=True, exist_ok=True)
    output.mkdir(parents=True, exist_ok=True)
    app_report = output / "release-app-report.json"
    hardware_report = hardware()
    identities = binary_identity(executable)
    launch = time.perf_counter()
    startup_info = subprocess.STARTUPINFO()
    startup_info.dwFlags |= subprocess.STARTF_USESHOWWINDOW
    startup_info.wShowWindow = 1 if visible_application else 0
    process_log = (output / "process-output.log").open("w", encoding="utf-8")
    try:
        process = subprocess.Popen([
            str(executable), "--verify-performance", f"--data-dir={data}",
            f"--verify-fixtures={fixtures}", f"--verify-report={app_report}",
        ], cwd=str(executable.parent), startupinfo=startup_info, creationflags=subprocess.CREATE_NO_WINDOW, stdout=process_log, stderr=subprocess.STDOUT)
    except BaseException:
        process_log.close()
        raise
    kernel, psapi = process_memory_api()
    handle = kernel.OpenProcess(0x0400 | 0x0010, False, process.pid)
    if not handle:
        error = ctypes.WinError(ctypes.get_last_error())
        process.terminate()
        process.wait(timeout=10)
        process_log.close()
        raise error
    samples = 0
    window_samples = []
    peak_working = peak_commit = peak_private_sample = 0
    sample_log = output / "process-memory-samples.jsonl"
    failure = None
    try:
        with sample_log.open("w", encoding="utf-8") as log:
            while process.poll() is None:
                elapsed = time.perf_counter() - launch
                if elapsed > timeout:
                    # 只终止本工具启动且记录PID的诊断进程，保留全部失败证据。
                    process.terminate()
                    failure = f"本机诊断超过 {timeout}s，已终止 PID {process.pid}"
                    process.wait(timeout=10)
                    break
                counters = MemoryCounters()
                counters.cb = ctypes.sizeof(counters)
                if psapi.GetProcessMemoryInfo(handle, ctypes.byref(counters), counters.cb):
                    samples += 1
                    peak_working = max(peak_working, counters.PeakWorkingSetSize)
                    peak_commit = max(peak_commit, counters.PeakPagefileUsage)
                    peak_private_sample = max(peak_private_sample, counters.PrivateUsage)
                    log.write(json.dumps({"elapsedSeconds": elapsed, "workingSetBytes": counters.WorkingSetSize, "privateBytes": counters.PrivateUsage, "peakWorkingSetBytes": counters.PeakWorkingSetSize, "peakCommitBytes": counters.PeakPagefileUsage}) + "\n")
                    log.flush()
                    if samples % 10 == 0:
                        window_samples.append({"elapsedSeconds": elapsed, "windows": process_windows(process.pid)})
                time.sleep(.1)
            # 保留退出进程句柄，尽可能补读终末累计峰值；系统若已拒绝查询则明确记录。
            final_counters = MemoryCounters()
            final_counters.cb = ctypes.sizeof(final_counters)
            final_peak_read = bool(psapi.GetProcessMemoryInfo(handle, ctypes.byref(final_counters), final_counters.cb))
            if final_peak_read:
                peak_working = max(peak_working, final_counters.PeakWorkingSetSize)
                peak_commit = max(peak_commit, final_counters.PeakPagefileUsage)
                peak_private_sample = max(peak_private_sample, final_counters.PrivateUsage)
                log.write(json.dumps({"elapsedSeconds": time.perf_counter() - launch, "terminalPeakRead": True, "peakWorkingSetBytes": final_counters.PeakWorkingSetSize, "peakCommitBytes": final_counters.PeakPagefileUsage}) + "\n")
                log.flush()
    finally:
        kernel.CloseHandle(handle)
        process_log.close()
    try:
        app = json.loads(app_report.read_text(encoding="utf-8")) if app_report.exists() else {"success": False, "error": "诊断没有生成应用报告"}
        if not isinstance(app, dict):
            app = {"success": False, "error": "应用报告必须是JSON对象"}
    except (ValueError, OSError) as error:
        app = {"success": False, "error": f"应用报告不可读取：{error}"}
    dataset = app.get("dataset")
    memory = {
        "method": "Windows GetProcessMemoryInfo，100ms采样；PeakWorkingSetSize和PeakPagefileUsage为OS累计峰值",
        "pid": process.pid, "samples": samples,
        "peakWorkingSetBytes": peak_working, "peakCommitBytes": peak_commit,
        "peakSampledPrivateBytes": peak_private_sample,
        "terminalPeakRead": final_peak_read,
        "peakCoverage": "OS累计峰值截至最后成功查询；终末补读失败时不保证最后100ms退出阶段的峰值",
        "within2GiB": samples > 0 and max(peak_working, peak_commit) <= MEMORY_LIMIT_BYTES,
        "completeCapacityWorkloadMeasured": app.get("success") is True and isinstance(dataset, dict) and all(type(dataset.get(field)) is int and dataset[field] == expected for field, expected in CAPACITY_COUNTS.items()),
    }
    memory_failures = memory_acceptance_failures(app, memory)
    group_failures = group_acceptance_failures(app) if require_group else []
    report = {
        "capturedAt": datetime.now(timezone.utc).isoformat(),
        "hardware": hardware_report, "application": app, "memory": memory,
        "binaryIdentity": identities,
        "processExitCode": process.returncode,
        "diagnosticProcessElapsedSeconds": time.perf_counter() - launch,
        "productionStartupMeasured": False,
        "lowestSpecifiedHardwareMeasured": False,
        "windowLaunchPolicy": "真实 OpenNote 主窗口：STARTF_USESHOWWINDOW SW_SHOWNORMAL + CREATE_NO_WINDOW" if visible_application else "请求 STARTF_USESHOWWINDOW SW_HIDE + CREATE_NO_WINDOW；runner首帧可能Show，实际状态以窗口样本为准",
        "windowSamples": window_samples,
        "runnerFailure": failure,
        "memoryAcceptance": {
            "passed": not memory_failures,
            "failures": memory_failures,
        },
        "groupAcceptance": {
            "required": require_group,
            "passed": not group_failures if require_group else None,
            "failures": group_failures,
        },
    }
    (output / "local-performance-report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--probe-output", type=Path, help="仅验证本 Python 进程的 native 硬件/内存采集，不启动应用")
    parser.add_argument("--exe", type=Path)
    parser.add_argument("--fixtures", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--data-dir", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--timeout", type=int, default=900)
    parser.add_argument("--visible-application", action="store_true", help="为已授权的本机软件验证显示实际 OpenNote 主窗口；后台辅助工具仍隐藏")
    parser.add_argument("--require-group", action="store_true", help="要求Release真实500节点组拖/单事务/撤销及175帧原33ms门槛；拒绝旧报告，保留失败证据")
    args = parser.parse_args()
    if args.probe_output:
        if args.require_group:
            parser.error("--require-group需要实际应用性能路径，不能用于native采集烟测")
        kernel, psapi = process_memory_api()
        handle = kernel.OpenProcess(0x0400 | 0x0010, False, os.getpid())
        if not handle:
            raise ctypes.WinError(ctypes.get_last_error())
        counters = MemoryCounters()
        counters.cb = ctypes.sizeof(counters)
        try:
            if not psapi.GetProcessMemoryInfo(handle, ctypes.byref(counters), counters.cb):
                raise ctypes.WinError(ctypes.get_last_error())
        finally:
            kernel.CloseHandle(handle)
        result = {"capturedAt": datetime.now(timezone.utc).isoformat(), "scope": "Python 自进程 native 采集烟测，非 OpenNote 性能结论", "hardware": hardware(), "pythonPrivateBytes": counters.PrivateUsage, "pythonPeakWorkingSetBytes": counters.PeakWorkingSetSize}
        args.probe_output.parent.mkdir(parents=True, exist_ok=True)
        args.probe_output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(result, ensure_ascii=False, indent=2))
        sys.exit(0)
    if not args.exe or not args.data_dir or not args.output:
        parser.error("启动应用需要 --exe、--data-dir、--output")
    result = run(args.exe.resolve(), args.fixtures.resolve(), args.data_dir.resolve(), args.output.resolve(), args.timeout, args.visible_application, args.require_group)
    graph_summary = {key: value for key, value in result["application"].get("graph", {}).items() if key != "rawEngineFrames"}
    group_summary = {key: value for key, value in result["application"].get("graphGroup", {}).items() if key != "rawEngineFrames"}
    print(json.dumps({"report": str(args.output.resolve() / "local-performance-report.json"), "applicationSuccess": result["application"].get("success"), "processExitCode": result["processExitCode"], "runnerFailure": result["runnerFailure"], "dataset": result["application"].get("dataset"), "search": result["application"].get("search"), "graph": graph_summary, "graphGroup": group_summary, "groupAcceptance": result["groupAcceptance"], "memory": result["memory"], "memoryAcceptance": result["memoryAcceptance"]}, ensure_ascii=False, indent=2))
    sys.exit(performance_exit_code(result, args.require_group))
