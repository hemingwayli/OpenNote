"""保存微软应用本地 C++ 运行库的官方许可原件及可离线阅读的 UTF-8 正文。"""
from __future__ import annotations

import shutil
import xml.etree.ElementTree as ET
import zipfile

from bootstrap_windows import ROOT, fetch

PAGE_URL = 'https://visualstudio.microsoft.com/license-terms/vs2026-ga-visualcpp-v14-redist-runtime/'
DOCUMENT_URL = 'https://visualstudio.microsoft.com/wp-content/uploads/2025/10/Visual-C-V14-License-Redistributable_and_Runtime_ENU.docx'


def main():
    document = ROOT / '.local' / 'vc-runtime-license.docx'
    fetch(DOCUMENT_URL, document)
    with zipfile.ZipFile(document) as package:
        root = ET.fromstring(package.read('word/document.xml'))
    ns = {'w': 'http://schemas.openxmlformats.org/wordprocessingml/2006/main'}
    paragraphs = [''.join(p.itertext()) for p in root.findall('.//w:p', ns)]
    content = '\n'.join(paragraphs)
    if 'MICROSOFT SOFTWARE LICENSE TERMS' not in content.upper():
        raise RuntimeError('官方文件未含预期许可正文')
    destination = ROOT / 'assets' / 'licenses' / 'Microsoft-VC-Runtime.txt'
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(f'Source: {PAGE_URL}\nOriginal: {DOCUMENT_URL}\n\n{content}\n', encoding='utf-8')
    shutil.copyfile(document, destination.with_suffix('.docx'))
    print(str(destination), flush=True)


if __name__ == '__main__':
    main()
