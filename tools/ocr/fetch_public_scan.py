"""开发验证用单页扫描下载器；限制大小并留存联网失败，不属于产品运行链。"""
from __future__ import annotations

import argparse
import datetime
import hashlib
import html
import json
import re
import time
import urllib.error
import urllib.request
from pathlib import Path


def fetch(url: str, output: Path, log: Path) -> bytes:
    output.parent.mkdir(parents=True, exist_ok=True)
    for attempt in range(4):
        if attempt:
            time.sleep([2, 5, 10][attempt - 1])
        try:
            request = urllib.request.Request(
                url, headers={'User-Agent': 'OpenNote-OCR-validation/0.1 (public-domain-page-sampling)'})
            with urllib.request.urlopen(request, timeout=40) as response:
                data = response.read(8 * 1024 * 1024 + 1)
                if len(data) > 8 * 1024 * 1024:
                    raise ValueError('Single-page request exceeds the 8 MiB sampling limit')
            if not data:
                raise ValueError('Empty response')
            temporary = output.with_suffix(output.suffix + '.partial')
            temporary.write_bytes(data)
            temporary.replace(output)
            print(json.dumps({'path': str(output), 'url': url, 'bytes': len(data),
                              'sha256': hashlib.sha256(data).hexdigest()}, ensure_ascii=False))
            return data
        except Exception as error:
            status = error.code if isinstance(error, urllib.error.HTTPError) else None
            entry = {'atUtc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                     'attempt': attempt + 1, 'url': url, 'type': type(error).__name__,
                     'status': status, 'reason': str(error)}
            with log.open('a', encoding='utf-8') as stream:
                stream.write(json.dumps(entry, ensure_ascii=False) + '\n')
            print(json.dumps(entry, ensure_ascii=False))
            if isinstance(error, ValueError) or (status and 400 <= status < 500 and status not in [408, 429]) or attempt == 3:
                raise
    raise AssertionError('Unreachable')


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('url')
    parser.add_argument('output', type=Path)
    parser.add_argument('--list-images', action='store_true')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    data = fetch(args.url, args.output, root / 'tools/ocr/download-errors.jsonl')
    if args.list_images:
        text = data.decode('utf-8')
        urls = [html.unescape(value) for value in re.findall(r'(?:src|href)="([^"]+)"', text)
                if ('wikimedia.org' in value and ('page' in value or 'upload.' in value))]
        print(json.dumps(list(dict.fromkeys(urls))[:35], ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
