import '../support/flutter_sdk.dart';

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opennote/domain/models.dart';
import 'package:opennote/ui/map/mind_map_pane.dart';
import 'package:opennote/ui/theme/open_note_theme.dart';
import 'package:opennote/ui/theme/open_note_context_menu.dart';

import '../support/map_context_menu.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final chinese = FontLoader('Source Han Sans CN');
    for (final weight in ['Regular', 'Medium', 'Bold']) {
      chinese.addFont(
        File('assets/fonts/source-han-sans/SourceHanSansCN-$weight.otf')
            .readAsBytes()
            .then(ByteData.sublistView),
      );
    }
    await chinese.load();
    for (final font in {
      'Segoe UI': 'segoeui.ttf',
      'Microsoft YaHei': 'msyh.ttc',
    }.entries) {
      await (FontLoader(font.key)..addFont(
            File('C:/Windows/Fonts/${font.value}')
                .readAsBytes()
                .then(ByteData.sublistView),
          ))
          .load();
    }
    await (FontLoader('MaterialIcons')..addFont(
          File(
            '${flutterSdkPath()}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          ).readAsBytes().then(ByteData.sublistView),
        ))
        .load();
  });

  testWidgets('卡片菜单精简：单击仅选择，F2仍编辑，没有悬浮工具栏', (tester) async {
    final host = await _mount(tester);
    await tester.tap(find.byKey(const ValueKey('map-node-parent')));
    await tester.pump();
    expect(find.byKey(const ValueKey('map-card-actions')), findsNothing);
    expect(find.byType(OpenNoteMenuItem<String>), findsNothing);
    expect(host.actions, isEmpty);
    expect(host.activated, ['parent']);
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    expect(host.actions, [('parent', 'editSelected')]);
    expect(find.byKey(const ValueKey('map-canvas-toolbar')), findsNothing);
    expect(find.byKey(const ValueKey('map-viewport-controls')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('卡片菜单精简：一级最多8项，真实回源编辑新建删除动作正确', (tester) async {
    final host = await _mount(tester);
    await openMapNodeMenu(tester, nodeId: 'parent');
    final items = tester
        .widgetList<OpenNoteMenuItem<String>>(
          find.byType(OpenNoteMenuItem<String>),
        )
        .toList();
    expect(items.map((item) => item.value), [
      'newChild',
      'newSibling',
      'edit',
      'source',
      'clipboardMenu',
      'styleMenu',
      'collapseMenu',
      'removeBranch',
    ]);
    expect(find.text('删除分支'), findsOneWidget);
    expect(find.text('卡片移入回收站'), findsNothing);
    expect(find.text('添加外框 Ctrl+B'), findsNothing);
    expect(find.text('与另一卡片关联'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('map-menu-source')));
    await tester.pumpAndSettle();
    await mapNodeMenuAction(tester, nodeId: 'parent', action: 'edit');
    await mapNodeMenuAction(tester, nodeId: 'parent', action: 'newChild');
    await mapNodeMenuAction(tester, nodeId: 'parent', action: 'newSibling');
    await mapNodeMenuAction(tester, nodeId: 'parent', action: 'removeBranch');
    expect(host.actions, [
      ('parent', 'source'),
      ('parent', 'edit'),
      ('parent', 'newChild'),
      ('parent', 'newSibling'),
      ('parent', 'removeBranch'),
    ]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('卡片菜单精简：级联菜单逐层取消不执行命令，复制剪切粘贴和跨图动作保留', (tester) async {
    final host = await _mount(tester);
    await openMapNodeMenu(tester, nodeId: 'parent');
    await tester.tap(find.byKey(const ValueKey('map-menu-clipboardMenu')));
    await tester.pumpAndSettle();
    expect(find.byType(OpenNoteMenuItem<String>), findsNWidgets(13));
    expect(find.byKey(const ValueKey('map-menu-back')), findsNothing);
    expect(find.byKey(const ValueKey('map-menu-edit')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('map-menu-clipboardCopy')), findsNothing);
    expect(find.byKey(const ValueKey('map-menu-edit')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(host.actions, isEmpty);
    expect(host.clipboard, isEmpty);
    for (final action in ['clipboardCopy', 'clipboardCut', 'clipboardPaste']) {
      await mapNodeMenuAction(
        tester,
        nodeId: 'parent',
        group: 'clipboardMenu',
        action: action,
      );
    }
    expect(host.clipboard, ['copy', 'cut', 'paste']);
    await mapNodeMenuAction(
      tester,
      nodeId: 'parent',
      group: 'clipboardMenu',
      action: 'copyBranch',
    );
    await mapNodeMenuAction(
      tester,
      nodeId: 'parent',
      group: 'clipboardMenu',
      action: 'moveBranch',
    );
    expect(host.actions, [('parent', 'copyBranch'), ('parent', 'moveBranch')]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('卡片菜单精简：格式保留精确多选，颜色仅作用目标；普通和递归折叠保留', (tester) async {
    final host = await _mount(tester, selection: const {'parent', 'leaf'});
    await mapNodeMenuAction(
      tester,
      nodeId: 'parent',
      group: 'styleMenu',
      action: 'topicStyle',
    );
    expect(host.actionSelection, {'parent', 'leaf'});
    await mapNodeMenuAction(
      tester,
      nodeId: 'parent',
      group: 'styleMenu',
      action: 'color',
    );
    expect(host.actionSelection, {'parent'});
    await mapNodeMenuAction(
      tester,
      nodeId: 'parent',
      group: 'collapseMenu',
      action: 'collapse',
    );
    expect(host.toggled, ['parent']);
    await mapNodeMenuAction(
      tester,
      nodeId: 'parent',
      group: 'collapseMenu',
      action: 'collapseBranch',
    );
    expect(host.actions.last, ('parent', 'collapseBranch'));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('卡片菜单精简：叶主题隐藏来源和折叠，处理中禁止新建', (tester) async {
    await _mount(tester, canCreate: false);
    await openMapNodeMenu(tester, nodeId: 'leaf');
    expect(find.byType(OpenNoteMenuItem<String>), findsNWidgets(6));
    expect(find.text('删除卡片'), findsOneWidget);
    expect(find.byKey(const ValueKey('map-menu-source')), findsNothing);
    expect(find.byKey(const ValueKey('map-menu-collapseMenu')), findsNothing);
    expect(
      tester
          .widget<OpenNoteMenuItem<String>>(
            find.byKey(const ValueKey('map-menu-newChild')),
          )
          .enabled,
      isFalse,
    );
    expect(
      tester
          .widget<OpenNoteMenuItem<String>>(
            find.byKey(const ValueKey('map-menu-newSibling')),
          )
          .enabled,
      isFalse,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final config in [
    (size: const Size(1000, 650), scale: 1.0, name: 'menu-1000x650'),
    (size: const Size(420, 520), scale: 1.25, name: 'menu-420x520-at125'),
    (size: const Size(1280, 720), scale: 1.5, name: 'menu-1280x720-at150'),
  ]) {
    testWidgets('卡片菜单精简：${config.name}无需滚动且完整可点击', (tester) async {
      final previousShadows = debugDisableShadows;
      debugDisableShadows = false;
      try {
        final host = await _mount(
          tester,
          size: config.size,
          textScale: config.scale,
        );
        await openMapNodeMenu(tester, nodeId: 'parent');
        // 等待整块菜单淡入完成，截图包含完整表面和轻阴影。
        await tester.pumpAndSettle();
        for (final item in tester.widgetList<OpenNoteMenuItem<String>>(
          find.byType(OpenNoteMenuItem<String>),
        )) {
          expect(find.byKey(item.key!).hitTestable(), findsOneWidget);
        }
        final first = tester.getRect(
          find.byKey(const ValueKey('map-menu-newChild')),
        );
        final last = tester.getRect(
          find.byKey(const ValueKey('map-menu-removeBranch')),
        );
        expect(last.bottom - first.top, lessThan(440));
        expect(tester.takeException(), isNull);
        await tester.runAsync(() async {
          final render =
              host.boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await render.toImage(pixelRatio: 1);
          try {
            final png = (await image.toByteData(
              format: ui.ImageByteFormat.png,
            ))!;
            final folder = await Directory(
              '.local/verification/map-menu-simplification',
            ).create(recursive: true);
            await File('${folder.path}/${config.name}.png')
                .writeAsBytes(png.buffer.asUint8List());
          } finally {
            image.dispose();
          }
        });
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox());
      } finally {
        debugDisableShadows = previousShadows;
      }
    });
  }
}

class _Host {
  final boundary = GlobalKey();
  final controller = MindMapPaneController();
  final actions = <(String, String)>[];
  final activated = <String>[];
  final clipboard = <String>[];
  final toggled = <String>[];
  Set<String> actionSelection = {};
}

Future<_Host> _mount(
  WidgetTester tester, {
  Set<String> selection = const {'parent'},
  bool canCreate = true,
  Size size = const Size(1000, 650),
  double textScale = 1,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final host = _Host();
  var selected = Set<String>.of(selection);
  var primary = 'parent';
  await tester.pumpWidget(
    RepaintBoundary(
      key: host.boundary,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: openNoteTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, state) => MindMapPane(
              snapshot: _snapshot(),
              controller: host.controller,
              canCreate: canCreate,
              selectedNodeId: primary,
              selectedNodeIds: selected,
              onSelect: (node) => state(() {
                primary = node.id;
                selected = {node.id};
              }),
              onSelectionChanged: (ids, id) => state(() {
                primary = id!;
                selected = ids;
              }),
              onActivate: (node) => host.activated.add(node.id),
              onMove: (_, _, _) async {},
              onReparent: (_, _) async {},
              onAssociate: (_, _) async {},
              onRemoveAssociation: (_) {},
              onClipboardAction: host.clipboard.add,
              onAction: (node, action) {
                host.actions.add((node.id, action));
                host.actionSelection = Set.of(selected);
              },
              onToggleCollapsed: host.toggled.add,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  host.controller.setView(scale: 1, worldTopLeft: Offset.zero);
  await tester.pumpAndSettle();
  return host;
}

MapSnapshot _snapshot() => MapSnapshot(
  map: const MindMap(
    id: 'map',
    projectId: 'project',
    title: '脑图',
    layout: MapLayoutKind.free,
  ),
  nodes: const [
    MapNode(id: 'parent', mapId: 'map', cardId: 'a', x: 60, y: 60),
    MapNode(
      id: 'child',
      mapId: 'map',
      cardId: 'b',
      parentNodeId: 'parent',
      x: 360,
      y: 80,
    ),
    MapNode(id: 'leaf', mapId: 'map', cardId: 'c', x: 60, y: 310),
  ],
  cards: {
    for (final id in ['a', 'b', 'c'])
      id: NoteCard(
        id: id,
        projectId: 'project',
        title: id == 'a' ? '阅读与思考' : '知识卡片',
        excerptSnapshot: '',
        body: '理解内容，建立联系。',
        note: '',
        color: '#F7D976',
      ),
  },
  anchors: {
    'a': [
      SourceAnchor(
        id: 'anchor',
        cardId: 'a',
        revisionId: 'revision',
        pageIndex: 0,
        quads: [PdfQuad.rect(0, 0, 100, 20)],
      ),
    ],
  },
  edges: const [],
);
