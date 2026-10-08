import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opennote/domain/models.dart';
import 'package:opennote/ui/map/mind_map_pane.dart';

void main() {
  setUpAll(() async {
    final font = FontLoader('Source Han Sans CN');
    font.addFont(
      rootBundle.load(
        'assets/fonts/source-han-sans/SourceHanSansCN-Regular.otf',
      ),
    );
    await font.load();
    final icons = FontLoader('MaterialIcons');
    icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });
  testWidgets('Xmind 折叠：选中显示外侧空心圆，取消选中隐藏，叶主题没有控件', (tester) async {
    final host = await _mount(tester);
    expect(_control('a'), findsNothing);
    await tester.tap(_node('a'));
    await tester.pumpAndSettle();
    expect(_control('a'), findsOneWidget);
    final rect = tester.getRect(_node('a'));
    final control = tester.getRect(_control('a'));
    expect(control.center.dx, closeTo(rect.right + 12, .01));
    expect(control.center.dy, closeTo(rect.center.dy, .01));
    expect(control.width, 24);
    expect(control.height, 24);
    expect(
      find.descendant(of: _control('a'), matching: find.byType(Text)),
      findsNothing,
    );
    final beforeHover = List<String>.of(host.events);
    final pointer = await tester.createGesture(
      kind: ui.PointerDeviceKind.mouse,
    );
    await pointer.addPointer(location: const Offset(20, 90));
    await pointer.moveTo(control.center);
    await tester.pump();
    BoxDecoration badgeStyle() =>
        tester
                .widget<Container>(
                  find.byKey(const ValueKey('map-collapse-badge-a')),
                )
                .decoration!
            as BoxDecoration;
    expect(badgeStyle().color, isNot(Colors.white));
    expect(host.events, beforeHover);
    await pointer.moveTo(const Offset(20, 90));
    await pointer.removePointer();
    await tester.pump();
    expect(badgeStyle().color, Colors.white);
    await _capture(tester, host.boundary, 'expanded');
    await tester.tap(_node('c'));
    await tester.pumpAndSettle();
    expect(_control('a'), findsNothing);
    expect(_control('c'), findsNothing);
  });

  testWidgets('Xmind 折叠：数字包含隐藏孙主题，点击单选并保留深层状态，不激活卡片', (tester) async {
    final host = await _mount(
      tester,
      rootCollapsed: true,
      childCollapsed: true,
    );
    expect(
      find.descendant(of: _control('a'), matching: find.text('3')),
      findsOneWidget,
    );
    expect(_node('b'), findsNothing);
    await _capture(tester, host.boundary, 'collapsed');
    final beforeScale = host.controller.scale;
    await tester.tap(_control('a'));
    await tester.pumpAndSettle();
    expect(host.events, ['select:a', 'toggle:a']);
    expect(_node('b'), findsOneWidget);
    expect(_node('d'), findsNothing);
    expect(
      find.descendant(of: _control('b'), matching: find.text('1')),
      findsOneWidget,
    );
    expect(host.controller.scale, beforeScale);
    await tester.tap(_control('a'));
    await tester.pumpAndSettle();
    expect(_node('b'), findsNothing);
    expect(host.events, ['select:a', 'toggle:a', 'toggle:a']);
    await tester.tapAt(const Offset(780, 550));
    await tester.pumpAndSettle();
    expect(_control('a'), findsOneWidget);
    expect(
      find.descendant(of: _control('a'), matching: find.text('3')),
      findsOneWidget,
    );
    expect(host.events.any((event) => event.startsWith('activate:')), isFalse);
  });

  for (final layout in [
    MapLayoutKind.left,
    MapLayoutKind.up,
    MapLayoutKind.down,
  ]) {
    testWidgets('Xmind 折叠：${layout.name} 的入口沿有效出枝方向且命中独立', (tester) async {
      final host = await _mount(tester, layout: layout, rootCollapsed: true);
      final rect = tester.getRect(_node('a'));
      final center = tester.getCenter(_control('a'));
      final expected = switch (layout) {
        MapLayoutKind.left => rect.centerLeft - const Offset(12, 0),
        MapLayoutKind.up => rect.topCenter - const Offset(0, 12),
        _ => rect.bottomCenter + const Offset(0, 12),
      };
      expect((center - expected).distance, lessThan(.01));
      await tester.tap(_control('a'));
      await tester.pumpAndSettle();
      expect(host.events, ['select:a', 'toggle:a']);
    });
  }

  testWidgets('Xmind 折叠：75% 缩放和局部分支方向覆盖仍使用真实外侧命中', (tester) async {
    final host = await _mount(
      tester,
      rootCollapsed: true,
      branchLayout: MapLayoutKind.left,
    );
    host.controller.setView(scale: .75, worldTopLeft: const Offset(-150, -150));
    await tester.pump();
    final rect = tester.getRect(_node('a'));
    final center = tester.getCenter(_control('a'));
    expect(center.dx, closeTo(rect.left - 9, .01));
    await tester.tap(_control('a'));
    await tester.pumpAndSettle();
    expect(host.events, ['select:a', 'toggle:a']);
    expect(host.controller.scale, .75);
  });

  testWidgets('Xmind 折叠：快捷键区分当前主题与整棵分支，编辑输入不拦截', (tester) async {
    final host = await _mount(tester);
    await tester.tap(_node('a'));
    await tester.pumpAndSettle();
    await _shortcut(tester);
    expect(host.events.last, 'toggle:a');
    await _shortcut(tester, recursive: true);
    expect(host.events.last, 'action:a:collapseBranch');
    await tester.tap(find.byKey(const Key('typing')));
    await tester.pumpAndSettle();
    final count = host.events.length;
    await _shortcut(tester);
    await _shortcut(tester, recursive: true);
    expect(host.events.length, count);
  });

  testWidgets('Xmind 折叠：三位后代数字完整显示，外侧徽标与热区不遮挡节点', (tester) async {
    final host = await _mount(tester, rootCollapsed: true, extraChildren: 97);
    final rect = tester.getRect(_node('a'));
    final badge = find.byKey(const ValueKey('map-collapse-badge-a'));
    expect(
      find.descendant(of: badge, matching: find.text('100')),
      findsOneWidget,
    );
    expect(tester.getRect(badge).left, greaterThan(rect.right));
    expect(tester.getRect(_control('a')).left, closeTo(rect.right, .01));
    await tester.tap(_control('a'));
    await tester.pumpAndSettle();
    expect(host.events, ['select:a', 'toggle:a']);
  });

  testWidgets('Xmind 折叠：右键命令与快捷键显示一致', (tester) async {
    final host = await _mount(tester);
    final mouse = await tester.startGesture(
      tester.getCenter(_node('a')),
      kind: ui.PointerDeviceKind.mouse,
      buttons: 2,
    );
    await mouse.up();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('map-menu-collapseMenu')));
    await tester.pumpAndSettle();
    expect(find.text('折叠细分主题'), findsOneWidget);
    expect(find.text('Ctrl+/'), findsOneWidget);
    expect(find.text('Ctrl+Alt+/'), findsOneWidget);
    await tester.ensureVisible(find.text('折叠所有次级分支'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('折叠所有次级分支'));
    await tester.pumpAndSettle();
    expect(host.events.last, 'action:a:collapseBranch');
  });
}

Finder _node(String id) => find.byKey(ValueKey('map-node-$id'));
Finder _control(String id) => find.byKey(ValueKey('map-collapse-$id'));

Future<void> _shortcut(WidgetTester tester, {bool recursive = false}) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  if (recursive) await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.slash);
  if (recursive) await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
}

class _Host {
  final controller = MindMapPaneController();
  final boundary = GlobalKey();
  final events = <String>[];
}

Future<_Host> _mount(
  WidgetTester tester, {
  bool rootCollapsed = false,
  bool childCollapsed = false,
  MapLayoutKind layout = MapLayoutKind.right,
  MapLayoutKind? branchLayout,
  int extraChildren = 0,
}) async {
  final host = _Host();
  var folded = {'a': rootCollapsed, 'b': childCollapsed};
  String? selected;
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(fontFamily: 'Source Han Sans CN'),
      home: Scaffold(
        body: RepaintBoundary(
          key: host.boundary,
          child: StatefulBuilder(
            builder: (context, setState) => Column(
              children: [
                const ColoredBox(
                  color: Colors.white,
                  child: SizedBox(
                    height: 40,
                    child: TextField(key: Key('typing')),
                  ),
                ),
                Expanded(
                  child: MindMapPane(
                    snapshot: MapSnapshot(
                      map: MindMap(
                        id: 'map',
                        projectId: 'project',
                        title: '折叠体验',
                        layout: layout,
                      ),
                      nodes: [
                        MapNode(
                          id: 'a',
                          mapId: 'map',
                          cardId: 'a',
                          x: 100,
                          y: 100,
                          collapsed: folded['a']!,
                          branchLayout: branchLayout,
                        ),
                        MapNode(
                          id: 'b',
                          mapId: 'map',
                          cardId: 'b',
                          parentNodeId: 'a',
                          x: 400,
                          y: 100,
                          collapsed: folded['b']!,
                        ),
                        const MapNode(
                          id: 'c',
                          mapId: 'map',
                          cardId: 'c',
                          parentNodeId: 'a',
                          x: 400,
                          y: 260,
                        ),
                        const MapNode(
                          id: 'd',
                          mapId: 'map',
                          cardId: 'd',
                          parentNodeId: 'b',
                          x: 700,
                          y: 100,
                        ),
                        for (var i = 0; i < extraChildren; i++)
                          MapNode(
                            id: 'extra-$i',
                            mapId: 'map',
                            cardId: 'extra-$i',
                            parentNodeId: 'a',
                            x: 400,
                            y: 400 + i * 140,
                          ),
                      ],
                      cards: {
                        for (final id in [
                          'a',
                          'b',
                          'c',
                          'd',
                          for (var i = 0; i < extraChildren; i++) 'extra-$i',
                        ])
                          id: NoteCard(
                            id: id,
                            projectId: 'project',
                            title: '主题 $id',
                            excerptSnapshot: '',
                            body: '分支内容',
                            note: '',
                            color: '#3574CB',
                          ),
                      },
                      anchors: const {},
                      edges: const [],
                    ),
                    controller: host.controller,
                    selectedNodeId: selected,
                    onSelect: (node) {
                      host.events.add('select:${node.id}');
                      setState(() => selected = node.id);
                    },
                    onActivate: (node) =>
                        host.events.add('activate:${node.id}'),
                    onClearSelection: () => setState(() => selected = null),
                    onToggleCollapsed: (id) {
                      host.events.add('toggle:$id');
                      setState(
                        () => folded = {...folded, id: !(folded[id] ?? false)},
                      );
                    },
                    onAction: (node, action) =>
                        host.events.add('action:${node.id}:$action'),
                    onMove: (_, _, _) async {},
                    onReparent: (_, _) async {},
                    onAssociate: (_, _) async {},
                    onRemoveAssociation: (_) {},
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  host.controller.setView(scale: 1, worldTopLeft: const Offset(-30, -30));
  await tester.pump();
  return host;
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  await tester.runAsync(() async {
    final render =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await render.toImage();
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('.local/verification/xmind-collapse-$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}
