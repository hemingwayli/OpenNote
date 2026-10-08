import '../support/flutter_sdk.dart';

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opennote/domain/models.dart';
import 'package:opennote/ui/map/mind_map_pane.dart';
import 'package:opennote/ui/theme/open_note_context_menu.dart';
import 'package:opennote/ui/theme/open_note_theme.dart';

import '../support/map_context_menu.dart';

void main() {
  setUpAll(() async {
    for (final font in {
      'Source Han Sans CN':
          'assets/fonts/source-han-sans/SourceHanSansCN-Regular.otf',
      'Segoe UI': 'C:/Windows/Fonts/segoeui.ttf',
      'MaterialIcons':
          '${flutterSdkPath()}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    }.entries) {
      await (FontLoader(
            font.key,
          )..addFont(File(font.value).readAsBytes().then(ByteData.sublistView)))
          .load();
    }
  });

  for (final scale in [1.0, 1.5]) {
    testWidgets('画布工具：${(scale * 100).round()}%下合并布局及向上菜单保持稳定', (tester) async {
      final host = await _mount(tester, scale: scale);
      final footer = find.byKey(const Key('map-viewport-controls'));
      final rect = tester.getRect(footer);
      final canvas = tester.getRect(find.byType(MindMapPane));
      expect(rect.right, canvas.right - 12);
      expect(rect.bottom, canvas.bottom - 12);
      expect(rect.left, greaterThanOrEqualTo(canvas.left + 12));
      expect(find.byKey(const Key('map-canvas-toolbar')), findsNothing);
      expect(find.byTooltip('放大脑图'), findsNothing);
      expect(find.byTooltip('缩小脑图'), findsNothing);
      expect(find.text('新建'), findsOneWidget);
      await _capture(tester, host, 'footer-${(scale * 100).round()}.png');
      await tester.tap(find.byTooltip('更多脑图工具'));
      await tester.pump();
      await tester.pump();
      final main = find.byKey(const Key('context-menu-main'));
      final before = tester.getRect(main);
      final row = tester.getRect(find.byKey(const Key('map-tool-association')));
      expect(before.bottom, lessThanOrEqualTo(rect.top - 6));
      expect(before.top, greaterThanOrEqualTo(8));
      final fade = tester.widget<FadeTransition>(
        find.byKey(const Key('context-menu-opacity')),
      );
      expect(fade.opacity.value, 0);
      await tester.pump(const Duration(milliseconds: 60));
      expect(fade.opacity.value, closeTo(.5, .01));
      expect(tester.getRect(main), before);
      expect(
        tester.getRect(find.byKey(const Key('map-tool-association'))),
        row,
      );
      await tester.pump(const Duration(milliseconds: 60));
      expect(fade.opacity.value, 1);
      await tester.tap(find.byKey(const Key('map-structure-menu')));
      await tester.pumpAndSettle();
      expect(tester.getRect(main), before);
      await _capture(tester, host, 'menu-${(scale * 100).round()}.png');
      await tester.tap(find.text('自动整理'));
      await waitForMapToolsClosed(tester);
      expect(host.actions, ['organize']);
      expect(tester.getRect(footer), rect);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('画布工具：框选及关联提示在工具组上方，Esc退出模式', (tester) async {
    final host = await _mount(tester, scale: 1.5);
    await mapCanvasToolAction(tester, 'tool:marquee');
    final footer = tester.getRect(
      find.byKey(const Key('map-viewport-controls')),
    );
    final hint = find.byKey(const Key('map-marquee-mode'));
    expect(hint, findsOneWidget);
    expect(tester.getRect(hint).bottom, footer.top - 6);
    expect(find.text('框选中 · Esc 退出'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(hint, findsNothing);
    await mapCanvasToolAction(tester, 'tool:association');
    final association = find.byKey(const Key('map-association-mode'));
    expect(association, findsOneWidget);
    expect(tester.getRect(association).overlaps(footer), isFalse);
    expect(find.textContaining('选择终点'), findsOneWidget);
    await _capture(tester, host, 'association-150.png');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(association, findsNothing);
    expect(host.links, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('画布工具：禁用条件及选集失效取消，不派发旧动作', (tester) async {
    final host = await _mount(tester);
    host.update(() => host.selected = {});
    await tester.pump();
    await openMapToolsMenu(tester);
    for (final key in ['map-tool-boundary', 'map-tool-summary']) {
      final item = tester.widget<OpenNoteMenuItem<String>>(
        find.byKey(Key(key)),
      );
      expect(item.entry.enabled, isFalse);
      await tester.tap(find.byKey(Key(key)));
      await tester.pump();
      expect(find.byKey(const Key('context-menu-main')), findsOneWidget);
    }
    host.update(() => host.selected = {'a'});
    await waitForMapToolsClosed(tester);
    expect(host.actions, isEmpty);
    await openMapToolsMenu(tester);
    host.update(() => host.mapId = 'other-map');
    await waitForMapToolsClosed(tester);
    expect(host.actions, isEmpty);
    expect(host.links, isEmpty);
    expect(tester.takeException(), isNull);
  });
}

class _Host {
  final boundary = GlobalKey();
  final controller = MindMapPaneController();
  final actions = <String>[];
  final links = <(String, String)>[];
  Set<String> selected = {'a'};
  String mapId = 'map';
  late StateSetter update;
}

Future<_Host> _mount(WidgetTester tester, {double scale = 1}) async {
  await tester.binding.setSurfaceSize(
    scale == 1 ? const Size(900, 600) : const Size(420, 560),
  );
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final host = _Host();
  await tester.pumpWidget(
    RepaintBoundary(
      key: host.boundary,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: openNoteTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, state) {
              host.update = state;
              return MindMapPane(
                snapshot: _snapshot(host.mapId),
                controller: host.controller,
                selectedNodeId: host.selected.firstOrNull,
                selectedNodeIds: host.selected,
                creationTools: SizedBox(
                  height: 36,
                  child: TextButton(
                    onPressed: () => host.actions.add('new'),
                    child: const Text('新建'),
                  ),
                ),
                structureMenuEntries: () => const [
                  OpenNoteMenuEntry('organize', '自动整理'),
                  OpenNoteMenuEntry('defaultStyle', '脑图默认格式…'),
                  OpenNoteMenuEntry.divider(),
                  OpenNoteMenuEntry('expandAll', '展开全部'),
                ],
                onStructureMenuAction: host.actions.add,
                onSelectionChanged: (ids, _) =>
                    state(() => host.selected = ids),
                onSelect: (node) => state(() => host.selected = {node.id}),
                onMove: (_, _, _) async {},
                onReparent: (_, _) async {},
                onAssociate: (from, to) async => host.links.add((from, to)),
                onCreateBoundaries: (_) async => [],
                onCreateSummaries: (_) async => [],
                onRemoveAssociation: (_) {},
                onAction: (_, _) {},
                onToggleCollapsed: (_) {},
              );
            },
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return host;
}

Future<void> _capture(WidgetTester tester, _Host host, String name) async {
  await tester.runAsync(() async {
    final boundary =
        host.boundary.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('.local/verification/map-tools-20261008/$name');
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

MapSnapshot _snapshot(String mapId) => MapSnapshot(
  map: MindMap(
    id: mapId,
    projectId: 'project',
    title: '阅读与思考',
    layout: MapLayoutKind.free,
  ),
  nodes: [
    MapNode(id: 'a', mapId: mapId, cardId: 'a', x: 0, y: 0),
    MapNode(id: 'b', mapId: mapId, cardId: 'b', x: 300, y: 120),
  ],
  cards: {
    for (final id in ['a', 'b'])
      id: NoteCard(
        id: id,
        projectId: 'project',
        title: id == 'a' ? '阅读与思考' : '建立联系',
        excerptSnapshot: '',
        body: '',
        note: '',
        color: '#F7D976',
      ),
  },
  anchors: const {},
  edges: const [],
);
