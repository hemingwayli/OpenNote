import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opennote/domain/map_layout.dart';
import 'package:opennote/domain/models.dart';
import 'package:opennote/ui/map/map_outline_pane.dart';
import 'package:opennote/ui/map/mind_map_pane.dart';
import 'package:opennote/ui/theme/open_note_theme.dart';

void main() {
  for (final kind in [MapLayoutKind.left, MapLayoutKind.up]) {
    testWidgets('已提交视口 ${kind.name}：先按新坐标适配，晚到的快照与负向原点不偏移', (tester) async {
      final controller = MindMapPaneController();
      final selected = <String>[];
      final activated = <String>[];
      await _mount(
        tester,
        MapLayoutKind.right,
        controller,
        selected,
        activated,
      );
      final committed = _snapshot(kind);
      controller.fitAll(snapshot: committed);
      await tester.pumpWidget(
        _host(committed, controller, selected, activated),
      );
      await tester.pumpAndSettle();
      final viewport = tester.getRect(find.byType(InteractiveViewer));
      final rects = [
        for (final node in committed.nodes)
          tester.getRect(find.byKey(ValueKey('map-node-${node.id}'))),
      ];
      final bounds = rects.reduce((a, b) => a.expandToInclude(b));
      expect((bounds.center - viewport.center).distance, lessThan(1));
      expect(
        rects.every(
          (rect) =>
              viewport.contains(rect.topLeft) &&
              viewport.contains(rect.bottomRight),
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
  for (final kind in [
    MapLayoutKind.right,
    MapLayoutKind.left,
    MapLayoutKind.down,
    MapLayoutKind.up,
  ]) {
    testWidgets('结构导航 ${kind.name}：方向键沿实际父子方向，同级使用保存顺序且不回源', (tester) async {
      final controller = MindMapPaneController();
      final selected = <String>[];
      final activated = <String>[];
      await _mount(tester, kind, controller, selected, activated);
      final childKey = switch (kind) {
        MapLayoutKind.left => LogicalKeyboardKey.arrowLeft,
        MapLayoutKind.down => LogicalKeyboardKey.arrowDown,
        MapLayoutKind.up => LogicalKeyboardKey.arrowUp,
        _ => LogicalKeyboardKey.arrowRight,
      };
      final parentKey = switch (kind) {
        MapLayoutKind.left => LogicalKeyboardKey.arrowRight,
        MapLayoutKind.down => LogicalKeyboardKey.arrowUp,
        MapLayoutKind.up => LogicalKeyboardKey.arrowDown,
        _ => LogicalKeyboardKey.arrowLeft,
      };
      await tester.sendKeyEvent(childKey);
      await tester.pump();
      expect(selected.last, 'a');
      await tester.sendKeyEvent(
        kind.vertical
            ? LogicalKeyboardKey.arrowRight
            : LogicalKeyboardKey.arrowDown,
      );
      await tester.pump();
      expect(selected.last, 'b');
      await tester.sendKeyEvent(parentKey);
      await tester.pump();
      expect(selected.last, 'root');
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pump();
      expect(selected.last, 'b');
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.pump();
      expect(selected.last, 'root');
      expect(activated, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('双侧方向键进入指定分支并沿左侧后代导航，左右菜单明确可用', (tester) async {
    final controller = MindMapPaneController();
    final selected = <String>[];
    await _mount(tester, MapLayoutKind.mindMap, controller, selected, []);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(selected.last, 'a');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(selected.last, 'c');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(selected.last, 'root');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(selected.last, 'b');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('大纲按同级顺序排列左向图，不按左右坐标反转；双侧方向菜单存在', (tester) async {
    final snapshot = _snapshot(MapLayoutKind.mindMap);
    await tester.pumpWidget(
      MaterialApp(
        theme: openNoteTheme(),
        home: Scaffold(
          body: MapOutlinePane(
            snapshot: snapshot,
            onSelect: (_) {},
            onAction: (_, _) {},
            onToggleCollapsed: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('outline-title-a'))).dy,
      lessThan(
        tester.getTopLeft(find.byKey(const ValueKey('outline-title-b'))).dy,
      ),
    );
    final menu = find.byKey(const ValueKey('outline-menu-a'));
    expect(menu, findsOneWidget);
    await tester.tap(menu);
    await tester.pumpAndSettle();
    expect(find.text('分支移到左侧'), findsOneWidget);
    expect(find.text('分支移到右侧'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _mount(
  WidgetTester tester,
  MapLayoutKind kind,
  MindMapPaneController controller,
  List<String> selected,
  List<String> activated,
) async {
  await tester.binding.setSurfaceSize(const Size(1200, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    _host(_snapshot(kind), controller, selected, activated),
  );
  await tester.pumpAndSettle();
  controller.fitAll();
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('map-node-root')));
  await tester.pump();
  activated.clear();
}

Widget _host(
  MapSnapshot snapshot,
  MindMapPaneController controller,
  List<String> selected,
  List<String> activated,
) => MaterialApp(
  theme: openNoteTheme(),
  home: Scaffold(
    body: MindMapPane(
      snapshot: snapshot,
      controller: controller,
      selectedNodeId: 'root',
      selectedNodeIds: const {'root'},
      onSelect: (n) => selected.add(n.id),
      onActivate: (n) => activated.add(n.id),
      onToggleCollapsed: (_) {},
      onAction: (_, _) {},
      onClearSelection: () {},
      onMove: (_, _, _) async {},
      onReparent: (_, _) async {},
      onAssociate: (_, _) async {},
      onRemoveAssociation: (_) {},
    ),
  ),
);

MapSnapshot _snapshot(MapLayoutKind kind) {
  final original = [
    const MapNode(
      id: 'root',
      mapId: 'map',
      cardId: 'root',
      x: 400,
      y: 300,
      sortIndex: 0,
    ),
    const MapNode(
      id: 'a',
      mapId: 'map',
      cardId: 'a',
      parentNodeId: 'root',
      x: 1,
      y: 1,
      sortIndex: 0,
      branchSide: -1,
    ),
    const MapNode(
      id: 'b',
      mapId: 'map',
      cardId: 'b',
      parentNodeId: 'root',
      x: 0,
      y: 0,
      sortIndex: 1,
      branchSide: 1,
    ),
    const MapNode(
      id: 'c',
      mapId: 'map',
      cardId: 'c',
      parentNodeId: 'a',
      x: 0,
      y: 0,
      sortIndex: 0,
    ),
  ];
  final plan = calculateMapLayout(original, kind);
  final nodes = [
    for (final n in original)
      MapNode(
        id: n.id,
        mapId: n.mapId,
        cardId: n.cardId,
        parentNodeId: n.parentNodeId,
        x: plan.positions[n.id]!.x,
        y: plan.positions[n.id]!.y,
        sortIndex: n.sortIndex,
        branchSide: n.branchSide,
      ),
  ];
  return MapSnapshot(
    map: MindMap(id: 'map', projectId: 'project', title: '阅读知识', layout: kind),
    nodes: nodes,
    cards: {
      for (final n in nodes)
        n.cardId: NoteCard(
          id: n.cardId,
          projectId: 'project',
          title: '主题-${n.id}',
          excerptSnapshot: '',
          body: '正文内容',
          note: '',
          color: '#F7D976',
        ),
    },
    anchors: const {},
    edges: const [],
  );
}
