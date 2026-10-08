"""只读核验本机专用扫描诊断库的小段；报告不输出版权正文或原图。"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sqlite3
import unicodedata


def normalized(text: str) -> str:
    return ''.join(c for c in unicodedata.normalize('NFC', text) if not c.isspace())


def distance(reference: str, actual: str) -> int:
    row = list(range(len(actual) + 1))
    for i, left in enumerate(reference, 1):
        following = [i]
        for j, right in enumerate(actual, 1):
            following.append(min(following[-1] + 1, row[j] + 1,
                                 row[j - 1] + (left != right)))
        row = following
    return row[-1]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--data-dir', type=Path, required=True)
    parser.add_argument('--manual', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    # 标识只用于验证项目，不探查普通库或原始聊天数据。
    marker = json.loads((args.data_dir / '.scan-book-verification.json').read_text(encoding='utf-8'))
    if marker['kind'] != 'opennote-local-scan-book-verification':
        raise ValueError('专用扫描诊断标识不匹配')
    pointer = json.loads((args.data_dir / 'active.json').read_text(encoding='utf-8'))
    library_id = pointer['libraryId']
    if not isinstance(library_id, str) or not library_id or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-' for c in library_id):
        raise ValueError('资料库标识不合法')
    database = args.data_dir / 'libraries' / library_id / 'library.sqlite'
    manual = json.loads(args.manual.read_text(encoding='utf-8-sig'))
    connection = sqlite3.connect(database.resolve().as_uri() + '?mode=ro', uri=True)
    try:
        layer = connection.execute(
            'SELECT text,fragments,parameters,engine_version FROM text_layers '
            'WHERE revision_id=? AND page_index=? AND is_current=1',
            (marker['revisionId'], manual['pageOneBased'] - 1)).fetchone()
        if layer is None:
            raise ValueError('指定采样页尚无已提交文字层')
    finally:
        connection.close()
    text, raw_fragments, raw_parameters, engine = layer
    parameters = json.loads(raw_parameters)
    geometry = parameters['pageGeometry']
    if geometry['rotation'] != 0:
        raise ValueError('该人工图像样本只支持已明确的零旋转页，不能默默使用错误坐标')
    crop = geometry['cropBox']['points']
    media = geometry['mediaBox']['points']
    left = max(min(point['x'] for point in crop), min(point['x'] for point in media))
    bottom = max(min(point['y'] for point in crop), min(point['y'] for point in media))
    right = min(max(point['x'] for point in crop), max(point['x'] for point in media))
    top = min(max(point['y'] for point in crop), max(point['y'] for point in media))
    width, height = manual['displaySize']
    x1, y1, x2, y2 = manual['boundsDisplayPixels']
    utf16 = text.encode('utf-16-le')
    selected: list[tuple[int, str, tuple[float, float]]] = []
    for fragment in json.loads(raw_fragments):
        points = fragment['quad']['points']
        center = (sum(point['x'] for point in points) / 4,
                  sum(point['y'] for point in points) / 4)
        display = ((center[0] - left) * width / (right - left),
                   (top - center[1]) * height / (top - bottom))
        if x1 <= display[0] <= x2 and y1 <= display[1] <= y2:
            token = utf16[fragment['start'] * 2:(fragment['start'] + fragment['length']) * 2].decode('utf-16-le')
            selected.append((fragment['start'], token, display))
    selected.sort(key=lambda item: item[0])
    actual = normalized(''.join(item[1] for item in selected))
    reference = normalized(manual['reference'])
    if not actual or not reference:
        raise ValueError('人工选段或对应 OCR 选段为空')
    no_punctuation = lambda text: ''.join(c for c in text if not unicodedata.category(c).startswith('P'))
    plain_reference, plain_actual = no_punctuation(reference), no_punctuation(actual)
    positions = [(glyph, item[2]) for item in selected for glyph in item[1] if not glyph.isspace()]
    geometry_spots = []
    for spot in manual.get('geometrySpots', []):
        index = spot['referenceIndex']
        if index >= len(positions) or index >= len(reference):
            geometry_spots.append({'referenceIndex': index, 'available': False})
            continue
        glyph, (x, y) = positions[index]
        bx1, by1, bx2, by2 = spot['manualGlyphBounds']
        geometry_spots.append({
            'referenceIndex': index,
            'available': True,
            'tokenMatchesReference': glyph == reference[index],
            'centerInsideManualGlyphBounds': bx1 <= x <= bx2 and by1 <= y <= by2,
            'centerDisplayPixels': [x, y],
            'manualGlyphBounds': spot['manualGlyphBounds'],
        })
    report = {
        'success': True,
        'sourceSha256': marker['sourceSha256'],
        'pageOneBased': manual['pageOneBased'],
        'processingVersion': engine,
        'manualReferenceCodepoints': len(reference),
        'actualCodepoints': len(actual),
        'edits': distance(reference, actual),
        'cer': distance(reference, actual) / len(reference),
        'withoutPunctuation': {
            'manualReferenceCodepoints': len(plain_reference),
            'edits': distance(plain_reference, plain_actual),
            'cer': distance(plain_reference, plain_actual) / len(plain_reference),
        },
        'excerptFragmentCount': len(selected),
        'geometrySpots': geometry_spots,
        'geometryScope': 'Three visually boxed glyph-center spots, approximate CTC alignment; '
                         'not tight glyph outlines or all-character accuracy.',
        'reportContainsBookText': False,
        'scope': 'Two visually transcribed body lines from one local user-provided scan. '
                 'Formal persisted OCR compared with manual reference; not a whole-book quality estimate.',
    }
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(report, ensure_ascii=False, indent=2), flush=True)


if __name__ == '__main__':
    main()
