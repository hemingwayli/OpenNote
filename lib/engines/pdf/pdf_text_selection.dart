import '../../domain/models.dart';

class PdfSelectionPoint {
  const PdfSelectionPoint(this.pageIndex, this.start, this.end);
  final int pageIndex;
  final int start;
  final int end;
}

class PdfSelectableText {
  const PdfSelectableText(
    this.id,
    this.text,
    this.fragments, {
    this.parameters = const {},
  });
  factory PdfSelectableText.fromPersisted(PageTextLayer layer) =>
      PdfSelectableText(
        layer.id,
        layer.text,
        layer.fragments,
        parameters: layer.parameters,
      );
  factory PdfSelectableText.fromDraft(TextLayerDraft layer) =>
      PdfSelectableText(
        null,
        layer.text,
        layer.fragments,
        parameters: layer.parameters,
      );
  final String? id;
  final String text;
  final List<TextFragment> fragments;
  final Map<String, Object?> parameters;
}

/// 原生/OCR 都走同一选区路径；每页分别绑定文本层版本与 UTF-16 范围。
List<AnchorDraft> selectTextAcrossPages({
  required String revisionId,
  required PdfSelectionPoint a,
  required PdfSelectionPoint b,
  required PdfSelectableText? Function(int pageIndex) layerForPage,
}) {
  final forward =
      a.pageIndex < b.pageIndex ||
      (a.pageIndex == b.pageIndex && a.start <= b.start);
  final first = forward ? a : b;
  final last = forward ? b : a;
  final anchors = <AnchorDraft>[];
  for (var index = first.pageIndex; index <= last.pageIndex; index++) {
    final layer = layerForPage(index);
    if (layer == null) continue;
    final start = (index == first.pageIndex ? first.start : 0).clamp(
      0,
      layer.text.length,
    );
    final end = (index == last.pageIndex ? last.end : layer.text.length).clamp(
      start,
      layer.text.length,
    );
    final fragments = layer.fragments
        .where(
          (fragment) =>
              fragment.start < end && fragment.start + fragment.length > start,
        )
        .toList();
    if (fragments.isEmpty) continue;
    anchors.add(
      AnchorDraft(
        revisionId: revisionId,
        pageIndex: index,
        quads: fragments.map((fragment) => fragment.quad).toList(),
        textLayerId: layer.id,
        textStart: start,
        textEnd: end,
        context: layer.text.substring(start, end),
      ),
    );
  }
  return anchors;
}
