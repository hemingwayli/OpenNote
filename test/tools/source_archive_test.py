"""使用真实 Git、自产资产与 ZIP 验证源码归档的失败边界。"""
from __future__ import annotations

import ctypes
from ctypes import wintypes
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile


PROJECT_ROOT = Path(__file__).resolve().parents[2]
ASSET_PATHS = (
    'tools/fixtures/pdf/native.pdf',
    'test/ocr/fixtures/bilingual.png',
)
ARCHIVE_NAME = 'OpenNote-0.1.0-Source.zip'

_spec = importlib.util.spec_from_file_location(
    'opennote_source_package_test', PROJECT_ROOT / 'tools' / 'package_windows.py'
)
assert _spec is not None and _spec.loader is not None
package_windows = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(package_windows)


class SourceArchiveTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix='opennote-source-archive-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'repo'
        self.root.mkdir()
        self.dist = self.root / 'dist'
        self.dist.mkdir()
        self.output = self.dist / ARCHIVE_NAME
        # 别的任务已经存在的临时文件不能被本次清理误删。
        self.foreign_temp = self.dist / f'.{ARCHIVE_NAME}.other-job.tmp'
        self.foreign_temp.write_bytes(b'other source archive job')
        self.patch_root = patch.object(package_windows, 'ROOT', self.root)
        self.patch_dist = patch.object(package_windows, 'DIST', self.dist)
        self.patch_root.start()
        self.addCleanup(self.patch_root.stop)
        self.patch_dist.start()
        self.addCleanup(self.patch_dist.stop)
        self.git_environment = patch.dict(os.environ, {
            'GIT_CONFIG_NOSYSTEM': '1',
            'GIT_CONFIG_GLOBAL': os.devnull,
            'GIT_TERMINAL_PROMPT': '0',
        })
        self.git_environment.start()
        self.addCleanup(self.git_environment.stop)
        self._git('init', '--quiet')
        (self.root / '.gitignore').write_text('dist/\nignored.pdf\n', encoding='utf-8')
        (self.root / 'README.md').write_text('中文源码归档回归\n', encoding='utf-8')
        self._git('add', '--', 'README.md')
        actual_manifest = json.loads(
            (PROJECT_ROOT / 'packaging' / 'source-assets.json').read_text(encoding='utf-8')
        )
        actual_assets = {entry['path']: entry for entry in actual_manifest['files']}
        self.approved = {'schemaVersion': 1, 'files': []}
        for relative in ASSET_PATHS:
            entry = dict(actual_assets[relative])
            self.assertEqual(entry['origin'], 'generated', '只允许自产回归资产')
            destination = self.root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(PROJECT_ROOT / relative, destination)
            self.approved['files'].append(entry)
        self.manifest_path = self.root / 'packaging' / 'source-assets.json'
        self.manifest_path.parent.mkdir()
        self._write_manifest()
        # 真实 Git 忽略规则仍应生效，不要求给被排除的文件添加资产声明。
        shutil.copyfile(PROJECT_ROOT / ASSET_PATHS[0], self.root / 'ignored.pdf')

    def _git(self, *arguments: str) -> None:
        subprocess.run(
            ['git', '-c', 'core.autocrlf=false', *arguments],
            cwd=self.root,
            check=True,
            capture_output=True,
        )

    def _write_manifest(self) -> None:
        self.manifest_path.write_text(
            json.dumps(self.approved, ensure_ascii=False, indent=2) + '\n',
            encoding='utf-8',
        )

    def _dist_bytes(self) -> dict[str, bytes]:
        return {entry.name: entry.read_bytes() for entry in self.dist.iterdir() if entry.is_file()}

    def _create_valid_archive(self) -> dict[str, bytes]:
        package_windows.write_source_archive()
        with zipfile.ZipFile(self.output) as archive:
            self.assertIsNone(archive.testzip())
            self.assertEqual(set(archive.namelist()), {
                'OpenNote/.gitignore',
                'OpenNote/README.md',
                'OpenNote/packaging/source-assets.json',
                *(f'OpenNote/{relative}' for relative in ASSET_PATHS),
            })
            for relative in ASSET_PATHS:
                self.assertEqual(archive.read(f'OpenNote/{relative}'), (self.root / relative).read_bytes())
        self.assertEqual(self.foreign_temp.read_bytes(), b'other source archive job')
        self.assertEqual({entry.name for entry in self.dist.iterdir()}, {
            ARCHIVE_NAME, self.foreign_temp.name,
        })
        return self._dist_bytes()

    def _assert_validation_rejection(self, before: dict[str, bytes], relative: str) -> None:
        with self.assertRaisesRegex(RuntimeError, re.escape(relative)):
            package_windows.write_source_archive()
        self.assertEqual(self._dist_bytes(), before, '旧合法 ZIP 与其他任务临时文件必须逐字节保留')
        self.assertEqual({entry.name for entry in self.dist.iterdir()}, set(before), '失败不得遗留本次临时文件')

    def test_valid_archive_uses_real_git_and_generated_pdf_png(self) -> None:
        self._create_valid_archive()

    def test_tracked_local_configuration_is_rejected_before_replacing_archive(self) -> None:
        before = self._create_valid_archive()
        relative = '.codex/config.toml'
        configuration = self.root / relative
        configuration.parent.mkdir()
        configuration.write_text('cwd = "private-workspace"\n', encoding='utf-8')
        self._git('add', '--', relative)
        self._assert_validation_rejection(before, relative)

    def test_tracked_environment_credentials_are_rejected(self) -> None:
        before = self._create_valid_archive()
        relative = '.env.local'
        (self.root / relative).write_text('LOCAL_ONLY=value\n', encoding='utf-8')
        self._git('add', '--', relative)
        self._assert_validation_rejection(before, relative)

    def test_same_bytes_with_wrong_declared_size_are_rejected(self) -> None:
        before = self._create_valid_archive()
        entry = self.approved['files'][0]
        original_bytes = (self.root / entry['path']).read_bytes()
        entry['size'] += 1
        self._write_manifest()
        self.assertEqual((self.root / entry['path']).read_bytes(), original_bytes)
        self._assert_validation_rejection(before, entry['path'])

    def test_undeclared_asset_failure_preserves_previous_zip(self) -> None:
        before = self._create_valid_archive()
        relative = 'zz-undeclared.pdf'
        shutil.copyfile(PROJECT_ROOT / ASSET_PATHS[0], self.root / relative)
        self._assert_validation_rejection(before, relative)

    def test_wrong_hash_failure_preserves_previous_zip(self) -> None:
        before = self._create_valid_archive()
        entry = self.approved['files'][1]
        entry['sha256'] = '0' * 64
        self._write_manifest()
        self._assert_validation_rejection(before, entry['path'])

    def test_directory_link_escape_preserves_previous_zip_and_external_file(self) -> None:
        before = self._create_valid_archive()
        outside = Path(self.temp.name) / 'repo-outside'
        outside.mkdir()
        external_file = outside / 'export.txt'
        external_file.write_text('只读外部文件\n', encoding='utf-8')
        external_bytes = external_file.read_bytes()
        link = self.root / 'zz-linked'
        link.mkdir()
        tracked_file = link / external_file.name
        tracked_file.write_text('原本的内部文件\n', encoding='utf-8')
        self._git('add', '--', tracked_file.relative_to(self.root).as_posix())
        tracked_file.unlink()
        link.rmdir()
        _create_directory_link(link, outside)
        try:
            self.assertFalse(tracked_file.resolve().is_relative_to(self.root.resolve()))
            self._assert_validation_rejection(before, tracked_file.relative_to(self.root).as_posix())
            self.assertEqual(external_file.read_bytes(), external_bytes)
        finally:
            # Windows junction 用 rmdir 只删除链接入口，不递归访问链接目标。
            if os.name == 'nt':
                link.rmdir()
            else:
                link.unlink()

    def test_real_file_disappearance_during_zip_write_keeps_previous_archive(self) -> None:
        before = self._create_valid_archive()
        late_asset = self.root / ASSET_PATHS[0]
        original_write = zipfile.ZipFile.write

        def remove_asset_then_write(archive: zipfile.ZipFile, filename, *args, **kwargs):
            # 仅删除临时库副本；真正 ZipFile.write 的 stat/open 必须实际失败。
            if Path(filename) == late_asset:
                late_asset.unlink()
            return original_write(archive, filename, *args, **kwargs)

        with patch.object(zipfile.ZipFile, 'write', remove_asset_then_write):
            with self.assertRaises(FileNotFoundError):
                package_windows.write_source_archive()
        self.assertFalse(late_asset.exists())
        self.assertEqual(self._dist_bytes(), before, '写 ZIP 中途失败必须保留旧合法包')
        self.assertEqual({entry.name for entry in self.dist.iterdir()}, set(before))


def _create_directory_link(link: Path, target: Path) -> None:
    if os.name != 'nt':
        link.symlink_to(target, target_is_directory=True)
        return
    # NTFS junction 无需管理员 symlink 权限；用真实文件系统重解析点覆盖越界场景。
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.CreateFileW.argtypes = [
        wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, ctypes.c_void_p,
        wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE,
    ]
    kernel.CreateFileW.restype = wintypes.HANDLE
    kernel.DeviceIoControl.argtypes = [
        wintypes.HANDLE, wintypes.DWORD, ctypes.c_void_p, wintypes.DWORD,
        ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(wintypes.DWORD), ctypes.c_void_p,
    ]
    kernel.DeviceIoControl.restype = wintypes.BOOL
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel.CloseHandle.restype = wintypes.BOOL
    substitute = ('\\??\\' + str(target.resolve())).encode('utf-16-le')
    printable = str(target.resolve()).encode('utf-16-le')
    path_buffer = substitute + b'\0\0' + printable + b'\0\0'
    data = struct.pack(
        '<IHHHHHH', 0xA0000003, len(path_buffer) + 8, 0,
        0, len(substitute), len(substitute) + 2, len(printable),
    ) + path_buffer
    link.mkdir()
    handle = kernel.CreateFileW(str(link), 0x40000000, 0, None, 3, 0x02200000, None)
    if handle == ctypes.c_void_p(-1).value:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        returned = wintypes.DWORD()
        buffer = ctypes.create_string_buffer(data)
        if not kernel.DeviceIoControl(
            handle, 0x000900A4, buffer, len(data), None, 0, ctypes.byref(returned), None,
        ):
            raise ctypes.WinError(ctypes.get_last_error())
    finally:
        kernel.CloseHandle(handle)


if __name__ == '__main__':
    unittest.main()
