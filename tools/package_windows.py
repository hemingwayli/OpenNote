"""构建产物的离线依赖与许可检查，生成可核验的 Windows 分发包。"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import uuid
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))
from toolchain import resolve_flutter_sdk
RELEASE = ROOT / 'build' / 'windows' / 'x64' / 'runner' / 'Release'
DIST = ROOT / 'dist'


def digest(path: Path) -> str:
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def write_source_archive() -> None:
    # 源码包遵守仓库忽略规则，模型与原生依赖通过固定哈希的准备工具取得。
    source_paths = subprocess.run(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'],
                                  cwd=ROOT, capture_output=True, check=True).stdout.decode('utf-8').split('\0')
    approved = json.loads((ROOT / 'packaging' / 'source-assets.json').read_text(encoding='utf-8'))
    assets = {entry['path']: entry for entry in approved['files']}
    document_extensions = {'.pdf', '.epub', '.png', '.jpg', '.jpeg', '.webp', '.gif', '.tif', '.tiff', '.bmp', '.ico', '.docx', '.otf'}
    source_entries = []
    root = ROOT.resolve()
    # 所有来源校验通过后才创建输出，避免后面的资产失败破坏已有合法包。
    for relative in sorted(set(source_paths)):
        if not relative:
            continue
        # 已跟踪文件不受 Git 忽略规则影响，仍须阻止本机配置进入公开包。
        name = Path(relative).name
        local_configuration = relative.startswith('.local/') or relative in {
            '.codex/config.toml', '.vscode/settings.json',
        }
        credentials = name == '.env' or (
            name.startswith('.env.') and not name.endswith('.example')
        )
        if local_configuration or credentials:
            raise RuntimeError(f'本机配置或凭据文件不得进入源码包: {relative}')
        source = ROOT / relative
        if not source.is_file():
            continue
        if not source.resolve().is_relative_to(root):
            raise RuntimeError(f'源码条目指向工作区外部: {relative}')
        if source.suffix.lower() in document_extensions:
            entry = assets.get(relative)
            if (entry is None or source.stat().st_size != entry['size']
                    or digest(source) != entry['sha256']):
                raise RuntimeError(f'未经来源声明或字节已改变的文档不得进入源码包: {relative}')
        source_entries.append((source, f'OpenNote/{relative}'))

    target = DIST / 'OpenNote-0.1.0-Source.zip'
    temporary = DIST / f'.{target.name}.{uuid.uuid4().hex}.tmp'
    created = False
    try:
        # 排他创建确保不会覆盖其他任务的临时文件；关闭全部句柄后再原子替换。
        with temporary.open('xb') as output:
            created = True
            with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED, compresslevel=5) as archive:
                for source, archive_path in source_entries:
                    archive.write(source, archive_path)
        temporary.replace(target)
    finally:
        if created:
            temporary.unlink(missing_ok=True)


def artifact_inventory() -> list[dict]:
    return [{'path': path.name, 'size': path.stat().st_size, 'sha256': digest(path)}
            for path in sorted(DIST.glob('OpenNote-0.1.0-*')) if path.is_file()]


def collect_licenses() -> None:
    target = RELEASE / 'licenses'
    target.mkdir(parents=True, exist_ok=True)
    config = json.loads((ROOT / '.dart_tool' / 'package_config.json').read_text(encoding='utf-8'))
    from urllib.parse import unquote, urlparse
    rows = []
    for package in config['packages']:
        if package['name'] == 'opennote':
            continue
        uri = package['rootUri']
        location = Path(unquote(urlparse(uri).path.lstrip('/'))) if uri.startswith('file:') else (ROOT / '.dart_tool' / uri).resolve()
        license_path = next((p for p in (location / 'LICENSE', location / 'LICENSE.txt', location / 'LICENSE.md') if p.is_file()), None)
        if license_path:
            shutil.copyfile(license_path, target / f"{package['name']}-LICENSE.txt")
            rows.append(f"| {package['name']} | `{location.name}` | `licenses/{package['name']}-LICENSE.txt` |")
    for name in ('OPENNOTE-PATCH.md','upstream-manifest.json','patch-manifest.json'):
        shutil.copyfile(ROOT / 'third_party/flutter_inappwebview_windows' / name,
                        target / f'flutter_inappwebview_windows-{name}')
    sdk = resolve_flutter_sdk(ROOT)
    shutil.copyfile(sdk / 'LICENSE', target / 'Flutter-LICENSE.txt')
    native = ROOT / 'native' / 'third_party'
    for package, candidates in {
        'ONNX-Runtime': [native / 'onnxruntime' / 'LICENSE'],
        'ONNX-Runtime-ThirdParty': [native / 'onnxruntime' / 'ThirdPartyNotices.txt'],
        'OpenCV': [native / 'opencv' / 'LICENSE', native / 'opencv' / 'build' / 'LICENSE'],
        'yaml-cpp': [native / 'yaml-cpp-0.8.0' / 'LICENSE'],
        'PP-OCR': [ROOT / 'assets' / 'ocr' / 'licenses' / 'PaddleOCR.txt'],
        'Source-Han-Sans-CN': [ROOT / 'assets' / 'fonts' / 'source-han-sans' / 'LICENSE.txt'],
        'epub.js-0.3.93': [ROOT / 'assets' / 'epub' / 'epubjs-LICENSE.txt'],
        'JSZip-3.10.1': [ROOT / 'assets' / 'epub' / 'jszip-LICENSE.txt'],
    }.items():
        source = next((p for p in candidates if p.is_file()), None)
        if source is None:
            raise RuntimeError(f'缺少分发许可: {package}')
        if package == 'PP-OCR':
            model_manifest = json.loads((ROOT / 'assets' / 'ocr' / 'manifest.json').read_text(encoding='utf-8'))
            license_entry = next(entry for entry in model_manifest['artifacts']
                                 if entry['name'] == 'PaddleOCR-LICENSE.txt')
            if source.stat().st_size != license_entry['size'] or digest(source) != license_entry['sha256']:
                raise RuntimeError('PaddleOCR 许可与固定来源的哈希不一致')
        shutil.copyfile(source, target / f'{package}-LICENSE.txt')
        rows.append(f'| {package} | 固定模型/原生依赖 | `licenses/{package}-LICENSE.txt` |')
    translation_license = ROOT / 'packaging' / 'windows' / 'ChineseSimplified-LICENSE.txt'
    if not translation_license.is_file():
        raise RuntimeError('缺少中文安装消息的分发许可；先运行 tools/prepare_inno_translation.py')
    shutil.copyfile(translation_license, target / 'Inno-ChineseSimplified-LICENSE.txt')
    rows.append('| Inno 简体中文消息 | translation-lock.json | `licenses/Inno-ChineseSimplified-LICENSE.txt` |')
    for directory in (ROOT / 'assets' / 'licenses', ROOT / 'assets' / 'ocr' / 'licenses'):
        if not directory.is_dir():
            raise RuntimeError(f'缺少原生组件许可目录: {directory}')
        shutil.copytree(directory, target / directory.parent.name, dirs_exist_ok=True)
    pdfium_lock = json.loads((ROOT / 'packaging' / 'windows' / 'pdfium-lock.json').read_text(encoding='utf-8'))
    if digest(RELEASE / 'pdfium.dll') != pdfium_lock['binarySha256']:
        raise RuntimeError('PDFium DLL 与许可锁定的二进制不一致')
    rows.append('| PDFium 与第三方组件 | chromium/7811, pdfium-lock.json | `licenses/assets/PDFium/` |')
    rows.append('| Microsoft VC++ Runtime | 应用本地 x64 CRT | `licenses/assets/Microsoft-VC-Runtime.txt` |')
    notice = '# 第三方分发许可\n\n本应用代码采用 Apache 2.0；组件与模型分别遵守原许可。Flutter 自带的依赖许可也可在应用许可页查看。\n\n| 组件 | 版本来源 | 许可文件 |\n| --- | --- | --- |\n' + '\n'.join(rows) + '\n'
    (ROOT / 'THIRD_PARTY_NOTICES.md').write_text(notice, encoding='utf-8')
    for name in ('LICENSE', 'NOTICE', 'THIRD_PARTY_NOTICES.md'):
        shutil.copyfile(ROOT / name, RELEASE / name)


def main() -> None:
    global DIST
    parser = argparse.ArgumentParser()
    parser.add_argument('--output-dir', type=Path, help='独立候选包目录；默认沿用 dist')
    parser.add_argument('--candidate', action='store_true', help='安装包使用独立产品身份，不覆盖正式安装或卸载登记')
    parser.add_argument('--iscc', type=Path)
    parser.add_argument('--vc-runtime', type=Path)
    parser.add_argument('--source-only', action='store_true', help='验证后更新源码与说明，不重新生成已验安装包')
    args = parser.parse_args()
    if args.candidate and args.output_dir is None:
        parser.error('候选包必须提供独立 --output-dir')
    if args.output_dir:
        DIST = args.output_dir.resolve()
        DIST.mkdir(parents=True, exist_ok=True)
    if args.source_only:
        manifest_path = DIST / 'release-manifest.json'
        metadata = json.loads(manifest_path.read_text(encoding='utf-8'))
        write_source_archive()
        metadata['artifacts'] = artifact_inventory()
        manifest_path.write_text(json.dumps(metadata, indent=2) + '\n', encoding='utf-8')
        print(json.dumps(metadata['artifacts'], indent=2), flush=True)
        return
    if args.vc_runtime is None:
        parser.error('分发打包必须提供 --vc-runtime')
    identity_path = RELEASE / 'OpenNote-build.json'
    if args.candidate:
        identity = json.loads(identity_path.read_text(encoding='utf-8'))
        if identity.get('candidate') is not True or any(digest(RELEASE/name)!=hash_value for name,hash_value in identity['files'].items()):
            raise RuntimeError('候选构建身份与当前产物不一致；先运行 tools/epub/build_candidate.py')
    elif identity_path.exists() and json.loads(identity_path.read_text(encoding='utf-8')).get('candidate') is True:
        raise RuntimeError('候选程序不能作为正式包分发；重新构建正式程序并清除候选构建标记')
    if args.iscc is None and list(DIST.glob('OpenNote-0.1.0-Windows-x64-Setup.exe')):
        raise RuntimeError('已有安装包；必须用 --iscc 同步生成，或用 --source-only 明确仅更新源码')
    for name in ('opennote.exe', 'flutter_windows.dll', 'opennote_ocr.dll', 'opennote_onnxruntime.dll', 'opencv_world4110.dll'):
        if not (RELEASE / name).is_file():
            raise RuntimeError(f'离线包缺少必需文件: {name}')
    if not (RELEASE / 'flutter_inappwebview_windows_plugin.dll').is_file():
        raise RuntimeError('候选包缺少 Windows EPUB WebView 插件')
    epub_manifest = json.loads((ROOT / 'assets/epub/manifest.json').read_text(encoding='utf-8'))
    for entry in epub_manifest['files']:
        asset = RELEASE / 'data/flutter_assets' / entry['path']
        if not asset.is_file() or asset.stat().st_size != entry['size'] or digest(asset) != entry['sha256']:
            raise RuntimeError(f"EPUB 离线资源不完整或 SHA256 不符: {entry['path']}")
    if not list((RELEASE / 'data' / 'ocr').rglob('*.onnx')):
        raise RuntimeError('离线包缺少 ONNX 模型')
    model_manifest = json.loads((ROOT / 'assets' / 'ocr' / 'manifest.json').read_text(encoding='utf-8'))
    for entry in model_manifest['files']:
        model_file = RELEASE / 'data' / 'ocr' / entry['path']
        if not model_file.is_file() or model_file.stat().st_size != entry['size'] or digest(model_file) != entry['sha256']:
            raise RuntimeError(f"OCR 模型包不完整或 SHA256 不符: {entry['path']}")
    shutil.copyfile(ROOT / 'assets' / 'ocr' / 'manifest.json', RELEASE / 'data' / 'ocr' / 'manifest.json')
    if not args.vc_runtime.is_dir():
        raise RuntimeError('VC++ 应用本地运行库目录不存在')
    for name in ('msvcp140.dll', 'msvcp140_1.dll', 'vcruntime140.dll', 'vcruntime140_1.dll', 'concrt140.dll'):
        if not (args.vc_runtime / name).is_file():
            raise RuntimeError(f'缺少必需的应用本地 VC++ 运行库: {name}')
    for source in args.vc_runtime.glob('*.dll'):
        shutil.copyfile(source, RELEASE / source.name)
    collect_licenses()
    DIST.mkdir(parents=True, exist_ok=True)
    archive_path = DIST / 'OpenNote-0.1.0-Windows-x64.zip'
    inventory = []
    with zipfile.ZipFile(archive_path, 'w', zipfile.ZIP_DEFLATED, compresslevel=5) as archive:
        for source in sorted(RELEASE.rglob('*')):
            # 原始 native_assets.json 仅供 Flutter tester 使用，包含构建机绝对路径。
            # 产品使用 data/flutter_assets/NativeAssetsManifest.json 的部署清单。
            if not source.is_file() or source.suffix == '.pdb' or source.name in {'onnxruntime.dll', 'native_assets.json'}:
                continue
            relative = source.relative_to(RELEASE).as_posix()
            archive.write(source, f'OpenNote/{relative}')
            inventory.append({'path': relative, 'size': source.stat().st_size, 'sha256': digest(source)})
    if args.iscc:
        subprocess.run([str(args.iscc), f'/DReleaseDir={RELEASE}', f'/DOutputDir={DIST}',
                        *(['/DCandidate=1'] if args.candidate else []),
                        str(ROOT / 'packaging' / 'windows' / 'opennote.iss')], check=True)
    write_source_archive()
    metadata = {'version': '0.1.0', 'candidate':args.candidate,'databaseVersion':11, 'files': inventory,
                'artifacts': artifact_inventory()}
    (DIST / 'release-manifest.json').write_text(json.dumps(metadata, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(metadata['artifacts'], indent=2), flush=True)


if __name__ == '__main__':
    main()
