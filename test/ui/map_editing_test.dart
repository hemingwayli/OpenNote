import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opennote/domain/models.dart';
import 'package:opennote/ui/map/mind_map_pane.dart';
import 'package:opennote/ui/theme/open_note_theme.dart';

void main() {
  testWidgets('快速编辑键：Tab、前后同级、上层和仅删当前主题；箭头不回源', (tester) async {
    final controller = MindMapPaneController();
    final actions = <(String, String)>[];
    final activated = <String>[];
    final selected = <String>[];
    await _mount(
      tester,
      controller,
      onAction: (node, action) => actions.add((node.id, action)),
      onSelect: (node) => selected.add(node.id),
      onActivate: (node) => activated.add(node.id),
    );
    await _click(tester, 'a');
    activated.clear();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _chord(
      tester,
      LogicalKeyboardKey.shiftLeft,
      LogicalKeyboardKey.enter,
    );
    await _chord(
      tester,
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.enter,
    );
    await _chord(
      tester,
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.delete,
    );
    expect(actions, [
      ('a', 'newChild'),
      ('a', 'newSibling'),
      ('a', 'newSiblingBefore'),
      ('a', 'newParent'),
      ('a', 'removeTopicOnly'),
    ]);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(selected.last, 'c');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(selected.last, 'a');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    expect(selected.last, 'b');
    expect(activated, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('标题编辑：中文组合态 Enter 不提前提交，文本快捷键不操作脑图', (tester) async {
    final controller = MindMapPaneController();
    final actions = <String>[];
    final clipboard = <String>[];
    var commits = 0;
    await _mount(
      tester,
      controller,
      onAction: (_, action) => actions.add(action),
      onClipboardAction: clipboard.add,
      onCommit: () async {
        commits++;
        controller.acceptTitle(controller.titleDraft!);
      },
    );
    await _click(tester, 'a');
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    final input = find.byKey(const ValueKey('map-title-input'));
    expect(input, findsOneWidget);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '中文标题',
        selection: TextSelection.collapsed(offset: 4),
        composing: TextRange(start: 0, end: 4),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(commits, 0);
    await _chord(
      tester,
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.keyA,
    );
    await _chord(
      tester,
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.keyC,
    );
    expect(clipboard, isEmpty);
    expect(actions, isEmpty);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '中文标题',
        selection: TextSelection.collapsed(offset: 4),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(commits, 1);
    expect(input, findsNothing);
    expect(controller.titleDraft, isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('标题编辑：保存失败保留草稿、Esc 取消，正文双击仍编辑卡片', (tester) async {
    final controller = MindMapPaneController();
    final actions = <String>[];
    await _mount(
      tester,
      controller,
      onAction: (_, action) => actions.add(action),
      onCommit: () async => throw StateError('测试保存失败'),
    );
    controller.editTitle('a');
    await tester.pump();
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('map-title-input')),
      '未丢失的草稿',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(controller.titleDraft!.title, '未丢失的草稿');
    expect(find.byKey(const ValueKey('map-title-input')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(controller.titleDraft, isNull);
    final point = tester.getCenter(find.byKey(const ValueKey('map-node-a')));
    await _mouseClick(tester, point, 100);
    await _mouseClick(tester, point, 190);
    expect(actions, ['edit']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('多选和剪贴板：全选仅可见节点，文本输入外路由 Ctrl+C/X/V', (tester) async {
    final controller = MindMapPaneController();
    final selections = <Set<String>>[];
    final clipboard = <String>[];
    await _mount(
      tester,
      controller,
      collapsed: true,
      onSelectionChanged: (ids, primary) => selections.add(ids),
      onClipboardAction: clipboard.add,
    );
    await _click(tester, 'a');
    await _chord(
      tester,
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.keyA,
    );
    expect(selections.single, {'a', 'b'});
    await _chord(
      tester,
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.keyC,
    );
    await _chord(
      tester,
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.keyX,
    );
    await _chord(
      tester,
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.keyV,
    );
    expect(clipboard, ['copy', 'cut', 'paste']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('标题双击只打开标题，迟到提交不污染卸载后的画布', (tester) async {
    final controller = MindMapPaneController();
    final done = Completer<void>();
    await _mount(tester, controller, onCommit: () => done.future);
    final rect = tester.getRect(find.byKey(const ValueKey('map-node-a')));
    final titlePoint = rect.topLeft + const Offset(50, 18);
    await _mouseClick(tester, titlePoint, 100);
    await _mouseClick(tester, titlePoint, 190);
    await tester.pump();
    expect(find.byKey(const ValueKey('map-title-input')), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('map-title-input')),
      '迟到草稿',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    final captured = controller.titleDraft!;
    await tester.pumpWidget(const SizedBox());
    done.complete();
    controller.acceptTitle(captured);
    await tester.pump();
    expect(controller.titleDraft, isNull);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _mount(
  WidgetTester tester,
  MindMapPaneController controller, {
  bool collapsed = false,
  void Function(MapNode, String)? onAction,
  void Function(MapNode)? onSelect,
  void Function(MapNode)? onActivate,
  void Function(Set<String>, String?)? onSelectionChanged,
  void Function(String)? onClipboardAction,
  Future<void> Function()? onCommit,
}) async {
  final snapshot = MapSnapshot(
    map: const MindMap(
      layout: MapLayoutKind.free,
      id: 'map',
      projectId: 'project',
      title: '脑图',
    ),
    nodes: [
      MapNode(
        id: 'a',
        mapId: 'map',
        cardId: 'a',
        x: 0,
        y: 0,
        collapsed: collapsed,
      ),
      const MapNode(id: 'b', mapId: 'map', cardId: 'b', x: 0, y: 200),
      const MapNode(
        id: 'c',
        mapId: 'map',
        cardId: 'c',
        parentNodeId: 'a',
        x: 300,
        y: 0,
      ),
    ],
    cards: {
      for (final id in ['a', 'b', 'c'])
        id: NoteCard(
          id: id,
          projectId: 'project',
          title: '主题 $id',
          excerptSnapshot: '原文',
          body: '正文',
          note: '',
          color: '#F7D976',
        ),
    },
    anchors: const {},
    edges: const [],
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: openNoteTheme(),
      home: Scaffold(
        body: MindMapPane(
          snapshot: snapshot,
          controller: controller,
          onSelect: onSelect ?? (_) {},
          onActivate: onActivate,
          onAction: onAction ?? (_, _) {},
          onMove: (_, _, _) async {},
          onReparent: (_, _) async {},
          onAssociate: (_, _) async {},
          onRemoveAssociation: (_) {},
          onToggleCollapsed: (_) {},
          onCommitTitle: onCommit,
          onClipboardAction: onClipboardAction,
          onSelectionChanged: onSelectionChanged,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  controller.setView(scale: 1, worldTopLeft: const Offset(-80, -80));
  await tester.pump();
}

Future<void> _click(WidgetTester tester, String id) async {
  await tester.tap(find.byKey(ValueKey('map-node-$id')));
  await tester.pump();
}

Future<void> _chord(
  WidgetTester tester,
  LogicalKeyboardKey modifier,
  LogicalKeyboardKey key,
) async {
  await tester.sendKeyDownEvent(modifier);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(modifier);
  await tester.pump();
}

Future<void> _mouseClick(WidgetTester tester, Offset point, int time) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.down(point, timeStamp: Duration(milliseconds: time));
  await gesture.up(timeStamp: Duration(milliseconds: time + 10));
}
