import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:opennote/domain/models.dart';
import 'package:opennote/engines/pdf/pdf_excerpt_text.dart';
import 'package:opennote/engines/pdf/pdf_text_selection.dart';

void main() {
  for (final precision in [
    GeometryPrecision.character,
    GeometryPrecision.approximateCharacter,
    GeometryPrecision.line,
  ]) {
    test('中文断词：$precision 使用完整行整理半行选区，原始锚点不变', () {
      final page = _page([
        '感到焦虑的人会反复疑虑和沉思。对即将发生的负',
        '面事件的疑虑趋向被称为忧虑。焦虑也连带一些不适的生理反应。',
        '这些感觉让人不安。',
      ], precision: precision);
      final start = page.layer.text.indexOf('对即将');
      final end = page.layer.text.indexOf('忧虑。') + '忧虑。'.length;
      final anchor = _anchor(page.layer, start: start, end: end);
      final context = anchor.context;
      final quads = List.of(anchor.quads);
      expect(_format(page, [anchor]), '对即将发生的负面事件的疑虑趋向被称为忧虑。');
      expect(anchor.context, context);
      expect(context, contains('负\n面'));
      expect(anchor.textStart, start);
      expect(anchor.textEnd, end);
      expect(anchor.textLayerId, 'layer');
      expect(anchor.quads, quads);
      expect(page.layer.text, contains('负\n面'));
    });
  }

  test('同段多句：句号不是段落边界，中文和标点之间不加空格', () {
    final page = _page([
      '第一句话的末尾恰好位于这一行的右边界。',
      '第二句话仍属于同一个段落，不能只因为句号就换行。',
      '最后一句结束。',
    ]);
    expect(_format(page), page.layer.text.replaceAll('\n', ''));
  });

  test('英文折行：去掉边界排版空白，保留单词空格和原有连字符', () {
    for (final pair in [
      (
        'The paragraph finishes this full line with alpha   ',
        '   beta continues',
      ),
      (
        'The paragraph finishes this full line with inter-',
        'national continues',
      ),
      ('The paragraph finishes this full line.   ', '   Another sentence'),
    ]) {
      final page = _page([pair.$1, pair.$2, 'A short ending.']);
      final expected =
          '${pair.$1.trimRight()}'
          '${pair.$1.trimRight().endsWith('-') ? '' : ' '}'
          '${pair.$2.trimLeft()} A short ending.';
      expect(_format(page), expected);
    }
  });

  test('真实段落：保留段首缩进和空行，不通过标点猜测', () {
    final indented = _page(
      ['这一行已经写到了完整正文栏的右侧边界。', '下一段有两个字的首行缩进，应当保留换行。', '短段尾结束。'],
      lefts: [40, 64, 40],
      widths: [300, 276, 130],
    );
    final first = _anchor(
      indented.layer,
      end: indented.layer.text.indexOf(
        '\n',
        indented.layer.text.indexOf('\n') + 1,
      ),
    );
    expect(_format(indented, [first]), first.context);
    final blank = _page(
      ['上一段的长行到达了正文栏右边界。', '', '下一段的长行也到达了正文栏右边界。', '短段尾结束。'],
      widths: [300, 0, 300, 130],
    );
    expect(_format(blank), contains('。\n\n下一段'));
  });

  test('真实段落：常规行距之外的段间距保留', () {
    final page = _page(
      [
        '第一段中的长行到达了正文栏右边界。',
        '第一段中的最后一行也恰好排满。',
        '第二段从明显更大的段间距后开始。',
        '第二段继续在正常行距中排列。',
        '短段尾结束。',
      ],
      tops: [60, 80, 130, 150, 170],
      widths: [300, 300, 300, 300, 130],
    );
    final start = page.layer.text.indexOf('第一段中的最后');
    final end = page.layer.text.indexOf('\n', page.layer.text.indexOf('第二段从'));
    final anchor = _anchor(page.layer, start: start, end: end);
    expect(_format(page, [anchor]), anchor.context);
  });

  test('列表、表格和诗行：保留结构换行', () {
    for (final prefix in ['1. ', '（一）', '二、', '• ', '- ']) {
      final page = _page([
        '$prefix第一条文字恰好排满一整行。',
        '$prefix第二条文字也恰好排满一整行。',
        '列表说明结束。',
      ]);
      expect(_format(page), page.layer.text);
    }
    for (final separator in ['\t', '|']) {
      final page = _page([
        '第一列$separator第二列，表格一行。',
        '下一行$separator第二列，表格二行。',
        '表格结束。',
      ]);
      expect(_format(page), page.layer.text);
    }
    for (final width in [100.0, 300.0]) {
      final poem = _page(
        ['第一诗行。', '第二诗行。', '第三诗行。'],
        widths: [width, width, width],
      );
      expect(_format(poem), poem.layer.text, reason: '短诗行或齐整诗行都缺乏连续正文的证据');
    }
  });

  test('双栏：各栏内可以整理，跨栏边界不合并', () {
    final page = _page(
      [
        '左栏第一行中的文字到达栏右边界。',
        '左栏第二行中的文字继续正常排列。',
        '左栏结束。',
        '右栏第一行中的文字到达栏右边界。',
        '右栏第二行中的文字继续正常排列。',
        '右栏结束。',
      ],
      widths: [220, 220, 110, 220, 220, 110],
      lefts: [40, 40, 40, 340, 340, 340],
      tops: [60, 80, 100, 60, 80, 100],
    );
    expect(
      _format(page),
      '${page.layer.text.split('\n').take(3).join()}'
      '\n${page.layer.text.split('\n').skip(3).join()}',
    );
  });

  test('缺少几何、文字层不匹配或字符框不完整：返回原始选区', () {
    final page = _page(['第一行长正文。', '第二行长正文。', '段落结束。']);
    final anchor = _anchor(page.layer);
    expect(
      formatPdfExcerptText(
        anchors: [anchor],
        layerForPage: (_) => page.layer,
        geometryForPage: (_) => null,
      ),
      anchor.context,
    );
    expect(
      formatPdfExcerptText(
        anchors: [anchor],
        layerForPage: (_) => null,
        geometryForPage: (_) => page.geometry,
      ),
      anchor.context,
    );
    final incomplete = PdfSelectableText(
      'layer',
      page.layer.text,
      page.layer.fragments.skip(1).toList(),
    );
    expect(
      _format(
        (layer: incomplete, geometry: page.geometry),
        [
          _anchor(
            page.layer,
            end: page.layer.text.indexOf(
              '\n',
              page.layer.text.indexOf('\n') + 1,
            ),
          ),
        ],
      ),
      page.layer.text.split('\n').take(2).join('\n'),
    );
    final other = PdfSelectableText(
      'other',
      page.layer.text,
      page.layer.fragments,
    );
    expect(
      _format((layer: other, geometry: page.geometry), [anchor]),
      anchor.context,
    );
    final stale = AnchorDraft(
      revisionId: 'fixture',
      pageIndex: 0,
      textLayerId: 'layer',
      textStart: 0,
      textEnd: page.layer.text.length,
      context: '旧选区\n保留',
    );
    expect(_format(page, [stale]), stale.context);
  });

  test('旋转页：四种旋转、非零裁剪框和 UserUnit 使用显示方向判断', () {
    for (final rotation in [0, 90, 180, 270]) {
      final page = _page([
        '第一行完整正文。',
        '第二行完整正文。',
        '短段尾结束。',
      ], rotation: rotation);
      expect(
        _format(page),
        page.layer.text.replaceAll('\n', ''),
        reason: 'rotation=$rotation',
      );
    }
  });

  test('明确竖排和未知书写方向：保留原始换行', () {
    for (final direction in ['verticalRtl', 'horizontalRtl', 'unknown']) {
      final page = _page([
        '第一行完整正文。',
        '第二行完整正文。',
        '短段尾结束。',
      ], direction: direction);
      expect(_format(page), page.layer.text);
    }
  });

  test('换行编码：CR、LF 和 CRLF 均可识别，真实空行原样保留', () {
    for (final newline in ['\r', '\n', '\r\n']) {
      final page = _page(['第一行完整正文。', '第二行完整正文。', '短段尾结束。'], newline: newline);
      expect(_format(page), page.layer.text.replaceAll(newline, ''));
      final blank = _page(['第一行完整正文。', '', '第二行完整正文。'], newline: newline);
      expect(_format(blank), blank.layer.text);
    }
  });

  test('跨页正反向选区：逐页整理，页间分隔和来源范围保留', () {
    final first = _page(['第一页完整正文。', '第一页第二长行。', '第一页段尾。']);
    final second = _page(['第二页完整正文。', '第二页第二长行。', '第二页段尾。']);
    PdfSelectableText? layerForPage(int i) => [first.layer, second.layer][i];
    for (final reverse in [false, true]) {
      final a = const PdfSelectionPoint(0, 0, 1);
      final b = PdfSelectionPoint(
        1,
        second.layer.text.length - 1,
        second.layer.text.length,
      );
      final anchors = selectTextAcrossPages(
        revisionId: 'fixture',
        a: reverse ? b : a,
        b: reverse ? a : b,
        layerForPage: layerForPage,
      );
      expect(
        formatPdfExcerptText(
          anchors: anchors,
          layerForPage: layerForPage,
          geometryForPage: (_) => first.geometry,
        ),
        '${first.layer.text.replaceAll('\n', '')}\n'
        '${second.layer.text.replaceAll('\n', '')}',
      );
      expect(anchors.map((a) => a.pageIndex), [0, 1]);
      expect(anchors.first.context, first.layer.text);
      expect(anchors.last.context, second.layer.text);
    }
  });
}

typedef _Page = ({PdfSelectableText layer, PdfPageGeometry geometry});

_Page _page(
  List<String> lines, {
  GeometryPrecision precision = GeometryPrecision.character,
  List<double>? widths,
  List<double>? lefts,
  List<double>? tops,
  int rotation = 0,
  String? direction,
  String newline = '\n',
}) {
  final geometry = PdfPageGeometry(
    pageIndex: 0,
    cropBox: PdfQuad.rect(40, 60, 640, 860),
    mediaBox: PdfQuad.rect(-30, -50, 650, 900),
    rotation: rotation,
    userUnit: 1.5,
  );
  final fragments = <TextFragment>[];
  var start = 0;
  for (var i = 0; i < lines.length; i++) {
    final text = lines[i];
    final left = lefts?[i] ?? 40.0, top = tops?[i] ?? 60.0 + i * 20;
    final width = widths?[i] ?? (i + 1 == lines.length ? 130.0 : 300.0);
    final tokens = precision == GeometryPrecision.line
        ? [text]
        : text.runes.map(String.fromCharCode).toList();
    // 行框描述可见正文；边界排版空白不伪造段首缩进或缩短右边界。
    final leading = precision == GeometryPrecision.line
        ? 0
        : text.runes.length - text.trimLeft().runes.length;
    final visible = precision == GeometryPrecision.line
        ? 1
        : text.trim().runes.length;
    final cells = visible > 0 ? visible : 1;
    var offset = start;
    for (var j = 0; j < tokens.length; j++) {
      final token = tokens[j];
      if (token.isEmpty) continue;
      final rect = Rect.fromLTWH(
        left + width * (j - leading) / cells,
        top,
        width / cells,
        12,
      );
      fragments.add(
        TextFragment(
          start: offset,
          length: token.length,
          quad: _sourceQuad(rect, geometry),
          order: fragments.length,
          precision: precision,
        ),
      );
      offset += token.length;
    }
    start += text.length + newline.length;
  }
  final draft = TextLayerDraft(
    revisionId: 'fixture',
    pageIndex: 0,
    source: precision == GeometryPrecision.character
        ? TextLayerSource.nativePdf
        : TextLayerSource.ocr,
    text: lines.join(newline),
    fragments: fragments,
    engineVersion: 'fixture',
    parameters: {'writingDirection': ?direction},
  );
  // 走实际工厂，确保 OCR 书写方向没有在选区适配时丢失。
  final layer = PdfSelectableText.fromPersisted(
    PageTextLayer(
      id: 'layer',
      revisionId: draft.revisionId,
      pageIndex: 0,
      source: draft.source,
      text: draft.text,
      fragments: fragments,
      engineVersion: 'fixture',
      createdAt: DateTime.utc(2026),
      parameters: draft.parameters,
    ),
  );
  expect(PdfSelectableText.fromDraft(draft).parameters, layer.parameters);
  return (layer: layer, geometry: geometry);
}

PdfQuad _sourceQuad(Rect rect, PdfPageGeometry geometry) => PdfQuad(
  [rect.topLeft, rect.topRight, rect.bottomRight, rect.bottomLeft].map((p) {
    final (x, y) = switch (geometry.rotation) {
      90 => (p.dy, 800 - p.dx),
      180 => (600 - p.dx, 800 - p.dy),
      270 => (600 - p.dy, p.dx),
      _ => (p.dx, p.dy),
    };
    return PdfPoint(40 + x, 860 - y);
  }).toList(),
);

AnchorDraft _anchor(PdfSelectableText layer, {int start = 0, int? end}) {
  end ??= layer.text.length;
  return AnchorDraft(
    revisionId: 'fixture',
    pageIndex: 0,
    quads: layer.fragments
        .where((f) => f.start < end! && f.start + f.length > start)
        .map((f) => f.quad)
        .toList(),
    textLayerId: layer.id,
    textStart: start,
    textEnd: end,
    context: layer.text.substring(start, end),
  );
}

String _format(_Page page, [List<AnchorDraft>? anchors]) =>
    formatPdfExcerptText(
      anchors: anchors ?? [_anchor(page.layer)],
      layerForPage: (_) => page.layer,
      geometryForPage: (_) => page.geometry,
    );
