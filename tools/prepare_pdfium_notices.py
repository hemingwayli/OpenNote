"""收集与锁定 PDFium Windows 二进制完全对应的分发许可。"""
from __future__ import annotations

import hashlib
import json
from pathlib import PurePosixPath
import tarfile

from bootstrap_windows import ROOT, fetch

URL = 'https://github.com/bblanchon/pdfium-binaries/releases/download/chromium%2F7811/pdfium-win-x64.tgz'
LOCK = ROOT / 'packaging' / 'windows' / 'pdfium-lock.json'


def main() -> None:
    archive = ROOT / '.local' / 'pdfium-win-x64-7811.tgz'
    if not archive.is_file():
        fetch(URL, archive)
    with archive.open('rb') as source:
        archive_hash = hashlib.file_digest(source, 'sha256').hexdigest()
    old = json.loads(LOCK.read_text(encoding='utf-8')) if LOCK.exists() else {}
    if old and old['archiveSha256'] != archive_hash:
        raise RuntimeError('PDFium 归档与固定 SHA256 不符')
    target = ROOT / 'assets' / 'licenses' / 'PDFium'
    notices = []
    with tarfile.open(archive, 'r:gz') as package:
        dll = package.extractfile('bin/pdfium.dll')
        if dll is None:
            raise RuntimeError('PDFium 归档缺少 DLL')
        binary_hash = hashlib.sha256(dll.read()).hexdigest()
        for item in package.getmembers():
            path = PurePosixPath(item.name)
            if not item.isfile() or not (path.parts[0] == 'licenses' or path.name.startswith('LICENSE')):
                continue
            if path.is_absolute() or '..' in path.parts:
                raise RuntimeError(f'非法许可路径: {path}')
            destination = target.joinpath(*path.parts)
            destination.parent.mkdir(parents=True, exist_ok=True)
            content = package.extractfile(item).read()
            destination.write_bytes(content)
            notices.append(str(path))
    if not notices:
        raise RuntimeError('PDFium 归档缺少第三方许可')
    LOCK.write_text(json.dumps({'url': URL, 'release': 'chromium/7811', 'archiveSha256': archive_hash,
                               'binarySha256': binary_hash, 'notices': notices}, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'binarySha256': binary_hash, 'noticeCount': len(notices)}, indent=2), flush=True)


if __name__ == '__main__':
    main()
