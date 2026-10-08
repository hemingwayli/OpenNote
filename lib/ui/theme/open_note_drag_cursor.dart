import 'package:flutter/widgets.dart';

/// 锁定一次拖动的光标；透明命中层不阻断底下的拖放目标或鼠标手势。
class OpenNoteDragCursor {
  OverlayEntry? _entry;
  MouseCursor _cursor = SystemMouseCursors.grabbing;

  void show(BuildContext context, MouseCursor cursor) {
    if (_entry != null) {
      update(cursor);
      return;
    }
    _cursor = cursor;
    _entry = OverlayEntry(
      builder: (_) => Positioned.fill(
        child: MouseRegion(
          cursor: _cursor,
          opaque: false,
          hitTestBehavior: HitTestBehavior.translucent,
          child: const SizedBox.expand(),
        ),
      ),
    );
    final overlay = Overlay.of(context, rootOverlay: true);
    final entry = _entry!;
    overlay.insert(entry);
    // 标签排序的预览层在启动回调后插入；下一帧把光标层放回其上方。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (identical(_entry, entry) && overlay.mounted) {
        overlay.rearrange([entry], below: entry);
      }
    });
  }

  void update(MouseCursor cursor) {
    if (_cursor == cursor) return;
    _cursor = cursor;
    _entry?.markNeedsBuild();
  }

  void hide() {
    final entry = _entry;
    _entry = null;
    entry?.remove();
    entry?.dispose();
  }
}
