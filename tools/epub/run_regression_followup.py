"""只复验全量记录中的工作台失败，保留首轮报告，不重复已通过的大型容量测试。"""
from pathlib import Path
import argparse
import json
import re
import subprocess
import sys
import time

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tools/dev'))
from flutter_dev import FLUTTER,environment

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--failed-report',type=Path,required=True)
args=parser.parse_args()
rows=[json.loads(line) for line in (args.failed_report/'tests.jsonl').read_text(encoding='utf-8').splitlines()]
tests={row['test']['id']:row['test'] for row in rows if row['type']=='testStart'}
failed=[tests[row['testID']] for row in rows if row['type']=='error']
if not failed or any('workbench_test.dart' not in test.get('root_url',test.get('url','')) for test in failed):
    raise SystemExit('只接受全量中工作台用例的失败列表')
names=sorted({test['name'] for test in failed})
directory=ROOT/'.local/verification/epub-pdf'/f'followup-{time.time_ns()}'
directory.mkdir()
command=FLUTTER+['test','--no-pub','--concurrency=1','--reporter=expanded',
    '--file-reporter=json:'+str(directory/'tests.jsonl'),'--name','|'.join(re.escape(name) for name in names),
    'test/workspace/workbench_test.dart']
started=time.monotonic()
with (directory/'output.log').open('w',encoding='utf-8') as log:
    process=subprocess.Popen(command,cwd=ROOT,env=environment(),stdout=subprocess.PIPE,stderr=subprocess.STDOUT,
        text=True,encoding='utf-8',errors='replace')
    for line in process.stdout:
        print(line,end='',flush=True);log.write(line);log.flush()
    code=process.wait()
(directory/'report.json').write_text(json.dumps({'scope':'全量工作台失败复验','sourceReport':str(args.failed_report),
    'names':names,'command':command,'exitCode':code,'seconds':round(time.monotonic()-started,2),'passed':code==0},
    ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
print('复验报告：',directory/'report.json',flush=True)
raise SystemExit(code)
