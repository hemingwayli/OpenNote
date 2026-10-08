import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../domain/models.dart';
import '../../domain/structure_geometry.dart';

Path structureLinePath(List<PdfPoint> points) {
  final path = Path();
  if (points.isEmpty) return path;
  path.moveTo(points.first.x, points.first.y);
  for (final point in points.skip(1)) {
    path.lineTo(point.x, point.y);
  }
  return path;
}

Path structureSpinePath(StructureSpineGeometry geometry) {
  final path = structureLinePath(geometry.points);
  final top = geometry.braceTop, bottom = geometry.braceBottom;
  if (top == null || bottom == null) return path;
  final x = top.x, middle = (top.y + bottom.y) / 2;
  final half = math.max(12.0, (bottom.y - top.y) / 2);
  final side = geometry.reverse ? -1.0 : 1.0;
  final radius = math.min(12.0, half / 2);
  // 单个子主题仍保留可辨认的大括号，括号中腰朝向父主题。
  path.moveTo(x + side * 10, middle - half);
  path.cubicTo(
    x,
    middle - half + radius / 3,
    x,
    middle - half + radius * 2 / 3,
    x,
    middle - half + radius,
  );
  path.lineTo(x, middle - radius);
  path.cubicTo(
    x,
    middle - radius * 2 / 3,
    x,
    middle - radius / 3,
    x - side * 10,
    middle,
  );
  path.cubicTo(
    x,
    middle + radius / 3,
    x,
    middle + radius * 2 / 3,
    x,
    middle + radius,
  );
  path.lineTo(x, middle + half - radius);
  path.cubicTo(
    x,
    middle + half - radius * 2 / 3,
    x,
    middle + half - radius / 3,
    x + side * 10,
    middle + half,
  );
  return path;
}

Path branchPath(Offset start, Offset end, BranchPath kind, bool vertical) {
  final path = Path()..moveTo(start.dx, start.dy);
  if (kind == BranchPath.straight) return path..lineTo(end.dx, end.dy);
  if (vertical) {
    final middle = (start.dy + end.dy) / 2;
    if (kind == BranchPath.elbow) {
      return path
        ..lineTo(start.dx, middle)
        ..lineTo(end.dx, middle)
        ..lineTo(end.dx, end.dy);
    }
    return path..cubicTo(start.dx, middle, end.dx, middle, end.dx, end.dy);
  }
  final middle = (start.dx + end.dx) / 2;
  if (kind == BranchPath.elbow) {
    return path
      ..lineTo(middle, start.dy)
      ..lineTo(middle, end.dy)
      ..lineTo(end.dx, end.dy);
  }
  return path..cubicTo(middle, start.dy, middle, end.dy, end.dx, end.dy);
}

Path dashedPath(Path path) {
  final dashed = Path();
  for (final metric in path.computeMetrics()) {
    for (var distance = 0.0; distance < metric.length; distance += 12) {
      dashed.addPath(
        metric.extractPath(distance, math.min(distance + 7, metric.length)),
        Offset.zero,
      );
    }
  }
  return dashed;
}

void paintBranch(Canvas canvas, Path path, BranchStyle style) {
  final paint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = style.width
    ..color = Color(
      int.parse(style.color.substring(1), radix: 16) | 0xff000000,
    );
  canvas.drawPath(style.dashed ? dashedPath(path) : path, paint);
  if (style.start == BranchEnd.none && style.end == BranchEnd.none) return;
  for (final metric in path.computeMetrics()) {
    for (final start in [true, false]) {
      if ((start ? style.start : style.end) == BranchEnd.none) continue;
      final tangent = metric.getTangentForOffset(start ? 0 : metric.length);
      if (tangent == null) continue;
      final direction = tangent.vector * (start ? -1 : 1);
      final size = 6 + style.width;
      final back = tangent.position - direction * size;
      final normal = Offset(-direction.dy, direction.dx) * (size * .45);
      canvas.drawPath(
        Path()
          ..moveTo((back + normal).dx, (back + normal).dy)
          ..lineTo(tangent.position.dx, tangent.position.dy)
          ..lineTo((back - normal).dx, (back - normal).dy),
        paint,
      );
    }
  }
}

class TopicBorderPainter extends CustomPainter {
  const TopicBorderPainter(this.style);
  final BoundaryStyle style;
  @override
  void paint(Canvas canvas, Size size) {
    final radius = style.shape == BoundaryShape.rectangle
        ? 0.0
        : style.shape == BoundaryShape.ellipse
        ? size.height / 2
        : 8.0;
    final rect = (Offset.zero & size).deflate(style.width / 2);
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(radius)));
    canvas.drawPath(
      dashedPath(path),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = style.width
        ..color = Color(
          int.parse(style.color.substring(1), radix: 16) | 0xff000000,
        ),
    );
  }

  @override
  bool shouldRepaint(TopicBorderPainter old) => old.style != style;
}
