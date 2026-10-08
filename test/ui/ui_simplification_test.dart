import 'package:flutter/material.dart';

import 'dart:ui' show Tristate;

import 'package:flutter_test/flutter_test.dart';
import 'package:opennote/ui/theme/open_note_search.dart';
import 'package:opennote/ui/theme/open_note_view_switch.dart';

void main() {
  testWidgets('搜索入口：图标展开、快捷键焦点、失焦保留查询与清空收起', (tester) async {
    final controller = TextEditingController();
    final focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);
    var query = '';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              OpenNoteSearch(
                controller: controller,
                focusNode: focus,
                inputKey: const Key('input'),
                label: '搜索项目',
                onChanged: (value) => query = value,
              ),
              TextButton(
                onPressed: () => FocusManager.instance.primaryFocus?.unfocus(),
                child: const Text('内容'),
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('input')), findsNothing);
    await tester.tap(find.byTooltip('搜索项目'));
    await tester.pump();
    expect(focus.hasFocus, isTrue);
    await tester.enterText(find.byKey(const Key('input')), '知识');
    await tester.tap(find.text('内容'));
    await tester.pump();
    expect(find.byKey(const Key('input')), findsOneWidget);
    expect(query, '知识');
    await tester.tap(find.byTooltip('清除搜索'));
    await tester.pump();
    await tester.tap(find.text('内容'));
    await tester.pump();
    expect(query, isEmpty);
    expect(find.byKey(const Key('input')), findsNothing);
    focus.requestFocus();
    await tester.pump();
    expect(find.byKey(const Key('input')), findsOneWidget);
    expect(focus.hasFocus, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('图标视图切换保留名称、选中语义与最小命中区域', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      var selected = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, update) => OpenNoteViewSwitch(
                value: selected,
                labels: const ['资料', '卡片'],
                iconOnly: true,
                icons: const [Icons.folder_open, Icons.layers],
                onChanged: (value) => update(() => selected = value),
              ),
            ),
          ),
        ),
      );
      expect(find.text('资料'), findsNothing);
      expect(find.byTooltip('卡片'), findsOneWidget);
      final button = find.descendant(
        of: find.byTooltip('卡片'),
        matching: find.byType(TextButton),
      );
      expect(tester.getSize(button).height, greaterThanOrEqualTo(36));
      expect(tester.getSize(button).width, greaterThanOrEqualTo(36));
      await tester.tap(button);
      await tester.pump();
      expect(selected, isTrue);
      expect(
        tester
            .getSemantics(
              find
                  .ancestor(
                    of: find.byTooltip('卡片'),
                    matching: find.byWidgetPredicate(
                      (w) => w is Semantics && w.properties.selected != null,
                    ),
                  )
                  .first,
            )
            .flagsCollection
            .isSelected,
        Tristate.isTrue,
      );
    } finally {
      semantics.dispose();
    }
  });
}
