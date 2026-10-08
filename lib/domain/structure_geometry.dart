import 'dart:math' as math;

import 'models.dart';

/// 主轴和大括号与主题卡片分开绘制，不修改节点尺寸或知识关系。
class StructureSpineGeometry {
  const StructureSpineGeometry(
    this.points, {
    this.braceTop,
    this.braceBottom,
    this.reverse = false,
  });
  final List<PdfPoint> points;
  final PdfPoint? braceTop, braceBottom;
  final bool reverse;
}

List<PdfPoint>? structureLinkGeometry(
  MapNode parent,
  MapNode node,
  MapLayoutKind kind,
  PdfPoint parentPosition,
  PdfPoint position, {
  StructureSpineGeometry? spine,
}) {
  final px = parentPosition.x, py = parentPosition.y;
  final x = position.x, y = position.y;
  if (kind.tree) {
    final reverse = kind == MapLayoutKind.treeLeft;
    final trunk = px + (reverse ? parent.width - 24 : 24);
    return [
      PdfPoint(trunk, py + parent.height),
      PdfPoint(trunk, y + node.height / 2),
      PdfPoint(x + (reverse ? node.width : 0), y + node.height / 2),
    ];
  }
  if (kind.brace) {
    final reverse = kind == MapLayoutKind.braceLeft;
    final joint = spine == null
        ? px + (reverse ? -46 : parent.width + 46)
        : braceAttachmentX(spine, y + node.height / 2);
    return [
      PdfPoint(joint, y + node.height / 2),
      PdfPoint(x + (reverse ? node.width : 0), y + node.height / 2),
    ];
  }
  if (kind == MapLayoutKind.timeline) {
    return [
      PdfPoint(x + node.width / 2, py + parent.height / 2),
      PdfPoint(x + node.width / 2, y < py ? y + node.height : y),
    ];
  }
  if (kind == MapLayoutKind.timelineVertical) {
    return [
      PdfPoint(px + parent.width / 2, y + node.height / 2),
      PdfPoint(x < px ? x + node.width : x, y + node.height / 2),
    ];
  }
  if (kind.fishbone) {
    final reverse = kind == MapLayoutKind.fishboneRight;
    final end = PdfPoint(x + (reverse ? node.width : 0), y + node.height / 2);
    final middle = py + parent.height / 2;
    final diagonal = (end.y - middle).abs();
    return [PdfPoint(end.x + (reverse ? diagonal : -diagonal), middle), end];
  }
  return null;
}

/// 大括号的横向轮廓与绘制贝塞尔一致，包含中间子主题的连接点。
double braceAttachmentX(StructureSpineGeometry spine, double y) {
  final top = spine.braceTop!, bottom = spine.braceBottom!;
  final middle = (top.y + bottom.y) / 2;
  final half = math.max(12.0, (bottom.y - top.y) / 2);
  final radius = math.min(12.0, half / 2);
  final first = middle - half, last = middle + half;
  final side = spine.reverse ? -1.0 : 1.0;
  double cube(double value) => value * value * value;
  if (y <= first + radius) {
    return top.x +
        side * 10 * cube(((first + radius - y) / radius).clamp(0.0, 1.0));
  }
  if (y >= last - radius) {
    return top.x +
        side * 10 * cube(((y - last + radius) / radius).clamp(0.0, 1.0));
  }
  if (y >= middle - radius && y <= middle + radius) {
    return top.x - side * 10 * cube(1 - (y - middle).abs() / radius);
  }
  return top.x;
}

StructureSpineGeometry? structureSpineGeometry(
  MapNode parent,
  Iterable<(MapNode, PdfPoint)> children,
  MapLayoutKind kind,
  PdfPoint position,
) {
  final entries = children.toList();
  if (entries.isEmpty || !kind.spine && !kind.brace) return null;
  final px = position.x, py = position.y;
  if (kind.brace) {
    final reverse = kind == MapLayoutKind.braceLeft;
    final x = px + (reverse ? -36 : parent.width + 36);
    final centers = entries.map((e) => e.$2.y + e.$1.height / 2).toList();
    final top = centers.reduce(math.min), bottom = centers.reduce(math.max);
    final middle = (top + bottom) / 2;
    return StructureSpineGeometry(
      [
        PdfPoint(px + (reverse ? 0 : parent.width), py + parent.height / 2),
        PdfPoint(
          px + (reverse ? -18 : parent.width + 18),
          py + parent.height / 2,
        ),
        PdfPoint(px + (reverse ? -18 : parent.width + 18), middle),
        PdfPoint(x + (reverse ? 10 : -10), middle),
      ],
      braceTop: PdfPoint(x, top),
      braceBottom: PdfPoint(x, bottom),
      reverse: reverse,
    );
  }
  final vertical = kind == MapLayoutKind.timelineVertical;
  final reverse = kind == MapLayoutKind.fishboneRight;
  final start = vertical
      ? PdfPoint(px + parent.width / 2, py + parent.height)
      : PdfPoint(px + (reverse ? 0 : parent.width), py + parent.height / 2);
  final attachments = [
    for (final (node, point) in entries)
      structureLinkGeometry(parent, node, kind, position, point)!.first,
  ];
  final end = vertical
      ? PdfPoint(start.x, attachments.map((p) => p.y).reduce(math.max) + 36)
      : PdfPoint(
          attachments.map((p) => p.x).reduce(reverse ? math.min : math.max) +
              (reverse ? -36 : 36),
          start.y,
        );
  return StructureSpineGeometry([start, end]);
}
