import 'package:flutter/material.dart';

import '../theme/open_note_icon.dart';
import '../theme/open_note_theme.dart';

class ReaderPageNavigation extends StatefulWidget {
  const ReaderPageNavigation({
    super.key,
    required this.controller,
    required this.ready,
    required this.pageCount,
    required this.showArrows,
    required this.onSubmitted,
    required this.onPrevious,
    required this.onNext,
  });

  final TextEditingController controller;
  final bool ready;
  final int? pageCount;
  final bool showArrows;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  @override
  State<ReaderPageNavigation> createState() => _ReaderPageNavigationState();
}

class _ReaderPageNavigationState extends State<ReaderPageNavigation> {
  final _pageFocus = FocusNode(debugLabel: 'PDF 页码');

  @override
  void dispose() {
    _pageFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(context).style.copyWith(
      fontSize: 14,
      height: 1.25,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final measure = TextPainter(
      text: TextSpan(text: '8888', style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    // 为四位数字、内边距、边框及光标预留固定空间。
    final inputWidth = (measure.width + 32).clamp(56.0, double.infinity);
    measure.dispose();
    return Row(
      key: const Key('reader-page-navigation'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        if (widget.showArrows)
          IconButton(
            tooltip: '上一页',
            onPressed: widget.ready ? widget.onPrevious : null,
            icon: const OpenNoteIcon(Icons.chevron_left),
          ),
        SizedBox(
          width: inputWidth,
          height: 32,
          child: AnimatedBuilder(
            animation: _pageFocus,
            builder: (context, child) => Container(
              key: const Key('reader-page-input-frame'),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: _pageFocus.hasFocus
                      ? OpenNoteTokens.accent
                      : OpenNoteTokens.border,
                  width: _pageFocus.hasFocus ? 1.5 : 1,
                ),
              ),
              child: child,
            ),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: TextField(
                  key: const Key('reader-page-input'),
                  controller: widget.controller,
                  focusNode: _pageFocus,
                  readOnly: !widget.ready,
                  textAlign: TextAlign.center,
                  textAlignVertical: TextAlignVertical.center,
                  style: style,
                  strutStyle: StrutStyle.fromTextStyle(
                    style,
                    forceStrutHeight: true,
                  ),
                  decoration: const InputDecoration(
                    isCollapsed: true,
                    filled: false,
                    contentPadding: EdgeInsets.zero,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    disabledBorder: InputBorder.none,
                  ),
                  onSubmitted: widget.onSubmitted,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Tooltip(
            message: '共 ${widget.pageCount ?? "—"} 页',
            child: Text(
              '/ ${widget.pageCount ?? "—"}',
              key: const Key('reader-page-total'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style.copyWith(color: OpenNoteTokens.secondary),
              strutStyle: StrutStyle.fromTextStyle(
                style,
                forceStrutHeight: true,
              ),
            ),
          ),
        ),
        if (widget.showArrows)
          IconButton(
            tooltip: '下一页',
            onPressed: widget.ready ? widget.onNext : null,
            icon: const OpenNoteIcon(Icons.chevron_right),
          ),
      ],
    );
  }
}
