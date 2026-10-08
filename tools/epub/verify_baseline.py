"""在实施前快照中复验失败合同，保留当前源码与用户资料。"""
from pathlib import Path
import json
import shutil
import subprocess
import sys
import zipfile

ROOT=Path(__file__).resolve().parents[2]
REPORT=ROOT/'.local/verification/epub-pdf'
TARGET=REPORT/'baseline-snapshot'
TARGET.mkdir(parents=True,exist_ok=True)
with zipfile.ZipFile(REPORT/'before-implementation.zip') as archive:
    for entry in archive.infolist():
        destination=(TARGET/entry.filename).resolve()
        if not destination.is_relative_to(TARGET.resolve()):
            raise ValueError('快照路径越界')
        if entry.is_dir():
            destination.mkdir(parents=True,exist_ok=True)
        else:
            destination.parent.mkdir(parents=True,exist_ok=True)
            destination.write_bytes(archive.read(entry))
shutil.copytree(ROOT/'assets/fonts',TARGET/'assets/fonts',dirs_exist_ok=True)
shutil.copytree(ROOT/'assets/epub',TARGET/'assets/epub',dirs_exist_ok=True)
sys.path.insert(0,str(ROOT/'tools/dev'))
from flutter_dev import FLUTTER,environment
with (REPORT/'baseline-failures.log').open('w',encoding='utf-8') as log:
    for args in [
        ['pub','get','--offline'],
        ['test','--no-pub','--concurrency=1','--reporter=expanded',
         '--file-reporter=json:'+str(REPORT/'baseline-tests.jsonl'),
         '--name','命令捕获调用时范围|关联创建自由主题与连线|同项目跨图移动保留身份|重挂拒绝环|中间插入主题动态纳入概要',
         'test/data/boundary_commands_test.dart','test/data/relationship_commands_test.dart',
         'test/data/repository_test.dart','test/data/summary_commands_test.dart'],
    ]:
        process=subprocess.Popen(FLUTTER+args,cwd=TARGET,env=environment(),stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,text=True,encoding='utf-8',errors='replace')
        for line in process.stdout:
            log.write(line);log.flush();print(line,end='',flush=True)
        result=process.wait()
        if args[0]=='pub' and result!=0:
            raise SystemExit(result)
    (REPORT/'baseline-result.json').write_text(json.dumps({'exitCode':result,'source':'before-implementation.zip'}),encoding='utf-8')
    raise SystemExit(result)
