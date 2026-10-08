"""构建具有独立默认资料目录的候选程序，并绑定产物身份。"""
from pathlib import Path
import hashlib
import json
import sys

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tools/dev'))
from flutter_dev import FLUTTER,run_logged

directory=ROOT/'.local/verification/epub-pdf/candidate-build'
directory.mkdir(parents=True,exist_ok=True)
command=FLUTTER+['build','windows','--release','--no-pub','--dart-define=OPENNOTE_CANDIDATE=true']
code,_=run_logged(command,directory)
if code:
    raise SystemExit(code)
release=ROOT/'build/windows/x64/runner/Release'
files=['opennote.exe','data/app.so','data/flutter_assets/assets/epub/reader.js','flutter_inappwebview_windows_plugin.dll']
identity={'candidate':True,'databaseVersion':11,'defaultDataDirectoryName':'OpenNote-EPUB-PDF-Candidate',
          'files':{name:hashlib.sha256((release/name).read_bytes()).hexdigest() for name in files}}
(release/'OpenNote-build.json').write_text(json.dumps(identity,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
(directory/'report.json').write_text(json.dumps({'passed':True,'command':command,'identity':identity},ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
print('候选默认资料目录与产物身份已固定。',flush=True)
