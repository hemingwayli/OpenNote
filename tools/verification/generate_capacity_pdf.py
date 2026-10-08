"""生成有实际中英文字、1000 个独立页对象的容量样本；不使用页数元数据替代。"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import pymupdf as fitz


def generate(output: Path) -> dict:
    output.mkdir(parents=True, exist_ok=True)
    path = output / "long-book-1000.pdf"
    document = fitz.open()
    sentence = "知识来自阅读与实践。中文印刷书应支持离线搜索，摘录保留原文位置。"
    for index in range(1000):
        page = document.new_page(width=600, height=800)
        page.insert_text((48, 55), f"OpenNote capacity book - page {index + 1:04d}", fontsize=16)
        page.insert_text((48, 86), f"知识长书：第 {index + 1:04d} 页", fontname="china-s", fontsize=16)
        for line in range(24):
            page.insert_text((48, 120 + line * 21), f"{line + 1:02d} {sentence}", fontname="china-s", fontsize=12)
        for line in range(3):
            page.insert_text((48, 656 + line * 20), f"English paragraph {line + 1}: source anchors, offline search, independent notes.", fontsize=11)
        page.insert_text((280, 765), f"{index + 1}", fontsize=10)
    document.set_toc([[1, "Capacity chapter", 1], [1, "Final chapter", 1000]])
    document.save(path, garbage=4, deflate=True, use_objstms=1)
    document.close()
    with fitz.open(path) as check:
        if len(check) != 1000:
            raise RuntimeError("真实页对象数量不是 1000")
        first_text = check[0].get_text()
        final_text = check[-1].get_text()
        if "知识" not in first_text or "1000" not in final_text:
            raise RuntimeError("首尾页实际文字校验失败")
        # 渲染后的像素存在墨迹，排除仅有空白页字典的样本。
        ink = []
        for index in (0, 499, 999):
            bitmap = check[index].get_pixmap(matrix=fitz.Matrix(.5, .5), colorspace=fitz.csGRAY)
            ink.append({"page": index + 1, "darkPixels": sum(value < 150 for value in bitmap.samples)})
        if any(page["darkPixels"] < 1000 for page in ink):
            raise RuntimeError("实际书页渲染没有足够墨迹")
    report = {
        "generator": "generate_capacity_pdf.py",
        "pymupdfVersion": fitz.VersionBind,
        "content": "本项目生成的中英印刷文字，非外部版权书籍",
        "file": path.name,
        "sha256": hashlib.file_digest(path.open("rb"), "sha256").hexdigest(),
        "bytes": path.stat().st_size,
        "actualPages": 1000,
        "sampleInk": ink,
        "firstTextCharacters": len(first_text),
        "lastTextCharacters": len(final_text),
    }
    (output / "manifest.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parent / "fixtures")
    arguments = parser.parse_args()
    print(json.dumps(generate(arguments.output.resolve()), ensure_ascii=False, indent=2))
