import '../support/flutter_sdk.dart';

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opennote/domain/models.dart';
import 'package:opennote/ui/theme/open_note_theme.dart';
import 'package:opennote/ui/workspace/card_editor.dart';

NoteCard cardWith({
  String id = 'card',
  String title = '在工作中练习正念',
  String excerptSnapshot = '以正确的精神、持守正念，工作可以是令人愉悦的。',
  String body = '我们需要确保自己享受工作。\n觉知自己的目标，也觉知身边的人。',
  String note = '',
  List<PersonalThought>? thoughts,
  String color = '#F7D976',
}) => NoteCard(
  id: id,
  projectId: 'project',
  title: title,
  excerptSnapshot: excerptSnapshot,
  body: body,
  note: note,
  thoughtEntries: thoughts,
  color: color,
);

Finder thoughtFields() => find.byWidgetPredicate(
  (widget) =>
      widget is TextField && widget.focusNode?.debugLabel == 'OpenNote 个人思考',
);

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

  Future<void> mount(
    WidgetTester tester,
    NoteCard card,
    CardEditorController controller,
    Future<void> Function(String, String, List<PersonalThought>) onSave, {
    Size size = const Size(360, 900),
    GlobalKey? boundary,
    Future<void> Function(String)? onColorChanged,
    Future<bool>? sourceAvailable,
    VoidCallback? onBackToSource,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: openNoteTheme(),
          home: Scaffold(
            body: CardEditor(
              key: ValueKey(card.id),
              card: card,
              controller: controller,
              onSave: onSave,
              imagePath: null,
              onSaveState: (_) {},
              sourceAvailable: sourceAvailable,
              onBackToSource: onBackToSource ?? () {},
              onClose: () {},
              onColorChanged: onColorChanged,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> controlKey(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    bool shift = false,
  }) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(key);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
  }

  const original = '工作可以是令人愉悦的。';
  final bodyField = find.byKey(const Key('card-body'));
  final originalSection = find.byKey(const Key('card-original-section'));

  testWidgets('原文入口：按完整文本判断，其他字段与回源按钮独立', (tester) async {
    final controller = CardEditorController();
    var backToSource = 0;
    await mount(
      tester,
      cardWith(body: original, excerptSnapshot: original),
      controller,
      (_, _, _) async {},
      sourceAvailable: Future.value(true),
      onBackToSource: () => backToSource++,
    );
    expect(find.text('原文'), findsNothing);
    expect(originalSection, findsNothing);
    expect(find.byTooltip('回到原文'), findsOneWidget);
    await tester.tap(find.byTooltip('回到原文'));
    expect(backToSource, 1);
    await tester.enterText(find.byKey(const Key('card-title')), '修改标题');
    await tester.enterText(thoughtFields(), '自己的理解');
    await tester.pump();
    expect(originalSection, findsNothing);
    await controller.flush();
    await mount(
      tester,
      cardWith(
        title: '修改标题',
        body: original,
        excerptSnapshot: original,
        note: '自己的理解',
        color: '#80B9EB',
      ),
      controller,
      (_, _, _) async {},
    );
    expect(originalSection, findsNothing);
    for (final text in ['修改正文', '$original ', '$original\n']) {
      await mount(
        tester,
        cardWith(body: text, excerptSnapshot: original),
        controller,
        (_, _, _) async {},
      );
      expect(find.text('原文'), findsOneWidget);
      expect(find.byType(SelectableText), findsNothing, reason: '已有差异默认收起');
    }
    await mount(
      tester,
      cardWith(body: '没有原始摘录的主题', excerptSnapshot: ''),
      controller,
      (_, _, _) async {},
    );
    expect(originalSection, findsNothing);
    await tester.enterText(bodyField, '继续编辑主题');
    await tester.pump();
    expect(originalSection, findsNothing);
    await controller.flush();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('原文入口：当前草稿立即显隐，保留焦点选区与中文组合输入且无占位', (tester) async {
    final controller = CardEditorController();
    final saved = <String>[];
    await mount(
      tester,
      cardWith(body: original, excerptSnapshot: original),
      controller,
      (_, body, _) async => saved.add(body),
    );
    await tester.showKeyboard(bodyField);
    final field = tester.widget<TextField>(bodyField);
    final thoughtTop = tester.getTopLeft(thoughtFields());
    final value = TextEditingValue(
      text: '$original修改',
      selection: TextSelection.collapsed(offset: original.length + 2),
      composing: TextRange(start: original.length, end: original.length + 2),
    );
    tester.testTextInput.updateEditingValue(value);
    await tester.pump();
    expect(originalSection, findsOneWidget);
    expect(saved, isEmpty, reason: '入口显隐不等待 500 毫秒自动保存');
    expect(
      tester.widget<TextField>(bodyField).controller,
      same(field.controller),
    );
    expect(field.focusNode!.hasFocus, isTrue);
    expect(field.controller!.value, value);
    expect(tester.getTopLeft(thoughtFields()), thoughtTop);
    await tester.enterText(bodyField, original);
    await tester.pump();
    expect(originalSection, findsNothing);
    expect(field.focusNode!.hasFocus, isTrue);
    expect(field.controller!.selection.baseOffset, original.length);
    final scroll = tester.widget<SingleChildScrollView>(
      find.byType(SingleChildScrollView),
    );
    expect(
      tester.getBottomLeft(find.byWidget(scroll.child!)).dy,
      tester
          .getBottomLeft(
            find.byKey(const ValueKey('card-thought-row-card:thought')),
          )
          .dy,
      reason: '隐藏后滚动内容在思考条目处结束，没有原文专属间距',
    );
    await controller.flush();
    expect(saved, [original]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('原文入口：粘贴剪切与文本撤销重做同步，原文只读且可复制', (tester) async {
    String? clipboard;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard = (call.arguments as Map)['text'] as String?;
        }
        if (call.method == 'Clipboard.getData') return {'text': clipboard};
        if (call.method == 'Clipboard.hasStrings') {
          return {'value': clipboard?.isNotEmpty ?? false};
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final controller = CardEditorController();
    await mount(
      tester,
      cardWith(body: original, excerptSnapshot: original),
      controller,
      (_, _, _) async {},
    );
    await tester.showKeyboard(bodyField);
    await tester.pump(const Duration(milliseconds: 550));
    await tester.enterText(bodyField, '$original修改');
    await tester.pump(const Duration(milliseconds: 550));
    expect(originalSection, findsOneWidget);
    await controlKey(tester, LogicalKeyboardKey.keyZ);
    expect(tester.widget<TextField>(bodyField).controller!.text, original);
    expect(originalSection, findsNothing);
    await controlKey(tester, LogicalKeyboardKey.keyZ, shift: true);
    expect(originalSection, findsOneWidget);
    final draft = tester.widget<TextField>(bodyField).controller!;
    draft.selection = TextSelection(
      baseOffset: original.length,
      extentOffset: draft.text.length,
    );
    await controlKey(tester, LogicalKeyboardKey.keyX);
    expect(clipboard, '修改');
    expect(draft.text, original);
    expect(originalSection, findsNothing);
    await controlKey(tester, LogicalKeyboardKey.keyV);
    await tester.pump();
    expect(draft.text, '$original修改');
    expect(originalSection, findsOneWidget);
    await tester.tap(find.text('原文'));
    await tester.pumpAndSettle();
    final source = tester.widget<SelectableText>(find.byType(SelectableText));
    expect(source.data, original);
    final sourceField = tester.widget<EditableText>(
      find.descendant(
        of: find.byType(SelectableText),
        matching: find.byType(EditableText),
      ),
    );
    expect(sourceField.readOnly, isTrue);
    sourceField.focusNode.requestFocus();
    sourceField.controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: original.length,
    );
    await tester.pump();
    await controlKey(tester, LogicalKeyboardKey.keyC);
    expect(clipboard, original);
    expect(draft.text, '$original修改');
    await controller.flush();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('原文入口：持续可见保留展开，隐藏重现切卡与重新打开均收起', (tester) async {
    final controller = CardEditorController();
    Future<void> save(String _, String _, List<PersonalThought> _) async {}
    final card = cardWith(body: '修改正文', excerptSnapshot: original);
    await mount(tester, card, controller, save);
    await tester.tap(find.text('原文'));
    await tester.pumpAndSettle();
    expect(find.byType(SelectableText), findsOneWidget);
    await tester.enterText(bodyField, '再次修改正文');
    await tester.pump();
    expect(
      tester.widget<SelectableText>(find.byType(SelectableText)).data,
      original,
    );
    await tester.enterText(bodyField, original);
    await tester.pump();
    expect(originalSection, findsNothing);
    await tester.enterText(bodyField, '再次产生差异');
    await tester.pump();
    expect(originalSection, findsOneWidget);
    expect(find.byType(SelectableText), findsNothing);
    await tester.tap(find.text('原文'));
    await tester.pumpAndSettle();
    await controller.flush();
    await mount(
      tester,
      cardWith(id: 'other-card', body: '另一张卡片', excerptSnapshot: '另一个摘录'),
      controller,
      save,
    );
    expect(find.byType(SelectableText), findsNothing);
    await tester.tap(find.text('原文'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<SelectableText>(find.byType(SelectableText)).data,
      '另一个摘录',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await mount(tester, card, controller, save);
    expect(originalSection, findsOneWidget);
    expect(find.byType(SelectableText), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('原文入口：保存回读与外部撤销同步，排队和失败期间保留当前草稿', (tester) async {
    final controller = CardEditorController();
    final failure = Completer<void>();
    var fail = false;
    var saved = original;
    Future<void> save(String _, String body, List<PersonalThought> _) async {
      if (fail) await failure.future;
      saved = body;
    }

    await mount(
      tester,
      cardWith(body: original, excerptSnapshot: original),
      controller,
      save,
    );
    await tester.enterText(bodyField, '已保存修改');
    await controller.flush();
    final draft = tester.widget<TextField>(bodyField).controller;
    await mount(
      tester,
      cardWith(body: saved, excerptSnapshot: original),
      controller,
      save,
    );
    expect(originalSection, findsOneWidget);
    expect(tester.widget<TextField>(bodyField).controller, same(draft));
    await mount(
      tester,
      cardWith(body: original, excerptSnapshot: original),
      controller,
      save,
    );
    expect(originalSection, findsNothing, reason: '外部撤销同步回原始摘录');
    await tester.enterText(bodyField, '失败后仍保留的草稿');
    fail = true;
    final failedSave = expectLater(controller.flush(), throwsStateError);
    await tester.pump();
    await mount(
      tester,
      cardWith(body: original, excerptSnapshot: original),
      controller,
      save,
    );
    expect(originalSection, findsOneWidget, reason: '保存期间的旧回读不能隐藏入口');
    failure.completeError(StateError('模拟正文保存失败'));
    await failedSave;
    await mount(
      tester,
      cardWith(body: original, excerptSnapshot: original),
      controller,
      save,
    );
    expect(draft!.text, '失败后仍保留的草稿');
    expect(originalSection, findsOneWidget);
    fail = false;
    await controller.flush();
    expect(saved, '失败后仍保留的草稿');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('原文入口：360宽隐藏收起展开三态截图无溢出', (tester) async {
    final controller = CardEditorController();
    final boundary = GlobalKey();
    Future<void> capture(String name) async {
      await tester.pumpAndSettle();
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await render.toImage(pixelRatio: 1);
        try {
          final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
          final directory = await Directory(
            '.local/verification/card-original-difference',
          ).create(recursive: true);
          await File('${directory.path}/editor-$name-360.png')
              .writeAsBytes(png.buffer.asUint8List());
        } finally {
          image.dispose();
        }
      });
      expect(tester.takeException(), isNull);
    }

    await mount(
      tester,
      cardWith(
        body: original,
        excerptSnapshot: original,
        note: '保持专注，记录自己的理解。',
      ),
      controller,
      (_, _, _) async {},
      boundary: boundary,
    );
    expect(originalSection, findsNothing);
    await capture('hidden');
    await tester.enterText(bodyField, '把日常工作变成练习觉察的机会。');
    expect(tester.widget<TextField>(bodyField).focusNode!.hasFocus, isTrue);
    await capture('collapsed');
    expect(find.text('原文').hitTestable(), findsOneWidget);
    expect(find.byType(SelectableText), findsNothing);
    await tester.tap(find.text('原文'));
    await capture('expanded');
    expect(find.byType(SelectableText).hitTestable(), findsOneWidget);
    await controller.flush();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('个人思考：紧凑空草稿、多条添加编辑删除与自动保存', (tester) async {
    final controller = CardEditorController();
    final saved = <List<PersonalThought>>[];
    await mount(
      tester,
      cardWith(),
      controller,
      (_, _, thoughts) async => saved.add(thoughts),
    );
    expect(find.text('个人备注'), findsNothing);
    expect(find.text('个人思考'), findsOneWidget);
    expect(thoughtFields(), findsOneWidget);
    expect(find.text('01'), findsNothing);
    expect(find.text('写下你的思考…'), findsNothing);
    expect(find.byTooltip('删除这条思考'), findsNothing);
    expect(
      tester
          .getSize(find.byKey(const ValueKey('card-thought-row-card:thought')))
          .height,
      lessThanOrEqualTo(64),
      reason: '空输入块不保留固定多行留白',
    );
    await tester.tap(find.byTooltip('添加个人思考'));
    await tester.pump();
    expect(thoughtFields(), findsOneWidget, reason: '空草稿直接接收焦点，不累积空条目');
    expect(
      tester.widget<TextField>(thoughtFields()).focusNode!.hasFocus,
      isTrue,
    );
    await tester.pump();
    expect(find.byTooltip('删除这条思考'), findsOneWidget);
    await tester.enterText(thoughtFields(), '第一条\n第二行仍在第一条');
    await tester.tap(find.byTooltip('添加个人思考'));
    await tester.pump();
    expect(thoughtFields(), findsNWidgets(2));
    expect(
      tester.widget<TextField>(thoughtFields().last).focusNode!.hasFocus,
      isTrue,
    );
    await tester.enterText(thoughtFields().last, '第二条思考');
    await tester.pump(const Duration(milliseconds: 550));
    await tester.pump();
    expect(saved.single.map((thought) => thought.text), [
      '第一条\n第二行仍在第一条',
      '第二条思考',
    ]);
    final secondId = saved.single.last.id;
    await tester.tap(thoughtFields().first);
    await tester.pump();
    expect(find.byTooltip('删除这条思考'), findsOneWidget);
    expect(
      find.byKey(ValueKey('card-delete-thought-$secondId')),
      findsNothing,
      reason: '删除按钮只跟随选中的条目',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(find.byTooltip('删除这条思考'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await controller.flush();
    expect(saved.last, [PersonalThought(id: secondId, text: '第二条思考')]);
    expect(thoughtFields(), findsOneWidget);
    await tester.tap(thoughtFields());
    await tester.pump();
    await tester.tap(find.byTooltip('删除这条思考'));
    await tester.pump();
    await controller.flush();
    expect(saved.last, isEmpty);
    expect(thoughtFields(), findsOneWidget, reason: '删除最后一条后可直接写下一条');
    await tester.tap(thoughtFields());
    await tester.pump();
    expect(find.byTooltip('删除这条思考'), findsOneWidget);
    await tester.tap(find.byKey(const Key('card-body')));
    await tester.pump();
    expect(find.byTooltip('删除这条思考'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('卡片色点：七色可点击，取消不提交且同卡改色保留输入焦点', (tester) async {
    final previousShadows = debugDisableShadows;
    debugDisableShadows = false;
    try {
      final controller = CardEditorController();
      final boundary = GlobalKey();
      final colors = <String>[];
      Future<void> save(String _, String _, List<PersonalThought> _) async {}
      Future<void> changeColor(String value) async => colors.add(value);
      await mount(
        tester,
        cardWith(note: '正在思考'),
        controller,
        save,
        onColorChanged: changeColor,
        boundary: boundary,
      );
      await tester.tap(thoughtFields());
      await tester.pump();
      final field = tester.widget<TextField>(thoughtFields());
      expect(field.focusNode!.hasFocus, isTrue);
      final colorButton = find.byKey(const Key('card-editor-color'));
      expect(tester.getSize(colorButton).width, greaterThanOrEqualTo(36));
      expect(tester.getSize(colorButton).height, greaterThanOrEqualTo(36));
      await tester.tap(colorButton);
      await tester.pumpAndSettle();
      final swatches = find.byWidgetPredicate(
        (widget) =>
            widget is InkWell && widget.key.toString().contains('card-color-#'),
      );
      expect(swatches, findsNWidgets(7));
      final rowTop = tester.getTopLeft(swatches.first).dy;
      for (final element in swatches.evaluate()) {
        expect(
          tester.getSize(find.byWidget(element.widget)).width,
          greaterThanOrEqualTo(36),
        );
        expect(find.byWidget(element.widget).hitTestable(), findsOneWidget);
        expect(
          tester.getTopLeft(find.byWidget(element.widget)).dy,
          rowTop,
          reason: '七种颜色在代表宽度下紧凑排列为一行',
        );
      }
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await render.toImage(pixelRatio: 1);
        try {
          final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
          await File(
            '.local/verification/sticky-card-panel/color-palette-360.png',
          ).writeAsBytes(png.buffer.asUint8List());
        } finally {
          image.dispose();
        }
      });
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(colors, isEmpty);
      await tester.tap(colorButton);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('card-color-#80B9EB')));
      await tester.pumpAndSettle();
      expect(colors, ['#80B9EB']);
      expect(swatches, findsNothing);
      await mount(
        tester,
        cardWith(note: '正在思考', color: '#80B9EB'),
        controller,
        save,
        onColorChanged: changeColor,
        boundary: boundary,
      );
      expect(
        tester.widget<TextField>(thoughtFields()).controller,
        same(field.controller),
      );
      expect(field.focusNode!.hasFocus, isTrue);
      expect(field.controller!.text, '正在思考');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      debugDisableShadows = previousShadows;
    }
  });

  testWidgets('卡片色点：提交期间禁用入口，失败恢复且空面板仅保留关闭', (tester) async {
    final controller = CardEditorController();
    final pending = Completer<void>();
    await mount(
      tester,
      cardWith(),
      controller,
      (_, _, _) async {},
      onColorChanged: (_) => pending.future,
    );
    await tester.tap(find.byKey(const Key('card-editor-color')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('card-color-#91C69A')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<PopupMenuButton<String>>(
            find.byKey(const Key('card-editor-color')),
          )
          .enabled,
      isFalse,
    );
    pending.completeError(StateError('模拟改色失败'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<PopupMenuButton<String>>(
            find.byKey(const Key('card-editor-color')),
          )
          .enabled,
      isTrue,
    );
    var closed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CardEditorPlaceholder(onClose: () => closed = true),
        ),
      ),
    );
    expect(find.text('请选择卡片'), findsOneWidget);
    expect(find.byKey(const Key('card-editor-color')), findsNothing);
    await tester.tap(find.byTooltip('收起编辑'));
    expect(closed, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('个人思考：排队保存使用完整快照，失败可重试最新内容', (tester) async {
    final controller = CardEditorController();
    final saved = <List<PersonalThought>>[];
    final firstSave = Completer<void>();
    var fail = false;
    await mount(tester, cardWith(note: '原思考'), controller, (
      _,
      _,
      thoughts,
    ) async {
      saved.add(thoughts);
      if (saved.length == 1) await firstSave.future;
      if (fail) throw StateError('模拟保存失败');
    });
    await tester.enterText(thoughtFields(), '第一份快照');
    final first = controller.flush();
    await tester.pump();
    await tester.tap(find.byTooltip('添加个人思考'));
    await tester.pump();
    await tester.enterText(thoughtFields().last, '排队中的第二条');
    final second = controller.flush();
    firstSave.complete();
    await first;
    await second;
    expect(saved.first.map((t) => t.text), ['第一份快照']);
    expect(saved.last.map((t) => t.text), ['第一份快照', '排队中的第二条']);
    await tester.enterText(thoughtFields().last, '失败后必须保留的思考');
    fail = true;
    await expectLater(controller.flush(), throwsStateError);
    fail = false;
    await controller.flush();
    expect(saved.last.last.text, '失败后必须保留的思考');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('个人思考：保存回读与窄栏缩放保留每条控制器及焦点，外部撤销同步内容', (tester) async {
    final controller = CardEditorController();
    var saved = <PersonalThought>[];
    Future<void> save(
      String _,
      String _,
      List<PersonalThought> thoughts,
    ) async => saved = thoughts;
    await mount(tester, cardWith(note: '旧备注'), controller, save);
    await tester.tap(find.byTooltip('添加个人思考'));
    await tester.pump();
    await tester.enterText(thoughtFields().last, '正在输入第二条');
    final field = tester.widget<TextField>(thoughtFields().last);
    await controller.flush();
    await mount(
      tester,
      cardWith(note: personalThoughtsText(saved), thoughts: saved),
      controller,
      save,
      size: const Size(320, 750),
    );
    expect(
      tester.widget<TextField>(thoughtFields().last).controller,
      same(field.controller),
    );
    expect(field.focusNode!.hasFocus, isTrue);
    expect(field.controller!.text, '正在输入第二条');
    await mount(
      tester,
      cardWith(note: '旧备注', thoughts: [saved.first]),
      controller,
      save,
    );
    expect(thoughtFields(), findsOneWidget);
    expect(tester.widget<TextField>(thoughtFields()).controller!.text, '旧备注');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('个人思考：长内容随外层滚动，360宽真实字体截图无溢出', (tester) async {
    final controller = CardEditorController();
    final boundary = GlobalKey();
    const thoughts = [
      PersonalThought(id: 'first', text: '我想把注意力放回当前这件事。\n把每天重复的工作，变成觉察自己的机会。'),
      PersonalThought(
        id: 'second',
        text: '明天试着在开始工作前停留一分钟，想清楚今天最重要的目标。\n也留意忙碌时有没有忽略身边的人。',
      ),
    ];
    await mount(
      tester,
      cardWith(note: personalThoughtsText(thoughts), thoughts: thoughts),
      controller,
      (_, _, _) async {},
      boundary: boundary,
    );
    await tester.tap(thoughtFields().first, kind: ui.PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    final render =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await render.toImage(pixelRatio: 1);
      try {
        final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        final directory = await Directory(
          '.local/verification/personal-thoughts',
        ).create(recursive: true);
        await File('${directory.path}/editor-360.png')
            .writeAsBytes(png.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
    await tester.enterText(
      thoughtFields().last,
      List.filled(25, '很长的思考也保持在同一条中。').join('\n'),
    );
    await tester.pump();
    expect(tester.widget<TextField>(thoughtFields().last).maxLines, isNull);
    await tester.ensureVisible(find.text('原文'));
    await tester.pumpAndSettle();
    expect(find.text('原文').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await controller.flush();
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
