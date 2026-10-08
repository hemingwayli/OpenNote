"""发布检查的隔离行为测试，不连接 GitHub、不改真实 Git 索引或资料库。"""
import contextlib
import hashlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import zipfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools/release'))
import audit_open_source as gate


class OpenSourceAuditTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='opennote-publish-test-')
        self.root = Path(self.temporary.name)
        self.git('init', '-q')
        self.git('config', 'user.name', 'OpenNote-Test')
        self.git('config', 'user.email', '0+test@users.noreply.github.com')
        for name in gate.REQUIRED:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('自产测试文档。\n', encoding='utf-8')
        (self.root / 'packaging/source-assets.json').write_text('{"files": []}\n', encoding='utf-8')
        (self.root / 'pubspec.yaml').write_text('name: opennote\nversion: 0.1.0+1\n', encoding='utf-8')
        (self.root / '.gitignore').write_text('.local/\ndist/\n', encoding='utf-8')

    def tearDown(self):
        self.temporary.cleanup()

    def git(self, *arguments):
        return subprocess.run(['git', '-C', str(self.root), *arguments], capture_output=True, check=True).stdout

    def invoke(self, *arguments):
        with contextlib.redirect_stdout(io.StringIO()) as output:
            code = gate.main(['--root', str(self.root), *arguments])
        summary = json.loads(output.getvalue())
        report = json.loads((self.root / summary['report']).read_text(encoding='utf-8'))
        return code, report

    def test_relative_home_module_is_not_a_personal_path(self):
        audit = gate.Audit(self.root)
        audit.scan('lib/app.dart', b"import 'ui/home/app_shell.dart';")
        self.assertFalse(audit.items)
        path = 'C:' + '/' + 'Users' + '/' + 'private-developer' + '/Desktop/config'
        audit.scan('docs/test.md', path.encode())
        self.assertIn('personal-user-path', {item['rule'] for item in audit.items})

    def test_batch_blob_reader_preserves_binary_bytes_empty_files_and_duplicate_objects(self):
        payload = b'\0binary\nheader-like blob 123\n\xff\xfe\0end\n'
        (self.root / 'binary.dat').write_bytes(payload)
        (self.root / 'same.dat').write_bytes(payload)
        (self.root / 'empty.txt').write_bytes(b'')
        self.git('add', '.')
        files = gate.select_files(self.root, 'index', 'HEAD')
        self.assertEqual(files['binary.dat'], payload)
        self.assertEqual(files['same.dat'], payload)
        self.assertEqual(files['empty.txt'], b'')
        oid = self.git('rev-parse', ':binary.dat').decode().strip()
        self.assertEqual(gate.git_blobs(self.root, [oid, oid]), {oid: payload})

    def test_batch_blob_reader_rejects_missing_truncated_and_wrong_type_objects(self):
        oid = 'a' * 40
        for payload in (f'{oid} missing\n'.encode(), f'{oid} tree 0\n\n'.encode(),
                        f'{oid} blob 3\na'.encode(), f'{oid} blob 0\n\nextra'.encode()):
            with self.subTest(payload=payload), mock.patch.object(gate, 'git', return_value=payload):
                with self.assertRaises(RuntimeError):
                    gate.git_blobs(self.root, [oid])

    def test_ascii_and_utf16_secrets_are_blocked_without_values_in_report(self):
        secret = 'ghp_' + 'Z' * 40
        for payload in [secret.encode(), ('\ufeff' + secret).encode('utf-16-le')]:
            audit = gate.Audit(self.root)
            audit.scan('test.txt', payload)
            self.assertIn('secret-format', {item['rule'] for item in audit.items})
            self.assertNotIn(secret, json.dumps(audit.items))

    def test_real_index_is_scanned_even_if_worktree_is_clean(self):
        secret = 'github_pat_' + 'Q' * 40
        readme = self.root / 'README.md'
        readme.write_text(secret, encoding='utf-8')
        self.git('add', '.')
        readme.write_text('安全的自产说明。', encoding='utf-8')
        code, report = self.invoke('--selection', 'index')
        self.assertEqual(code, 1)
        self.assertIn('secret-format', {item['rule'] for item in report['findings']})
        self.assertEqual(self.invoke('--selection', 'worktree')[0], 0)

    def test_tracked_ignored_configuration_is_blocked(self):
        path = self.root / '.local/config.toml'
        path.parent.mkdir()
        path.write_text('本地测试配置。', encoding='utf-8')
        self.git('add', '.')
        self.git('add', '-f', '.local/config.toml')
        code, report = self.invoke('--selection', 'index')
        self.assertEqual(code, 1)
        self.assertIn('private-or-generated-file', {item['rule'] for item in report['findings']})

    def test_force_tracked_private_instructions_are_blocked(self):
        path = self.root / 'AGENTS.md'
        path.write_text('本地私人执行规则。\n', encoding='utf-8')
        self.git('add', '.')
        self.git('add', '-f', 'AGENTS.md')
        code, report = self.invoke('--selection', 'index')
        self.assertEqual(code, 1)
        self.assertIn('private-or-generated-file', {item['rule'] for item in report['findings']})

    def test_deleted_historical_secret_still_blocks_final_commit(self):
        path = self.root / '.env'
        path.write_text('ghp_' + 'R' * 40, encoding='utf-8')
        self.git('add', '.')
        self.git('commit', '-qm', 'fixture')
        self.git('rm', '.env')
        self.git('commit', '-qm', 'remove fixture')
        code, report = self.invoke('--selection', 'commit')
        self.assertEqual(code, 1)
        self.assertIn('historical-private-file', {item['rule'] for item in report['findings']})
        self.assertIn('secret-format', {item['rule'] for item in report['findings']})
        self.assertEqual(report['historyCommits'], 2)

    def test_compressed_container_and_binary_machine_marker_are_checked(self):
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, 'w', zipfile.ZIP_DEFLATED) as archive:
            archive.writestr('OEBPS/content.xhtml', 'ghp_' + 'T' * 40)
        audit = gate.Audit(self.root)
        audit.scan('sample.epub', buffer.getvalue())
        self.assertIn('secret-format', {item['rule'] for item in audit.items})
        audit.scan('plugin.dll', b'MZ\0' + str(self.root).encode('utf-16-le'))
        self.assertIn('private-machine-or-deny-marker', {item['rule'] for item in audit.items})

    def test_passing_snapshot_cannot_be_reused_after_source_change(self):
        code, report = self.invoke()
        self.assertEqual(code, 0)
        (self.root / 'README.md').write_text('另一个安全的说明。', encoding='utf-8')
        code, newer = self.invoke('--expect-digest', report['snapshotDigest'])
        self.assertEqual(code, 1)
        self.assertIn('snapshot-changed-since-review', {item['rule'] for item in newer['findings']})

    def test_review_can_resolve_public_contact_but_not_secret(self):
        contact = 'public-maintainer@' + 'example.invalid'
        (self.root / 'README.md').write_text(contact, encoding='utf-8')
        code, report = self.invoke()
        self.assertEqual(code, 1)
        path = self.root / '.local/review.json'
        reasons = {item['id']: '隔离测试的公开联系地址，已确认不是真实私有账号。' for item in report['findings']}
        path.write_text(json.dumps(reasons, ensure_ascii=False), encoding='utf-8')
        self.assertEqual(self.invoke('--review-file', str(path))[0], 0)
        (self.root / 'README.md').write_text('ghp_' + 'W' * 40, encoding='utf-8')
        code, report = self.invoke()
        reasons.update({item['id']: '不能通过误报记录放行真正的秘密，本记录用于负向测试。' for item in report['findings']})
        path.write_text(json.dumps(reasons, ensure_ascii=False), encoding='utf-8')
        self.assertEqual(self.invoke('--review-file', str(path))[0], 1)

    def test_changed_source_asset_requires_new_distribution_evidence(self):
        image = self.root / 'docs/images/demo.png'
        image.parent.mkdir(parents=True)
        image.write_bytes(b'original')
        manifest = {'files': [{'path': 'docs/images/demo.png', 'size': 8,
                              'sha256': hashlib.sha256(b'original').hexdigest(),
                              'origin': 'generated', 'license': 'Apache-2.0',
                              'sourceStatement': '自产测试素材。', 'sourceReferences': ['test']}]}
        (self.root / 'packaging/source-assets.json').write_text(json.dumps(manifest), encoding='utf-8')
        self.assertEqual(self.invoke()[0], 0)
        image.write_bytes(b'changed')
        code, report = self.invoke()
        self.assertEqual(code, 1)
        self.assertIn('unapproved-or-changed-source-asset', {item['rule'] for item in report['findings']})

    def release_fixture(self, source_files):
        directory = self.root / 'dist'
        directory.mkdir()
        version = 'OpenNote-0.1.0-'
        (directory / (version + 'Windows-x64-Setup.exe')).write_bytes(b'MZ\0test-installer')
        with zipfile.ZipFile(directory / (version + 'Source.zip'), 'w') as archive:
            for name, data in source_files.items():
                archive.writestr('OpenNote/' + name, data)
        with zipfile.ZipFile(directory / (version + 'Windows-x64.zip'), 'w') as archive:
            for name in ['opennote.exe', 'flutter_windows.dll', 'pdfium.dll', 'opennote_ocr.dll',
                         'opennote_onnxruntime.dll', 'flutter_inappwebview_windows_plugin.dll',
                         'data/app.so', 'LICENSE', 'THIRD_PARTY_NOTICES.md']:
                archive.writestr('OpenNote/' + name, b'MZ\0test-payload')
            model = b'fixed-test-model'
            archive.writestr('OpenNote/data/ocr/test.onnx', model)
            archive.writestr('OpenNote/data/ocr/manifest.json', json.dumps({'files': [
                {'path': 'test.onnx', 'size': len(model), 'sha256': gate.sha(model)}]}))
        manifest = {'version': '0.1.0', 'candidate': False, 'artifacts': [
            {'path': path.name, 'size': path.stat().st_size, 'sha256': gate.sha(path.read_bytes())}
            for path in directory.iterdir()]}
        (directory / 'release-manifest.json').write_text(json.dumps(manifest), encoding='utf-8')
        return directory

    def test_release_source_archive_drift_is_detected(self):
        files = gate.select_files(self.root, 'worktree', 'HEAD')
        self.release_fixture(files)
        audit = gate.Audit(self.root)
        audit.release(files)
        self.assertFalse(audit.items)
        files['README.md'] = b'changed source'
        audit = gate.Audit(self.root)
        audit.release(files)
        self.assertIn('source-archive-drift', {item['rule'] for item in audit.items})

    def test_release_hash_mismatch_blocks_upload(self):
        files = gate.select_files(self.root, 'worktree', 'HEAD')
        directory = self.release_fixture(files)
        (directory / 'OpenNote-0.1.0-Windows-x64-Setup.exe').write_bytes(b'changed installer')
        audit = gate.Audit(self.root)
        audit.release(files)
        self.assertIn('release-manifest-hash-mismatch', {item['rule'] for item in audit.items})

    def test_short_chinese_private_marker_is_not_silently_skipped(self):
        marker = ''.join(['私', '密', '词'])
        profile = self.root / '.local/release-privacy.json'
        profile.parent.mkdir()
        profile.write_text(json.dumps({'denyStrings': [marker]}, ensure_ascii=False), encoding='utf-8')
        (self.root / 'README.md').write_text(marker, encoding='utf-8')
        code, report = self.invoke()
        self.assertEqual(code, 1)
        self.assertIn('private-machine-or-deny-marker', {item['rule'] for item in report['findings']})

    def test_upstream_license_contacts_do_not_hide_machine_markers(self):
        location = 'dist/package.zip!OpenNote/data/ocr/licenses/upstream.txt'
        audit = gate.Audit(self.root)
        audit.scan(location, ('upstream-author@' + 'example.invalid').encode())
        self.assertFalse(audit.items)
        audit.scan(location, str(self.root).encode())
        self.assertIn('private-machine-or-deny-marker', {item['rule'] for item in audit.items})

    def test_secret_in_commit_message_is_not_missed(self):
        self.git('add', '.')
        self.git('commit', '-qm', 'ghp_' + 'M' * 40)
        code, report = self.invoke('--selection', 'commit')
        self.assertEqual(code, 1)
        self.assertTrue(any(item['rule'] == 'secret-format' and item['location'].startswith('.git/commit-message/') for item in report['findings']))


if __name__ == '__main__':
    unittest.main()
