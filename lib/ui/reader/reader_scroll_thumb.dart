import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../theme/open_note_theme.dart';

/// 沿用 PDF 的定位和拖动算法，只管理滚动条的显隐。
class ReaderScrollThumb extends StatefulWidget {
  const ReaderScrollThumb({
    super.key,
    required this.controller,
    required this.onInteraction,
  });
  final PdfViewerController controller;
  final VoidCallback onInteraction;

  @override
  State<ReaderScrollThumb> createState() => _ReaderScrollThumbState();
}

class _ReaderScrollThumbState extends State<ReaderScrollThumb> {
  Timer? _idle;
  bool _visible = true;
  bool _hovered = false;
  bool _pressed = false;
  late List<double> _lastTransform;

  @override
  void initState() {
    super.initState();
    _lastTransform = widget.controller.isReady
        ? List.of(widget.controller.value.storage)
        : [];
    widget.controller.addListener(_changed);
    _scheduleHide();
  }

  @override
  void didUpdateWidget(ReaderScrollThumb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
      _lastTransform = widget.controller.isReady
          ? List.of(widget.controller.value.storage)
          : [];
    }
  }

  void _changed() {
    if (!widget.controller.isReady) return;
    final transform = widget.controller.value.storage;
    if (listEquals(_lastTransform, transform)) return;
    _lastTransform = List.of(transform);
    _show();
  }

  void _show() {
    if (!_visible && mounted) setState(() => _visible = true);
    _scheduleHide();
  }

  void _scheduleHide() {
    _idle?.cancel();
    if (_hovered || _pressed) return;
    _idle = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _visible = false);
    });
  }

  @override
  void dispose() {
    _idle?.cancel();
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Positioned.fill(
    child: MouseRegion(
      opaque: true,
      hitTestBehavior: HitTestBehavior.deferToChild,
      onEnter: (_) {
        _hovered = true;
        _show();
      },
      onExit: (_) {
        _hovered = false;
        _scheduleHide();
      },
      child: Stack(
        children: [
          // 只在右侧保留唤出区域，透明覆盖层不拦截正文操作。
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            width: 20,
            child: MouseRegion(
              opaque: false,
              hitTestBehavior: HitTestBehavior.translucent,
              onEnter: (_) {
                _hovered = true;
                _show();
              },
              onExit: (_) {
                _hovered = false;
                _scheduleHide();
              },
              child: const SizedBox.expand(),
            ),
          ),
          PdfViewerScrollThumb(
            key: const Key('reader-document-scrollbar'),
            controller: widget.controller,
            thumbSize: const Size(18, 56),
            thumbBuilder: (context, size, page, controller) => AnimatedOpacity(
              key: const Key('reader-scrollbar-opacity'),
              opacity: _visible ? 1 : 0,
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 200),
              child: IgnorePointer(
                ignoring: !_visible,
                child: Listener(
                  onPointerDown: (_) {
                    _pressed = true;
                    _show();
                    widget.onInteraction();
                  },
                  onPointerUp: (_) {
                    _pressed = false;
                    _scheduleHide();
                  },
                  onPointerCancel: (_) {
                    _pressed = false;
                    _scheduleHide();
                  },
                  child: Tooltip(
                    message:
                        '第 ${page ?? 1} / ${controller.pageCount} 页 · 拖动定位',
                    child: Semantics(
                      label: '文档滚动条',
                      child: Container(
                        key: const Key('reader-document-scroll-thumb'),
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        decoration: BoxDecoration(
                          color: OpenNoteTokens.secondary.withValues(
                            alpha: .55,
                          ),
                          borderRadius: BorderRadius.circular(5),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
