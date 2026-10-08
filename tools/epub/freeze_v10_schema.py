"""从已保存的实施前源码导出固定 v10 SQL，供迁移测试长期复验。"""
from pathlib import Path
import subprocess
import sys

ROOT=Path(__file__).resolve().parents[2]
BASE=ROOT/'.local/verification/epub-pdf/baseline-snapshot'
TARGET=ROOT/'test/epub/fixtures/schema-v10.json'
TARGET.parent.mkdir(parents=True,exist_ok=True)
script=BASE/'export_v10_schema.dart'
script.write_text("import 'dart:convert';\nimport 'dart:io';\nimport 'lib/data/database.dart';\n"
    "void main(List<String> args) {if(currentDatabaseVersion!=10) throw StateError('需要 v10 原始源码');"
    "File(args.single).writeAsStringSync(jsonEncode(schemaStatements));}\n",encoding='utf-8')
sys.path.insert(0,str(ROOT/'tools/dev'))
from flutter_dev import DART,environment
raise SystemExit(subprocess.call([str(DART),'run',str(script),str(TARGET)],cwd=BASE,env=environment()))
