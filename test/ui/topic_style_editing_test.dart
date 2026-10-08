import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opennote/domain/models.dart';
import 'package:opennote/ui/map/mind_map_pane.dart';
import 'package:opennote/ui/map/map_outline_pane.dart';
import 'package:opennote/ui/map/topic_style_dialog.dart';
import 'package:opennote/ui/map/topic_style_painter.dart';
import 'package:opennote/ui/theme/open_note_theme.dart';

import '../support/map_context_menu.dart';

void main() {
  testWidgets('主题和分支页签保存格式、选择范围与默认；非法颜色不保存', (tester) async {
    TopicStyleEditResult? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: openNoteTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showDialog<TopicStyleEditResult>(
                  context: context,
                  builder: (_) => const TopicStyleDialog(
                    style: TopicStyle(),
                    defaultStyle: TopicStyle(),
                    selectionCount: 3,
                  ),
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('topic-style-填充颜色')),
      '#EAF1FC',
    );
    await tester.tap(find.text('分支'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('topic-style-连线形状')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('折线').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('topic-style-连线颜色')),
      '不合法',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(find.text('颜色请使用 #RRGGBB 格式。'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('topic-style-连线颜色')),
      '#3574CB',
    );
    await tester.tap(find.text('同时应用到子主题'));
    await tester.tap(find.text('设为本图默认格式'));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(result!.style!.surface.fill, '#EAF1FC');
    expect(result!.style!.branch.path, BranchPath.elbow);
    expect(result!.style!.branch.color, '#3574CB');
    expect(result!.includeDescendants, isTrue);
    expect(result!.makeDefault, isTrue);
    expect(tester.takeException(), isNull);
  });
  testWidgets('900 宽及文字 1.25 倍格式面板可滚动、恢复默认更新控件；取消不返回结果', (tester) async {
    tester.view.physicalSize = const Size(900, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    TopicStyleEditResult? result;
    final styled = const TopicStyle().copyWith(
      surface: const TopicStyle().surface.copyWith(
        textSize: 32,
        shape: BoundaryShape.ellipse,
      ),
    );
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
                result = await showDialog<TopicStyleEditResult>(
                  context: context,
                  builder: (_) => TopicStyleDialog(
                    style: styled,
                    defaultStyle: const TopicStyle(),
                    selectionCount: 1,
                  ),
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('恢复默认'));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.text('示例主题')).style!.fontSize, 15);
    expect(
      find.byKey(const ValueKey('topic-style-主题形状-BoundaryShape.rounded')),
      findsOneWidget,
    );
    await tester.tap(find.text('分支'));
    await tester.pumpAndSettle();
    final end = find.byKey(const ValueKey('topic-style-终点'));
    await tester.ensureVisible(end);
    await tester.pumpAndSettle();
    await tester.tap(end);
    await tester.pumpAndSettle();
    await tester.tap(find.text('箭头').last);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(find.byType(TopicStyleDialog), findsNothing);
  });
  testWidgets('节点拖动中格式刷新保留手势与位置；格式入口可用，大纲文字跟随且大字号无溢出', (tester) async {
    tester.view.physicalSize = const Size(1000, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var style = const TopicStyle();
    late StateSetter refresh;
    final controller = MindMapPaneController(), actions = <String>[];
    var moves = 0;
    MapSnapshot snapshot() => MapSnapshot(
      map: MindMap(
        layout: MapLayoutKind.free,
        id: 'm',
        projectId: 'p',
        title: '格式',
        defaultStyle: style,
      ),
      nodes: const [MapNode(id: 'a', mapId: 'm', cardId: 'c', x: 100, y: 100)],
      cards: const {
        'c': NoteCard(
          id: 'c',
          projectId: 'p',
          title: '普通主题',
          excerptSnapshot: '',
          body: '内容',
          note: '',
          color: '#F7D976',
        ),
      },
      anchors: const {},
      edges: const [],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: openNoteTheme(),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (_, state) {
              refresh = state;
              return MindMapPane(
                snapshot: snapshot(),
                controller: controller,
                selectedNodeId: 'a',
                onSelect: (_) {},
                onMove: (_, _, _) async {
                  moves++;
                },
                onReparent: (_, _) async {},
                onAssociate: (_, _) async {},
                onRemoveAssociation: (_) {},
                onAction: (_, action) => actions.add(action),
                onToggleCollapsed: (_) {},
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    controller.setView(scale: 1, worldTopLeft: Offset.zero);
    await tester.pumpAndSettle();
    await mapNodeMenuAction(
      tester,
      nodeId: 'a',
      group: 'styleMenu',
      action: 'topicStyle',
    );
    await tester.pumpAndSettle();
    expect(actions, ['topicStyle']);
    final node = find.byKey(const ValueKey('map-node-a'));
    final gesture = await tester.startGesture(
      tester.getCenter(node),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(25, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(30, 0));
    await tester.pump();
    final position = tester.getTopLeft(node);
    refresh(
      () => style = style.copyWith(
        surface: style.surface.copyWith(
          textSize: 20,
          italic: true,
          dashed: true,
          textColor: '#3574CB',
        ),
      ),
    );
    await tester.pump();
    expect(tester.getTopLeft(node), position);
    expect(tester.widget<Text>(find.text('普通主题')).style!.fontSize, 20);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(moves, 1);
    expect(tester.takeException(), isNull);
    style = style.copyWith(surface: style.surface.copyWith(textSize: 32));
    await tester.pumpWidget(
      MaterialApp(
        theme: openNoteTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.25)),
          child: child!,
        ),
        home: Scaffold(
          body: MindMapPane(
            snapshot: snapshot(),
            controller: controller,
            selectedNodeId: 'a',
            onSelect: (_) {},
            onMove: (_, _, _) async {},
            onReparent: (_, _) async {},
            onAssociate: (_, _) async {},
            onRemoveAssociation: (_) {},
            onAction: (_, _) {},
            onToggleCollapsed: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.text('普通主题')).style!.fontSize, 32);
    expect(tester.takeException(), isNull, reason: '最大字号和文字放大不能撑出固定节点');
    await tester.pumpWidget(
      MaterialApp(
        theme: openNoteTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.25)),
          child: child!,
        ),
        home: Scaffold(
          body: MapOutlinePane(
            snapshot: snapshot(),
            selectedNodeId: null,
            onSelect: (_) {},
            onAction: (_, _) {},
            onToggleCollapsed: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final title = tester.widget<Text>(
      find.byKey(const ValueKey('outline-title-a')),
    );
    expect(title.style!.fontSize, 32);
    expect(title.style!.fontStyle, FontStyle.italic);
    expect(tester.takeException(), isNull);
  });
  test('直线、曲线与折线共用端点；虚线路径确实存在间隙', () {
    for (final kind in BranchPath.values) {
      final path = branchPath(
        const Offset(5, 10),
        const Offset(180, 100),
        kind,
        false,
      );
      final metric = path.computeMetrics().single;
      expect(metric.getTangentForOffset(0)!.position, const Offset(5, 10));
      expect(
        (metric.getTangentForOffset(metric.length)!.position -
                const Offset(180, 100))
            .distance,
        lessThan(.1),
      );
      expect(dashedPath(path).computeMetrics().length, greaterThan(1));
    }
  });
}
