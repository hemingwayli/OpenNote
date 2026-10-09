import 'dart:math' as math;
import 'dart:ui';

import '../../domain/models.dart';
import 'pdf_text_selection.dart';

/// 只整理新摘录的显示文字；原始文本、UTF-16 范围和回源坐标保持不变。
String formatPdfExcerptText({
  required List<AnchorDraft> anchors,
  required PdfSelectableText? Function(int pageIndex) layerForPage,
  required PdfPageGeometry? Function(int pageIndex) geometryForPage,
}) => anchors
    .map((anchor) {
      final layer = layerForPage(anchor.pageIndex);
      final geometry = geometryForPage(anchor.pageIndex);
      final start = anchor.textStart, end = anchor.textEnd;
      if (layer == null ||
          geometry == null ||
          start == null ||
          end == null ||
          start < 0 ||
          end > layer.text.length ||
          start >= end ||
          (anchor.textLayerId != null && anchor.textLayerId != layer.id) ||
          anchor.context != layer.text.substring(start, end) ||
          !const [0, 90, 180, 270].contains(geometry.rotation) ||
          (layer.parameters['writingDirection'] != null &&
              layer.parameters['writingDirection'] != 'horizontalLtr')) {
        return anchor.context;
      }
      final lines = _pageLines(layer, geometry);
      final output = StringBuffer();
      var cursor = start;
      for (var index = 0; index + 1 < lines.length; index++) {
        final line = lines[index];
        if (line.end < start ||
            line.separatorEnd > end ||
            !_canJoin(lines, index)) {
          continue;
        }
        var from = line.end, to = line.separatorEnd;
        while (from > cursor &&
            _horizontalSpace.hasMatch(layer.text[from - 1])) {
          from--;
        }
        while (to < end && _horizontalSpace.hasMatch(layer.text[to])) {
          to++;
        }
        // 只选到了换行或空白时，不能从选区外引入任何字符或连接空格。
        if (from <= cursor || to >= end) continue;
        output.write(layer.text.substring(cursor, from));
        output.write(
          _separator(
            layer.text.substring(cursor, from).runes.last,
            layer.text.substring(to, end).runes.first,
          ),
        );
        cursor = to;
      }
      output.write(layer.text.substring(cursor, end));
      return output.toString();
    })
    .join('\n');

final _newLine = RegExp(r'\r\n|\r|\n');
final _whiteSpace = RegExp(r'\s');
final _horizontalSpace = RegExp(r'[ \t\u00a0\u3000]');
final _listStart = RegExp(
  r'^\s*(?:[•●○▪◦‣]|[-–—]\s|\(?\d{1,3}[.)、．]|'
  r'[（(][0-9一二三四五六七八九十百]+[）)]|[一二三四五六七八九十百]+[、．])',
);
final _sentenceEnd = RegExp(r'[。！？.!?][”’"\x27）)\]]*$');

class _Line {
  _Line(this.start, this.end, this.separatorEnd, this.text);
  final int start;
  final int end;
  final int separatorEnd;
  final String text;
  Rect? bounds;
  double height = 0;
}

List<_Line> _pageLines(PdfSelectableText layer, PdfPageGeometry geometry) {
  final lines = <_Line>[];
  var start = 0;
  for (final match in _newLine.allMatches(layer.text)) {
    lines.add(
      _Line(
        start,
        match.start,
        match.end,
        layer.text.substring(start, match.start),
      ),
    );
    start = match.end;
  }
  lines.add(
    _Line(
      start,
      layer.text.length,
      layer.text.length,
      layer.text.substring(start),
    ),
  );
  final fragments = List<TextFragment>.of(layer.fragments)
    ..sort((a, b) => a.start.compareTo(b.start));
  var fragmentIndex = 0;
  for (final line in lines) {
    final rects = <Rect>[];
    var covered = 0, coveredEnd = line.start;
    while (fragmentIndex < fragments.length &&
        fragments[fragmentIndex].start + fragments[fragmentIndex].length <=
            line.start) {
      fragmentIndex++;
    }
    for (var index = fragmentIndex; index < fragments.length; index++) {
      final fragment = fragments[index];
      if (fragment.start >= line.end) break;
      final end = fragment.start + fragment.length;
      if (fragment.start < line.start ||
          end > line.end ||
          fragment.length <= 0) {
        continue;
      }
      final rect = _displayBounds(fragment.quad, geometry);
      if (rect == null || rect.isEmpty) continue;
      final text = layer.text.substring(fragment.start, end);
      if (text.trim().isEmpty) continue;
      rects.add(rect);
      final uncoveredStart = math.max(coveredEnd, fragment.start);
      if (end > uncoveredStart) {
        covered += layer.text
            .substring(uncoveredStart, end)
            .replaceAll(_whiteSpace, '')
            .length;
        coveredEnd = end;
      }
    }
    if (rects.isEmpty ||
        covered != line.text.replaceAll(_whiteSpace, '').length) {
      continue;
    }
    final height = _median(rects.map((r) => r.height));
    final center = _median(rects.map((r) => r.center.dy));
    // 竖排、同一文本行里混入其他行或表格分栏时，几何不能作为折行证据。
    if (height <= 0 ||
        rects.any((r) => (r.center.dy - center).abs() > height * .5)) {
      continue;
    }
    rects.sort((a, b) => a.left.compareTo(b.left));
    var bounds = rects.first;
    var continuous = true;
    for (final rect in rects.skip(1)) {
      if (rect.left - bounds.right > height * 4) continuous = false;
      bounds = bounds.expandToInclude(rect);
    }
    if (!continuous) continue;
    line.bounds = bounds;
    line.height = height;
  }
  return lines;
}

bool _canJoin(List<_Line> lines, int index) {
  final a = lines[index], b = lines[index + 1];
  final first = a.bounds, next = b.bounds;
  if (first == null ||
      next == null ||
      a.text.contains('\t') ||
      b.text.contains('\t') ||
      a.text.contains('|') ||
      b.text.contains('|') ||
      _listStart.hasMatch(a.text) ||
      _listStart.hasMatch(b.text)) {
    return false;
  }
  final height = math.min(a.height, b.height);
  if (math.max(a.height, b.height) > height * 1.3 ||
      first.width < height * 12 ||
      !_sameColumn(first, next, height)) {
    return false;
  }
  final peers = <_Line>[];
  for (
    var i = math.max(0, index - 8);
    i < math.min(lines.length, index + 10);
    i++
  ) {
    final line = lines[i], rect = line.bounds;
    if (rect != null &&
        rect.width >= height * 4 &&
        line.height >= height * .8 &&
        line.height <= height * 1.3 &&
        _sameColumn(first, rect, height)) {
      peers.add(line);
    }
  }
  if (peers.length < 3) return false;
  final left = peers.map((l) => l.bounds!.left).reduce(math.min);
  final right = peers.map((l) => l.bounds!.right).reduce(math.max);
  // 重复的右边界和段首缩进/短段尾共同确认正文栏，避免把齐整诗行当成正文。
  if (peers.where((l) => right - l.bounds!.right <= height * 1.1).length < 2 ||
      !peers.any(
        (l) =>
            l.bounds!.left - left >= height * 1.2 ||
            (right - l.bounds!.right >= height * 2 &&
                _sentenceEnd.hasMatch(l.text.trimRight())),
      )) {
    return false;
  }
  if (right - first.right > height * 1.1 || next.left - left > height * .75) {
    return false;
  }
  final gaps = <double>[];
  for (var i = 0; i + 1 < peers.length; i++) {
    final delta = peers[i + 1].bounds!.center.dy - peers[i].bounds!.center.dy;
    if (delta >= height * .9 && delta <= height * 2.7) gaps.add(delta);
  }
  if (gaps.length < 2) return false;
  final gap = next.center.dy - first.center.dy;
  // 取较低的中位数，避免把段间大间距抬高成常规行距。
  final regular = _median(gaps);
  return gap >= regular * .8 && gap <= regular * 1.3 && gap <= height * 2.7;
}

bool _sameColumn(Rect a, Rect b, double height) {
  final overlap = math.min(a.right, b.right) - math.max(a.left, b.left);
  return (a.left - b.left).abs() <= height * 2.5 &&
      overlap >= math.min(a.width, b.width) * .65;
}

double _median(Iterable<double> values) {
  final sorted = values.toList()..sort();
  return sorted[(sorted.length - 1) ~/ 2];
}

Rect? _displayBounds(PdfQuad quad, PdfPageGeometry geometry) {
  final boxPoints = [...geometry.cropBox.points, ...geometry.mediaBox.points];
  if ([
    ...boxPoints,
    ...quad.points,
  ].any((p) => !p.x.isFinite || !p.y.isFinite)) {
    return null;
  }
  Rect bounds(PdfQuad q) => Rect.fromLTRB(
    q.points.map((p) => p.x).reduce(math.min),
    q.points.map((p) => p.y).reduce(math.min),
    q.points.map((p) => p.x).reduce(math.max),
    q.points.map((p) => p.y).reduce(math.max),
  );
  final box = bounds(geometry.cropBox).intersect(bounds(geometry.mediaBox));
  if (box.isEmpty) return null;
  final points = quad.points.map((p) {
    final x = p.x - box.left, y = box.bottom - p.y;
    return switch (geometry.rotation) {
      90 => Offset(box.height - y, x),
      180 => Offset(box.width - x, box.height - y),
      270 => Offset(y, box.width - x),
      _ => Offset(x, y),
    };
  }).toList();
  return Rect.fromLTRB(
    points.map((p) => p.dx).reduce(math.min),
    points.map((p) => p.dy).reduce(math.min),
    points.map((p) => p.dx).reduce(math.max),
    points.map((p) => p.dy).reduce(math.max),
  );
}

String _separator(int previous, int next) {
  bool cjk(int c) =>
      (c >= 0x2e80 && c <= 0x9fff) ||
      (c >= 0xf900 && c <= 0xfaff) ||
      (c >= 0xff00 && c <= 0xffef) ||
      (c >= 0x20000 && c <= 0x323af);
  if (cjk(previous) ||
      cjk(next) ||
      const [0x2d, 0xad, 0x2010, 0x2011].contains(previous) ||
      '([{“‘'.runes.contains(previous) ||
      '.,;:!?)]}”’'.runes.contains(next)) {
    return '';
  }
  return ' ';
}
