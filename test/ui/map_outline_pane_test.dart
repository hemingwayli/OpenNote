import 'package:opennote/ui/theme/open_note_context_menu.dart';

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opennote/domain/models.dart';
import 'package:opennote/ui/map/map_outline_pane.dart';

void main() {
  testWidgets('大纲多选：连续Ctrl完整点击按最新集合切换，普通点击回到单选', (tester) async {
    final toggled = <String>[];
    final selected = <String>[];
    final activated = <String>[];
    var ids = <String>{};
    String? primary;
    final snapshot = _snapshot([_node('a'), _node('b', y: 80)]);
    await tester.pumpWidget(
      _frame(
        StatefulBuilder(
          builder: (context, setState) {
            return _pane(
              snapshot,
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
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    for (final id in ['a', 'b']) {
      final click = await tester.startGesture(
        tester.getCenter(_row(id)),
        kind: PointerDeviceKind.mouse,
      );
      await click.up();
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(toggled, ['a', 'b']);
    expect(ids, {'a', 'b'});
    expect(primary, 'b');
    expect(selected, isEmpty);
    expect(activated, isEmpty);
    expect(tester.widget<Semantics>(_row('a')).properties.value, '已选');
    expect(tester.widget<Semantics>(_row('b')).properties.value, '主选');
    expect(_outlineBorder(tester, 'a').width, 1);
    expect(_outlineBorder(tester, 'b').width, 1);
    expect(
      _outlineBorder(tester, 'b').color,
      isNot(_outlineBorder(tester, 'a').color),
    );
    await tester.tap(_row('a'), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(ids, {'a'});
    expect(selected, ['a']);
    expect(activated, ['a']);
    expect(tester.widget<Semantics>(_row('b')).properties.selected, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('大纲多选：Ctrl提前松开和同ID正文刷新不丢捕获，取消与滚动不切换', (tester) async {
    var snapshot = _snapshot([
      _node('a'),
      _node('b', y: 80),
      for (var index = 0; index < 30; index++)
        _node('scroll-$index', y: 160 + index * 60.0),
    ]);
    late StateSetter refresh;
    final toggled = <String>[];
    final selected = <String>[];
    final activated = <String>[];
    await tester.pumpWidget(
      _frame(
        StatefulBuilder(
          builder: (context, setState) {
            refresh = setState;
            return _pane(
              snapshot,
              selectedNodeId: 'a',
              selectedNodeIds: const {'a'},
              onSelect: (node) => selected.add(node.id),
              onToggleSelection: (node) => toggled.add(node.id),
              onActivate: (node) => activated.add(node.id),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    final click = await tester.startGesture(
      tester.getCenter(_row('b')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    refresh(
      () => snapshot = MapSnapshot(
        map: snapshot.map,
        nodes: snapshot.nodes,
        cards: {
          ...snapshot.cards,
          'card-b': _card('b', body: '后台OCR刷新后的正文'),
        },
        anchors: snapshot.anchors,
        edges: snapshot.edges,
      ),
    );
    await tester.pump();
    await click.up();
    await tester.pumpAndSettle();
    expect(toggled, ['b']);
    expect(selected, isEmpty);
    expect(activated, isEmpty);
    expect(tester.widget<Semantics>(_row('a')).properties.value, '已选');
    expect(tester.widget<Semantics>(_row('b')).properties.value, '主选');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    final cancelled = await tester.startGesture(
      tester.getCenter(_row('scroll-0')),
      kind: PointerDeviceKind.mouse,
    );
    await cancelled.cancel();
    await tester.pumpAndSettle();
    final list = tester.widget<ListView>(
      find.byKey(const ValueKey('outline-list')),
    );
    final startOffset = list.controller!.offset;
    // Windows 标准 ListView 用鼠标滚轮滚动；默认不把鼠标按住当作触摸拖动。
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(find.byKey(const ValueKey('outline-list'))),
        kind: PointerDeviceKind.mouse,
        scrollDelta: const Offset(0, 90),
      ),
    );
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(list.controller!.offset, greaterThan(startOffset));
    expect(toggled, ['b']);
    expect(selected, isEmpty);
    expect(activated, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('大纲多选：隐藏选中后代随折叠恢复，正文显示保组且来源菜单保持单目标', (tester) async {
    var snapshot = _snapshot(
      [_node('root', collapsed: true), _node('child', parent: 'root', y: 80)],
      anchors: {
        'card-child': [
          SourceAnchor(
            id: 'source',
            cardId: 'card-child',
            revisionId: 'revision',
            pageIndex: 0,
            quads: [PdfQuad.rect(10, 20, 40, 50)],
          ),
        ],
      },
    );
    var ids = <String>{'root', 'child'};
    var primary = 'child';
    late StateSetter refresh;
    final selected = <String>[];
    final activated = <String>[];
    final actions = <(String, String)>[];
    await tester.pumpWidget(
      _frame(
        StatefulBuilder(
          builder: (context, setState) {
            refresh = setState;
            return _pane(
              snapshot,
              selectedNodeId: primary,
              selectedNodeIds: ids,
              onSelect: (node) {
                selected.add(node.id);
                setState(() {
                  ids = {node.id};
                  primary = node.id;
                });
              },
              onToggleSelection: (_) {},
              onActivate: (node) => activated.add(node.id),
              onAction: (node, action) => actions.add((node.id, action)),
              onToggleCollapsed: (id) => setState(() {
                snapshot = _withNodes(snapshot, [
                  for (final node in snapshot.nodes)
                    node.id == id
                        ? _copyNode(node, collapsed: !node.collapsed)
                        : node,
                ]);
              }),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(_row('child'), findsNothing);
    expect(tester.widget<Semantics>(_row('root')).properties.selected, isTrue);
    await tester.tap(find.byKey(const ValueKey('outline-collapse-root')));
    await tester.pumpAndSettle();
    expect(_row('child'), findsOneWidget);
    expect(tester.widget<Semantics>(_row('child')).properties.value, '主选');
    expect(tester.widget<Semantics>(_row('root')).properties.value, '已选');
    await tester.tap(find.byKey(const ValueKey('outline-show-body')));
    await tester.pumpAndSettle();
    expect(find.text('正文-child'), findsOneWidget);
    expect(ids, {'root', 'child'});
    expect(selected, isEmpty);
    await tester.tap(find.byKey(const ValueKey('outline-source-child')));
    await tester.pumpAndSettle();
    expect(ids, {'child'});
    expect(selected, ['child']);
    expect(actions, [('child', 'source')]);
    expect(activated, isEmpty);
    refresh(() => ids = {'root', 'child'});
    await tester.pumpAndSettle();
    final menuButton = find.byKey(const ValueKey('outline-menu-root'));
    final menuState = tester.state(menuButton);
    await tester.tap(menuButton, kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(menuState.mounted, isTrue, reason: '切换主选不能销毁等待菜单结果的按钮');
    expect(identical(tester.state(menuButton), menuState), isTrue);
    final remove = find.widgetWithText(OpenNoteMenuItem<String>, '分支卡片移入回收站');
    expect(remove.hitTestable(), findsOneWidget);
    await tester.tap(remove, kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(ids, {'root'});
    expect(actions.last, ('root', 'removeBranch'));
    expect(activated, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('大纲多选：切图取消按住的Ctrl点击，新图后续普通点击可用', (tester) async {
    var snapshot = _snapshot([_node('a'), _node('b', y: 80)]);
    late StateSetter refresh;
    final toggled = <String>[];
    final selected = <String>[];
    final activated = <String>[];
    await tester.pumpWidget(
      _frame(
        StatefulBuilder(
          builder: (context, setState) {
            refresh = setState;
            return _pane(
              snapshot,
              selectedNodeId: 'a',
              selectedNodeIds: const {'a'},
              onSelect: (node) => selected.add(node.id),
              onToggleSelection: (node) => toggled.add(node.id),
              onActivate: (node) => activated.add(node.id),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    final click = await tester.startGesture(
      tester.getCenter(_row('b')),
      kind: PointerDeviceKind.mouse,
    );
    refresh(
      () => snapshot = MapSnapshot(
        map: const MindMap(
          layout: MapLayoutKind.free,
          id: 'next-map',
          projectId: 'project',
          title: '下一大纲',
        ),
        nodes: [
          for (final node in snapshot.nodes)
            MapNode(
              id: node.id,
              mapId: 'next-map',
              cardId: node.cardId,
              x: node.x,
              y: node.y,
              parentNodeId: node.parentNodeId,
              collapsed: node.collapsed,
              width: node.width,
              height: node.height,
            ),
        ],
        cards: snapshot.cards,
        anchors: snapshot.anchors,
        edges: snapshot.edges,
      ),
    );
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await click.up();
    await tester.pumpAndSettle();
    expect(toggled, isEmpty);
    expect(selected, isEmpty);
    expect(activated, isEmpty);
    await tester.tap(_row('b'), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(selected, ['b']);
    expect(activated, ['b']);
    expect(toggled, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('大纲按同层坐标稳定浏览，孤立环有限显示', (tester) async {
    final nodes = [
      _node('second', x: 50),
      _node('child-b', parent: 'root', x: 10, y: 20),
      _node('leaf', parent: 'child-b', y: 40),
      _node('child-a', parent: 'root', x: 10, y: 20),
      _node('root', x: 30),
      _node('orphan', parent: 'missing', y: 100),
    ];
    await tester.pumpWidget(_host(_snapshot(nodes)));
    await tester.pumpAndSettle();
    final order = ['root', 'child-a', 'child-b', 'leaf', 'second', 'orphan'];
    final positions = [for (final id in order) tester.getTopLeft(_row(id)).dy];
    expect(positions, orderedEquals([...positions]..sort()));
    expect(
      tester.widget<Semantics>(_row('leaf')).properties.label,
      '大纲第 3 级 标题-leaf',
    );
    expect(
      tester
          .widgetList<Container>(
            find.descendant(of: _row('root'), matching: find.byType(Container)),
          )
          .any((widget) => widget.color == const Color(0xFFF7D976)),
      isTrue,
    );
    await tester.pumpWidget(
      _host(_snapshot([_node('a', parent: 'b'), _node('b', parent: 'a')])),
    );
    await tester.pumpAndSettle();
    expect(_row('a'), findsOneWidget);
    expect(_row('b'), findsOneWidget);
    expect(
      tester
          .widget<ListView>(find.byKey(const ValueKey('outline-list')))
          .childrenDelegate
          .estimatedChildCount,
      2,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('2500层深树迭代展开且只构建视口行', (tester) async {
    final nodes = List.generate(
      2500,
      (index) =>
          _node('deep-$index', parent: index == 0 ? null : 'deep-${index - 1}'),
    );
    await tester.pumpWidget(_host(_snapshot(nodes)));
    await tester.pumpAndSettle();
    final list = tester.widget<ListView>(
      find.byKey(const ValueKey('outline-list')),
    );
    expect(list.childrenDelegate.estimatedChildCount, 2500);
    expect(_row('deep-2499'), findsNothing);
    final rows = find.byWidgetPredicate(
      (widget) =>
          widget is Semantics &&
          widget.key is ValueKey<String> &&
          (widget.key! as ValueKey<String>).value.startsWith('outline-node-'),
    );
    expect(rows.evaluate().length, lessThan(40));
    list.controller!.jumpTo(list.controller!.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(_row('deep-2499'), findsOneWidget);
    expect(find.text('L2500'), findsOneWidget);
    expect(
      tester.widget<Semantics>(_row('deep-2499')).properties.label,
      '大纲第 2500 级 标题-deep-2499',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('正文显示和分支折叠独立，隐藏后代不会冒充根节点', (tester) async {
    var snapshot = _snapshot([
      _node('root', collapsed: true),
      _node('child', parent: 'root'),
      _node('leaf', parent: 'child'),
    ]);
    final folded = <String>[];
    await tester.pumpWidget(
      _frame(
        StatefulBuilder(
          builder: (context, setState) => _pane(
            snapshot,
            onToggleCollapsed: (id) => setState(() {
              folded.add(id);
              snapshot = _withNodes(snapshot, [
                for (final node in snapshot.nodes)
                  node.id == id
                      ? _copyNode(node, collapsed: !node.collapsed)
                      : node,
              ]);
            }),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(_row('root'), findsOneWidget);
    expect(_row('child'), findsNothing);
    expect(_row('leaf'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('outline-show-body')));
    await tester.pumpAndSettle();
    expect(find.text('正文-root'), findsOneWidget);
    expect(_row('child'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('outline-collapse-root')));
    await tester.pumpAndSettle();
    expect(folded, ['root']);
    expect(_row('child'), findsOneWidget);
    expect(find.text('正文-leaf'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('outline-single-line')));
    await tester.pumpAndSettle();
    expect(_row('leaf'), findsOneWidget);
    expect(find.text('正文-leaf'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('完整鼠标点击激活，外部选择与新卡片正文同步', (tester) async {
    var snapshot = _snapshot([_node('a'), _node('b', y: 80)]);
    String? selected;
    late StateSetter refresh;
    final activated = <String>[];
    await tester.pumpWidget(
      _frame(
        StatefulBuilder(
          builder: (context, setState) {
            refresh = setState;
            return _pane(
              snapshot,
              selectedNodeId: selected,
              onSelect: (node) => setState(() => selected = node.id),
              onActivate: (node) => activated.add(node.id),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final click = await tester.startGesture(
      tester.getCenter(_row('a')),
      kind: PointerDeviceKind.mouse,
    );
    expect(activated, isEmpty);
    await click.up();
    await tester.pumpAndSettle();
    expect(activated, ['a']);
    expect(tester.widget<Semantics>(_row('a')).properties.selected, isTrue);
    refresh(() {
      selected = 'b';
      snapshot = MapSnapshot(
        map: snapshot.map,
        nodes: snapshot.nodes,
        cards: {
          ...snapshot.cards,
          'card-b': _card('b', title: '编辑后的标题', body: '最新卡片正文'),
        },
        anchors: snapshot.anchors,
        edges: snapshot.edges,
      );
    });
    await tester.pumpAndSettle();
    expect(tester.widget<Semantics>(_row('a')).properties.selected, isFalse);
    expect(tester.widget<Semantics>(_row('b')).properties.selected, isTrue);
    expect(find.text('编辑后的标题'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('outline-show-body')));
    await tester.pumpAndSettle();
    expect(find.text('最新卡片正文'), findsOneWidget);
    expect(activated, ['a'], reason: '外部反选不会重复触发用户激活');
    expect(tester.takeException(), isNull);
  });

  testWidgets('来源和菜单沿用脑图动作合同，禁用创建与无来源入口', (tester) async {
    final actions = <(String, String)>[];
    final activated = <String>[];
    final selected = <String>[];
    final snapshot = _snapshot(
      [_node('source'), _node('plain', y: 80)],
      anchors: {
        'card-source': [
          SourceAnchor(
            id: 'anchor',
            cardId: 'card-source',
            revisionId: 'revision',
            pageIndex: 0,
            quads: [PdfQuad.rect(10, 20, 40, 50)],
          ),
        ],
      },
    );
    Widget host({bool canCreate = true}) => _host(
      snapshot,
      canCreate: canCreate,
      onSelect: (node) => selected.add(node.id),
      onActivate: (node) => activated.add(node.id),
      onAction: (node, action) => actions.add((node.id, action)),
    );
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('outline-source-plain')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('outline-source-source')));
    await tester.pumpAndSettle();
    expect(actions, [('source', 'source')]);
    expect(selected, ['source']);
    expect(activated, isEmpty);
    const menuActions = [
      ('编辑卡片', 'edit'),
      ('回到原文', 'source'),
      ('新建子主题', 'newChild'),
      ('新建同级主题', 'newSibling'),
      ('卡片颜色…', 'color'),
      ('复制独立分支…', 'copyBranch'),
      ('分支卡片移入回收站', 'removeBranch'),
    ];
    for (final entry in menuActions) {
      await tester.tap(find.byKey(const ValueKey('outline-menu-source')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(entry.$1));
      await tester.pumpAndSettle();
      expect(actions.last, ('source', entry.$2));
    }
    expect(activated, isEmpty);
    await tester.pumpWidget(host(canCreate: false));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('outline-menu-plain')));
    await tester.pumpAndSettle();
    for (final label in ['回到原文', '新建子主题', '新建同级主题']) {
      final menu = find.ancestor(
        of: find.text(label),
        matching: find.byType(OpenNoteMenuItem<String>),
      );
      expect(tester.widget<OpenNoteMenuItem<String>>(menu).enabled, isFalse);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('外部深层选择在完整长正文模式可见，同ID刷新不抢手动滚动', (tester) async {
    final nodes = List.generate(
      600,
      (index) => _node('row-$index', y: index * 60.0),
    );
    var snapshot = _snapshot(
      nodes,
      cards: {
        for (var index = 0; index < 600; index++)
          'card-row-$index': _card(
            'row-$index',
            body: List.filled(8, '长正文包含完整中文知识解释与摘录内容。').join('\n'),
          ),
      },
    );
    String? selected;
    late StateSetter refresh;
    await tester.pumpWidget(
      _frame(
        StatefulBuilder(
          builder: (context, setState) {
            refresh = setState;
            return _pane(snapshot, selectedNodeId: selected);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('outline-show-body')));
    await tester.pumpAndSettle();
    expect(_row('row-500'), findsNothing);
    refresh(() => selected = 'row-500');
    await tester.pumpAndSettle();
    final listFinder = find.byKey(const ValueKey('outline-list'));
    expect(_row('row-500'), findsOneWidget);
    expect(
      tester.widget<Semantics>(_row('row-500')).properties.selected,
      isTrue,
    );
    final viewport = tester.getRect(listFinder);
    final title = find.descendant(
      of: _row('row-500'),
      matching: find.text('标题-row-500'),
    );
    expect(viewport.contains(tester.getCenter(title)), isTrue);
    final body = tester.widget<Text>(
      find.byKey(const ValueKey('outline-body-row-500')),
    );
    expect(body.maxLines, isNull);
    expect(body.data, contains('\n'));
    final controller = tester.widget<ListView>(listFinder).controller!;
    controller.jumpTo(0);
    await tester.pumpAndSettle();
    expect(_row('row-500'), findsNothing);
    refresh(
      () => snapshot = MapSnapshot(
        map: snapshot.map,
        nodes: snapshot.nodes,
        cards: {
          ...snapshot.cards,
          'card-row-0': _card('row-0', title: '普通快照更新'),
        },
        anchors: snapshot.anchors,
        edges: snapshot.edges,
      ),
    );
    await tester.pumpAndSettle();
    expect(controller.offset, closeTo(0, .01));
    expect(_row('row-500'), findsNothing);
    expect(find.text('普通快照更新'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('已选中的隐藏后代在折叠快照展开后才定位', (tester) async {
    var snapshot = _snapshot([
      _node('root', collapsed: true),
      for (var index = 0; index < 200; index++)
        _node('child-$index', parent: 'root', y: index * 60.0),
    ]);
    await tester.pumpWidget(
      _frame(
        StatefulBuilder(
          builder: (context, setState) => _pane(
            snapshot,
            selectedNodeId: 'child-199',
            onToggleCollapsed: (id) => setState(() {
              snapshot = _withNodes(snapshot, [
                for (final node in snapshot.nodes)
                  node.id == id
                      ? _copyNode(node, collapsed: !node.collapsed)
                      : node,
              ]);
            }),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(_row('child-199'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('outline-show-body')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('outline-collapse-root')));
    await tester.pumpAndSettle();
    expect(_row('child-199'), findsOneWidget);
    final title = find.descendant(
      of: _row('child-199'),
      matching: find.text('标题-child-199'),
    );
    expect(
      tester
          .getRect(find.byKey(const ValueKey('outline-list')))
          .contains(tester.getCenter(title)),
      isTrue,
    );
    expect(
      tester.widget<Semantics>(_row('child-199')).properties.selected,
      isTrue,
    );
    expect(
      find.byKey(const ValueKey('outline-body-child-199')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('正文截图由真实资源解码，单行和离屏行不查询图片', (tester) async {
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('opennote-outline-image-'),
    ))!;
    try {
      final imagePath = '${directory.path}${Platform.pathSeparator}自产截图.png';
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawRect(
          const Rect.fromLTWH(0, 0, 24, 20),
          Paint()..color = Colors.blue,
        );
        final picture = recorder.endRecording();
        final image = await picture.toImage(24, 20);
        try {
          final bytes = (await image.toByteData(
            format: ui.ImageByteFormat.png,
          ))!;
          await File(imagePath).writeAsBytes(bytes.buffer.asUint8List());
        } finally {
          image.dispose();
          picture.dispose();
        }
      });
      final requests = <String>[];
      Future<String> resolver(String resourceId) async {
        requests.add(resourceId);
        return imagePath;
      }

      final nodes = List.generate(
        60,
        (index) => _node('image-$index', y: index * 60.0),
      );
      final snapshot = _snapshot(
        nodes,
        cards: {
          'card-image-0': _card(
            'image-0',
            body: '图片摘录说明',
            note: '图片备注',
            imageResourceId: 'visible',
          ),
          'card-image-59': _card('image-59', imageResourceId: 'offscreen'),
        },
      );
      await tester.pumpWidget(_host(snapshot, imagePathResolver: resolver));
      await tester.pumpAndSettle();
      expect(requests, isEmpty);
      await tester.tap(find.byKey(const ValueKey('outline-show-body')));
      await tester.pump();
      final raw = find.descendant(
        of: find.byKey(const ValueKey('outline-image-image-0')),
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
      expect(raw, findsOneWidget);
      expect(tester.renderObject<RenderImage>(raw).image, isNotNull);
      expect(
        tester.renderObject<RenderImage>(raw).image!.width,
        greaterThan(0),
      );
      expect(find.text('图片摘录说明'), findsOneWidget);
      expect(find.text('图片备注'), findsOneWidget);
      expect(requests, ['visible']);
      expect(_row('image-59'), findsNothing);
      await tester.pumpWidget(
        _host(snapshot, selectedNodeId: 'image-0', imagePathResolver: resolver),
      );
      await tester.pumpAndSettle();
      expect(requests, ['visible']);
      await tester.tap(find.byKey(const ValueKey('outline-single-line')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('outline-show-body')));
      await tester.pumpAndSettle();
      expect(requests, ['visible'], reason: '销毁并重建正文行仍复用同一资源路径');
      final replacement = MapSnapshot(
        map: snapshot.map,
        nodes: snapshot.nodes,
        cards: {
          ...snapshot.cards,
          'card-image-0': _card('image-0', imageResourceId: 'replacement'),
        },
        anchors: snapshot.anchors,
        edges: snapshot.edges,
      );
      await tester.pumpWidget(
        _host(
          replacement,
          selectedNodeId: 'image-0',
          imagePathResolver: resolver,
        ),
      );
      await tester.pumpAndSettle();
      expect(requests, ['visible', 'replacement'], reason: '换资源不能复用旧图片的路径');
      final replacementRequests = <String>[];
      Future<String> replacementResolver(String id) async {
        replacementRequests.add(id);
        return imagePath;
      }

      await tester.pumpWidget(
        _host(
          replacement,
          selectedNodeId: 'image-0',
          imagePathResolver: replacementResolver,
        ),
      );
      await tester.pumpAndSettle();
      expect(replacementRequests, [
        'replacement',
      ], reason: '新resolver拥有独立资源路径结果');
      await tester.pumpWidget(
        _host(
          MapSnapshot(
            map: const MindMap(
              layout: MapLayoutKind.free,
              id: 'new-map',
              projectId: 'project',
              title: '另一脑图',
            ),
            nodes: replacement.nodes,
            cards: replacement.cards,
            anchors: replacement.anchors,
            edges: replacement.edges,
          ),
          selectedNodeId: 'image-0',
          imagePathResolver: replacementResolver,
        ),
      );
      await tester.pumpAndSettle();
      expect(replacementRequests, [
        'replacement',
        'replacement',
      ], reason: '脑图切换清空原资源路径缓存');
      expect(requests, ['visible', 'replacement']);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await directory.delete(recursive: true);
      });
    }
  });
}

Finder _row(String id) => find.byKey(ValueKey('outline-node-$id'));

Widget _frame(Widget child) => MaterialApp(
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(width: 300, height: 420, child: child),
    ),
  ),
);

Widget _host(
  MapSnapshot snapshot, {
  String? selectedNodeId,
  Set<String>? selectedNodeIds,
  void Function(MapNode)? onSelect,
  void Function(MapNode)? onToggleSelection,
  void Function(MapNode)? onActivate,
  void Function(MapNode, String)? onAction,
  void Function(String)? onToggleCollapsed,
  bool canCreate = true,
  Future<String> Function(String)? imagePathResolver,
}) => _frame(
  _pane(
    snapshot,
    selectedNodeId: selectedNodeId,
    selectedNodeIds: selectedNodeIds,
    onSelect: onSelect,
    onToggleSelection: onToggleSelection,
    onActivate: onActivate,
    onAction: onAction,
    onToggleCollapsed: onToggleCollapsed,
    canCreate: canCreate,
    imagePathResolver: imagePathResolver,
  ),
);

MapOutlinePane _pane(
  MapSnapshot snapshot, {
  String? selectedNodeId,
  Set<String>? selectedNodeIds,
  void Function(MapNode)? onSelect,
  void Function(MapNode)? onToggleSelection,
  void Function(MapNode)? onActivate,
  void Function(MapNode, String)? onAction,
  void Function(String)? onToggleCollapsed,
  bool canCreate = true,
  Future<String> Function(String)? imagePathResolver,
}) => MapOutlinePane(
  snapshot: snapshot,
  selectedNodeId: selectedNodeId,
  selectedNodeIds: selectedNodeIds,
  onSelect: onSelect ?? (_) {},
  onToggleSelection: onToggleSelection,
  onActivate: onActivate,
  onAction: onAction ?? (_, _) {},
  onToggleCollapsed: onToggleCollapsed ?? (_) {},
  canCreate: canCreate,
  imagePathResolver: imagePathResolver,
);

MapNode _node(
  String id, {
  String? parent,
  double x = 0,
  double y = 0,
  bool collapsed = false,
}) => MapNode(
  id: id,
  mapId: 'map',
  cardId: 'card-$id',
  x: x,
  y: y,
  parentNodeId: parent,
  collapsed: collapsed,
);

NoteCard _card(
  String id, {
  String? title,
  String? body,
  String note = '',
  String? imageResourceId,
}) => NoteCard(
  id: 'card-$id',
  projectId: 'project',
  title: title ?? '标题-$id',
  excerptSnapshot: '原始摘录-$id',
  body: body ?? '正文-$id',
  note: note,
  color: '#F7D976',
  imageResourceId: imageResourceId,
);

MapSnapshot _snapshot(
  List<MapNode> nodes, {
  Map<String, NoteCard> cards = const {},
  Map<String, List<SourceAnchor>> anchors = const {},
}) => MapSnapshot(
  map: const MindMap(
    layout: MapLayoutKind.free,
    id: 'map',
    projectId: 'project',
    title: '测试大纲',
  ),
  nodes: nodes,
  cards: {for (final node in nodes) node.cardId: _card(node.id), ...cards},
  anchors: anchors,
  edges: const [],
);

MapSnapshot _withNodes(MapSnapshot original, List<MapNode> nodes) =>
    MapSnapshot(
      map: original.map,
      nodes: nodes,
      cards: original.cards,
      anchors: original.anchors,
      edges: original.edges,
    );

MapNode _copyNode(MapNode node, {required bool collapsed}) => MapNode(
  id: node.id,
  mapId: node.mapId,
  cardId: node.cardId,
  x: node.x,
  y: node.y,
  parentNodeId: node.parentNodeId,
  width: node.width,
  height: node.height,
  collapsed: collapsed,
);

BorderSide _outlineBorder(WidgetTester tester, String id) =>
    (tester
                .widget<Material>(
                  find.byKey(ValueKey('outline-row-surface-$id')),
                )
                .shape!
            as RoundedRectangleBorder)
        .side;
