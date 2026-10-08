"""计时实际 Release 工作台，使用容量验证资料库，不清空或覆盖任何资料。"""
from datetime import datetime, timezone
import argparse
import json
import os
from pathlib import Path
import subprocess


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--exe', type=Path, required=True)
    parser.add_argument('--data-dir', type=Path, required=True)
    parser.add_argument('--report-dir', type=Path, required=True)
    args = parser.parse_args()
    if not (args.data_dir / 'active.json').is_file():
        raise RuntimeError('启动验收应使用已有容量验证库，避免空白首屏代替真实工作台')
    report_dir = args.report_dir.resolve()
    report_dir.mkdir(parents=True, exist_ok=True)
    options = subprocess.STARTUPINFO()
    options.dwFlags |= subprocess.STARTF_USESHOWWINDOW
    options.wShowWindow = 0
    environment = dict(os.environ)
    environment['PATH'] = str(Path(os.environ['SystemRoot']) / 'System32')
    runs = []
    for index in range(3):
        path = report_dir / f'startup-{index + 1}.json'
        if path.exists():
            raise RuntimeError('输出目录已有计时报告，请指定新目录')
        launched = datetime.now(timezone.utc)
        subprocess.run([str(args.exe.resolve()), '--verify-startup', f'--data-dir={args.data_dir.resolve()}',
                        f'--verify-report={path}'], cwd=args.exe.resolve().parent, env=environment,
                       timeout=60, check=True, startupinfo=options, creationflags=subprocess.CREATE_NO_WINDOW)
        result = json.loads(path.read_text(encoding='utf-8'))
        if not result.get('success'):
            raise RuntimeError(f'真实工作台计时失败：{result}')
        result['workspaceReadyFromProcessLaunchMs'] = (
            datetime.fromisoformat(result['workspaceReadyAtUtc']) - launched).total_seconds() * 1000
        result['initialPdfReadyFromProcessLaunchMs'] = (
            datetime.fromisoformat(result['initialPdfReadyAtUtc']) - launched).total_seconds() * 1000
        runs.append(result)
    summary = {'success': True, 'runs': runs,
               'workspaceUnder5s': all(run['workspaceReadyFromProcessLaunchMs'] <= 5000 for run in runs),
               'initialPdfPreviewUnder3s': all(run['initialPdfReadyFromProcessLaunchMs'] <= 3000 for run in runs),
               'scope': '本机真实Release工作台，已有1000页/5000卡容量库；三个新进程，系统文件缓存未清除；启动请求隐藏，但Windows runner首帧后可显示窗口；初始PDF预览完成的一帧为保守上界，非高分辨率细化或物理显示时间'}
    (report_dir / 'summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(summary, ensure_ascii=False, indent=2), flush=True)


if __name__ == '__main__':
    main()
