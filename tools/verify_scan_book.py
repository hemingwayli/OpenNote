"""实际分发程序处理用户授权扫描书，验证强制结束后的持久 OCR 续跑。"""
from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

from verification.run_performance import MemoryCounters, process_memory_api


def read_process_peak(psapi, handle, memory: dict, *, terminal: bool = False) -> None:
    # 复用性能脚本的 Windows API 合同；OS 累计峰值不等同于离散瞬时采样最大值。
    counters = MemoryCounters()
    counters.cb = ctypes.sizeof(counters)
    successful = bool(psapi.GetProcessMemoryInfo(handle, ctypes.byref(counters), counters.cb))
    if terminal:
        memory['terminalPeakRead'] = successful
        if not successful:
            memory['terminalPeakReadError'] = str(ctypes.WinError(ctypes.get_last_error()))
    if successful:
        if not terminal:
            memory['samples'] += 1
        memory['peakWorkingSetBytes'] = max(memory['peakWorkingSetBytes'], counters.PeakWorkingSetSize)
        memory['peakCommitBytes'] = max(memory['peakCommitBytes'], counters.PeakPagefileUsage)


def write_memory_report(report_dir: Path, processes: list[dict]) -> dict:
    peak_working = max((entry['peakWorkingSetBytes'] for entry in processes), default=0)
    peak_commit = max((entry['peakCommitBytes'] for entry in processes), default=0)
    both_sampled = len(processes) == 2 and all(entry['samples'] > 0 for entry in processes)
    terminal_peaks = len(processes) == 2 and all(entry['terminalPeakRead'] for entry in processes)
    within_limit = both_sampled and max(peak_working, peak_commit) <= 2 * 1024**3
    report = {
        'method': 'Windows GetProcessMemoryInfo; 50ms sampling; PeakWorkingSetSize and '
                  'PeakPagefileUsage are OS cumulative process peaks.',
        'scope': 'Two actual application processes for five sampled pages of the user-authorized '
                 'scan, interrupted then resumed. Not simultaneous OCR of 1000 pages/5000 cards.',
        'processes': processes,
        'bothProcessesSampled': both_sampled,
        'peakWorkingSetBytes': peak_working,
        'peakCommitBytes': peak_commit,
        'maximumPeakBytes': max(peak_working, peak_commit),
        'limitBytes': 2 * 1024**3,
        'within2GiB': within_limit,
        'completeLifetimePeakRead': terminal_peaks,
        'completeLifetimeWithin2GiB': terminal_peaks and within_limit,
        'peakCoverage': 'OS cumulative peaks through the last successful read. If terminalPeakRead '
                        'is false, the last 50ms/exit interval is not guaranteed covered.',
        'completeCapacityWorkloadMeasured': False,
    }
    (report_dir / 'scan-book-memory.json').write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    return report


def sha256(path: Path) -> str:
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--exe', type=Path, required=True)
    parser.add_argument('--pdf', type=Path, required=True)
    parser.add_argument('--report-dir', type=Path, required=True)
    args = parser.parse_args()
    report_dir = args.report_dir.resolve()
    report_dir.mkdir(parents=True, exist_ok=True)
    original_hash = sha256(args.pdf)
    data = Path(tempfile.mkdtemp(prefix='OpenNote-扫描书中断验证-')) / 'data'
    startup = subprocess.STARTUPINFO()
    startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
    startup.wShowWindow = 0
    options = {'startupinfo': startup, 'creationflags': subprocess.CREATE_NO_WINDOW}
    environment = dict(os.environ)
    environment['PATH'] = str(Path(os.environ['SystemRoot']) / 'System32')
    report = report_dir / 'scan-book.json'
    command = [str(args.exe.resolve()), f'--data-dir={data}', f'--verify-scan-book={args.pdf.resolve()}',
               f'--verify-report={report}']
    kernel, psapi = process_memory_api()
    memory_processes = []
    started_at = time.time()
    process = subprocess.Popen(command, env=environment, cwd=data.parent, **options)
    first_memory = {'role': 'interrupted', 'pid': process.pid, 'samples': 0,
                    'peakWorkingSetBytes': 0, 'peakCommitBytes': 0,
                    'terminalPeakRead': False, 'controlledTermination': False}
    memory_processes.append(first_memory)
    first_handle = None
    interrupted = None
    deadline = time.monotonic() + 180
    progress_file = report_dir / 'progress.json'
    try:
        first_handle = kernel.OpenProcess(0x0400 | 0x0010, False, process.pid)
        if not first_handle:
            raise ctypes.WinError(ctypes.get_last_error())
        while process.poll() is None and time.monotonic() < deadline:
            read_process_peak(psapi, first_handle, first_memory)
            try:
                if progress_file.stat().st_mtime < started_at:
                    time.sleep(0.05)
                    continue
                progress = json.loads(progress_file.read_text(encoding='utf-8'))
            except (FileNotFoundError, json.JSONDecodeError, PermissionError):
                progress = {}
            if (progress.get('stage') == 'ocr' and progress.get('completedPages', 0) >= 1
                    and (progress.get('queuedPages', 0) > 0 or progress.get('currentPageOneBased') is not None)):
                interrupted = progress
                first_memory['controlledTermination'] = True
                process.terminate()
                process.wait(timeout=15)
                break
            time.sleep(0.05)
    finally:
        try:
            if process.poll() is None:
                first_memory['controlledTermination'] = True
                process.terminate()
                process.wait(timeout=15)
            if first_handle:
                read_process_peak(psapi, first_handle, first_memory, terminal=True)
        finally:
            if first_handle:
                kernel.CloseHandle(first_handle)
            first_memory['processExitCode'] = process.returncode
            write_memory_report(report_dir, memory_processes)
    if interrupted is None:
        raise RuntimeError('未能在部分完成的 OCR 队列中完成实际进程中断；不声称续跑通过')
    (report_dir / 'interruption.json').write_text(json.dumps(interrupted, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    resumed_command = command + ['--verify-existing']
    resumed = subprocess.Popen(resumed_command, env=environment, cwd=data.parent, **options)
    resumed_memory = {'role': 'resumed', 'pid': resumed.pid, 'samples': 0,
                      'peakWorkingSetBytes': 0, 'peakCommitBytes': 0,
                      'terminalPeakRead': False, 'controlledTermination': False}
    memory_processes.append(resumed_memory)
    resumed_handle = None
    deadline = time.monotonic() + 600
    try:
        resumed_handle = kernel.OpenProcess(0x0400 | 0x0010, False, resumed.pid)
        if not resumed_handle:
            raise ctypes.WinError(ctypes.get_last_error())
        while resumed.poll() is None:
            read_process_peak(psapi, resumed_handle, resumed_memory)
            if time.monotonic() > deadline:
                resumed_memory['controlledTermination'] = True
                raise subprocess.TimeoutExpired(resumed_command, 600)
            time.sleep(0.05)
    finally:
        try:
            if resumed.poll() is None:
                resumed_memory['controlledTermination'] = True
                resumed.terminate()
                resumed.wait(timeout=15)
            if resumed_handle:
                read_process_peak(psapi, resumed_handle, resumed_memory, terminal=True)
        finally:
            if resumed_handle:
                kernel.CloseHandle(resumed_handle)
            resumed_memory['processExitCode'] = resumed.returncode
            memory_report = write_memory_report(report_dir, memory_processes)
    # 续跑必须自然以 exit 0 结束，不能用成功 JSON 掩盖应用退出故障。
    if resumed.returncode != 0 or resumed_memory['controlledTermination']:
        raise subprocess.CalledProcessError(resumed.returncode, resumed_command)
    result = json.loads(report.read_text(encoding='utf-8'))
    if not result.get('success') or result.get('reusedCompletedPagesAtStartup', 0) < 1:
        raise RuntimeError(f'真实扫描书续跑失败：{result}')
    source_unchanged = sha256(args.pdf) == original_hash
    if not source_unchanged:
        raise RuntimeError('原始扫描 PDF 字节发生变化')
    summary = {'success': True, 'actualProcessInterrupted': True,
               'completedAtInterruption': interrupted['completedPages'],
               'resumedCompletedPages': result['reusedCompletedPagesAtStartup'],
               'sourceBytesUnchanged': source_unchanged, 'sourceSha256': original_hash,
               'dataPath': str(data), 'memory': memory_report, 'result': result}
    (report_dir / 'summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(summary, ensure_ascii=False, indent=2), flush=True)


if __name__ == '__main__':
    main()
