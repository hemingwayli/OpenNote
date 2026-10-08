import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../domain/models.dart';
import '../../domain/boundary_geometry.dart';

class BoundaryVisual {
  const BoundaryVisual(this.boundary, this.rect);
  final MapBoundary boundary;
  final Rect rect;
  Offset get label => Offset(rect.left + 22, rect.top - 12);
  Path path(Rect box) => switch (boundary.style.shape) {
    BoundaryShape.ellipse => Path()..addOval(box),
    BoundaryShape.rectangle => Path()..addRect(box),
    BoundaryShape.rounded =>
      Path()..addRRect(RRect.fromRectAndRadius(box, const Radius.circular(14))),
  };
  bool hit(Offset point, double tolerance) =>
      path(rect.inflate(tolerance)).contains(point) &&
      !path(rect.deflate(tolerance)).contains(point);
}

BoundaryVisual? boundaryVisual(
  MapBoundary boundary,
  Iterable<MapNode> nodes,
  Set<String> shown,
  Offset Function(MapNode) position, {
  Set<String> auxiliaryRoots = const {},
}) {
  final members = boundaryMembers(
    boundary,
    nodes,
    shown,
    auxiliaryRoots: auxiliaryRoots,
  );
  Rect? bounds;
  for (final node in nodes) {
    if (!members.contains(node.id)) continue;
    final rect = position(node) & Size(node.width, node.height);
    bounds = bounds?.expandToInclude(rect) ?? rect;
  }
  if (bounds == null) return null;
  var rect = bounds.inflate(22);
  if (boundary.style.shape == BoundaryShape.ellipse) {
    rect = Rect.fromCenter(
      center: rect.center,
      width: rect.width * math.sqrt2,
      height: rect.height * math.sqrt2,
    );
  }
  return BoundaryVisual(boundary, rect);
}

class BoundaryCanvasPainter extends CustomPainter {
  const BoundaryCanvasPainter(
    this.visuals,
    this.origin,
    this.selected,
    this.visible,
  );
  final List<BoundaryVisual> visuals;
  final Offset origin;
  final String? selected;
  final Rect visible;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(origin.dx, origin.dy);
    for (final visual in visuals) {
      if (!visual.rect.overlaps(visible)) continue;
      final style = visual.boundary.style;
      final path = visual.path(visual.rect);
      Color color(String hex) =>
          Color(int.parse(hex.substring(1), radix: 16) | 0xFF000000);
      canvas.drawPath(
        path,
        Paint()..color = color(style.fill).withValues(alpha: style.fillOpacity),
      );
      final line = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = style.width
        ..color = selected == visual.boundary.id
            ? const Color(0xFF3574CB)
            : color(style.color);
      if (style.dashed) {
        for (final metric in path.computeMetrics()) {
          for (var d = 0.0; d < metric.length; d += 10) {
            canvas.drawPath(
              metric.extractPath(d, math.min(d + 5, metric.length)),
              line,
            );
          }
        }
      } else {
        canvas.drawPath(path, line);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant BoundaryCanvasPainter old) => true;
}
