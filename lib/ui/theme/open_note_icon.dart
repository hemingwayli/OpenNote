import 'package:flutter/material.dart';

/// 应用工具图标使用同一套 24 单位轮廓与 1.7 单位圆头笔画。
/// 保留 Icon 的类型和语义，现有按钮、提示、禁用状态与查找器不变。
class OpenNoteIcon extends Icon {
  const OpenNoteIcon(
    super.icon, {
    super.key,
    super.size,
    super.color,
    super.semanticLabel,
  });

  @override
  Widget build(BuildContext context) {
    final paths = _paths(icon);
    if (paths == null) return super.build(context);
    final theme = IconTheme.of(context);
    final extent = size ?? theme.size ?? 20;
    final ink = (color ?? theme.color ?? Colors.black).withValues(
      alpha: (color ?? theme.color ?? Colors.black).a * (theme.opacity ?? 1),
    );
    return Semantics(
      label: semanticLabel,
      child: Center(
        widthFactor: 1,
        heightFactor: 1,
        child: SizedBox.square(
          dimension: extent,
          child: CustomPaint(painter: _LineIconPainter(paths, ink)),
        ),
      ),
    );
  }
}

class _LineIconPainter extends CustomPainter {
  const _LineIconPainter(this.paths, this.color);
  final List<Path> paths;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24, size.height / 24);
    final pen = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.7
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    for (final path in paths) {
      canvas.drawPath(path, pen);
    }
  }

  @override
  bool shouldRepaint(_LineIconPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.paths != paths;
}

Path _line(List<double> points) {
  final p = Path()..moveTo(points[0], points[1]);
  for (var i = 2; i < points.length; i += 2) {
    p.lineTo(points[i], points[i + 1]);
  }
  return p;
}

Path _box(double x, double y, double w, double h, [double radius = 2]) => Path()
  ..addRRect(
    RRect.fromRectAndRadius(Rect.fromLTWH(x, y, w, h), Radius.circular(radius)),
  );
Path _circle(double x, double y, double r) =>
    Path()..addOval(Rect.fromCircle(center: Offset(x, y), radius: r));

final _iconPaths = <IconData, List<Path>?>{};
List<Path>? _paths(IconData? icon) =>
    icon == null ? null : _iconPaths.putIfAbsent(icon, () => _makePaths(icon));

List<Path>? _makePaths(IconData icon) => switch (icon) {
  Icons.home_outlined => [
    _line([3, 11, 12, 3, 21, 11]),
    _line([5, 10, 5, 21, 10, 21, 10, 14, 14, 14, 14, 21, 19, 21, 19, 10]),
  ],
  Icons.menu => [
    _line([4, 6, 20, 6]),
    _line([4, 12, 20, 12]),
    _line([4, 18, 20, 18]),
  ],
  Icons.close => [
    _line([6, 6, 18, 18]),
    _line([18, 6, 6, 18]),
  ],
  Icons.add || Icons.add_rounded => [
    _line([5, 12, 19, 12]),
    _line([12, 5, 12, 19]),
  ],
  Icons.remove => [
    _line([5, 12, 19, 12]),
  ],
  Icons.search => [
    _circle(10.5, 10.5, 6.5),
    _line([15.5, 15.5, 21, 21]),
  ],
  Icons.undo => [
    _line([8, 4, 3, 9, 8, 14]),
    Path()
      ..moveTo(3, 9)
      ..lineTo(14, 9)
      ..cubicTo(22, 9, 22, 20, 14, 20),
  ],
  Icons.redo => [
    _line([16, 4, 21, 9, 16, 14]),
    Path()
      ..moveTo(21, 9)
      ..lineTo(10, 9)
      ..cubicTo(2, 9, 2, 20, 10, 20),
  ],
  Icons.menu_book_outlined || Icons.auto_stories_outlined => [
    Path()
      ..moveTo(12, 6)
      ..quadraticBezierTo(8, 3, 3, 5)
      ..lineTo(3, 20)
      ..quadraticBezierTo(8, 18, 12, 21)
      ..quadraticBezierTo(16, 18, 21, 20)
      ..lineTo(21, 5)
      ..quadraticBezierTo(16, 3, 12, 6)
      ..lineTo(12, 21),
  ],
  Icons.description_outlined || Icons.picture_as_pdf_outlined => [
    _line([14, 3, 5, 3, 5, 21, 19, 21, 19, 8, 14, 3, 14, 8, 19, 8]),
    _line([8, 12, 16, 12]),
    _line([8, 16, 14, 16]),
  ],
  Icons.account_tree_outlined || Icons.hub_outlined => [
    _box(3, 9, 6, 6, 1),
    _box(15, 3, 6, 6, 1),
    _box(15, 15, 6, 6, 1),
    _line([9, 12, 12, 12, 12, 6, 15, 6]),
    _line([12, 12, 12, 18, 15, 18]),
  ],
  Icons.view_list_outlined || Icons.notes_outlined => [
    _line([8, 5, 21, 5]),
    _line([8, 12, 21, 12]),
    _line([8, 19, 21, 19]),
    _line([3, 5, 4, 5]),
    _line([3, 12, 4, 12]),
    _line([3, 19, 4, 19]),
  ],
  Icons.folder_open_outlined || Icons.folder_outlined => [
    _line([3, 8, 3, 5, 9, 5, 11, 8, 21, 8, 21, 20, 3, 20, 3, 8, 21, 8]),
  ],
  Icons.layers_outlined || Icons.auto_awesome_motion_outlined => [
    _line([3, 8, 12, 3, 21, 8, 12, 13, 3, 8]),
    _line([3, 12, 12, 17, 21, 12]),
    _line([3, 16, 12, 21, 21, 16]),
  ],
  Icons.chevron_left => [
    _line([15, 5, 8, 12, 15, 19]),
  ],
  Icons.chevron_right => [
    _line([9, 5, 16, 12, 9, 19]),
  ],
  Icons.expand_more || Icons.arrow_drop_down => [
    _line([6, 9, 12, 15, 18, 9]),
  ],
  Icons.arrow_back => [
    _line([10, 5, 3, 12, 10, 19]),
    _line([3, 12, 21, 12]),
  ],
  Icons.arrow_forward => [
    _line([14, 5, 21, 12, 14, 19]),
    _line([3, 12, 21, 12]),
  ],
  Icons.more_horiz => [
    _circle(5, 12, .8),
    _circle(12, 12, .8),
    _circle(19, 12, .8),
  ],
  Icons.crop_square => [_box(4, 4, 16, 16, 2)],
  Icons.filter_none || Icons.copy_outlined || Icons.content_copy => [
    _box(8, 8, 13, 13, 1),
    _line([4, 16, 3, 16, 3, 3, 16, 3, 16, 4]),
  ],
  Icons.crop_free || Icons.fullscreen_rounded => [
    _line([3, 9, 3, 3, 9, 3]),
    _line([15, 3, 21, 3, 21, 9]),
    _line([21, 15, 21, 21, 15, 21]),
    _line([9, 21, 3, 21, 3, 15]),
  ],
  Icons.fit_screen => [
    _line([3, 8, 3, 4, 7, 4]),
    _line([17, 4, 21, 4, 21, 8]),
    _line([21, 16, 21, 20, 17, 20]),
    _line([7, 20, 3, 20, 3, 16]),
    _box(7, 8, 10, 8, 1),
  ],
  Icons.view_sidebar_outlined => [
    _box(3, 4, 18, 16),
    _line([9, 4, 9, 20]),
  ],
  Icons.sync_alt => [
    _line([3, 8, 21, 8, 17, 4]),
    _line([21, 16, 3, 16, 7, 20]),
  ],
  Icons.link => [
    Path()
      ..moveTo(9, 15)
      ..lineTo(15, 9),
    Path()
      ..moveTo(14, 6)
      ..lineTo(16, 4)
      ..cubicTo(21, 0, 25, 7, 20, 10)
      ..lineTo(18, 12),
    Path()
      ..moveTo(6, 12)
      ..lineTo(4, 14)
      ..cubicTo(0, 19, 7, 24, 10, 20)
      ..lineTo(12, 18),
  ],
  Icons.link_off => [
    _line([3, 3, 21, 21]),
    _line([14, 5, 17, 3, 21, 7, 19, 10]),
    _line([5, 14, 3, 17, 7, 21, 10, 19]),
  ],
  Icons.select_all => [
    _line([3, 7, 3, 3, 7, 3]),
    _line([11, 3, 13, 3]),
    _line([17, 3, 21, 3, 21, 7]),
    _line([21, 11, 21, 13]),
    _line([21, 17, 21, 21, 17, 21]),
    _line([13, 21, 11, 21]),
    _line([7, 21, 3, 21, 3, 17]),
    _line([3, 13, 3, 11]),
    _box(8, 8, 8, 8, 1),
  ],
  Icons.data_array => [
    _line([8, 3, 4, 3, 4, 21, 8, 21]),
    _line([16, 3, 20, 3, 20, 21, 16, 21]),
  ],
  Icons.tune => [
    _line([3, 6, 7, 6]),
    _line([11, 6, 21, 6]),
    _circle(9, 6, 2),
    _line([3, 12, 13, 12]),
    _line([17, 12, 21, 12]),
    _circle(15, 12, 2),
    _line([3, 18, 7, 18]),
    _line([11, 18, 21, 18]),
    _circle(9, 18, 2),
  ],
  Icons.title || Icons.text_fields => [
    _line([4, 5, 20, 5]),
    _line([12, 5, 12, 20]),
    _line([8, 20, 16, 20]),
  ],
  Icons.crop => [
    _line([7, 3, 7, 17, 21, 17]),
    _line([3, 7, 17, 7, 17, 21]),
  ],
  Icons.check || Icons.check_rounded => [
    _line([4, 12, 9, 17, 20, 6]),
  ],
  Icons.check_box_outlined => [
    _box(3, 3, 18, 18),
    _line([7, 12, 10, 15, 17, 8]),
  ],
  Icons.check_circle_outline => [
    _circle(12, 12, 9),
    _line([7, 12, 10, 15, 17, 8]),
  ],
  Icons.edit_note || Icons.edit_outlined || Icons.border_color_outlined => [
    _line([4, 16, 16, 4, 20, 8, 8, 20, 4, 20, 4, 16]),
    _line([13, 7, 17, 11]),
  ],
  Icons.comment_outlined || Icons.sticky_note_2_outlined => [
    _line([3, 4, 21, 4, 21, 17, 9, 17, 4, 21, 4, 17, 3, 17, 3, 4]),
    _line([7, 8, 17, 8]),
    _line([7, 12, 14, 12]),
  ],
  Icons.add_comment_outlined => [
    _line([3, 4, 21, 4, 21, 17, 9, 17, 4, 21, 4, 17, 3, 17, 3, 4]),
    _line([8, 10, 16, 10]),
    _line([12, 6, 12, 14]),
  ],
  Icons.pan_tool_outlined => [
    Path()
      ..moveTo(8, 12)
      ..lineTo(8, 5)
      ..quadraticBezierTo(10, 2, 12, 5)
      ..lineTo(12, 11)
      ..lineTo(12, 4)
      ..quadraticBezierTo(14, 1, 16, 4)
      ..lineTo(16, 11)
      ..lineTo(16, 6)
      ..quadraticBezierTo(18, 3, 20, 6)
      ..lineTo(20, 15)
      ..quadraticBezierTo(20, 21, 14, 21)
      ..lineTo(10, 21)
      ..quadraticBezierTo(8, 21, 7, 19)
      ..lineTo(3, 13)
      ..quadraticBezierTo(2, 10, 5, 11)
      ..lineTo(8, 14),
  ],
  Icons.delete_outline || Icons.delete_forever_outlined => [
    _line([3, 6, 21, 6]),
    _line([9, 6, 9, 3, 15, 3, 15, 6]),
    _line([5, 6, 6, 21, 18, 21, 19, 6]),
    _line([10, 10, 10, 17]),
    _line([14, 10, 14, 17]),
  ],
  Icons.short_text => [
    _line([4, 8, 20, 8]),
    _line([4, 15, 14, 15]),
  ],
  Icons.sort => [
    _line([4, 6, 20, 6]),
    _line([4, 12, 15, 12]),
    _line([4, 18, 10, 18]),
  ],
  Icons.image_outlined => [
    _box(3, 3, 18, 18),
    _circle(8, 8, 2),
    _line([3, 18, 10, 11, 15, 16, 18, 13, 21, 16]),
  ],
  Icons.inbox_outlined => [
    _line([
      3,
      15,
      6,
      4,
      18,
      4,
      21,
      15,
      21,
      21,
      3,
      21,
      3,
      15,
      8,
      15,
      10,
      18,
      14,
      18,
      16,
      15,
      21,
      15,
    ]),
  ],
  Icons.grid_view_outlined => [
    _box(3, 3, 7, 7, 1),
    _box(14, 3, 7, 7, 1),
    _box(3, 14, 7, 7, 1),
    _box(14, 14, 7, 7, 1),
  ],
  Icons.document_scanner_outlined => [
    _line([3, 7, 3, 3, 7, 3]),
    _line([17, 3, 21, 3, 21, 7]),
    _line([21, 17, 21, 21, 17, 21]),
    _line([7, 21, 3, 21, 3, 17]),
    _line([8, 7, 16, 7]),
    _line([8, 12, 16, 12]),
    _line([8, 17, 13, 17]),
  ],
  Icons.schedule_outlined => [
    _circle(12, 12, 9),
    _line([12, 6, 12, 12, 16, 14]),
  ],
  Icons.pause_circle_outline => [
    _circle(12, 12, 9),
    _line([9, 8, 9, 16]),
    _line([15, 8, 15, 16]),
  ],
  Icons.error_outline => [
    _circle(12, 12, 9),
    _line([12, 7, 12, 12]),
    _circle(12, 17, .5),
  ],
  Icons.warning_amber => [
    _line([12, 3, 22, 21, 2, 21, 12, 3]),
    _line([12, 9, 12, 14]),
    _circle(12, 18, .5),
  ],
  Icons.unfold_more => [
    _line([8, 8, 12, 4, 16, 8]),
    _line([8, 16, 12, 20, 16, 16]),
  ],
  Icons.unfold_less => [
    _line([8, 4, 12, 8, 16, 4]),
    _line([8, 20, 12, 16, 16, 20]),
  ],
  Icons.refresh || Icons.restart_alt => [
    Path()
      ..moveTo(20, 9)
      ..cubicTo(17, 0, 3, 2, 3, 12)
      ..cubicTo(3, 22, 18, 24, 21, 15),
    _line([20, 3, 20, 9, 14, 9]),
  ],
  Icons.drag_indicator => [
    _circle(9, 5, .6),
    _circle(15, 5, .6),
    _circle(9, 12, .6),
    _circle(15, 12, .6),
    _circle(9, 19, .6),
    _circle(15, 19, .6),
  ],
  Icons.content_paste => [
    _line([8, 4, 4, 4, 4, 21, 20, 21, 20, 4, 16, 4]),
    _box(8, 2, 8, 5, 1),
  ],
  Icons.subdirectory_arrow_right => [
    _line([5, 3, 5, 15, 20, 15]),
    _line([14, 9, 20, 15, 14, 21]),
  ],
  Icons.drive_file_move_outline => [
    _line([3, 8, 3, 5, 9, 5, 11, 8, 21, 8, 21, 20, 3, 20, 3, 8]),
    _line([8, 14, 16, 14, 13, 11]),
    _line([16, 14, 13, 17]),
  ],
  Icons.format_shapes => [
    _box(5, 5, 14, 14, 0),
    _box(2, 2, 5, 5, 0),
    _box(17, 2, 5, 5, 0),
    _box(2, 17, 5, 5, 0),
    _box(17, 17, 5, 5, 0),
  ],
  Icons.palette_outlined => [
    Path()
      ..moveTo(12, 3)
      ..cubicTo(1, 3, 1, 21, 12, 21)
      ..cubicTo(17, 21, 10, 15, 16, 15)
      ..cubicTo(26, 15, 23, 3, 12, 3),
    _circle(7, 9, .8),
    _circle(11, 6, .8),
    _circle(17, 8, .8),
  ],
  Icons.content_cut => [
    _circle(6, 6, 3),
    _circle(6, 18, 3),
    _line([8, 8, 21, 21]),
    _line([8, 16, 21, 3]),
  ],
  _ => null,
};
