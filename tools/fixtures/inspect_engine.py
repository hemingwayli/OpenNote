"""下载已锁定的官方 PDF 包源码，供 M1 接口与许可证核验。"""

from __future__ import annotations

import hashlib
import json
import pathlib
import tarfile
import tempfile
import time
import urllib.error
import urllib.request


def request_bytes(url: str) -> bytes:
    for attempt, delay in enumerate((0, 2, 5, 10), start=1):
        if delay:
            time.sleep(delay)
        try:
            with urllib.request.urlopen(url, timeout=45) as response:
                return response.read()
        except (urllib.error.URLError, TimeoutError) as error:
            print(f"attempt={attempt} url={url} error={type(error).__name__}: {error}")
            if isinstance(error, urllib.error.HTTPError) and error.code not in (
                408, 429, 500, 502, 503, 504
            ):
                raise
            if attempt == 4:
                raise
    raise RuntimeError("request did not return")


def fetch_package(name: str, version: str, parent: pathlib.Path) -> dict:
    metadata = json.loads(request_bytes(f"https://pub.dev/api/packages/{name}/versions/{version}"))
    archive = request_bytes(metadata["archive_url"])
    actual_hash = hashlib.sha256(archive).hexdigest()
    if actual_hash != metadata["archive_sha256"]:
        raise RuntimeError(f"official archive hash mismatch: {name}")
    archive_path = parent / f"{name}-{version}.tar.gz"
    archive_path.write_bytes(archive)
    source_path = parent / f"{name}-{version}"
    source_path.mkdir()
    with tarfile.open(archive_path, "r:gz") as package:
        package.extractall(source_path, filter="data")
    print(f"{name}={source_path} sha256={actual_hash}")
    return metadata


def main() -> None:
    destination = pathlib.Path(tempfile.mkdtemp(prefix="opennote-pdf-source-"))
    metadata = fetch_package("pdfrx", "2.6.5", destination)
    print(json.dumps(metadata["pubspec"], ensure_ascii=False, indent=2))
    engine = fetch_package("pdfrx_engine", "0.6.1", destination)
    print(json.dumps(engine["pubspec"], ensure_ascii=False, indent=2))
    parser = fetch_package("dart_pdf_reader", "2.2.0", destination)
    print(json.dumps(parser["pubspec"], ensure_ascii=False, indent=2))
    try:
        import fitz

        print(f"pymupdf={fitz.VersionBind}")
    except ImportError:
        print("pymupdf=unavailable")


if __name__ == "__main__":
    main()
