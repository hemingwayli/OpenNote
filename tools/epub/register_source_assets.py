"""声明自产 EPUB 样本的来源、字节与分发依据；只接受 fixtures/epub 内的固定样本。"""
import hashlib
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]
path=ROOT/'packaging/source-assets.json'
manifest=json.loads(path.read_text(encoding='utf-8'))
manifest['assetExtensions']=list(dict.fromkeys([*manifest['assetExtensions'],'.epub']))
entries={entry['path']:entry for entry in manifest['files']}
for name in ('epub2-reflow','epub3-reflow','epub3-vertical','epub3-fixed','epub3-mixed'):
    source=ROOT/f'tools/fixtures/epub/{name}.epub'
    relative=source.relative_to(ROOT).as_posix()
    entries[relative]={'path':relative,'size':source.stat().st_size,
        'sha256':hashlib.sha256(source.read_bytes()).hexdigest(),
        'origin':'generated','license':'Apache-2.0',
        'sourceStatement':'OpenNote 自造的中英日韩文字、SVG、公式、目录与脚注，内含已声明的自产 bilingual.png，不包含外部书页。',
        'sourceReferences':['tools/epub/create_fixtures.py','test/ocr/fixtures/expected.json']}
manifest['files']=list(entries.values())
path.write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
print('5 份自产 EPUB 的大小、SHA-256 与来源已声明。')
