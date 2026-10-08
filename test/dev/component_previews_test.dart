import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opennote/dev/component_previews.dart';
import 'package:opennote/ui/map/map_outline_pane.dart';
import 'package:opennote/ui/map/mind_map_pane.dart';

void main() {
  final previews = <String, ({Widget Function() builder, Size size})>{
    '输入与按钮': (builder: namingDialogPreview, size: const Size(520, 320)),
    '卡片编辑': (builder: cardEditorPreview, size: const Size(420, 660)),
    '窄栏卡片编辑': (builder: cardEditorPreview, size: const Size(320, 660)),
    '脑图画布': (builder: mindMapPreview, size: const Size(900, 520)),
    '大纲侧栏': (builder: outlineSidebarPreview, size: const Size(360, 540)),
    '窄栏大纲侧栏': (builder: outlineSidebarPreview, size: const Size(280, 540)),
  };
  for (final entry in previews.entries) {
    testWidgets('${entry.key}实际组件可以布局', (tester) async {
      await tester.binding.setSurfaceSize(entry.value.size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      tester.platformDispatcher.textScaleFactorTestValue =
          entry.key.startsWith('窄栏') ? 1.25 : 1;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(entry.value.builder());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('预览中的输入、保存与侧栏选择响应真实操作', (tester) async {
    await tester.binding.setSurfaceSize(const Size(520, 660));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(namingDialogPreview());
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '');
    await tester.pump();
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    await tester.enterText(find.byType(TextField), '预览项目');
    await tester.pump();
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNotNull,
    );

    await tester.pumpWidget(cardEditorPreview());
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('card-body')), '编辑内存预览');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    expect(find.text('资料已保存'), findsOneWidget);

    await tester.pumpWidget(outlineSidebarPreview());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('outline-node-child')));
    await tester.pump();
    expect(
      tester.widget<MapOutlinePane>(find.byType(MapOutlinePane)).selectedNodeId,
      'child',
    );

    await tester.pumpWidget(mindMapPreview());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('map-node-child')));
    await tester.pump();
    expect(
      tester.widget<MindMapPane>(find.byType(MindMapPane)).selectedNodeId,
      'child',
    );
    expect(tester.takeException(), isNull);
  });
}
