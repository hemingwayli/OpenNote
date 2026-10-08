"""将许可允许分发的简体中文安装消息锁定到提交与哈希，不修改系统 Inno 设置。"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path

from bootstrap_windows import ROOT, fetch

TARGET = ROOT / 'packaging' / 'windows'
LOCK = TARGET / 'translation-lock.json'
REPOSITORY = 'kira-96/Inno-Setup-Chinese-Simplified-Translation'


def main() -> None:
    if LOCK.exists():
        lock = json.loads(LOCK.read_text(encoding='utf-8'))
    else:
        metadata = ROOT / '.local' / 'inno-translation-commit.json'
        fetch(f'https://api.github.com/repos/{REPOSITORY}/commits?per_page=1', metadata)
        lock = {'repository': REPOSITORY, 'commit': json.loads(metadata.read_text(encoding='utf-8'))[0]['sha'], 'files': {}}
    for source, target in [('ChineseSimplified.isl', 'ChineseSimplified.isl'), ('LICENSE', 'ChineseSimplified-LICENSE.txt')]:
        path = TARGET / target
        url = f"https://raw.githubusercontent.com/{REPOSITORY}/{lock['commit']}/{source}"
        if not path.exists():
            fetch(url, path)
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        expected = lock['files'].get(target, {}).get('sha256')
        if expected and expected != digest:
            raise RuntimeError(f'安装语言文件 SHA256 不一致: {path}')
        lock['files'][target] = {'url': url, 'sha256': digest}
    LOCK.write_text(json.dumps(lock, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(lock, ensure_ascii=False, indent=2), flush=True)


if __name__ == '__main__':
    main()
