"""在独立目录运行实际 Windows 分发程序，验证安装/重装/卸载的数据边界。"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import uuid
import winreg

ROOT = Path(__file__).resolve().parents[1]


def hidden_options() -> dict:
    startup = subprocess.STARTUPINFO()
    startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
    startup.wShowWindow = 0
    return {'startupinfo': startup, 'creationflags': subprocess.CREATE_NO_WINDOW}


def inventory(directory: Path) -> dict[str, str]:
    result = {}
    for path in directory.rglob('*'):
        if path.is_file():
            with path.open('rb') as source:
                result[path.relative_to(directory).as_posix()] = hashlib.file_digest(source, 'sha256').hexdigest()
    return result


def verify(executable: Path, data: Path, report: Path, cwd: Path, *, existing: bool = False) -> dict:
    report.parent.mkdir(parents=True, exist_ok=True)
    environment = dict(os.environ)
    environment['PATH'] = str(Path(os.environ['SystemRoot']) / 'System32')
    args = [str(executable), f'--data-dir={data}', f'--verify-fixtures={ROOT}', f'--verify-report={report}']
    if existing:
        args.append('--verify-existing')
    subprocess.run(args, cwd=cwd, env=environment, timeout=180, check=True, **hidden_options())
    result = json.loads(report.read_text(encoding='utf-8'))
    if not result.get('success'):
        raise RuntimeError(f'分发程序自检失败：{result}')
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--exe', type=Path, required=True)
    parser.add_argument('--installer', type=Path)
    parser.add_argument('--report-dir', type=Path)
    args = parser.parse_args()
    token = uuid.uuid4().hex
    report_dir = (args.report_dir or ROOT / '.local' / f'package-validation-{token}').resolve()
    report_dir.mkdir(parents=True, exist_ok=True)
    sandbox = Path(tempfile.mkdtemp(prefix='OpenNote-离线验证-'))
    result = {'scope': '本机 Windows 11 独立目录；不代表未安装开发工具的干净机器',
              'runtimePath': str(args.exe.resolve()), 'sandbox': str(sandbox), 'reports': {}}
    result['reports']['portable'] = verify(args.exe.resolve(), sandbox / 'portable-data', report_dir / 'portable.json', sandbox)
    if args.installer:
        registry_key = r'Software\Microsoft\Windows\CurrentVersion\Uninstall\{E7A94626-9D1F-46A1-87CF-0395DAE6A205}_is1'
        try:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, registry_key):
                raise RuntimeError('已有 OpenNote 安装记录；不接管已有安装，请使用独立测试用户或机器')
        except FileNotFoundError:
            pass
        install = sandbox / '程序 中文路径' / 'OpenNote'
        setup = args.installer.resolve()
        setup_args = [str(setup), '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', '/NOICONS', '/TASKS=',
                      f'/DIR={install}', f'/LOG={report_dir / "install.log"}']
        subprocess.run(setup_args, cwd=sandbox, timeout=180, check=True, **hidden_options())
        data = sandbox / 'installed-data'
        result['reports']['installed'] = verify(install / 'opennote.exe', data, report_dir / 'installed.json', sandbox)
        before = inventory(data)
        setup_args[-1] = f'/LOG={report_dir / "upgrade.log"}'
        subprocess.run(setup_args, cwd=sandbox, timeout=180, check=True, **hidden_options())
        if inventory(data) != before:
            raise RuntimeError('重装/升级改变了用户资料文件')
        result['reports']['afterUpgrade'] = verify(install / 'opennote.exe', data, report_dir / 'after-upgrade.json', sandbox, existing=True)
        before_uninstall = inventory(data)
        subprocess.run([str(install / 'unins000.exe'), '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART',
                        f'/LOG={report_dir / "uninstall.log"}'], cwd=sandbox, timeout=180, check=True, **hidden_options())
        if inventory(data) != before_uninstall:
            raise RuntimeError('卸载改变了用户资料文件')
        result.update({'installer': str(setup), 'upgradePreservesDataBytes': True, 'uninstallPreservesDataBytes': True,
                       'upgradeScope': 'v0.1.0 同版覆盖重装；未来版本迁移另需验证'})
    (report_dir / 'summary.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(result, ensure_ascii=False, indent=2), flush=True)


if __name__ == '__main__':
    main()
