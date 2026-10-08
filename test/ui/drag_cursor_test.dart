import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opennote/ui/theme/open_note_drag_cursor.dart';
import 'package:opennote/ui/reader/reader_contract.dart';

void main() {
  testWidgets('光标反馈：透明命中、不阻断按钮，移除和销毁恢复默认光标', (tester) async {
    final cursor = OpenNoteDragCursor();
    late BuildContext host;
    var clicked = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              host = context;
              return Center(
                child: IconButton(
                  onPressed: () => clicked++,
                  icon: const Icon(Icons.add),
                ),
              );
            },
          ),
        ),
      ),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(find.byType(IconButton)));
    await mouse.moveTo(tester.getCenter(find.byType(IconButton)));
    cursor.show(host, SystemMouseCursors.grabbing);
    final preview = OverlayEntry(
      builder: (_) => const Positioned.fill(
        child: MouseRegion(
          cursor: SystemMouseCursors.grab,
          child: SizedBox.expand(),
        ),
      ),
    );
    Overlay.of(host, rootOverlay: true).insert(preview);
    await tester.pump();
    await tester.pump();
    expect(
      tester.binding.mouseTracker.debugDeviceActiveCursor(1),
      SystemMouseCursors.grabbing,
    );
    preview.remove();
    preview.dispose();
    await tester.pump();
    await tester.tap(find.byType(IconButton));
    expect(clicked, 1);
    cursor.update(SystemMouseCursors.noDrop);
    await tester.pump();
    expect(
      tester.binding.mouseTracker.debugDeviceActiveCursor(1),
      SystemMouseCursors.noDrop,
    );
    cursor.hide();
    await tester.pump();
    expect(
      tester.binding.mouseTracker.debugDeviceActiveCursor(1),
      SystemMouseCursors.basic,
    );
    cursor.show(host, SystemMouseCursors.copy);
    cursor.hide();
    await tester.pumpWidget(const SizedBox.shrink());
    await mouse.removePointer();
    expect(tester.takeException(), isNull);
  });

  test('光标反馈：文字落点按接收区身份清理，取消后旧目标不显示有效反馈', () {
    final drag = ReaderExcerptDrag(
      revisionId: 'r',
      text: '文字',
      anchors: const [],
      sourceIsCurrent: () => true,
      prepareExcerpt: () async =>
          const SelectedExcerpt(text: '文字', anchors: []),
      onCommitted: () {},
      onFinished: (_) {},
    );
    final first = Object(), second = Object();
    drag.start();
    drag.setDropTarget(first, accepted: true);
    expect(drag.hasDropTarget, isTrue);
    drag.setDropTarget(second, accepted: true);
    drag.clearDropTarget(first);
    expect(drag.hasDropTarget, isTrue);
    drag.clearDropTarget(second);
    expect(drag.hasDropTarget, isFalse);
    drag.cancel();
    drag.setDropTarget(first, accepted: true);
    expect(drag.hasDropTarget, isFalse);
    drag.dispose();
  });
}
