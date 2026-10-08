"""生成可复现的真实 PDF 阅读、OCR 和坐标验收样本。"""

from pathlib import Path
import argparse
import hashlib
import json

import pymupdf as fitz
from PIL import Image, ImageDraw, ImageFont
from pypdf import PdfReader, PdfWriter
from pypdf.generic import ArrayObject, DictionaryObject, FloatObject, NameObject, NumberObject


ROOT = Path(__file__).resolve().parent
OUTPUT = ROOT / "pdf"


def native_page(document, english, chinese):
    page = document.new_page(width=600, height=800)
    page.insert_text((70, 100), english, fontsize=22)
    page.insert_text((70, 150), chinese, fontname="china-s", fontsize=22)
    page.insert_text((70, 220), "Source anchors remain stable after zoom and rotation.", fontsize=14)
    return page


def scanned_page(document):
    image = Image.new("RGB", (1200, 1600), "white")
    draw = ImageDraw.Draw(image)
    font = ImageFont.truetype("C:/Windows/Fonts/msyh.ttc", 42)
    draw.text((140, 160), "OpenNote scanned page", fill="black", font=font)
    draw.text((140, 250), "离线中文识别与英文搜索", fill="black", font=font)
    draw.text((140, 360), "OCR selection must preserve PDF source coordinates.", fill="black", font=font)
    import io

    buffer = io.BytesIO()
    image.save(buffer, format="PNG")
    page = document.new_page(width=600, height=800)
    page.insert_image(page.rect, stream=buffer.getvalue())
    return page


def linked_document():
    """生成真正的页面 /Link 注释，并从 PDF 字典记录标准用户坐标。"""
    path = OUTPUT / "links.pdf"
    document = fitz.open()
    first = document.new_page(width=600, height=800)
    document.new_page(width=600, height=800)
    # 加页后重新取页，避免 PyMuPDF 的旧 page 对象失效。
    first = document[0]
    second = document[1]
    first.insert_text((70, 100), "Jump to second page", fontsize=20)
    first.insert_text((70, 170), "Annotation has priority", fontsize=20)
    first.insert_text((70, 252), "External link is not supported yet", fontsize=16)
    first.insert_text((70, 330), "Drag text or draw a rectangle without navigating.", fontsize=16)
    first.insert_text((70, 400), "真实 PDF 文内链接与拖动摘录", fontname="china-s", fontsize=20)
    first.insert_text((70, 470), "Incomplete destination must not crash", fontsize=16)
    for rectangle in (fitz.Rect(70, 76, 360, 110), fitz.Rect(70, 146, 360, 180)):
        first.draw_rect(rectangle, color=(0.2, 0.4, 0.8), width=0.8)
        first.insert_link({"kind": fitz.LINK_GOTO, "from": rectangle, "page": 1, "to": fitz.Point(70, 100)})
    first.insert_link({
        "kind": fitz.LINK_URI,
        "from": fitz.Rect(70, 226, 450, 264),
        "uri": "https://example.org/opennote-fixture",
    })
    second.insert_text((70, 100), "Return to first page", fontsize=20)
    second.insert_text((70, 220), "Second page destination", fontsize=24)
    second.insert_text((70, 290), "第二页：文内跳转目的地", fontname="china-s", fontsize=20)
    second.insert_link({
        "kind": fitz.LINK_GOTO,
        "from": fitz.Rect(70, 76, 360, 110),
        "page": 0,
        "to": fitz.Point(70, 100),
    })
    document.save(path)
    document.close()

    # 真实但参数不完整的 /XYZ 目标，供阅读器验证公开 goToDest 返回 false。
    writer = PdfWriter()
    writer.clone_document_from_reader(PdfReader(path))
    writer.add_annotation(0, DictionaryObject({
        NameObject("/Subtype"): NameObject("/Link"),
        NameObject("/Rect"): ArrayObject([FloatObject(70), FloatObject(320), FloatObject(430), FloatObject(354)]),
        NameObject("/A"): DictionaryObject({
            NameObject("/S"): NameObject("/GoTo"),
            NameObject("/D"): ArrayObject([writer.pages[1].indirect_reference, NameObject("/XYZ")]),
        }),
    }))
    writer.write(path)

    reader = PdfReader(path)
    page_references = {page.indirect_reference.idnum: index for index, page in enumerate(reader.pages)}
    links = []
    for page_index, page in enumerate(reader.pages):
        for reference in page.get("/Annots", []):
            annotation = reference.get_object()
            if annotation.get("/Subtype") != "/Link":
                continue
            action = annotation.get("/A", {})
            destination = annotation.get("/Dest") or action.get("/D")
            entry = {"pageIndex": page_index, "rect": [float(value) for value in annotation["/Rect"]]}
            if destination is not None:
                entry.update({
                    "type": "goTo",
                    "destinationPageIndex": page_references[destination[0].idnum],
                    "destinationCommand": str(destination[1]),
                })
                if len(destination) >= 4:
                    entry["destinationPdfPoint"] = [float(destination[2]), float(destination[3])]
                else:
                    entry["expectedNavigationFailure"] = True
            else:
                entry.update({"type": "uri", "uri": str(action["/URI"])})
            links.append(entry)
    return {"sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "pages": len(reader.pages), "links": links}


def main(links_only=False):
    OUTPUT.mkdir(parents=True, exist_ok=True)
    if links_only:
        manifest_path = OUTPUT / "manifest.json"
        fixtures = json.loads(manifest_path.read_text(encoding="utf-8"))
        fixtures["links.pdf"] = linked_document()
        manifest_path.write_text(json.dumps(fixtures, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(fixtures["links.pdf"], ensure_ascii=False, indent=2))
        return
    document = fitz.open()
    native_page(document, "OpenNote native text first page", "原生文字选择与来源定位")
    native_page(document, "Second page for cross-page excerpts", "跨页摘录必须分段保存")
    document.set_toc([[1, "First chapter", 1], [1, "Second chapter", 2]])
    document.save(OUTPUT / "native.pdf")
    document.close()

    document = fitz.open()
    scanned_page(document)
    document.save(OUTPUT / "scanned.pdf")
    document.close()

    document = fitz.open()
    native_page(document, "Mixed document native page", "混合文档的原生页")
    scanned_page(document)
    native_page(document, "Mixed document final page", "混合文档的末页")
    document.save(OUTPUT / "mixed.pdf")
    document.close()

    reader = PdfReader(OUTPUT / "native.pdf")
    writer = PdfWriter()
    expected = []
    for rotation in (0, 90, 180, 270):
        writer.add_page(reader.pages[0])
        page = writer.pages[-1]
        page[NameObject("/MediaBox")] = ArrayObject([FloatObject(-30), FloatObject(-50), FloatObject(650), FloatObject(850)])
        page[NameObject("/CropBox")] = ArrayObject([FloatObject(40), FloatObject(60), FloatObject(570), FloatObject(750)])
        page[NameObject("/Rotate")] = NumberObject(rotation)
        page[NameObject("/UserUnit")] = FloatObject(1.5)
        expected.append({"rotation": rotation, "mediaBox": [-30, -50, 650, 850], "cropBox": [40, 60, 570, 750], "userUnit": 1.5})
    with (OUTPUT / "rotate_cropbox.pdf").open("wb") as stream:
        writer.write(stream)

    document = fitz.open(OUTPUT / "rotate_cropbox.pdf")
    document.save(OUTPUT / "compressed_geometry.pdf", deflate=True, use_objstms=1)
    document.close()

    link_details = linked_document()
    fixtures = {}
    for path in sorted(OUTPUT.glob("*.pdf")):
        check = PdfReader(path)
        fixtures[path.name] = {"sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "pages": len(check.pages)}
    fixtures["rotate_cropbox.pdf"]["geometry"] = expected
    fixtures["compressed_geometry.pdf"]["geometry"] = expected
    fixtures["links.pdf"] = link_details
    (OUTPUT / "manifest.json").write_text(json.dumps(fixtures, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(fixtures, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--links-only", action="store_true", help="只补链接样本，不重生成既有 PDF")
    main(links_only=parser.parse_args().links_only)
