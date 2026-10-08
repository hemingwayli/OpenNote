"""在独立 Profile 程序中测量真实阅读滚动和 500 节点画布拖动。"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import subprocess
import time

from flutter_dev import FLUTTER, ROOT, environment, run


def main() -> int:
    report_dir = ROOT / '.local/flutter-dev/ui-profile'
    report_dir.mkdir(parents=True, exist_ok=True)
    build_started = time.monotonic()
    code = run(FLUTTER + ['build', 'windows', '--profile', '--no-pub', '-t', 'lib/dev/ui_profile.dart'])
    if code:
        return code
    executable = ROOT / 'build/windows/x64/runner/Profile/opennote.exe'
    report_path = report_dir / 'frames.json'
    args = [str(executable), f'--report={report_path}', f'--pdf={ROOT / "tools/fixtures/pdf/ui-reading.pdf"}']
    launch = {
        'executable': str(executable),
        'sha256': hashlib.sha256(executable.read_bytes()).hexdigest(),
        'buildSeconds': round(time.monotonic() - build_started, 3),
        'entrypoint': 'lib/dev/ui_profile.dart',
    }
    print('启动独立 Profile 探针，仅使用自产 PDF 与内存卡片…', flush=True)
    try:
        result = subprocess.run(args, cwd=ROOT, env=environment(), capture_output=True, timeout=180)
        (report_dir / 'runtime.log').write_bytes(result.stdout + result.stderr)
        launch['exitCode'] = result.returncode
        if result.returncode != 0:
            failure = json.loads(report_path.read_text(encoding='utf-8')) if report_path.exists() else {}
            print(failure.get('error', 'Profile 程序未生成报告。'), flush=True)
            return result.returncode or 1
        frames = json.loads(report_path.read_text(encoding='utf-8'))
        if not frames.get('success'):
            raise RuntimeError('Profile 探针没有完整成功。')
        print(json.dumps({name: {key: value for key, value in frames[name].items() if key != 'rawFrames'} for name in ['reader', 'graph']}, ensure_ascii=False, indent=2), flush=True)
        return 0
    except subprocess.TimeoutExpired:
        launch['error'] = 'Profile 程序在 180 秒内未完成，已结束本次所属进程。'
        print(launch['error'], flush=True)
        return 1
    finally:
        (report_dir / 'launch.json').write_text(json.dumps(launch, ensure_ascii=False, indent=2), encoding='utf-8')


if __name__ == '__main__':
    raise SystemExit(main())
