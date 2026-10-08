import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opennote/ui/reader/reader_page_navigation.dart';
import 'package:opennote/ui/theme/open_note_theme.dart';

void main() {
  for (final scale in [1.0, 1.5]) {
    testWidgets('阅读排版：页码统一基线、四位输入宽度稳定和回车跳转（$scale）', (tester) async {
      final controller = TextEditingController(text: '1');
      addTearDown(controller.dispose);
      String? submitted;
      var previous = 0;
      var next = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: openNoteTheme(),
          home: Scaffold(
            body: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: Center(
                child: SizedBox(
                  width: 380,
                  child: ReaderPageNavigation(
                    controller: controller,
                    ready: true,
                    pageCount: 9999,
                    showArrows: true,
                    onSubmitted: (value) => submitted = value,
                    onPrevious: () => previous++,
                    onNext: () => next++,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final input = find.byKey(const Key('reader-page-input'));
      final total = find.byKey(const Key('reader-page-total'));
      final field = tester.widget<TextField>(input);
      final text = tester.widget<Text>(total);
      expect(field.style!.fontSize, text.style!.fontSize);
      expect(field.decoration!.enabledBorder, InputBorder.none);
      expect(field.decoration!.focusedBorder, InputBorder.none);
      expect(field.style!.height, text.style!.height);
      final editable = _renderDescendant<RenderEditable>(
        tester.renderObject(find.byType(EditableText)),
      );
      final paragraph = _renderDescendant<RenderParagraph>(
        tester.renderObject(total),
      );
      final inputGlyph = editable.getRectForComposingRange(
        const TextRange(start: 0, end: 1),
      )!;
      final totalGlyph = paragraph
          .getBoxesForSelection(
            const TextSelection(baseOffset: 0, extentOffset: 1),
            boxHeightStyle: editable.selectionHeightStyle,
            boxWidthStyle: editable.selectionWidthStyle,
          )
          .single
          .toRect();
      // 两处使用同一字体及行高，实际字形框的底边应对齐。
      final inputBaseline = editable.localToGlobal(inputGlyph.bottomLeft).dy;
      final totalBaseline = paragraph.localToGlobal(totalGlyph.bottomLeft).dy;
      expect(inputBaseline, closeTo(totalBaseline, 1));
      final frame = find.byKey(const Key('reader-page-input-frame'));
      final width = tester.getSize(frame).width;
      final nextPosition = tester.getTopLeft(find.byTooltip('下一页'));
      Border border() =>
          (tester
                          .widget<Container>(
                            find.byKey(const Key('reader-page-input-frame')),
                          )
                          .decoration!
                      as BoxDecoration)
                  .border!
              as Border;
      expect(border().top.color, OpenNoteTokens.border);
      await tester.enterText(input, '1234');
      await tester.pump();
      expect(tester.getSize(frame).width, width);
      expect(tester.getTopLeft(find.byTooltip('下一页')), nextPosition);
      expect(editable.maxScrollExtent, 0, reason: '四位页码完整显示');
      expect(border().top.color, OpenNoteTokens.accent);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      expect(submitted, '1234');
      await tester.tap(find.byTooltip('上一页'));
      await tester.tap(find.byTooltip('下一页'));
      expect(previous, 1);
      expect(next, 1);
      expect(tester.takeException(), isNull);
    });
  }
}

T _renderDescendant<T extends RenderObject>(RenderObject root) {
  T? result;
  void visit(RenderObject object) {
    if (object is T) result = object;
    object.visitChildren(visit);
  }

  visit(root);
  expect(result, isNotNull, reason: '必须检查实际文字渲染对象');
  return result!;
}
