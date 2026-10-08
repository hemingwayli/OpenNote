import '../support/flutter_sdk.dart';

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opennote/domain/models.dart';
import 'package:opennote/ui/map/mind_map_pane.dart';
import 'package:opennote/ui/map/summary_style_dialog.dart';
import 'package:opennote/ui/theme/open_note_theme.dart';

void main() {
  testWidgets('光标反馈：概要范围手柄采用分支方向，混合布局不沿用全图方向', (tester) async {
    final h = await mount(tester);
    await tester.tap(find.byKey(const Key('map-node-s')));
    await tester.pumpAndSettle();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(1, 1));
    final handle = find.byKey(const Key('summary-handle-summary-end'));
    await mouse.moveTo(tester.getCenter(handle));
    await tester.pump();
    expect(
      tester.binding.mouseTracker.debugDeviceActiveCursor(1),
      SystemMouseCursors.resizeUpDown,
    );
    final old = h.snapshot;
    h.setSnapshot(
      MapSnapshot(
        map: old.map,
        nodes: [
          for (final n in old.nodes)
            if (n.id == 'root')
              MapNode(
                id: n.id,
                mapId: n.mapId,
                cardId: n.cardId,
                x: n.x,
                y: n.y,
                branchLayout: MapLayoutKind.down,
              )
            else
              n,
        ],
        cards: old.cards,
        anchors: old.anchors,
        edges: old.edges,
        summaries: old.summaries,
      ),
    );
    await tester.pump();
    h.controller.fitAll();
    await tester.pump();
    await mouse.moveTo(tester.getCenter(handle));
    await tester.pump();
    expect(
      tester.binding.mouseTracker.debugDeviceActiveCursor(1),
      SystemMouseCursors.resizeLeftRight,
    );
    await mouse.removePointer();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Ctrl+Shift+S 创建概要并编辑标题；Tab 使用普通子主题命令', (tester) async {
    final h = await mount(tester, exists: false);
    await tester.tap(find.byKey(const Key('map-node-a')));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(h.created, [
      {'a'},
    ]);
    expect(find.byKey(const Key('map-title-editor')), findsOneWidget);
    final field = find.descendant(
      of: find.byKey(const Key('map-title-editor')),
      matching: find.byType(TextField),
    );
    await tester.enterText(field, '中文概要');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(h.titles, ['中文概要']);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(h.actions, ['s:newChild']);
  });
  testWidgets('概要范围拖动仅松开后提交一次，Esc 和 pointer cancel 不提交', (tester) async {
    final h = await mount(tester);
    await tester.tap(find.byKey(const Key('map-node-s')));
    await tester.pumpAndSettle();
    final handle = find.byKey(const Key('summary-handle-summary-end'));
    final target = tester.getCenter(find.byKey(const Key('map-node-c')));
    var gesture = await tester.startGesture(
      tester.getCenter(handle),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveTo(target);
    await tester.pump();
    expect(h.ranges, isEmpty);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(h.ranges, [
      ['a', 'b', 'c'],
    ]);
    gesture = await tester.startGesture(
      tester.getCenter(handle),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(0, -100));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(h.ranges, hasLength(1));
    await tester.tap(find.byKey(const Key('map-node-s')));
    await tester.pumpAndSettle();
    gesture = await tester.startGesture(
      tester.getCenter(handle),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(0, -100));
    await tester.pump();
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(h.ranges, hasLength(1));
  });
  testWidgets('保存失败保留范围，样式入口和去除括号保留主题', (tester) async {
    final h = await mount(tester);
    h.fail = true;
    await tester.tap(find.byKey(const Key('map-node-s')));
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('summary-handle-summary-end'))),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveTo(tester.getCenter(find.byKey(const Key('map-node-c'))));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(h.ranges, isEmpty);
    expect(h.snapshot.summaries.single.nodeIds, ['a', 'b']);
    expect(tester.takeException(), isNull);
    h.fail = false;
    await tester.tap(find.byTooltip('概要样式与范围'));
    await tester.pumpAndSettle();
    expect(h.styles, 1);
    await tester.tap(find.byTooltip('移除概要括号（保留主题）'));
    await tester.pumpAndSettle();
    expect(h.snapshot.summaries, isEmpty);
    expect(find.byKey(const Key('map-node-s')), findsOneWidget);
  });
  testWidgets('范围拖动中切图取消旧手势，迟到鼠标松开不保存或抛异常', (tester) async {
    final h = await mount(tester);
    await tester.tap(find.byKey(const Key('map-node-s')));
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('summary-handle-summary-end'))),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveTo(tester.getCenter(find.byKey(const Key('map-node-c'))));
    await tester.pump();
    h.changeMap();
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(h.ranges, isEmpty);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('summary-handle-summary-end')), findsNothing);
  });
  testWidgets('完整概要范围拖动时主题和子主题同步预览，多选一次保存全部位置', (tester) async {
    final h = await mount(tester);
    h.replace(
      const MapSummary(
        id: 'summary',
        mapId: 'map',
        summaryNodeId: 's',
        parentNodeId: 'root',
        nodeIds: ['a'],
      ),
    );
    await tester.pumpAndSettle();
    Offset position(String id) =>
        tester.getTopLeft(find.byKey(Key('map-node-$id')));
    final before = {
      for (final id in ['a', 's', 'child']) id: position(id),
    };
    var gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('map-node-a'))),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(0, 25));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 30));
    await tester.pump();
    final delta = position('a') - before['a']!;
    expect(delta.dy, greaterThan(20));
    for (final id in ['s', 'child']) {
      expect(position(id) - before[id]!, delta);
    }
    expect(h.moves, isEmpty);
    await gesture.cancel();
    await tester.pumpAndSettle();
    for (final id in before.keys) {
      expect(position(id), before[id]);
    }

    h.replace(fixture().summaries.single);
    // 多选落点保存属于自由分支；自动分支在空白松手应归位，不能要求写入坐标。
    final groupSnapshot = h.snapshot;
    h.setSnapshot(
      MapSnapshot(
        map: groupSnapshot.map,
        nodes: [
          for (final n in groupSnapshot.nodes)
            if (n.id == 'root')
              MapNode(
                id: n.id,
                mapId: n.mapId,
                cardId: n.cardId,
                x: n.x,
                y: n.y,
                branchLayout: MapLayoutKind.free,
              )
            else
              n,
        ],
        cards: groupSnapshot.cards,
        anchors: groupSnapshot.anchors,
        edges: groupSnapshot.edges,
        summaries: groupSnapshot.summaries,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('map-node-a')));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(find.byKey(const Key('map-node-b')));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(h.selectedIds, {'a', 'b'});
    final groupBefore = {
      for (final id in ['a', 'b', 's', 'child']) id: position(id),
    };
    gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('map-node-a'))),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(0, 25));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 30));
    await tester.pump();
    final groupDelta = position('a') - groupBefore['a']!;
    expect(groupDelta.dy, greaterThan(20));
    for (final id in ['b', 's', 'child']) {
      expect(position(id) - groupBefore[id]!, groupDelta, reason: id);
    }
    expect(h.groupMoves, isEmpty);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(h.groupMoves, hasLength(1));
    expect(h.groupMoves.single.keys.toSet(), {'a', 'b', 's', 'child'});
    expect(h.moves, isEmpty);
    expect(tester.takeException(), isNull);
  });
  testWidgets('900 宽及文字 1.25 倍样式窗口可滚动、可重置且无溢出', (tester) async {
    tester.view.physicalSize = const Size(900, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final snapshot = fixture();
    await tester.pumpWidget(
      MaterialApp(
        theme: openNoteTheme(),
        builder: (c, child) => MediaQuery(
          data: MediaQuery.of(c)
              .copyWith(textScaler: const TextScaler.linear(1.25)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (c) => TextButton(
              onPressed: () => showDialog<SummaryEditResult>(
                context: c,
                builder: (_) => SummaryStyleDialog(
                  summary: snapshot.summaries.single,
                  snapshot: snapshot,
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('重置样式'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byType(SummaryStyleDialog), findsNothing);
  });
  testWidgets('1920 概要画布代表截图，括号和子主题可见', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      final fonts = FontLoader('Source Han Sans CN');
      fonts.addFont(
        File('assets/fonts/source-han-sans/SourceHanSansCN-Regular.otf')
            .readAsBytes()
            .then((b) => ByteData.sublistView(b)),
      );
      await fonts.load();
      await (FontLoader('Segoe UI')..addFont(
            File('C:/Windows/Fonts/segoeui.ttf')
                .readAsBytes()
                .then((b) => ByteData.sublistView(b)),
          ))
          .load();
      await (FontLoader('MaterialIcons')..addFont(
            File(
              '${flutterSdkPath()}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
            ).readAsBytes().then((b) => ByteData.sublistView(b)),
          ))
          .load();
    });
    final capture = GlobalKey();
    final h = await mount(tester, capture: capture);
    h.controller.fitAll();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('map-node-s')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('summary-handle-summary-start')),
      findsOneWidget,
    );
    await tester.runAsync(() async {
      final image =
          await (capture.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File(
        '.local/verification/xmind-summaries-20261005/summaries-1920.png',
      );
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  });
}

Future<HarnessState> mount(
  WidgetTester tester, {
  bool exists = true,
  GlobalKey? capture,
}) async {
  final key = GlobalKey<HarnessState>();
  await tester.pumpWidget(
    MaterialApp(
      theme: openNoteTheme(),
      home: Scaffold(
        body: RepaintBoundary(
          key: capture,
          child: Harness(key: key, exists: exists),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  key.currentState!.controller.setView(
    scale: 1,
    worldTopLeft: const Offset(-80, -80),
  );
  await tester.pumpAndSettle();
  return key.currentState!;
}

class Harness extends StatefulWidget {
  const Harness({super.key, required this.exists});
  final bool exists;
  @override
  State<Harness> createState() => HarnessState();
}

class HarnessState extends State<Harness> {
  late MapSnapshot snapshot = fixture(exists: widget.exists);
  final controller = MindMapPaneController();
  String? selected;
  Set<String> selectedIds = {};
  final created = <Set<String>>[],
      ranges = <List<String>>[],
      titles = <String>[],
      actions = <String>[];
  var styles = 0;
  final moves = <String>[], groupMoves = <Map<String, PdfPoint>>[];
  bool fail = false;
  void setSnapshot(MapSnapshot value) => setState(() => snapshot = value);
  void replace(MapSummary? summary) => setState(
    () => snapshot = MapSnapshot(
      map: snapshot.map,
      nodes: snapshot.nodes,
      cards: snapshot.cards,
      anchors: snapshot.anchors,
      edges: [],
      summaries: summary == null ? [] : [summary],
    ),
  );
  void changeMap() => setState(() {
    selected = null;
    selectedIds = {};
    snapshot = const MapSnapshot(
      map: MindMap(
        layout: MapLayoutKind.free,
        id: 'new',
        projectId: 'p',
        title: '新图',
      ),
      nodes: [],
      cards: {},
      anchors: {},
      edges: [],
    );
  });
  @override
  Widget build(BuildContext context) => MindMapPane(
    snapshot: snapshot,
    controller: controller,
    selectedNodeId: selected,
    selectedNodeIds: selectedIds,
    onSelect: (n) => setState(() {
      selected = n.id;
      selectedIds = {n.id};
    }),
    onSelectionChanged: (ids, primary) => setState(() {
      selectedIds = Set.of(ids);
      selected = primary;
    }),
    onToggleSelection: (node) => setState(() {
      selectedIds = Set.of(selectedIds);
      if (selectedIds.remove(node.id)) {
        if (selected == node.id) selected = selectedIds.lastOrNull;
      } else {
        selectedIds.add(node.id);
        selected = node.id;
      }
    }),
    onMove: (id, _, _) async => moves.add(id),
    onMoveGroup: (positions) async => groupMoves.add(Map.of(positions)),
    onReparent: (_, _) async {},
    onAssociate: (_, _) async {},
    onRemoveAssociation: (_) {},
    onAction: (n, a) => actions.add('${n.id}:$a'),
    onToggleCollapsed: (_) {},
    onCreateSummaries: (ids) async {
      created.add(Set.of(ids));
      setState(() => snapshot = fixture());
      return ['s'];
    },
    onCommitTitle: () async {
      final draft = controller.titleDraft!;
      titles.add(draft.title);
      controller.acceptTitle(draft);
    },
    onEditSummary: (s) async {
      styles++;
    },
    onChangeSummaryRange: (s, ids) async {
      if (fail) throw StateError('保存失败');
      ranges.add(List.of(ids));
      replace(
        MapSummary(
          id: s.id,
          mapId: s.mapId,
          summaryNodeId: s.summaryNodeId,
          parentNodeId: s.parentNodeId,
          nodeIds: ids,
          style: s.style,
        ),
      );
    },
    onRemoveSummary: (s) async {
      replace(null);
    },
  );
}

MapSnapshot fixture({bool exists = true}) {
  final nodes = [
    const MapNode(
      id: 'root',
      mapId: 'map',
      cardId: 'card-root',
      x: -250,
      y: 170,
    ),
    for (var i = 0; i < 3; i++)
      MapNode(
        id: ['a', 'b', 'c'][i],
        mapId: 'map',
        cardId: 'card-${['a', 'b', 'c'][i]}',
        parentNodeId: 'root',
        x: 40,
        y: i * 170.0,
        sortIndex: i,
      ),
    if (exists)
      const MapNode(
        id: 's',
        mapId: 'map',
        cardId: 'card-s',
        parentNodeId: 'root',
        x: 380,
        y: 85,
      ),
    if (exists)
      const MapNode(
        id: 'child',
        mapId: 'map',
        cardId: 'card-child',
        parentNodeId: 's',
        x: 670,
        y: 85,
      ),
  ];
  final names = {
    'root': '知识主题',
    'a': '概念与方法',
    'b': '证据与论述',
    'c': '应用与实践',
    's': '核心结论',
    'child': '继续深入思考',
  };
  return MapSnapshot(
    map: const MindMap(
      id: 'map',
      projectId: 'p',
      title: '概要示例',
      layout: MapLayoutKind.right,
    ),
    nodes: nodes,
    cards: {
      for (final n in nodes)
        n.cardId: NoteCard(
          id: n.cardId,
          projectId: 'p',
          title: names[n.id]!,
          excerptSnapshot: '',
          body: '将知识整理成清晰的主题与概要',
          note: '',
          color: '#DCE6F6',
        ),
    },
    anchors: {},
    edges: [],
    summaries: exists
        ? [
            const MapSummary(
              id: 'summary',
              mapId: 'map',
              summaryNodeId: 's',
              parentNodeId: 'root',
              nodeIds: ['a', 'b'],
            ),
          ]
        : [],
  );
}
