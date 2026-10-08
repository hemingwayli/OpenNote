"""复制已锁定的 Windows 插件源码，供项目修正并核验关闭协议；不修改 Pub 缓存。"""
from pathlib import Path
from urllib.parse import urlparse,unquote
import hashlib
import json
import shutil

ROOT=Path(__file__).resolve().parents[2]
config=json.loads((ROOT/'.dart_tool/package_config.json').read_text(encoding='utf-8'))
entry=next(p for p in config['packages'] if p['name']=='flutter_inappwebview_windows')
source=Path(unquote(urlparse(entry['rootUri']).path).lstrip('/'))
target=ROOT/'third_party/flutter_inappwebview_windows'
if source.name!='flutter_inappwebview_windows-0.6.0' or target.exists():
    raise SystemExit('必须从官方 0.6.0 缓存复制到尚未存在的项目目录')
rows=[]
for relative in ('lib','windows','LICENSE','pubspec.yaml','README.md','CHANGELOG.md'):
    original=source/relative
    if original.is_dir(): shutil.copytree(original,target/relative)
    else:
        target.mkdir(parents=True,exist_ok=True);shutil.copyfile(original,target/relative)
for path in sorted(target.rglob('*')):
    if path.is_file():
        rows.append({'path':path.relative_to(target).as_posix(),'size':path.stat().st_size,
            'sha256':hashlib.sha256(path.read_bytes()).hexdigest()})
(target/'upstream-manifest.json').write_text(json.dumps({'package':'flutter_inappwebview_windows',
    'version':'0.6.0','source':'https://pub.dev/packages/flutter_inappwebview_windows/versions/0.6.0',
    'files':rows},indent=2)+'\n',encoding='utf-8')
print(f'官方插件源码已隔离复制：{len(rows)} 文件，{sum(r["size"] for r in rows)} 字节。')
