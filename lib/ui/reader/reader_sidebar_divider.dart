import 'package:flutter/material.dart';

import '../theme/open_note_theme.dart';

class ReaderSidebarDivider extends StatefulWidget {
  const ReaderSidebarDivider({
    super.key,
    required this.onDragUpdate,
    required this.onDragEnd,
  });
  final ValueChanged<double> onDragUpdate;
  final VoidCallback onDragEnd;

  @override
  State<ReaderSidebarDivider> createState() => _ReaderSidebarDividerState();
}

class _ReaderSidebarDividerState extends State<ReaderSidebarDivider> {
  bool _hovered = false;
  bool _dragging = false;

  void _end() {
    if (!_dragging) return;
    setState(() => _dragging = false);
    widget.onDragEnd();
  }

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.resizeColumn,
    onEnter: (_) => setState(() => _hovered = true),
    onExit: (_) => setState(() => _hovered = false),
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragStart: (_) => setState(() => _dragging = true),
      onHorizontalDragUpdate: (event) => widget.onDragUpdate(event.delta.dx),
      onHorizontalDragEnd: (_) => _end(),
      onHorizontalDragCancel: _end,
      child: SizedBox(
        width: 6,
        child: Center(
          child: AnimatedContainer(
            key: const Key('reader-sidebar-divider-line'),
            duration: const Duration(milliseconds: 120),
            width: _dragging ? 2 : 1,
            color: _dragging
                ? OpenNoteTokens.accent
                : _hovered
                ? OpenNoteTokens.secondary.withValues(alpha: .55)
                : OpenNoteTokens.border,
          ),
        ),
      ),
    ),
  );
}
