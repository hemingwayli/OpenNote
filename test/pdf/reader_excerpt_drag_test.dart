import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:opennote/domain/models.dart';
import 'package:opennote/ui/reader/reader_contract.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('文字拖动合同：锚点只读，一次领取、一次准备和一次成功确认', () async {
    final quads = [PdfQuad.rect(1, 2, 3, 4)];
    final originalPoints = quads.single.points;
    final anchors = [
      AnchorDraft(
        revisionId: 'revision',
        pageIndex: 0,
        textLayerId: 'layer-version',
        quads: quads,
        context: '甲  乙',
      ),
    ];
    var prepared = 0, committed = 0, finished = 0;
    final pending = Completer<SelectedExcerpt>();
    final drag = ReaderExcerptDrag(
      revisionId: 'revision',
      text: '甲  乙',
      anchors: anchors,
      sourceIsCurrent: () => true,
      prepareExcerpt: () {
        prepared++;
        return pending.future;
      },
      onCommitted: () => committed++,
      onFinished: (_) => finished++,
    );
    anchors.clear();
    quads.clear();
    originalPoints.clear();
    expect(drag.anchors.single.quads, hasLength(1));
    expect(drag.anchors.single.quads.single.points, hasLength(4));
    expect(drag.anchors.single.textLayerId, 'layer-version');
    expect(() => drag.anchors.clear(), throwsUnsupportedError);
    expect(() => drag.anchors.single.quads.clear(), throwsUnsupportedError);
    expect(
      () => drag.anchors.single.quads.single.points.clear(),
      throwsUnsupportedError,
    );
    drag.start();
    expect(drag.started, isTrue);
    expect(drag.claim(), isTrue);
    expect(drag.claim(), isFalse);
    final first = drag.prepare();
    expect(identical(first, drag.prepare()), isTrue);
    pending.complete(SelectedExcerpt(text: drag.text, anchors: drag.anchors));
    expect((await first).text, '甲  乙');
    drag.commit();
    drag.commit();
    drag.fail(StateError('迟到失败'));
    expect(prepared, 1);
    expect(committed, 1);
    expect(finished, 1);
    expect(drag.canAccept, isFalse);
  });

  test('文字拖动合同：准备中取消或切换会话，迟到结果不确认也不报告旧错误', () async {
    for (final cancel in [true, false]) {
      var current = true, committed = 0, finished = 0;
      Object? reported;
      final pending = Completer<SelectedExcerpt>();
      final drag = ReaderExcerptDrag(
        revisionId: 'old',
        text: '原选区',
        anchors: const [],
        sourceIsCurrent: () => current,
        prepareExcerpt: () => pending.future,
        onCommitted: () => committed++,
        onFinished: (error) {
          finished++;
          reported = error;
        },
      );
      expect(drag.claim(), isTrue);
      final preparing = drag.prepare();
      final rejected = expectLater(
        preparing,
        throwsA(isA<ReaderExcerptDragCancelled>()),
      );
      if (cancel) {
        drag.cancel();
      } else {
        current = false;
      }
      pending.complete(const SelectedExcerpt(text: '原选区', anchors: []));
      await rejected;
      drag.fail(StateError('旧保存错误'));
      drag.commit();
      expect(committed, 0);
      expect(finished, 1);
      expect(reported, isNull);
      expect(drag.canAccept, isFalse);
    }
  });
}
