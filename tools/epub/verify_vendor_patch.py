"""核对本地 Windows 插件只改动已声明的生命周期路径。"""
from pathlib import Path
import hashlib
import json

ROOT=Path(__file__).resolve().parents[2]
target=ROOT/'third_party/flutter_inappwebview_windows'
manifest=json.loads((target/'upstream-manifest.json').read_text(encoding='utf-8'))
allowed={'lib/flutter_inappwebview_windows.dart','lib/src/webview_environment/webview_environment.dart',
    'lib/src/in_app_webview/custom_platform_view.dart',
    'windows/in_app_webview/in_app_webview_manager.h','windows/in_app_webview/in_app_webview_manager.cpp',
    'windows/in_app_webview/in_app_webview.h','windows/in_app_webview/in_app_webview.cpp'}
changed=[]
for entry in manifest['files']:
    path=target/entry['path']
    value=hashlib.sha256(path.read_bytes()).hexdigest()
    if value!=entry['sha256']:
        if entry['path'] not in allowed: raise SystemExit(f'范围外改动：{entry["path"]}')
        changed.append({'path':entry['path'],'sha256':value,'upstreamSha256':entry['sha256']})
if {entry['path'] for entry in changed}!=allowed: raise SystemExit('本地生命周期修正不完整')
(target/'patch-manifest.json').write_text(json.dumps({'version':'0.6.0-opennote-lifecycle-3',
    'files':changed},indent=2)+'\n',encoding='utf-8')
print('Windows 插件仅有 7 处已声明的生命周期源码改动。')
