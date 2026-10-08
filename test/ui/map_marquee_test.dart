import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opennote/domain/models.dart';
import 'package:opennote/ui/map/mind_map_pane.dart';

import '../support/map_context_menu.dart';

void main() {
  testWidgets('缩放后的框选命中可见节点，逐帧预览只在抬起提交一次且不移动画布', (tester) async {
    final graph = MindMapPaneController();
    final selections = <Set<String>>[];
    final activated = <String>[];
    final moves = <String>[];
    await _mount(tester, graph, selections, activated, moves);
    graph.setView(scale: .75);
    await tester.pump();
    final before = tester.getTopLeft(_node('a'));
    await mapCanvasToolAction(tester, 'tool:marquee');
    await tester.pump();
    final gesture = await tester.startGesture(
      const Offset(6, 30),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveTo(const Offset(120, 120));
    await tester.pump();
    await gesture.moveTo(const Offset(255, 325));
    await tester.pump();
    expect(find.byKey(const ValueKey('map-selection-box')), findsOneWidget);
    expect(selections, isEmpty);
    expect(_selected(tester, 'a'), isTrue);
    expect(_selected(tester, 'b'), isTrue);
    expect(_selected(tester, 'c'), isFalse);
    expect(_selected(tester, 'd'), isFalse);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(selections, [
      {'a', 'b'},
    ]);
    expect(tester.getTopLeft(_node('a')), before);
    expect(find.byKey(const ValueKey('map-selection-box')), findsNothing);
    expect(activated, isEmpty);
    expect(moves, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Shift框选捕获追加意图，Esc和指针取消恢复原选择且不提交', (tester) async {
    final graph = MindMapPaneController();
    final selections = <Set<String>>[];
    final activated = <String>[];
    final moves = <String>[];
    await _mount(tester, graph, selections, activated, moves, selected: {'c'});
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    final gesture = await tester.startGesture(
      const Offset(330, 420),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveTo(const Offset(100, 100));
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(_selected(tester, 'a'), isTrue);
    expect(_selected(tester, 'b'), isTrue);
    expect(_selected(tester, 'c'), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(_selected(tester, 'a'), isFalse);
    expect(_selected(tester, 'b'), isFalse);
    expect(_selected(tester, 'c'), isTrue);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(selections, isEmpty);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    final cancel = await tester.startGesture(
      const Offset(6, 40),
      kind: PointerDeviceKind.mouse,
    );
    await cancel.moveTo(const Offset(330, 420));
    await tester.pump();
    await cancel.cancel();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(selections, isEmpty);
    expect(_selected(tester, 'c'), isTrue);
    expect(_selected(tester, 'a'), isFalse);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    final add = await tester.startGesture(
      const Offset(6, 40),
      kind: PointerDeviceKind.mouse,
    );
    await add.moveTo(const Offset(330, 420));
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await add.up();
    await tester.pumpAndSettle();
    expect(selections, [
      {'a', 'b', 'c'},
    ]);
    expect(activated, isEmpty);
    expect(moves, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('普通空白拖动继续平移，框选排除折叠后代且切图取消旧手势', (tester) async {
    final graph = MindMapPaneController();
    final selections = <Set<String>>[];
    final activated = <String>[];
    final moves = <String>[];
    await _mount(tester, graph, selections, activated, moves);
    final before = tester.getTopLeft(_node('a'));
    final pan = await tester.startGesture(
      const Offset(40, 440),
      kind: PointerDeviceKind.mouse,
    );
    await pan.moveBy(const Offset(60, 30));
    await tester.pump();
    await pan.moveBy(const Offset(40, 20));
    await tester.pump();
    await pan.up();
    await tester.pumpAndSettle();
    expect((tester.getTopLeft(_node('a')) - before).distance, greaterThan(20));
    expect(selections, isEmpty);
    graph.setView(scale: 1);
    await tester.pump();
    await mapCanvasToolAction(tester, 'tool:marquee');
    await tester.pump();
    final drag = await tester.startGesture(
      const Offset(6, 40),
      kind: PointerDeviceKind.mouse,
    );
    await drag.moveTo(const Offset(790, 420));
    await tester.pump();
    await drag.up();
    await tester.pumpAndSettle();
    expect(selections, [
      {'a', 'b', 'c', 'd'},
    ]);
    expect(find.byKey(const ValueKey('map-node-hidden')), findsNothing);
    selections.clear();
    final old = await tester.startGesture(
      const Offset(40, 440),
      kind: PointerDeviceKind.mouse,
    );
    await old.moveTo(const Offset(700, 40));
    await tester.pump();
    await _mount(tester, graph, selections, activated, moves, mapId: 'new-map');
    await old.up();
    await tester.pumpAndSettle();
    expect(selections, isEmpty);
    expect(find.byKey(const ValueKey('map-selection-box')), findsNothing);
    expect(activated, isEmpty);
    expect(moves, isEmpty);
    expect(tester.takeException(), isNull);
  });
}

Finder _node(String id) => find.byKey(ValueKey('map-node-$id'));
bool _selected(WidgetTester tester, String id) =>
    tester
        .widget<Semantics>(
          find
              .descendant(of: _node(id), matching: find.byType(Semantics))
              .first,
        )
        .properties
        .selected ??
    false;

Future<void> _mount(
  WidgetTester tester,
  MindMapPaneController controller,
  List<Set<String>> selections,
  List<String> activated,
  List<String> moves, {
  Set<String> selected = const {},
  String mapId = 'map',
}) async {
  final nodes = [
    MapNode(id: 'a', mapId: mapId, cardId: 'a', x: 0, y: 0),
    MapNode(id: 'b', mapId: mapId, cardId: 'b', x: 0, y: 200),
    MapNode(id: 'c', mapId: mapId, cardId: 'c', x: 300, y: 0),
    MapNode(
      id: 'd',
      mapId: mapId,
      cardId: 'd',
      x: 540,
      y: 200,
      collapsed: true,
    ),
    MapNode(
      id: 'hidden',
      mapId: mapId,
      cardId: 'hidden',
      x: 540,
      y: 0,
      parentNodeId: 'd',
    ),
  ];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: MindMapPane(
          snapshot: MapSnapshot(
            map: MindMap(
              layout: MapLayoutKind.free,
              id: mapId,
              projectId: 'project',
              title: '框选',
            ),
            nodes: nodes,
            cards: {
              for (final n in nodes)
                n.cardId: NoteCard(
                  id: n.cardId,
                  projectId: 'project',
                  title: n.id,
                  excerptSnapshot: '',
                  body: '',
                  note: '',
                  color: '#F7D976',
                ),
            },
            anchors: const {},
            edges: const [],
          ),
          controller: controller,
          selectedNodeId: selected.lastOrNull,
          selectedNodeIds: selected,
          onSelect: (_) {},
          onActivate: (node) => activated.add(node.id),
          onSelectionChanged: (ids, _) => selections.add(ids),
          onMove: (id, _, _) async => moves.add(id),
          onReparent: (_, _) async {},
          onAssociate: (_, _) async {},
          onRemoveAssociation: (_) {},
          onAction: (_, _) {},
          onToggleCollapsed: (_) {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  controller.setView(scale: 1);
  await tester.pump();
}
