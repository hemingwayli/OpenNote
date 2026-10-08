import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../../domain/document_locator.dart';

class EpubSection {
  const EpubSection({
    required this.href,
    required this.id,
    required this.title,
    required this.fixedLayout,
    required this.index,
  });
  final String href;
  final String id;
  final String title;
  final bool fixedLayout;
  final int index;
  Map<String, Object?> toJson() => {
    'href': href,
    'id': id,
    'title': title,
    'fixedLayout': fixedLayout,
    'index': index,
  };
}

class EpubOutlineItem {
  const EpubOutlineItem(this.title, this.href, this.children);
  final String title;
  final String href;
  final List<EpubOutlineItem> children;
}

/// 原始 ZIP 字节只读；仅缓存中的正文去掉脚本，字体按标准解除混淆。
class EpubPublication {
  EpubPublication._({
    required this.title,
    required this.author,
    required this.packagePath,
    required this.sections,
    required this.outline,
    required this.resources,
    required this.direction,
    required this.contentHash,
    this.coverPath,
  });
  final String title;
  final String author;
  final String packagePath;
  final List<EpubSection> sections;
  final List<EpubOutlineItem> outline;
  final Map<String, Uint8List> resources;
  final String direction;
  final String contentHash;
  final String? coverPath;

  static Future<EpubPublication> open(String path) => Isolate.run(
    () => EpubPublication.fromBytes(File(path).readAsBytesSync()),
  );

  factory EpubPublication.fromBytes(Uint8List bytes) {
    if (bytes.length > 512 * 1024 * 1024) {
      throw const FormatException('EPUB 超过 512 MiB 的导入边界');
    }
    final archive = ZipDecoder().decodeBytes(bytes, verify: true);
    if (archive.length > 20000) throw const FormatException('EPUB 资源数量过多');
    final resources = <String, Uint8List>{};
    var total = 0;
    for (final file in archive) {
      final name = file.name;
      if (!file.isFile) continue;
      if (!isLocalPublicationPath(name) ||
          resources.containsKey(name) ||
          file.isSymbolicLink) {
        throw const FormatException('EPUB 包含越界、重复或符号链接资源');
      }
      total += file.size;
      if (total > 1024 * 1024 * 1024 || file.size > 128 * 1024 * 1024) {
        throw const FormatException('EPUB 解压资源超过安全边界');
      }
      resources[name] = Uint8List.fromList(file.content);
    }
    if (utf8.decode(resources['mimetype'] ?? []) != 'application/epub+zip') {
      throw const FormatException('文件不是有效 EPUB');
    }
    XmlDocument readXml(String path) {
      final data = resources[path];
      if (data == null) throw FormatException('EPUB 缺少资源：$path');
      final document = XmlDocument.parse(
        _xmlText(data),
        entityMapping: const XmlDefaultEntityMapping.html5(),
      );
      document.declaration?.setAttribute('encoding', 'utf-8');
      resources[path] = Uint8List.fromList(utf8.encode(document.toXmlString()));
      return document;
    }

    final container = readXml('META-INF/container.xml');
    final root = _elements(container, 'rootfile').firstOrNull;
    final packagePath = root?.getAttribute('full-path');
    if (packagePath == null || !isLocalPublicationPath(packagePath)) {
      throw const FormatException('EPUB 根文件路径不合法');
    }
    final package = readXml(packagePath);
    final packageElement = package.rootElement;
    if (!{'2.0', '3.0'}.contains(packageElement.getAttribute('version'))) {
      throw const FormatException('仅支持 EPUB 2／3');
    }
    final manifest = <String, XmlElement>{};
    for (final item in _elements(package, 'item')) {
      final id = item.getAttribute('id');
      final href = item.getAttribute('href');
      if (id == null || href == null || manifest.containsKey(id)) {
        throw const FormatException('EPUB 资源清单不合法');
      }
      final path = resolvePath(packagePath, href);
      if (!resources.containsKey(path)) {
        throw FormatException('EPUB 缺少资源：$path');
      }
      manifest[id] = item;
    }
    final uidName = packageElement.getAttribute('unique-identifier');
    final uid =
        _elements(package, 'identifier')
            .where((e) => e.getAttribute('id') == uidName)
            .firstOrNull
            ?.innerText ??
        '';
    if (resources.containsKey('META-INF/encryption.xml')) {
      _decodeFonts(readXml('META-INF/encryption.xml'), uid, resources);
    }
    final spine = _elements(package, 'spine').firstOrNull;
    if (spine == null) throw const FormatException('EPUB 缺少阅读顺序');
    final fixed = _elements(package, 'meta').any(
      (e) =>
          e.getAttribute('property') == 'rendition:layout' &&
          e.innerText.trim() == 'pre-paginated',
    );
    final outline = <EpubOutlineItem>[];
    final nav = manifest.values
        .where(
          (e) =>
              (e.getAttribute('properties') ?? '').split(' ').contains('nav'),
        )
        .firstOrNull;
    if (nav != null) {
      final navPath = resolvePath(packagePath, nav.getAttribute('href')!);
      final navXml = readXml(navPath);
      final toc = _elements(navXml, 'nav')
          .where(
            (e) => e.attributes.any(
              (a) =>
                  a.name.local == 'type' && a.value.split(' ').contains('toc'),
            ),
          )
          .firstOrNull;
      final list = toc?.childElements
          .where((e) => e.name.local == 'ol')
          .firstOrNull;
      if (list != null) outline.addAll(_navList(list, navPath));
    } else {
      final ncx = manifest[spine.getAttribute('toc')];
      if (ncx != null) {
        final ncxPath = resolvePath(packagePath, ncx.getAttribute('href')!);
        final map = _elements(readXml(ncxPath), 'navMap').firstOrNull;
        if (map != null) outline.addAll(_ncxList(map, ncxPath));
      }
    }
    String outlineTitle(String href) {
      String? find(List<EpubOutlineItem> items) {
        for (final item in items) {
          if (item.href.split('#').first == href) return item.title;
          final result = find(item.children);
          if (result != null) return result;
        }
        return null;
      }

      return find(outline) ?? p.posix.basenameWithoutExtension(href);
    }

    final sections = <EpubSection>[];
    for (final ref in spine.childElements.where(
      (e) => e.name.local == 'itemref',
    )) {
      final id = ref.getAttribute('idref');
      final item = manifest[id];
      if (item == null) throw const FormatException('EPUB 阅读顺序引用缺失');
      final href = resolvePath(packagePath, item.getAttribute('href')!);
      final properties = (ref.getAttribute('properties') ?? '').split(' ');
      sections.add(
        EpubSection(
          href: href,
          id: id!,
          title: outlineTitle(href),
          fixedLayout:
              properties.contains('rendition:layout-pre-paginated') ||
              (fixed && !properties.contains('rendition:layout-reflowable')),
          index: sections.length,
        ),
      );
    }
    if (sections.isEmpty) throw const FormatException('EPUB 没有可阅读内容');
    for (final item in manifest.values) {
      if (!{
        'application/xhtml+xml',
        'image/svg+xml',
      }.contains(item.getAttribute('media-type'))) {
        continue;
      }
      final href = resolvePath(packagePath, item.getAttribute('href')!);
      final document = readXml(href);
      _sanitize(document);
      resources[href] = Uint8List.fromList(utf8.encode(document.toXmlString()));
    }
    final cover =
        manifest.values
            .where(
              (e) => (e.getAttribute('properties') ?? '')
                  .split(' ')
                  .contains('cover-image'),
            )
            .firstOrNull ??
        manifest[_elements(package, 'meta')
            .where((e) => e.getAttribute('name') == 'cover')
            .firstOrNull
            ?.getAttribute('content')];
    return EpubPublication._(
      title:
          _elements(package, 'title').firstOrNull?.innerText.trim() ?? 'EPUB',
      author: _elements(package, 'creator').firstOrNull?.innerText.trim() ?? '',
      packagePath: packagePath,
      sections: List.unmodifiable(sections),
      contentHash: sha256.convert(bytes).toString(),
      outline: List.unmodifiable(outline),
      resources: resources,
      direction: spine.getAttribute('page-progression-direction') == 'rtl'
          ? 'rtl'
          : 'ltr',
      coverPath: cover == null
          ? null
          : resolvePath(packagePath, cover.getAttribute('href')!),
    );
  }

  Map<String, Object?> metadata() => {
    'title': title,
    'author': author,
    'packagePath': packagePath,
    'coverPath': coverPath,
    'direction': direction,
    'sections': sections.map((s) => s.toJson()).toList(),
  };

  static String resolvePath(String base, String href) {
    final uri = Uri.parse(href);
    if (uri.hasScheme || uri.hasAuthority || uri.path.startsWith('/')) {
      throw const FormatException('EPUB 依赖外部或绝对资源');
    }
    final path = p.posix.normalize(
      p.posix.join(p.posix.dirname(base), Uri.decodeComponent(uri.path)),
    );
    if (!isLocalPublicationPath(path)) {
      throw const FormatException('EPUB 资源路径越界');
    }
    return path;
  }
}

Iterable<XmlElement> _elements(XmlNode node, String local) => node.descendants
    .whereType<XmlElement>()
    .where((e) => e.name.local == local);

List<EpubOutlineItem> _navList(XmlElement list, String base) {
  final result = <EpubOutlineItem>[];
  for (final li in list.childElements.where((e) => e.name.local == 'li')) {
    // 分组可以只有 span；不能把后代第一章的链接误当成分组标题。
    final label = li.childElements
        .where((e) => {'a', 'span'}.contains(e.name.local))
        .firstOrNull;
    final children = li.childElements
        .where((e) => e.name.local == 'ol')
        .expand((e) => _navList(e, base))
        .toList();
    if (label == null) continue;
    final href = label.getAttribute('href');
    result.add(
      EpubOutlineItem(
        label.innerText.trim(),
        href == null
            ? ''
            : '${EpubPublication.resolvePath(base, href)}${Uri.parse(href).hasFragment ? '#${Uri.parse(href).fragment}' : ''}',
        children,
      ),
    );
  }
  return result;
}

List<EpubOutlineItem> _ncxList(XmlElement list, String base) => [
  for (final point in list.childElements.where(
    (e) => e.name.local == 'navPoint',
  ))
    if (point.childElements.where((e) => e.name.local == 'content').firstOrNull
        case final content?)
      EpubOutlineItem(
        _elements(point, 'navLabel').firstOrNull?.innerText.trim() ?? '',
        '${EpubPublication.resolvePath(base, content.getAttribute('src') ?? '')}${Uri.parse(content.getAttribute('src') ?? '').hasFragment ? '#${Uri.parse(content.getAttribute('src')!).fragment}' : ''}',
        _ncxList(point, base),
      ),
];

void _sanitize(XmlDocument document) {
  for (final element in document.descendants.whereType<XmlElement>().toList()) {
    if (element.name.local.toLowerCase() == 'meta' &&
        element.getAttribute('http-equiv')?.toLowerCase() == 'refresh') {
      element.parent?.children.remove(element);
      continue;
    }
    if ({
      'script',
      'iframe',
      'object',
      'embed',
      'form',
      'audio',
      'video',
      'base',
    }.contains(element.name.local.toLowerCase())) {
      element.parent?.children.remove(element);
      continue;
    }
    element.attributes.removeWhere(
      (a) =>
          a.name.local.toLowerCase().startsWith('on') ||
          a.name.local.toLowerCase() == 'srcdoc' ||
          ({'src', 'href', 'action'}.contains(a.name.local.toLowerCase()) &&
              RegExp(
                r'^\s*(javascript|file|vbscript):',
                caseSensitive: false,
              ).hasMatch(a.value)),
    );
  }
}

void _decodeFonts(
  XmlDocument encryption,
  String uid,
  Map<String, Uint8List> resources,
) {
  for (final encrypted in _elements(encryption, 'EncryptedData')) {
    final algorithm = _elements(
      encrypted,
      'EncryptionMethod',
    ).firstOrNull?.getAttribute('Algorithm');
    final href = _elements(
      encrypted,
      'CipherReference',
    ).firstOrNull?.getAttribute('URI');
    if (href == null || !isLocalPublicationPath(Uri.decodeComponent(href))) {
      throw const FormatException('EPUB 加密资源路径不合法');
    }
    final path = Uri.decodeComponent(href);
    final data = resources[path];
    if (data == null) throw const FormatException('EPUB 加密资源缺失');
    late List<int> key;
    late int length;
    if (algorithm == 'http://www.idpf.org/2008/embedding') {
      if (uid.isEmpty) throw const FormatException('字体混淆缺少书籍标识');
      key = sha1.convert(utf8.encode(uid.replaceAll(RegExp(r'\s'), ''))).bytes;
      length = 1040;
    } else if (algorithm == 'http://ns.adobe.com/pdf/enc#RC') {
      final hex = uid.replaceFirst('urn:uuid:', '').replaceAll('-', '');
      if (!RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(hex)) {
        throw const FormatException('Adobe 字体混淆标识不合法');
      }
      key = [
        for (var i = 0; i < 32; i += 2)
          int.parse(hex.substring(i, i + 2), radix: 16),
      ];
      length = 1024;
    } else {
      throw const FormatException('本书包含 DRM 或不支持的加密资源，需要授权阅读器');
    }
    final decoded = Uint8List.fromList(data);
    for (var i = 0; i < decoded.length && i < length; i++) {
      decoded[i] ^= key[i % key.length];
    }
    resources[path] = decoded;
  }
}

String _xmlText(Uint8List data) {
  if (data.length >= 2 &&
      ((data[0] == 255 && data[1] == 254) ||
          (data[0] == 254 && data[1] == 255))) {
    if (data.length.isOdd) throw const FormatException('UTF-16 XML 字节不完整');
    final little = data[0] == 255;
    return String.fromCharCodes([
      for (var i = 2; i < data.length; i += 2)
        little ? data[i] | data[i + 1] << 8 : data[i] << 8 | data[i + 1],
    ]);
  }
  return utf8.decode(data);
}
