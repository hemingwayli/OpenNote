"""用固定 Flutter SDK 串行构建并运行独立 EPUB 原生探针。"""
from pathlib import Path
import subprocess
import sys
import time
import json

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools/dev'))
from flutter_dev import FLUTTER, environment

directory = ROOT / '.local/verification/epub-pdf/native-probe'
directory.mkdir(parents=True, exist_ok=True)
for attempt, delay in enumerate((0,2,5,10), 1):
    if delay:
        time.sleep(delay)
    lines = []
    with (directory / f'run-{time.time_ns()}-{attempt}.log').open('w',encoding='utf-8') as log:
        process = subprocess.Popen(FLUTTER + ['run','-d','windows','-t','lib/dev/epub_probe.dart'],
            cwd=ROOT,env=environment(),stdout=subprocess.PIPE,stderr=subprocess.STDOUT,
            text=True,encoding='utf-8',errors='replace')
        for line in process.stdout:
            print(line,end='',flush=True)
            log.write(line);log.flush();lines.append(line)
        result = process.wait()
    output = ''.join(lines)
    if 'EPUB_NATIVE_PROBE_PASSED' in output:
        rows=json.loads((directory/'report.json').read_text(encoding='utf-8'))
        raise SystemExit(0 if rows and all(row.get('status')=='passed' for row in rows) else 1)
    if 'EPUB 原生探针失败' in output or result==0:
        raise SystemExit(1)
    if attempt == 4 or not any(term in output.lower() for term in ('socket','timeout','connection','handshake','502','503','429')):
        raise SystemExit(result)
