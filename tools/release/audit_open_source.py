"""OpenNote 发布前的只读自动检查；秘密值不进入输出，语义与素材须人工审查。"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
from urllib.parse import unquote
import zipfile

REQUIRED = ('README.md', 'LICENSE', 'NOTICE', 'THIRD_PARTY_NOTICES.md',
            'CONTRIBUTING.md', 'SECURITY.md', 'CHANGELOG.md', 'docs/privacy.md',
            'docs/build-windows.md', 'docs/testing.md', 'packaging/source-assets.json')
ASSETS = {'.pdf', '.epub', '.png', '.jpg', '.jpeg', '.webp', '.gif', '.bmp',
          '.tif', '.tiff', '.ico', '.docx', '.otf'}
VENDORS = ('assets/licenses/', 'assets/ocr/licenses/', 'assets/epub/', 'third_party/')
SECRET = re.compile(rb'(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-(?:proj-)?[A-Za-z0-9_-]{24,}|AKIA[A-Z0-9]{16}|AKID[A-Za-z0-9]{20,}|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----)')
PERSONAL = re.compile(r'(?i)(?:[a-z]:[\\/]+Users[\\/]+([^\\/\s\"<>]+)|(?<![A-Za-z0-9_.])/(?:Users|home)/([^/\s\"<>]+))')
CREDENTIAL = re.compile(r'''(?i)\b(?:api[_-]?key|access[_-]?token|secret[_-]?key|password|client[_-]?secret)["']?\s*[=:]\s*["']([^"'\r\n]{8,})["']''')
EMAIL = re.compile(r'[A-Za-z0-9_.+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}')


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def marker_length_ok(value: str) -> bool:
    return len(value) >= 4 or (len(value) >= 2 and any(ord(character) > 127 for character in value))


def git(root: Path, *args: str, required: bool = True, input_bytes: bytes | None = None) -> bytes:
    result = subprocess.run(['git', '-C', str(root), *args], input=input_bytes, capture_output=True)
    if required and result.returncode:
        raise RuntimeError('Git 读取失败：' + args[0])
    return result.stdout if result.returncode == 0 else b''


def git_blobs(root: Path, identifiers: list[str]) -> dict[str, bytes]:
    # 批量读取同样的不可变对象；避免 Windows 为每个文件启动一个 Git 进程。
    identifiers = list(dict.fromkeys(identifiers))
    if not identifiers:
        return {}
    if any(not re.fullmatch(r'[0-9a-f]{40}|[0-9a-f]{64}', oid) for oid in identifiers):
        raise RuntimeError('Git 对象标识无效')
    payload = git(root, 'cat-file', '--batch', input_bytes=('\n'.join(identifiers) + '\n').encode('ascii'))
    files = {}
    offset = 0
    for expected in identifiers:
        end = payload.find(b'\n', offset)
        fields = payload[offset:end].split() if end >= 0 else []
        if len(fields) != 3 or fields[0] != expected.encode('ascii') or fields[1] != b'blob' or not fields[2].isdigit():
            raise RuntimeError('Git 批量对象头不符合预期')
        size = int(fields[2])
        start = end + 1
        offset = start + size
        if offset >= len(payload) or payload[offset:offset + 1] != b'\n':
            raise RuntimeError('Git 批量对象内容不完整')
        files[expected] = payload[start:offset]
        offset += 1
    if offset != len(payload):
        raise RuntimeError('Git 批量对象包含非预期尾部')
    return files


def private_file(relative: str) -> bool:
    relative = relative.lower()
    path = PurePosixPath(relative)
    name = path.name.lower()
    return (relative.startswith(('.local/', '.codex/', 'build/', 'dist/', '.dart_tool/', 'backups/'))
            or relative == '.vscode/settings.json'
            or name == '.env' or (name.startswith('.env.') and not name.endswith('.example'))
            or path.suffix.lower() in {'.pem', '.key', '.pdb', '.db', '.sqlite', '.log'}
            or name in {'id_rsa', 'id_ed25519', 'native_assets.json', 'agents.md', 'agent.md', 'agents.override.md'}
            or name.endswith(('.backup.zip', '.db-wal', '.db-shm')))


def upstream(location: str) -> bool:
    if location.startswith('.git/history/'):
        location = location.split('/', 3)[-1]
    if '!' in location:
        location = location.split('!', 1)[-1].removeprefix('OpenNote/')
    return location.startswith(VENDORS + ('licenses/', 'data/ocr/licenses/')) or location.endswith('.isl')


class Audit:
    def __init__(self, root: Path, deny_strings: list[str] | None = None):
        self.root = root.resolve()
        self.items: list[dict] = []
        self.inventory: dict[str, str] = {}
        self.history_blobs = 0
        self.history_commits = 0
        markers = [str(self.root), str(self.root).replace('\\', '/'), str(Path.home()), str(Path.home()).replace('\\', '/')]
        markers.extend(deny_strings or [])
        self.markers = tuple(value for value in set(markers) if marker_length_ok(value))
        username = Path.home().name
        self.account_marker = re.compile(r'(?<![\w.])' + re.escape(username) + r'(?![\w.])') if username.isdigit() and len(username) >= 4 else None

    def finding(self, rule: str, location: str, data: bytes = b'', offset: int = 0, severity: str = 'block'):
        identity = sha((rule + '\0' + location + '\0' + str(offset) + '\0' + sha(data)).encode('utf-8'))
        item = {'id': identity, 'rule': rule, 'location': location,
                'line': data[:offset].count(b'\n') + 1 if data else 0,
                'severity': severity, 'contentSha256': sha(data)}
        if not any(old['id'] == identity for old in self.items):
            self.items.append(item)

    def scan(self, location: str, data: bytes, *, inspect_container: bool = True):
        for value in self.markers:
            for encoding in ('utf-8', 'utf-16-le'):
                position = data.lower().find(value.encode(encoding).lower())
                if position >= 0:
                    self.finding('private-machine-or-deny-marker', location, data, position)
        for match in SECRET.finditer(data):
            self.finding('secret-format', location, data, match.start())
        text = None
        if data.startswith((b'\xff\xfe', b'\xfe\xff')):
            text = data.decode('utf-16')
        elif PurePosixPath(location).suffix.lower() not in ASSETS and b'\0' not in data[:8192]:
            try:
                text = data.decode('utf-8-sig')
            except UnicodeDecodeError:
                # 上游许可可能使用单字节编码；ASCII 路径／凭据规则仍可审查。
                if upstream(location):
                    text = data.decode('latin-1')
                else:
                    self.finding('unknown-text-encoding', location, data, severity='review')
        if text is not None:
            if self.account_marker:
                for match in self.account_marker.finditer(text):
                    self.finding('private-local-account-marker', location, data, len(text[:match.start()].encode('utf-8')))
            if data.startswith((b'\xff\xfe', b'\xfe\xff')):
                for match in SECRET.finditer(text.encode('utf-8')):
                    self.finding('secret-format', location, data, match.start())
            for match in PERSONAL.finditer(text):
                user = match.group(1) or match.group(2)
                if user.lower() not in {'public', 'default', 'runner'} and not user.startswith(('{', '$')):
                    self.finding('personal-user-path', location, data, len(text[:match.start()].encode('utf-8')))
            for match in CREDENTIAL.finditer(text):
                value = match.group(1).lower()
                if not value.startswith(('<', '${', 'your_', 'example', 'dummy', 'test-')):
                    self.finding('credential-literal-review', location, data, len(text[:match.start()].encode('utf-8')), 'review')
            if not upstream(location):
                for match in EMAIL.finditer(text):
                    if not match.group().lower().endswith('@users.noreply.github.com'):
                        self.finding('public-contact-review', location, data, len(text[:match.start()].encode('utf-8')), 'review')
        if inspect_container and zipfile.is_zipfile(io.BytesIO(data)):
            with zipfile.ZipFile(io.BytesIO(data)) as archive:
                for entry in archive.infolist():
                    if entry.is_dir():
                        continue
                    name = entry.filename
                    if PurePosixPath(name).is_absolute() or '..' in PurePosixPath(name).parts or entry.flag_bits & 1 or private_file(name):
                        self.finding('unsafe-or-encrypted-archive', location, data)
                        continue
                    if entry.file_size > 128 * 1024 * 1024:
                        self.finding('oversized-archive-entry-review', location + '!' + name, severity='review')
                        continue
                    self.scan(location + '!' + name, archive.read(entry), inspect_container=False)

    def source(self, files: dict[str, bytes]):
        for relative, data in files.items():
            self.inventory[relative] = sha(data)
            if private_file(relative):
                self.finding('private-or-generated-file', relative, data)
            if len(data) >= 100 * 1024 * 1024:
                self.finding('git-file-too-large', relative, data)
            self.scan(relative, data)
            if relative.endswith('.json'):
                try:
                    json.loads(data.decode('utf-8-sig'))
                except (ValueError, UnicodeDecodeError):
                    self.finding('invalid-public-json', relative, data)
        for relative in REQUIRED:
            if not files.get(relative):
                self.finding('missing-open-source-document', relative)
        manifest = json.loads(files.get('packaging/source-assets.json', b'{"files":[]}').decode('utf-8-sig'))
        assets = {item['path']: item for item in manifest['files']}
        for relative, data in files.items():
            if PurePosixPath(relative).suffix.lower() in ASSETS:
                item = assets.get(relative)
                if not item or len(data) != item['size'] or sha(data) != item['sha256'] or not all(item.get(key) for key in ('origin', 'license', 'sourceStatement', 'sourceReferences')):
                    self.finding('unapproved-or-changed-source-asset', relative, data)
            if relative.endswith('.md') and not relative.startswith(VENDORS):
                text = data.decode('utf-8-sig')
                if len(re.findall(r'^```', text, flags=re.MULTILINE)) % 2:
                    self.finding('markdown-fence', relative, data)
                for match in re.finditer(r'\[[^\]]*\]\(([^)]+)\)', text):
                    target = match.group(1).strip().strip('<>')
                    if re.match(r'^[A-Za-z][A-Za-z0-9+.-]*:|^#', target):
                        continue
                    target = unquote(target.split('#', 1)[0])
                    normalized = os.path.normpath(str(PurePosixPath(relative).parent / target)).replace('\\', '/')
                    if normalized not in files:
                        self.finding('missing-public-local-link', relative, data, len(text[:match.start()].encode('utf-8')))
        for relative in assets:
            if relative not in files:
                self.finding('missing-declared-asset', relative)

    def history(self, ref: str):
        commits = git(self.root, 'log', ref, '--format=%H%x00%an%x00%ae%x00%cn%x00%ce').decode('utf-8')
        for line in commits.splitlines():
            commit, author, email, committer, committer_email = line.split('\0')
            self.history_commits += 1
            metadata = line.encode('utf-8')
            self.scan('.git/commit/' + commit, metadata)
            # 原始提交消息同样会公开；删文件不能清除消息里的秘密或机器记录。
            self.scan('.git/commit-message/' + commit, git(self.root, 'cat-file', 'commit', commit))
            if any(not address.lower().endswith('@users.noreply.github.com') for address in (email, committer_email)):
                self.finding('git-author-email-review', '.git/commit/' + commit, metadata, severity='review')
        objects = {}
        for line in git(self.root, 'rev-list', '--objects', ref).decode('utf-8').splitlines():
            oid, _, relative = line.partition(' ')
            objects[oid] = relative
        if not objects:
            return
        result = subprocess.run(['git', '-C', str(self.root), 'cat-file', '--batch-check=%(objectname) %(objecttype) %(objectsize)'],
                                input=('\n'.join(objects) + '\n').encode('ascii'), capture_output=True, check=True)
        selected = []
        for line in result.stdout.decode('ascii').splitlines():
            oid, kind, size = line.split()
            if kind != 'blob':
                continue
            location = '.git/history/' + oid + '/' + objects[oid]
            if private_file(objects[oid]):
                self.finding('historical-private-file', location)
            if int(size) >= 100 * 1024 * 1024:
                self.finding('historical-oversized-blob', location)
                continue
            selected.append(oid)
        for oid, data in git_blobs(self.root, selected).items():
            self.scan('.git/history/' + oid + '/' + objects[oid], data)
            self.history_blobs += 1

    def release(self, files: dict[str, bytes]) -> dict[str, str]:
        version = re.search(rb'^version:\s*([^+\s]+)', files['pubspec.yaml'], re.MULTILINE).group(1).decode('ascii')
        directory = self.root / 'dist'
        names = [f'OpenNote-{version}-Windows-x64-Setup.exe', f'OpenNote-{version}-Windows-x64.zip', f'OpenNote-{version}-Source.zip']
        inventory = {}
        manifest_path = directory / 'release-manifest.json'
        if not manifest_path.is_file():
            self.finding('missing-release-manifest', 'dist/release-manifest.json')
            return inventory
        manifest_bytes = manifest_path.read_bytes()
        self.scan('dist/release-manifest.json', manifest_bytes)
        inventory['release-manifest.json'] = sha(manifest_bytes)
        manifest = json.loads(manifest_bytes)
        if manifest['version'] != version or manifest.get('candidate') is not False:
            self.finding('release-version-or-candidate', 'dist/release-manifest.json', manifest_bytes)
        declared = {item['path']: item for item in manifest['artifacts']}
        for name in names:
            path = directory / name
            if not path.is_file():
                self.finding('missing-ready-to-use-release', 'dist/' + name)
                continue
            payload = path.read_bytes()
            inventory[name] = sha(payload)
            item = declared.get(name)
            if not item or item['size'] != len(payload) or item['sha256'] != sha(payload):
                self.finding('release-manifest-hash-mismatch', 'dist/' + name, payload)
            self.scan('dist/' + name, payload, inspect_container=False)
            if name.endswith('.zip'):
                with zipfile.ZipFile(io.BytesIO(payload)) as archive:
                    if len(archive.namelist()) != len(set(archive.namelist())):
                        self.finding('duplicate-release-zip-entry', 'dist/' + name, payload)
                    entries = {entry.filename: entry for entry in archive.infolist() if not entry.is_dir()}
                    for entry_name, entry in entries.items():
                        relative = entry_name.removeprefix('OpenNote/')
                        if entry_name == relative or '..' in PurePosixPath(relative).parts or private_file(relative):
                            self.finding('private-or-unsafe-release-entry', 'dist/' + name + '!' + entry_name)
                        content = archive.read(entry)
                        self.scan('dist/' + name + '!' + entry_name, content)
                        if name.endswith('-Source.zip') and (relative not in files or sha(content) != sha(files[relative])):
                            self.finding('source-archive-drift', 'dist/' + name + '!' + entry_name, content)
                    if name.endswith('-Source.zip'):
                        for relative in set(files) - {value.removeprefix('OpenNote/') for value in entries}:
                            self.finding('source-archive-missing-file', relative)
                    else:
                        required = {'opennote.exe', 'flutter_windows.dll', 'pdfium.dll', 'opennote_ocr.dll',
                                    'opennote_onnxruntime.dll', 'flutter_inappwebview_windows_plugin.dll',
                                    'data/app.so', 'data/ocr/manifest.json', 'LICENSE', 'THIRD_PARTY_NOTICES.md'}
                        available = {value.removeprefix('OpenNote/') for value in entries}
                        for missing in required - available:
                            self.finding('portable-missing-dependency', missing)
                        model_name = 'OpenNote/data/ocr/manifest.json'
                        if model_name in entries:
                            models = json.loads(archive.read(model_name))
                            if not any(item['path'].endswith('.onnx') for item in models.get('files', [])):
                                self.finding('portable-missing-ocr-model', model_name)
                            for item in models.get('files', []):
                                model_path = 'OpenNote/data/ocr/' + item['path']
                                if model_path not in entries:
                                    self.finding('portable-missing-model-resource', model_path)
                                else:
                                    resource = archive.read(model_path)
                                    if len(resource) != item['size'] or sha(resource) != item['sha256']:
                                        self.finding('portable-model-hash-mismatch', model_path, resource)
                        epub = json.loads(files.get('assets/epub/manifest.json', b'{"files":[]}').decode('utf-8'))
                        for item in epub['files']:
                            asset_path = 'OpenNote/data/flutter_assets/' + item['path']
                            if asset_path not in entries:
                                self.finding('portable-missing-epub-resource', asset_path)
                            else:
                                resource = archive.read(asset_path)
                                if len(resource) != item['size'] or sha(resource) != item['sha256']:
                                    self.finding('portable-epub-hash-mismatch', asset_path, resource)
                    if archive.testzip() is not None:
                        self.finding('release-zip-crc', 'dist/' + name)
        return inventory


def select_files(root: Path, selection: str, ref: str) -> dict[str, bytes]:
    files = {}
    if selection == 'worktree':
        names = git(root, 'ls-files', '--cached', '--others', '--exclude-standard', '-z').decode('utf-8').split('\0')
        for relative in sorted(set(filter(None, names))):
            path = root / relative
            if path.is_symlink() or not path.resolve().is_relative_to(root.resolve()):
                raise RuntimeError('发布范围含符号链接或工作区外部文件')
            files[relative] = path.read_bytes()
    else:
        listing = git(root, 'ls-files', '--stage', '-z') if selection == 'index' else git(root, 'ls-tree', '-r', '-z', ref)
        objects = {}
        for item in filter(None, listing.decode('utf-8').split('\0')):
            metadata, relative = item.split('\t', 1)
            mode, middle, last = metadata.split()
            if mode not in {'100644', '100755'} or (selection == 'index' and last != '0'):
                raise RuntimeError('发布范围含未合并条目、子模块或符号链接，须先审查')
            oid = middle if selection == 'index' else last
            objects[relative] = oid
        blobs = git_blobs(root, list(objects.values()))
        files = {relative: blobs[oid] for relative, oid in objects.items()}
    return files


def main(arguments=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path.cwd())
    parser.add_argument('--selection', choices=('worktree', 'index', 'commit'), default='worktree')
    parser.add_argument('--ref', default='HEAD')
    parser.add_argument('--with-release', action='store_true')
    parser.add_argument('--expect-digest', help='发布前复核既定快照，内容变化则阻断')
    parser.add_argument('--review-file', type=Path, help='本地逐项误报理由；仅可处理 review 级别')
    options = parser.parse_args(arguments)
    root = options.root.resolve()
    if not (root / 'pubspec.yaml').is_file() or not re.search(r'^name:\s*opennote\s*$', (root / 'pubspec.yaml').read_text(encoding='utf-8'), re.MULTILINE):
        parser.error('目标必须是 OpenNote Git 根目录')
    if Path(git(root, 'rev-parse', '--show-toplevel').decode('utf-8').strip()).resolve() != root:
        parser.error('必须指定 Git 根目录')
    if options.ref.startswith('-'):
        parser.error('ref 不能以选项前缀开头')
    head = git(root, 'rev-parse', '--verify', options.ref + '^{commit}', required=False).decode('ascii').strip()
    if options.selection == 'commit' and not head:
        parser.error('提交不存在')
    local_profile = root / '.local/release-privacy.json'
    profile = json.loads(local_profile.read_text(encoding='utf-8')) if local_profile.is_file() else {}
    deny_strings = profile.get('denyStrings', [])
    if not isinstance(deny_strings, list) or any(not isinstance(value, str) or not marker_length_ok(value) for value in deny_strings):
        parser.error('私有标记必须为有效字符串列表；纯 ASCII 至少四字符，含非 ASCII 至少两字符')
    audit = Audit(root, deny_strings)
    files = select_files(root, options.selection, head or options.ref)
    audit.source(files)
    if head:
        audit.history(head)
    email = git(root, 'config', '--get', 'user.email', required=False).strip()
    if not email.lower().endswith(b'@users.noreply.github.com'):
        audit.finding('current-git-email-review', '.git/config', email, severity='review')
    release = audit.release(files) if options.with_release else {}
    review_bytes = b''
    if options.review_file:
        review_path = options.review_file.resolve()
        if not review_path.is_relative_to((root / '.local').resolve()):
            parser.error('误报记录必须保存在 .local 内')
        review_bytes = review_path.read_bytes()
        reasons = json.loads(review_bytes)
        for item in audit.items:
            reason = reasons.get(item['id'])
            if item['severity'] == 'review' and isinstance(reason, str) and len(reason.strip()) >= 12:
                item['reviewedAsPublicOrSynthetic'] = True
    digest = sha(json.dumps({'selection': options.selection, 'commit': head, 'files': audit.inventory,
                             'release': release, 'privacyProfile': sha(json.dumps(profile, sort_keys=True).encode()),
                             'reviewFile': sha(review_bytes)}, sort_keys=True).encode('utf-8'))
    if options.expect_digest and digest != options.expect_digest:
        audit.finding('snapshot-changed-since-review', 'release-snapshot')
    blockers = [item for item in audit.items if not item.get('reviewedAsPublicOrSynthetic')]
    # 读取索引／工作树二次确认，避免审查过程中被另一任务修改。
    if {path: sha(data) for path, data in select_files(root, options.selection, head or options.ref).items()} != audit.inventory:
        audit.finding('source-changed-during-audit', 'release-snapshot')
        blockers = [item for item in audit.items if not item.get('reviewedAsPublicOrSynthetic')]
    if any(sha((root / 'dist' / name).read_bytes()) != digest for name, digest in release.items()):
        audit.finding('release-changed-during-audit', 'release-snapshot')
        blockers = [item for item in audit.items if not item.get('reviewedAsPublicOrSynthetic')]
    report = {'automaticChecksPassed': not blockers, 'humanSemanticAndAssetReviewRequired': True,
              'selection': options.selection, 'commit': head, 'snapshotDigest': digest,
              'files': audit.inventory, 'artifacts': release, 'historyCommits': audit.history_commits,
              'historyBlobs': audit.history_blobs, 'unresolvedCount': len(blockers), 'findings': audit.items,
              'installerPayloadAndBuildProvenanceRequireReview': options.with_release,
              'matchedValuesPrinted': False}
    directory = root / '.local/verification/github-open-source' / datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    directory.mkdir(parents=True, exist_ok=False)
    if git(root, 'check-ignore', '--', str(directory / 'audit.json'), required=False).strip() == b'':
        raise RuntimeError('报告目录必须被 Git 忽略')
    (directory / 'audit.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'automaticChecksPassed': not blockers, 'unresolvedCount': len(blockers),
                      'candidateFiles': len(files), 'snapshotDigest': digest,
                      'report': (directory / 'audit.json').relative_to(root).as_posix(),
                      'humanReviewStillRequired': True}, ensure_ascii=False))
    return 0 if not blockers else 1


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError, zipfile.BadZipFile, KeyError) as error:
        print('审查未完成：' + type(error).__name__, file=sys.stderr)
        raise SystemExit(2)
