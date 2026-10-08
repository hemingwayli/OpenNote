import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:opennote/engines/epub/epub_publication.dart';
import 'package:opennote/domain/document_locator.dart';

Uint8List fixture(String name) =>
    File('tools/fixtures/epub/$name.epub').readAsBytesSync();
Uint8List changed(void Function(Archive) action) {
  final archive = ZipDecoder().decodeBytes(fixture('epub3-reflow'));
  action(archive);
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void main() {
  for (final name in [
    'epub3-reflow',
    'epub2-reflow',
    'epub3-vertical',
    'epub3-fixed',
  ]) {
    test('解析 $name 的章节目录且不执行书籍脚本', () {
      final bytes = fixture(name);
      final publication = EpubPublication.fromBytes(bytes);
      expect(publication.sections.length, 2);
      expect(publication.outline.map((i) => i.title), ['第一章', '第二章']);
      expect(publication.sections.first.href, 'OPS/ch1.xhtml');
      expect(publication.sections.first.fixedLayout, name == 'epub3-fixed');
      expect(publication.direction, name == 'epub3-vertical' ? 'rtl' : 'ltr');
      final sanitized = String.fromCharCodes(
        publication.resources['OPS/ch1.xhtml']!,
      );
      expect(sanitized, isNot(contains('<script')));
      expect(sanitized, isNot(contains('onclick')));
      expect(sanitized, contains('MathML'));
      expect(bytes, orderedEquals(fixture(name)));
    });
  }
  test('拒绝 ZIP 路径越界和符号链接', () {
    expect(
      () => EpubPublication.fromBytes(
        changed(
          (archive) => archive.add(ArchiveFile('../outside', 3, [1, 2, 3])),
        ),
      ),
      throwsFormatException,
    );
  });
  test('EPUB 3 分组目录保留 span 标题及有正文的父章节', () {
    final bytes = changed(
      (archive) => archive.add(
        ArchiveFile.string(
          'OPS/nav.xhtml',
          '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body>'
              '<nav epub:type="toc"><ol><li><span>上篇</span><ol><li><a href="ch1.xhtml">第一章</a></li></ol></li>'
              '<li><a href="ch2.xhtml#intro">下篇正文</a><ol><li><a href="ch2.xhtml">第二章</a></li></ol></li>'
              '</ol></nav></body></html>',
        ),
      ),
    );
    final outline = EpubPublication.fromBytes(bytes).outline;
    expect(outline.first.title, '上篇');
    expect(outline.first.href, isEmpty);
    expect(outline.first.children.single.title, '第一章');
    expect(outline.last.title, '下篇正文');
    expect(outline.last.href, 'OPS/ch2.xhtml#intro');
    expect(outline.last.children.single.href, 'OPS/ch2.xhtml');
  });
  test('拒绝损坏的阅读顺序且不创建部分文档', () {
    final bytes = changed((archive) {
      final old = archive.findFile('OPS/package.opf')!;
      final text = String.fromCharCodes(old.content)
          .replaceAll('idref="c1"', 'idref="missing"');
      archive.add(ArchiveFile.string('OPS/package.opf', text));
    });
    expect(() => EpubPublication.fromBytes(bytes), throwsFormatException);
  });
  test('来源编码保持 CFI、原文和图片裁剪', () {
    const locator = EpubLocator(
      href: 'OPS/ch1.xhtml',
      cfi: 'epubcfi(/6/2!/4/2/1:0)',
      quote: '中文',
      imageHref: 'OPS/image.png',
      crop: [0.1, 0.2, 0.3, 0.4],
    );
    final restored = DocumentLocator.decode(locator.encode()) as EpubLocator;
    expect(restored.toJson(), locator.toJson());
    expect(
      () => DocumentLocator.decode(
        locator.encode().replaceAll('OPS/ch1.xhtml', '../x'),
      ),
      throwsFormatException,
    );
    expect(
      () => DocumentLocator.decode(
        locator.encode().replaceAll('epubcfi(', 'evil('),
      ),
      throwsFormatException,
    );
  });
  test('阅读设置拒绝无穷数与越界字号', () {
    expect(
      () => EpubReadingSettings.fromJson({
        ...const EpubReadingSettings().toJson(),
        'fontSize': 100,
      }),
      throwsFormatException,
    );
    expect(
      () => EpubReadingSettings.fromJson({
        ...const EpubReadingSettings().toJson(),
        'lineHeight': double.nan,
      }),
      throwsFormatException,
    );
  });
  test('混合版式逐章节保存布局且封面来自原图', () {
    final book = EpubPublication.fromBytes(fixture('epub3-mixed'));
    expect(book.sections.map((s) => s.fixedLayout), [false, true]);
    expect(book.coverPath, 'OPS/image.png');
    expect(
      book.resources[book.coverPath],
      orderedEquals(File('test/ocr/fixtures/bilingual.png').readAsBytesSync()),
    );
  });
  test('标准字体混淆逐字节还原并拒绝真正的 DRM', () {
    const uid = 'urn:uuid:347b2d9b-4b8c-4cce-9750-1b6ff826f5ef';
    final original = List<int>.generate(1500, (i) => i % 256);
    for (final algorithm in [
      'http://www.idpf.org/2008/embedding',
      'http://ns.adobe.com/pdf/enc#RC',
    ]) {
      final key = algorithm.contains('idpf')
          ? sha1.convert(utf8.encode(uid)).bytes
          : [
              for (var i = 0; i < 32; i += 2)
                int.parse(
                  uid.substring(9).replaceAll('-', '').substring(i, i + 2),
                  radix: 16,
                ),
            ];
      final data = List<int>.from(original);
      for (var i = 0; i < (algorithm.contains('idpf') ? 1040 : 1024); i++) {
        data[i] ^= key[i % key.length];
      }
      final bytes = changed((archive) {
        archive.add(ArchiveFile('OPS/font.otf', data.length, data));
        archive.add(
          ArchiveFile.string(
            'META-INF/encryption.xml',
            '<encryption><EncryptedData><EncryptionMethod Algorithm="$algorithm"/><CipherData><CipherReference URI="OPS/font.otf"/></CipherData></EncryptedData></encryption>',
          ),
        );
      });
      expect(
        EpubPublication.fromBytes(bytes).resources['OPS/font.otf'],
        orderedEquals(original),
      );
    }
    expect(
      () => EpubPublication.fromBytes(
        changed((archive) {
          archive.add(
            ArchiveFile.string(
              'META-INF/encryption.xml',
              '<encryption><EncryptedData><EncryptionMethod Algorithm="aes"/><CipherData><CipherReference URI="OPS/ch1.xhtml"/></CipherData></EncryptedData></encryption>',
            ),
          );
        }),
      ),
      throwsFormatException,
    );
  });
  test('CFI 搜索范围保留带斜杠与转义字符的断言', () {
    const point = 'epubcfi(/6/2[chapter/a^,b]!/4/4[paragraph/x]/1:0)';
    expect(isEpubCfi(point), isTrue);
    expect(
      epubTextRangeCfi(point, 2, point, 4),
      'epubcfi(/6/2[chapter/a^,b]!/4/4[paragraph/x],/1:2,/1:4)',
    );
    expect(isEpubCfi('epubcfi(foo)'), isFalse);
    expect(isEpubCfi('epubcfi(/6/2[broken)'), isFalse);
  });
  test('EPUB 2 XHTML 命名实体和 UTF-16 XML 在缓存中规范化，原件不改写', () {
    final bytes = changed((archive) {
      var text = utf8.decode(archive.findFile('OPS/ch1.xhtml')!.content);
      text = text
          .replaceFirst('encoding="utf-8"', 'encoding="utf-16"')
          .replaceFirst('安全正文', '安全&nbsp;正文');
      final data = <int>[
        255,
        254,
        for (final unit in text.codeUnits) ...[unit & 255, unit >> 8],
      ];
      archive.add(ArchiveFile('OPS/ch1.xhtml', data.length, data));
    });
    final publication = EpubPublication.fromBytes(bytes);
    final text = utf8.decode(publication.resources['OPS/ch1.xhtml']!);
    expect(text, contains('encoding="utf-8"'));
    expect(text, contains('安全\u00a0正文'));
  });
}
