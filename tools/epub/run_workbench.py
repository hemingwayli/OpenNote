"""串行启动真实混合工作台；原件只读，资料库与报告始终在 .local。"""
from pathlib import Path
import os
import subprocess
import sys
import time
import shutil

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tools/dev'))
from flutter_dev import FLUTTER,environment

if not os.environ.get('OPENNOTE_EPUB_REAL_BOOK'):
    raise SystemExit('必须提供 OPENNOTE_EPUB_REAL_BOOK')
directory=ROOT/'.local/verification/epub-pdf/workbench'
directory.mkdir(parents=True,exist_ok=True)
previous=directory/'report.json'
if previous.exists():
    shutil.copyfile(previous,directory/f'report-prior-{time.time_ns()}.json')
env=environment()
env['OPENNOTE_EPUB_PROBE_ROOT']=str(directory/f'library-{time.time_ns()}')
with (directory/f'run-{time.time_ns()}.log').open('w',encoding='utf-8') as log:
    process=subprocess.Popen(FLUTTER+['drive','-d','windows','--target=test_driver/epub_workbench_app.dart',
        '--driver=test_driver/epub_workbench_test.dart'],cwd=ROOT,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,
        text=True,encoding='utf-8',errors='replace')
    for line in process.stdout:
        print(line,end='',flush=True);log.write(line);log.flush()
    raise SystemExit(process.wait())
