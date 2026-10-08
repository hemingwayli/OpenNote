"""解析项目锁定 SDK 的实际位置，个人路径仅写入本地配置。"""
from __future__ import annotations

import json
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SDK = '.local/toolchains/flutter'


def resolve_flutter_sdk(root: Path = ROOT) -> Path:
    value = os.environ.get('OPENNOTE_FLUTTER_ROOT')
    if not value:
        local = root / '.local/toolchain.json'
        if local.is_file():
            value = json.loads(local.read_text(encoding='utf-8')).get('sdkPath')
    if not value:
        lock = json.loads((root / 'tools/toolchain-lock.json').read_text(encoding='utf-8'))
        value = lock.get('sdkPath', DEFAULT_SDK)
    if not isinstance(value, str) or not value.strip():
        raise ValueError('SDK 位置须为非空路径字符串。')
    sdk = Path(os.path.expandvars(os.path.expanduser(value)))
    return (sdk if sdk.is_absolute() else root / sdk).resolve()


def save_toolchain(release: dict, sdk: Path, root: Path = ROOT) -> None:
    """共享清单只保存版本与可移植默认路径，本机选择单独保存。"""
    local = root / '.local/toolchain.json'
    local.parent.mkdir(parents=True, exist_ok=True)
    for path, data in (
        (local, {'sdkPath': str(sdk.resolve())}),
        (root / 'tools/toolchain-lock.json', {
            'flutter': release, 'sdkPath': DEFAULT_SDK,
            'manifestUrl': 'https://storage.googleapis.com/flutter_infra_release/releases/releases_windows.json',
        }),
    ):
        pending = path.with_suffix('.pending.json')
        pending.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
        pending.replace(path)


if __name__ == '__main__':
    print(resolve_flutter_sdk())
