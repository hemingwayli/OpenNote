import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opennote/domain/models.dart';
import 'package:opennote/domain/topic_drop.dart';
import 'package:opennote/ui/map/branch_structure_dialog.dart';
import 'package:opennote/ui/map/mind_map_pane.dart';
import 'package:opennote/ui/map/map_outline_pane.dart';
import 'package:opennote/ui/theme/open_note_theme.dart';

MapSnapshot fixture({
  MapLayoutKind? branch,
  MapLayoutKind kind = MapLayoutKind.right,
}) => MapSnapshot(
  map: MindMap(id: 'm', projectId: 'p', title: '混合结构', layout: kind),
  nodes: [
    // 自动结构的根主题拖动用于平移画布；节点拖放用例必须使用真正的子主题。
    const MapNode(
      id: 'source',
      mapId: 'm',
      cardId: 'source',
      parentNodeId: 'root',
      x: 50,
      y: 100,
    ),
    const MapNode(
      id: 'root',
      mapId: 'm',
      cardId: 'root',
      x: 0,
      y: 0,
      height: 100,
    ),
    MapNode(
      id: 'target',
      mapId: 'm',
      cardId: 'target',
      parentNodeId: 'root',
      x: 450,
      y: 300,
      branchLayout: branch,
    ),
  ],
  cards: {
    for (final id in ['source', 'root', 'target'])
      id: NoteCard(
        id: id,
        projectId: 'p',
        title: id,
        excerptSnapshot: '',
        body: '',
        note: '',
        color: '#F7D976',
      ),
  },
  anchors: const {},
  edges: const [],
);

void main() {
  testWidgets('自动排布确认及撤销先于拖放回调结束时，权威坐标立即接管预览', (tester) async {
    tester.view.physicalSize = const Size(1000, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = MindMapPaneController(), done = Completer<void>();
    var snapshot = fixture();
    late StateSetter refresh;
    await tester.pumpWidget(
      MaterialApp(
        theme: openNoteTheme(),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (_, state) {
              refresh = state;
              return MindMapPane(
                snapshot: snapshot,
                controller: controller,
                selectedNodeId: 'source',
                onSelect: (_) {},
                onMove: (_, _, _) async {},
                onReparent: (_, _) async {},
                onAssociate: (_, _) async {},
                onRemoveAssociation: (_) {},
                onAction: (_, _) {},
                onToggleCollapsed: (_) {},
                onDropTopic: (_, _, _, _) => done.future,
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    controller.setView(scale: 1, worldTopLeft: Offset.zero);
    await tester.pumpAndSettle();
    final source = find.byKey(const ValueKey('map-node-source')),
        target = find.byKey(const ValueKey('map-node-target'));
    final original = tester.getTopLeft(source),
        destination = tester.getRect(target).topCenter + const Offset(0, 8);
    final g = await tester.startGesture(
      tester.getCenter(source),
      kind: PointerDeviceKind.mouse,
    );
    await g.moveBy(const Offset(25, 0));
    await tester.pump();
    await g.moveTo(destination);
    await tester.pump();
    await g.up();
    await tester.pump();
    MapSnapshot moved() => MapSnapshot(
      map: snapshot.map,
      nodes: [
        const MapNode(
          id: 'source',
          mapId: 'm',
          cardId: 'source',
          x: 100,
          y: 200,
          sortIndex: 0,
        ),
        snapshot.nodes.last,
      ],
      cards: snapshot.cards,
      anchors: snapshot.anchors,
      edges: snapshot.edges,
    );
    refresh(() => snapshot = moved());
    await tester.pump();
    expect(
      tester.getTopLeft(source),
      original + const Offset(50, 100),
      reason: '排布坐标不必与鼠标预览一致',
    );
    refresh(() => snapshot = fixture());
    await tester.pump();
    expect(tester.getTopLeft(source), original, reason: '回调尚未结束，撤销仍立即接管旧预览');
    done.complete();
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(source), original);
    expect(tester.takeException(), isNull);
  });
  testWidgets('混合方向键按画布位置浏览父子，折叠向前先展开而不跳过主题', (tester) async {
    final nodes = [
      const MapNode(id: 'r', mapId: 'm', cardId: 'r', x: 60, y: 100),
      const MapNode(
        id: 'a',
        mapId: 'm',
        cardId: 'a',
        parentNodeId: 'r',
        x: 380,
        y: 100,
        branchLayout: MapLayoutKind.down,
      ),
      const MapNode(
        id: 'b',
        mapId: 'm',
        cardId: 'b',
        parentNodeId: 'a',
        x: 380,
        y: 320,
      ),
    ];
    MapSnapshot snapshot(bool folded) => MapSnapshot(
      map: const MindMap(
        id: 'm',
        projectId: 'p',
        title: '方向',
        layout: MapLayoutKind.right,
      ),
      nodes: [
        nodes.first,
        folded
            ? MapNode(
                id: 'a',
                mapId: 'm',
                cardId: 'a',
                parentNodeId: 'r',
                x: 380,
                y: 100,
                branchLayout: MapLayoutKind.down,
                collapsed: true,
              )
            : nodes[1],
        nodes.last,
        if (folded)
          const MapNode(id: 'other', mapId: 'm', cardId: 'r', x: 380, y: 360),
      ],
      cards: {
        for (final id in ['r', 'a', 'b'])
          id: NoteCard(
            id: id,
            projectId: 'p',
            title: id,
            excerptSnapshot: '',
            body: '',
            note: '',
            color: '#F7D976',
          ),
      },
      anchors: const {},
      edges: const [],
    );
    final controller = MindMapPaneController(),
        selected = <String>[],
        expanded = <String>[];
    Widget host(bool folded) => MaterialApp(
      theme: openNoteTheme(),
      home: Scaffold(
        body: MindMapPane(
          snapshot: snapshot(folded),
          controller: controller,
          selectedNodeId: folded ? 'a' : 'r',
          onSelect: (node) => selected.add(node.id),
          onMove: (_, _, _) async {},
          onReparent: (_, _) async {},
          onAssociate: (_, _) async {},
          onRemoveAssociation: (_) {},
          onAction: (_, _) {},
          onToggleCollapsed: expanded.add,
        ),
      ),
    );
    await tester.pumpWidget(host(false));
    await tester.pumpAndSettle();
    controller.setView(scale: 1, worldTopLeft: Offset.zero);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('map-node-r')));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(selected.last, 'a');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(selected.last, 'b');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(selected.last, 'a');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(selected.last, 'r');
    await tester.pumpWidget(host(true));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('map-node-a')));
    await tester.pump();
    final count = selected.length;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(expanded, ['a']);
    expect(selected.length, count);
    expect(tester.takeException(), isNull);
  });
  testWidgets('大纲分支结构菜单保持精确多选，菜单操作不激活卡片', (tester) async {
    final actions = <String>[], selections = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: openNoteTheme(),
        home: Scaffold(
          body: MapOutlinePane(
            snapshot: fixture(),
            selectedNodeId: 'source',
            selectedNodeIds: const {'source', 'target'},
            onSelect: (node) => selections.add(node.id),
            onAction: (_, action) => actions.add(action),
            onToggleCollapsed: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final menu = find.byKey(const ValueKey('outline-menu-target'));
    await tester.tap(menu);
    await tester.pumpAndSettle();
    await tester.tap(find.text('分支结构…'));
    await tester.pumpAndSettle();
    expect(actions, ['branchStructure']);
    expect(selections, isEmpty);
    expect(tester.takeException(), isNull);
  });
  testWidgets('900 宽和 1.25 倍文字下分支结构选择、重置后代和取消可用', (tester) async {
    tester.view.physicalSize = const Size(900, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    BranchStructureResult? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: openNoteTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.25)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              child: const Text('打开'),
              onPressed: () async {
                result = await showDialog<BranchStructureResult>(
                  context: context,
                  builder: (_) => const BranchStructureDialog(
                    kind: null,
                    selectionCount: 3,
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('branch-structure-choice')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(MapLayoutKind.down.label).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('同时重置内层分支结构'));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(result!.kind, MapLayoutKind.down);
    expect(result!.resetDescendants, isTrue);
    result = null;
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(tester.takeException(), isNull);
  });

  for (final placement in TopicDropPlacement.values) {
    testWidgets('鼠标拖放 ${placement.name} 显示对应提示，松开一次提交且外部工具栏位置稳定', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1000, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = MindMapPaneController(), drops = <TopicDropTarget>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: openNoteTheme(),
          home: Scaffold(
            body: Column(
              children: [
                const SizedBox(height: 52, child: Center(child: Text('稳定工具栏'))),
                Expanded(
                  child: MindMapPane(
                    snapshot: fixture(),
                    controller: controller,
                    selectedNodeId: 'source',
                    onSelect: (_) {},
                    onMove: (_, _, _) async {},
                    onReparent: (_, _) async {},
                    onAssociate: (_, _) async {},
                    onRemoveAssociation: (_) {},
                    onAction: (_, _) {},
                    onToggleCollapsed: (_) {},
                    onDropTopic: (source, target, x, y) async {
                      drops.add(target);
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      controller.setView(scale: 1, worldTopLeft: Offset.zero);
      await tester.pumpAndSettle();
      final tools = tester.getRect(find.text('稳定工具栏'));
      final source = find.byKey(const ValueKey('map-node-source')),
          target = find.byKey(const ValueKey('map-node-target'));
      final rect = tester.getRect(target);
      final point = Offset(rect.center.dx, switch (placement) {
        TopicDropPlacement.before => rect.top + 10,
        TopicDropPlacement.after => rect.bottom - 10,
        _ => rect.center.dy,
      });
      final gesture = await tester.startGesture(
        tester.getCenter(source),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(25, 0));
      await tester.pump();
      await gesture.moveTo(point);
      await tester.pump();
      expect(
        find.text(TopicDropTarget(fixture().nodes.last, placement).label),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('map-drop-insertion')),
        placement == TopicDropPlacement.child ? findsNothing : findsOneWidget,
      );
      expect(tester.getRect(find.text('稳定工具栏')), tools);
      expect(drops, isEmpty);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(drops.single.placement, placement);
      expect(drops.single.anchor.id, 'target');
      expect(tester.getRect(find.text('稳定工具栏')), tools);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('Esc 或拖放目标结构刷新取消预览，不提交旧的操作', (tester) async {
    tester.view.physicalSize = const Size(1000, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = MindMapPaneController();
    var drops = 0;
    MapLayoutKind? branch;
    late StateSetter refresh;
    await tester.pumpWidget(
      MaterialApp(
        theme: openNoteTheme(),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (_, state) {
              refresh = state;
              return MindMapPane(
                snapshot: fixture(branch: branch),
                controller: controller,
                selectedNodeId: 'source',
                onSelect: (_) {},
                onMove: (_, _, _) async {},
                onReparent: (_, _) async {},
                onAssociate: (_, _) async {},
                onRemoveAssociation: (_) {},
                onAction: (_, _) {},
                onToggleCollapsed: (_) {},
                onDropTopic: (source, target, x, y) async {
                  drops++;
                },
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    controller.setView(scale: 1, worldTopLeft: Offset.zero);
    await tester.pumpAndSettle();
    Future<TestGesture> drag() async {
      final g = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('map-node-source'))),
        kind: PointerDeviceKind.mouse,
      );
      await g.moveBy(const Offset(25, 0));
      await tester.pump();
      await g.moveTo(
        tester.getCenter(find.byKey(const ValueKey('map-node-target'))),
      );
      await tester.pump();
      return g;
    }

    var g = await drag();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await g.up();
    await tester.pumpAndSettle();
    expect(drops, 0);
    expect(find.text('加入子主题'), findsNothing);
    g = await drag();
    refresh(() => branch = MapLayoutKind.down);
    await tester.pump();
    await g.up();
    await tester.pumpAndSettle();
    expect(drops, 0);
    expect(tester.takeException(), isNull);
  });
}
