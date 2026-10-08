import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:opennote/ui/reader/source_highlight.dart';
import 'package:opennote/ui/reader/reader_contract.dart';
import 'package:opennote/domain/models.dart';

void main() {
  test('连续文字标注：普通和连续空格连接，索引换行与栏间空白不跨越', () {
    const a = Rect.fromLTWH(10, 10, 9, 14);
    const b = Rect.fromLTWH(45, 10.1, 9, 14);
    const c = Rect.fromLTWH(11, 32, 9, 14);
    const column = Rect.fromLTWH(180, 10, 9, 14);
    final ranges = <Rect, HighlightTextRange>{
      a: (start: 0, end: 1),
      b: (start: 4, end: 5),
      c: (start: 6, end: 7),
      column: (start: 4, end: 5),
    };
    expect(
      mergeTextHighlightRects([b, c, a], text: '甲   乙\n丙', textRanges: ranges),
      [const Rect.fromLTRB(10, 10, 54, 24.1), c],
    );
    expect(
      mergeTextHighlightRects([a, column], text: '甲   乙', textRanges: ranges),
      [a, column],
    );
    const close = Rect.fromLTWH(20, 10, 9, 14);
    expect(
      mergeTextHighlightRects(
        [a, close],
        text: '甲\n乙',
        textRanges: {a: (start: 0, end: 1), close: (start: 2, end: 3)},
      ),
      [a, close],
      reason: '有文字索引时，几何接近也不能跨文本流的换行',
    );
  });

  test('连续文字标注：无文字层沿用邻接规则，旋转后空格连接且坐标输入不改变', () {
    const a = Rect.fromLTWH(10, 10, 9, 14);
    const b = Rect.fromLTWH(45, 10.1, 9, 14);
    Rect rotate(Rect r) => Rect.fromLTRB(r.top, r.left, r.bottom, r.right);
    final input = [rotate(b), rotate(a)];
    expect(
      mergeTextHighlightRects(
        input,
        vertical: true,
        text: 'A   B',
        textRanges: {
          rotate(a): (start: 0, end: 1),
          rotate(b): (start: 4, end: 5),
        },
      ),
      [rotate(const Rect.fromLTRB(10, 10, 54, 24.1))],
    );
    expect(input, [rotate(b), rotate(a)]);
    final legacy = [a, const Rect.fromLTWH(20, 10, 9, 14), b];
    expect(mergeTextHighlightRects(legacy), mergeSourceHighlightRects(legacy));
    expect(mergeTextHighlightRects(const []), isEmpty);
  });
  test('柔和回源：邻接字框合并，不跨行跨栏，旋转后仍连续', () {
    final rects = [
      const Rect.fromLTWH(10, 10, 9, 14),
      const Rect.fromLTWH(20, 10, 9, 14),
      const Rect.fromLTWH(11, 30, 9, 14),
      const Rect.fromLTWH(150, 10, 9, 14),
    ];
    expect(mergeSourceHighlightRects(rects), hasLength(3));
    expect(
      mergeSourceHighlightRects(rects).first,
      const Rect.fromLTRB(10, 10, 29, 24),
    );
    final rotated = rects.map(
      (r) => Rect.fromLTRB(r.top, r.left, r.bottom, r.right),
    );
    expect(mergeSourceHighlightRects(rotated, vertical: true), hasLength(3));
  });
  test('柔和回源：轻微基线误差及乱序字框仍形成单条连续底色', () {
    expect(
      mergeSourceHighlightRects([
        const Rect.fromLTWH(30, 10, 9, 14),
        const Rect.fromLTWH(10, 10.1, 9, 14),
        const Rect.fromLTWH(20, 10.2, 9, 14),
      ]),
      [const Rect.fromLTRB(10, 10, 39, 24.2)],
    );
  });

  test('柔和回源：请求序号隔离旧结果，删除来源卡片取消等待和强调', () async {
    final controller = ReaderPaneController()..currentZoomDelegate = () => 1.19;
    final requests = <ReaderSourceRequest>[];
    var cleared = 0;
    controller.jumpToAnchorsDelegate = (request) async {
      requests.add(request);
    };
    controller.clearHighlightsDelegate = () => cleared++;
    await controller.jumpToAnchors(const [
      AnchorDraft(revisionId: 'old', pageIndex: 0, quads: []),
    ], cardId: 'a');
    await controller.jumpToAnchors(const [
      AnchorDraft(revisionId: 'new', pageIndex: 2, quads: []),
    ], cardId: 'b');
    expect(requests.last.zoom, 1.19);
    expect(controller.isCurrentSource(requests.first), isFalse);
    controller.activateRevision('new');
    expect(controller.isCurrentSource(requests.last), isTrue);
    controller.clearAfterCardDeletion({'b'});
    expect(controller.pendingAnchors, isNull);
    expect(controller.isCurrentSource(requests.last), isFalse);
    expect(cleared, 1);
    await controller.jumpToAnchors(const [
      AnchorDraft(revisionId: 'new', pageIndex: 0, quads: []),
    ]);
    controller.activateRevision('manual-other');
    expect(controller.pendingAnchors, isNull);
  });
}
