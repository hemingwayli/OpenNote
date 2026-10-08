"""核验候选安装、便携运行、重装与卸载；正式安装和用户资料不作为测试目标。"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import uuid
import winreg
import zipfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
from verify_windows_package import hidden_options, inventory, verify

FORMAL_KEY = r'Software\Microsoft\Windows\CurrentVersion\Uninstall\{E7A94626-9D1F-46A1-87CF-0395DAE6A205}_is1'
CANDIDATE_KEY = r'Software\Microsoft\Windows\CurrentVersion\Uninstall\OpenNote-EPUB-PDF-Candidate_is1'


def digest(path: Path) -> str:
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def registration(key: str) -> dict | None:
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, key) as handle:
            values = {}
            for index in range(winreg.QueryInfoKey(handle)[1]):
                name, value, kind = winreg.EnumValue(handle, index)
                values[name] = [value.hex() if isinstance(value, bytes) else value, kind]
            return values
    except FileNotFoundError:
        return None


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--packages', type=Path, required=True)
    parser.add_argument('--book', type=Path, required=True)
    args = parser.parse_args()
    packages = args.packages.resolve()
    manifest = json.loads((packages / 'release-manifest.json').read_text(encoding='utf-8'))
    if manifest.get('candidate') is not True or manifest.get('databaseVersion') != 11:
        raise RuntimeError('只接受数据库 v11 的独立候选交付清单')
    for entry in manifest['artifacts']:
        path = packages / entry['path']
        if path.parent != packages or digest(path) != entry['sha256'] or path.stat().st_size != entry['size']:
            raise RuntimeError(f'候选产物哈希或边界不符：{path.name}')
    if registration(CANDIDATE_KEY) is not None:
        raise RuntimeError('存在候选产品的安装登记；不接管已有候选安装')
    formal_before = registration(FORMAL_KEY)
    formal_exe = Path(os.environ['LOCALAPPDATA']) / 'Programs/OpenNote/opennote.exe'
    formal_hash = digest(formal_exe) if formal_exe.exists() else None
    book_hash = digest(args.book)
    sandbox = ROOT / '.local/verification/epub-pdf' / f'candidate-{uuid.uuid4().hex}'
    sandbox.mkdir(parents=True)
    report = {'scope':'本机 Windows 11，系统 WebView2，独立目录；非干净机器或最低硬件验收',
              'success':False, 'bookSha256':book_hash, 'reports':{}}
    install = sandbox / '程序 中文路径/OpenNote'
    installed = False
    setup = packages / 'OpenNote-0.1.0-Windows-x64-Setup.exe'

    def epub(exe: Path, name: str) -> dict:
        output = sandbox / name
        output.mkdir()
        result_file = output / 'report.json'
        env = dict(os.environ)
        env['PATH'] = str(Path(os.environ['SystemRoot']) / 'System32')
        subprocess.run([str(exe), f'--data-dir={output / "library"}', f'--verify-fixtures={ROOT}',
                        f'--verify-epub-book={args.book.resolve()}', f'--verify-report={result_file}'],
                       env=env,cwd=sandbox,check=True,timeout=180,**hidden_options())
        result = json.loads(result_file.read_text(encoding='utf-8'))
        if result.get('success') is not True or result.get('sourceHash','').lower() != book_hash:
            raise RuntimeError(f'候选 EPUB 原生验收失败：{name}')
        if result.get('candidateBuild') is not True or result.get('defaultDataDirectoryName')!='OpenNote-EPUB-PDF-Candidate':
            raise RuntimeError('候选程序默认资料目录未与正式产品隔离')
        return result

    try:
        portable = sandbox / 'portable'
        with zipfile.ZipFile(packages / 'OpenNote-0.1.0-Windows-x64.zip') as archive:
            for name in archive.namelist():
                if not (portable / name).resolve().is_relative_to(portable.resolve()):
                    raise RuntimeError('便携归档路径越界')
            archive.extractall(portable)
        exe = portable / 'OpenNote/opennote.exe'
        expected = {entry['path']:entry['sha256'] for entry in manifest['files']}
        if inventory(exe.parent) != expected:
            raise RuntimeError('便携文件与候选清单不一致')
        report['reports']['portablePdfOcr'] = verify(exe,sandbox/'portable-pdf-data',sandbox/'portable-pdf.json',sandbox)
        report['reports']['portableEpub'] = epub(exe,'portable-epub')
        setup_args = [str(setup),'/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-','/NOICONS','/TASKS=',
                      f'/DIR={install}',f'/LOG={sandbox / "install.log"}']
        subprocess.run(setup_args,cwd=sandbox,check=True,timeout=180,**hidden_options())
        installed = True
        reg = registration(CANDIDATE_KEY)
        if not reg or Path(reg['InstallLocation'][0]).resolve() != install.resolve():
            raise RuntimeError('候选安装未登记到指定独立目录')
        actual = inventory(install)
        if any(actual.get(name)!=hash_value for name,hash_value in expected.items()):
            raise RuntimeError('安装文件与候选清单不一致')
        report['reports']['installedEpub'] = epub(install/'opennote.exe','installed-epub')
        before = inventory(sandbox/'installed-epub/library')
        setup_args[-1] = f'/LOG={sandbox / "reinstall.log"}'
        subprocess.run(setup_args,cwd=sandbox,check=True,timeout=180,**hidden_options())
        if inventory(sandbox/'installed-epub/library') != before:
            raise RuntimeError('候选重装改变了独立资料')
        report['reinstallPreservesDataBytes'] = True
        with zipfile.ZipFile(packages / 'OpenNote-0.1.0-Source.zip') as archive:
            epub_names = [name for name in archive.namelist() if name.lower().endswith('.epub')]
            allowed = json.loads((ROOT / 'packaging/source-assets.json').read_text(encoding='utf-8'))
            allowed_epubs = {'OpenNote/' + item['path'] for item in allowed['files'] if item['path'].endswith('.epub')}
            if set(epub_names) != allowed_epubs or len(epub_names) != len(allowed_epubs):
                raise RuntimeError('源码包 EPUB 不符合自产样本边界')
            if any('/.local/' in name for name in archive.namelist()):
                raise RuntimeError('源码包包含私有验证资料')
        report.update({'sourcePrivateAssetsExcluded':True,'fileCount':len(expected),'success':True})
    except Exception as error:
        report['error'] = f'{type(error).__name__}: {error}'
        raise
    finally:
        if installed:
            try:
                before = inventory(sandbox/'installed-epub/library')
                subprocess.run([str(install/'unins000.exe'),'/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',
                                f'/LOG={sandbox / "uninstall.log"}'],cwd=sandbox,check=True,timeout=180,**hidden_options())
                if inventory(sandbox/'installed-epub/library')!=before or registration(CANDIDATE_KEY) is not None:
                    raise RuntimeError('卸载资料边界或候选登记不符合约定')
                report['uninstallPreservesDataBytes']=True
            except Exception as cleanup_error:
                report['success']=False
                report['uninstallError']=str(cleanup_error)
        formal_unchanged=(registration(FORMAL_KEY)==formal_before and
                          (digest(formal_exe) if formal_exe.exists() else None)==formal_hash)
        report['formalInstallationUnchanged']=formal_unchanged
        report['sourceBookBytesUnchanged']=digest(args.book)==book_hash
        report['success']=report['success'] and formal_unchanged and report['sourceBookBytesUnchanged']
        (sandbox/'summary.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
        print(json.dumps({'report':str(sandbox/'summary.json'),'success':report['success']},ensure_ascii=False),flush=True)
    if report['success'] is not True:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
