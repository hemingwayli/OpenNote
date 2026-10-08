import '../theme/open_note_icon.dart';

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../domain/models.dart';
import '../../domain/map_layout.dart';
import '../../domain/branch_structure.dart';
import '../../domain/structure_geometry.dart';
import '../theme/open_note_theme.dart';
import 'topic_style_painter.dart';

/// 用结构示意图帮助选择；确认前不修改当前脑图或草稿。
class MapStructureDialog extends StatefulWidget {
  const MapStructureDialog({super.key, required this.current});
  final MapLayoutKind current;
  @override
  State<MapStructureDialog> createState() => _MapStructureDialogState();
}

class _MapStructureDialogState extends State<MapStructureDialog> {
  late MapLayoutKind selected = widget.current;
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('选择脑图结构'),
    content: SizedBox(
      width: 720,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final scale = MediaQuery.textScalerOf(context).scale(1);
          final columns = math.max(
            1,
            math.min(4, (constraints.maxWidth / (160 * scale)).floor()),
          );
          final width = (constraints.maxWidth - (columns - 1) * 12) / columns;
          return SingleChildScrollView(
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final kind in MapLayoutKind.values)
                  SizedBox(
                    width: width,
                    child: OutlinedButton(
                      key: ValueKey('structure-${kind.name}'),
                      onPressed: () => setState(() => selected = kind),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.all(12),
                        foregroundColor: selected == kind
                            ? OpenNoteTokens.accent
                            : OpenNoteTokens.text,
                        backgroundColor: selected == kind
                            ? OpenNoteTokens.background
                            : Colors.white,
                        side: BorderSide(
                          color: selected == kind
                              ? OpenNoteTokens.accent
                              : OpenNoteTokens.border,
                        ),
                      ),
                      child: Column(
                        children: [
                          SizedBox(
                            height: 68,
                            width: double.infinity,
                            child: CustomPaint(
                              painter: StructurePreviewPainter(kind),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Flexible(
                                child: Text(
                                  kind.label,
                                  textAlign: TextAlign.center,
                                ),
                              ),
                              if (selected == kind) ...[
                                const SizedBox(width: 6),
                                const OpenNoteIcon(
                                  Icons.check_rounded,
                                  size: 16,
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const ValueKey('confirm-map-structure'),
        onPressed: () => Navigator.pop(context, selected),
        child: const Text('应用结构'),
      ),
    ],
  );
}

class StructurePreviewPainter extends CustomPainter {
  StructurePreviewPainter(this.kind);
  final MapLayoutKind kind;
  @override
  void paint(Canvas canvas, Size size) {
    final nodes = [
      for (var i = 0; i < 7; i++)
        MapNode(
          id: '$i',
          mapId: 'preview',
          cardId: '$i',
          parentNodeId: i == 0
              ? null
              : i <= 3
              ? '0'
              : '${i - 3}',
          x: i == 0 ? 0 : 200,
          y: i * 90,
          width: i == 0 ? 110 : 80,
          height: 40,
        ),
    ];
    final plan = calculateMapLayout(nodes, kind);
    final positions = kind == MapLayoutKind.free
        ? <String, PdfPoint>{
            '0': const PdfPoint(180, 100),
            '1': const PdfPoint(360, 20),
            '2': const PdfPoint(390, 140),
            '3': const PdfPoint(20, 170),
            '4': const PdfPoint(480, 80),
            '5': const PdfPoint(400, 270),
            '6': const PdfPoint(20, 30),
          }
        : plan.positions;
    final left = positions.values.map((p) => p.x).reduce(math.min);
    final top = positions.values.map((p) => p.y).reduce(math.min);
    final right = nodes
        .map((n) => positions[n.id]!.x + n.width)
        .reduce(math.max);
    final bottom = nodes
        .map((n) => positions[n.id]!.y + n.height)
        .reduce(math.max);
    final scale = math.min(
      (size.width - 8) / (right - left),
      (size.height - 8) / (bottom - top),
    );
    canvas.save();
    canvas.translate(
      (size.width - (right - left) * scale) / 2,
      (size.height - (bottom - top) * scale) / 2,
    );
    canvas.scale(scale);
    canvas.translate(-left, -top);
    final placed = [
      for (final n in nodes)
        MapNode(
          id: n.id,
          mapId: n.mapId,
          cardId: n.cardId,
          parentNodeId: n.parentNodeId,
          x: positions[n.id]!.x,
          y: positions[n.id]!.y,
          width: n.width,
          height: n.height,
          branchSide: plan.branchSides[n.id],
        ),
    ];
    final layouts = branchLayoutsFor(placed, kind);
    final paint = Paint()
      ..color = const Color(0xffb7babf)
      ..strokeWidth = 1.3 / scale
      ..style = PaintingStyle.stroke;
    final spines = <String, StructureSpineGeometry>{};
    for (final parent in placed) {
      final outgoing = layouts[parent.id]!;
      final geometry = structureSpineGeometry(
        parent,
        [
          for (final n in placed.where((n) => n.parentNodeId == parent.id))
            (n, positions[n.id]!),
        ],
        outgoing,
        positions[parent.id]!,
      );
      if (geometry != null) {
        spines[parent.id] = geometry;
        canvas.drawPath(structureSpinePath(geometry), paint);
      }
    }
    for (final n in placed.skip(1)) {
      final parent = placed.firstWhere((p) => p.id == n.parentNodeId);
      final incoming = layouts[parent.id]!;
      final special = structureLinkGeometry(
        parent,
        n,
        incoming,
        positions[parent.id]!,
        positions[n.id]!,
        spine: spines[parent.id],
      );
      final direction = incoming.primaryDirection;
      final reverse =
          direction == MapLayoutKind.left ||
          direction == MapLayoutKind.up ||
          incoming == MapLayoutKind.mindMap && n.x < parent.x;
      final start = Offset(
        parent.x +
            (direction.vertical
                ? parent.width / 2
                : reverse
                ? 0
                : parent.width),
        parent.y +
            (direction.vertical
                ? reverse
                      ? 0
                      : parent.height
                : parent.height / 2),
      );
      final end = Offset(
        n.x +
            (direction.vertical
                ? n.width / 2
                : reverse
                ? n.width
                : 0),
        n.y +
            (direction.vertical
                ? reverse
                      ? n.height
                      : 0
                : n.height / 2),
      );
      canvas.drawPath(
        special == null
            ? branchPath(start, end, BranchPath.curve, direction.vertical)
            : structureLinePath(special),
        paint,
      );
    }
    for (final n in placed) {
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(n.x, n.y, n.width, n.height),
        const Radius.circular(8),
      );
      canvas.drawRRect(
        rect,
        Paint()
          ..color = n.id == '0' ? OpenNoteTokens.text : OpenNoteTokens.selected,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(StructurePreviewPainter old) => old.kind != kind;
}
