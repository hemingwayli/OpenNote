"""开发验证工具；产品识别链不依赖 Python 或 Pillow。"""
from __future__ import annotations
import argparse
import ctypes as c
import hashlib
import json
import threading
import time
import zlib
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont, ImageFilter

LINES = [
    '离线阅读与知识整理',
    '扫描书页可以选择文字并制作独立卡片。',
    '复制卡片后，修改副本不会影响原卡片。',
    'OpenNote keeps your documents on this device.',
    'Select text, create notes, and return to the source.',
    'Offline OCR works with Chinese and English books.',
]

def fixtures(output: Path) -> Path:
    output.mkdir(parents=True, exist_ok=True)
    image = Image.new('RGBA', (1800, 1200), 'white')
    draw = ImageDraw.Draw(image)
    font = ImageFont.truetype('C:/Windows/Fonts/msyh.ttc', 45)
    labels = []
    for index, text in enumerate(LINES):
        xy = (95, 95 + index * 145)
        draw.text(xy, text, font=font, fill='black')
        labels.append({'text': text, 'bounds': list(draw.textbbox(xy, text, font=font))})
    image.save(output / 'bilingual.png')
    image.filter(ImageFilter.GaussianBlur(.35)).rotate(2, fillcolor='white').save(output / 'bilingual_skew.png')
    (output / 'expected.json').write_text(json.dumps({'lines': labels}, ensure_ascii=False, indent=2), encoding='utf-8')
    return output / 'bilingual.png'

def scanned_pdf(image_path: Path, destination: Path) -> None:
    """四种显示旋转使用相反 content 旋转，保证用户所见中英文字均正向。"""
    image = Image.open(image_path).convert('RGB')
    packed = zlib.compress(image.tobytes())
    objects = [b'<< /Type /Catalog /Pages 2 0 R >>',
               b'<< /Type /Pages /Kids [5 0 R 7 0 R 9 0 R 11 0 R] /Count 4 >>',
               f'<< /Type /XObject /Subtype /Image /Width {image.width} /Height {image.height} /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode /Length {len(packed)} >>\nstream\n'.encode() + packed + b'\nendstream']
    transforms = ['600 0 0 400 40 60', '0 600 -400 0 440 60', '-600 0 0 -400 640 460', '0 -600 400 0 40 660']
    for index, (rotation, transform) in enumerate(zip([0, 90, 180, 270], transforms)):
        contents = f'q {transform} cm /Im0 Do Q'.encode()
        objects.append(f'<< /Length {len(contents)} >>\nstream\n'.encode()+contents+b'\nendstream')
        right, top = (640,460) if rotation in (0,180) else (440,660)
        objects.append(f'<< /Type /Page /Parent 2 0 R /MediaBox [-20 -40 {right} {top}] /CropBox [40 60 {right} {top}] /Rotate {rotation} /UserUnit 2 /Resources << /XObject << /Im0 3 0 R >> >> /Contents {4+index*2} 0 R >>'.encode())
    result = bytearray(b'%PDF-1.6\n%\xe2\xe3\xcf\xd3\n')
    offsets = [0]
    for index, obj in enumerate(objects,1):
        offsets.append(len(result)); result.extend(f'{index} 0 obj\n'.encode()+obj+b'\nendobj\n')
    xref = len(result)
    result.extend(f'xref\n0 {len(offsets)}\n0000000000 65535 f \n'.encode())
    for offset in offsets[1:]: result.extend(f'{offset:010d} 00000 n \n'.encode())
    result.extend(f'trailer\n<< /Size {len(offsets)} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n'.encode())
    destination.parent.mkdir(parents=True,exist_ok=True)
    destination.write_bytes(result)

def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[2])
    args = parser.parse_args()
    root = args.root.resolve()
    out = root / 'tools/ocr/validation'
    fixture = fixtures(out)
    scanned_pdf(fixture, root / 'test/ocr/fixtures/scanned_rotated.pdf')
    binary = root / 'native/build/Release/opennote_ocr.dll'
    model = root / 'assets/ocr/models/PP-OCRv6_small'
    # ctypes winmode 明确让相邻依赖 DLL 可被搜索，仅属于验证工具。
    dll = c.CDLL(str(binary), winmode=0x1100)
    dll.onocr_create.argtypes = [c.c_char_p, c.c_int32, c.POINTER(c.c_void_p), c.POINTER(c.c_void_p)]
    dll.onocr_create.restype = c.c_int32
    dll.onocr_recognize.argtypes = [c.c_void_p, c.c_void_p, c.c_size_t, c.c_int32, c.c_int32, c.c_int32, c.POINTER(c.c_void_p), c.POINTER(c.c_void_p)]
    dll.onocr_recognize.restype = c.c_int32
    dll.onocr_free.argtypes = [c.c_void_p]
    dll.onocr_destroy.argtypes = [c.c_void_p]
    dll.onocr_cancel.argtypes = [c.c_void_p]
    engine, error = c.c_void_p(), c.c_void_p()
    started = time.perf_counter()
    status = dll.onocr_create(str(model).encode('utf-8'), 2, c.byref(engine), c.byref(error))
    if status:
        message = c.string_at(error).decode('utf-8') if error.value else 'unknown create error'
        dll.onocr_free(error)
        raise RuntimeError(message)
    init_ms = round((time.perf_counter()-started)*1000)

    def recognize(image: Image.Image, stride_padding: int = 0):
        image = image.convert('RGBA')
        width, height = image.size
        stride = width*4 + stride_padding
        packed = image.tobytes()
        if stride_padding:
            packed = b''.join(packed[y*width*4:(y+1)*width*4] + b'\0'*stride_padding for y in range(height))
        raw = c.create_string_buffer(packed)
        result, err = c.c_void_p(), c.c_void_p()
        status = dll.onocr_recognize(engine, raw, len(packed), width, height, stride, c.byref(result), c.byref(err))
        message = c.string_at(err).decode('utf-8') if err.value else None
        parsed = json.loads(c.string_at(result)) if result.value else None
        dll.onocr_free(result); dll.onocr_free(err)
        return status, parsed, message

    report = {'model': 'PP-OCRv6_small', 'onnxruntime': '1.21.0', 'initializationMs': init_ms, 'tests': []}
    try:
        for name, padding in [('bilingual.png', 0), ('bilingual.png', 16), ('bilingual_skew.png', 0)]:
            image = Image.open(out / name)
            status, result, message = recognize(image, padding)
            assert status == 0, message
            assert len(result['lines']) == len(LINES), result
            actual = [line['text'] for line in result['lines']]
            def normalize(text):
                return ''.join(char for char in text if not char.isspace()).replace('，', ',').replace('。', '.')
            assert [normalize(text) for text in actual] == [normalize(text) for text in LINES], actual
            for order, line in enumerate(result['lines']):
                assert line['order'] == order
                assert line['precision'] == 'detectedLine'
                assert ''.join(char['text'] for char in line['characters']) == line['text']
                for entry in [line, *line['characters']]:
                    for x, y in entry['quad']:
                        assert -.1 <= x < image.width+.1 and -.1 <= y < image.height+.1, entry
                assert all(char['precision'] == 'approximateCtcAlignment' for char in line['characters'])
            (out / f'{Path(name).stem}_{padding}.json').write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
            report['tests'].append({'name': name, 'stridePadding': padding, 'elapsedMs': result['elapsedMs'], 'lineCount': len(actual), 'textMatches': True})
        empty = Image.new('RGBA', (600, 800), (0, 0, 0, 0))
        status, result, message = recognize(empty)
        assert status == 0 and result['lines'] == [], message
        report['tests'].append({'name': 'transparentWhiteComposite', 'passed': True})
        # 原生校验不得读取短缓冲区，也不得留下结果 allocation。
        raw = c.create_string_buffer(b'\xff'*4)
        result, error = c.c_void_p(), c.c_void_p()
        assert dll.onocr_recognize(engine, raw, 4, 10, 10, 40, c.byref(result), c.byref(error)) == 2
        assert not result.value
        dll.onocr_free(error)
        report['tests'].append({'name': 'shortBufferRejected', 'passed': True})
        # 真实推理期间跨线程取消，等待结束后同一引擎再次可用。
        busy = Image.open(fixture).resize((3600, 2400))
        cancelled = []
        worker = threading.Thread(target=lambda: cancelled.append(recognize(busy)))
        worker.start(); time.sleep(.08)
        cancel_start = time.perf_counter(); dll.onocr_cancel(engine)
        worker.join(15)
        assert not worker.is_alive(), 'Cancellation did not finish within 15s'
        assert cancelled[0][0] == 1, cancelled[0]
        report['tests'].append({'name': 'inferenceCancelled', 'returnAfterCancelMs': round((time.perf_counter()-cancel_start)*1000), 'passed': True})
        status, result, message = recognize(Image.open(fixture))
        assert status == 0 and len(result['lines']) == len(LINES), message
        report['tests'].append({'name': 'reuseAfterCancel', 'passed': True})
    finally:
        dll.onocr_destroy(engine)
    report['fixtureSha256'] = hashlib.sha256(fixture.read_bytes()).hexdigest()
    report['scope'] = 'Controlled rasterized printed-page fixtures; not real-book or PDF-selection acceptance.'
    (out / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps(report, ensure_ascii=False, indent=2))

if __name__ == '__main__':
    main()
