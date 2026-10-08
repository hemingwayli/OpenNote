import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opennote/domain/models.dart';
import 'package:opennote/ui/map/mind_map_pane.dart';
import 'package:opennote/ui/reader/reader_contract.dart';

import '../support/map_context_menu.dart';

void main() {
  testWidgets('编辑区收窄后保持卡片可见，不改变缩放焦点或业务选择', (tester) async {
    final controller = MindMapPaneController();
    final selected = <String>[];
    await tester.pumpWidget(
      _host(_snapshot(), controller, onSelect: (node) => selected.add(node.id)),
    );
    await tester.pumpAndSettle();
    controller.setView(scale: .3, worldTopLeft: const Offset(900, 900));
    await tester.pump();
    final focus = FocusManager.instance.primaryFocus;
    controller.keepNodeVisible('a');
    await tester.pump();
    final node = tester.getRect(_mapNode('a'));
    final pane = tester.getRect(find.byType(MindMapPane));
    expect(node.left, greaterThanOrEqualTo(pane.left + 11.9));
    expect(node.top, greaterThanOrEqualTo(pane.top + 59.9));
    expect(node.right, lessThanOrEqualTo(pane.right - 11.9));
    expect(controller.scale, closeTo(.3, .00001));
    expect(FocusManager.instance.primaryFocus, same(focus));
    expect(selected, isEmpty);
    controller.keepNodeVisible('a');
    await tester.pump();
    expect(tester.getRect(_mapNode('a')), node);
    expect(tester.takeException(), isNull);
  });

  testWidgets('根节点平移：所有自动结构及缩放下任一根节点都平移整图且不提交', (tester) async {
    for (final kind in MapLayoutKind.values.where(
      (kind) => kind != MapLayoutKind.free,
    )) {
      for (final scale in [.75, 1.25]) {
        for (final root in ['a', 'b']) {
          final controller = MindMapPaneController();
          final snapshot = _withLayout(_snapshot(), kind);
          final commits = <String>[];
          final activated = <String>[];
          final selected = <String>[];
          await tester.pumpWidget(
            _host(
              snapshot,
              controller,
              key: ValueKey((kind, scale, root)),
              onSelect: (node) => selected.add(node.id),
              onActivate: (node) => activated.add(node.id),
              onMove: (_, _, _) async => commits.add('move'),
              onMoveGroup: (_) async => commits.add('group'),
              onReparentAt: (_, _, _, _) async => commits.add('reparent'),
            ),
          );
          await tester.pumpAndSettle();
          controller.setView(
            scale: scale,
            worldTopLeft: const Offset(-24, -24),
          );
          await tester.pump();
          final before = {
            for (final node in snapshot.nodes)
              node.id: tester.getRect(_mapNode(node.id)),
          };
          final drag = await tester.startGesture(
            _nodeHitPoint(tester, root),
            kind: PointerDeviceKind.mouse,
          );
          await drag.moveBy(const Offset(30, 0));
          await tester.pump();
          await drag.moveBy(const Offset(50, 30));
          await tester.pump();
          final delta =
              tester.getRect(_mapNode(root)).topLeft - before[root]!.topLeft;
          expect(
            delta.distance,
            greaterThan(20),
            reason: '$kind / $scale / $root',
          );
          for (final entry in before.entries) {
            expect(
              tester.getRect(_mapNode(entry.key)),
              rectMoreOrLessEquals(entry.value.shift(delta), epsilon: .000001),
              reason: '其他独立根节点及后代随整张画布同步移动',
            );
          }
          expect(
            tester.binding.mouseTracker.debugDeviceActiveCursor(1),
            SystemMouseCursors.grabbing,
          );
          expect(find.text('成为子卡片'), findsNothing);
          expect(commits, isEmpty);
          await drag.up();
          await tester.pumpAndSettle();
          for (final entry in before.entries) {
            expect(
              tester.getRect(_mapNode(entry.key)),
              rectMoreOrLessEquals(entry.value.shift(delta), epsilon: .000001),
              reason: '平移视图在松手后保留，不产生节点归位动画',
            );
          }
          expect(controller.scale, closeTo(scale, .00001));
          expect(selected, [root]);
          expect(_mapSemantics(tester, root).properties.selected, isTrue);
          expect(activated, isEmpty, reason: '拖动不误触回源');
          expect(commits, isEmpty, reason: '不进入移动、挂接或多选提交，不产生保存和撤销');
          expect(find.byType(LinearProgressIndicator), findsNothing);
          expect(
            tester.binding.mouseTracker.debugDeviceActiveCursor(1),
            isNot(SystemMouseCursors.grabbing),
          );
          expect(tester.takeException(), isNull);
        }
      }
    }
  });

  testWidgets('根节点平移：轻微抖动仍单击，双击编辑和原生取消不串连', (tester) async {
    final controller = MindMapPaneController();
    final activated = <String>[];
    final actions = <String>[];
    final commits = <String>[];
    await tester.pumpWidget(
      _host(
        _withLayout(_snapshot(), MapLayoutKind.right),
        controller,
        onActivate: (node) => activated.add(node.id),
        onAction: (_, action) => actions.add(action),
        onMove: (_, _, _) async => commits.add('move'),
      ),
    );
    await tester.pumpAndSettle();
    controller.setView(scale: 1, worldTopLeft: const Offset(-100, -80));
    await tester.pump();
    final view = tester
        .widget<InteractiveViewer>(find.byType(InteractiveViewer))
        .transformationController!;
    final before = view.value.clone();
    final click = _timestampGesture(tester);
    await click.down(
      _nodeHitPoint(tester, 'a'),
      timeStamp: const Duration(milliseconds: 100),
    );
    await click.moveBy(
      const Offset(kPrecisePointerPanSlop / 4, 0),
      timeStamp: const Duration(milliseconds: 105),
    );
    await click.up(timeStamp: const Duration(milliseconds: 110));
    await tester.pump();
    expect(view.value, before);
    expect(activated, ['a']);
    await _timedNodeClick(tester, 'a', down: 190, up: 200);
    expect(actions, ['edit']);
    expect(activated, ['a']);
    final drag = _timestampGesture(tester);
    await drag.down(
      _nodeHitPoint(tester, 'a'),
      timeStamp: const Duration(milliseconds: 400),
    );
    await drag.moveBy(
      const Offset(30, 0),
      timeStamp: const Duration(milliseconds: 410),
    );
    await tester.pump();
    await drag.moveBy(
      const Offset(40, 20),
      timeStamp: const Duration(milliseconds: 420),
    );
    await tester.pump();
    expect(view.value, isNot(before));
    expect(
      tester.binding.mouseTracker.debugDeviceActiveCursor(1),
      SystemMouseCursors.grabbing,
    );
    final cancelledView = view.value.clone();
    await drag.cancel(timeStamp: const Duration(milliseconds: 430));
    await tester.pumpAndSettle();
    expect(view.value, cancelledView);
    expect(commits, isEmpty);
    await _timedNodeClick(tester, 'a', down: 700, up: 710);
    expect(activated, ['a', 'a'], reason: '取消平移后恢复正常点击');
    expect(actions, ['edit'], reason: '平移不成为下一次双击的首击');
    await tester.pumpWidget(const SizedBox.shrink());
    expect(
      tester.binding.mouseTracker.debugDeviceActiveCursor(1),
      isNot(SystemMouseCursors.grabbing),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('根节点平移：自动和自由布局切换更新手势，自由根仅移动自身分支', (tester) async {
    final controller = MindMapPaneController();
    final base = _withNodes(_snapshot(), [
      for (final node in _snapshot().nodes)
        node.id == 'a' ? node.withBranchLayout(MapLayoutKind.right) : node,
    ]);
    var snapshot = _withLayout(base, MapLayoutKind.right);
    late StateSetter refresh;
    final commits = <String>[];
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (_, setState) {
          refresh = setState;
          return _host(
            snapshot,
            controller,
            selectedNodeId: 'a',
            onMove: (id, _, _) async => commits.add(id),
          );
        },
      ),
    );
    await tester.pumpAndSettle();
    for (final layout in [
      MapLayoutKind.right,
      MapLayoutKind.free,
      MapLayoutKind.left,
    ]) {
      refresh(() => snapshot = _withLayout(base, layout));
      await tester.pump();
      controller.setView(scale: .75, worldTopLeft: const Offset(-100, -80));
      await tester.pump();
      final view = tester
          .widget<InteractiveViewer>(find.byType(InteractiveViewer))
          .transformationController!;
      final beforeView = view.value.clone();
      final before = {
        for (final id in ['a', 'b', 'c']) id: tester.getRect(_mapNode(id)),
      };
      final drag = await tester.startGesture(
        _nodeHitPoint(tester, 'a'),
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveBy(const Offset(30, 0));
      await tester.pump();
      await drag.moveBy(const Offset(40, 20));
      await tester.pump();
      final delta =
          tester.getRect(_mapNode('a')).topLeft - before['a']!.topLeft;
      expect(delta.distance, greaterThan(20));
      expect(tester.getRect(_mapNode('c')), before['c']!.shift(delta));
      if (layout == MapLayoutKind.free) {
        expect(view.value, beforeView);
        expect(tester.getRect(_mapNode('b')), before['b']);
      } else {
        expect(view.value, isNot(beforeView));
        expect(tester.getRect(_mapNode('b')), before['b']!.shift(delta));
      }
      await drag.up();
      await tester.pumpAndSettle();
      expect(commits, layout == MapLayoutKind.right ? isEmpty : ['a']);
      expect(tester.getRect(_mapNode('a')), before['a']!.shift(delta));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('根节点平移：多选且无整组保存入口仍可平移，关联模式不平移', (tester) async {
    final controller = MindMapPaneController();
    final snapshot = _withLayout(_snapshot(), MapLayoutKind.right);
    final commits = <String>[];
    await tester.pumpWidget(
      _host(
        snapshot,
        controller,
        selectedNodeId: 'a',
        selectedNodeIds: const {'a', 'c'},
        onMove: (_, _, _) async => commits.add('move'),
        onAssociate: (_, _) async => commits.add('associate'),
      ),
    );
    await tester.pumpAndSettle();
    controller.setView(scale: 1, worldTopLeft: const Offset(-100, -80));
    await tester.pump();
    final view = tester
        .widget<InteractiveViewer>(find.byType(InteractiveViewer))
        .transformationController!;
    final before = view.value.clone();
    final drag = await tester.startGesture(
      _nodeHitPoint(tester, 'a'),
      kind: PointerDeviceKind.mouse,
    );
    await drag.moveBy(const Offset(30, 0));
    await tester.pump();
    await drag.moveBy(const Offset(40, 20));
    await tester.pump();
    expect(view.value, isNot(before));
    await drag.up();
    await tester.pumpAndSettle();
    expect(_mapSemantics(tester, 'a').properties.selected, isTrue);
    expect(_mapSemantics(tester, 'c').properties.selected, isTrue);
    expect(commits, isEmpty);
    await tester.tapAt(_nodeHitPoint(tester, 'a'));
    await tester.pump();
    await mapCanvasToolAction(tester, 'tool:association');
    await tester.pump();
    final associationView = view.value.clone();
    final blocked = await tester.startGesture(
      _nodeHitPoint(tester, 'b'),
      kind: PointerDeviceKind.mouse,
    );
    await blocked.moveBy(const Offset(40, 0));
    await tester.pump();
    await blocked.moveBy(const Offset(40, 20));
    await tester.pump();
    expect(view.value, associationView);
    await blocked.up();
    await tester.pumpAndSettle();
    expect(commits, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('光标反馈：平移、卡片拖动、关联和 Shift 框选随实际模式变化', (tester) async {
    final controller = MindMapPaneController();
    await tester.pumpWidget(
      _host(
        _snapshot(),
        controller,
        selectedNodeId: 'a',
        onSelectionChanged: (_, _) {},
      ),
    );
    await tester.pumpAndSettle();
    controller.setView(scale: 1, worldTopLeft: const Offset(-100, -80));
    await tester.pump();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(40, 500));
    Future<void> hover(Offset point, MouseCursor cursor) async {
      await mouse.moveTo(point);
      await tester.pump();
      expect(tester.binding.mouseTracker.debugDeviceActiveCursor(1), cursor);
    }

    await hover(const Offset(40, 500), SystemMouseCursors.grab);
    final before = controller.scale;
    final beforePosition = tester.getCenter(_mapNode('a'));
    await mouse.down(const Offset(40, 500));
    await mouse.moveBy(const Offset(50, -30));
    await tester.pump();
    await mouse.moveBy(const Offset(20, -20));
    await tester.pump();
    expect(
      tester.binding.mouseTracker.debugDeviceActiveCursor(1),
      SystemMouseCursors.grabbing,
    );
    await mouse.up();
    await tester.pumpAndSettle();
    expect(controller.scale, before);
    expect(tester.getCenter(_mapNode('a')), isNot(beforePosition));
    await hover(tester.getCenter(_mapNode('a')), SystemMouseCursors.grab);
    await mouse.down(tester.getCenter(_mapNode('a')));
    await mouse.moveBy(const Offset(40, 20));
    await tester.pump();
    expect(
      tester.binding.mouseTracker.debugDeviceActiveCursor(1),
      SystemMouseCursors.grabbing,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await mouse.up();
    await tester.pumpAndSettle();
    await hover(tester.getCenter(_mapNode('a')), SystemMouseCursors.grab);
    await mapCanvasToolAction(tester, 'tool:association');
    await tester.pump();
    await hover(tester.getCenter(_mapNode('b')), SystemMouseCursors.click);
    await hover(const Offset(40, 500), SystemMouseCursors.precise);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(
      tester.binding.mouseTracker.debugDeviceActiveCursor(1),
      SystemMouseCursors.precise,
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(
      tester.binding.mouseTracker.debugDeviceActiveCursor(1),
      SystemMouseCursors.grab,
    );
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('文字拖入脑图：空白与卡片落点换算准确，悬停不改变选择且提交只领取一次', (tester) async {
    final controller = MindMapPaneController();
    final drops = <(Offset, String?)>[];
    var committed = 0;
    var drag = _excerptDrag(onCommitted: () => committed++);
    late StateSetter refresh;
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) {
          refresh = setState;
          return _host(
            _snapshot(),
            controller,
            selectedNodeId: 'a',
            selectedNodeIds: const {'a'},
            dragSource: _excerptDragSource(drag),
            onTextExcerptDrop: (value, position, parent) async {
              expect(value.claim(), isFalse, reason: '目标在回调前已领取，重复回调不可再次领取');
              final excerpt = await value.prepare();
              expect(excerpt.text, '文字摘录');
              drops.add((position, parent?.id));
            },
          );
        },
      ),
    );
    await tester.pumpAndSettle();
    controller.setView(scale: .5, worldTopLeft: const Offset(-100, -80));
    await tester.pump();
    Future<void> dropAt(Offset global) async {
      final held = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('test-text-drag-source'))),
        kind: PointerDeviceKind.mouse,
      );
      await held.moveBy(const Offset(24, 0));
      await tester.pump();
      await held.moveTo(global);
      await tester.pump();
      expect(find.byKey(const Key('map-text-drop-preview')), findsOneWidget);
      expect(_mapSemantics(tester, 'a').properties.selected, isTrue);
      await held.up();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('map-text-drop-preview')), findsNothing);
    }

    final pane = tester.getRect(find.byType(MindMapPane));
    await dropAt(pane.topLeft + const Offset(25, 115));
    expect(drops.single.$1.dx, closeTo(-50, .01));
    expect(drops.single.$1.dy, closeTo(150, .01));
    expect(drops.single.$2, isNull);
    expect(committed, 1);
    refresh(() => drag = _excerptDrag(onCommitted: () => committed++));
    await tester.pump();
    controller.setView(scale: .75, worldTopLeft: const Offset(-100, -80));
    await tester.pump();
    await dropAt(tester.getCenter(_mapNode('b')));
    expect(drops.last.$2, 'b');
    expect(drops.last.$1.dx, closeTo(510, .01));
    expect(drops.last.$1.dy, closeTo(58, .01));
    expect(committed, 2);
    expect(_mapSemantics(tester, 'a').properties.selected, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('文字拖入脑图：工具栏不接收，删除目标或隐藏接收入口后不错误创建顶层', (tester) async {
    final controller = MindMapPaneController();
    var snapshot = _snapshot();
    var drag = _excerptDrag();
    var accepting = true;
    var drops = 0;
    late StateSetter refresh;
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) {
          refresh = setState;
          return _host(
            snapshot,
            controller,
            dragSource: _excerptDragSource(drag),
            onTextExcerptDrop: accepting ? (_, _, _) async => drops++ : null,
          );
        },
      ),
    );
    await tester.pumpAndSettle();
    controller.setView(scale: .75, worldTopLeft: const Offset(-100, -80));
    await tester.pump();
    Future<TestGesture> hover(Offset point) async {
      final held = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('test-text-drag-source'))),
        kind: PointerDeviceKind.mouse,
      );
      await held.moveBy(const Offset(24, 0));
      await tester.pump();
      await held.moveTo(point);
      await tester.pump();
      return held;
    }

    final toolbar = await hover(tester.getCenter(find.byTooltip('适合全部卡片')));
    expect(find.byKey(const Key('map-text-drop-preview')), findsNothing);
    await toolbar.up();
    await tester.pumpAndSettle();
    expect(drops, 0);
    refresh(() => drag = _excerptDrag());
    await tester.pump();
    final deleted = await hover(tester.getCenter(_mapNode('b')));
    expect(find.text('加入子主题'), findsOneWidget);
    refresh(
      () => snapshot = _withNodes(
        snapshot,
        snapshot.nodes.where((n) => n.id != 'b').toList(),
      ),
    );
    await tester.pump();
    await deleted.up();
    await tester.pumpAndSettle();
    expect(drops, 0);
    refresh(() {
      snapshot = _snapshot();
      drag = _excerptDrag();
    });
    await tester.pump();
    final hidden = await hover(tester.getCenter(_mapNode('b')));
    refresh(() => accepting = false);
    await tester.pump();
    await hidden.up();
    await tester.pumpAndSettle();
    expect(drops, 0);
    expect(tester.takeException(), isNull);
  });
  testWidgets('卡片双击编辑：首击立即回源，第二抬起只编辑最新同ID节点一次', (tester) async {
    final controller = MindMapPaneController();
    var snapshot = _withNodes(_snapshot(), [_snapshot().nodes.first]);
    late StateSetter refresh;
    var canCreate = true;
    final activated = <MapNode>[];
    final actions = <(MapNode, String)>[];
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) {
          refresh = setState;
          return _host(
            snapshot,
            controller,
            canCreate: canCreate,
            onActivate: activated.add,
            onAction: (node, action) => actions.add((node, action)),
          );
        },
      ),
    );
    await tester.pumpAndSettle();
    controller.setView(scale: 1, worldTopLeft: const Offset(-200, -180));
    await tester.pump();
    final first = _timestampGesture(tester);
    await first.down(
      _nodeHitPoint(tester, 'a'),
      timeStamp: const Duration(milliseconds: 100),
    );
    expect(activated, isEmpty);
    await first.up(timeStamp: const Duration(milliseconds: 110));
    expect(activated, hasLength(1), reason: '第一次抬起立即回源，不等待双击超时或下一帧');
    expect(actions, isEmpty);
    await tester.pump();
    final gestureState = tester.state(_nodeGesture('a'));
    final second = _timestampGesture(tester);
    await second.down(
      _nodeHitPoint(tester, 'a'),
      timeStamp: const Duration(milliseconds: 190),
    );
    expect(actions, isEmpty, reason: '第二次按下仍不能编辑');
    final latestNode = _copyNodeAt(snapshot.nodes.single, x: 8, y: 6);
    refresh(() {
      snapshot = _withCardBody(
        _withNodes(snapshot, [latestNode]),
        'card-a',
        '后台刷新后的正文',
      );
      canCreate = false;
    });
    await tester.pump();
    expect(tester.state(_nodeGesture('a')), same(gestureState));
    await second.up(timeStamp: const Duration(milliseconds: 200));
    expect(activated, hasLength(1), reason: '第二次成功点击不能再次回源');
    expect(actions, hasLength(1));
    expect(actions.single.$1, same(latestNode));
    expect(actions.single.$2, 'edit');
    await _timedNodeClick(tester, 'a', down: 280, up: 290);
    expect(actions, hasLength(1), reason: '完成一对后第三次点击重新成为普通单击');
    expect(activated, hasLength(2));
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('卡片双击编辑：真实时间距离设备及触摸边界不串连', (tester) async {
    final cases = [
      (
        name: '最小间隔之前',
        gap: 39,
        shift: 0.0,
        device: 1,
        kind: PointerDeviceKind.mouse,
        node: 'a',
        edit: false,
      ),
      (
        name: '最小间隔边界',
        gap: 40,
        shift: 0.0,
        device: 1,
        kind: PointerDeviceKind.mouse,
        node: 'a',
        edit: true,
      ),
      (
        name: '最大间隔边界',
        gap: 300,
        shift: 0.0,
        device: 1,
        kind: PointerDeviceKind.mouse,
        node: 'a',
        edit: true,
      ),
      (
        name: '最大间隔之后',
        gap: 301,
        shift: 0.0,
        device: 1,
        kind: PointerDeviceKind.mouse,
        node: 'a',
        edit: false,
      ),
      (
        name: '逻辑距离边界',
        gap: 100,
        shift: 100.0,
        device: 1,
        kind: PointerDeviceKind.mouse,
        node: 'a',
        edit: true,
      ),
      (
        name: '超过逻辑距离',
        gap: 100,
        shift: 100.01,
        device: 1,
        kind: PointerDeviceKind.mouse,
        node: 'a',
        edit: false,
      ),
      (
        name: '另一鼠标设备',
        gap: 100,
        shift: 0.0,
        device: 2,
        kind: PointerDeviceKind.mouse,
        node: 'a',
        edit: false,
      ),
      (
        name: '触摸保持普通点击',
        gap: 100,
        shift: 0.0,
        device: 0,
        kind: PointerDeviceKind.touch,
        node: 'a',
        edit: false,
      ),
      (
        name: '相邻不同卡片',
        gap: 100,
        shift: 0.0,
        device: 1,
        kind: PointerDeviceKind.mouse,
        node: 'b',
        edit: false,
      ),
    ];
    for (final sample in cases) {
      final controller = MindMapPaneController();
      final activated = <String>[];
      final actions = <String>[];
      final base = _snapshot();
      final snapshot = _withNodes(base, [
        base.nodes.first,
        _copyNodeAt(base.nodes[1], x: 230),
      ]);
      await tester.pumpWidget(
        _host(
          snapshot,
          controller,
          onActivate: (node) => activated.add(node.id),
          onAction: (_, action) => actions.add(action),
        ),
      );
      await tester.pumpAndSettle();
      controller.setView(scale: 1, worldTopLeft: const Offset(-200, -180));
      await tester.pump();
      final firstPoint =
          _nodeHitPoint(tester, 'a') +
          (sample.node == 'b' ? const Offset(90, 0) : Offset.zero);
      await _timedNodeClick(
        tester,
        'a',
        down: 1000,
        up: 1010,
        point: firstPoint,
      );
      expect(activated, ['a'], reason: sample.name);
      final secondPoint = sample.node == 'b'
          ? tester.getRect(_mapNode('b')).centerLeft + const Offset(10, 0)
          : firstPoint + Offset(sample.shift, 0);
      if (sample.node == 'b') {
        expect((secondPoint - firstPoint).distance, lessThan(kDoubleTapSlop));
      }
      await _timedNodeClick(
        tester,
        sample.node,
        down: 1010 + sample.gap,
        up: 1020 + sample.gap,
        point: secondPoint,
        kind: sample.kind,
        device: sample.device,
      );
      expect(actions, sample.edit ? ['edit'] : isEmpty, reason: sample.name);
      expect(activated.length, sample.edit ? 1 : 2, reason: sample.name);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull, reason: sample.name);
    }
  });

  testWidgets('卡片双击编辑：长第一次按压按实际抬起计时且第二次仍须成功抬起', (tester) async {
    final controller = MindMapPaneController();
    final activated = <String>[];
    final actions = <String>[];
    await tester.pumpWidget(
      _host(
        _withNodes(_snapshot(), [_snapshot().nodes.first]),
        controller,
        onActivate: (node) => activated.add(node.id),
        onAction: (_, action) => actions.add(action),
      ),
    );
    await tester.pumpAndSettle();
    controller.setView(scale: 1, worldTopLeft: const Offset(-200, -180));
    await tester.pump();
    final first = _timestampGesture(tester);
    await first.down(
      _nodeHitPoint(tester, 'a'),
      timeStamp: const Duration(milliseconds: 100),
    );
    await tester.pump(const Duration(milliseconds: 1200));
    expect(activated, isEmpty);
    await first.up(timeStamp: const Duration(milliseconds: 1300));
    expect(activated, ['a']);
    final second = _timestampGesture(tester);
    await second.down(
      _nodeHitPoint(tester, 'a'),
      timeStamp: const Duration(milliseconds: 1400),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(actions, isEmpty);
    await second.up(timeStamp: const Duration(milliseconds: 1900));
    expect(actions, ['edit'], reason: '间隔取1300→1400，不能把第一次长按时长计入间隔');
    expect(activated, ['a']);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('卡片双击编辑：Ctrl提前释放刷新拖动及真实取消都终止候选', (tester) async {
    final controller = MindMapPaneController();
    var snapshot = _withNodes(_snapshot(), [_snapshot().nodes.first]);
    late StateSetter refresh;
    final activated = <String>[];
    final toggled = <String>[];
    final actions = <String>[];
    final moves = <String>[];
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) {
          refresh = setState;
          return _host(
            snapshot,
            controller,
            onActivate: (node) => activated.add(node.id),
            onToggleSelection: (node) => toggled.add(node.id),
            onAction: (_, action) => actions.add(action),
            onMove: (id, x, y) async {
              moves.add(id);
              refresh(
                () =>
                    snapshot = _applyPositions(snapshot, {id: PdfPoint(x, y)}),
              );
            },
          );
        },
      ),
    );
    await tester.pumpAndSettle();
    controller.setView(scale: 1, worldTopLeft: const Offset(-200, -180));
    await tester.pump();
    await _timedNodeClick(tester, 'a', down: 10, up: 20);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    final modified = _timestampGesture(tester);
    await modified.down(
      _nodeHitPoint(tester, 'a'),
      timeStamp: const Duration(milliseconds: 100),
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    refresh(() => snapshot = _withCardBody(snapshot, 'card-a', '按住期间模型更新'));
    await tester.pump();
    await modified.up(timeStamp: const Duration(milliseconds: 110));
    expect(toggled, ['a']);
    expect(activated, ['a']);
    expect(actions, isEmpty);
    await _timedNodeClick(tester, 'a', down: 200, up: 210);
    final drag = _timestampGesture(tester);
    await drag.down(
      _nodeHitPoint(tester, 'a'),
      timeStamp: const Duration(milliseconds: 290),
    );
    await drag.moveBy(
      const Offset(24, 0),
      timeStamp: const Duration(milliseconds: 300),
    );
    await tester.pump();
    await drag.up(timeStamp: const Duration(milliseconds: 310));
    await tester.pumpAndSettle();
    expect(moves, ['a']);
    expect(activated, ['a', 'a']);
    expect(actions, isEmpty);
    await _timedNodeClick(tester, 'a', down: 400, up: 410);
    final cancelled = _timestampGesture(tester);
    await cancelled.down(
      _nodeHitPoint(tester, 'a'),
      timeStamp: const Duration(milliseconds: 490),
    );
    await cancelled.cancel(timeStamp: const Duration(milliseconds: 500));
    await tester.pump();
    await _timedNodeClick(tester, 'a', down: 550, up: 560);
    expect(activated, hasLength(4), reason: '取消不能留下先前普通点击的编辑候选');
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await _timedNodeClick(tester, 'a', down: 640, up: 650);
    expect(activated, hasLength(5), reason: '两次点击间短暂Ctrl也终止候选');
    expect(actions, isEmpty);
    expect(toggled, ['a']);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('卡片双击编辑：折叠回源菜单空白与关联按钮打断鼠标点击对', (tester) async {
    for (final interrupt in [
      'fold',
      'source',
      'context',
      'blank',
      'association',
    ]) {
      final controller = MindMapPaneController();
      final base = _snapshot();
      final snapshot = MapSnapshot(
        map: base.map,
        nodes: [
          base.nodes.first,
          _copyNodeAt(base.nodes[1], x: 230),
          base.nodes.last,
        ],
        cards: base.cards,
        anchors: {
          'card-a': [
            SourceAnchor(
              id: 'anchor',
              cardId: 'card-a',
              revisionId: 'revision',
              pageIndex: 0,
              quads: [PdfQuad.rect(10, 10, 30, 20)],
            ),
          ],
        },
        edges: base.edges,
      );
      final activated = <String>[];
      final actions = <String>[];
      final links = <(String, String)>[];
      final created = <Offset>[];
      await tester.pumpWidget(
        _host(
          snapshot,
          controller,
          onActivate: (node) => activated.add(node.id),
          onAction: (_, action) => actions.add(action),
          onAssociate: (from, to) async => links.add((from, to)),
          onCreateAt: created.add,
        ),
      );
      await tester.pumpAndSettle();
      controller.setView(scale: 1, worldTopLeft: const Offset(-200, -180));
      await tester.pump();
      await _timedNodeClick(tester, 'a', down: 100, up: 110);
      await tester.pump();
      final point = switch (interrupt) {
        'fold' => tester.getCenter(
          find.byKey(const ValueKey('map-collapse-a')),
        ),
        'source' => _nodeHitPoint(tester, 'a'),
        'context' => _nodeHitPoint(tester, 'a'),
        'association' => tester.getCenter(find.byTooltip('更多脑图工具')),
        _ => const Offset(700, 500),
      };
      final button = _timestampGesture(
        tester,
        buttons: interrupt == 'context' || interrupt == 'source'
            ? kSecondaryMouseButton
            : kPrimaryMouseButton,
      );
      await button.down(point, timeStamp: const Duration(milliseconds: 200));
      await button.up(timeStamp: const Duration(milliseconds: 210));
      if (interrupt == 'source') {
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('map-menu-source')));
        await tester.pumpAndSettle();
      } else if (interrupt == 'association') {
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('map-tool-association')));
        await waitForMapToolsClosed(tester);
      } else if (interrupt == 'context') {
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('map-menu-newChild')), findsOneWidget);
        expect(find.text('Tab'), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
      } else {
        await tester.pump();
      }
      if (interrupt == 'association') {
        await _timedNodeClick(tester, 'b', down: 230, up: 240);
        await tester.pumpAndSettle();
        expect(links, [('a', 'b')]);
      }
      await _timedNodeClick(tester, 'a', down: 250, up: 260);
      expect(activated, ['a', 'a'], reason: interrupt);
      expect(
        actions.where((action) => action == 'edit'),
        isEmpty,
        reason: interrupt,
      );
      if (interrupt == 'source') expect(actions, ['source']);
      await tester.pump(kDoubleTapTimeout);
      expect(created, isEmpty, reason: '一次空白点击不能被误判为新主题双击');
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull, reason: interrupt);
    }
  });

  testWidgets('卡片双击编辑：用户滚轮打断候选而程序定位保留正常双击', (tester) async {
    final controller = MindMapPaneController();
    final activated = <String>[];
    final actions = <String>[];
    await tester.pumpWidget(
      _host(
        _withNodes(_snapshot(), [_snapshot().nodes.first]),
        controller,
        onActivate: (node) => activated.add(node.id),
        onAction: (_, action) => actions.add(action),
      ),
    );
    await tester.pumpAndSettle();
    controller.setView(scale: 1, worldTopLeft: const Offset(-200, -180));
    await tester.pump();
    await _timedNodeClick(tester, 'a', down: 100, up: 110);
    final oldScale = controller.scale;
    await tester.sendEventToBinding(
      PointerScrollEvent(
        timeStamp: const Duration(milliseconds: 150),
        kind: PointerDeviceKind.mouse,
        position: _nodeHitPoint(tester, 'a'),
        scrollDelta: const Offset(0, -20),
      ),
    );
    await tester.pump();
    expect(controller.scale, isNot(oldScale));
    await _timedNodeClick(tester, 'a', down: 210, up: 220);
    expect(activated, ['a', 'a']);
    expect(actions, isEmpty);
    controller.setView(scale: 1, worldTopLeft: const Offset(-200, -180));
    await tester.pump();
    await _timedNodeClick(tester, 'a', down: 300, up: 310);
    expect(actions, ['edit'], reason: '程序定位不等于用户滚轮或平移，不能清掉有效点击对');
    expect(activated, ['a', 'a']);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('卡片双击编辑：按住时换图和失效节点不编辑，控制器换绑不继承候选', (tester) async {
    for (final interrupt in ['map', 'removed', 'controller']) {
      var controller = MindMapPaneController();
      var snapshot = _withNodes(_snapshot(), [_snapshot().nodes.first]);
      late StateSetter refresh;
      final activated = <String>[];
      final actions = <String>[];
      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, setState) {
            refresh = setState;
            return _host(
              snapshot,
              controller,
              onActivate: (node) => activated.add(node.id),
              onAction: (_, action) => actions.add(action),
            );
          },
        ),
      );
      await tester.pumpAndSettle();
      controller.setView(scale: 1, worldTopLeft: const Offset(-200, -180));
      await tester.pump();
      await _timedNodeClick(tester, 'a', down: 100, up: 110);
      if (interrupt == 'controller') {
        refresh(() => controller = MindMapPaneController());
        await tester.pump();
        await _timedNodeClick(tester, 'a', down: 190, up: 200);
        expect(activated, ['a', 'a']);
      } else {
        final second = _timestampGesture(tester);
        await second.down(
          _nodeHitPoint(tester, 'a'),
          timeStamp: const Duration(milliseconds: 190),
        );
        refresh(() {
          snapshot = interrupt == 'map'
              ? MapSnapshot(
                  map: const MindMap(
                    layout: MapLayoutKind.free,
                    id: 'new-map',
                    projectId: 'project',
                    title: '另一脑图',
                  ),
                  nodes: [_copyNodeAt(snapshot.nodes.single, mapId: 'new-map')],
                  cards: snapshot.cards,
                  anchors: snapshot.anchors,
                  edges: snapshot.edges,
                )
              : _withNodes(snapshot, []);
        });
        await tester.pump();
        await second.up(timeStamp: const Duration(milliseconds: 200));
        expect(activated, ['a']);
      }
      expect(actions, isEmpty, reason: interrupt);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull, reason: interrupt);
    }
  });

  for (final scale in [.25, .375, .5, 1.0]) {
    final percent = scale * 100;
    final scaleLabel = percent == percent.truncateToDouble()
        ? percent.toInt().toString()
        : percent.toString();
    for (final dpr in [1.0, 1.5]) {
      testWidgets('屏幕比例快照：$scaleLabel% DPR$dpr 中英字形实际像素与纹理尺寸', (tester) async {
        tester.view.devicePixelRatio = dpr;
        tester.view.physicalSize = Size(800 * dpr, 600 * dpr);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        await tester.runAsync(_loadSnapshotPixelFonts);
        final boundary = GlobalKey();
        final controller = MindMapPaneController();
        final original = _withNodes(_snapshot(), [_snapshot().nodes.first]);
        final snapshot = _withCardVisuals(
          original,
          'card-a',
          title: '知识卡片 Note 007',
          body: '离线阅读与独立摘录。\nText snapshots keep real glyphs.\n正文保持原始样式。',
          note: '中文备注 Snapshot',
        );
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: _host(
              snapshot,
              controller,
              selectedNodeId: 'a',
              theme: ThemeData(
                fontFamily: 'OpenNotePixelSegoe',
                fontFamilyFallback: const ['OpenNotePixelYaHei'],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        controller.setView(
          scale: scale,
          worldTopLeft: Offset(-200 / scale, -200 / scale),
        );
        await tester.pump();
        final gestureState = tester.state(_nodeGesture('a'));
        final tileBox = tester.renderObject<RenderBox>(_mapNode('a'));
        final originalData = MediaQuery.of(
          tester.element(find.byType(MindMapPane)),
        );
        final name = 'screen-$scaleLabel-dpr-$dpr';
        final livePixels = await _nodePixels(
          tester,
          boundary,
          'a',
          evidenceName: '$name-live',
        );
        final created = <Size>[];
        final previousCreate = ui.Image.onCreate;
        ui.Image.onCreate = (image) {
          previousCreate?.call(image);
          created.add(Size(image.width.toDouble(), image.height.toDouble()));
        };
        addTearDown(() => ui.Image.onCreate = previousCreate);
        final mouse = await tester.startGesture(
          _nodeHitPoint(tester, 'a'),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump();
        expect(tester.state(_nodeGesture('a')), same(gestureState));
        // 24 个逻辑像素在两种实际 DPI 下均为整数物理像素，排除落点相位变化。
        await mouse.moveBy(const Offset(24, 0));
        await tester.pump();
        final captureData = MediaQuery.of(
          tester.element(
            find.ancestor(
              of: _mapNode('a'),
              matching: find.byType(SnapshotWidget),
            ),
          ),
        );
        final captureDpr = dpr * scale;
        final node = snapshot.nodes.single;
        final texture = Size(
          (node.width * captureDpr).ceilToDouble(),
          (node.height * captureDpr).ceilToDouble(),
        );
        expect(_nodeSnapshot(tester, 'a').controller.allowSnapshotting, isTrue);
        expect(captureData.devicePixelRatio, closeTo(captureDpr, .000001));
        expect(captureData.size, originalData.size);
        expect(captureData.textScaler, originalData.textScaler);
        expect(captureData.gestureSettings, originalData.gestureSettings);
        expect(created, contains(texture), reason: '读取公开 ui.Image 创建事件的真实纹理尺寸');
        expect(tester.state(_nodeGesture('a')), same(gestureState));
        expect(tester.renderObject<RenderBox>(_mapNode('a')), same(tileBox));
        debugPrint(
          'MAP_SNAPSHOT_CAPTURE $name: viewDpr=$dpr, scale=$scale, captureDpr=${captureData.devicePixelRatio}, createdTextures=$created, rawBytes=${texture.width * texture.height * 4}',
        );
        final cachedPixels = await _nodePixels(
          tester,
          boundary,
          'a',
          evidenceName: '$name-cached',
        );
        await _pixelMask(
          tester,
          'a',
          livePixels,
          cachedPixels,
          '$name-live-cached-mask',
        );
        expect(
          _pixelDifference(livePixels, cachedPixels),
          lessThan(.025),
          reason: '按实际屏幕 DPI 比较原字体向量绘制与屏幕比例纹理，不能降低比较分辨率',
        );
        await mouse.cancel();
        await tester.pump();
        expect(
          _nodeSnapshot(tester, 'a').controller.allowSnapshotting,
          isFalse,
        );
        expect(
          MediaQuery.devicePixelRatioOf(tester.element(_mapNode('a'))),
          originalData.devicePixelRatio,
        );
        await tester.pumpWidget(const SizedBox());
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('屏幕比例快照：同次鼠标手势缩放重新捕获并在放大时恢复实时像素', (tester) async {
    tester.view.devicePixelRatio = 1.5;
    tester.view.physicalSize = const Size(1200, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final boundary = GlobalKey();
    final controller = MindMapPaneController();
    final snapshot = _withNodes(_snapshot(), [_snapshot().nodes.first]);
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: _host(snapshot, controller, selectedNodeId: 'a'),
      ),
    );
    await tester.pumpAndSettle();
    controller.setView(scale: .25, worldTopLeft: const Offset(-800, -800));
    await tester.pump();
    final gestureState = tester.state(_nodeGesture('a'));
    final created = <Size>[];
    final previousCreate = ui.Image.onCreate;
    ui.Image.onCreate = (image) {
      previousCreate?.call(image);
      created.add(Size(image.width.toDouble(), image.height.toDouble()));
    };
    addTearDown(() => ui.Image.onCreate = previousCreate);
    final mouse = await tester.startGesture(
      _nodeHitPoint(tester, 'a'),
      kind: PointerDeviceKind.mouse,
    );
    await mouse.moveBy(const Offset(24, 0));
    await tester.pump();
    expect(_nodeSnapshot(tester, 'a').controller.allowSnapshotting, isTrue);
    expect(created, contains(const Size(83, 44)));
    created.clear();
    controller.setView(scale: .5, worldTopLeft: const Offset(-350, -360));
    await tester.pump();
    expect(tester.state(_nodeGesture('a')), same(gestureState));
    expect(MediaQuery.devicePixelRatioOf(tester.element(_mapNode('a'))), .75);
    expect(created, contains(const Size(165, 87)));
    created.clear();
    controller.setView(scale: 1, worldTopLeft: const Offset(-104, -180));
    await tester.pump();
    expect(MediaQuery.devicePixelRatioOf(tester.element(_mapNode('a'))), 1.5);
    expect(created, contains(const Size(330, 174)), reason: '不能上采样旧的小纹理');
    final fullSizePixels = await _nodePixels(
      tester,
      boundary,
      'a',
      evidenceName: 'screen-scale-change-cached',
    );
    created.clear();
    controller.setView(scale: 1.25, worldTopLeft: const Offset(-64, -144));
    await tester.pump();
    expect(_nodeSnapshot(tester, 'a').controller.allowSnapshotting, isFalse);
    expect(MediaQuery.devicePixelRatioOf(tester.element(_mapNode('a'))), 1.5);
    expect(created, isEmpty, reason: '放大后仅真实绘制，不创建并放大缓存纹理');
    expect(tester.state(_nodeGesture('a')), same(gestureState));
    await mouse.cancel();
    await tester.pump();
    controller.setView(scale: 1, worldTopLeft: const Offset(-200, -180));
    await tester.pump();
    final liveFullSizePixels = await _nodePixels(
      tester,
      boundary,
      'a',
      evidenceName: 'screen-scale-change-live',
    );
    await _pixelMask(
      tester,
      'a',
      fullSizePixels,
      liveFullSizePixels,
      'screen-scale-change-mask',
    );
    expect(
      _pixelDifference(fullSizePixels, liveFullSizePixels),
      lessThan(.025),
    );
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('拖动像素快照：25%未选卡按下后绘制再移动保持原识别器并提交一次', (tester) async {
    final controller = MindMapPaneController();
    final submissions = <(String, double, double)>[];
    await tester.pumpWidget(
      _host(
        _withNodes(_snapshot(), [_snapshot().nodes.first]),
        controller,
        onMove: (id, x, y) async => submissions.add((id, x, y)),
      ),
    );
    await tester.pumpAndSettle();
    controller.setView(scale: .25, worldTopLeft: const Offset(-800, -800));
    await tester.pump();
    final start = _nodeHitPoint(tester, 'a');
    final gestureState = tester.state(_nodeGesture('a'));
    final tileBox = tester.renderObject<RenderBox>(_mapNode('a'));
    final mouse = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    expect(
      tester.state(_nodeGesture('a')),
      same(gestureState),
      reason: '按下选中后的独立绘制帧不能换掉仍跟踪鼠标的识别器',
    );
    expect(tester.renderObject<RenderBox>(_mapNode('a')), same(tileBox));
    await mouse.moveBy(const Offset(30, 0));
    await tester.pump();
    await mouse.moveBy(const Offset(20, 15));
    await tester.pump();
    expect(
      (tester.getCenter(_mapNode('a')) - start - const Offset(50, 15)).distance,
      lessThan(.01),
    );
    await mouse.up();
    await tester.pumpAndSettle();
    expect(submissions, hasLength(1));
    expect(submissions.single, ('a', 200, 60));
    expect(tester.takeException(), isNull);
  });

  testWidgets('拖动像素快照：正文颜色实时更新，识别器保持，取消继续与权威撤销无残留', (tester) async {
    final boundary = GlobalKey();
    final controller = MindMapPaneController();
    final original = _withNodes(_snapshot(), [_snapshot().nodes.first]);
    var snapshot = _withCardVisuals(
      original,
      'card-a',
      title: 'Original title',
      body: 'Old body',
      note: 'Original note',
    );
    late StateSetter refresh;
    final submissions = <(String, double, double)>[];
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: StatefulBuilder(
          builder: (context, setState) {
            refresh = setState;
            return _host(
              snapshot,
              controller,
              selectedNodeId: 'a',
              onMove: (id, x, y) async {
                submissions.add((id, x, y));
                setState(
                  () => snapshot = _applyPositions(snapshot, {
                    id: PdfPoint(x, y),
                  }),
                );
              },
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    controller.setView(scale: 1, worldTopLeft: const Offset(-200, -180));
    await tester.pump();
    final start = _nodeHitPoint(tester, 'a');
    final position = tester.widget<Positioned>(
      find.byKey(const ValueKey('map-position-a')),
    );
    final tileElement = tester.element(_mapNode('a'));
    final tileBox = tester.renderObject<RenderBox>(_mapNode('a'));
    final gestureState = tester.state(_nodeGesture('a'));
    final livePixels = await _nodePixels(
      tester,
      boundary,
      'a',
      evidenceName: 'text-live',
    );
    final mouse = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await mouse.moveBy(const Offset(30, 0));
    await tester.pump();
    await mouse.moveBy(const Offset(40, 20));
    await tester.pump();
    final cachedPixels = await _nodePixels(
      tester,
      boundary,
      'a',
      evidenceName: 'text-cached',
    );
    await _pixelMask(
      tester,
      'a',
      livePixels,
      cachedPixels,
      'text-live-cached-mask',
    );
    expect(
      _pixelDifference(livePixels, cachedPixels),
      lessThan(.025),
      reason: '拖动保留完整标题、正文、备注、颜色与主选样式',
    );
    expect(tester.element(_mapNode('a')), same(tileElement));
    expect(tester.renderObject<RenderBox>(_mapNode('a')), same(tileBox));
    expect(tester.state(_nodeGesture('a')), same(gestureState));
    expect(_nodeSnapshot(tester, 'a').controller.allowSnapshotting, isTrue);
    final movedCenter = tester.getCenter(_mapNode('a'));
    refresh(
      () => snapshot = _withCardVisuals(
        snapshot,
        'card-a',
        title: 'Changed much longer title',
        body: 'New body with substantially different visible text',
        note: 'New note with different length',
        color: '#31BC77',
      ),
    );
    await tester.pump();
    final changedPixels = await _nodePixels(
      tester,
      boundary,
      'a',
      evidenceName: 'text-changed',
    );
    expect(_pixelDifference(cachedPixels, changedPixels), greaterThan(.02));
    expect(tester.getCenter(_mapNode('a')), movedCenter);
    expect(tester.state(_nodeGesture('a')), same(gestureState));
    await mouse.moveBy(const Offset(10, 10));
    await tester.pump();
    expect(
      (tester.getCenter(_mapNode('a')) - movedCenter - const Offset(10, 10))
          .distance,
      lessThan(.01),
      reason: '正文更新后原鼠标手势仍在移动',
    );
    await mouse.cancel();
    await tester.pump();
    expect(submissions, isEmpty);
    expect(tester.getCenter(_mapNode('a')), start);
    expect(_nodeSnapshot(tester, 'a').controller.allowSnapshotting, isFalse);
    expect(
      _pixelDifference(changedPixels, await _nodePixels(tester, boundary, 'a')),
      lessThan(.025),
      reason: '退出快照后的真实正文与更新快照一致',
    );

    final continued = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await continued.moveBy(const Offset(30, 0));
    await tester.pump();
    await continued.moveBy(const Offset(40, 20));
    await tester.pump();
    expect(tester.state(_nodeGesture('a')), same(gestureState));
    await continued.up();
    await tester.pumpAndSettle();
    expect(submissions, hasLength(1));
    expect(submissions.single.$1, 'a');
    expect(submissions.single.$2, closeTo(70, .01));
    expect(submissions.single.$3, closeTo(20, .01));
    expect(_nodeSnapshot(tester, 'a').controller.allowSnapshotting, isFalse);
    refresh(() => snapshot = _withNodes(snapshot, original.nodes));
    await tester.pump();
    final restored = tester.widget<Positioned>(
      find.byKey(const ValueKey('map-position-a')),
    );
    expect(restored.left, position.left);
    expect(restored.top, position.top);
    expect(tester.getCenter(_mapNode('a')), start);
    expect(tester.state(_nodeGesture('a')), same(gestureState));
    expect(
      _pixelDifference(changedPixels, await _nodePixels(tester, boundary, 'a')),
      lessThan(.025),
    );
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('拖动像素快照：主题失效与文字缩放和默认字形更新保留手势', (tester) async {
    await tester.runAsync(() async {
      final font = FontLoader('MaterialIcons');
      font.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await font.load();
    });
    final boundary = GlobalKey();
    final controller = MindMapPaneController();
    final snapshot = _withCardVisuals(
      _snapshot(),
      'card-a',
      body: 'ABCDE abcde',
      note: 'Changed font sample',
    );
    var theme = ThemeData();
    var scaler = TextScaler.noScaling;
    var textStyle = const TextStyle(fontStyle: FontStyle.normal);
    late StateSetter refresh;
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: StatefulBuilder(
          builder: (context, setState) {
            refresh = setState;
            return _host(
              snapshot,
              controller,
              selectedNodeId: 'a',
              theme: theme,
              textScaler: scaler,
              defaultTextStyle: textStyle,
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    controller.setView(scale: 1, worldTopLeft: const Offset(-200, -180));
    await tester.pump();
    expect(find.byKey(const ValueKey('map-collapse-a')), findsOneWidget);
    Future<void> checkUpdate(String name, VoidCallback update) async {
      final gestureState = tester.state(_nodeGesture('a'));
      final mouse = await tester.startGesture(
        _nodeHitPoint(tester, 'a'),
        kind: PointerDeviceKind.mouse,
      );
      await mouse.moveBy(const Offset(30, 0));
      await tester.pump();
      expect(_nodeSnapshot(tester, 'a').controller.allowSnapshotting, isTrue);
      final before = await _nodePixels(
        tester,
        boundary,
        'a',
        evidenceName: '$name-before',
      );
      refresh(update);
      await tester.pump();
      final snapshottingAfterUpdate = _nodeSnapshot(
        tester,
        'a',
      ).controller.allowSnapshotting;
      expect(tester.state(_nodeGesture('a')), same(gestureState));
      // 保持原鼠标按住，等待按钮自身200ms动画结束；不能固化动画起点。
      await tester.pumpAndSettle();
      final updated = await _nodePixels(
        tester,
        boundary,
        'a',
        evidenceName: '$name-updated',
      );
      await _pixelMask(tester, 'a', before, updated, '$name-updated-mask');
      final snapshottingAfterAnimation = _nodeSnapshot(
        tester,
        'a',
      ).controller.allowSnapshotting;
      expect(find.byKey(const ValueKey('map-collapse-a')), findsOneWidget);
      final center = tester.getCenter(_mapNode('a'));
      await mouse.moveBy(const Offset(10, 10));
      await tester.pump();
      expect(
        (tester.getCenter(_mapNode('a')) - center - const Offset(10, 10))
            .distance,
        lessThan(.01),
      );
      expect(tester.state(_nodeGesture('a')), same(gestureState));
      final snapshottingAfterMove = _nodeSnapshot(
        tester,
        'a',
      ).controller.allowSnapshotting;
      await mouse.cancel();
      await tester.pump();
      final liveAfterUpdate = await _nodePixels(
        tester,
        boundary,
        'a',
        evidenceName: '$name-live-after-update',
      );
      await _pixelMask(
        tester,
        'a',
        before,
        liveAfterUpdate,
        '$name-before-live-mask',
      );
      await _pixelMask(
        tester,
        'a',
        updated,
        liveAfterUpdate,
        '$name-cached-live-mask',
      );
      // 分开保留本帧与内部按钮动画结束后的实时画面，避免把主题动画当静态像素。
      await tester.pumpAndSettle();
      final liveSettled = await _nodePixels(
        tester,
        boundary,
        'a',
        evidenceName: '$name-live-settled',
      );
      await _pixelMask(
        tester,
        'a',
        before,
        liveSettled,
        '$name-before-live-settled-mask',
      );
      debugPrint(
        'MAP_PIXEL_DEPENDENCY $name: cachedChange=${_pixelDifference(before, updated)}, liveChange=${_pixelDifference(before, liveAfterUpdate)}, settledLiveChange=${_pixelDifference(before, liveSettled)}',
      );
      if (name == 'theme') {
        expect(
          _pixelDifference(before, updated),
          lessThan(.001),
          reason: '卡片不再包含主题色 IconButton；外侧控件不进入节点纹理，缓存仍须失效',
        );
      } else {
        expect(
          _pixelDifference(before, updated),
          greaterThan(.001),
          reason: '文字缩放与默认字形应改变真实正文像素',
        );
      }
      expect(snapshottingAfterUpdate, isFalse);
      expect(snapshottingAfterAnimation, isFalse);
      expect(snapshottingAfterMove, isFalse);
      expect(
        _pixelDifference(updated, liveAfterUpdate),
        lessThan(.025),
        reason: '缓存画面与最新实时绘制一致',
      );
      final next = await tester.startGesture(
        _nodeHitPoint(tester, 'a'),
        kind: PointerDeviceKind.mouse,
      );
      await next.moveBy(const Offset(30, 0));
      await tester.pump();
      expect(
        _nodeSnapshot(tester, 'a').controller.allowSnapshotting,
        isTrue,
        reason: '下一次稳定手势恢复像素复用',
      );
      expect(tester.state(_nodeGesture('a')), same(gestureState));
      await next.cancel();
      await tester.pump();
    }

    await checkUpdate('theme', () {
      theme = ThemeData(
        iconButtonTheme: const IconButtonThemeData(
          style: ButtonStyle(
            foregroundColor: WidgetStatePropertyAll(Color(0xFFFF0000)),
          ),
        ),
      );
    });
    await checkUpdate('text-scaler', () => scaler = TextScaler.linear(1.25));
    await checkUpdate(
      'default-text-style',
      () => textStyle = const TextStyle(fontStyle: FontStyle.italic),
    );
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('拖动像素快照：放大保持实时，DPR与节点尺寸变化不改命中和拖动状态', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final boundary = GlobalKey();
    final controller = MindMapPaneController();
    var snapshot = _withNodes(_snapshot(), [_snapshot().nodes.first]);
    late StateSetter refresh;
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: StatefulBuilder(
          builder: (context, setState) {
            refresh = setState;
            return _host(snapshot, controller, selectedNodeId: 'a');
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    controller.setView(scale: 1.25, worldTopLeft: const Offset(-160, -144));
    await tester.pump();
    final gestureState = tester.state(_nodeGesture('a'));
    final mouse = await tester.startGesture(
      _nodeHitPoint(tester, 'a'),
      kind: PointerDeviceKind.mouse,
    );
    await mouse.moveBy(const Offset(30, 0));
    await tester.pump();
    expect(_nodeSnapshot(tester, 'a').controller.allowSnapshotting, isFalse);
    final before = await _nodePixels(tester, boundary, 'a');
    refresh(
      () => snapshot = _withCardVisuals(
        snapshot,
        'card-a',
        body: 'Bigger live text contains different glyphs',
        color: '#CC44AA',
      ),
    );
    await tester.pump();
    expect(
      _pixelDifference(before, await _nodePixels(tester, boundary, 'a')),
      greaterThan(.02),
    );
    controller.setView(scale: 1, worldTopLeft: const Offset(-200, -180));
    await tester.pump();
    expect(_nodeSnapshot(tester, 'a').controller.allowSnapshotting, isTrue);
    final bounds = tester.getRect(_mapNode('a'));
    tester.view.devicePixelRatio = 1.5;
    tester.view.physicalSize = const Size(1200, 900);
    await tester.pump();
    expect(tester.getRect(_mapNode('a')), bounds);
    expect(tester.state(_nodeGesture('a')), same(gestureState));
    final highDpr = await _nodePixels(
      tester,
      boundary,
      'a',
      evidenceName: 'dpr-cached',
    );
    await mouse.cancel();
    await tester.pump();
    final highDprLive = await _nodePixels(
      tester,
      boundary,
      'a',
      evidenceName: 'dpr-live',
    );
    await _pixelMask(tester, 'a', highDpr, highDprLive, 'dpr-live-cached-mask');
    expect(_pixelDifference(highDpr, highDprLive), lessThan(.025));
    final resized = await tester.startGesture(
      _nodeHitPoint(tester, 'a'),
      kind: PointerDeviceKind.mouse,
    );
    await resized.moveBy(const Offset(30, 0));
    await tester.pump();
    final node = snapshot.nodes.single;
    refresh(
      () => snapshot = _withNodes(snapshot, [
        MapNode(
          id: node.id,
          mapId: node.mapId,
          cardId: node.cardId,
          x: node.x,
          y: node.y,
          width: 260,
          height: 140,
        ),
      ]),
    );
    await tester.pump();
    expect(tester.getSize(_mapNode('a')), const Size(260, 140));
    expect(tester.state(_nodeGesture('a')), same(gestureState));
    final resizedPixels = await _nodePixels(tester, boundary, 'a');
    await resized.cancel();
    await tester.pump();
    expect(
      _pixelDifference(resizedPixels, await _nodePixels(tester, boundary, 'a')),
      lessThan(.025),
    );
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('拖动像素快照：图片的待完成资源继续加载，缩略图状态和真实红色像素保留', (tester) async {
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('opennote-map-drag-image-'),
    ))!;
    try {
      final path = '${directory.path}${Platform.pathSeparator}拖动.png';
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawRect(
          const Rect.fromLTWH(0, 0, 16, 16),
          Paint()..color = const Color(0xFFFF0000),
        );
        final picture = recorder.endRecording();
        final image = await picture.toImage(16, 16);
        try {
          final bytes = (await image.toByteData(
            format: ui.ImageByteFormat.png,
          ))!;
          await File(path).writeAsBytes(bytes.buffer.asUint8List());
        } finally {
          image.dispose();
          picture.dispose();
        }
      });
      final boundary = GlobalKey();
      final controller = MindMapPaneController();
      final completion = Completer<String>();
      final requests = <String>[];
      final snapshot = MapSnapshot(
        map: _snapshot().map,
        nodes: const [
          MapNode(id: 'image', mapId: 'map', cardId: 'image-card', x: 0, y: 0),
        ],
        cards: {'image-card': _imageCard('image-card', 'delayed')},
        anchors: const {},
        edges: const [],
      );
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: _host(
            snapshot,
            controller,
            selectedNodeId: 'image',
            imagePathResolver: (id) {
              requests.add(id);
              return completion.future;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      controller.setView(scale: 1, worldTopLeft: const Offset(-200, -180));
      await tester.pump();
      expect(find.text('载入图片…'), findsOneWidget);
      final thumbnail = find.descendant(
        of: _mapNode('image'),
        matching: find.byType(FutureBuilder<String>),
      );
      expect(thumbnail, findsOneWidget);
      final thumbnailState = tester.state(thumbnail);
      final gestureState = tester.state(_nodeGesture('image'));
      final mouse = await tester.startGesture(
        _nodeHitPoint(tester, 'image'),
        kind: PointerDeviceKind.mouse,
      );
      await mouse.moveBy(const Offset(30, 0));
      await tester.pump();
      expect(
        _nodeSnapshot(tester, 'image').controller.allowSnapshotting,
        isFalse,
      );
      completion.complete(path);
      await tester.pump();
      final raw = find.descendant(
        of: find.byKey(const ValueKey('map-image-delayed')),
        matching: find.byType(RawImage),
      );
      for (var attempt = 0; attempt < 40; attempt++) {
        if (raw.evaluate().isNotEmpty &&
            tester.renderObject<RenderImage>(raw).image != null) {
          break;
        }
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
      expect(tester.renderObject<RenderImage>(raw).image, isNotNull);
      expect(
        _redPixels(await _nodePixels(tester, boundary, 'image')),
        greaterThan(100),
      );
      expect(tester.state(thumbnail), same(thumbnailState));
      expect(tester.state(_nodeGesture('image')), same(gestureState));
      await mouse.moveBy(const Offset(30, 20));
      await tester.pump();
      expect(
        _redPixels(await _nodePixels(tester, boundary, 'image')),
        greaterThan(100),
      );
      expect(requests, ['delayed']);
      await mouse.cancel();
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await directory.delete(recursive: true);
      });
    }
  });

  testWidgets('脑图移动快照：未完成提交保预览，成功后迟到快照和跳过确认帧的撤销接管', (tester) async {
    final controller = MindMapPaneController();
    final original = _groupSnapshot();
    var snapshot = original;
    late StateSetter refresh;
    var completion = Completer<void>();
    final submissions = <Map<String, PdfPoint>>[];
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) {
          refresh = setState;
          return _host(
            snapshot,
            controller,
            selectedNodeId: 'b',
            selectedNodeIds: const {'a', 'b'},
            onMoveGroup: (positions) async {
              submissions.add(Map.of(positions));
              await completion.future;
            },
          );
        },
      ),
    );
    await tester.pumpAndSettle();
    controller.setView(scale: .75);
    await tester.pump();
    final centers = {
      for (final id in ['a', 'b']) id: tester.getCenter(_mapNode(id)),
    };
    final positioned = {
      for (final id in ['a', 'b'])
        id: tester.widget<Positioned>(find.byKey(ValueKey('map-position-$id'))),
    };
    final progress = find.descendant(
      of: find.byType(MindMapPane),
      matching: find.byType(LinearProgressIndicator),
    );
    Future<void> drag() async {
      final mouse = await tester.startGesture(
        tester.getCenter(_mapNode('a')),
        kind: PointerDeviceKind.mouse,
      );
      await mouse.moveBy(const Offset(30, 0));
      await tester.pump();
      await mouse.moveBy(const Offset(45, 30));
      await tester.pump();
      await mouse.up();
      await tester.pump();
    }

    await drag();
    expect(submissions, hasLength(1));
    expect(submissions.single.keys.toSet(), {'a', 'b', 'c', 'd'});
    expect(progress, findsOneWidget);
    refresh(() => snapshot = _withCardBody(snapshot, 'card-a', '提交期间的后台正文刷新'));
    await tester.pump();
    for (final id in centers.keys) {
      expect(
        (tester.getCenter(_mapNode(id)) - centers[id]! - const Offset(75, 30))
            .distance,
        lessThan(.01),
        reason: '未完成的命令不能被旧模型正文刷新抹去预览',
      );
    }
    completion.complete();
    await tester.pumpAndSettle();
    expect(progress, findsNothing);
    final held = await tester.startGesture(
      tester.getCenter(_mapNode('a')),
      kind: PointerDeviceKind.mouse,
    );
    await held.moveBy(const Offset(30, 0));
    await tester.pump();
    await held.moveBy(const Offset(45, 30));
    await tester.pump();
    refresh(() => snapshot = _withCardBody(snapshot, 'card-a', '新手势期间的后台刷新'));
    await tester.pump();
    for (final id in centers.keys) {
      expect(
        (tester.getCenter(_mapNode(id)) - centers[id]! - const Offset(150, 60))
            .distance,
        lessThan(.01),
        reason: '新的按住拖动也必须保留起点所包含的已接受预览',
      );
    }
    await held.cancel();
    await tester.pump();
    expect(submissions, hasLength(1), reason: '取消的新手势没有提交第二个命令');
    for (final id in centers.keys) {
      expect(
        (tester.getCenter(_mapNode(id)) - centers[id]! - const Offset(75, 30))
            .distance,
        lessThan(.01),
        reason: '真实PointerCancel仅撤销当前手势预览，保留先前已接受的移动',
      );
    }
    // 模拟提交已成功，但它的确认快照被后台刷新合并；下一个权威快照直接是撤销。
    refresh(() => snapshot = _withNodes(snapshot, original.nodes));
    await tester.pump();
    for (final id in centers.keys) {
      final actual = tester.widget<Positioned>(
        find.byKey(ValueKey('map-position-$id')),
      );
      expect(
        actual.left,
        positioned[id]!.left,
        reason: '成功旧命令的pending不能覆盖后续撤销坐标',
      );
      expect(actual.top, positioned[id]!.top);
      expect(
        (tester.getCenter(_mapNode(id)) - centers[id]!).distance,
        lessThan(.01),
      );
    }

    completion = Completer<void>();
    await drag();
    expect(submissions, hasLength(2));
    completion.complete();
    await tester.pumpAndSettle();
    refresh(() => snapshot = _applyPositions(snapshot, submissions.last));
    await tester.pump();
    for (final id in centers.keys) {
      expect(
        (tester.getCenter(_mapNode(id)) - centers[id]! - const Offset(75, 30))
            .distance,
        lessThan(.01),
        reason: '迟到的成功快照应无跳动地接管预览',
      );
    }
    refresh(() => snapshot = _withNodes(snapshot, original.nodes));
    await tester.pump();
    for (final id in centers.keys) {
      final actual = tester.widget<Positioned>(
        find.byKey(ValueKey('map-position-$id')),
      );
      expect(actual.left, positioned[id]!.left);
      expect(actual.top, positioned[id]!.top);
      expect(
        (tester.getCenter(_mapNode(id)) - centers[id]!).distance,
        lessThan(.01),
      );
    }
    expect(submissions, hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('脑图多选：连续Ctrl完整点击按最新集合切换且不激活', (tester) async {
    final controller = MindMapPaneController();
    final toggled = <String>[];
    final selected = <String>[];
    final activated = <String>[];
    var ids = <String>{};
    String? primary;
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) {
          return _host(
            _snapshot(),
            controller,
            selectedNodeId: primary,
            selectedNodeIds: ids,
            onSelect: (node) {
              selected.add(node.id);
              setState(() {
                ids = {node.id};
                primary = node.id;
              });
            },
            onToggleSelection: (node) {
              toggled.add(node.id);
              setState(() {
                ids = Set.of(ids);
                if (ids.remove(node.id)) {
                  if (primary == node.id) primary = ids.lastOrNull;
                } else {
                  ids.add(node.id);
                  primary = node.id;
                }
              });
            },
            onActivate: (node) => activated.add(node.id),
          );
        },
      ),
    );
    await tester.pumpAndSettle();
    controller.setView(scale: 1);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    for (final id in ['a', 'b', 'a']) {
      final click = await tester.startGesture(
        tester.getCenter(_mapNode(id)),
        kind: PointerDeviceKind.mouse,
      );
      await click.up();
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(toggled, ['a', 'b', 'a']);
    expect(ids, {'b'});
    expect(primary, 'b');
    expect(selected, isEmpty);
    expect(activated, isEmpty);
    expect(_mapSemantics(tester, 'a').properties.selected, isFalse);
    expect(_mapSemantics(tester, 'b').properties.value, '主选');
    expect(_mapBorder(tester, 'b').top.width, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('脑图多选：Ctrl提前松开及同ID正文刷新仍只切换一次，拖动取消不切换', (tester) async {
    final controller = MindMapPaneController();
    final toggled = <String>[];
    final selected = <String>[];
    final activated = <String>[];
    final moves = <String>[];
    var snapshot = _snapshot();
    late StateSetter refresh;
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) {
          refresh = setState;
          return _host(
            snapshot,
            controller,
            selectedNodeId: 'a',
            selectedNodeIds: const {'a'},
            onToggleSelection: (node) => toggled.add(node.id),
            onSelect: (node) => selected.add(node.id),
            onActivate: (node) => activated.add(node.id),
            onMove: (id, _, _) async => moves.add(id),
          );
        },
      ),
    );
    await tester.pumpAndSettle();
    controller.setView(scale: 1);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    final click = await tester.startGesture(
      tester.getCenter(_mapNode('b')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    refresh(() => snapshot = _withCardBody(snapshot, 'card-b', '后台OCR刷新后的正文'));
    await tester.pump();
    await click.up();
    await tester.pumpAndSettle();
    expect(toggled, ['b']);
    expect(selected, isEmpty);
    expect(activated, isEmpty);
    expect(_mapSemantics(tester, 'a').properties.value, '已选');
    expect(_mapSemantics(tester, 'b').properties.value, '主选');
    expect(_mapBorder(tester, 'a').top.width, 1.25);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    final cancelled = await tester.startGesture(
      tester.getCenter(_mapNode('c')),
      kind: PointerDeviceKind.mouse,
    );
    await cancelled.cancel();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(toggled, ['b']);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    final drag = await tester.startGesture(
      tester.getCenter(_mapNode('c')),
      kind: PointerDeviceKind.mouse,
    );
    await drag.moveBy(const Offset(30, 0));
    await tester.pump();
    await drag.moveBy(const Offset(60, 50));
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await drag.up();
    await tester.pumpAndSettle();
    expect(toggled, ['b']);
    expect(selected, ['c']);
    expect(moves, ['c']);
    expect(activated, isEmpty);
    expect(_mapSemantics(tester, 'c').properties.value, '主选');
    expect(_mapSemantics(tester, 'a').properties.selected, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('脑图多选：组成员down保组，普通完整点击单选，未选down立即单选', (tester) async {
    final controller = MindMapPaneController();
    final selected = <String>[];
    final activated = <String>[];
    await tester.pumpWidget(
      _host(
        _snapshot(),
        controller,
        selectedNodeId: 'b',
        selectedNodeIds: const {'a', 'b'},
        onSelect: (node) => selected.add(node.id),
        onActivate: (node) => activated.add(node.id),
        onToggleSelection: (_) {},
        onMoveGroup: (_) async {},
      ),
    );
    await tester.pumpAndSettle();
    controller.setView(scale: 1);
    await tester.pump();
    final member = await tester.startGesture(
      tester.getCenter(_mapNode('a')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    expect(selected, isEmpty);
    expect(_mapSemantics(tester, 'a').properties.selected, isTrue);
    expect(_mapSemantics(tester, 'b').properties.selected, isTrue);
    await member.up();
    await tester.pumpAndSettle();
    expect(selected, ['a']);
    expect(activated, ['a']);
    expect(_mapSemantics(tester, 'b').properties.selected, isFalse);
    final unselected = await tester.startGesture(
      tester.getCenter(_mapNode('c')),
      kind: PointerDeviceKind.mouse,
    );
    expect(selected, ['a', 'c']);
    await unselected.cancel();
    await tester.pumpAndSettle();
    expect(activated, ['a']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('脑图多选：父子和多根在75%缩放去重平移一次，折叠后代包含且无重挂提示', (tester) async {
    final controller = MindMapPaneController();
    var snapshot = _groupSnapshot();
    final original = {for (final node in snapshot.nodes) node.id: node};
    final submissions = <Map<String, PdfPoint>>[];
    final singles = <String>[];
    final reparents = <String>[];
    final selected = <String>[];
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) {
          return _host(
            snapshot,
            controller,
            selectedNodeId: 'c',
            selectedNodeIds: const {'a', 'c', 'b'},
            onSelect: (node) => selected.add(node.id),
            onMove: (id, _, _) async => singles.add(id),
            onReparentAt: (id, _, _, _) async => reparents.add(id),
            onMoveGroup: (positions) async {
              submissions.add(Map.of(positions));
              expect(
                () => positions['foreign'] = const PdfPoint(0, 0),
                throwsUnsupportedError,
              );
              setState(() => snapshot = _applyPositions(snapshot, positions));
            },
          );
        },
      ),
    );
    await tester.pumpAndSettle();
    controller.setView(scale: .75);
    await tester.pump();
    expect(_mapNode('c'), findsNothing);
    expect(_mapNode('d'), findsNothing);
    final start = tester.getCenter(_mapNode('a'));
    final otherStart = tester.getCenter(_mapNode('b'));
    final target = tester.getCenter(_mapNode('target'));
    final drag = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await drag.moveBy(const Offset(30, 0));
    await tester.pump();
    await drag.moveBy(const Offset(45, 30));
    await tester.pump();
    expect(
      (tester.getCenter(_mapNode('a')) - start - const Offset(75, 30)).distance,
      lessThan(.01),
    );
    expect(
      (tester.getCenter(_mapNode('b')) - otherStart - const Offset(75, 30))
          .distance,
      lessThan(.01),
    );
    await drag.moveTo(target);
    await tester.pump();
    expect(find.text('成为子卡片'), findsNothing);
    expect(find.byKey(const ValueKey('map-drop-target')), findsNothing);
    expect(_mapBorder(tester, 'target').top.color, const Color(0xFFE1E5EA));
    await drag.up();
    await tester.pumpAndSettle();
    expect(submissions, hasLength(1));
    expect(submissions.single.keys.toSet(), {'a', 'b', 'c', 'd'});
    final delta = (target - start) / .75;
    for (final entry in submissions.single.entries) {
      final node = original[entry.key]!;
      expect(entry.value.x, closeTo(node.x + delta.dx, .01));
      expect(entry.value.y, closeTo(node.y + delta.dy, .01));
    }
    expect(
      snapshot.nodes.firstWhere((node) => node.id == 'c').parentNodeId,
      'a',
    );
    expect(
      snapshot.nodes.firstWhere((node) => node.id == 'd').parentNodeId,
      'c',
    );
    expect(selected, isEmpty);
    expect(singles, isEmpty);
    expect(reparents, isEmpty);
    expect(_mapNode('c'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('脑图多选：Escape和分支快照变化取消整组，切图丢弃迟到Ctrl点击', (tester) async {
    final controller = MindMapPaneController();
    var snapshot = _groupSnapshot(collapsed: false);
    late StateSetter refresh;
    final submissions = <Map<String, PdfPoint>>[];
    final toggled = <String>[];
    final activated = <String>[];
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) {
          refresh = setState;
          return _host(
            snapshot,
            controller,
            selectedNodeId: 'b',
            selectedNodeIds: const {'a', 'b'},
            onToggleSelection: (node) => toggled.add(node.id),
            onActivate: (node) => activated.add(node.id),
            onMoveGroup: (positions) async =>
                submissions.add(Map.of(positions)),
          );
        },
      ),
    );
    await tester.pumpAndSettle();
    controller.setView(scale: .75);
    await tester.pump();
    final a = tester.getCenter(_mapNode('a'));
    final b = tester.getCenter(_mapNode('b'));
    final escape = await tester.startGesture(a, kind: PointerDeviceKind.mouse);
    await escape.moveBy(const Offset(30, 0));
    await tester.pump();
    await escape.moveBy(const Offset(45, 30));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await escape.up();
    await tester.pumpAndSettle();
    expect(submissions, isEmpty);
    expect((tester.getCenter(_mapNode('a')) - a).distance, lessThan(.01));
    expect((tester.getCenter(_mapNode('b')) - b).distance, lessThan(.01));
    final changed = await tester.startGesture(a, kind: PointerDeviceKind.mouse);
    await changed.moveBy(const Offset(30, 0));
    await tester.pump();
    await changed.moveBy(const Offset(45, 30));
    await tester.pump();
    refresh(
      () => snapshot = _withNodes(snapshot, [
        for (final node in snapshot.nodes)
          node.id == 'c'
              ? _copyNodeAt(node, parent: null, replaceParent: true)
              : node,
      ]),
    );
    await tester.pump();
    await changed.up();
    await tester.pumpAndSettle();
    expect(submissions, isEmpty);
    expect((tester.getCenter(_mapNode('a')) - a).distance, lessThan(.01));
    expect((tester.getCenter(_mapNode('b')) - b).distance, lessThan(.01));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    final staleClick = await tester.startGesture(
      tester.getCenter(_mapNode('b')),
      kind: PointerDeviceKind.mouse,
    );
    refresh(
      () => snapshot = MapSnapshot(
        map: const MindMap(
          layout: MapLayoutKind.free,
          id: 'next-map',
          projectId: 'project',
          title: '下一脑图',
        ),
        nodes: [
          for (final node in snapshot.nodes)
            _copyNodeAt(node, mapId: 'next-map'),
        ],
        cards: snapshot.cards,
        anchors: snapshot.anchors,
        edges: snapshot.edges,
      ),
    );
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await staleClick.up();
    await tester.pumpAndSettle();
    expect(toggled, isEmpty);
    expect(activated, isEmpty);
    expect(submissions, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('脑图多选：失败整组移动回滚所有预览，后续一次提交可用', (tester) async {
    final controller = MindMapPaneController();
    var snapshot = _groupSnapshot();
    late StateSetter refresh;
    var fail = true;
    final submissions = <Map<String, PdfPoint>>[];
    final singles = <String>[];
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) {
          refresh = setState;
          return _host(
            snapshot,
            controller,
            selectedNodeId: 'b',
            selectedNodeIds: const {'a', 'b'},
            onMove: (id, _, _) async => singles.add(id),
            onMoveGroup: (positions) async {
              submissions.add(Map.of(positions));
              if (fail) throw StateError('验证分组移动失败');
              setState(() => snapshot = _applyPositions(snapshot, positions));
            },
          );
        },
      ),
    );
    await tester.pumpAndSettle();
    controller.setView(scale: .75);
    await tester.pump();
    final a = tester.getCenter(_mapNode('a'));
    final b = tester.getCenter(_mapNode('b'));
    for (var attempt = 0; attempt < 2; attempt++) {
      final drag = await tester.startGesture(
        tester.getCenter(_mapNode('a')),
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveBy(const Offset(30, 0));
      await tester.pump();
      await drag.moveBy(const Offset(45, 30));
      await tester.pump();
      await drag.up();
      await tester.pumpAndSettle();
      expect(submissions, hasLength(attempt + 1));
      expect(submissions.last.keys.toSet(), {'a', 'b', 'c', 'd'});
      if (attempt == 0) {
        expect(find.textContaining('验证分组移动失败'), findsOneWidget);
        expect((tester.getCenter(_mapNode('a')) - a).distance, lessThan(.01));
        expect((tester.getCenter(_mapNode('b')) - b).distance, lessThan(.01));
        refresh(
          () => snapshot = _withNodes(snapshot, [
            for (final node in snapshot.nodes)
              node.id == 'a' ? _copyNode(node, collapsed: false) : node,
          ]),
        );
        await tester.pump();
        for (final id in ['c', 'd']) {
          final node = snapshot.nodes.firstWhere((node) => node.id == id);
          final expected =
              Offset(
                node.x + node.width / 2 + 80,
                node.y + node.height / 2 + 80,
              ) *
              .75;
          expect(
            (tester.getCenter(_mapNode(id)) - expected).distance,
            lessThan(.01),
            reason: '展开后也不能保留折叠后代的失败位置',
          );
        }
        refresh(
          () => snapshot = _withNodes(snapshot, [
            for (final node in snapshot.nodes)
              node.id == 'a' ? _copyNode(node, collapsed: true) : node,
          ]),
        );
        await tester.pump();
        fail = false;
      }
    }
    expect(
      (tester.getCenter(_mapNode('a')) - a - const Offset(75, 30)).distance,
      lessThan(.01),
    );
    expect(
      (tester.getCenter(_mapNode('b')) - b - const Offset(75, 30)).distance,
      lessThan(.01),
    );
    expect(singles, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('脑图多选：Delete明确批量动作，普通右键仍只作用单目标', (tester) async {
    final controller = MindMapPaneController();
    final actions = <(String, String)>[];
    await tester.pumpWidget(
      _host(
        _snapshot(),
        controller,
        selectedNodeId: 'b',
        selectedNodeIds: const {'a', 'b'},
        onMoveGroup: (_) async {},
        onAction: (node, action) => actions.add((node.id, action)),
      ),
    );
    await tester.pumpAndSettle();
    controller.setView(scale: 1);
    await tester.pump();
    final focusClick = await tester.startGesture(
      tester.getCenter(_mapNode('a')),
      kind: PointerDeviceKind.mouse,
    );
    await focusClick.cancel();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    expect(actions, [('b', 'removeSelectedBranches')]);
    final menuClick = await tester.startGesture(
      tester.getCenter(_mapNode('a')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await menuClick.up();
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('map-menu-removeBranch')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('map-menu-removeBranch')));
    await tester.pumpAndSettle();
    expect(actions, [('b', 'removeSelectedBranches'), ('a', 'removeBranch')]);
    expect(_mapSemantics(tester, 'a').properties.value, '主选');
    expect(_mapSemantics(tester, 'b').properties.selected, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('关联虚线合并绘制后仍有真实间隙，点击关联显示强调蓝选择', (tester) async {
    final boundaryKey = GlobalKey();
    final controller = MindMapPaneController();
    final original = _snapshot();
    final snapshot = MapSnapshot(
      map: original.map,
      nodes: original.nodes,
      cards: original.cards,
      anchors: original.anchors,
      edges: const [
        MapEdge(
          id: 'association',
          mapId: 'map',
          fromNodeId: 'a',
          toNodeId: 'b',
        ),
      ],
    );
    await tester.pumpWidget(
      RepaintBoundary(key: boundaryKey, child: _host(snapshot, controller)),
    );
    await tester.pumpAndSettle();
    controller.setView(scale: 1);
    await tester.pumpAndSettle();
    final left = tester.getRect(find.byKey(const ValueKey('map-node-a')));
    final right = tester.getRect(find.byKey(const ValueKey('map-node-b')));
    final y = left.center.dy.round();
    Future<(int, int)> countLinePixels() async {
      return (await tester.runAsync(() async {
        final boundary =
            boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        try {
          final data = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          var orange = 0;
          var accent = 0;
          for (var x = left.right.ceil() + 5; x < right.left.floor() - 5; x++) {
            final offset = (y * image.width + x) * 4;
            final red = data.getUint8(offset);
            final green = data.getUint8(offset + 1);
            final blueValue = data.getUint8(offset + 2);
            if (red > 150 && green >= 110 && green < 190 && blueValue < 140) {
              orange++;
            }
            if (red < 100 && green >= 90 && green < 160 && blueValue > 160) {
              accent++;
            }
          }
          return (orange, accent);
        } finally {
          image.dispose();
        }
      }))!;
    }

    final initial = await countLinePixels();
    final gapLength = (right.left - left.right - 10).floor();
    expect(initial.$1, greaterThan(40));
    expect(initial.$1, lessThan(gapLength - 30));
    expect(initial.$2, 0);
    await tester.tapAt(Offset((left.right + right.left) / 2, left.center.dy));
    await tester.pumpAndSettle();
    final selected = await countLinePixels();
    expect(selected.$1, 0);
    expect(selected.$2, greaterThan(40));
    expect(tester.takeException(), isNull);
  });

  testWidgets('总览保留标题、命中框与折叠，选中或放大立即恢复完整正文', (tester) async {
    final controller = MindMapPaneController();
    await tester.pumpWidget(_host(_snapshot(), controller));
    await tester.pumpAndSettle();
    controller.setView(scale: .6);
    await tester.pump();
    expect(find.text('中文知识卡片内容'), findsNWidgets(3));
    controller.setView(scale: .25);
    await tester.pump();
    expect(controller.renderedNodeCount, 3);
    expect(find.text('card-a'), findsOneWidget);
    expect(find.text('中文知识卡片内容'), findsNothing);
    expect(find.byKey(const ValueKey('map-collapse-a')), findsNothing);
    expect(find.textContaining('总览，放大查看正文'), findsNothing);
    expect(controller.scale, closeTo(.25, .0001));
    expect(find.text('25%'), findsNothing);
    final node = find.byKey(const ValueKey('map-node-b'));
    final overviewRect = tester.getRect(node);
    final mouse = await tester.startGesture(
      overviewRect.center,
      kind: PointerDeviceKind.mouse,
    );
    await mouse.up();
    await tester.pumpAndSettle();
    expect(tester.getRect(node), overviewRect);
    expect(find.text('中文知识卡片内容'), findsOneWidget);
    expect(find.byKey(const ValueKey('map-card-actions')), findsNothing);
    controller.setView(scale: .8);
    await tester.pump();
    expect(find.text('中文知识卡片内容'), findsNWidgets(3));
    expect(find.textContaining('总览，放大查看正文'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('视口平移后卡片刷新立即显示新正文，缓存节点使用最新选择回调', (tester) async {
    final controller = MindMapPaneController();
    final original = _snapshot();
    await tester.pumpWidget(_host(original, controller));
    await tester.pumpAndSettle();
    controller.setView(scale: 1);
    await tester.pump();
    final pan = await tester.startGesture(
      const Offset(700, 450),
      kind: PointerDeviceKind.mouse,
    );
    await pan.moveBy(const Offset(-40, -30));
    await tester.pump();
    await pan.up();
    await tester.pumpAndSettle();
    final updated = MapSnapshot(
      map: original.map,
      nodes: original.nodes,
      cards: {
        ...original.cards,
        'card-a': const NoteCard(
          id: 'card-a',
          projectId: 'project',
          title: '更新后的中文标题',
          excerptSnapshot: '原始摘录',
          body: '更新后的中文正文',
          note: '更新备注',
          color: '#89C2FF',
        ),
      },
      anchors: original.anchors,
      edges: original.edges,
    );
    final selected = <String>[];
    await tester.pumpWidget(
      _host(updated, controller, onSelect: (n) => selected.add(n.id)),
    );
    await tester.pumpAndSettle();
    expect(find.text('更新后的中文标题'), findsOneWidget);
    expect(find.text('更新后的中文正文'), findsOneWidget);
    // b的数据未改动，仍须通过当前父组件回调选中。
    final mouse = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('map-node-b'))),
      kind: PointerDeviceKind.mouse,
    );
    await mouse.up();
    await tester.pumpAndSettle();
    expect(selected, ['b']);
    expect(find.byKey(const ValueKey('map-card-actions')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('文本编辑焦点经真实鼠标单击切到脑图，CtrlZ进入应用快捷键作用域', (tester) async {
    final editorFocus = FocusNode(debugLabel: '测试卡片正文');
    final controller = MindMapPaneController();
    var undoSeen = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Focus(
            onKeyEvent: (_, event) {
              if (event is KeyDownEvent &&
                  event.logicalKey == LogicalKeyboardKey.keyZ &&
                  HardwareKeyboard.instance.isControlPressed) {
                undoSeen = true;
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: Row(
              children: [
                SizedBox(width: 250, child: TextField(focusNode: editorFocus)),
                Expanded(
                  child: MindMapPane(
                    snapshot: _snapshot(),
                    controller: controller,
                    onSelect: (_) {},
                    onMove: (_, _, _) async {},
                    onReparent: (_, _) async {},
                    onAssociate: (_, _) async {},
                    onRemoveAssociation: (_) {},
                    onAction: (_, _) {},
                    onToggleCollapsed: (_) {},
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    controller.setView(scale: .6);
    await tester.pump();
    await tester.enterText(find.byType(TextField), '卡片正文');
    expect(editorFocus.hasFocus, isTrue);
    final mouse = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('map-node-a'))),
      kind: PointerDeviceKind.mouse,
    );
    await mouse.up();
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'OpenNote 脑图');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(undoSeen, isTrue);
    await tester.pumpWidget(const SizedBox());
    editorFocus.dispose();
    expect(tester.takeException(), isNull);
  });

  testWidgets('完整点击才激活卡片，按下、拖动、取消和关联不会激活回源', (tester) async {
    final controller = MindMapPaneController();
    final selected = <String>[];
    final activated = <String>[];
    final moves = <String>[];
    final links = <(String, String)>[];
    await tester.pumpWidget(
      _host(
        _snapshot(),
        controller,
        onSelect: (node) => selected.add(node.id),
        onActivate: (node) => activated.add(node.id),
        onMove: (id, _, _) async => moves.add(id),
        onAssociate: (from, to) async => links.add((from, to)),
      ),
    );
    await tester.pumpAndSettle();
    controller.setView(scale: 1);
    await tester.pump();
    final nodeA = find.byKey(const ValueKey('map-node-a'));
    final nodeB = find.byKey(const ValueKey('map-node-b'));
    final click = await tester.startGesture(
      tester.getCenter(nodeA),
      kind: PointerDeviceKind.mouse,
    );
    expect(selected, ['a']);
    expect(activated, isEmpty);
    await tester.pump();
    await click.up();
    await tester.pumpAndSettle();
    expect(activated, ['a']);
    expect(selected, ['a'], reason: '一次完整点击不重复提交选择');
    final drag = await tester.startGesture(
      tester.getCenter(nodeA),
      kind: PointerDeviceKind.mouse,
    );
    await drag.moveBy(const Offset(30, 0));
    await tester.pump();
    await drag.moveBy(const Offset(90, 20));
    await tester.pump();
    await drag.up();
    await tester.pumpAndSettle();
    expect(moves, ['a']);
    expect(activated, ['a']);
    final cancelled = await tester.startGesture(
      tester.getCenter(nodeB),
      kind: PointerDeviceKind.mouse,
    );
    await cancelled.cancel();
    await tester.pumpAndSettle();
    expect(activated, ['a']);
    controller.beginAssociation('a');
    await tester.pump();
    await tester.tap(nodeB, kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(links, [('a', 'b')]);
    expect(activated, ['a']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('缓存卡片在父组件更新后，完整点击使用新的激活回调', (tester) async {
    final controller = MindMapPaneController();
    final snapshot = _snapshot();
    final first = <String>[];
    final second = <String>[];
    await tester.pumpWidget(
      _host(snapshot, controller, onActivate: (node) => first.add(node.id)),
    );
    await tester.pumpAndSettle();
    controller.setView(scale: 1);
    await tester.pump();
    await tester.pumpWidget(
      _host(snapshot, controller, onActivate: (node) => second.add(node.id)),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('map-node-b')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(first, isEmpty);
    expect(second, ['b']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('真实鼠标完整单击保留节点选择，只有空白点击清空', (tester) async {
    final controller = MindMapPaneController();
    final selected = <String>[];
    var cleared = 0;
    await tester.pumpWidget(
      _host(
        _snapshot(),
        controller,
        onSelect: (node) => selected.add(node.id),
        onClearSelection: () => cleared++,
      ),
    );
    await tester.pumpAndSettle();
    controller.setView(scale: 1);
    await tester.pump();
    final mouse = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('map-node-a'))),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await mouse.up();
    await tester.pumpAndSettle();
    expect(selected, ['a']);
    expect(cleared, 0);
    expect(find.byKey(const ValueKey('map-card-actions')), findsNothing);
    await tester.tapAt(const Offset(700, 450));
    await tester.pumpAndSettle();
    expect(cleared, 1);
    expect(find.byKey(const ValueKey('map-card-actions')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('空白双击转换画布落点，节点完整点击不受双击竞争', (tester) async {
    final controller = MindMapPaneController();
    final created = <Offset>[];
    final activated = <String>[];
    await tester.pumpWidget(
      _host(
        _snapshot(),
        controller,
        onCreateAt: created.add,
        onActivate: (node) => activated.add(node.id),
      ),
    );
    await tester.pumpAndSettle();
    controller.setView(scale: .5, worldTopLeft: const Offset(100, 200));
    await tester.pump();
    const background = Offset(700, 500);
    await tester.tapAt(background, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(background, kind: PointerDeviceKind.mouse);
    await tester.pump();
    expect(created, hasLength(1));
    expect((created.single - const Offset(1500, 1200)).distance, lessThan(.01));

    controller.centerOnNode('a');
    await tester.pump();
    await tester.pump();
    final node = find.byKey(const ValueKey('map-node-a'));
    await tester.tap(node, kind: PointerDeviceKind.mouse);
    await tester.pump();
    expect(activated, ['a'], reason: '完整节点点击无需等待空白双击的超时');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(node, kind: PointerDeviceKind.mouse);
    await tester.pump();
    expect(activated, ['a', 'a']);
    expect(created, hasLength(1), reason: '节点点击不能穿透到空白创建');
    expect(tester.takeException(), isNull);
  });

  testWidgets('Insert与Enter显式传卡片目标，关联拖动及提交中不创建', (tester) async {
    final controller = MindMapPaneController();
    final actions = <(String, String)>[];
    final created = <Offset>[];
    final snapshot = _snapshot();
    Widget host({bool canCreate = true}) => _host(
      snapshot,
      controller,
      canCreate: canCreate,
      onCreateAt: created.add,
      onAction: (node, action) => actions.add((node.id, action)),
    );
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    controller.setView(scale: 1);
    await tester.pump();
    final node = find.byKey(const ValueKey('map-node-a'));
    await tester.tap(node, kind: PointerDeviceKind.mouse);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.insert);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(actions, [('a', 'newChild'), ('a', 'newSibling')]);

    controller.beginAssociation('a');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.insert);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    const background = Offset(700, 500);
    await tester.tapAt(background, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(background, kind: PointerDeviceKind.mouse);
    await tester.pump();
    expect(actions, hasLength(2));
    expect(created, isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    final drag = await tester.startGesture(
      tester.getCenter(node),
      kind: PointerDeviceKind.mouse,
    );
    await drag.moveBy(const Offset(30, 60));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.insert);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(actions, hasLength(2));
    await drag.cancel();
    await tester.pumpAndSettle();

    await tester.pumpWidget(host(canCreate: false));
    await tester.pump();
    await tester.tap(node, kind: PointerDeviceKind.mouse);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.insert);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(actions, hasLength(2));
    expect(created, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('鼠标按下立即选中，拖到目标显示绿色重挂提示并只提交一次', (tester) async {
    final controller = MindMapPaneController();
    final selected = <String>[];
    final moves = <(String, double, double)>[];
    final reparents = <(String, String?, double, double)>[];
    await tester.pumpWidget(
      _host(
        _snapshot(),
        controller,
        onSelect: (n) => selected.add(n.id),
        onMove: (id, x, y) async => moves.add((id, x, y)),
        onReparentAt: (id, parent, x, y) async =>
            reparents.add((id, parent, x, y)),
      ),
    );
    await tester.pumpAndSettle();
    controller.setView(scale: 1);
    await tester.pump();
    final root = find.byKey(const ValueKey('map-node-a'));
    final target = find.byKey(const ValueKey('map-node-b'));
    final gesture = await tester.startGesture(
      tester.getCenter(root),
      kind: PointerDeviceKind.mouse,
    );
    expect(selected, ['a']);
    await tester.pump();
    expect(find.byKey(const ValueKey('map-card-actions')), findsNothing);
    await gesture.moveBy(const Offset(30, 0));
    await tester.pump();
    await gesture.moveTo(tester.getCenter(target));
    await tester.pump();
    expect(find.text('成为子卡片'), findsOneWidget);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(moves, isEmpty);
    expect(reparents.length, 1);
    expect(reparents.single.$1, 'a');
    expect(reparents.single.$2, 'b');
    expect(reparents.single.$3, closeTo(400, 2));
    expect(find.text('成为子卡片'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('自动布局归位：各结构子卡在空白处松手立即归位且不提交', (tester) async {
    for (final kind in MapLayoutKind.values.where(
      (kind) => kind != MapLayoutKind.free,
    )) {
      final controller = MindMapPaneController();
      final moves = <String>[];
      final reparents = <String>[];
      await tester.pumpWidget(
        _host(
          _withLayout(_snapshot(), kind),
          controller,
          key: ValueKey(kind),
          onMove: (id, _, _) async => moves.add(id),
          onReparentAt: (id, _, _, _) async => reparents.add(id),
        ),
      );
      await tester.pumpAndSettle();
      controller.setView(scale: .75, worldTopLeft: const Offset(-100, -80));
      await tester.pump();
      for (final id in ['c']) {
        final before = {
          for (final node in ['a', 'b', 'c'])
            node: tester.getRect(_mapNode(node)),
        };
        final drag = await tester.startGesture(
          _nodeHitPoint(tester, id),
          kind: PointerDeviceKind.mouse,
        );
        await drag.moveBy(const Offset(20, 0));
        await tester.pump();
        await drag.moveBy(const Offset(40, 22.5));
        await tester.pump();
        expect(
          (tester.getCenter(_mapNode(id)) - before[id]!.center).distance,
          greaterThan(30),
          reason: '$kind 仍允许临时拖动预览',
        );
        await drag.up();
        await tester.pump();
        for (final entry in before.entries) {
          expect(tester.getRect(_mapNode(entry.key)), entry.value);
        }
        expect(moves, isEmpty);
        expect(reparents, isEmpty);
        expect(find.byType(LinearProgressIndicator), findsNothing);
        expect(_mapSemantics(tester, id).properties.selected, isTrue);
      }
      expect(controller.scale, .75);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('自动布局归位：混合分支依据父级布局，自动与自由卡片混选时整组归位', (tester) async {
    final controller = MindMapPaneController();
    final base = _groupSnapshot(collapsed: false);
    final snapshot = _withLayout(
      _withNodes(base, [
        for (final node in base.nodes)
          node.id == 'c' ? node.withBranchLayout(MapLayoutKind.free) : node,
      ]),
      MapLayoutKind.right,
    );
    final moves = <String>[];
    final groups = <Map<String, PdfPoint>>[];
    await tester.pumpWidget(
      _host(snapshot, controller, onMove: (id, _, _) async => moves.add(id)),
    );
    await tester.pumpAndSettle();
    controller.setView(scale: .75, worldTopLeft: const Offset(-100, -40));
    await tester.pump();
    final cBefore = tester.getRect(_mapNode('c'));
    for (final id in ['c', 'd']) {
      final drag = await tester.startGesture(
        _nodeHitPoint(tester, id),
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveBy(const Offset(20, 0));
      await tester.pump();
      await drag.moveBy(const Offset(40, 22.5));
      await tester.pump();
      await drag.up();
      await tester.pumpAndSettle();
    }
    expect(tester.getRect(_mapNode('c')), cBefore);
    expect(moves, ['d'], reason: '自由结构主题自身仍由自动父级定位，其后代可以自由移动');

    await tester.pumpWidget(
      _host(
        snapshot,
        controller,
        key: const ValueKey('mixed-group'),
        selectedNodeId: 'b',
        selectedNodeIds: const {'b', 'd'},
        onMoveGroup: (positions) async => groups.add(positions),
      ),
    );
    await tester.pumpAndSettle();
    controller.setView(scale: .75, worldTopLeft: const Offset(-100, -40));
    await tester.pump();
    final before = {
      for (final id in ['b', 'd']) id: tester.getRect(_mapNode(id)),
    };
    final group = await tester.startGesture(
      _nodeHitPoint(tester, 'd'),
      kind: PointerDeviceKind.mouse,
    );
    await group.moveBy(const Offset(20, 0));
    await tester.pump();
    await group.moveBy(const Offset(40, 22.5));
    await tester.pump();
    for (final entry in before.entries) {
      expect(tester.getRect(_mapNode(entry.key)).left, entry.value.left + 60);
    }
    await group.up();
    await tester.pump();
    for (final entry in before.entries) {
      expect(tester.getRect(_mapNode(entry.key)), entry.value);
      expect(_mapSemantics(tester, entry.key).properties.selected, isTrue);
    }
    expect(groups, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('自动布局归位：自由画布中的自动分支整组平移，选中后代不阻止移动', (tester) async {
    final controller = MindMapPaneController();
    final base = _groupSnapshot(collapsed: false);
    final snapshot = _withNodes(base, [
      for (final node in base.nodes)
        node.id == 'a' ? node.withBranchLayout(MapLayoutKind.right) : node,
    ]);
    final groups = <Map<String, PdfPoint>>[];
    await tester.pumpWidget(
      _host(
        snapshot,
        controller,
        selectedNodeId: 'a',
        selectedNodeIds: const {'a', 'c'},
        onMoveGroup: (positions) async => groups.add(positions),
      ),
    );
    await tester.pumpAndSettle();
    controller.setView(scale: .75, worldTopLeft: const Offset(-100, -40));
    await tester.pump();
    final drag = await tester.startGesture(
      _nodeHitPoint(tester, 'a'),
      kind: PointerDeviceKind.mouse,
    );
    await drag.moveBy(const Offset(20, 0));
    await tester.pump();
    await drag.moveBy(const Offset(40, 22.5));
    await tester.pump();
    await drag.up();
    await tester.pumpAndSettle();
    expect(groups, hasLength(1));
    expect(groups.single.keys.toSet(), {'a', 'c', 'd'});
    for (final entry in groups.single.entries) {
      final old = snapshot.nodes.singleWhere((node) => node.id == entry.key);
      expect(entry.value.x, closeTo(old.x + 80, .01));
      expect(entry.value.y, closeTo(old.y + 30, .01));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('滚轮细调：小步缩放以鼠标为中心，连续输入等价并保留限值和控制器步幅', (tester) async {
    final controller = MindMapPaneController();
    await tester.pumpWidget(_host(_snapshot(), controller));
    await tester.pumpAndSettle();
    controller.setView(scale: 1);
    await tester.pump();
    final viewer = tester.widget<InteractiveViewer>(
      find.byType(InteractiveViewer),
    );
    const cursor = Offset(700, 450);
    final local = cursor - tester.getTopLeft(find.byType(InteractiveViewer));
    final anchored = viewer.transformationController!.toScene(local);
    Future<void> wheel(double delta) async {
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: cursor,
          kind: PointerDeviceKind.mouse,
          scrollDelta: Offset(0, delta),
        ),
      );
      await tester.pumpAndSettle();
    }

    await wheel(-20);
    expect(controller.scale, inInclusiveRange(1.02, 1.03));
    expect(
      (viewer.transformationController!.toScene(local) - anchored).distance,
      lessThan(.001),
    );
    await wheel(20);
    expect(controller.scale, closeTo(1, .00001));
    for (var tick = 0; tick < 4; tick++) {
      await wheel(-20);
    }
    final continuous = controller.scale;
    controller.setView(scale: 1);
    await tester.pump();
    await wheel(-80);
    expect(controller.scale, inInclusiveRange(1.10, 1.11));
    expect(controller.scale, closeTo(continuous, .00001));
    await wheel(80);
    expect(controller.scale, closeTo(1, .00001));
    controller.zoomIn();
    await tester.pump();
    expect(controller.scale, closeTo(1.25, .00001));
    controller.zoomOut();
    await tester.pump();
    expect(controller.scale, closeTo(1, .00001));
    controller.setView(scale: .08);
    await tester.pump();
    await wheel(120);
    expect(controller.scale, closeTo(.08, .00001));
    controller.setView(scale: 2.5);
    await tester.pump();
    await wheel(-120);
    expect(controller.scale, closeTo(2.5, .00001));
    expect(tester.takeException(), isNull);
  });

  testWidgets('画布工具：合并后固定右下，平移缩放不影响命中', (tester) async {
    final controller = MindMapPaneController();
    await tester.pumpWidget(_host(_snapshot(), controller));
    await tester.pumpAndSettle();
    final pane = tester.getRect(find.byType(MindMapPane));
    final viewport = find.byKey(const ValueKey('map-viewport-controls'));
    final before = tester.getRect(viewport);
    expect(find.byKey(const ValueKey('map-canvas-toolbar')), findsNothing);
    expect(find.byTooltip('放大脑图'), findsNothing);
    expect(find.byTooltip('缩小脑图'), findsNothing);
    expect(find.textContaining('%'), findsNothing);
    expect(pane.right - before.right, 12);
    expect(pane.bottom - before.bottom, 12);
    controller.setView(scale: .5, worldTopLeft: const Offset(-200, -100));
    await tester.pump();
    expect(tester.getRect(viewport), before);
    final fit = tester.getRect(find.byTooltip('适合全部卡片'));
    expect(fit.width, greaterThanOrEqualTo(36));
    expect(fit.height, greaterThanOrEqualTo(36));
    await openMapToolsMenu(tester);
    expect(
      tester.getRect(find.byKey(const Key('context-menu-main'))).bottom,
      lessThanOrEqualTo(before.top - 6),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await waitForMapToolsClosed(tester);
    await tester.tap(find.byTooltip('适合全部卡片'));
    await tester.pump();
    expect(controller.scale, isNot(closeTo(.5, .00001)));
    expect(tester.getRect(viewport), before);
    expect(tester.takeException(), isNull);
  });

  testWidgets('拖动空白平移、滚轮缩放和节点自由拖动保持分开的输入合同', (tester) async {
    final controller = MindMapPaneController();
    final moves = <(String, double, double)>[];
    await tester.pumpWidget(
      _host(
        _snapshot(),
        controller,
        onMove: (id, x, y) async => moves.add((id, x, y)),
      ),
    );
    await tester.pumpAndSettle();
    controller.setView(scale: 1);
    await tester.pump();
    final node = find.byKey(const ValueKey('map-node-a'));
    final initial = tester.getCenter(node);
    final pan = await tester.startGesture(
      const Offset(700, 450),
      kind: PointerDeviceKind.mouse,
    );
    await pan.moveBy(const Offset(-60, -35));
    await tester.pump();
    await pan.moveBy(const Offset(-25, -20));
    await tester.pump();
    await pan.up();
    await tester.pumpAndSettle();
    expect(tester.getCenter(node).dx, lessThan(initial.dx - 20));
    expect(moves, isEmpty);
    final oldScale = controller.scale;
    await tester.sendEventToBinding(
      const PointerScrollEvent(
        position: Offset(700, 450),
        kind: PointerDeviceKind.mouse,
        scrollDelta: Offset(0, -80),
      ),
    );
    await tester.pumpAndSettle();
    expect(controller.scale, greaterThan(oldScale));
    controller.setView(scale: 1);
    await tester.pump();
    final drag = await tester.startGesture(
      tester.getCenter(node),
      kind: PointerDeviceKind.mouse,
    );
    await drag.moveBy(const Offset(90, 50));
    await tester.pump();
    await drag.up();
    await tester.pumpAndSettle();
    expect(moves.length, 1);
    expect(moves.single.$2, closeTo(90, 2));
    expect(moves.single.$3, closeTo(50, 2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('折叠读取真实层级、关联模式与右键独立分支复制可操作', (tester) async {
    final controller = MindMapPaneController();
    var snapshot = _snapshot();
    final links = <(String, String)>[];
    final actions = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => MindMapPane(
              snapshot: snapshot,
              selectedNodeId: 'a',
              controller: controller,
              onSelect: (_) {},
              onMove: (_, _, _) async {},
              onReparent: (_, _) async {},
              onAssociate: (from, to) async => links.add((from, to)),
              onRemoveAssociation: (_) {},
              onAction: (_, action) => actions.add(action),
              onToggleCollapsed: (id) => setState(() {
                snapshot = _withNodes(
                  snapshot,
                  snapshot.nodes
                      .map(
                        (n) => n.id == id
                            ? _copyNode(n, collapsed: !n.collapsed)
                            : n,
                      )
                      .toList(),
                );
              }),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    controller.setView(scale: 1);
    await tester.pump();
    expect(find.byKey(const ValueKey('map-node-c')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('map-collapse-a')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('map-node-c')), findsNothing);
    expect(find.byKey(const ValueKey('map-node-a')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('map-collapse-a')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('map-node-c')), findsOneWidget);
    controller.beginAssociation('a');
    await tester.pump();
    expect(find.byKey(const ValueKey('map-association-mode')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('map-node-b')));
    await tester.pumpAndSettle();
    expect(links, [('a', 'b')]);
    expect(find.byKey(const ValueKey('map-association-mode')), findsNothing);
    final right = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('map-node-a'))),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await right.up();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('map-menu-clipboardMenu')));
    await tester.pumpAndSettle();
    expect(find.text('复制到其他脑图…'), findsOneWidget);
    await tester.tap(find.text('复制到其他脑图…'));
    await tester.pumpAndSettle();
    expect(actions, ['copyBranch']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('500 可见节点实际渲染，离开视口的节点不进入控件树', (tester) async {
    final controller = MindMapPaneController();
    final nodes = List.generate(
      500,
      (i) => MapNode(
        id: 'node-$i',
        mapId: 'map',
        cardId: 'card-$i',
        x: (i % 20) * 240.0,
        y: (i ~/ 20) * 130.0,
      ),
    );
    var snapshot = MapSnapshot(
      map: const MindMap(
        layout: MapLayoutKind.free,
        id: 'map',
        projectId: 'project',
        title: '容量脑图',
      ),
      nodes: nodes,
      cards: {for (var i = 0; i < 500; i++) 'card-$i': _card('card-$i')},
      anchors: const {},
      edges: const [],
    );
    await tester.pumpWidget(_host(snapshot, controller));
    await tester.pumpAndSettle();
    controller.setView(scale: .1);
    await tester.pumpAndSettle();
    expect(controller.renderedNodeCount, 500);
    expect(find.byKey(const ValueKey('map-node-node-499')), findsOneWidget);
    controller.setView(scale: 1, worldTopLeft: const Offset(2000, 1500));
    await tester.pumpAndSettle();
    expect(controller.renderedNodeCount, greaterThan(1));
    expect(controller.renderedNodeCount, lessThan(50));
    expect(find.byKey(const ValueKey('map-node-node-0')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('更换脑图 key 后旧 State 不会解除新 controller 绑定', (tester) async {
    final controller = MindMapPaneController();
    await tester.pumpWidget(
      _host(_snapshot(), controller, key: const ValueKey('first')),
    );
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      _host(_snapshot(), controller, key: const ValueKey('second')),
    );
    await tester.pumpAndSettle();
    controller.setView(scale: .8);
    await tester.pump();
    expect(controller.scale, closeTo(.8, .001));
    controller.centerOnNode('b');
    await tester.pumpAndSettle();
    expect(
      (tester.getCenter(find.byKey(const ValueKey('map-node-b'))) -
              const Offset(400, 300))
          .distance,
      lessThan(1),
    );
  });

  testWidgets('图片卡片真实解码缩略图，新增离屏图片不触发资源查询', (tester) async {
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('opennote-map-image-'),
    ))!;
    try {
      final path = '${directory.path}${Platform.pathSeparator}截图.png';
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        canvas.drawRect(
          const Rect.fromLTWH(0, 0, 16, 16),
          Paint()..color = Colors.red,
        );
        final picture = recorder.endRecording();
        final image = await picture.toImage(16, 16);
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        await File(path).writeAsBytes(bytes.buffer.asUint8List());
        image.dispose();
        picture.dispose();
      });
      final requests = <String>[];
      final controller = MindMapPaneController();
      final node = const MapNode(
        id: 'image',
        mapId: 'map',
        cardId: 'image-card',
        x: 0,
        y: 0,
      );
      var snapshot = MapSnapshot(
        map: _snapshot().map,
        nodes: [node],
        cards: {'image-card': _imageCard('image-card', 'visible')},
        anchors: const {},
        edges: const [],
      );
      Future<String> resolver(String resourceId) async {
        requests.add(resourceId);
        return path;
      }

      await tester.pumpWidget(
        _host(snapshot, controller, imagePathResolver: resolver),
      );
      await tester.pumpAndSettle();
      controller.setView(scale: 1);
      await tester.pump();
      final imageWidget = find.byKey(const ValueKey('map-image-visible'));
      expect(imageWidget, findsOneWidget);
      final raw = find.descendant(
        of: imageWidget,
        matching: find.byType(RawImage),
      );
      // 文件长度、读取和 codec 各自跨真实 IO；逐帧等待实际解码状态。
      for (var attempt = 0; attempt < 40; attempt++) {
        if (tester.renderObject<RenderImage>(raw).image != null) break;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
      expect(tester.renderObject<RenderImage>(raw).image, isNotNull);
      expect(find.text('图片备注'), findsOneWidget);
      expect(requests, ['visible']);
      snapshot = MapSnapshot(
        map: snapshot.map,
        nodes: [
          node,
          const MapNode(
            id: 'hidden',
            mapId: 'map',
            cardId: 'hidden-card',
            x: 6000,
            y: 0,
          ),
        ],
        cards: {
          ...snapshot.cards,
          'hidden-card': _imageCard('hidden-card', 'hidden'),
        },
        anchors: const {},
        edges: const [],
      );
      await tester.pumpWidget(
        _host(snapshot, controller, imagePathResolver: resolver),
      );
      await tester.pumpAndSettle();
      expect(requests, ['visible']);
      expect(find.byKey(const ValueKey('map-node-hidden')), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await directory.delete(recursive: true);
      });
    }
  });

  testWidgets('新脑图布局前发出的回源反选定位在新 Pane 兑现', (tester) async {
    final controller = MindMapPaneController();
    controller.centerOnNode('pending');
    await tester.pumpWidget(_host(_snapshot(), controller));
    await tester.pumpAndSettle();
    final snapshot = _withNodes(_snapshot(), const [
      MapNode(id: 'pending', mapId: 'map', cardId: 'card-a', x: 2400, y: 1800),
      MapNode(id: 'other', mapId: 'map', cardId: 'card-b', x: 0, y: 0),
    ]);
    await tester.pumpWidget(
      _host(snapshot, controller, key: const ValueKey('new-map')),
    );
    await tester.pumpAndSettle();
    expect(
      (tester.getCenter(find.byKey(const ValueKey('map-node-pending'))) -
              const Offset(400, 300))
          .distance,
      lessThan(1),
    );
    expect(tester.takeException(), isNull);
  });
}

int _nextTimestampPointer = 30000;

TestGesture _timestampGesture(
  WidgetTester tester, {
  PointerDeviceKind kind = PointerDeviceKind.mouse,
  int device = 1,
  int buttons = kPrimaryMouseButton,
}) => TestGesture(
  dispatcher: tester.sendEventToBinding,
  pointer: _nextTimestampPointer++,
  kind: kind,
  device: device,
  buttons: buttons,
);

Future<void> _timedNodeClick(
  WidgetTester tester,
  String nodeId, {
  required int down,
  required int up,
  Offset? point,
  PointerDeviceKind kind = PointerDeviceKind.mouse,
  int device = 1,
}) async {
  final position = point ?? _nodeHitPoint(tester, nodeId);
  final box = tester.renderObject<RenderBox>(_mapNode(nodeId));
  expect(
    tester
        .hitTestOnBinding(position)
        .path
        .any((entry) => identical(entry.target, box)),
    isTrue,
    reason: '真实事件必须命中目标卡片',
  );
  final gesture = _timestampGesture(tester, kind: kind, device: device);
  await gesture.down(position, timeStamp: Duration(milliseconds: down));
  await gesture.up(timeStamp: Duration(milliseconds: up));
}

Widget _host(
  MapSnapshot snapshot,
  MindMapPaneController controller, {
  Key? key,
  String? selectedNodeId,
  Set<String>? selectedNodeIds,
  void Function(MapNode)? onSelect,
  void Function(MapNode)? onToggleSelection,
  void Function(MapNode)? onActivate,
  void Function(Offset)? onCreateAt,
  void Function(MapNode, String)? onAction,
  bool canCreate = true,
  Future<void> Function(String, double, double)? onMove,
  Future<void> Function(Map<String, PdfPoint>)? onMoveGroup,
  void Function(Set<String>, String?)? onSelectionChanged,
  Future<void> Function(String, String?, double, double)? onReparentAt,
  Future<void> Function(String, String)? onAssociate,
  Future<String> Function(String)? imagePathResolver,
  VoidCallback? onClearSelection,
  ThemeData? theme,
  TextScaler? textScaler,
  TextStyle? defaultTextStyle,
  Widget? dragSource,
  Future<void> Function(ReaderExcerptDrag, Offset, MapNode?)? onTextExcerptDrop,
}) {
  final pane = MindMapPane(
    key: key,
    snapshot: snapshot,
    selectedNodeId: selectedNodeId,
    selectedNodeIds: selectedNodeIds,
    controller: controller,
    imagePathResolver: imagePathResolver,
    onClearSelection: onClearSelection,
    onSelect: onSelect ?? (_) {},
    onToggleSelection: onToggleSelection,
    onActivate: onActivate,
    onCreateAt: onCreateAt,
    canCreate: canCreate,
    onMove: onMove ?? (_, _, _) async {},
    onMoveGroup: onMoveGroup,
    onSelectionChanged: onSelectionChanged,
    onReparent: (_, _) async {},
    onReparentAt: onReparentAt,
    onAssociate: onAssociate ?? (_, _) async {},
    onRemoveAssociation: (_) {},
    onAction: onAction ?? (_, _) {},
    onToggleCollapsed: (_) {},
    onTextExcerptDrop: onTextExcerptDrop,
  );
  final content = dragSource == null
      ? pane
      : Row(
          children: [
            SizedBox(width: 120, child: dragSource),
            Expanded(child: pane),
          ],
        );
  return MaterialApp(
    theme: theme,
    themeAnimationDuration: Duration.zero,
    builder: textScaler == null
        ? null
        : (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: textScaler),
            child: child!,
          ),
    home: Scaffold(
      body: defaultTextStyle == null
          ? content
          : DefaultTextStyle(style: defaultTextStyle, child: content),
    ),
  );
}

ReaderExcerptDrag _excerptDrag({VoidCallback? onCommitted}) =>
    ReaderExcerptDrag(
      revisionId: 'revision',
      text: '文字摘录',
      anchors: [
        AnchorDraft(
          revisionId: 'revision',
          pageIndex: 0,
          quads: [PdfQuad.rect(10, 20, 30, 40)],
          context: '文字摘录',
          textLayerId: 'layer',
          textStart: 0,
          textEnd: 4,
        ),
      ],
      sourceIsCurrent: () => true,
      prepareExcerpt: () async =>
          const SelectedExcerpt(text: '文字摘录', anchors: []),
      onCommitted: onCommitted ?? () {},
      onFinished: (_) {},
    );

Widget _excerptDragSource(ReaderExcerptDrag drag) => Center(
  child: Draggable<ReaderExcerptDrag>(
    data: drag,
    dragAnchorStrategy: pointerDragAnchorStrategy,
    onDragStarted: drag.start,
    onDragEnd: (details) {
      if (!details.wasAccepted) drag.cancel();
    },
    feedback: const Material(child: Text('文字摘录')),
    child: const SizedBox(
      key: Key('test-text-drag-source'),
      width: 100,
      height: 52,
      child: ColoredBox(
        color: Colors.white,
        child: Center(child: Text('拖拽文字')),
      ),
    ),
  ),
);

Finder _nodeGesture(String id) => find.descendant(
  of: _mapNode(id),
  matching: find.byWidgetPredicate(
    (widget) =>
        widget is RawGestureDetector &&
        widget.gestures.containsKey(PanGestureRecognizer),
  ),
);

SnapshotWidget _nodeSnapshot(WidgetTester tester, String id) =>
    tester.widget<SnapshotWidget>(
      find.ancestor(of: _mapNode(id), matching: find.byType(SnapshotWidget)),
    );

Offset _nodeHitPoint(WidgetTester tester, String id) {
  final box = tester.renderObject<RenderBox>(_mapNode(id));
  final point = tester.getCenter(_mapNode(id));
  expect(
    tester
        .hitTestOnBinding(point)
        .path
        .any((entry) => identical(entry.target, box)),
    isTrue,
    reason: '真实鼠标落点必须命中卡片，不能由悬浮工具条消费',
  );
  return point;
}

Future<List<int>> _nodePixels(
  WidgetTester tester,
  GlobalKey boundaryKey,
  String id, {
  String? evidenceName,
}) async {
  final box =
      boundaryKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final rect = tester.getRect(_mapNode(id));
  final local = box.globalToLocal(rect.topLeft);
  final ratio = View.of(tester.element(_mapNode(id))).devicePixelRatio;
  final left = (local.dx * ratio).round();
  final top = (local.dy * ratio).round();
  final width = (rect.width * ratio).round();
  final height = (rect.height * ratio).round();
  return (await tester.runAsync(() async {
    // 始终按实际屏幕 DPR 截图，不用局部快照采样比例降低质量比较分辨率。
    final image = await box.toImage(pixelRatio: ratio);
    try {
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      if (evidenceName != null) {
        final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        final directory = await _pixelEvidenceDirectory();
        await File('${directory.path}/$evidenceName-scene.png')
            .writeAsBytes(png.buffer.asUint8List());
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawImageRect(
          image,
          Rect.fromLTWH(
            left.toDouble(),
            top.toDouble(),
            width.toDouble(),
            height.toDouble(),
          ),
          Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
          Paint()..filterQuality = FilterQuality.none,
        );
        final picture = recorder.endRecording();
        final crop = await picture.toImage(width, height);
        try {
          final cropPng = (await crop.toByteData(
            format: ui.ImageByteFormat.png,
          ))!;
          await File('${directory.path}/$evidenceName-card.png')
              .writeAsBytes(cropPng.buffer.asUint8List());
        } finally {
          crop.dispose();
          picture.dispose();
        }
        debugPrint(
          'MAP_PIXEL_CAPTURE $evidenceName: logicalRect=$rect, dpr=$ratio, nativeRegion=($left,$top,$width,$height)',
        );
      }
      final pixels = <int>[];
      for (var y = top; y < top + height; y++) {
        for (var x = left; x < left + width; x++) {
          final offset = (y * image.width + x) * 4;
          for (var channel = 0; channel < 4; channel++) {
            pixels.add(bytes.getUint8(offset + channel));
          }
        }
      }
      return pixels;
    } finally {
      image.dispose();
    }
  }))!;
}

Future<void>? _snapshotPixelFonts;

Future<void> _loadSnapshotPixelFonts() => _snapshotPixelFonts ??= () async {
  // 仅在本机测试中加载已有系统字形，不复制或把系统字体加入产品/源码包。
  await (FontLoader(
    'MaterialIcons',
  )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  for (final font in {
    'OpenNotePixelSegoe': 'segoeui.ttf',
    'OpenNotePixelYaHei': 'msyh.ttc',
  }.entries) {
    final file = File('C:/Windows/Fonts/${font.value}');
    if (!file.existsSync()) {
      throw StateError('像素回归需要本机已有字体：${file.path}');
    }
    await (FontLoader(
      font.key,
    )..addFont(file.readAsBytes().then(ByteData.sublistView))).load();
  }
}();

Future<Directory>? _pixelDirectory;

Future<Directory> _pixelEvidenceDirectory() => _pixelDirectory ??= () async {
  final root = Directory(
    '${Directory.current.path}/.local/continuous-alignment-20261004',
  );
  await root.create(recursive: true);
  final directory = await root.createTemp('map-pixel-007-');
  debugPrint('MAP_PIXEL_EVIDENCE_DIR=${directory.path}');
  return directory;
}();

Future<void> _pixelMask(
  WidgetTester tester,
  String id,
  List<int> first,
  List<int> second,
  String name,
) async {
  expect(second.length, first.length);
  final rect = tester.getRect(_mapNode(id));
  final ratio = View.of(tester.element(_mapNode(id))).devicePixelRatio;
  final width = (rect.width * ratio).round();
  final height = (rect.height * ratio).round();
  expect(first.length, width * height * 4);
  await tester.runAsync(() async {
    final pixels = Uint8List(first.length);
    for (var i = 0; i < first.length; i += 4) {
      final changed =
          (first[i] - second[i]).abs() +
              (first[i + 1] - second[i + 1]).abs() +
              (first[i + 2] - second[i + 2]).abs() >
          30;
      pixels[i] = 255;
      pixels[i + 1] = changed ? 0 : 255;
      pixels[i + 2] = changed ? 0 : 255;
      pixels[i + 3] = 255;
    }
    final decoded = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      pixels,
      width,
      height,
      ui.PixelFormat.rgba8888,
      decoded.complete,
    );
    final image = await decoded.future;
    try {
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      final directory = await _pixelEvidenceDirectory();
      await File('${directory.path}/$name.png')
          .writeAsBytes(bytes.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

double _pixelDifference(List<int> first, List<int> second) {
  expect(second.length, first.length);
  var changed = 0;
  for (var i = 0; i < first.length; i += 4) {
    final difference =
        (first[i] - second[i]).abs() +
        (first[i + 1] - second[i + 1]).abs() +
        (first[i + 2] - second[i + 2]).abs();
    if (difference > 30) changed++;
  }
  return changed / (first.length / 4);
}

int _redPixels(List<int> pixels) {
  var red = 0;
  for (var i = 0; i < pixels.length; i += 4) {
    if (pixels[i] > 200 && pixels[i + 1] < 60 && pixels[i + 2] < 60) red++;
  }
  return red;
}

MapSnapshot _withCardVisuals(
  MapSnapshot snapshot,
  String cardId, {
  String? title,
  String? body,
  String? note,
  String? color,
}) {
  final card = snapshot.cards[cardId]!;
  return MapSnapshot(
    map: snapshot.map,
    nodes: snapshot.nodes,
    cards: {
      ...snapshot.cards,
      cardId: NoteCard(
        id: card.id,
        projectId: card.projectId,
        title: title ?? card.title,
        excerptSnapshot: card.excerptSnapshot,
        body: body ?? card.body,
        note: note ?? card.note,
        color: color ?? card.color,
        imageResourceId: card.imageResourceId,
      ),
    },
    anchors: snapshot.anchors,
    edges: snapshot.edges,
  );
}

MapSnapshot _snapshot() => MapSnapshot(
  map: const MindMap(
    layout: MapLayoutKind.free,
    id: 'map',
    projectId: 'project',
    title: '测试脑图',
  ),
  nodes: const [
    MapNode(id: 'a', mapId: 'map', cardId: 'card-a', x: 0, y: 0),
    MapNode(id: 'b', mapId: 'map', cardId: 'card-b', x: 400, y: 0),
    MapNode(
      id: 'c',
      mapId: 'map',
      cardId: 'card-c',
      parentNodeId: 'a',
      x: 0,
      y: 180,
    ),
  ],
  cards: {
    for (final id in ['a', 'b', 'c']) 'card-$id': _card('card-$id'),
  },
  anchors: const {},
  edges: const [],
);

NoteCard _card(String id) => NoteCard(
  id: id,
  projectId: 'project',
  title: id,
  excerptSnapshot: '原始摘录',
  body: '中文知识卡片内容',
  note: '',
  color: '#F7D976',
);

NoteCard _imageCard(String id, String resourceId) => NoteCard(
  id: id,
  projectId: 'project',
  title: '截图摘录',
  excerptSnapshot: '',
  body: '',
  note: '图片备注',
  color: '#F7D976',
  imageResourceId: resourceId,
);
MapSnapshot _withNodes(MapSnapshot original, List<MapNode> nodes) =>
    MapSnapshot(
      map: original.map,
      nodes: nodes,
      cards: original.cards,
      anchors: original.anchors,
      edges: original.edges,
    );
MapSnapshot _withLayout(MapSnapshot original, MapLayoutKind layout) =>
    MapSnapshot(
      map: MindMap(
        id: original.map.id,
        projectId: original.map.projectId,
        title: original.map.title,
        deletedAt: original.map.deletedAt,
        defaultStyle: original.map.defaultStyle,
        layout: layout,
      ),
      nodes: original.nodes,
      cards: original.cards,
      anchors: original.anchors,
      edges: original.edges,
    );
MapNode _copyNode(MapNode n, {bool? collapsed}) => MapNode(
  id: n.id,
  mapId: n.mapId,
  cardId: n.cardId,
  x: n.x,
  y: n.y,
  width: n.width,
  height: n.height,
  parentNodeId: n.parentNodeId,
  collapsed: collapsed ?? n.collapsed,
);

Finder _mapNode(String id) => find.byKey(ValueKey('map-node-$id'));

Semantics _mapSemantics(WidgetTester tester, String id) =>
    tester.widget<Semantics>(
      find.descendant(
        of: _mapNode(id),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Semantics &&
              (widget.properties.label ?? '').startsWith('脑图卡片 '),
        ),
      ),
    );

Border _mapBorder(WidgetTester tester, String id) =>
    (tester
                    .widget<DecoratedBox>(
                      find.byKey(ValueKey('map-node-border-$id')),
                    )
                    .decoration
                as BoxDecoration)
            .border!
        as Border;

MapSnapshot _groupSnapshot({bool collapsed = true}) {
  final nodes = [
    MapNode(
      id: 'a',
      mapId: 'map',
      cardId: 'card-a',
      x: 0,
      y: 0,
      collapsed: collapsed,
    ),
    const MapNode(id: 'b', mapId: 'map', cardId: 'card-b', x: 400, y: 0),
    const MapNode(
      id: 'c',
      mapId: 'map',
      cardId: 'card-c',
      x: 0,
      y: 180,
      parentNodeId: 'a',
    ),
    const MapNode(
      id: 'd',
      mapId: 'map',
      cardId: 'card-d',
      x: 0,
      y: 360,
      parentNodeId: 'c',
    ),
    const MapNode(
      id: 'target',
      mapId: 'map',
      cardId: 'card-target',
      x: 400,
      y: 240,
    ),
  ];
  return MapSnapshot(
    map: _snapshot().map,
    nodes: nodes,
    cards: {for (final node in nodes) node.cardId: _card(node.cardId)},
    anchors: const {},
    edges: const [],
  );
}

MapNode _copyNodeAt(
  MapNode node, {
  double? x,
  double? y,
  String? parent,
  bool replaceParent = false,
  String? mapId,
}) => MapNode(
  id: node.id,
  mapId: mapId ?? node.mapId,
  cardId: node.cardId,
  x: x ?? node.x,
  y: y ?? node.y,
  width: node.width,
  height: node.height,
  parentNodeId: replaceParent ? parent : node.parentNodeId,
  collapsed: node.collapsed,
);

MapSnapshot _applyPositions(
  MapSnapshot snapshot,
  Map<String, PdfPoint> positions,
) => _withNodes(snapshot, [
  for (final node in snapshot.nodes)
    _copyNodeAt(node, x: positions[node.id]?.x, y: positions[node.id]?.y),
]);

MapSnapshot _withCardBody(MapSnapshot snapshot, String cardId, String body) {
  final card = snapshot.cards[cardId]!;
  return MapSnapshot(
    map: snapshot.map,
    nodes: snapshot.nodes,
    cards: {
      ...snapshot.cards,
      cardId: NoteCard(
        id: card.id,
        projectId: card.projectId,
        title: card.title,
        excerptSnapshot: card.excerptSnapshot,
        body: body,
        note: card.note,
        color: card.color,
        imageResourceId: card.imageResourceId,
      ),
    },
    anchors: snapshot.anchors,
    edges: snapshot.edges,
  );
}
