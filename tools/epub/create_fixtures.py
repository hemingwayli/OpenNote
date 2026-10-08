"""生成可随源码分发的 EPUB 2／3 测试书，不包含用户或第三方书页。"""
from pathlib import Path
import zipfile

ROOT = Path(__file__).resolve().parents[2]
TARGET = ROOT / 'tools/fixtures/epub'


def make(name: str, version: str = '3.0', fixed: bool = False, vertical: bool = False, mixed: bool = False) -> None:
    TARGET.mkdir(parents=True, exist_ok=True)
    layout = '<meta property="rendition:layout">pre-paginated</meta>' if fixed else ''
    text = '中文阅读测试：知识通过摘录与脑图整理。中文竖排与英文 example 均保留来源。日本語の縦書き。한국어 세로 쓰기。'
    style = 'body{writing-mode:vertical-rl;text-orientation:mixed;}' if vertical else 'body{font-family:serif;}'
    extra = '<meta name="viewport" content="width=800,height=1000"/>' if fixed else ''
    chapters = {}
    for number in (1, 2):
        chapters[f'OPS/ch{number}.xhtml'] = f'''<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>第{number}章</title>{extra}<style>{style}</style></head><body>
<h1 id="title">第{number}章：OpenNote 自产样本</h1><p>{text}</p><p>Repeated English source keeps the same anchor after reflow.</p>
<table><tr><th>项目</th><th>数值</th></tr><tr><td>测试</td><td>42</td></tr></table>
<svg xmlns="http://www.w3.org/2000/svg" width="120" height="60"><rect width="100" height="50" fill="#3574cb"/><text x="5" y="30" fill="white">SVG</text></svg>
<math xmlns="http://www.w3.org/1998/Math/MathML"><mfrac><mi>a</mi><mi>b</mi></mfrac></math>
<img src="image.png" alt="OpenNote 自产中英文字图片" width="360"/>
<p><a epub:type="noteref" href="#note">脚注1</a> <a href="ch{3-number}.xhtml#title">下一章节</a></p><aside epub:type="footnote" id="note">脚注内容</aside>
<script>throw Error('书籍脚本不应执行');</script><p onclick="alert(1)">安全正文</p>
</body></html>'''
    nav = '''<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>目录</title></head><body><nav epub:type="toc"><ol><li><a href="ch1.xhtml">第一章</a></li><li><a href="ch2.xhtml">第二章</a></li></ol></nav></body></html>'''
    ncx = '''<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head/><docTitle><text>样本</text></docTitle><navMap><navPoint id="n1" playOrder="1"><navLabel><text>第一章</text></navLabel><content src="ch1.xhtml"/></navPoint><navPoint id="n2" playOrder="2"><navLabel><text>第二章</text></navLabel><content src="ch2.xhtml"/></navPoint></navMap></ncx>'''
    opf = f'''<?xml version="1.0" encoding="utf-8"?><package xmlns="http://www.idpf.org/2007/opf" version="{version}" unique-identifier="uid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">urn:uuid:347b2d9b-4b8c-4cce-9750-1b6ff826f5ef</dc:identifier><dc:title>OpenNote {name}</dc:title><dc:creator>OpenNote</dc:creator><dc:language>zh-CN</dc:language>{layout}</metadata><manifest><item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/><item id="c2" href="ch2.xhtml" media-type="application/xhtml+xml"/><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/></manifest><spine toc="ncx" page-progression-direction="{'rtl' if vertical else 'ltr'}"><itemref idref="c1"/><itemref idref="c2"/></spine></package>'''
    if version == '2.0':
        opf = opf.replace(' properties="nav"', '')
    opf = opf.replace('<item id="nav"', '<item id="image" href="image.png" media-type="image/png" properties="cover-image"/><item id="nav"')
    if mixed:
        opf=opf.replace('<itemref idref="c2"/>','<itemref idref="c2" properties="rendition:layout-pre-paginated"/>')
        chapters['OPS/ch2.xhtml']=chapters['OPS/ch2.xhtml'].replace('<style>', '<meta name="viewport" content="width=800,height=1000"/><style>')
    container = '''<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>'''
    with zipfile.ZipFile(TARGET / f'{name}.epub', 'w', zipfile.ZIP_DEFLATED) as archive:
        archive.writestr('mimetype','application/epub+zip',compress_type=zipfile.ZIP_STORED)
        for path, content in {'META-INF/container.xml':container,'OPS/package.opf':opf,
            'OPS/nav.xhtml':nav,'OPS/toc.ncx':ncx,**chapters}.items():
            archive.writestr(path,content.encode('utf-8'))
        archive.write(ROOT/'test/ocr/fixtures/bilingual.png','OPS/image.png')


if __name__ == '__main__':
    make('epub3-reflow')
    make('epub2-reflow','2.0')
    make('epub3-vertical',vertical=True)
    make('epub3-fixed',fixed=True)
    make('epub3-mixed',mixed=True)
    print(f'自产 EPUB 样本已生成：{TARGET}')
