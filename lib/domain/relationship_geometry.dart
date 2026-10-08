import 'dart:math' as math;

import 'models.dart';

/// 世界坐标几何同时供绘制、命中和控制柄使用，避免三套曲线算法漂移。
class RelationshipGeometry {
  RelationshipGeometry({
    required this.shape,
    required this.start,
    required this.end,
    required this.controlFrom,
    required this.controlTo,
    required this.corners,
    required this.labelOffset,
  });
  final RelationshipShape shape;
  final PdfPoint start, end, controlFrom, controlTo, labelOffset;
  final List<PdfPoint> corners;

  PdfPoint point(double t) {
    if (shape == RelationshipShape.curve) {
      final s = 1 - t;
      return PdfPoint(
        s * s * s * start.x +
            3 * s * s * t * controlFrom.x +
            3 * s * t * t * controlTo.x +
            t * t * t * end.x,
        s * s * s * start.y +
            3 * s * s * t * controlFrom.y +
            3 * s * t * t * controlTo.y +
            t * t * t * end.y,
      );
    }
    final points = [start, ...corners, end];
    final lengths = [
      for (var i = 1; i < points.length; i++)
        _distance(points[i - 1], points[i]),
    ];
    var remaining = lengths.fold(0.0, (a, b) => a + b) * t;
    for (var i = 0; i < lengths.length; i++) {
      if (remaining <= lengths[i] || i == lengths.length - 1) {
        final fraction = lengths[i] == 0 ? 0.0 : remaining / lengths[i];
        return _mix(points[i], points[i + 1], fraction);
      }
      remaining -= lengths[i];
    }
    return end;
  }

  PdfPoint get label => _plus(point(.5), labelOffset);
  List<PdfPoint> get samples => shape == RelationshipShape.curve
      ? [for (var i = 0; i <= 64; i++) point(i / 64)]
      : [start, ...corners, end];
  double distanceTo(PdfPoint location) {
    final points = samples;
    var result = double.infinity;
    for (var i = 1; i < points.length; i++) {
      final a = points[i - 1], b = points[i];
      final dx = b.x - a.x, dy = b.y - a.y, length2 = dx * dx + dy * dy;
      final t = length2 == 0
          ? 0.0
          : (((location.x - a.x) * dx + (location.y - a.y) * dy) / length2)
                .clamp(0.0, 1.0);
      result = math.min(
        result,
        _distance(location, PdfPoint(a.x + t * dx, a.y + t * dy)),
      );
    }
    return result;
  }
}

RelationshipGeometry relationshipGeometry(
  MapNode from,
  MapNode to,
  RelationshipStyle style,
) {
  final a = PdfPoint(from.x + from.width / 2, from.y + from.height / 2);
  final b = PdfPoint(to.x + to.width / 2, to.y + to.height / 2);
  final dx = b.x - a.x, dy = b.y - a.y;
  final length = math.sqrt(dx * dx + dy * dy);
  final normal = length == 0
      ? const PdfPoint(0, 80)
      : PdfPoint(
          -dy / length * 80 * style.curveBias,
          dx / length * 80 * style.curveBias,
        );
  final c1 = _plus(
    a,
    style.controlFrom ?? _plus(PdfPoint(dx / 3, dy / 3), normal),
  );
  final c2 = _plus(
    b,
    style.controlTo ?? _plus(PdfPoint(-dx / 3, -dy / 3), normal),
  );
  final start = _port(
    from,
    style.anchorFrom,
    style.shape == RelationshipShape.curve ? c1 : b,
  );
  final end = _port(
    to,
    style.anchorTo,
    style.shape == RelationshipShape.curve ? c2 : a,
  );
  final corners = style.shape != RelationshipShape.elbow
      ? <PdfPoint>[]
      : dx.abs() >= dy.abs()
      ? [
          PdfPoint((start.x + end.x) / 2, start.y),
          PdfPoint((start.x + end.x) / 2, end.y),
        ]
      : [
          PdfPoint(start.x, (start.y + end.y) / 2),
          PdfPoint(end.x, (start.y + end.y) / 2),
        ];
  return RelationshipGeometry(
    shape: style.shape,
    start: start,
    end: end,
    controlFrom: c1,
    controlTo: c2,
    corners: corners,
    labelOffset: style.labelOffset ?? const PdfPoint(0, -12),
  );
}

PdfPoint _port(MapNode node, PdfPoint? anchor, PdfPoint toward) {
  if (anchor != null) {
    return PdfPoint(
      node.x + node.width * anchor.x,
      node.y + node.height * anchor.y,
    );
  }
  final center = PdfPoint(node.x + node.width / 2, node.y + node.height / 2);
  final dx = toward.x - center.x, dy = toward.y - center.y;
  if (dx == 0 && dy == 0) return PdfPoint(node.x + node.width, center.y);
  final scale = math.min(
    dx == 0 ? double.infinity : node.width / 2 / dx.abs(),
    dy == 0 ? double.infinity : node.height / 2 / dy.abs(),
  );
  return PdfPoint(center.x + dx * scale, center.y + dy * scale);
}

/// 手动端点投影到距离最近的矩形边，存为归一化坐标，主题缩放后仍在边界。
PdfPoint relationshipAnchorAt(MapNode node, PdfPoint location) {
  final x = (location.x - node.x).clamp(0.0, node.width);
  final y = (location.y - node.y).clamp(0.0, node.height);
  final distances = [x, node.width - x, y, node.height - y];
  final minimum = distances.reduce(math.min);
  return switch (distances.indexOf(minimum)) {
    0 => PdfPoint(0, y / node.height),
    1 => PdfPoint(1, y / node.height),
    2 => PdfPoint(x / node.width, 0),
    _ => PdfPoint(x / node.width, 1),
  };
}

PdfPoint _plus(PdfPoint a, PdfPoint b) => PdfPoint(a.x + b.x, a.y + b.y);
PdfPoint _mix(PdfPoint a, PdfPoint b, double t) =>
    PdfPoint(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t);
double _distance(PdfPoint a, PdfPoint b) =>
    math.sqrt(math.pow(a.x - b.x, 2) + math.pow(a.y - b.y, 2));
