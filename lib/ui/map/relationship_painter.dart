import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../domain/models.dart';
import '../../domain/relationship_geometry.dart';
import '../theme/open_note_theme.dart';

Color relationshipColor(String hex) =>
    Color(int.parse('ff${hex.substring(1)}', radix: 16));
Offset relationOffset(PdfPoint point) => Offset(point.x, point.y);

Path relationshipPath(RelationshipGeometry geometry, Offset origin) {
  final start = relationOffset(geometry.start) + origin;
  final end = relationOffset(geometry.end) + origin;
  final path = Path()..moveTo(start.dx, start.dy);
  if (geometry.shape == RelationshipShape.curve) {
    final a = relationOffset(geometry.controlFrom) + origin,
        b = relationOffset(geometry.controlTo) + origin;
    path.cubicTo(a.dx, a.dy, b.dx, b.dy, end.dx, end.dy);
  } else {
    for (final point in geometry.corners) {
      path.lineTo(point.x + origin.dx, point.y + origin.dy);
    }
    path.lineTo(end.dx, end.dy);
  }
  return path;
}

void paintRelationship(
  Canvas canvas,
  RelationshipGeometry geometry,
  RelationshipStyle style, {
  Offset origin = Offset.zero,
  bool selected = false,
  Rect? clip,
}) {
  final path = relationshipPath(geometry, origin);
  if (clip != null && !path.getBounds().inflate(16).overlaps(clip)) return;
  final paint = Paint()
    ..style = PaintingStyle.stroke
    ..color = selected ? OpenNoteTokens.accent : relationshipColor(style.color)
    ..strokeWidth = selected ? math.max(2.2, style.width) : style.width
    ..strokeCap = StrokeCap.round;
  if (style.dashed) {
    final dashed = Path();
    for (final metric in path.computeMetrics()) {
      for (var distance = 0.0; distance < metric.length; distance += 14) {
        final segment = metric.extractPath(
          distance,
          math.min(distance + 8, metric.length),
        );
        if (clip == null ||
            segment.getBounds().inflate(style.width).overlaps(clip)) {
          dashed.addPath(segment, Offset.zero);
        }
      }
    }
    canvas.drawPath(dashed, paint);
  } else {
    canvas.drawPath(path, paint);
  }
  final samples = geometry.samples;
  void arrow(RelationshipArrow kind, bool start) {
    if (kind == RelationshipArrow.none) return;
    final tip = relationOffset(start ? geometry.start : geometry.end) + origin;
    final neighbor =
        relationOffset(start ? samples[1] : samples[samples.length - 2]) +
        origin;
    final delta = tip - neighbor;
    if (delta.distance < .001) return;
    final unit = delta / delta.distance, normal = Offset(-unit.dy, unit.dx);
    final length = 9 + style.width;
    final base = tip - unit * length;
    final shape = Path()..moveTo(tip.dx, tip.dy);
    switch (kind) {
      case RelationshipArrow.triangle:
      case RelationshipArrow.open:
        shape
          ..lineTo((base + normal * 4).dx, (base + normal * 4).dy)
          ..moveTo(tip.dx, tip.dy)
          ..lineTo((base - normal * 4).dx, (base - normal * 4).dy);
        if (kind == RelationshipArrow.triangle) {
          shape
            ..lineTo((base + normal * 4).dx, (base + normal * 4).dy)
            ..close();
        }
      case RelationshipArrow.diamond:
        final middle = tip - unit * length / 2, back = tip - unit * length;
        shape
          ..lineTo((middle + normal * 4).dx, (middle + normal * 4).dy)
          ..lineTo(back.dx, back.dy)
          ..lineTo((middle - normal * 4).dx, (middle - normal * 4).dy)
          ..close();
      case RelationshipArrow.circle:
        shape.addOval(Rect.fromCircle(center: tip - unit * 4, radius: 4));
      case RelationshipArrow.none:
        return;
    }
    canvas.drawPath(
      shape,
      Paint()
        ..color = paint.color
        ..style = (kind == RelationshipArrow.open
            ? PaintingStyle.stroke
            : PaintingStyle.fill)
        ..strokeWidth = paint.strokeWidth,
    );
  }

  arrow(style.startArrow, true);
  arrow(style.endArrow, false);
}

TextStyle relationshipLabelStyle(RelationshipStyle style) => TextStyle(
  fontFamily: style.labelFont,
  fontSize: style.labelSize,
  color: relationshipColor(style.labelColor),
  fontWeight: style.labelBold ? FontWeight.w600 : FontWeight.w400,
  fontStyle: style.labelItalic ? FontStyle.italic : FontStyle.normal,
  height: 1.4,
);

class RelationshipGuidePainter extends CustomPainter {
  const RelationshipGuidePainter(this.lines);
  final List<(Offset, Offset)> lines;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = OpenNoteTokens.accent.withValues(alpha: .35)
      ..strokeWidth = 1;
    for (final line in lines) {
      canvas.drawLine(line.$1, line.$2, paint);
    }
  }

  @override
  bool shouldRepaint(RelationshipGuidePainter old) => old.lines != lines;
}
