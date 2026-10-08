import 'dart:convert';

enum DocumentFormat { pdf, epub }

/// 阅读器真实能力；界面按格式提供入口，不制造虚假的页码或坐标。
class ReaderCapabilities {
  const ReaderCapabilities({
    required this.reflow,
    required this.pageCoordinates,
  });
  final bool reflow;
  final bool pageCoordinates;
  static const pdf = ReaderCapabilities(reflow: false, pageCoordinates: true);
  static const epub = ReaderCapabilities(reflow: true, pageCoordinates: false);
}

sealed class DocumentLocator {
  const DocumentLocator();
  DocumentFormat get format;
  Map<String, Object?> toJson();
  String encode() => jsonEncode(toJson());

  static DocumentLocator decode(String value) {
    final json = jsonDecode(value);
    if (json is! Map<String, dynamic> || json['version'] != 1) {
      throw const FormatException('来源定位版本或结构不合法');
    }
    return switch (json['format']) {
      'epub' => EpubLocator.fromJson(json),
      'pdf' => PdfLocator.fromJson(json),
      _ => throw const FormatException('不支持的来源格式'),
    };
  }
}

/// PDF 领域对象继续持有既有精确几何；通用导航只传递页码与偏移。
final class PdfLocator extends DocumentLocator {
  const PdfLocator({required this.pageIndex, this.offset = 0});
  final int pageIndex;
  final double offset;
  @override
  DocumentFormat get format => DocumentFormat.pdf;
  @override
  Map<String, Object?> toJson() => {
    'version': 1,
    'format': 'pdf',
    'pageIndex': pageIndex,
    'offset': offset,
  };
  factory PdfLocator.fromJson(Map<String, dynamic> json) {
    final page = json['pageIndex'];
    final offset = json['offset'];
    if (page is! int || page < 0 || offset is! num || !offset.isFinite) {
      throw const FormatException('PDF 阅读位置不合法');
    }
    return PdfLocator(pageIndex: page, offset: offset.toDouble());
  }
}

final class EpubLocator extends DocumentLocator {
  const EpubLocator({
    required this.href,
    required this.cfi,
    this.quote = '',
    this.prefix = '',
    this.suffix = '',
    this.imageHref,
    this.crop = const [],
  });
  final String href;
  final String cfi;
  final String quote;
  final String prefix;
  final String suffix;
  final String? imageHref;

  /// 原图内的相对矩形 x、y、宽、高；重排截图通过 CFI 内容范围回源。
  final List<double> crop;
  @override
  DocumentFormat get format => DocumentFormat.epub;
  @override
  Map<String, Object?> toJson() => {
    'version': 1,
    'format': 'epub',
    'href': href,
    'cfi': cfi,
    'quote': quote,
    'prefix': prefix,
    'suffix': suffix,
    'imageHref': imageHref,
    'crop': crop,
  };
  factory EpubLocator.fromJson(Map<String, dynamic> json) {
    final href = json['href'];
    final cfi = json['cfi'];
    final crop = json['crop'];
    if (href is! String ||
        !isLocalPublicationPath(href) ||
        cfi is! String ||
        !isEpubCfi(cfi) ||
        cfi.length > 16384 ||
        json['quote'] is! String ||
        json['prefix'] is! String ||
        json['suffix'] is! String ||
        crop is! List ||
        (crop.isNotEmpty && crop.length != 4) ||
        crop.any((v) => v is! num || !v.isFinite || v < 0 || v > 1) ||
        (crop.length == 4 &&
            ((crop[0] as num) + (crop[2] as num) > 1.000001 ||
                (crop[1] as num) + (crop[3] as num) > 1.000001)) ||
        (json['imageHref'] != null &&
            (json['imageHref'] is! String ||
                !isLocalPublicationPath(json['imageHref'] as String)))) {
      throw const FormatException('EPUB 来源定位不合法');
    }
    return EpubLocator(
      href: href,
      cfi: cfi,
      quote: json['quote'] as String,
      prefix: json['prefix'] as String,
      suffix: json['suffix'] as String,
      imageHref: json['imageHref'] as String?,
      crop: crop.cast<num>().map((v) => v.toDouble()).toList(growable: false),
    );
  }
}

/// 忽略断言内部的分隔符，保留转义；CFI 的 ID 可以含斜杠、逗号等字符。
List<String> _cfiParts(String value, String separator) {
  final result = <String>[];
  var start = 0, depth = 0;
  for (var index = 0; index < value.length; index++) {
    final character = value[index];
    if (character == '^') {
      index++;
      continue;
    }
    if (character == '[') depth++;
    if (character == ']') depth--;
    if (depth < 0) throw const FormatException('CFI 断言未闭合');
    if (character == separator && depth == 0) {
      result.add(value.substring(start, index));
      start = index + 1;
    }
  }
  if (depth != 0) throw const FormatException('CFI 断言未闭合');
  result.add(value.substring(start));
  return result;
}

bool isEpubCfi(String value) {
  if (!value.startsWith('epubcfi(') ||
      !value.endsWith(')') ||
      value.length > 16384) {
    return false;
  }
  try {
    final paths = _cfiParts(value.substring(8, value.length - 1), ',');
    if (paths.length != 1 && paths.length != 3) return false;
    for (final path in paths) {
      final structural = StringBuffer();
      var depth = 0;
      for (var index = 0; index < path.length; index++) {
        final character = path[index];
        if (character == '^') {
          if (depth == 0 || ++index >= path.length) return false;
          continue;
        }
        if (character == '[') {
          depth++;
          continue;
        }
        if (character == ']') {
          depth--;
          continue;
        }
        if (depth == 0) structural.write(character);
      }
      if (!RegExp(
        r'^/[1-9]\d*(?:/[1-9]\d*)*(?:!/[1-9]\d*(?:/[1-9]\d*)*)?(?::\d+|~\d+(?:\.\d+)?(?:@\d+(?:\.\d+)?:\d+(?:\.\d+)?)?|@\d+(?:\.\d+)?:\d+(?:\.\d+)?)?$',
      ).hasMatch(structural.toString())) {
        return false;
      }
    }
    return true;
  } on FormatException {
    return false;
  }
}

/// 搜索的 UTF-16 范围与浏览器生成的文本节点点合并，原断言保持原样。
String epubTextRangeCfi(String from, int start, String to, int end) {
  List<String> point(String value, int offset) {
    if (offset < 0 || !isEpubCfi(value)) {
      throw const FormatException('CFI 文本点无效');
    }
    final parts = _cfiParts(value.substring(8, value.length - 1), '/');
    final terminal = parts.last;
    final assertion = terminal.indexOf('[');
    final plain = assertion < 0 ? terminal : terminal.substring(0, assertion);
    if (!RegExp(r'^\d+:\d+$').hasMatch(plain)) {
      throw const FormatException('CFI 缺少字符偏移');
    }
    parts[parts.length - 1] = '${plain.split(':').first}:$offset';
    return parts;
  }

  final a = point(from, start), b = point(to, end);
  var common = 0;
  while (common < a.length - 1 &&
      common < b.length - 1 &&
      a[common] == b[common]) {
    common++;
  }
  if (common < 2) throw const FormatException('CFI 文本范围跨书籍或章节');
  return 'epubcfi(${a.take(common).join('/')},/${a.skip(common).join('/')},/${b.skip(common).join('/')})';
}

bool isLocalPublicationPath(String path) =>
    path.isNotEmpty &&
    !path.startsWith('/') &&
    !path.contains('\\') &&
    !path.contains(':') &&
    !path.contains('\u0000') &&
    !path.split('/').any((p) => p == '..' || p == '.' || p.isEmpty);

class EpubReadingSettings {
  const EpubReadingSettings({
    this.fontSize = 18,
    this.lineHeight = 1.7,
    this.margin = 24,
    this.font = 'Source Han Sans CN',
    this.paginated = false,
    this.fixedZoom = 1,
  });
  final double fontSize;
  final double lineHeight;
  final double margin;
  final String font;
  final bool paginated;
  final double fixedZoom;
  Map<String, Object?> toJson() => {
    'fontSize': fontSize,
    'lineHeight': lineHeight,
    'margin': margin,
    'font': font,
    'paginated': paginated,
    'fixedZoom': fixedZoom,
  };
  factory EpubReadingSettings.fromJson(Map<String, dynamic> json) {
    final size = json['fontSize'];
    final line = json['lineHeight'];
    final margin = json['margin'];
    final zoom = json['fixedZoom'] ?? 1;
    if (size is! num ||
        !size.isFinite ||
        size < 12 ||
        size > 48 ||
        line is! num ||
        !line.isFinite ||
        line < 1 ||
        line > 3 ||
        margin is! num ||
        !margin.isFinite ||
        margin < 0 ||
        margin > 100 ||
        zoom is! num ||
        !zoom.isFinite ||
        zoom < .2 ||
        zoom > 5 ||
        !{'Source Han Sans CN', 'Segoe UI', 'serif'}.contains(json['font']) ||
        json['paginated'] is! bool) {
      throw const FormatException('EPUB 阅读设置不合法');
    }
    return EpubReadingSettings(
      fontSize: size.toDouble(),
      lineHeight: line.toDouble(),
      margin: margin.toDouble(),
      font: json['font'] as String,
      paginated: json['paginated'] as bool,
      fixedZoom: zoom.toDouble(),
    );
  }
}
