import '../support/flutter_sdk.dart';

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opennote/domain/models.dart';
import 'package:opennote/domain/relationship_geometry.dart';
import 'package:opennote/ui/map/mind_map_pane.dart';
import 'package:opennote/ui/map/relationship_style_dialog.dart';
import 'package:opennote/ui/theme/open_note_theme.dart';

import '../support/map_context_menu.dart';

void main() {
  testWidgets('右键菜单：关联说明编辑与重置只派发一次，取消不修改', (tester) async {
    final harness = await _mount(tester, shape: RelationshipShape.curve);
    final initial = harness.snapshot.edges.single;
    // 将说明移出曲线命中位置，避免走说明本身的样式快捷入口。
    harness.replace(
      MapEdge(
        id: initial.id,
        mapId: initial.mapId,
        fromNodeId: initial.fromNodeId,
        toNodeId: initial.toNodeId,
        label: initial.label,
        style: initial.style.copyWith(labelOffset: const PdfPoint(0, -100)),
      ),
    );
    await tester.pump();
    Future<void> open() async {
      final edge = harness.snapshot.edges.single;
      final point = relationshipGeometry(
        harness.snapshot.nodes[0],
        harness.snapshot.nodes[1],
        edge.style,
      ).point(.5);
      final target = Offset(point.x + 80, point.y + 80);
      final mouse = await tester.startGesture(
        target,
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await tester.pump(kPressTimeout);
      await mouse.up();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('context-menu-main')), findsOneWidget);
    }

    await open();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(harness.savedStyles, isEmpty);
    await open();
    await tester.tap(find.text('编辑关系说明'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('relationship-label-editor')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    final original = harness.snapshot.edges.single;
    await open();
    await tester.tap(find.text('重置关联线样式'));
    await tester.pumpAndSettle();
    expect(harness.savedStyles, hasLength(1));
    expect(harness.savedStyles.single.shape, RelationshipShape.straight);
    expect(harness.snapshot.edges.single.label, original.label);
    expect(harness.snapshot.edges.single.fromNodeId, original.fromNodeId);
    expect(harness.snapshot.edges.single.toNodeId, original.toNodeId);
    expect(tester.takeException(), isNull);
  });

  testWidgets('光标反馈：关系说明点击、选中拖动和控制点调整各自明确', (tester) async {
    final h = await _mount(tester, shape: RelationshipShape.curve);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(1, 1));
    final label = find.byKey(const Key('relationship-label-edge'));
    await mouse.moveTo(tester.getCenter(label));
    await tester.pump();
    expect(
      tester.binding.mouseTracker.debugDeviceActiveCursor(1),
      SystemMouseCursors.click,
    );
    await _select(tester, h);
    await mouse.moveTo(tester.getCenter(label));
    await tester.pump();
    expect(
      tester.binding.mouseTracker.debugDeviceActiveCursor(1),
      SystemMouseCursors.grab,
    );
    final control = find.byKey(
      const Key('relationship-handle-edge-controlFrom'),
    );
    await mouse.moveTo(tester.getCenter(control));
    await tester.pump();
    expect(
      tester.binding.mouseTracker.debugDeviceActiveCursor(1),
      SystemMouseCursors.move,
    );
    await mouse.down(tester.getCenter(control));
    await mouse.moveBy(const Offset(35, 25));
    await tester.pump();
    expect(
      tester.binding.mouseTracker.debugDeviceActiveCursor(1),
      SystemMouseCursors.move,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await mouse.up();
    await tester.pumpAndSettle();
    expect(
      tester.binding.mouseTracker.debugDeviceActiveCursor(1),
      isNot(SystemMouseCursors.grabbing),
    );
    await mouse.removePointer();
  });

  testWidgets('无选中主题可用工具或 Ctrl+Shift+R 进入两次点选，Esc 取消', (tester) async {
    final harness = await _mount(tester);
    await mapCanvasToolAction(tester, 'tool:association');
    await tester.pump();
    expect(find.byKey(const ValueKey('map-association-mode')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('map-node-a')));
    await tester.pump();
    expect(harness.associations, isEmpty);
    await tester.tap(find.byKey(const ValueKey('map-node-b')));
    await tester.pumpAndSettle();
    expect(harness.associations, [('a', 'b')]);
    expect(find.byKey(const ValueKey('map-association-mode')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('relationship-label-edge')));
    await tester.pump(kDoubleTapTimeout);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(find.byKey(const ValueKey('map-association-mode')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byKey(const ValueKey('map-association-mode')), findsNothing);
    expect(harness.associations, hasLength(1));
  });

  testWidgets('关联模式点击空白创建起点及终点自由主题，失败保持模式可重试', (tester) async {
    final harness = await _mount(tester);
    await mapCanvasToolAction(tester, 'tool:association');
    await tester.pump();
    await tester.tapAt(const Offset(200, 400));
    await tester.pumpAndSettle();
    expect(harness.createdFrom, [null]);
    expect(find.byKey(const ValueKey('map-association-mode')), findsOneWidget);
    harness.failSave = true;
    await tester.tapAt(const Offset(600, 500));
    await tester.pumpAndSettle();
    expect(harness.createdFrom, [null]);
    expect(find.byKey(const ValueKey('map-association-mode')), findsOneWidget);
    harness.failSave = false;
    await tester.tapAt(const Offset(600, 500));
    await tester.pumpAndSettle();
    expect(harness.createdFrom, [null, 'floating-0']);
    expect(find.byKey(const ValueKey('map-association-mode')), findsNothing);
    expect(
      harness.snapshot.nodes.where((n) => n.id.startsWith('floating-')),
      hasLength(2),
    );
  });

  testWidgets('关系说明 Space 编辑、中文组词 Enter 不误提交、保存一次及 Esc 取消', (tester) async {
    final harness = await _mount(tester);
    await _select(tester, harness);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    final field = find.byKey(const Key('relationship-label-editor'));
    expect(field, findsOneWidget);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '中文关系',
        selection: TextSelection.collapsed(offset: 4),
        composing: TextRange(start: 0, end: 4),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(harness.savedLabels, isEmpty);
    expect(harness.controller.relationshipDraft!.label, '中文关系');
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '中文关系',
        selection: TextSelection.collapsed(offset: 4),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(harness.savedLabels, ['中文关系']);
    expect(field, findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    await tester.enterText(field, '取消的新关系');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(harness.savedLabels, ['中文关系']);
    expect(harness.snapshot.edges.single.label, '中文关系');
  });

  testWidgets('关系说明双击、失败保留草稿焦点，身份改变取消旧草稿', (tester) async {
    final harness = await _mount(tester);
    final label = find.byKey(const ValueKey('relationship-label-edge'));
    await tester.tap(label);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(label);
    await tester.pumpAndSettle();
    final field = find.byKey(const Key('relationship-label-editor'));
    expect(field, findsOneWidget);
    await tester.enterText(field, '保留失败草稿');
    harness.failSave = true;
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(field, findsOneWidget);
    expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
    expect(harness.controller.relationshipDraft!.label, '保留失败草稿');
    final stale = harness.controller.relationshipDraft!;
    harness.replace(
      const MapEdge(
        id: 'edge',
        mapId: 'map',
        fromNodeId: 'a',
        toNodeId: 'c',
        label: '新的端点',
      ),
    );
    await tester.pump();
    harness.controller.acceptRelationshipLabel(stale);
    await tester.pump();
    expect(field, findsNothing);
    expect(harness.snapshot.edges.single.label, '新的端点');
    expect(harness.savedLabels, isEmpty);
  });

  testWidgets('曲线控制点预览局部更新、松手一次提交，取消和失败恢复原样', (tester) async {
    final harness = await _mount(tester, shape: RelationshipShape.curve);
    await _select(tester, harness);
    final handle = find.byKey(
      const ValueKey('relationship-handle-edge-controlFrom'),
    );
    final start = tester.getCenter(handle);
    final drag = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await drag.moveBy(const Offset(24, 30));
    await tester.pump();
    await drag.moveBy(const Offset(40, 20));
    await tester.pump();
    expect(harness.savedStyles, isEmpty);
    expect(harness.selections, 0, reason: '控制柄不触发全局选择或重建');
    expect(tester.getCenter(handle), isNot(start));
    await drag.up();
    await tester.pumpAndSettle();
    expect(harness.savedStyles, hasLength(1));
    final accepted = tester.getCenter(handle);
    final cancelled = await tester.startGesture(
      accepted,
      kind: PointerDeviceKind.mouse,
    );
    await cancelled.moveBy(const Offset(35, -20));
    await tester.pump();
    await cancelled.cancel();
    await tester.pumpAndSettle();
    expect(harness.savedStyles, hasLength(1));
    expect(tester.getCenter(handle), accepted);
    harness.failSave = true;
    await tester.drag(handle, const Offset(55, -20));
    await tester.pumpAndSettle();
    expect(harness.savedStyles, hasLength(1));
    expect(tester.getCenter(handle), accepted);
    expect(find.text('Bad state: 模拟保存失败'), findsOneWidget);
  });

  testWidgets('端点可重连到其他主题，空白松手及陈旧模型不提交', (tester) async {
    final harness = await _mount(tester);
    await _select(tester, harness);
    final handle = find.byKey(const ValueKey('relationship-handle-edge-to'));
    final start = tester.getCenter(handle);
    final target = tester
        .getRect(find.byKey(const ValueKey('map-node-c')))
        .topCenter;
    final drag = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await drag.moveTo(target + const Offset(0, 2));
    await tester.pump();
    expect(harness.reconnected, isEmpty);
    await drag.up();
    await tester.pumpAndSettle();
    expect(harness.reconnected, ['b→c']);
    expect(harness.snapshot.edges.single.toNodeId, 'c');
    expect(harness.snapshot.edges.single.style.anchorTo!.y, 0);
    final after = tester.getCenter(handle);
    final invalid = await tester.startGesture(
      after,
      kind: PointerDeviceKind.mouse,
    );
    await invalid.moveTo(const Offset(770, 460));
    await tester.pump();
    await invalid.up();
    await tester.pumpAndSettle();
    expect(harness.reconnected, ['b→c']);
    expect(tester.getCenter(handle), after);
    final stale = await tester.startGesture(
      after,
      kind: PointerDeviceKind.mouse,
    );
    await stale.moveBy(const Offset(30, 10));
    await tester.pump();
    harness.replace(
      const MapEdge(id: 'other', mapId: 'map', fromNodeId: 'a', toNodeId: 'b'),
    );
    await tester.pump();
    await stale.up();
    await tester.pumpAndSettle();
    expect(harness.reconnected, ['b→c']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('关系说明拖动按缩放后的世界坐标提交，控制点模型更新中止旧拖动', (tester) async {
    final harness = await _mount(tester, shape: RelationshipShape.curve);
    harness.controller.setView(scale: .8, worldTopLeft: const Offset(-80, -80));
    await tester.pump();
    await _select(tester, harness);
    final label = find.byKey(const ValueKey('relationship-label-edge'));
    final before =
        harness.snapshot.edges.single.style.labelOffset ??
        const PdfPoint(0, -12);
    await tester.drag(label, const Offset(40, 16));
    await tester.pumpAndSettle();
    expect(harness.savedStyles, hasLength(1));
    final after = harness.snapshot.edges.single.style.labelOffset!;
    expect(after.x - before.x, closeTo(50, 1));
    expect(after.y - before.y, closeTo(20, 1));
    final handle = find.byKey(
      const ValueKey('relationship-handle-edge-controlFrom'),
    );
    final drag = await tester.startGesture(
      tester.getCenter(handle),
      kind: PointerDeviceKind.mouse,
    );
    await drag.moveBy(const Offset(20, 10));
    await tester.pump();
    final current = harness.snapshot.edges.single;
    harness.replace(
      MapEdge(
        id: current.id,
        mapId: current.mapId,
        fromNodeId: current.fromNodeId,
        toNodeId: current.toNodeId,
        label: current.label,
        style: current.style.copyWith(color: '#123456'),
      ),
    );
    await tester.pump();
    await drag.up();
    await tester.pumpAndSettle();
    expect(harness.savedStyles, hasLength(1));
    expect(harness.snapshot.edges.single.style.color, '#123456');
  });

  testWidgets('跟随主题颜色的关联随卡片颜色变化重绘，原存储样式不被覆盖', (tester) async {
    final key = GlobalKey();
    final harness = await _mount(
      tester,
      shape: RelationshipShape.curve,
      captureKey: key,
    );
    final edge = harness.snapshot.edges.single;
    harness.replace(
      MapEdge(
        id: edge.id,
        mapId: edge.mapId,
        fromNodeId: edge.fromNodeId,
        toNodeId: edge.toNodeId,
        label: '',
        style: edge.style.copyWith(colorSource: RelationshipColorSource.from),
      ),
    );
    await tester.pump();
    final geometry = relationshipGeometry(
      harness.snapshot.nodes[0],
      harness.snapshot.nodes[1],
      edge.style,
    );
    final point = geometry.point(.2);
    expect(
      await _colorNear(
        tester,
        key,
        Offset(point.x + 80, point.y + 80),
        const Color(0xffF7D976),
      ),
      isTrue,
    );
    harness.recolor('a', '#EB5B5B');
    await tester.pump();
    expect(
      await _colorNear(
        tester,
        key,
        Offset(point.x + 80, point.y + 80),
        const Color(0xffEB5B5B),
      ),
      isTrue,
    );
    expect(harness.snapshot.edges.single.style.color, '#3574CB');
    expect(
      harness.snapshot.edges.single.style.colorSource,
      RelationshipColorSource.from,
    );
  });

  testWidgets('适合全部包含负坐标曲线控制点及远处关系说明', (tester) async {
    final harness = await _mount(tester, shape: RelationshipShape.curve);
    final edge = harness.snapshot.edges.single;
    harness.replace(
      MapEdge(
        id: edge.id,
        mapId: edge.mapId,
        fromNodeId: edge.fromNodeId,
        toNodeId: edge.toNodeId,
        label: '远处的关系说明',
        style: edge.style.copyWith(
          controlFrom: const PdfPoint(-500, -420),
          controlTo: const PdfPoint(380, -450),
          labelOffset: const PdfPoint(450, -240),
        ),
      ),
    );
    await tester.pump();
    harness.controller.fitAll();
    await tester.pumpAndSettle();
    final label = find.byKey(const ValueKey('relationship-label-edge'));
    expect(label.hitTestable(), findsOneWidget);
    await tester.tap(label);
    await tester.pump(kDoubleTapTimeout);
    for (final part in ['controlFrom', 'controlTo']) {
      expect(
        find.byKey(ValueKey('relationship-handle-edge-$part')).hitTestable(),
        findsOneWidget,
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('关系样式对话框可取消、校验非法颜色、原子保存说明和线条', (tester) async {
    RelationshipEditResult? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: openNoteTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  result = await showDialog<RelationshipEditResult>(
                    context: context,
                    builder: (_) => const RelationshipStyleDialog(
                      edge: MapEdge(
                        id: 'edge',
                        mapId: 'map',
                        fromNodeId: 'a',
                        toNodeId: 'b',
                        label: '旧说明',
                      ),
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
    await tester.enterText(
      find.byKey(const Key('relationship-description')),
      '新的关系说明',
    );
    await tester.enterText(
      find.byKey(const Key('relationship-line-color')),
      'bad',
    );
    await tester.tap(find.byKey(const Key('relationship-style-save')));
    await tester.pumpAndSettle();
    expect(find.text('输入六位十六进制颜色'), findsOneWidget);
    expect(result, isNull);
    await tester.enterText(
      find.byKey(const Key('relationship-line-color')),
      '#3574CB',
    );
    await tester.tap(
      find.byKey(
        const ValueKey('relationship-shape-RelationshipShape.straight'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('曲线').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('relationship-style-save')));
    await tester.pumpAndSettle();
    expect(result!.label, '新的关系说明');
    expect(result!.style.color, '#3574CB');
    expect(result!.style.shape, RelationshipShape.curve);
    result = null;
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('relationship-description')),
      '不能保存',
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });

  testWidgets('900 宽和 1.25 倍文字下样式编辑无溢出，重置保留说明', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 720);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    RelationshipEditResult? result;
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
                  result = await showDialog<RelationshipEditResult>(
                    context: context,
                    builder: (_) => const RelationshipStyleDialog(
                      edge: MapEdge(
                        id: 'edge',
                        mapId: 'map',
                        fromNodeId: 'a',
                        toNodeId: 'b',
                        label: '关系说明继续保留',
                        style: RelationshipStyle(
                          shape: RelationshipShape.curve,
                          controlFrom: PdfPoint(150, 200),
                          labelBold: true,
                          endArrow: RelationshipArrow.triangle,
                        ),
                      ),
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
    await tester.tap(find.byKey(const Key('relationship-style-save')));
    await tester.pumpAndSettle();
    expect(result!.label, '关系说明继续保留');
    expect(result!.style, const RelationshipStyle());
    expect(tester.takeException(), isNull);
  });

  testWidgets('关联编辑 1920 代表截图与文字工具栏布局', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1920, 1080));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      final sdk = flutterSdkPath();
      await (FontLoader('MaterialIcons')..addFont(
            File(
              '$sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
            ).readAsBytes().then(ByteData.sublistView),
          ))
          .load();
      await (FontLoader('Segoe UI')..addFont(
            File('C:/Windows/Fonts/segoeui.ttf')
                .readAsBytes()
                .then(ByteData.sublistView),
          ))
          .load();
      final font = FontLoader('Source Han Sans CN');
      for (final weight in ['Regular', 'Medium', 'Bold']) {
        font.addFont(
          File('assets/fonts/source-han-sans/SourceHanSansCN-$weight.otf')
              .readAsBytes()
              .then(ByteData.sublistView),
        );
      }
      await font.load();
    });
    final key = GlobalKey();
    final harness = await _mount(
      tester,
      shape: RelationshipShape.curve,
      captureKey: key,
    );
    harness.controller.fitAll();
    await tester.pumpAndSettle();
    await _select(tester, harness);
    await tester.runAsync(() async {
      final image =
          await (key.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary)
              .toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final folder = await Directory(
        '.local/verification/xmind-relationships-20261005',
      ).create(recursive: true);
      await File('${folder.path}/relationships-1920.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
    expect(tester.takeException(), isNull);
  });
}

class _Harness extends StatefulWidget {
  const _Harness({required this.shape, this.captureKey});
  final RelationshipShape shape;
  final GlobalKey? captureKey;
  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final controller = MindMapPaneController();
  late MapSnapshot snapshot = _snapshot(widget.shape);
  final savedLabels = <String>[];
  final savedStyles = <RelationshipStyle>[];
  final reconnected = <String>[];
  final associations = <(String, String)>[];
  final createdFrom = <String?>[];
  bool failSave = false;
  int selections = 0;
  void recolor(String cardId, String color) {
    final card = snapshot.cards[cardId]!;
    setState(
      () => snapshot = MapSnapshot(
        map: snapshot.map,
        nodes: snapshot.nodes,
        edges: snapshot.edges,
        anchors: snapshot.anchors,
        cards: {
          ...snapshot.cards,
          cardId: NoteCard(
            id: card.id,
            projectId: card.projectId,
            title: card.title,
            body: card.body,
            excerptSnapshot: card.excerptSnapshot,
            note: card.note,
            color: color,
          ),
        },
      ),
    );
  }

  void replace(MapEdge edge) => setState(
    () => snapshot = MapSnapshot(
      map: snapshot.map,
      nodes: snapshot.nodes,
      cards: snapshot.cards,
      anchors: snapshot.anchors,
      edges: [edge],
    ),
  );
  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: openNoteTheme(),
    home: Scaffold(
      body: RepaintBoundary(
        key: widget.captureKey,
        child: MindMapPane(
          snapshot: snapshot,
          controller: controller,
          onSelect: (_) => selections++,
          onMove: (_, _, _) async {},
          onReparent: (_, _) async {},
          onAssociate: (from, to) async => associations.add((from, to)),
          onCreateRelatedAt: (position, from) async {
            if (failSave) throw StateError('模拟保存失败');
            final id = 'floating-${createdFrom.length}';
            createdFrom.add(from);
            setState(
              () => snapshot = MapSnapshot(
                map: snapshot.map,
                nodes: [
                  ...snapshot.nodes,
                  MapNode(
                    id: id,
                    mapId: 'map',
                    cardId: id,
                    x: position.dx,
                    y: position.dy,
                  ),
                ],
                cards: {
                  ...snapshot.cards,
                  id: NoteCard(
                    id: id,
                    projectId: 'project',
                    title: '自由主题',
                    body: '',
                    excerptSnapshot: '',
                    note: '',
                    color: '#F7D976',
                  ),
                },
                anchors: snapshot.anchors,
                edges: snapshot.edges,
              ),
            );
            return id;
          },
          onRemoveAssociation: (_) {},
          onAction: (_, _) {},
          onToggleCollapsed: (_) {},
          onCommitRelationshipLabel: () async {
            if (failSave) throw StateError('模拟保存失败');
            final draft = controller.relationshipDraft!;
            savedLabels.add(draft.label);
            final old = snapshot.edges.single;
            controller.acceptRelationshipLabel(draft);
            replace(
              MapEdge(
                id: old.id,
                mapId: old.mapId,
                fromNodeId: old.fromNodeId,
                toNodeId: old.toNodeId,
                label: draft.label,
                style: old.style,
              ),
            );
          },
          onChangeAssociationStyle: (old, style) async {
            if (failSave) throw StateError('模拟保存失败');
            savedStyles.add(style);
            replace(
              MapEdge(
                id: old.id,
                mapId: old.mapId,
                fromNodeId: old.fromNodeId,
                toNodeId: old.toNodeId,
                label: old.label,
                style: style,
              ),
            );
          },
          onReconnectAssociation: (old, endpoint, target, anchor) async {
            if (failSave) throw StateError('模拟保存失败');
            reconnected.add('$endpoint→$target');
            replace(
              MapEdge(
                id: old.id,
                mapId: old.mapId,
                fromNodeId: endpoint == old.fromNodeId
                    ? target
                    : old.fromNodeId,
                toNodeId: endpoint == old.toNodeId ? target : old.toNodeId,
                label: old.label,
                style: endpoint == old.fromNodeId
                    ? old.style.copyWith(anchorFrom: anchor)
                    : old.style.copyWith(anchorTo: anchor),
              ),
            );
          },
        ),
      ),
    ),
  );
}

Future<_HarnessState> _mount(
  WidgetTester tester, {
  RelationshipShape shape = RelationshipShape.straight,
  GlobalKey? captureKey,
}) async {
  await tester.pumpWidget(_Harness(shape: shape, captureKey: captureKey));
  await tester.pumpAndSettle();
  final state = tester.state<_HarnessState>(find.byType(_Harness));
  state.controller.setView(scale: 1, worldTopLeft: const Offset(-80, -80));
  await tester.pump();
  return state;
}

Future<void> _select(WidgetTester tester, _HarnessState harness) async {
  await tester.tap(find.byKey(const ValueKey('relationship-label-edge')));
  await tester.pump(kDoubleTapTimeout);
  expect(find.byKey(const Key('relationship-actions')), findsOneWidget);
}

MapSnapshot _snapshot(RelationshipShape shape) => MapSnapshot(
  map: const MindMap(
    layout: MapLayoutKind.free,
    id: 'map',
    projectId: 'project',
    title: '关联编辑',
  ),
  nodes: const [
    MapNode(id: 'a', mapId: 'map', cardId: 'a', x: 0, y: 0),
    MapNode(id: 'b', mapId: 'map', cardId: 'b', x: 400, y: 0),
    MapNode(id: 'c', mapId: 'map', cardId: 'c', x: 400, y: 260),
  ],
  cards: {
    for (final id in ['a', 'b', 'c'])
      id: NoteCard(
        id: id,
        projectId: 'project',
        title: switch (id) {
          'a' => '研究问题',
          'b' => '核心结论',
          _ => '支持证据',
        },
        excerptSnapshot: '',
        body: '内容优先，关系让思路清晰。',
        note: '',
        color: '#F7D976',
      ),
  },
  anchors: const {},
  edges: [
    MapEdge(
      id: 'edge',
      mapId: 'map',
      fromNodeId: 'a',
      toNodeId: 'b',
      label: '支持与影响',
      style: RelationshipStyle(
        shape: shape,
        dashed: false,
        endArrow: RelationshipArrow.triangle,
        color: '#3574CB',
      ),
    ),
  ],
);

Future<bool> _colorNear(
  WidgetTester tester,
  GlobalKey key,
  Offset point,
  Color color,
) async => (await tester.runAsync(() async {
  final image =
      await (key.currentContext!.findRenderObject()! as RenderRepaintBoundary)
          .toImage();
  try {
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    for (var y = point.dy.floor() - 4; y <= point.dy.ceil() + 4; y++) {
      for (var x = point.dx.floor() - 4; x <= point.dx.ceil() + 4; x++) {
        final offset = 4 * (y * image.width + x);
        if ((bytes.getUint8(offset) - (color.r * 255).round()).abs() < 20 &&
            (bytes.getUint8(offset + 1) - (color.g * 255).round()).abs() < 20 &&
            (bytes.getUint8(offset + 2) - (color.b * 255).round()).abs() < 20) {
          return true;
        }
      }
    }
    return false;
  } finally {
    image.dispose();
  }
}))!;
