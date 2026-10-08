import 'dart:ui';

typedef HighlightTextRange = ({int start, int end});

/// 文字索引补齐同行空格；过大的空白按栏间分隔处理，缺少版本几何时保留邻接规则。
List<Rect> mergeTextHighlightRects(
  Iterable<Rect> rects, {
  bool vertical = false,
  String? text,
  Map<Rect, HighlightTextRange> textRanges = const {},
}) {
  Rect orient(Rect r) =>
      vertical ? Rect.fromLTRB(r.top, r.left, r.bottom, r.right) : r;
  final sorted =
      rects
          .where((r) => !r.isEmpty)
          .map((r) => (rect: orient(r), range: textRanges[r]))
          .toList()
        ..sort((a, b) {
          final line = a.rect.center.dy.compareTo(b.rect.center.dy);
          return line == 0 ? a.rect.left.compareTo(b.rect.left) : line;
        });
  final merged = <({Rect rect, HighlightTextRange? range})>[];
  for (var candidate in sorted) {
    for (var index = 0; index < merged.length;) {
      final line = merged[index];
      final height = line.rect.height < candidate.rect.height
          ? line.rect.height
          : candidate.rect.height;
      final gap = candidate.rect.left > line.rect.right
          ? candidate.rect.left - line.rect.right
          : line.rect.left > candidate.rect.right
          ? line.rect.left - candidate.rect.right
          : 0.0;
      final a = line.range, b = candidate.range;
      var continuous = gap <= height * .65;
      if (text != null && a != null && b != null) {
        final first = a.start <= b.start ? a : b;
        final last = a.start <= b.start ? b : a;
        final from = first.end.clamp(0, text.length);
        final to = last.start.clamp(from, text.length);
        final between = text.substring(from, to);
        continuous =
            gap <= height * 4 &&
            !between.contains('\n') &&
            !between.contains('\r') &&
            !between.contains('\t') &&
            between.trim().isEmpty;
      }
      if ((line.rect.center.dy - candidate.rect.center.dy).abs() <=
              height * .4 &&
          continuous) {
        candidate = (
          rect: candidate.rect.expandToInclude(merged.removeAt(index).rect),
          range: a != null && b != null
              ? (
                  start: a.start < b.start ? a.start : b.start,
                  end: a.end > b.end ? a.end : b.end,
                )
              : null,
        );
        index = 0;
      } else {
        index++;
      }
    }
    merged.add(candidate);
  }
  return merged.map((item) => orient(item.rect)).toList();
}

/// 合并同一书写行的邻接字符，保留跨行和栏间空白，避免逐字格子及重复着色。
List<Rect> mergeSourceHighlightRects(
  Iterable<Rect> rects, {
  bool vertical = false,
}) {
  Rect orient(Rect r) =>
      vertical ? Rect.fromLTRB(r.top, r.left, r.bottom, r.right) : r;
  final sorted = rects.where((r) => !r.isEmpty).map(orient).toList()
    ..sort((a, b) {
      final line = a.center.dy.compareTo(b.center.dy);
      return line == 0 ? a.left.compareTo(b.left) : line;
    });
  final merged = <Rect>[];
  for (final rect in sorted) {
    var candidate = rect;
    for (var index = 0; index < merged.length;) {
      final line = merged[index];
      final height = line.height < candidate.height
          ? line.height
          : candidate.height;
      final gap = candidate.left > line.right
          ? candidate.left - line.right
          : line.left > candidate.right
          ? line.left - candidate.right
          : 0.0;
      if ((line.center.dy - candidate.center.dy).abs() <= height * .4 &&
          gap <= height * .65) {
        candidate = candidate.expandToInclude(merged.removeAt(index));
        index = 0; // 中间字框可能桥接两段，合并后继续消除重复着色。
      } else {
        index++;
      }
    }
    merged.add(candidate);
  }
  return merged.map(orient).toList();
}
