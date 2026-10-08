import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opennote/ui/map/mind_map_pane.dart';
import 'package:opennote/ui/theme/open_note_context_menu.dart';

/// 通过画布右下角入口打开工具菜单，保留真实焦点与菜单取消行为。
Future<void> openMapToolsMenu(WidgetTester tester) async {
  await _waitForMenuItem(tester, find.byTooltip('更多脑图工具'));
  await tester.tap(find.byTooltip('更多脑图工具'));
  await _waitForMenuItem(tester, find.byKey(const Key('map-tool-association')));
}

Future<void> mapCanvasToolAction(WidgetTester tester, String action) async {
  await openMapToolsMenu(tester);
  final item = find.byWidgetPredicate(
    (widget) =>
        widget is OpenNoteMenuItem<String> && widget.entry.value == action,
  );
  await _waitForMenuItem(tester, item);
  await tester.tap(item);
  await waitForMapToolsClosed(tester);
}

Future<void> waitForMapToolsClosed(WidgetTester tester) async {
  final menu = find.byKey(const Key('context-menu-main'));
  for (var attempt = 0; attempt < 40 && menu.evaluate().isNotEmpty; attempt++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(menu, findsNothing, reason: '工具操作完成后整组菜单必须关闭');
}

/// 画布使用侧向子菜单，大纲继续使用页头入口。
Future<void> openMapStructureMenu(WidgetTester tester) async {
  // 结构事务可能仍在保存；沿用旧页头菜单测试的可用状态等待。
  bool enabled() => find.byType(MindMapPane).evaluate().isNotEmpty
      ? tester.widget<MindMapPane>(find.byType(MindMapPane)).canCreate
      : tester
            .widget<PopupMenuButton<String>>(
              find.byKey(const Key('map-structure-menu')),
            )
            .enabled;
  for (var attempt = 0; attempt < 100 && !enabled(); attempt++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  expect(enabled(), isTrue, reason: '保存结束后才打开结构菜单');
  if (find.byTooltip('更多脑图工具').evaluate().isNotEmpty) {
    await openMapToolsMenu(tester);
    await tester.tap(find.byKey(const Key('map-structure-menu')));
  } else {
    await tester.tap(find.byKey(const Key('map-structure-menu')));
  }
  await _waitForMenuItem(tester, find.text('自动整理'));
}

/// 通过真实右键和菜单点击操作，不直接调用产品命令回调。
Future<void> openMapNodeMenu(WidgetTester tester, {String? nodeId}) async {
  final pane = tester.widget<MindMapPane>(find.byType(MindMapPane));
  final id = nodeId ?? pane.selectedNodeId;
  expect(id, isNotNull, reason: '菜单测试必须有明确目标');
  final node = find.byKey(ValueKey('map-node-$id'));
  final point = tester
      .getRect(node)
      .intersect(tester.getRect(find.byType(MindMapPane)))
      .center;
  expect(node.hitTestable(at: Alignment.center), findsOneWidget);
  final gesture = await tester.startGesture(
    point,
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryMouseButton,
  );
  await gesture.up();
  await _waitForMenuItem(
    tester,
    find.byKey(const ValueKey('map-menu-removeBranch')),
  );
  expect(find.byKey(const ValueKey('map-menu-edit')), findsOneWidget);
}

Future<void> mapNodeMenuAction(
  WidgetTester tester, {
  String? nodeId,
  String? group,
  required String action,
}) async {
  await openMapNodeMenu(tester, nodeId: nodeId);
  if (group != null) {
    await tester.tap(find.byKey(ValueKey('map-menu-$group')));
  }
  final item = find.byKey(ValueKey('map-menu-$action'));
  await _waitForMenuItem(tester, item);
  if (group != null) {
    expect(find.byKey(const ValueKey('map-menu-back')), findsNothing);
    expect(find.byKey(const ValueKey('map-menu-edit')), findsOneWidget);
  }
  expect(item.hitTestable(), findsOneWidget);
  await tester.tap(item);
  for (var attempt = 0; attempt < 40 && item.evaluate().isNotEmpty; attempt++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(item, findsNothing, reason: '执行操作后菜单必须关闭');
}

Future<void> _waitForMenuItem(WidgetTester tester, Finder item) async {
  // PDF 加载和保存可持续安排帧，只等待当前菜单的真实命中状态。
  for (var attempt = 0; attempt < 40; attempt++) {
    await tester.pump(const Duration(milliseconds: 16));
    if (item.hitTestable().evaluate().isNotEmpty) return;
  }
  expect(item.hitTestable(), findsOneWidget, reason: '菜单项必须在有界等待内可点击');
}
