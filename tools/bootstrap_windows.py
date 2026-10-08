"""从官方清单部署项目专用 Flutter 工具链，保留下载失败及哈希证据。"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import time
import urllib.error
import urllib.request
import uuid
import zipfile

from toolchain import resolve_flutter_sdk, save_toolchain

ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / '.local' / 'toolchains'
LOG = ROOT / '.local' / 'downloads.jsonl'


def fetch(url: str, target: Path) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_name(f'{target.name}.{uuid.uuid4().hex}.part')
    LOG.parent.mkdir(parents=True, exist_ok=True)
    try:
        for attempt, delay in enumerate((0, 2, 5, 10), 1):
            time.sleep(delay)
            try:
                request = urllib.request.Request(url, headers={'User-Agent': 'OpenNote-build/0.1'})
                with urllib.request.urlopen(request, timeout=120) as response, temporary.open('wb') as output:
                    size = int(response.headers.get('Content-Length', 0))
                    written = 0
                    last_report = time.monotonic()
                    while chunk := response.read(4 * 1024 * 1024):
                        output.write(chunk)
                        written += len(chunk)
                        if time.monotonic() - last_report > 10:
                            print(f'Download {written // 1048576}/{size // 1048576} MiB', flush=True)
                            last_report = time.monotonic()
                if written == 0 or (size and written != size):
                    raise OSError(f'Incomplete download: {written}/{size}')
                temporary.replace(target)
                return
            except (OSError, urllib.error.URLError) as error:
                status = getattr(error, 'code', None)
                entry = {'time': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
                         'url': url, 'attempt': attempt, 'type': type(error).__name__,
                         'message': str(error), 'status': status}
                with LOG.open('a', encoding='utf-8') as log:
                    log.write(json.dumps(entry, ensure_ascii=False) + '\n')
                print(json.dumps(entry, ensure_ascii=False), flush=True)
                if attempt == 4 or (status and 400 <= status < 500 and status not in (408, 429)):
                    raise
    finally:
        if temporary.exists():
            temporary.unlink()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--manifest-only', action='store_true')
    parser.add_argument('--update-lock', action='store_true', help='明确请求更新到官方当前稳定版')
    parser.add_argument('--sdk-dir', type=Path, default=resolve_flutter_sdk())
    args = parser.parse_args()
    manifest_path = ROOT / '.local' / 'flutter-releases.json'
    lock_path = ROOT / 'tools' / 'toolchain-lock.json'
    if lock_path.exists() and not args.update_lock and not args.manifest_only:
        release = json.loads(lock_path.read_text(encoding='utf-8'))['flutter']
        base_url = 'https://storage.googleapis.com/flutter_infra_release/releases'
    else:
        fetch('https://storage.googleapis.com/flutter_infra_release/releases/releases_windows.json', manifest_path)
        manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
        revision = manifest['current_release']['stable']
        release = next(item for item in manifest['releases'] if item['hash'] == revision and item.get('dart_sdk_arch', 'x64') == 'x64')
        base_url = manifest['base_url']
    print(json.dumps(release, ensure_ascii=False, indent=2), flush=True)
    if args.manifest_only:
        return
    sdk = args.sdk_dir.resolve()
    if not (sdk / 'bin' / 'flutter.bat').exists():
        archive = TOOLS / Path(release['archive']).name
        if not archive.exists():
            fetch(f"{base_url}/{release['archive']}", archive)
        digest = hashlib.file_digest(archive.open('rb'), 'sha256').hexdigest()
        if digest != release['sha256']:
            raise RuntimeError(f'Flutter SHA256 mismatch: {digest}')
        print('Verified SHA256; extracting Flutter SDK', flush=True)
        with zipfile.ZipFile(archive) as package:
            for entry in package.infolist():
                resolved = (sdk.parent / entry.filename).resolve()
                if not resolved.is_relative_to(sdk.parent.resolve()):
                    raise RuntimeError(f'Unsafe archive path: {entry.filename}')
            if sdk.name != 'flutter':
                raise RuntimeError('SDK 目录必须以 flutter 结尾，以保持官方归档布局')
            package.extractall(sdk.parent)
    sdk_version_file = sdk / 'bin' / 'cache' / 'flutter.version.json'
    if sdk_version_file.exists():
        actual = json.loads(sdk_version_file.read_text(encoding='utf-8'))
        if actual.get('frameworkRevision') != release['hash']:
            raise RuntimeError(f"SDK 版本不符：{sdk}。请选择另一个 SDK 目录，不修改其他项目的工具链。")
    save_toolchain(release, sdk)
    print(f'Flutter SDK ready: {sdk}', flush=True)


if __name__ == '__main__':
    main()
