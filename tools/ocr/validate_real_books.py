"""真实公共领域印刷扫描的人工抽段质量评估；Python 仅供开发复现。"""
from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import time
import unicodedata
from pathlib import Path
from PIL import Image, ImageDraw


def normalize(text: str, *, omit_punctuation: bool = False) -> str:
    text = unicodedata.normalize('NFC', text)
    return ''.join(char for char in text if not char.isspace() and
                   not (omit_punctuation and unicodedata.category(char).startswith('P')))


def edit_distance(reference: str, actual: str) -> int:
    row = list(range(len(actual) + 1))
    for i, a in enumerate(reference, 1):
        next_row = [i]
        for j, b in enumerate(actual, 1):
            next_row.append(min(next_row[-1] + 1, row[j] + 1, row[j - 1] + (a != b)))
        row = next_row
    return row[-1]


def center(quad):
    return (sum(point[0] for point in quad) / 4, sum(point[1] for point in quad) / 4)


def inside(quad, rectangle) -> bool:
    x, y = center(quad)
    return rectangle[0] <= x <= rectangle[2] and rectangle[1] <= y <= rectangle[3]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--run', action='store_true', help='重新顺序运行真实 C++ CLI 推理')
    parser.add_argument('--prepare-fixtures', action='store_true', help='复制少量扫描页并包装成纯图像 PDF 测试资料')
    parser.add_argument('--inspect-characters', action='store_true', help='打印抽段第一行的字符位置并保存局部目测图')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    folder = root / 'tools/ocr/validation'
    specifications = json.loads((root / 'tools/ocr/real-book-samples.json').read_text(encoding='utf-8'))
    report = {'formatVersion': 1, 'processingVersion': 'opennote-ppocrv6-small-cpu-v2',
              'hardware': '13th Gen Intel Core i9-13900H, 14 cores / 20 logical CPUs',
              'threads': 2, 'method': 'Manual visual transcription of bounded excerpts; Unicode codepoint Levenshtein CER. NFC and whitespace removal; punctuation-free CER reported separately. No traditional-to-simplified conversion.',
              'scope': 'Four original public-domain printed-book page scans, small manually transcribed excerpts; not a representative book corpus, minimum-hardware benchmark or installed UI acceptance.', 'samples': []}
    if args.prepare_fixtures:
        destination = root / 'test/ocr/fixtures/real-books'
        destination.mkdir(parents=True, exist_ok=True)
        for filename in ['austen-page11.jpg', 'chinese-page20.jpg', 'hillier-page110.jpg']:
            (destination / filename).write_bytes((folder / filename).read_bytes())
        # 原始下载 JPEG 字节直接嵌入，既不重新排版文字，也不生成打印内容。
        image_path = folder / 'chinese-page20.jpg'
        image = Image.open(image_path)
        jpeg = image_path.read_bytes()
        assert image.mode in ['L', 'RGB'], '包装资料必须按 JPEG 实际分量声明 PDF 颜色空间'
        color_space = 'DeviceGray' if image.mode == 'L' else 'DeviceRGB'
        page_width, page_height = image.width / 3, image.height / 3
        commands = f'q {page_width} 0 0 {page_height} 0 0 cm /Scan Do Q'.encode('ascii')
        objects = [b'<< /Type /Catalog /Pages 2 0 R >>',
                   b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
                   f'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {page_width} {page_height}] /Resources << /XObject << /Scan 5 0 R >> >> /Contents 4 0 R >>'.encode('ascii'),
                   f'<< /Length {len(commands)} >>\nstream\n'.encode('ascii') + commands + b'\nendstream',
                   f'<< /Type /XObject /Subtype /Image /Width {image.width} /Height {image.height} /ColorSpace /{color_space} /BitsPerComponent 8 /Filter /DCTDecode /Length {len(jpeg)} >>\nstream\n'.encode('ascii') + jpeg + b'\nendstream']
        content = bytearray(b'%PDF-1.4\n%\xe2\xe3\xcf\xd3\n')
        offsets = [0]
        for index, obj in enumerate(objects, 1):
            offsets.append(len(content))
            content.extend(f'{index} 0 obj\n'.encode('ascii') + obj + b'\nendobj\n')
        xref = len(content)
        content.extend(f'xref\n0 {len(offsets)}\n0000000000 65535 f \n'.encode('ascii'))
        for offset in offsets[1:]:
            content.extend(f'{offset:010d} 00000 n \n'.encode('ascii'))
        content.extend(f'trailer\n<< /Size {len(offsets)} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n'.encode('ascii'))
        (destination / 'chinese-page20-image-only.pdf').write_bytes(content)
    for spec in specifications['samples']:
        image_path = folder / spec['image']
        raw = image_path.read_bytes()
        assert hashlib.sha256(raw).hexdigest() == spec['sha256'], spec['id']
        output_path = folder / (image_path.stem + '-ocr.json')
        wall_ms = None
        if args.run:
            started = time.perf_counter()
            subprocess.run([str(root / 'native/build/Release/opennote_ocr_cli.exe'),
                            str(root / 'assets/ocr/models/PP-OCRv6_small'), str(image_path), str(output_path)],
                           check=True, capture_output=True)
            wall_ms = round((time.perf_counter() - started) * 1000)
        result = json.loads(output_path.read_text(encoding='utf-8'))
        image = Image.open(image_path).convert('RGB')
        assert image.size == (result['width'], result['height'])
        overlay = image.copy()
        draw = ImageDraw.Draw(overlay)
        for line in result['lines']:
            draw.line([tuple(point) for point in line['quad']] + [tuple(line['quad'][0])], fill='red', width=2)
            draw.text(tuple(line['quad'][0]), str(line['order']), fill='red')
        evaluations = []
        for evaluation in spec.get('excerpts', []):
            selected = [line for line in result['lines'] if inside(line['quad'], evaluation['bounds'])]
            actual = '\n'.join(line['text'] for line in selected)
            metrics = {}
            for name, without_punctuation in [('cer', False), ('cerWithoutPunctuation', True)]:
                reference = normalize(evaluation['reference'], omit_punctuation=without_punctuation)
                prediction = normalize(actual, omit_punctuation=without_punctuation)
                errors = edit_distance(reference, prediction)
                metrics[name] = {'referenceCodepoints': len(reference), 'edits': errors,
                                 'rate': errors / len(reference) if reference else None}
            evaluations.append({'name': evaluation['name'], 'bounds': evaluation['bounds'],
                                'reference': evaluation['reference'], 'actual': actual,
                                'lineOrders': [line['order'] for line in selected], **metrics})
            draw.rectangle(tuple(evaluation['bounds']), outline='green', width=3)
            if args.inspect_characters and selected:
                first = selected[0]
                print(json.dumps({'id': spec['id'], 'characters': [
                    {'index': index, 'text': char['text'], 'center': center(char['quad'])}
                    for index, char in enumerate(first['characters'])]}, ensure_ascii=False))
                xs = [point[0] for point in first['quad']]
                ys = [point[1] for point in first['quad']]
                crop = image.crop((max(0, min(xs)-10), max(0, min(ys)-10),
                                   min(image.width, max(xs)+10), min(image.height, max(ys)+10)))
                crop.save(folder / (image_path.stem + '-first-line.png'))
        geometry_checks = []
        for check in spec.get('geometrySpots', []):
            selected = [line for line in result['lines'] if inside(line['quad'], check['lineRegion'])]
            assert len(selected) == 1, check
            character = selected[0]['characters'][check['characterIndex']]
            x, y = center(character['quad'])
            bx0, by0, bx1, by1 = check['manualGlyphBounds']
            matched = bx0 <= x <= bx1 and by0 <= y <= by1
            geometry_checks.append({**check, 'actualToken': character['text'],
                                    'quad': character['quad'], 'center': [x, y],
                                    'centerInsideManualGlyphBounds': matched})
            draw.rectangle((bx0, by0, bx1, by1), outline='magenta', width=3)
            draw.line([tuple(point) for point in character['quad']] + [tuple(character['quad'][0])], fill='blue', width=3)
        overlay.save(folder / (image_path.stem + '-geometry.png'))
        bad_quads = 0
        for line in result['lines']:
            assert ''.join(char['text'] for char in line['characters']) == line['text']
            for entry in [line, *line['characters']]:
                if any(not (-.2 <= x <= image.width + .2 and -.2 <= y <= image.height + .2) for x, y in entry['quad']):
                    bad_quads += 1
        report['samples'].append({'id': spec['id'], 'source': spec['source'],
                                  'sourceImage': spec['imageUrl'], 'sha256': spec['sha256'],
                                  'license': spec['license'], 'dimensions': list(image.size),
                                  'elapsedNativeMs': result['elapsedMs'], 'elapsedColdCliWallMs': wall_ms,
                                  'lineCount': len(result['lines']), 'readingOrder': result['readingOrder'],
                                  'writingDirection': result.get('writingDirection'),
                                  'directionDetection': result.get('directionDetection'),
                                  'outOfImageQuads': bad_quads, 'excerpts': evaluations,
                                  'geometrySpots': geometry_checks, 'observedLimits': spec.get('observedLimits', [])})
    path = root / 'tools/ocr/real-book-validation.json'
    path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
