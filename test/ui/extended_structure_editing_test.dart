import '../support/flutter_sdk.dart';

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opennote/domain/models.dart';
import 'package:opennote/domain/map_layout.dart';
import 'package:opennote/ui/map/mind_map_pane.dart';
import 'package:opennote/ui/map/map_structure_dialog.dart';
import 'package:opennote/ui/theme/open_note_theme.dart';

MapSnapshot fixture(MapLayoutKind kind) {
  final original = [
    for (var i = 0; i < 7; i++)
      MapNode(
        id: '$i',
        mapId: 'm',
        cardId: '$i',
        parentNodeId: i == 0
            ? null
            : i <= 3
            ? '0'
            : '${i - 3}',
        x: 100,
        y: 100,
        sortIndex: i,
      ),
  ];
  final plan = calculateMapLayout(original, kind);
  return MapSnapshot(
    map: MindMap(id: 'm', projectId: 'p', title: kind.label, layout: kind),
    nodes: [
      for (final n in original)
        MapNode(
          id: n.id,
          mapId: n.mapId,
          cardId: n.cardId,
          parentNodeId: n.parentNodeId,
          x: plan.positions[n.id]!.x,
          y: plan.positions[n.id]!.y,
          width: n.width,
          height: n.height,
          sortIndex: n.sortIndex,
          branchSide: plan.branchSides[n.id],
        ),
    ],
    cards: {
      for (final n in original)
        n.cardId: NoteCard(
          id: n.cardId,
          projectId: 'p',
          title: n.id == '0' ? '阅读知识 · ${kind.label}' : '主题 ${n.id}',
          body: '阅读、思考与知识整理',
          excerptSnapshot: '',
          note: '',
          color: '#F7D976',
        ),
    },
    anchors: const {},
    edges: const [],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    for (final (family, path) in [
      (
        'Source Han Sans CN',
        'assets/fonts/source-han-sans/SourceHanSansCN-Regular.otf',
      ),
      ('Segoe UI', 'C:/Windows/Fonts/segoeui.ttf'),
      (
        'MaterialIcons',
        '${flutterSdkPath()}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      ),
    ]) {
      await (FontLoader(
        family,
      )..addFont(File(path).readAsBytes().then(ByteData.sublistView))).load();
    }
  });
  for (final kind in MapLayoutKind.values.where((k) => k.extended)) {
    testWidgets('${kind.name} 画布适配完整节点与特殊连线，方向键浏览树形和主轴', (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = MindMapPaneController();
      final selected = <String>[];
      final boundary = GlobalKey();
      final snapshot = fixture(kind);
      await tester.pumpWidget(
        MaterialApp(
          theme: openNoteTheme(),
          home: Scaffold(
            body: RepaintBoundary(
              key: boundary,
              child: MindMapPane(
                snapshot: snapshot,
                controller: controller,
                selectedNodeId: '0',
                onSelect: (n) => selected.add(n.id),
                onMove: (_, _, _) async {},
                onReparent: (_, _) async {},
                onAssociate: (_, _) async {},
                onRemoveAssociation: (_) {},
                onAction: (_, _) {},
                onToggleCollapsed: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      controller.fitAll();
      await tester.pumpAndSettle();
      final viewport = tester.getRect(find.byType(InteractiveViewer));
      for (final n in snapshot.nodes) {
        final rect = tester.getRect(find.byKey(ValueKey('map-node-${n.id}')));
        expect(
          viewport.contains(rect.topLeft) &&
              viewport.contains(rect.bottomRight),
          isTrue,
          reason: n.id,
        );
      }
      if (kind.tree || kind.spine) {
        await tester.tap(find.byKey(const ValueKey('map-node-0')));
        final forward = kind.primaryDirection == MapLayoutKind.left
            ? LogicalKeyboardKey.arrowLeft
            : kind == MapLayoutKind.timelineVertical
            ? LogicalKeyboardKey.arrowDown
            : LogicalKeyboardKey.arrowRight;
        await tester.sendKeyEvent(forward);
        await tester.pump();
        expect(selected.last, '1');
        if (kind.spine) {
          await tester.sendKeyEvent(forward);
          await tester.pump();
          expect(selected.last, '2');
        }
        final backward = forward == LogicalKeyboardKey.arrowLeft
            ? LogicalKeyboardKey.arrowRight
            : forward == LogicalKeyboardKey.arrowDown
            ? LogicalKeyboardKey.arrowUp
            : LogicalKeyboardKey.arrowLeft;
        await tester.sendKeyEvent(backward);
        await tester.pump();
        expect(selected.last, kind.spine ? '1' : '0');
      }
      expect(tester.takeException(), isNull);
      final output = File(
        '.local/verification/xmind-extended-structure-20261005/screenshots/${kind.name}.png',
      );
      await tester.runAsync(() async {
        final render =
            boundary.currentContext!.findRenderObject()
                as RenderRepaintBoundary;
        final image = await render.toImage(pixelRatio: 1);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await output.parent.create(recursive: true);
        await output.writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets('900 宽与 1.25 倍文字的结构选择器可浏览所有结构并明确确认', (tester) async {
    tester.view.physicalSize = const Size(900, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    MapLayoutKind? result;
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
              onPressed: () async {
                result = await showDialog<MapLayoutKind>(
                  context: context,
                  builder: (_) =>
                      const MapStructureDialog(current: MapLayoutKind.right),
                );
              },
              child: const Text('结构'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('结构'));
    await tester.pumpAndSettle();
    final last = find.byKey(const ValueKey('structure-fishboneRight'));
    await tester.ensureVisible(last);
    await tester.pumpAndSettle();
    await tester.tap(last);
    await tester.pump();
    expect(
      find.descendant(of: last, matching: find.byIcon(Icons.check_rounded)),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('confirm-map-structure')));
    await tester.pumpAndSettle();
    expect(result, MapLayoutKind.fishboneRight);
    expect(tester.takeException(), isNull);
  });
}
