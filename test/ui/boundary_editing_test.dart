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
import 'package:opennote/ui/map/boundary_style_dialog.dart';
import 'package:opennote/ui/theme/open_note_theme.dart';

void main() {
  testWidgets('右键菜单：外框编辑与删除保留主题，切图取消旧菜单', (tester) async {
    final harness = await _mount(tester);
    Future<void> open() async {
      final mouse = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('boundary-label-box'))),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await mouse.up();
      await tester.pumpAndSettle();
    }

    await open();
    expect(find.text('编辑外框说明'), findsOneWidget);
    expect(find.text('Space'), findsOneWidget);
    await tester.tap(find.text('编辑外框说明'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('boundary-label-editor')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    final nodes = harness.snapshot.nodes.map((node) => node.id).toList();
    await open();
    await tester.tap(find.text('删除外框（保留主题）'));
    await tester.pumpAndSettle();
    expect(harness.snapshot.boundaries, isEmpty);
    expect(harness.snapshot.nodes.map((node) => node.id), nodes);
    await tester.pumpWidget(const SizedBox());
    final fresh = await _mount(tester);
    await open();
    fresh.changeMap();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('context-menu-main')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('光标反馈：外框说明可点击，范围手柄可二维调整且取消恢复', (tester) async {
    await _mount(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(1, 1));
    final label = find.byKey(const Key('boundary-label-box'));
    await mouse.moveTo(tester.getCenter(label));
    await tester.pump();
    expect(
      tester.binding.mouseTracker.debugDeviceActiveCursor(1),
      SystemMouseCursors.click,
    );
    await _select(tester);
    await tester.pumpAndSettle();
    final handle = find.byKey(const Key('boundary-handle-box-end'));
    await mouse.moveTo(tester.getCenter(handle));
    await tester.pump();
    expect(
      tester.binding.mouseTracker.debugDeviceActiveCursor(1),
      SystemMouseCursors.move,
    );
    await mouse.down(tester.getCenter(handle));
    await mouse.moveBy(const Offset(35, 25));
    await tester.pump();
    expect(
      tester.binding.mouseTracker.debugDeviceActiveCursor(1),
      SystemMouseCursors.move,
    );
    await mouse.cancel();
    await tester.pumpAndSettle();
    await mouse.removePointer();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Ctrl+B 添加外框，删除只移除框而保留主题', (tester) async {
    final harness = await _mount(tester, boundary: false);
    await tester.tap(find.byKey(const Key('map-node-a')));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(harness.created, [
      {'a'},
    ]);
    expect(harness.snapshot.boundaries, hasLength(1));
    expect(find.byKey(const Key('boundary-label-box')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pumpAndSettle();
    expect(harness.snapshot.boundaries, isEmpty);
    expect(harness.snapshot.nodes, hasLength(4));
  });
  testWidgets('外框 Space 文字编辑保护中文组词，Enter 一次保存，Esc 取消', (tester) async {
    final harness = await _mount(tester);
    await _select(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    final field = find.byKey(const Key('boundary-label-editor'));
    expect(field, findsOneWidget);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '中文说明',
        selection: TextSelection.collapsed(offset: 4),
        composing: TextRange(start: 0, end: 4),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(harness.labels, isEmpty);
    expect(harness.controller.boundaryDraft!.label, '中文说明');
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '中文说明',
        selection: TextSelection.collapsed(offset: 4),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(harness.labels, ['中文说明']);
    expect(field, findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    await tester.enterText(field, '取消文字');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(harness.labels, ['中文说明']);
  });
  testWidgets('外框双击及保存失败保留焦点和草稿，切图取消旧身份', (tester) async {
    final harness = await _mount(tester);
    await tester.tap(find.byKey(const Key('boundary-label-box')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const Key('boundary-label-box')));
    await tester.pumpAndSettle();
    final field = find.byKey(const Key('boundary-label-editor'));
    expect(field, findsOneWidget);
    await tester.enterText(field, '失败后保留');
    harness.fail = true;
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(harness.controller.boundaryDraft!.label, '失败后保留');
    expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
    final stale = harness.controller.boundaryDraft!;
    harness.changeMap();
    await tester.pumpAndSettle();
    harness.controller.acceptBoundaryLabel(stale);
    await tester.pump();
    expect(field, findsNothing);
    expect(harness.labels, isEmpty);
  });

  testWidgets('双击外框边线进入文字编辑，不触发空白创建', (tester) async {
    await _mount(tester);
    final node = tester.getRect(find.byKey(const Key('map-node-a')));
    final point = Offset(node.left - 22, node.center.dy);
    await tester.tapAt(point);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(point);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('boundary-label-editor')), findsOneWidget);
  });

  testWidgets('前一草稿准备失败时不启动外框编辑、不抛出未处理异常', (tester) async {
    final harness = await _mount(tester);
    harness.failPrepare = true;
    await _select(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('boundary-label-editor')), findsNothing);
    expect(harness.controller.boundaryDraft, isNull);
    expect(tester.takeException(), isNull);
  });
  testWidgets('范围控制柄预览不保存，松手一次提交，取消和失败回滚', (tester) async {
    final harness = await _mount(tester);
    await _select(tester);
    final end = find.byKey(const Key('boundary-handle-box-end'));
    final start = tester.getCenter(end),
        c = tester.getCenter(find.byKey(const Key('map-node-c')));
    final gesture = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveTo(c);
    await tester.pump();
    expect(harness.ranges, isEmpty);
    expect(tester.getCenter(end), isNot(start));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(harness.ranges, [
      ['a', 'b', 'c'],
    ]);
    final again = await tester.startGesture(
      tester.getCenter(end),
      kind: PointerDeviceKind.mouse,
    );
    await again.moveTo(tester.getCenter(find.byKey(const Key('map-node-a'))));
    await tester.pump();
    await again.cancel();
    await tester.pumpAndSettle();
    expect(harness.ranges, hasLength(1));
    harness.fail = true;
    final failed = await tester.startGesture(
      tester.getCenter(end),
      kind: PointerDeviceKind.mouse,
    );
    await failed.moveTo(tester.getCenter(find.byKey(const Key('map-node-a'))));
    await tester.pump();
    await failed.up();
    await tester.pumpAndSettle();
    expect(harness.ranges, hasLength(1));
    expect(harness.snapshot.boundaries.single.nodeIds, ['a', 'b', 'c']);
  });
  testWidgets('范围拖动期间主题身份变更丢弃旧手势，折叠隐藏整个范围', (tester) async {
    final harness = await _mount(tester);
    await _select(tester);
    final drag = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('boundary-handle-box-end'))),
      kind: PointerDeviceKind.mouse,
    );
    await drag.moveBy(const Offset(0, 30));
    await tester.pump();
    harness.hide();
    await tester.pump();
    await drag.up();
    await tester.pumpAndSettle();
    expect(harness.ranges, isEmpty);
    expect(find.byKey(const Key('boundary-label-box')), findsNothing);
  });
  testWidgets('外框样式 900 宽和 1.25 文字下可滚动，取消不写入，重置保留说明', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 720);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    BoundaryEditResult? result;
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
              onPressed: () async =>
                  result = await showDialog<BoundaryEditResult>(
                    context: context,
                    builder: (_) => BoundaryStyleDialog(
                      boundary: _snapshot().boundaries.single,
                      snapshot: _snapshot(),
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
    await tester.enterText(
      find.byKey(const Key('boundary-description')),
      '保留说明',
    );
    await tester.tap(find.text('重置样式'));
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(result!.label, '保留说明');
    expect(result!.style, const BoundaryStyle());
    result = null;
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });
  testWidgets('外框 1920 代表截图与帧布局检查', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1920, 1080));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      final loader = FontLoader('Source Han Sans CN');
      for (final weight in ['Regular', 'Medium', 'Bold']) {
        loader.addFont(
          File('assets/fonts/source-han-sans/SourceHanSansCN-$weight.otf')
              .readAsBytes()
              .then(ByteData.sublistView),
        );
      }
      await loader.load();
      await (FontLoader('Segoe UI')..addFont(
            File('C:/Windows/Fonts/segoeui.ttf')
                .readAsBytes()
                .then(ByteData.sublistView),
          ))
          .load();
      await (FontLoader('MaterialIcons')..addFont(
            File(
              '${flutterSdkPath()}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
            ).readAsBytes().then(ByteData.sublistView),
          ))
          .load();
    });
    final key = GlobalKey();
    final harness = await _mount(tester, capture: key);
    harness.controller.fitAll();
    await tester.pumpAndSettle();
    await _select(tester);
    await tester.runAsync(() async {
      final image =
          await (key.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary)
              .toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final folder = await Directory(
        '.local/verification/xmind-boundaries-20261005',
      ).create(recursive: true);
      await File('${folder.path}/boundaries-1920.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
    expect(tester.takeException(), isNull);
  });
}

Future<void> _select(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('boundary-label-box')));
  await tester.pump(kDoubleTapTimeout);
  await tester.pump();
}

Future<_HarnessState> _mount(
  WidgetTester tester, {
  bool boundary = true,
  GlobalKey? capture,
}) async {
  final key = GlobalKey<_HarnessState>();
  await tester.pumpWidget(
    MaterialApp(
      theme: openNoteTheme(),
      home: Scaffold(
        body: RepaintBoundary(
          key: capture,
          child: _Harness(key: key, boundary: boundary),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  key.currentState!.controller.setView(
    scale: 1,
    worldTopLeft: const Offset(-100, -80),
  );
  await tester.pumpAndSettle();
  return key.currentState!;
}

class _Harness extends StatefulWidget {
  const _Harness({super.key, required this.boundary});
  final bool boundary;
  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final controller = MindMapPaneController();
  late MapSnapshot snapshot = _snapshot(boundary: widget.boundary);
  bool fail = false;
  bool failPrepare = false;
  final labels = <String>[],
      ranges = <List<String>>[],
      created = <Set<String>>[];
  void replace(MapBoundary? b) => setState(
    () => snapshot = MapSnapshot(
      map: snapshot.map,
      nodes: snapshot.nodes,
      cards: snapshot.cards,
      anchors: snapshot.anchors,
      edges: [],
      boundaries: b == null ? [] : [b],
    ),
  );
  void hide() => setState(() => snapshot = _snapshot(collapsed: true));
  void changeMap() => setState(
    () => snapshot = MapSnapshot(
      map: const MindMap(
        layout: MapLayoutKind.free,
        id: 'new',
        projectId: 'p',
        title: '新图',
      ),
      nodes: [],
      cards: {},
      anchors: {},
      edges: [],
    ),
  );
  @override
  Widget build(BuildContext context) => MindMapPane(
    snapshot: snapshot,
    controller: controller,
    selectedNodeId: snapshot.boundaries.isEmpty ? 'a' : null,
    onSelect: (_) {},
    onClearSelection: () {},
    onMove: (_, _, _) async {},
    onReparent: (_, _) async {},
    onAssociate: (_, _) async {},
    onRemoveAssociation: (_) {},
    onAction: (_, _) {},
    onToggleCollapsed: (_) {},
    onPrepareRelationshipEdit: () async {
      if (failPrepare) throw StateError('之前草稿未保存');
    },
    onCreateBoundaries: (ids) async {
      created.add(Set.of(ids));
      replace(_snapshot().boundaries.single);
      return ['box'];
    },
    onCommitBoundaryLabel: () async {
      if (fail) throw StateError('保存失败');
      final draft = controller.boundaryDraft!;
      labels.add(draft.label);
      controller.acceptBoundaryLabel(draft);
      final b = snapshot.boundaries.single;
      replace(
        MapBoundary(
          id: b.id,
          mapId: b.mapId,
          parentNodeId: b.parentNodeId,
          nodeIds: b.nodeIds,
          label: draft.label,
          style: b.style,
        ),
      );
    },
    onChangeBoundaryRange: (b, ids) async {
      if (fail) throw StateError('保存失败');
      ranges.add(List.of(ids));
      replace(
        MapBoundary(
          id: b.id,
          mapId: b.mapId,
          parentNodeId: b.parentNodeId,
          nodeIds: ids,
          label: b.label,
          style: b.style,
        ),
      );
    },
    onRemoveBoundary: (_) async => replace(null),
  );
}

MapSnapshot _snapshot({bool boundary = true, bool collapsed = false}) {
  final nodes = [
    MapNode(
      id: 'root',
      mapId: 'map',
      cardId: 'root',
      x: 0,
      y: 160,
      collapsed: collapsed,
    ),
    const MapNode(
      id: 'a',
      mapId: 'map',
      cardId: 'a',
      parentNodeId: 'root',
      sortIndex: 0,
      x: 320,
      y: 30,
    ),
    const MapNode(
      id: 'b',
      mapId: 'map',
      cardId: 'b',
      parentNodeId: 'root',
      sortIndex: 1,
      x: 320,
      y: 190,
    ),
    const MapNode(
      id: 'c',
      mapId: 'map',
      cardId: 'c',
      parentNodeId: 'root',
      sortIndex: 2,
      x: 320,
      y: 350,
    ),
  ];
  const titles = {'root': '研究方法', 'a': '提出问题', 'b': '证据与论证', 'c': '整理结论'};
  return MapSnapshot(
    map: const MindMap(
      layout: MapLayoutKind.free,
      id: 'map',
      projectId: 'p',
      title: '外框范围编辑',
    ),
    nodes: nodes,
    cards: {
      for (final n in nodes)
        n.cardId: NoteCard(
          id: n.cardId,
          projectId: 'p',
          title: titles[n.id]!,
          excerptSnapshot: '',
          body: '内容优先 · 按分支组织知识',
          note: '',
          color: '#F7D976',
        ),
    },
    anchors: {},
    edges: [],
    boundaries: boundary
        ? [
            const MapBoundary(
              id: 'box',
              mapId: 'map',
              parentNodeId: 'root',
              nodeIds: ['a', 'b'],
              label: '分析与验证',
            ),
          ]
        : [],
  );
}
