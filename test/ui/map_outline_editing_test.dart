import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opennote/domain/models.dart';
import 'package:opennote/ui/map/map_outline_pane.dart';

void main() {
  testWidgets('大纲待编辑请求等待可操作状态，多选标题不丢组且身份替换取消旧草稿', (tester) async {
    final controller = MapOutlinePaneController();
    Widget host(MapSnapshot snapshot, {bool canCreate = true}) => MaterialApp(
      home: Scaffold(
        body: MapOutlinePane(
          snapshot: snapshot,
          controller: controller,
          canCreate: canCreate,
          selectedNodeId: 'a',
          selectedNodeIds: const {'a', 'b'},
          onSelect: (_) {},
          onAction: (_, _) {},
          onToggleCollapsed: (_) {},
          onCommitTitle: () async =>
              controller.acceptTitle(controller.titleDraft!),
        ),
      ),
    );
    final original = _snapshot();
    await tester.pumpWidget(host(original, canCreate: false));
    controller.editTitle('a');
    await tester.pumpAndSettle();
    expect(controller.titleDraft, isNull);
    await tester.pumpWidget(host(original));
    await tester.pumpAndSettle();
    expect(controller.titleDraft!.cardId, 'card-a');
    expect(
      tester
          .widget<Semantics>(find.byKey(const ValueKey('outline-node-b')))
          .properties
          .selected,
      isTrue,
    );
    final field = find.byKey(const ValueKey('outline-title-input'));
    await tester.enterText(field, '旧身份草稿');
    final captured = controller.titleDraft!;
    final replacement = MapSnapshot(
      map: original.map,
      nodes: [
        for (final n in original.nodes)
          if (n.id == 'a')
            MapNode(
              id: n.id,
              mapId: n.mapId,
              cardId: 'replacement',
              x: n.x,
              y: n.y,
            )
          else
            n,
      ],
      cards: {
        ...original.cards,
        'replacement': const NoteCard(
          id: 'replacement',
          projectId: 'project',
          title: '新身份标题',
          excerptSnapshot: '',
          body: '',
          note: '',
          color: '#F7D976',
        ),
      },
      anchors: original.anchors,
      edges: original.edges,
    );
    await tester.pumpWidget(host(replacement));
    await tester.pumpAndSettle();
    expect(controller.titleDraft, isNull);
    controller.editTitle('a');
    await tester.pumpAndSettle();
    controller.acceptTitle(captured);
    expect(controller.titleDraft!.cardId, 'replacement');
    expect(controller.titleDraft!.title, '新身份标题');
    expect(field, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('大纲键盘导航按可见行浏览，Shift范围可收缩且不触发PDF回源', (tester) async {
    final selections = <(Set<String>, String?)>[];
    final activations = <String>[];
    final actions = <(String, String)>[];
    final collapses = <String>[];
    await tester.pumpWidget(
      _host(
        _snapshot(),
        onSelectionChanged: (ids, primary) => selections.add((ids, primary)),
        onActivate: (node) => activations.add(node.id),
        onAction: (node, action) => actions.add((node.id, action)),
        onToggleCollapsed: collapses.add,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('outline-node-a')));
    await tester.pumpAndSettle();
    activations.clear();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    expect(selections.last.$1, {'a', 'b', 'c'});
    expect(selections.last.$2, 'c');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    expect(selections.last.$1, {'a', 'b'});
    expect(selections.last.$2, 'b');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    expect(collapses, ['a']);
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    expect(collapses, ['a', 'd']);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(selections.last.$1, {'a', 'b', 'c', 'd'});
    expect(selections.last.$1.contains('hidden'), isFalse);
    expect(activations, isEmpty);
    expect(actions, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('大纲结构与剪贴板快捷键沿用原子命令，文本输入保留原生快捷键', (tester) async {
    final controller = MapOutlinePaneController();
    final actions = <String>[];
    final clipboard = <String>[];
    final titles = <String>[];
    await tester.pumpWidget(
      _host(
        _snapshot(),
        controller: controller,
        onAction: (_, action) => actions.add(action),
        onClipboardAction: clipboard.add,
        onCommitTitle: () async {
          final draft = controller.titleDraft!;
          titles.add(draft.title);
          controller.acceptTitle(draft);
        },
      ),
    );
    await tester.tap(find.byKey(const ValueKey('outline-node-a')));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    for (final key in [
      LogicalKeyboardKey.keyC,
      LogicalKeyboardKey.keyX,
      LogicalKeyboardKey.keyV,
    ]) {
      await tester.sendKeyEvent(key);
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    expect(actions, [
      'newChild',
      'newSibling',
      'newSiblingBefore',
      'newParent',
      'removeTopicOnly',
      'demote',
      'moveBefore',
      'editSelected',
    ]);
    expect(clipboard, ['copy', 'cut', 'paste']);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('outline-title-input'));
    expect(field, findsOneWidget);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '中文组合标题',
        selection: TextSelection.collapsed(offset: 6),
        composing: TextRange(start: 0, end: 6),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(titles, isEmpty);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '中文组合标题',
        selection: TextSelection.collapsed(offset: 6),
      ),
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(clipboard, ['copy', 'cut', 'paste']);
    expect(
      tester.widget<TextField>(field).controller!.selection,
      const TextSelection(baseOffset: 0, extentOffset: 6),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(titles, ['中文组合标题']);
    expect(actions.last, 'newChild');
    expect(field, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('大纲标题保存失败可重试，Esc取消且切图隔离旧完成回调', (tester) async {
    final controller = MapOutlinePaneController();
    var fail = true;
    final delayed = Completer<void>();
    Widget host(MapSnapshot snapshot) => _host(
      snapshot,
      controller: controller,
      onCommitTitle: () async {
        final draft = controller.titleDraft!;
        if (fail) throw StateError('保存失败');
        await delayed.future;
        controller.acceptTitle(draft);
      },
    );
    await tester.pumpWidget(host(_snapshot()));
    controller.editTitle('a');
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('outline-title-input'));
    await tester.enterText(field, '保留失败草稿');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(controller.titleDraft!.title, '保留失败草稿');
    expect(tester.widget<TextField>(field).readOnly, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(controller.titleDraft, isNull);
    fail = false;
    controller.editTitle('a');
    await tester.pumpAndSettle();
    await tester.enterText(field, '旧图待保存');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pumpWidget(host(_snapshot(mapId: 'another')));
    await tester.pump();
    expect(controller.titleDraft, isNull);
    delayed.complete();
    await tester.pumpAndSettle();
    expect(field, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('大纲标题鼠标双击可编辑，单击即时激活且新节点请求等到快照就绪', (tester) async {
    final controller = MapOutlinePaneController();
    final activated = <String>[];
    Widget host(MapSnapshot snapshot) => _host(
      snapshot,
      controller: controller,
      onActivate: (node) => activated.add(node.id),
      onCommitTitle: () async => controller.acceptTitle(controller.titleDraft!),
    );
    await tester.pumpWidget(host(_snapshot()));
    final title = find.byKey(const ValueKey('outline-title-a'));
    final first = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await first.down(
      tester.getCenter(title),
      timeStamp: const Duration(seconds: 1),
    );
    await first.up(timeStamp: const Duration(milliseconds: 1020));
    await tester.pump(const Duration(milliseconds: 150));
    expect(activated, ['a']);
    final second = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await second.down(
      tester.getCenter(title),
      timeStamp: const Duration(milliseconds: 1170),
    );
    await second.up(timeStamp: const Duration(milliseconds: 1190));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('outline-title-input')), findsOneWidget);
    expect(activated, ['a']);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    controller.editTitle('new');
    await tester.pump();
    expect(controller.titleDraft, isNull);
    await tester.pumpWidget(host(_snapshot(extra: true)));
    await tester.pumpAndSettle();
    expect(controller.titleDraft!.nodeId, 'new');
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('outline-title-input')))
          .focusNode!
          .hasFocus,
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });
}

Widget _host(
  MapSnapshot snapshot, {
  MapOutlinePaneController? controller,
  void Function(MapNode)? onActivate,
  void Function(MapNode, String)? onAction,
  void Function(Set<String>, String?)? onSelectionChanged,
  void Function(String)? onToggleCollapsed,
  void Function(String)? onClipboardAction,
  Future<void> Function()? onCommitTitle,
}) => MaterialApp(
  home: Scaffold(
    body: SizedBox(
      width: 380,
      height: 420,
      child: MapOutlinePane(
        snapshot: snapshot,
        controller: controller,
        selectedNodeId: 'a',
        selectedNodeIds: const {'a'},
        onSelect: (_) {},
        onActivate: onActivate,
        onAction: onAction ?? (_, _) {},
        onSelectionChanged: onSelectionChanged,
        onToggleCollapsed: onToggleCollapsed ?? (_) {},
        onClipboardAction: onClipboardAction,
        onCommitTitle: onCommitTitle,
      ),
    ),
  ),
);

MapSnapshot _snapshot({String mapId = 'map', bool extra = false}) {
  MapNode node(String id, double y, {String? parent, bool collapsed = false}) =>
      MapNode(
        id: id,
        mapId: mapId,
        cardId: 'card-$id',
        x: 0,
        y: y,
        parentNodeId: parent,
        collapsed: collapsed,
      );
  final nodes = [
    node('a', 0),
    node('b', 40, parent: 'a'),
    node('c', 80),
    node('d', 120, collapsed: true),
    node('hidden', 160, parent: 'd'),
    if (extra) node('new', 200),
  ];
  return MapSnapshot(
    map: MindMap(
      layout: MapLayoutKind.free,
      id: mapId,
      projectId: 'project',
      title: '键盘大纲',
    ),
    nodes: nodes,
    cards: {
      for (final n in nodes)
        n.cardId: NoteCard(
          id: n.cardId,
          projectId: 'project',
          title: '标题-${n.id}',
          excerptSnapshot: '',
          body: '正文',
          note: '',
          color: '#F7D976',
        ),
    },
    anchors: const {},
    edges: const [],
  );
}
