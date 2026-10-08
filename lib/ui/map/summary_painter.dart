import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../domain/models.dart';
import '../../domain/summary_geometry.dart';

class SummaryVisual {
  const SummaryVisual(
    this.summary,
    this.path,
    this.start,
    this.end,
    this.bounds,
  );
  final MapSummary summary;
  final Path path;
  final Offset start, end;
  final Rect bounds;
  bool hit(Offset point, double tolerance) {
    if (!bounds.inflate(tolerance).contains(point)) return false;
    for (final metric in path.computeMetrics()) {
      for (var d = 0.0; d <= metric.length; d += math.max(2, tolerance / 2)) {
        final tangent = metric.getTangentForOffset(d);
        if (tangent != null &&
            (point - tangent.position).distance <= tolerance) {
          return true;
        }
      }
    }
    return false;
  }
}

SummaryVisual? summaryVisual(
  MapSummary summary,
  List<MapNode> nodes,
  List<MapSummary> summaries,
  Set<String> shown,
  Offset Function(MapNode) position,
  MapLayoutKind kind, {
  Map<String, MapLayoutKind>? branchLayouts,
}) {
  final topic = nodes.where((n) => n.id == summary.summaryNodeId).firstOrNull;
  if (topic == null || !shown.contains(topic.id)) return null;
  final members = summaryMembers(summary, nodes, summaries, shown);
  if (members.isEmpty) return null;
  Rect? scope;
  for (final n in nodes.where((n) => members.contains(n.id))) {
    final r = position(n) & Size(n.width, n.height);
    scope = scope == null ? r : scope.expandToInclude(r);
  }
  final direction = summaryDirection(
    summary,
    nodes,
    kind,
    summaries: summaries,
    layouts: branchLayouts,
  );
  final vertical = direction.vertical;
  final reverse =
      direction == MapLayoutKind.left || direction == MapLayoutKind.up;
  final rect = scope!;
  final first = vertical ? rect.left : rect.top;
  final last = vertical ? rect.right : rect.bottom;
  final axis = vertical
      ? (reverse ? rect.top - 24 : rect.bottom + 24)
      : (reverse ? rect.left - 24 : rect.right + 24);
  final sign = reverse ? -1.0 : 1.0;
  Offset world(double primary, double cross) =>
      vertical ? Offset(cross, primary) : Offset(primary, cross);
  final middle = (first + last) / 2;
  final local = Path();
  void move(double p, double c) {
    final a = world(p, c);
    local.moveTo(a.dx, a.dy);
  }

  void line(double p, double c) {
    final a = world(p, c);
    local.lineTo(a.dx, a.dy);
  }

  void cubic(double p1, double c1, double p2, double c2, double p, double c) {
    final a = world(p1, c1), b = world(p2, c2), e = world(p, c);
    local.cubicTo(a.dx, a.dy, b.dx, b.dy, e.dx, e.dy);
  }

  move(axis, first);
  switch (summary.style.bracket) {
    case SummaryBracket.square:
      line(axis + sign * 14, first);
      line(axis + sign * 14, last);
      line(axis, last);
    case SummaryBracket.curve:
      cubic(axis + sign * 28, first, axis + sign * 28, last, axis, last);
    case SummaryBracket.brace:
      cubic(
        axis + sign * 16,
        first,
        axis + sign * 8,
        middle - 12,
        axis + sign * 24,
        middle,
      );
      cubic(axis + sign * 8, middle + 12, axis + sign * 16, last, axis, last);
  }
  final p = position(topic);
  final port = vertical
      ? p + Offset(topic.width / 2, reverse ? topic.height : 0)
      : p + Offset(reverse ? topic.width : 0, topic.height / 2);
  move(
    axis + sign * (summary.style.bracket == SummaryBracket.square ? 14 : 24),
    middle,
  );
  local.lineTo(port.dx, port.dy);
  return SummaryVisual(
    summary,
    local,
    world(axis, first),
    world(axis, last),
    local.getBounds(),
  );
}

void paintSummary(
  Canvas canvas,
  SummaryVisual visual,
  Offset origin,
  bool selected,
) {
  paintSummaryPath(canvas, visual.path, visual.summary.style, origin, selected);
}

void paintSummaryPath(
  Canvas canvas,
  Path source,
  SummaryStyle style,
  Offset origin,
  bool selected,
) {
  final paint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = selected ? math.max(2, style.width) : style.width
    ..color = selected
        ? const Color(0xFF3574CB)
        : Color(int.parse(style.color.substring(1), radix: 16) | 0xFF000000);
  final path = source.shift(origin);
  if (!style.dashed) {
    canvas.drawPath(path, paint);
    return;
  }
  for (final metric in path.computeMetrics()) {
    for (var d = 0.0; d < metric.length; d += 10) {
      canvas.drawPath(
        metric.extractPath(d, math.min(d + 6, metric.length)),
        paint,
      );
    }
  }
}
