"""保留实施前源码快照，取得并校验固定版本的官方 EPUB 资源。"""
from __future__ import annotations

import argparse
import base64
import hashlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tarfile
import time
import urllib.error
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[2]
REPORT = ROOT / '.local/verification/epub-pdf'


def fetch(url: str) -> bytes:
    REPORT.mkdir(parents=True, exist_ok=True)
    for attempt, delay in enumerate((0, 2, 5, 10), 1):
        if delay:
            time.sleep(delay)
        try:
            with urllib.request.urlopen(url, timeout=60) as response:
                return response.read()
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            with (REPORT / 'download-errors.jsonl').open('a', encoding='utf-8') as log:
                log.write(json.dumps({'url': url, 'attempt': attempt,
                    'error': f'{type(error).__name__}: {error}'}) + '\n')
            print(f'下载失败 {attempt}: {url}: {error}', flush=True)
            if isinstance(error, urllib.error.HTTPError) and error.code not in (408, 429) and error.code < 500:
                raise
            if attempt == 4:
                raise
    raise AssertionError('不可达')


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--pub', action='store_true')
    args = parser.parse_args()
    REPORT.mkdir(parents=True, exist_ok=True)
    snapshot = REPORT / 'before-implementation.zip'
    if not snapshot.exists():
        with zipfile.ZipFile(snapshot, 'w', zipfile.ZIP_DEFLATED) as archive:
            for directory in ('lib', 'docs', 'test', 'tools', 'packaging', 'windows'):
                for path in (ROOT / directory).rglob('*'):
                    if path.is_file() and not any(part in ('build', '__pycache__', 'ephemeral') for part in path.parts):
                        archive.write(path, path.relative_to(ROOT).as_posix())
            for name in ('pubspec.yaml', 'pubspec.lock'):
                archive.write(ROOT / name, name)
        print(f'源码快照: {snapshot}', flush=True)
    assets = ROOT / 'assets/epub'
    assets.mkdir(parents=True, exist_ok=True)
    entries = []
    for name, version, filename in (('epubjs', '0.3.93', 'epub.min.js'), ('jszip', '3.10.1', 'jszip.min.js')):
        metadata = json.loads(fetch(f'https://registry.npmjs.org/{name}/{version}'))
        data = fetch(metadata['dist']['tarball'])
        integrity = metadata['dist']['integrity']
        algorithm, digest = integrity.split('-', 1)
        if base64.b64encode(hashlib.new(algorithm, data).digest()).decode() != digest:
            raise ValueError(f'{name} 包完整性校验失败')
        (REPORT / f'{name}-{version}.tgz').write_bytes(data)
        with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as archive:
            license_member = next((path for path in archive.getnames()
                if path.lower() in ('package/license', 'package/license.md', 'package/license.txt', 'package/license.markdown')), None)
            if license_member is None:
                raise ValueError(f'{name} 缺少许可证: {archive.getnames()[:20]}')
            selected = [f'package/dist/{filename}', license_member]
            for member in selected:
                resource = archive.extractfile(member)
                if resource is None:
                    raise ValueError(f'缺少资产 {member}')
                content = resource.read()
                target = assets / (filename if member.endswith('.js') else f'{name}-LICENSE.txt')
                target.write_bytes(content)
                entries.append({'path': target.relative_to(ROOT).as_posix(), 'size': len(content),
                    'sha256': hashlib.sha256(content).hexdigest(), 'package': name, 'version': version,
                    'source': metadata['dist']['tarball'], 'integrity': integrity, 'license': metadata['license']})
    (assets / 'manifest.json').write_text(json.dumps({'files': entries}, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print('官方资源已校验并保存。', flush=True)
    if args.pub:
        sys.path.insert(0, str(ROOT / 'tools/dev'))
        from flutter_dev import FLUTTER, environment
        for attempt, delay in enumerate((0, 2, 5, 10), 1):
            if delay:
                time.sleep(delay)
            result = subprocess.run(FLUTTER + ['pub', 'get'], cwd=ROOT, env=environment(),
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, encoding='utf-8', errors='replace')
            (REPORT / f'pub-get-{attempt}.log').write_text(result.stdout, encoding='utf-8')
            print(result.stdout, flush=True)
            if result.returncode == 0:
                break
            if attempt == 4 or not any(term in result.stdout.lower() for term in ('socket', 'timeout', 'connection', 'handshake', '502', '503', '429')):
                raise SystemExit(result.returncode)


if __name__ == '__main__':
    main()
