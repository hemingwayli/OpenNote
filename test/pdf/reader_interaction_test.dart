import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opennote/domain/models.dart' as model;
import 'package:opennote/engines/pdf/pdf_read_engine.dart';
import 'package:opennote/ui/reader/reader_pane.dart';
import 'package:opennote/ui/map/mind_map_pane.dart';
import 'package:opennote/ui/theme/open_note_theme.dart';
import 'package:opennote/ui/theme/open_note_view_switch.dart';
import 'package:pdfrx/pdfrx.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    Pdfrx.pdfiumModulePath = File('build/windows/x64/runner/Release/pdfium.dll')
        .absolute
        .path;
    await pdfrxInitialize();
    if (Platform.environment['OPENNOTE_READER_OUTLINE_PREVIEW_DIR'] != null) {
      final latin = FontLoader('Segoe UI')
        ..addFont(
          File('C:/Windows/Fonts/segoeui.ttf')
              .readAsBytes()
              .then(ByteData.sublistView),
        );
      final chinese = FontLoader('Source Han Sans CN');
      for (final weight in ['Regular', 'Medium', 'Bold']) {
        chinese.addFont(
          rootBundle.load(
            'assets/fonts/source-han-sans/SourceHanSansCN-$weight.otf',
          ),
        );
      }
      await latin.load();
      await chinese.load();
    }
  });

  for (final ocr in [false, true]) {
    testWidgets('排版折行：${ocr ? 'OCR' : '原生'}按钮、右键、拖入一致，复制和失败选区保留', (
      tester,
    ) async {
      final excerpts = <SelectedExcerpt>[];
      var drops = 0;
      String? clipboard;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String;
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
      final directory = await tester.runAsync(
        () => Directory.systemTemp.createTemp('opennote-excerpt-wrap-'),
      );
      final file = File('${directory!.path}/wrapped.pdf');
      final first = '${List.filled(6, 'context ').join()}alpha';
      final second = 'beta ${List.filled(6, 'context ').join()}'.trimRight();
      const third = 'A short ending.';
      await tester.runAsync(
        () => file.writeAsBytes(
          _outlinePdf(
            contentOverride:
                'BT /F1 12 Tf 40 700 Td ($first) Tj '
                '0 -14 Td ($second) Tj 0 -14 Td ($third) Tj ET',
          ),
        ),
      );
      final text = [first, second, third].join('\n');
      final fragments = <model.TextFragment>[];
      var offset = 0;
      for (var row = 0; row < 3; row++) {
        final line = [first, second, third][row];
        for (var index = 0; index < line.length; index++) {
          fragments.add(
            model.TextFragment(
              start: offset + index,
              length: 1,
              order: fragments.length,
              quad: model.PdfQuad.rect(
                40 + index * 6,
                690 - row * 14,
                46 + index * 6,
                702 - row * 14,
              ),
              precision: model.GeometryPrecision.approximateCharacter,
            ),
          );
        }
        offset += line.length + 1;
      }
      final ocrLayer = model.PageTextLayer(
        id: 'ocr-wrap',
        revisionId: 'interaction',
        pageIndex: 0,
        source: model.TextLayerSource.ocr,
        text: text,
        fragments: fragments,
        engineVersion: 'fixture',
        createdAt: DateTime.utc(2026),
        parameters: const {'writingDirection': 'horizontalLtr'},
      );
      final session = await _mount(
        tester,
        ocr ? 'tools/fixtures/pdf/scanned.pdf' : file.path,
        excerpts.add,
        textLayers: ocr ? [ocrLayer] : const [],
        waitForText: !ocr,
        enableTextDrag: true,
        outside: DragTarget<ReaderExcerptDrag>(
          onWillAcceptWithDetails: (details) => details.data.canAccept,
          onAcceptWithDetails: (details) async {
            final drag = details.data;
            if (!drag.claim()) return;
            excerpts.add(await drag.prepare());
            drops++;
            if (drops == 1) {
              drag.fail(StateError('模拟保存失败'));
            } else {
              drag.commit();
            }
          },
          builder: (_, _, _) => const SizedBox.expand(),
        ),
      );
      try {
        final layer = ocr
            ? model.TextLayerDraft(
                revisionId: ocrLayer.revisionId,
                pageIndex: 0,
                source: ocrLayer.source,
                text: text,
                fragments: fragments,
                engineVersion: 'fixture',
                parameters: ocrLayer.parameters,
              )
            : session.layers[0]!;
        final start = layer.text.indexOf('alpha');
        final end = layer.text.indexOf('beta') + 4;
        Offset character(int index) => _characterPosition(
          tester,
          session.viewer,
          layer,
          session.geometry[0],
          index,
        );
        final gesture = await tester.startGesture(
          character(start),
          kind: PointerDeviceKind.mouse,
        );
        await gesture.moveTo(character(end - 1));
        await tester.pump();
        await gesture.up();
        await tester.pump();
        final raw = layer.text.substring(start, end);
        expect(raw, contains('\n'));
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
        expect(clipboard, raw);
        await tester.tap(find.byTooltip('摘录到顶层'));
        await _until(tester, () => excerpts.length == 1);
        expect(excerpts.single.text, 'alpha beta');
        await tester.tapAt(
          character(start + 2),
          buttons: kSecondaryMouseButton,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('摘录'));
        await _until(tester, () => excerpts.length == 2);
        for (var attempt = 0; attempt < 2; attempt++) {
          final data = tester
              .widget<Draggable<ReaderExcerptDrag>>(
                find.byType(Draggable<ReaderExcerptDrag>).first,
              )
              .data!;
          expect(data.text, raw, reason: '拖动校验继续使用原始选区');
          final held = await tester.startGesture(
            character(start + 2),
            kind: PointerDeviceKind.mouse,
          );
          await held.moveBy(const Offset(24, 0));
          await tester.pump();
          await held.moveTo(const Offset(840, 340));
          await held.up();
          await _until(tester, () => drops == attempt + 1);
          await tester.pumpAndSettle();
          expect(
            find.byKey(const Key('reader-selection-start')),
            attempt == 0 ? findsOneWidget : findsNothing,
          );
        }
        expect(excerpts, hasLength(4));
        for (final excerpt in excerpts) {
          expect(excerpt.text, 'alpha beta');
          final anchor = excerpt.anchors.single;
          expect(anchor.context, raw);
          expect(anchor.textStart, start);
          expect(anchor.textEnd, end);
          expect(
            anchor.quads.map((q) => q.toJson()),
            excerpts.first.anchors.single.quads.map((q) => q.toJson()),
          );
          if (ocr) expect(anchor.textLayerId, 'ocr-wrap');
        }
        await session.controller.jumpToAnchors(excerpts.last.anchors);
        await tester.pumpAndSettle();
        expect(session.viewer.pageNumber, 1);
        expect(tester.takeException(), isNull);
      } finally {
        await _unmount(tester, session.controller);
        await tester.runAsync(() => directory.delete(recursive: true));
      }
    });
  }

  testWidgets('光标反馈：正文、空白、链接、移动平移和扫描页文字就绪', (tester) async {
    var session = await _mount(tester, 'tools/fixtures/pdf/links.pdf', (_) {});
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(1, 1));
    Future<void> hover(Offset point, MouseCursor expected) async {
      await mouse.moveTo(point);
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump();
      expect(tester.binding.mouseTracker.debugDeviceActiveCursor(1), expected);
    }

    try {
      final pane = tester.getRect(find.byType(PdfViewer));
      final blank = pane.topLeft + const Offset(12, 50);
      await hover(blank, SystemMouseCursors.basic);
      late List<PdfLink> links;
      await tester.runAsync(() async {
        links = await session.viewer.pages[0].loadLinks(
          enableAutoLinkDetection: false,
        );
      });
      final link = links.firstWhere(
        (link) => link.dest != null && link.rects.single.bottom == 690,
      );
      final rect = link.rects.single.toRectInDocument(
        page: session.viewer.pages[0],
        pageRect: session.viewer.layout.pageLayouts[0],
      );
      await session.viewer.ensureVisible(rect, duration: Duration.zero);
      await tester.pump();
      final linkPoint =
          tester.getTopLeft(find.byType(PdfViewer)) +
          session.viewer.documentToLocal(rect.center);
      await hover(linkPoint, SystemMouseCursors.click);
      await tester.tap(find.byTooltip('矩形'));
      await tester.pump();
      await hover(linkPoint, SystemMouseCursors.precise);
      await tester.tap(find.byTooltip('移动'));
      await tester.pump();
      await hover(blank, SystemMouseCursors.grab);
      final before = session.viewer.value.clone();
      await mouse.down(blank);
      await mouse.moveBy(const Offset(35, -35));
      await tester.pump();
      await mouse.moveBy(const Offset(0, -25));
      await tester.pump();
      expect(
        tester.binding.mouseTracker.debugDeviceActiveCursor(1),
        SystemMouseCursors.grabbing,
      );
      expect(session.viewer.value, isNot(before), reason: '透明光标层必须保留真实平移');
      await mouse.up();
      await tester.pumpAndSettle();
      await hover(blank, SystemMouseCursors.grab);
      await _unmount(tester, session.controller);
      session = await _mount(
        tester,
        'tools/fixtures/pdf/scanned.pdf',
        (_) {},
        waitForText: false,
      );
      await hover(
        tester.getCenter(find.byType(PdfViewer)),
        SystemMouseCursors.basic,
      );
    } finally {
      await mouse.removePointer();
      await _unmount(tester, session.controller);
    }
  });

  testWidgets('光标反馈：文字拖入真实脑图显示复制，工具栏禁止，取消与保存恢复', (tester) async {
    var received = 0;
    final saved = Completer<void>();
    final session = await _mount(
      tester,
      'tools/fixtures/pdf/native.pdf',
      (_) {},
      enableTextDrag: true,
      outsideWidth: 320,
      outside: MindMapPane(
        snapshot: const model.MapSnapshot(
          map: model.MindMap(id: 'map', projectId: 'p', title: '脑图'),
          nodes: [],
          cards: {},
          anchors: {},
          edges: [],
        ),
        onSelect: (_) {},
        onMove: (_, _, _) async {},
        onReparent: (_, _) async {},
        onAssociate: (_, _) async {},
        onRemoveAssociation: (_) {},
        onAction: (_, _) {},
        onToggleCollapsed: (_) {},
        onTextExcerptDrop: (drag, _, _) async {
          final excerpt = await drag.prepare();
          expect(excerpt.text, 'OpenNote');
          received++;
          await saved.future;
        },
      ),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(1, 1));
    try {
      await _selectHeading(
        tester,
        session.viewer,
        session.layers[0]!,
        session.geometry[0],
      );
      final source = _characterPosition(
        tester,
        session.viewer,
        session.layers[0]!,
        session.geometry[0],
        session.layers[0]!.text.indexOf('OpenNote') + 2,
      );
      await mouse.moveTo(
        tester.getCenter(find.byKey(const Key('reader-selection-start'))),
      );
      await tester.pump();
      expect(
        tester.binding.mouseTracker.debugDeviceActiveCursor(1),
        SystemMouseCursors.move,
      );
      await mouse.moveTo(source);
      await tester.pump();
      expect(
        tester.binding.mouseTracker.debugDeviceActiveCursor(1),
        SystemMouseCursors.grab,
      );
      Future<void> begin() async {
        await mouse.down(source);
        await mouse.moveBy(const Offset(24, 0));
        await tester.pump();
        expect(
          find.byKey(const Key('reader-text-drag-preview')),
          findsOneWidget,
        );
      }

      final target =
          tester.getCenter(find.byType(MindMapPane)) - const Offset(0, 80);
      await begin();
      await mouse.moveTo(target);
      await tester.pump();
      expect(
        tester.binding.mouseTracker.debugDeviceActiveCursor(1),
        SystemMouseCursors.copy,
      );
      await mouse.moveTo(tester.getCenter(find.byTooltip('适合全部卡片')));
      await tester.pump();
      expect(
        tester.binding.mouseTracker.debugDeviceActiveCursor(1),
        SystemMouseCursors.grabbing,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await mouse.up();
      await tester.pump();
      expect(received, 0);
      expect(find.byKey(const Key('reader-selection-start')), findsOneWidget);
      await mouse.moveTo(source);
      await tester.pump();
      expect(
        tester.binding.mouseTracker.debugDeviceActiveCursor(1),
        SystemMouseCursors.grab,
      );
      await begin();
      await mouse.moveTo(target);
      await tester.pump();
      expect(
        tester.binding.mouseTracker.debugDeviceActiveCursor(1),
        SystemMouseCursors.copy,
      );
      await mouse.up();
      await _until(tester, () => received == 1);
      saved.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reader-selection-start')), findsNothing);
      await mouse.moveTo(source);
      await tester.pump();
      expect(
        tester.binding.mouseTracker.debugDeviceActiveCursor(1),
        SystemMouseCursors.text,
      );
      expect(received, 1);
    } finally {
      if (!saved.isCompleted) saved.complete();
      await mouse.removePointer();
      await _unmount(tester, session.controller);
    }
  });

  testWidgets('文字拖出：右键摘录优先，文字层准备与保存确认后才清除整个选区', (tester) async {
    final received = <SelectedExcerpt>[];
    final saved = Completer<void>();
    final session = await _mount(
      tester,
      'tools/fixtures/pdf/native.pdf',
      (_) {},
      enableTextDrag: true,
      outside: DragTarget<ReaderExcerptDrag>(
        onWillAcceptWithDetails: (details) => details.data.canAccept,
        onAcceptWithDetails: (details) async {
          final drag = details.data;
          if (!drag.claim()) return;
          try {
            received.add(await drag.prepare());
            await saved.future;
            drag.commit();
          } catch (error) {
            drag.fail(error);
          }
        },
        builder: (_, _, _) =>
            const ColoredBox(color: Colors.white, child: SizedBox.expand()),
      ),
    );
    try {
      await _selectHeading(
        tester,
        session.viewer,
        session.layers[0]!,
        session.geometry[0],
      );
      final index = session.layers[0]!.text.indexOf('OpenNote') + 2;
      final point = _characterPosition(
        tester,
        session.viewer,
        session.layers[0]!,
        session.geometry[0],
        index,
      );
      await tester.tapAt(point, buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('摘录')).dy,
        lessThan(tester.getTopLeft(find.text('复制选中文字')).dy),
      );
      await tester.tap(find.text('复制选中文字'));
      await tester.pumpAndSettle();
      final start = _characterPosition(
        tester,
        session.viewer,
        session.layers[0]!,
        session.geometry[0],
        index,
      );
      final held = await tester.startGesture(
        start,
        kind: PointerDeviceKind.mouse,
      );
      await held.moveBy(const Offset(24, 0));
      await tester.pump();
      expect(find.byKey(const Key('reader-text-drag-preview')), findsOneWidget);
      final cursor = tester.widget<MouseRegion>(
        find
            .ancestor(
              of: find.byType(Draggable<ReaderExcerptDrag>).first,
              matching: find.byType(MouseRegion),
            )
            .first,
      );
      expect(cursor.cursor, SystemMouseCursors.grab);
      await held.moveTo(const Offset(840, 340));
      await tester.pump();
      await held.up();
      await _until(tester, () => received.isNotEmpty);
      expect(received.single.text, 'OpenNote');
      expect(
        received.single.anchors.single.textStart,
        session.layers[0]!.text.indexOf('OpenNote'),
      );
      expect(
        received.single.anchors.single.textEnd,
        session.layers[0]!.text.indexOf('OpenNote') + 8,
      );
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (w) => w is IconButton && w.tooltip == '摘录到顶层',
              ),
            )
            .onPressed,
        isNull,
        reason: '保存确认前不允许重复摘录',
      );
      saved.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reader-selection-start')), findsNothing);
      expect(find.byKey(const Key('reader-selection-end')), findsNothing);
      expect(received, hasLength(1));
      expect(tester.takeException(), isNull);
    } finally {
      if (!saved.isCompleted) saved.complete();
      await _unmount(tester, session.controller);
    }
  });

  testWidgets('文字拖出：无效落点、Esc 和保存失败均保留选区，右键不启动拖动', (tester) async {
    var accepted = 0;
    final session = await _mount(
      tester,
      'tools/fixtures/pdf/native.pdf',
      (_) {},
      enableTextDrag: true,
      outside: DragTarget<ReaderExcerptDrag>(
        onWillAcceptWithDetails: (details) => details.data.canAccept,
        onAcceptWithDetails: (details) {
          if (details.data.claim()) {
            accepted++;
            details.data.fail(StateError('模拟保存失败'));
          }
        },
        builder: (_, _, _) =>
            const ColoredBox(color: Colors.white, child: SizedBox.expand()),
      ),
    );
    try {
      await _selectHeading(
        tester,
        session.viewer,
        session.layers[0]!,
        session.geometry[0],
      );
      Offset source() => _characterPosition(
        tester,
        session.viewer,
        session.layers[0]!,
        session.geometry[0],
        session.layers[0]!.text.indexOf('OpenNote') + 2,
      );
      Future<TestGesture> start() async {
        final held = await tester.startGesture(
          source(),
          kind: PointerDeviceKind.mouse,
        );
        await held.moveBy(const Offset(24, 0));
        await tester.pump();
        expect(
          find.byKey(const Key('reader-text-drag-preview')),
          findsOneWidget,
        );
        return held;
      }

      final invalid = await start();
      await invalid.moveTo(
        tester.getTopLeft(find.byType(PdfViewer)) + const Offset(20, 300),
      );
      await invalid.up();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reader-selection-start')), findsOneWidget);
      expect(accepted, 0);
      final cancelled = await start();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byKey(const Key('reader-text-drag-preview')), findsNothing);
      await cancelled.moveTo(const Offset(840, 340));
      await cancelled.up();
      await tester.pumpAndSettle();
      expect(accepted, 0);
      expect(find.byKey(const Key('reader-selection-start')), findsOneWidget);
      await tester.tapAt(source(), buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reader-text-drag-preview')), findsNothing);
      await tester.tap(find.text('复制选中文字'));
      await tester.pumpAndSettle();
      final rejected = await start();
      await rejected.moveTo(const Offset(840, 340));
      await rejected.up();
      await tester.pumpAndSettle();
      expect(accepted, 1);
      expect(find.textContaining('模拟保存失败'), findsOneWidget);
      expect(find.byKey(const Key('reader-selection-start')), findsOneWidget);
      expect(find.byKey(const Key('reader-selection-end')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(
        find.byKey(const Key('reader-selection-start')),
        findsNothing,
        reason: '未拖动时 Esc 仍清除选区',
      );
      expect(tester.takeException(), isNull);
    } finally {
      await _unmount(tester, session.controller);
    }
  });

  testWidgets('文字拖出：切换上下文取消旧拖动，迟到提交不清除新选区', (tester) async {
    final context = ValueNotifier<Object>('脑图 A');
    final saved = Completer<void>();
    var accepted = 0, prepared = 0;
    final session = await _mount(
      tester,
      'tools/fixtures/pdf/native.pdf',
      (_) {},
      enableTextDrag: true,
      dragContext: context,
      outside: DragTarget<ReaderExcerptDrag>(
        onWillAcceptWithDetails: (details) => details.data.canAccept,
        onAcceptWithDetails: (details) async {
          if (!details.data.claim()) return;
          accepted++;
          await details.data.prepare();
          prepared++;
          await saved.future;
          details.data.commit();
        },
        builder: (_, _, _) =>
            const ColoredBox(color: Colors.white, child: SizedBox.expand()),
      ),
    );
    try {
      await _selectHeading(
        tester,
        session.viewer,
        session.layers[0]!,
        session.geometry[0],
      );
      Future<TestGesture> start() async {
        final point = _characterPosition(
          tester,
          session.viewer,
          session.layers[0]!,
          session.geometry[0],
          session.layers[0]!.text.indexOf('OpenNote') + 2,
        );
        final held = await tester.startGesture(
          point,
          kind: PointerDeviceKind.mouse,
        );
        await held.moveBy(const Offset(24, 0));
        await tester.pump();
        expect(
          find.byKey(const Key('reader-text-drag-preview')),
          findsOneWidget,
        );
        return held;
      }

      final old = await start();
      context.value = '脑图 B';
      await tester.pump();
      // 来源在构建期间失效，浮层监听在该帧结束后更新。
      await tester.pump();
      expect(find.byKey(const Key('reader-text-drag-preview')), findsNothing);
      await old.moveTo(const Offset(840, 340));
      await old.up();
      await tester.pump();
      expect(accepted, 0);
      expect(find.byKey(const Key('reader-selection-start')), findsOneWidget);
      final waiting = await start();
      await waiting.moveTo(const Offset(840, 340));
      await waiting.up();
      await _until(tester, () => prepared == 1);
      context.value = '项目 C';
      await tester.pump();
      await _selectHeading(
        tester,
        session.viewer,
        session.layers[0]!,
        session.geometry[0],
      );
      saved.complete();
      await tester.pumpAndSettle();
      expect(accepted, 1);
      expect(find.byKey(const Key('reader-selection-start')), findsOneWidget);
      expect(find.byKey(const Key('reader-selection-end')), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      if (!saved.isCompleted) saved.complete();
      await _unmount(tester, session.controller);
      context.dispose();
    }
  });

  testWidgets('文字拖出：多行跨页选区一次完整接收并保留逐页锚点', (tester) async {
    final received = <SelectedExcerpt>[];
    final session = await _mount(
      tester,
      'tools/fixtures/pdf/native.pdf',
      (_) {},
      enableTextDrag: true,
      outside: DragTarget<ReaderExcerptDrag>(
        onWillAcceptWithDetails: (details) => details.data.canAccept,
        onAcceptWithDetails: (details) async {
          if (!details.data.claim()) return;
          received.add(await details.data.prepare());
          details.data.commit();
        },
        builder: (_, _, _) =>
            const ColoredBox(color: Colors.white, child: SizedBox.expand()),
      ),
    );
    try {
      await _until(tester, () => session.layers.containsKey(1));
      await session.viewer.setZoom(
        const Offset(300, 650),
        .35,
        duration: Duration.zero,
      );
      await session.viewer.goToPage(pageNumber: 1, duration: Duration.zero);
      await tester.pumpAndSettle();
      Offset position(int page, model.TextFragment fragment) {
        final rect = PdfCoordinateAdapter(session.geometry[page])
            .quadInDocument(
              fragment.quad,
              session.viewer.pages[page],
              session.viewer.layout.pageLayouts[page],
            )
            .getBounds();
        return tester.getTopLeft(find.byType(PdfViewer)) +
            session.viewer.documentToLocal(rect.center);
      }

      final a = session.layers[0]!.fragments.first;
      final b = session.layers[1]!.fragments.firstWhere(
        (f) => session.layers[1]!.text
            .substring(f.start, f.start + f.length)
            .trim()
            .isNotEmpty,
      );
      final begin = position(0, a), end = position(1, b);
      expect(tester.getRect(find.byType(PdfViewer)).contains(end), isTrue);
      final selecting = await tester.startGesture(
        begin,
        kind: PointerDeviceKind.mouse,
      );
      await selecting.moveTo(end);
      await tester.pump();
      await selecting.up();
      await tester.pump();
      expect(find.byKey(const Key('reader-selection-start')), findsOneWidget);
      final data = tester
          .widget<Draggable<ReaderExcerptDrag>>(
            find.byType(Draggable<ReaderExcerptDrag>).first,
          )
          .data!;
      expect(data.anchors.map((a) => a.pageIndex), [0, 1]);
      expect(data.text, data.anchors.map((a) => a.context).join('\n'));
      expect(
        data.anchors.first.quads.length,
        greaterThan(10),
        reason: '第一页面包含多行文字',
      );
      final held = await tester.startGesture(
        begin + const Offset(1, 0),
        kind: PointerDeviceKind.mouse,
      );
      await held.moveBy(const Offset(24, 0));
      await tester.pump();
      expect(find.byKey(const Key('reader-text-drag-preview')), findsOneWidget);
      await held.moveTo(const Offset(840, 340));
      await held.up();
      await _until(tester, () => received.isNotEmpty);
      await tester.pumpAndSettle();
      expect(received, hasLength(1));
      expect(received.single.text, data.text);
      expect(received.single.anchors.map((a) => a.pageIndex), [0, 1]);
      expect(find.byKey(const Key('reader-selection-start')), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await _unmount(tester, session.controller);
    }
  });

  testWidgets('连续文字标注：空格像素为黄色且点击空格激活整条标注', (tester) async {
    final prepared = await _mount(
      tester,
      'tools/fixtures/pdf/native.pdf',
      (_) {},
    );
    final layer = prepared.layers[0]!;
    final geometry = prepared.geometry;
    final space = layer.text.indexOf(' ');
    expect(space, greaterThan(0));
    final left = layer.fragments.lastWhere((f) => f.start < space);
    final right = layer.fragments.firstWhere(
      (f) => f.start > space && layer.text[f.start].trim().isNotEmpty,
    );
    await _unmount(tester, prepared.controller);
    final controller = ReaderPaneController();
    final boundary = GlobalKey();
    final ready = <int>[];
    final activated = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RepaintBoundary(
            key: boundary,
            child: ReaderPane(
              revisionId: 'annotation-gap',
              filePath: File('tools/fixtures/pdf/native.pdf').absolute.path,
              controller: controller,
              pageGeometry: geometry,
              onExcerpt: (_) {},
              onNativeTextLayer: (value) async => ready.add(value.pageIndex),
              onAnnotationActivated: (value) => activated.add(value.id),
              annotations: [
                model.AppAnnotation(
                  id: 'continuous',
                  revisionId: 'annotation-gap',
                  pageIndex: 0,
                  quads: [left.quad, right.quad],
                  kind: 'highlight',
                  text: '',
                  color: '#F7D976',
                ),
              ],
            ),
          ),
        ),
      ),
    );
    try {
      await _until(tester, () => ready.contains(0));
      final viewer = tester
          .widget<PdfViewer>(find.byType(PdfViewer))
          .controller!;
      final adapter = PdfCoordinateAdapter(geometry[0]);
      final pageRect = viewer.layout.pageLayouts[0];
      final a = adapter
          .quadInDocument(left.quad, viewer.pages[0], pageRect)
          .getBounds();
      final b = adapter
          .quadInDocument(right.quad, viewer.pages[0], pageRect)
          .getBounds();
      final documentPoint = Offset(
        (a.right + b.left) / 2,
        (a.center.dy + b.center.dy) / 2,
      );
      final global =
          tester.getTopLeft(find.byType(PdfViewer)) +
          viewer.documentToLocal(documentPoint);
      await tester.pumpAndSettle();
      final box =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = (await tester.runAsync(() => box.toImage(pixelRatio: 1)))!;
      try {
        final data = (await tester.runAsync(
          () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
        ))!;
        final local = box.globalToLocal(global);
        final offset = (local.dy.floor() * image.width + local.dx.floor()) * 4;
        expect(data.getUint8(offset), greaterThan(245));
        expect(
          data.getUint8(offset + 2),
          lessThan(235),
          reason: '空格像素应填入黄色，不能露出白色断点',
        );
        final png = (await tester.runAsync(
          () => image.toByteData(format: ui.ImageByteFormat.png),
        ))!;
        await tester.runAsync(() async {
          final file = File(
            '.local/verification/text-excerpt-20261006/continuous-highlight.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(png.buffer.asUint8List());
        });
      } finally {
        image.dispose();
      }
      await tester.tapAt(global);
      await tester.pump();
      expect(activated, ['continuous']);
      expect(tester.takeException(), isNull);
    } finally {
      await _unmount(tester, controller);
    }
  });

  testWidgets('滚轮阅读：系统距离不受缩放和 DPI 影响，三种工具均平滑累加', (tester) async {
    final session = await _mount(
      tester,
      'tools/fixtures/pdf/native.pdf',
      (_) {},
    );
    addTearDown(tester.view.resetDevicePixelRatio);
    try {
      for (final dpr in [1.0, 1.5]) {
        tester.view.devicePixelRatio = dpr;
        await tester.pumpAndSettle();
        for (final zoom in [.75, 1.0, 2.0]) {
          await session.viewer.setZoom(
            const Offset(300, 800),
            zoom,
            duration: Duration.zero,
          );
          await tester.pumpAndSettle();
          final before = session.viewer.visibleRect.top;
          await _wheel(tester, const Offset(0, 100));
          expect(session.viewer.visibleRect.top, closeTo(before, .01));
          await tester.pump(const Duration(milliseconds: 50));
          expect(
            (session.viewer.visibleRect.top - before) * zoom,
            inExclusiveRange(0, 100),
          );
          await tester.pumpAndSettle();
          expect(
            (session.viewer.visibleRect.top - before) * zoom,
            closeTo(100, .1),
          );
        }
      }
      tester.view.resetDevicePixelRatio();
      for (final tool in ['移动', '选文', '矩形']) {
        await tester.tap(find.byTooltip(tool));
        await tester.pumpAndSettle();
        await session.viewer.setZoom(
          const Offset(300, 800),
          1,
          duration: Duration.zero,
        );
        await tester.pumpAndSettle();
        final before = session.viewer.visibleRect.top;
        await _wheel(tester, const Offset(0, 100));
        await tester.pump(const Duration(milliseconds: 35));
        await _wheel(tester, const Offset(0, 100));
        await tester.pump(const Duration(milliseconds: 35));
        await _wheel(tester, const Offset(0, 100));
        await tester.pumpAndSettle();
        expect(session.viewer.visibleRect.top - before, closeTo(300, .1));
      }
    } finally {
      await _unmount(tester, session.controller);
    }
  });

  testWidgets('滚轮阅读：反向、边界、点击、跳页与 Ctrl 缩放均可打断旧滚动', (tester) async {
    final session = await _mount(
      tester,
      'tools/fixtures/pdf/native.pdf',
      (_) {},
    );
    try {
      await session.viewer.setZoom(
        const Offset(300, 800),
        1,
        duration: Duration.zero,
      );
      await tester.pumpAndSettle();
      await _wheel(tester, const Offset(0, 100));
      await tester.pump(const Duration(milliseconds: 40));
      final reversal = session.viewer.visibleRect.top;
      await _wheel(tester, const Offset(0, -100));
      await tester.pump(const Duration(milliseconds: 40));
      expect(session.viewer.visibleRect.top, lessThan(reversal));
      await tester.pumpAndSettle();
      expect(session.viewer.visibleRect.top, closeTo(reversal - 100, .1));

      await _wheel(tester, const Offset(0, -10000));
      await tester.pumpAndSettle();
      final top = session.viewer.visibleRect.top;
      await _wheel(tester, const Offset(0, -100));
      await tester.pumpAndSettle();
      expect(session.viewer.visibleRect.top, closeTo(top, .1));
      await _wheel(tester, const Offset(0, 100));
      await tester.pumpAndSettle();
      expect(session.viewer.visibleRect.top, closeTo(top + 100, .1));

      await _wheel(tester, const Offset(0, 100));
      await tester.pump(const Duration(milliseconds: 40));
      final stopped = session.viewer.visibleRect.top;
      await tester.tapAt(tester.getCenter(find.byType(PdfViewer)));
      await tester.pumpAndSettle();
      expect(session.viewer.visibleRect.top, closeTo(stopped, .1));

      await _wheel(tester, const Offset(0, 100));
      await tester.pump(const Duration(milliseconds: 40));
      await session.viewer.goToPage(pageNumber: 2, duration: Duration.zero);
      final destination = session.viewer.visibleRect;
      await tester.pumpAndSettle();
      expect(session.viewer.visibleRect, destination);

      await session.viewer.setZoom(
        const Offset(300, 800),
        2,
        duration: Duration.zero,
      );
      await tester.pumpAndSettle();
      final beforeHorizontal = session.viewer.visibleRect;
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await _wheel(tester, const Offset(0, 100));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      expect(
        (session.viewer.visibleRect.left - beforeHorizontal.left) * 2,
        closeTo(100, .1),
      );
      expect(session.viewer.visibleRect.top, closeTo(beforeHorizontal.top, .1));

      await _wheel(tester, const Offset(0, 100));
      await tester.pump(const Duration(milliseconds: 40));
      final zoomBefore = session.viewer.currentZoom;
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await _wheel(tester, const Offset(0, -100));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(session.viewer.currentZoom, greaterThan(zoomBefore));
      final zoomed = session.viewer.visibleRect;
      await tester.pumpAndSettle();
      expect(session.viewer.visibleRect, zoomed);

      // 关闭时仍有滚动动画，必须释放 ticker 和 PDF 句柄。
      await _wheel(tester, const Offset(0, 100));
      await tester.pump(const Duration(milliseconds: 30));
    } finally {
      await _unmount(tester, session.controller);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('滚轮阅读：系统减少动画时保留相同滚动距离', (tester) async {
    tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(
      tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue,
    );
    final session = await _mount(
      tester,
      'tools/fixtures/pdf/native.pdf',
      (_) {},
    );
    try {
      await session.viewer.setZoom(
        const Offset(300, 800),
        1,
        duration: Duration.zero,
      );
      await tester.pumpAndSettle();
      final before = session.viewer.visibleRect.top;
      await _wheel(tester, const Offset(0, 100));
      expect(session.viewer.visibleRect.top, closeTo(before + 100, .1));
      await tester.pump(const Duration(milliseconds: 400));
      expect(session.viewer.visibleRect.top, closeTo(before + 100, .1));
    } finally {
      await _unmount(tester, session.controller);
    }
  });

  testWidgets('选文阅读：触控板平移不选文，翻页更新优先级且只建立一次索引', (tester) async {
    final readingPages = <int>[];
    final indexingPages = <int>[];
    final session = await _mount(
      tester,
      'tools/fixtures/pdf/native.pdf',
      (_) {},
      onReadingPageChanged: readingPages.add,
      onIndexingRequested: indexingPages.add,
    );
    try {
      await _until(tester, () => indexingPages.isNotEmpty);
      expect(readingPages, [0]);
      await session.viewer.setZoom(
        const Offset(300, 600),
        1,
        duration: Duration.zero,
      );
      await tester.pumpAndSettle();
      final beforeWheel = session.viewer.visibleRect.top;
      await _wheel(tester, const Offset(0, 100));
      await tester.pumpAndSettle();
      expect(session.viewer.visibleRect.top - beforeWheel, closeTo(100, .1));
      final position = tester.getCenter(find.byType(PdfViewer));
      final trackpad = await tester.createGesture(
        kind: PointerDeviceKind.trackpad,
      );
      final beforePan = session.viewer.visibleRect.top;
      await trackpad.panZoomStart(position);
      await trackpad.panZoomUpdate(
        position,
        pan: const Offset(0, -50),
        timeStamp: const Duration(milliseconds: 30),
      );
      await tester.pump();
      await trackpad.panZoomUpdate(
        position,
        pan: const Offset(0, -150),
        timeStamp: const Duration(milliseconds: 100),
      );
      await tester.pump();
      expect(session.viewer.visibleRect.top, greaterThan(beforePan + 60));
      await trackpad.panZoomEnd(timeStamp: const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reader-selection-start')), findsNothing);
      expect(find.byKey(const Key('reader-selection-end')), findsNothing);
      final pinch = await tester.createGesture(
        kind: PointerDeviceKind.trackpad,
      );
      final zoomBefore = session.viewer.currentZoom;
      await pinch.panZoomStart(position);
      await pinch.panZoomUpdate(position, scale: 1.2);
      await tester.pump();
      await pinch.panZoomUpdate(position, scale: 1.5);
      await tester.pump();
      await pinch.panZoomEnd();
      expect(session.viewer.currentZoom, closeTo(zoomBefore * 1.5, .001));
      expect(find.byKey(const Key('reader-selection-start')), findsNothing);
      await session.viewer.goToPage(pageNumber: 2, duration: Duration.zero);
      await tester.pumpAndSettle();
      expect(readingPages.last, 1);
      final calls = readingPages.length;
      await tester.pump(const Duration(milliseconds: 500));
      expect(readingPages.length, calls);
      expect(indexingPages, [0]);
      await session.viewer.goToPage(pageNumber: 1, duration: Duration.zero);
      await tester.pumpAndSettle();
      expect(readingPages.last, 0);
    } finally {
      await _unmount(tester, session.controller);
    }
  });

  testWidgets('阅读优先级：继续阅读先恢复目标页，再触发索引', (tester) async {
    final pages = <int>[];
    final indexed = <int>[];
    final session = await _mount(
      tester,
      'tools/fixtures/pdf/native.pdf',
      (_) {},
      initialPosition: const model.ReadingPosition(
        revisionId: 'interaction',
        pageIndex: 1,
        offset: .1,
      ),
      onReadingPageChanged: pages.add,
      onIndexingRequested: indexed.add,
    );
    try {
      await _until(tester, () => indexed.isNotEmpty);
      expect(pages, [1]);
      expect(indexed, [1]);
    } finally {
      await _unmount(tester, session.controller);
    }
  });

  testWidgets('阅读交互：复制、右键、双击中英文、键盘扩选与端点拖动保留摘录坐标', (tester) async {
    final excerpts = <SelectedExcerpt>[];
    String? clipboard;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard = (call.arguments as Map)['text'] as String;
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
    final session = await _mount(
      tester,
      'tools/fixtures/pdf/native.pdf',
      excerpts.add,
    );
    final layer = session.layers[0]!;
    final first = layer.text.indexOf('OpenNote');
    Offset character(int index) {
      final fragment = layer.fragments.firstWhere(
        (f) => f.start <= index && f.start + f.length > index,
      );
      final bounds = PdfCoordinateAdapter(session.geometry[0])
          .quadInDocument(
            fragment.quad,
            session.viewer.pages[0],
            session.viewer.layout.pageLayouts[0],
          )
          .getBounds();
      return tester.getTopLeft(find.byType(PdfViewer)) +
          session.viewer.documentToLocal(bounds.center);
    }

    Future<void> copy() async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
    }

    Future<void> doubleClick(int index) async {
      await tester.tapAt(character(index));
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tapAt(character(index));
      await tester.pump(const Duration(milliseconds: 350));
    }

    await doubleClick(first + 2);
    await copy();
    expect(clipboard, 'OpenNote');
    final readingRect = tester.getRect(find.byType(PdfViewer));
    expect(find.text('已复制'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1900));
    expect(find.text('已复制'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('已复制'), findsNothing);
    expect(tester.getRect(find.byType(PdfViewer)), readingRect);
    expect(find.byKey(const Key('reader-selection-start')), findsOneWidget);
    expect(find.byKey(const Key('reader-selection-end')), findsOneWidget);
    await tester.tapAt(character(first + 2), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('复制选中文字').last);
    await tester.pumpAndSettle();
    expect(clipboard, 'OpenNote');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    await copy();
    expect(clipboard, 'OpenNot');
    final handle = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('reader-selection-end'))),
      kind: PointerDeviceKind.mouse,
    );
    await handle.moveTo(character(first + 3));
    await tester.pump();
    await handle.up();
    await tester.pump();
    await copy();
    expect(clipboard, 'Open');
    await tester.tap(find.byTooltip('摘录到顶层'));
    await _until(tester, () => excerpts.isNotEmpty);
    expect(excerpts.single.text, 'Open');
    expect(excerpts.single.anchors.single.pageIndex, 0);
    expect(excerpts.single.anchors.single.textStart, first);
    expect(excerpts.single.anchors.single.textEnd, first + 4);

    final chinese = layer.text.indexOf('原生');
    expect(chinese, isNonNegative);
    await doubleClick(chinese);
    await copy();
    expect(clipboard, isNotEmpty);
    expect('原生文字选择与来源定位', contains(clipboard!));
    expect(clipboard, isNot('Open'));
    final blank =
        tester.getTopLeft(find.byType(PdfViewer)) + const Offset(20, 200);
    await tester.tapAt(blank);
    await tester.pump();
    expect(find.byKey(const Key('reader-selection-start')), findsNothing);
    expect(find.byKey(const Key('reader-selection-end')), findsNothing);
    clipboard = '未复制';
    await copy();
    expect(clipboard, '未复制');
    // 双击页边空白也不应选中距离最近的词。
    await tester.tapAt(blank);
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byKey(const Key('reader-selection-start')), findsNothing);
    // 两次点击之间发生滚动，不应被当作在同一位置双击选词。
    await tester.tapAt(character(first + 2));
    await _wheel(tester, const Offset(0, 25));
    await tester.pumpAndSettle();
    await tester.tapAt(character(first + 2));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byKey(const Key('reader-selection-start')), findsNothing);
    await doubleClick(first + 2);
    await copy();
    expect(clipboard, 'OpenNote');
    expect(tester.takeException(), isNull);
    await _unmount(tester, session.controller);
  });

  testWidgets('阅读选区：外部点击立即取消且不吞点击，工具栏、侧栏、空白与 Esc 同步清除', (tester) async {
    // 外部按钮位于右侧，测试视图边界须与 900×750 的布局一致。
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 750);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    var outsideClicks = 0;
    final session = await _mount(
      tester,
      'tools/fixtures/pdf/native.pdf',
      (_) {},
      outside: TextButton(
        onPressed: () => outsideClicks++,
        child: const Text('脑图操作'),
      ),
    );
    try {
      Future<void> select() => _selectHeading(
        tester,
        session.viewer,
        session.layers[0]!,
        session.geometry[0],
      );
      void expectCleared() {
        expect(find.byKey(const Key('reader-selection-start')), findsNothing);
        expect(find.byKey(const Key('reader-selection-end')), findsNothing);
        expect(find.textContaining('已选择'), findsNothing);
        expect(
          tester
              .widget<IconButton>(
                find.byWidgetPredicate(
                  (widget) => widget is IconButton && widget.tooltip == '摘录到顶层',
                ),
              )
              .onPressed,
          isNull,
        );
      }

      await select();
      await tester.tap(find.text('脑图操作'));
      await tester.pump();
      expectCleared();
      expect(outsideClicks, 1, reason: '清除选区不能吞掉同一次点击');

      await select();
      await tester.tap(find.byTooltip('目录与缩略图'));
      await tester.pumpAndSettle();
      expectCleared();
      expect(find.byKey(const Key('reader-sidebar')), findsOneWidget);

      await select();
      await tester.tap(find.text('缩略图'));
      await tester.pumpAndSettle();
      expectCleared();
      await tester.tap(find.byTooltip('目录与缩略图'));
      await tester.pumpAndSettle();

      await select();
      final layer = session.layers[0]!;
      await tester.tapAt(
        _characterPosition(
          tester,
          session.viewer,
          layer,
          session.geometry[0],
          layer.text.indexOf('OpenNote') + 2,
        ),
      );
      await tester.pump();
      expectCleared();

      await select();
      await tester.tapAt(
        tester.getTopLeft(find.byType(PdfViewer)) + const Offset(20, 200),
      );
      await tester.pump();
      expectCleared();

      await select();
      await _revealScrollThumb(tester);
      await tester.tap(find.byKey(const Key('reader-document-scroll-thumb')));
      await tester.pump();
      expectCleared();

      await select();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expectCleared();
      expect(tester.takeException(), isNull);
    } finally {
      await _unmount(tester, session.controller);
    }
  });

  testWidgets('阅读选区：滚轮、触控板、复制菜单、批注和摘录保留可用选区', (tester) async {
    final excerpts = <SelectedExcerpt>[];
    final annotations = <ReaderAnnotationDraft>[];
    String? clipboard;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard = (call.arguments as Map)['text'] as String;
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
    final session = await _mount(
      tester,
      'tools/fixtures/pdf/native.pdf',
      excerpts.add,
      onAnnotationCreated: annotations.add,
    );
    try {
      await _selectHeading(
        tester,
        session.viewer,
        session.layers[0]!,
        session.geometry[0],
      );
      void expectSelected() {
        expect(find.byKey(const Key('reader-selection-start')), findsOneWidget);
        expect(find.byKey(const Key('reader-selection-end')), findsOneWidget);
      }

      await _wheel(tester, const Offset(0, 25));
      await tester.pumpAndSettle();
      expectSelected();
      final trackpad = await tester.createGesture(
        kind: PointerDeviceKind.trackpad,
      );
      final position = tester.getCenter(find.byType(PdfViewer));
      await trackpad.panZoomStart(position);
      await trackpad.panZoomUpdate(position, pan: const Offset(0, -10));
      await trackpad.panZoomEnd();
      await tester.pumpAndSettle();
      expectSelected();

      await tester.tap(find.byTooltip('更多阅读工具'));
      await tester.pumpAndSettle();
      expectSelected();
      await tester.tap(find.text('复制选中文字  Ctrl+C'));
      await tester.pumpAndSettle();
      expect(clipboard, 'OpenNote');
      expectSelected();

      await tester.tap(find.byTooltip('添加独立高亮批注'));
      await tester.pump();
      expect(annotations.single.kind, 'highlight');
      expectSelected();
      await tester.tap(find.byTooltip('添加文字批注'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        '选区批注',
      );
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();
      expect(annotations.last.text, '选区批注');
      expectSelected();

      await tester.tap(find.byTooltip('摘录到顶层'));
      await _until(tester, () => excerpts.isNotEmpty);
      expect(excerpts.single.text, 'OpenNote');
      expectSelected();

      // 关闭选区菜单属于点击别处，不能留下蓝色选区。
      await tester.tap(find.byTooltip('更多阅读工具'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reader-selection-start')), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await _unmount(tester, session.controller);
    }
  });

  testWidgets('阅读排版：滚动条闲置淡出，右侧唤出且悬停拖动保持可见', (tester) async {
    final session = await _mount(
      tester,
      'tools/fixtures/pdf/native.pdf',
      (_) {},
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    final opacity = find.byKey(const Key('reader-scrollbar-opacity'));
    double visible() => tester.widget<AnimatedOpacity>(opacity).opacity;
    try {
      await tester.pump(const Duration(milliseconds: 1800));
      expect(visible(), 0);
      await session.viewer.goToPosition(
        documentOffset: Offset(
          session.viewer.visibleRect.left,
          session.viewer.visibleRect.top + 100,
        ),
        duration: Duration.zero,
      );
      await tester.pump();
      expect(visible(), 1);
      await tester.pump(const Duration(milliseconds: 1499));
      expect(visible(), 1);
      await tester.pump(const Duration(milliseconds: 201));
      expect(visible(), 0);
      final viewport = tester.getRect(find.byType(PdfViewer));
      await mouse.addPointer(location: viewport.center);
      await mouse.moveTo(Offset(viewport.right - 8, viewport.center.dy));
      await tester.pump(const Duration(milliseconds: 250));
      expect(visible(), 1);
      await tester.pump(const Duration(seconds: 2));
      expect(visible(), 1, reason: '悬停右侧时保持可见');
      final thumb = find.byKey(const Key('reader-document-scroll-thumb'));
      await mouse.moveTo(tester.getCenter(thumb));
      await mouse.down(tester.getCenter(thumb));
      await tester.pump(const Duration(seconds: 2));
      expect(visible(), 1);
      final top = session.viewer.visibleRect.top;
      await mouse.moveBy(const Offset(0, 100));
      await tester.pump();
      await mouse.moveBy(const Offset(0, 30));
      await tester.pump();
      expect(session.viewer.visibleRect.top, greaterThan(top));
      await mouse.up();
      await mouse.moveTo(viewport.center);
      await tester.pump(const Duration(milliseconds: 1800));
      expect(visible(), 0);
      await session.viewer.goToPage(pageNumber: 1, duration: Duration.zero);
      await tester.tap(find.byTooltip('移动'));
      await tester.pump();
      final edge = Offset(viewport.right - 8, viewport.center.dy);
      await mouse.moveTo(edge);
      await mouse.down(edge);
      final beforePan = session.viewer.visibleRect.top;
      await mouse.moveBy(const Offset(0, -60));
      await tester.pump();
      await mouse.moveBy(const Offset(0, -40));
      await tester.pump();
      await mouse.up();
      expect(
        session.viewer.visibleRect.top,
        greaterThan(beforePan),
        reason: '右侧透明唤出区域仍允许正文平移',
      );
      expect(tester.takeException(), isNull);
    } finally {
      await mouse.removePointer();
      await _unmount(tester, session.controller);
    }
  });

  testWidgets('阅读排版：目录分隔线无图案，悬停和拖动反馈保留尺寸保存', (tester) async {
    final updates = <model.PdfReadingSettings>[];
    final session = await _mount(
      tester,
      'tools/fixtures/pdf/native.pdf',
      (_) {},
      initialPdfSettings: const model.PdfReadingSettings(sidebarVisible: true),
      onPdfSettingsChanged: updates.add,
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    final divider = find.byKey(const Key('reader-sidebar-divider'));
    final line = find.byKey(const Key('reader-sidebar-divider-line'));
    Color? color() =>
        (tester.widget<AnimatedContainer>(line).decoration! as BoxDecoration)
            .color;
    try {
      expect(tester.getSize(divider).width, 6);
      expect(
        find.descendant(of: divider, matching: find.byType(Icon)),
        findsNothing,
      );
      expect(color(), OpenNoteTokens.border);
      await mouse.addPointer(
        location: tester.getCenter(find.byType(PdfViewer)),
      );
      await mouse.moveTo(tester.getCenter(divider));
      await tester.pump();
      expect(color(), OpenNoteTokens.secondary.withValues(alpha: .55));
      final width = tester
          .getSize(find.byKey(const Key('reader-sidebar')))
          .width;
      await mouse.down(tester.getCenter(divider));
      await mouse.moveBy(const Offset(40, 0));
      await tester.pump();
      expect(color(), OpenNoteTokens.accent);
      await mouse.moveBy(const Offset(20, 0));
      await tester.pump();
      await mouse.up();
      await mouse.moveTo(tester.getCenter(find.byType(PdfViewer)));
      await tester.pump();
      expect(color(), OpenNoteTokens.border);
      expect(
        tester.getSize(find.byKey(const Key('reader-sidebar'))).width,
        greaterThan(width),
      );
      expect(updates, hasLength(1));
      expect(
        updates.single.sidebarWidth,
        tester.getSize(find.byKey(const Key('reader-sidebar'))).width,
      );
      expect(tester.takeException(), isNull);
    } finally {
      await mouse.removePointer();
      await _unmount(tester, session.controller);
    }
  });

  testWidgets('PDF 目录记忆：恢复宽度，拖动结束保存，临时窄栏不覆盖偏好', (tester) async {
    final updates = <model.PdfReadingSettings>[];
    final session = await _mount(
      tester,
      'tools/fixtures/pdf/native.pdf',
      (_) {},
      initialPdfSettings: const model.PdfReadingSettings(
        sidebarVisible: true,
        sidebarWidth: 320,
      ),
      onPdfSettingsChanged: updates.add,
    );
    try {
      final sidebar = find.byKey(const Key('reader-sidebar'));
      expect(tester.getSize(sidebar).width, 320);
      expect(updates, isEmpty, reason: '初始化恢复不重复写库');
      await tester.drag(
        find.byKey(const Key('reader-sidebar-divider')),
        const Offset(-40, 0),
      );
      await tester.pumpAndSettle();
      final width = tester.getSize(sidebar).width;
      expect(width, lessThan(320));
      expect(updates, hasLength(1));
      expect(updates.last.sidebarWidth, width);
      expect(updates.last.sidebarVisible, isTrue);
      await tester.binding.setSurfaceSize(const Size(720, 750));
      await tester.pumpAndSettle();
      expect(tester.getSize(sidebar).width, 234);
      expect(updates, hasLength(1));
      await tester.binding.setSurfaceSize(const Size(900, 750));
      await tester.pumpAndSettle();
      expect(tester.getSize(sidebar).width, width);
      await tester.tap(find.byTooltip('目录与缩略图'));
      await tester.pumpAndSettle();
      expect(sidebar, findsNothing);
      expect(updates.last.sidebarVisible, isFalse);
      expect(updates.last.sidebarWidth, width);
      await tester.tap(find.byTooltip('目录与缩略图'));
      await tester.pumpAndSettle();
      expect(tester.getSize(sidebar).width, width);
      expect(updates.last.sidebarVisible, isTrue);
      await tester.binding.setSurfaceSize(const Size(640, 750));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reader-sidebar-scrim')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(updates.last.sidebarVisible, isFalse);
      expect(updates.last.sidebarWidth, width);
    } finally {
      await _unmount(tester, session.controller);
    }
  });

  for (final manual in [false, true]) {
    testWidgets('目录跳转：Fit 书签保持${manual ? '手动比例' : '宽度适配'}且即时定位', (
      tester,
    ) async {
      final directory = Directory.systemTemp.createTempSync(
        'opennote-outline-navigation-',
      );
      final file = File('${directory.path}/outline.pdf')
        ..writeAsBytesSync(_outlinePdf());
      final session = await _mount(
        tester,
        file.path,
        (_) {},
        initialPdfSettings: const model.PdfReadingSettings(
          sidebarVisible: true,
        ),
      );
      final observedZooms = <double>[];
      void recordZoom() => observedZooms.add(session.viewer.currentZoom);
      try {
        await tester.tap(find.byTooltip('适合页面宽度'));
        await tester.pumpAndSettle();
        if (manual) {
          await tester.tap(find.byTooltip('放大'));
          await tester.pumpAndSettle();
        }
        final zoom = session.viewer.currentZoom;
        final sidebarWidth = tester
            .getSize(find.byKey(const Key('reader-sidebar')))
            .width;
        session.viewer.addListener(recordZoom);
        await tester.tap(find.text('Child chapter'));
        await tester.pumpAndSettle();
        expect(session.viewer.pageNumber, 2);
        expect(session.viewer.currentZoom, closeTo(zoom, .000001));
        expect(observedZooms, isNotEmpty);
        expect(
          observedZooms.every((value) => (value - zoom).abs() < .000001),
          isTrue,
          reason: '目录跳转不能先缩小再恢复',
        );
        expect(
          tester.getSize(find.byKey(const Key('reader-sidebar'))).width,
          sidebarWidth,
        );
        final page = session.viewer.layout.pageLayouts[1];
        expect(
          session.viewer.documentToLocal(page.topCenter).dy,
          closeTo(16, .01),
        );
        expect(tester.takeException(), isNull);
      } finally {
        session.viewer.removeListener(recordZoom);
        await _unmount(tester, session.controller);
        await tester.runAsync(() => directory.delete(recursive: true));
      }
    });
  }

  for (final destination in [
    (name: '未知指令', value: '[4 0 R /Unrecognized]', x: null, y: 0.0),
    (
      name: '非有限坐标',
      value: '[4 0 R /XYZ ${List.filled(400, '9').join()} 600 7]',
      x: null,
      y: 200.0,
    ),
    (name: 'XYZ 指定缩放', value: '[4 0 R /XYZ 120 600 7]', x: 120.0, y: 200.0),
    (name: 'XYZ 空坐标', value: '[4 0 R /XYZ null null 7]', x: null, y: 0.0),
    (name: 'XYZ 空横坐标', value: '[4 0 R /XYZ null 600 7]', x: null, y: 200.0),
    (name: 'XYZ 越界坐标', value: '[4 0 R /XYZ -500 900 7]', x: 0.0, y: 0.0),
    (name: 'XYZ 参数不足', value: '[4 0 R /XYZ 120]', x: null, y: 0.0),
    (name: 'FitB', value: '[4 0 R /FitB]', x: null, y: 0.0),
    (name: 'FitH', value: '[4 0 R /FitH 600]', x: null, y: 200.0),
    (name: 'FitBH', value: '[4 0 R /FitBH 600]', x: null, y: 200.0),
    (name: 'FitH 空坐标', value: '[4 0 R /FitH null]', x: null, y: 0.0),
    (name: 'FitV', value: '[4 0 R /FitV 220]', x: 220.0, y: 0.0),
    (name: 'FitBV', value: '[4 0 R /FitBV 220]', x: 220.0, y: 0.0),
    (name: 'FitR', value: '[4 0 R /FitR 400 200 520 600]', x: 400.0, y: 200.0),
    (name: 'FitR 参数不足', value: '[4 0 R /FitR 400 200]', x: null, y: 0.0),
    (name: '命名目标', value: '(named-chapter)', x: null, y: 200.0),
  ]) {
    testWidgets('目录跳转：${destination.name}保留位置并忽略书签缩放', (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'opennote-outline-dest-',
      );
      final file = File('${directory.path}/outline.pdf')
        ..writeAsBytesSync(_outlinePdf(childDestination: destination.value));
      final positions = <model.ReadingPosition>[];
      final session = await _mount(
        tester,
        file.path,
        (_) {},
        onReadingPositionChanged: positions.add,
        initialPdfSettings: const model.PdfReadingSettings(
          sidebarVisible: true,
        ),
      );
      try {
        await tester.tap(find.byTooltip('放大'));
        await tester.pumpAndSettle();
        final zoom = session.viewer.currentZoom;
        await tester.tap(find.text('Child chapter'));
        await tester.pumpAndSettle();
        expect(session.viewer.pageNumber, 2);
        expect(session.viewer.currentZoom, closeTo(zoom, .000001));
        final page = session.viewer.layout.pageLayouts[1];
        final target = Offset(
          page.left + (destination.x ?? 300),
          page.top + destination.y,
        );
        expect(session.viewer.documentToLocal(target).dy, closeTo(16, .01));
        if (destination.x != null) {
          expect(
            session.viewer.documentToLocal(target).dx,
            inInclusiveRange(15.99, session.viewer.viewSize.width - 15.99),
          );
        }
        await tester.pump(const Duration(milliseconds: 400));
        expect(positions.last.pageIndex, 1);
        expect(
          positions.last.offset,
          closeTo((destination.y - 16 / zoom).clamp(0, 800) / 800, .00001),
        );
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('reader-page-input')))
              .controller!
              .text,
          '2',
        );
        expect(tester.takeException(), isNull);
      } finally {
        await _unmount(tester, session.controller);
        await tester.runAsync(() => directory.delete(recursive: true));
      }
    });
  }

  for (final mode in ['width', 'page', 'manual']) {
    testWidgets('目录跳转：$mode 模式跨不同页尺寸并保留后续适配', (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'opennote-outline-size-',
      );
      final file = File('${directory.path}/outline.pdf')
        ..writeAsBytesSync(
          _outlinePdf(secondPageGeometry: '/MediaBox [0 0 900 1100]'),
        );
      final session = await _mount(
        tester,
        file.path,
        (_) {},
        initialPdfSettings: const model.PdfReadingSettings(
          sidebarVisible: true,
        ),
      );
      try {
        if (mode == 'page') {
          await tester.tap(find.byTooltip('更多阅读工具'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('适合整页'));
        } else {
          await tester.tap(find.byTooltip('适合页面宽度'));
          if (mode == 'manual') await tester.tap(find.byTooltip('放大'));
        }
        await tester.pumpAndSettle();
        final before = session.viewer.currentZoom;
        await tester.tap(find.text('Child chapter'));
        await tester.pumpAndSettle();
        final targetZoom = session.viewer.currentZoom;
        final page = session.viewer.layout.pageLayouts[1];
        void expectMode() {
          if (mode == 'manual') {
            expect(session.viewer.currentZoom, closeTo(before, .000001));
          } else if (mode == 'width') {
            expect(
              session.viewer.currentZoom,
              closeTo(
                (session.viewer.viewSize.width - 16) / page.width,
                .000001,
              ),
            );
            expect(
              session.viewer.documentToLocal(page.center).dx,
              closeTo(session.viewer.viewSize.width / 2, .01),
            );
          } else {
            expect(
              session.viewer.visibleRect.width,
              greaterThanOrEqualTo(page.width),
            );
            expect(
              session.viewer.visibleRect.height,
              greaterThanOrEqualTo(page.height),
            );
          }
        }

        expect(session.viewer.pageNumber, 2);
        expectMode();
        await tester.drag(
          find.byKey(const Key('reader-sidebar-divider')),
          const Offset(80, 0),
        );
        await tester.pumpAndSettle();
        expectMode();
        await tester.tap(find.byTooltip('目录与缩略图'));
        await tester.pumpAndSettle();
        expectMode();
        await tester.tap(find.byTooltip('目录与缩略图'));
        await tester.pumpAndSettle();
        expectMode();
        await tester.binding.setSurfaceSize(const Size(800, 600));
        await tester.pumpAndSettle();
        expectMode();
        if (mode == 'manual') expect(targetZoom, before);
        expect(tester.takeException(), isNull);
      } finally {
        await _unmount(tester, session.controller);
        await tester.runAsync(() => directory.delete(recursive: true));
      }
    });
  }

  for (final rotation in [0, 90, 180, 270]) {
    testWidgets('目录跳转：裁剪偏移与 $rotation 度旋转的标题位置', (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'opennote-outline-crop-',
      );
      final file = File('${directory.path}/outline.pdf')
        ..writeAsBytesSync(
          _outlinePdf(
            childDestination: '[4 0 R /XYZ 200 650 7]',
            secondPageGeometry:
                '/MediaBox [0 0 700 900] /CropBox [50 100 650 850] /Rotate $rotation',
            trailingPage: true,
          ),
        );
      final session = await _mount(
        tester,
        file.path,
        (_) {},
        initialPdfSettings: const model.PdfReadingSettings(
          sidebarVisible: true,
        ),
      );
      try {
        await tester.tap(find.byTooltip('放大'));
        await tester.pumpAndSettle();
        final zoom = session.viewer.currentZoom;
        await tester.tap(find.text('Child chapter'));
        await tester.pumpAndSettle();
        // 原始点扣除页框偏移后是 (150, 550)，按四种旋转得到显示坐标。
        final offset = switch (rotation) {
          0 => const Offset(150, 200),
          90 => const Offset(550, 150),
          180 => const Offset(450, 550),
          _ => const Offset(200, 450),
        };
        final page = session.viewer.layout.pageLayouts[1];
        final point = session.viewer.documentToLocal(page.topLeft + offset);
        expect(session.viewer.pageNumber, 2);
        expect(session.viewer.currentZoom, closeTo(zoom, .000001));
        expect(point.dy, closeTo(16, .01));
        expect(
          point.dx,
          inInclusiveRange(15.99, session.viewer.viewSize.width - 15.99),
        );
        expect(tester.takeException(), isNull);
      } finally {
        await _unmount(tester, session.controller);
        await tester.runAsync(() => directory.delete(recursive: true));
      }
    });
  }

  testWidgets('目录跳转：无目标与越界目标保留视口并反馈', (tester) async {
    for (final destination in ['none', '[40 0 R /Fit]']) {
      final directory = Directory.systemTemp.createTempSync(
        'opennote-outline-invalid-',
      );
      final file = File('${directory.path}/outline.pdf')
        ..writeAsBytesSync(_outlinePdf(childDestination: destination));
      final session = await _mount(
        tester,
        file.path,
        (_) {},
        initialPdfSettings: const model.PdfReadingSettings(
          sidebarVisible: true,
        ),
      );
      try {
        final before = session.viewer.value.clone();
        await tester.tap(find.text('Child chapter'));
        await tester.pumpAndSettle();
        expect(session.viewer.value.storage, before.storage);
        expect(find.text('此章节没有有效的跳转目标'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await _unmount(tester, session.controller);
        await tester.runAsync(() => directory.delete(recursive: true));
      }
    }
  });

  testWidgets('目录跳转：抽屉关闭后最新请求生效，卸载阻止过期跳转', (tester) async {
    final directory = Directory.systemTemp.createTempSync(
      'opennote-outline-drawer-',
    );
    final file = File('${directory.path}/outline.pdf')
      ..writeAsBytesSync(_outlinePdf());
    final session = await _mount(tester, file.path, (_) {});
    try {
      await tester.binding.setSurfaceSize(const Size(640, 750));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('目录与缩略图'));
      await tester.pumpAndSettle();
      final callbacks = tester
          .widgetList<ListTile>(find.byType(ListTile))
          .where((tile) => tile.onTap != null)
          .map((tile) => tile.onTap!)
          .toList();
      callbacks.first();
      callbacks.last();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reader-sidebar')), findsNothing);
      expect(session.viewer.pageNumber, 2);
      final page = session.viewer.layout.pageLayouts[1];
      expect(
        session.viewer.currentZoom,
        closeTo((session.viewer.viewSize.width - 16) / page.width, .000001),
      );
      await tester.tap(find.byTooltip('目录与缩略图'));
      await tester.pumpAndSettle();
      tester.widgetList<ListTile>(find.byType(ListTile)).first.onTap!();
      await _unmount(tester, session.controller);
      expect(tester.takeException(), isNull);
    } finally {
      await _unmount(tester, session.controller);
      await tester.runAsync(() => directory.delete(recursive: true));
    }
  });

  testWidgets('目录适配：初次打开未手动缩放时，展开目录默认继续宽度适配', (tester) async {
    final session = await _mount(
      tester,
      'tools/fixtures/pdf/native.pdf',
      (_) {},
    );
    try {
      final before = session.viewer.currentZoom;
      await tester.tap(find.byTooltip('目录与缩略图'));
      await tester.pumpAndSettle();
      final page = session.viewer.layout.pageLayouts[0];
      expect(session.viewer.currentZoom, lessThan(before));
      expect(
        session.viewer.documentToLocal(page.topLeft).dx,
        greaterThanOrEqualTo(-.01),
      );
      expect(
        session.viewer.documentToLocal(page.topRight).dx,
        lessThanOrEqualTo(session.viewer.viewSize.width + .01),
      );
      expect(
        session.viewer.documentToLocal(page.center).dx,
        closeTo(session.viewer.viewSize.width / 2, .01),
      );
      expect(session.viewer.pageNumber, 1);
      expect(tester.takeException(), isNull);
    } finally {
      await _unmount(tester, session.controller);
    }
  });

  testWidgets('目录适配：适合宽度持续居中，开关拖宽和窗口变化保留纵向位置', (tester) async {
    final session = await _mount(
      tester,
      'tools/fixtures/pdf/native.pdf',
      (_) {},
    );
    try {
      await tester.tap(find.byTooltip('适合页面宽度'));
      await tester.pumpAndSettle();
      final page = session.viewer.layout.pageLayouts[0];
      await session.viewer.goToPosition(
        documentOffset: Offset(
          session.viewer.visibleRect.left,
          page.top + page.height * .25,
        ),
        duration: Duration.zero,
      );
      await tester.pumpAndSettle();
      final top = session.viewer.visibleRect.top;
      final zoom = session.viewer.currentZoom;
      void expectReadingPosition() {
        final viewer = session.viewer;
        final left = viewer.documentToLocal(page.topLeft).dx;
        final right = viewer.documentToLocal(page.topRight).dx;
        expect(left, greaterThanOrEqualTo(-.01), reason: '页面左侧应在可见范围内');
        expect(
          right,
          lessThanOrEqualTo(viewer.viewSize.width + .01),
          reason: '正文右侧不得被目录裁掉',
        );
        expect((left + right) / 2, closeTo(viewer.viewSize.width / 2, .01));
        expect(viewer.visibleRect.top, closeTo(top, .01), reason: '保留正在读的纵向位置');
        expect(viewer.pageNumber, 1);
      }

      await tester.tap(find.byTooltip('目录与缩略图'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reader-sidebar-scrim')), findsNothing);
      expect(session.viewer.currentZoom, lessThan(zoom));
      expectReadingPosition();
      final withSidebarZoom = session.viewer.currentZoom;
      await tester.drag(
        find.byKey(const Key('reader-sidebar-divider')),
        const Offset(80, 0),
      );
      await tester.pumpAndSettle();
      expect(session.viewer.currentZoom, lessThan(withSidebarZoom));
      expectReadingPosition();
      await tester.tap(find.byTooltip('目录与缩略图'));
      await tester.pumpAndSettle();
      expect(session.viewer.currentZoom, closeTo(zoom, .000001));
      expectReadingPosition();
      await tester.binding.setSurfaceSize(const Size(820, 750));
      await tester.pumpAndSettle();
      expectReadingPosition();
      expect(tester.takeException(), isNull);
    } finally {
      await _unmount(tester, session.controller);
    }
  });

  testWidgets('目录适配：适合整页持续生效，不被后续目录和窗口变化改成适合宽度', (tester) async {
    final session = await _mount(
      tester,
      'tools/fixtures/pdf/native.pdf',
      (_) {},
    );
    try {
      await tester.tap(find.byTooltip('更多阅读工具'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('适合整页'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('目录与缩略图'));
      await tester.pumpAndSettle();
      final before = session.viewer.currentZoom;
      await tester.binding.setSurfaceSize(const Size(900, 400));
      await tester.pumpAndSettle();
      final page = session.viewer.layout.pageLayouts[0];
      expect(session.viewer.currentZoom, lessThan(before));
      expect(
        session.viewer.visibleRect.width,
        greaterThanOrEqualTo(page.width - .01),
      );
      expect(
        session.viewer.visibleRect.height,
        greaterThanOrEqualTo(page.height - .01),
      );
      expect(
        session.viewer.documentToLocal(page.center).dx,
        closeTo(session.viewer.viewSize.width / 2, .01),
      );
      expect(session.viewer.pageNumber, 1);
      expect(tester.takeException(), isNull);
    } finally {
      await _unmount(tester, session.controller);
    }
  });

  testWidgets('目录适配：手动放大保留缩放与阅读锚点，适合宽度按钮可重新启用自动适配', (tester) async {
    final session = await _mount(
      tester,
      'tools/fixtures/pdf/native.pdf',
      (_) {},
    );
    try {
      await tester.tap(find.byTooltip('放大'));
      await tester.pumpAndSettle();
      final page = session.viewer.layout.pageLayouts[0];
      final zoom = session.viewer.currentZoom;
      session.viewer.value = session.viewer.calcMatrixFor(
        Offset(
          page.center.dx + 40,
          page.top +
              page.height * .25 +
              session.viewer.viewSize.height / zoom / 2,
        ),
        zoom: zoom,
      );
      await tester.pumpAndSettle();
      final before = session.viewer.visibleRect;
      for (var index = 0; index < 2; index++) {
        await tester.tap(find.byTooltip('目录与缩略图'));
        await tester.pumpAndSettle();
        expect(session.viewer.currentZoom, closeTo(zoom, .000001));
        expect(
          session.viewer.visibleRect.center.dx,
          closeTo(before.center.dx, .01),
        );
        expect(session.viewer.visibleRect.top, closeTo(before.top, .01));
        expect(session.viewer.pageNumber, 1);
      }
      await tester.tap(find.byTooltip('适合页面宽度'));
      await tester.pumpAndSettle();
      final fitted = session.viewer.currentZoom;
      await tester.tap(find.byTooltip('目录与缩略图'));
      await tester.pumpAndSettle();
      expect(session.viewer.currentZoom, lessThan(fitted));
      expect(tester.takeException(), isNull);
    } finally {
      await _unmount(tester, session.controller);
    }
  });

  testWidgets('目录批量操作：递归处理隐藏分支，禁用状态跟随单章节操作且不跳页', (tester) async {
    final directory = Directory.systemTemp.createTempSync(
      'opennote-reader-outline-bulk-',
    );
    final file = File('${directory.path}/outline.pdf')
      ..writeAsBytesSync(_outlinePdf(extended: true));
    final boundary = GlobalKey();
    final session = await _mount(
      tester,
      file.path,
      (_) {},
      initialPdfSettings: const model.PdfReadingSettings(
        sidebarVisible: true,
        sidebarWidth: 320,
      ),
      theme: openNoteTheme(),
      boundaryKey: boundary,
    );
    final expand = find.byKey(const Key('reader-outline-expand-all'));
    final collapse = find.byKey(const Key('reader-outline-collapse-all'));
    final footer = find.byKey(const Key('reader-outline-actions'));
    void expectBottomActions() {
      final sidebar = tester.getRect(find.byKey(const Key('reader-sidebar')));
      expect(tester.getRect(footer).bottom, closeTo(sidebar.bottom, .01));
      expect(tester.getRect(expand).bottom, closeTo(sidebar.bottom - 8, .01));
      expect(tester.getRect(collapse).bottom, closeTo(sidebar.bottom - 8, .01));
      expect(tester.getRect(expand).left, closeTo(sidebar.left + 8, .01));
      expect(
        tester.getRect(collapse).left,
        closeTo(tester.getRect(expand).right + 4, .01),
      );
    }

    try {
      await tester.pumpAndSettle();
      expect(find.text('Grandchild chapter'), findsOneWidget);
      expect(find.text('Second child'), findsOneWidget);
      expect(find.text('Top-level leaf'), findsOneWidget);
      expect(tester.widget<IconButton>(expand).onPressed, isNull);
      expect(tester.widget<IconButton>(collapse).onPressed, isNotNull);
      expect(tester.getSize(expand), const Size(36, 36));
      expect(tester.getSize(collapse), const Size(36, 36));
      final switchRect = tester.getRect(find.byType(OpenNoteViewSwitch));
      expect(
        switchRect.width,
        closeTo(
          tester.getSize(find.byKey(const Key('reader-sidebar'))).width - 16,
          .01,
        ),
      );
      expectBottomActions();
      await _saveOutlinePreview(tester, boundary, 'expanded-320');
      final before = session.viewer.value.clone();
      final page = session.viewer.pageNumber;
      await tester.tap(collapse);
      await tester.pumpAndSettle();
      expect(find.text('Child chapter'), findsNothing);
      expect(find.text('Grandchild chapter'), findsNothing);
      expect(find.text('Second child'), findsNothing);
      expect(find.text('Second chapter'), findsOneWidget);
      expect(find.text('Top-level leaf'), findsOneWidget);
      expect(tester.widget<IconButton>(collapse).onPressed, isNull);
      expect(tester.widget<IconButton>(expand).onPressed, isNotNull);
      expect(session.viewer.value, before);
      expect(session.viewer.pageNumber, page);
      await _saveOutlinePreview(tester, boundary, 'collapsed-320');

      await tester.tap(find.byTooltip('展开章节').first);
      await tester.pumpAndSettle();
      expect(find.text('Child chapter'), findsOneWidget);
      expect(
        find.text('Grandchild chapter'),
        findsNothing,
        reason: '折叠全部也应折叠当时不可见的深层分支',
      );
      expect(tester.widget<IconButton>(expand).onPressed, isNotNull);
      expect(tester.widget<IconButton>(collapse).onPressed, isNotNull);
      await tester.tap(expand);
      await tester.pumpAndSettle();
      expect(find.text('Grandchild chapter'), findsOneWidget);
      expect(find.text('Second child'), findsOneWidget);
      expect(tester.widget<IconButton>(expand).onPressed, isNull);
      expect(tester.widget<IconButton>(collapse).onPressed, isNotNull);
      expect(session.viewer.value, before);
      expect(session.viewer.pageNumber, page);

      await tester.tap(find.byTooltip('折叠章节').at(1));
      await tester.pumpAndSettle();
      expect(find.text('Grandchild chapter'), findsNothing);
      expect(tester.widget<IconButton>(expand).onPressed, isNotNull);
      await tester.tap(find.byTooltip('展开章节').first);
      await tester.pumpAndSettle();
      expect(tester.widget<IconButton>(expand).onPressed, isNull);

      final headerBefore = tester.getRect(find.byType(OpenNoteViewSwitch));
      await tester.tap(find.text('缩略图'));
      await tester.pumpAndSettle();
      expect(expand, findsNothing);
      expect(collapse, findsNothing);
      expect(footer, findsNothing);
      expect(tester.getRect(find.byType(OpenNoteViewSwitch)), headerBefore);
      await _saveOutlinePreview(tester, boundary, 'thumbnails-320');
      await tester.tap(find.text('目录'));
      await tester.pumpAndSettle();
      expect(find.text('Grandchild chapter'), findsOneWidget);
      expect(tester.getRect(find.byType(OpenNoteViewSwitch)), headerBefore);
      expect(tester.widget<IconButton>(expand).onPressed, isNull);

      for (final width in [220.0, 120.0]) {
        final sidebar = find.byKey(const Key('reader-sidebar'));
        final resize = await tester.startGesture(
          tester.getCenter(find.byKey(const Key('reader-sidebar-divider'))),
          kind: PointerDeviceKind.mouse,
        );
        // 先越过拖动阈值，再按实际宽度调整，避免阈值吞掉测试位移。
        await resize.moveBy(const Offset(-24, 0));
        await tester.pump();
        await resize.moveBy(Offset(width - tester.getSize(sidebar).width, 0));
        await resize.up();
        await tester.pumpAndSettle();
        expect(tester.getSize(sidebar).width, closeTo(width, .01));
        expectBottomActions();
        expect(
          tester.getRect(collapse).right,
          lessThanOrEqualTo(tester.getRect(sidebar).right),
        );
        await _saveOutlinePreview(
          tester,
          boundary,
          'expanded-${width.toInt()}',
        );
        expect(tester.takeException(), isNull);
        if (width == 220) {
          tester.platformDispatcher.textScaleFactorTestValue = 1.5;
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          await tester.pumpAndSettle();
          expectBottomActions();
          expect(tester.takeException(), isNull);
          await _saveOutlinePreview(tester, boundary, 'expanded-220-text150');
          tester.platformDispatcher.clearTextScaleFactorTestValue();
          await tester.pumpAndSettle();
        }
      }
      await tester.binding.setSurfaceSize(const Size(900, 280));
      await tester.pumpAndSettle();
      final footerBeforeScroll = tester.getRect(footer);
      final outlineList = find.descendant(
        of: find.byKey(const Key('reader-sidebar')),
        matching: find.byType(ListView),
      );
      final scrollable = find.descendant(
        of: outlineList,
        matching: find.byType(Scrollable),
      );
      final scrollState = tester.state<ScrollableState>(scrollable);
      final offsetBeforeScroll = scrollState.position.pixels;
      await tester.drag(outlineList, const Offset(0, -160));
      await tester.pumpAndSettle();
      expect(scrollState.position.pixels, greaterThan(offsetBeforeScroll));
      expect(
        tester.getRect(footer),
        footerBeforeScroll,
        reason: '目录滚动时底部操作保持固定',
      );
      expectBottomActions();
      await tester.binding.setSurfaceSize(const Size(640, 750));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reader-sidebar-scrim')), findsOneWidget);
      expect(find.byTooltip('关闭目录'), findsOneWidget);
      expect(collapse.hitTestable(), findsOneWidget);
      expectBottomActions();
      await tester.tap(collapse);
      await tester.pumpAndSettle();
      expect(find.text('Child chapter'), findsNothing);
      expect(
        find.byKey(const Key('reader-sidebar')),
        findsOneWidget,
        reason: '批量目录操作应保留抽屉，不能触发章节跳转',
      );
      await _saveOutlinePreview(tester, boundary, 'drawer-220');
      await tester.tap(find.byTooltip('关闭目录'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reader-sidebar')), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await _unmount(tester, session.controller);
      await tester.runAsync(() => directory.delete(recursive: true));
    }
  });

  for (final flat in [false, true]) {
    testWidgets('目录批量操作：${flat ? '纯叶子目录' : '没有目录'}时隐藏图标', (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'opennote-reader-outline-empty-',
      );
      final file = File('${directory.path}/outline.pdf')
        ..writeAsBytesSync(_outlinePdf(flat: flat, noOutline: !flat));
      final session = await _mount(
        tester,
        file.path,
        (_) {},
        initialPdfSettings: const model.PdfReadingSettings(
          sidebarVisible: true,
        ),
        theme: openNoteTheme(),
      );
      try {
        await tester.pumpAndSettle();
        if (flat) {
          expect(find.byType(ListTile), findsOneWidget);
          expect(find.byTooltip('展开章节'), findsNothing);
          expect(find.byTooltip('折叠章节'), findsNothing);
        } else {
          expect(find.text('暂无目录'), findsOneWidget);
        }
        expect(
          find.byKey(const Key('reader-outline-expand-all')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('reader-outline-collapse-all')),
          findsNothing,
        );
        await tester.tap(find.text('缩略图'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('reader-outline-expand-all')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('reader-outline-collapse-all')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await _unmount(tester, session.controller);
        await tester.runAsync(() => directory.delete(recursive: true));
      }
    });
  }

  testWidgets('目录适配：窄栏目录使用抽屉，导航后收起并支持关闭按钮、遮罩和 Esc', (tester) async {
    final directory = Directory.systemTemp.createTempSync(
      'opennote-reader-drawer-',
    );
    final file = File('${directory.path}/outline.pdf')
      ..writeAsBytesSync(_outlinePdf());
    final session = await _mount(tester, file.path, (_) {});
    try {
      await tester.binding.setSurfaceSize(const Size(640, 750));
      await tester.pumpAndSettle();
      final size = session.viewer.viewSize;
      Future<void> open() async {
        await tester.tap(find.byTooltip('目录与缩略图'));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('reader-sidebar-scrim')), findsOneWidget);
        expect(session.viewer.viewSize, size, reason: '抽屉遮盖而不挤压 PDF 视口');
      }

      await open();
      await tester.tap(find.text('Child chapter'));
      await tester.pumpAndSettle();
      expect(session.viewer.pageNumber, 2);
      expect(find.byKey(const Key('reader-sidebar')), findsNothing);
      await open();
      await tester.tap(find.byTooltip('关闭目录'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reader-sidebar')), findsNothing);
      await open();
      final scrim = tester.getRect(
        find.byKey(const Key('reader-sidebar-scrim')),
      );
      await tester.tapAt(scrim.topRight + const Offset(-16, 40));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reader-sidebar')), findsNothing);
      await open();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reader-sidebar')), findsNothing);
      expect(session.viewer.viewSize, size);
      expect(tester.takeException(), isNull);
    } finally {
      await _unmount(tester, session.controller);
      await tester.runAsync(() => directory.delete(recursive: true));
    }
  });

  testWidgets('阅读交互：缩放按钮、整页适配、滚动条、分级目录和窄栏拖宽', (tester) async {
    final directory = Directory.systemTemp.createTempSync(
      'opennote-reader-controls-',
    );
    final file = File('${directory.path}/outline.pdf');
    file.writeAsBytesSync(_outlinePdf());
    final session = await _mount(
      tester,
      file.path,
      (_) {},
      documentActions: IconButton(
        tooltip: '测试文档识别',
        onPressed: () {},
        icon: const Icon(Icons.document_scanner_outlined),
      ),
    );
    try {
      final initialZoom = session.viewer.currentZoom;
      await tester.tap(find.byTooltip('放大'));
      await tester.pumpAndSettle();
      final enlargedZoom = session.viewer.currentZoom;
      expect(enlargedZoom, greaterThan(initialZoom));
      await tester.tap(find.byTooltip('缩小'));
      await tester.pumpAndSettle();
      expect(session.viewer.currentZoom, lessThan(enlargedZoom));
      final thumb = find.byKey(const Key('reader-document-scroll-thumb'));
      expect(thumb, findsOneWidget);
      await _revealScrollThumb(tester);
      final before = session.viewer.visibleRect.top;
      await tester.drag(thumb, const Offset(0, 200));
      await tester.pumpAndSettle();
      expect(session.viewer.visibleRect.top, greaterThan(before + 100));
      await tester.tap(find.byTooltip('更多阅读工具'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('适合整页'));
      await tester.pumpAndSettle();
      final pageRect =
          session.viewer.layout.pageLayouts[session.viewer.pageNumber! - 1];
      expect(
        session.viewer.visibleRect.height,
        greaterThanOrEqualTo(pageRect.height - 1),
      );
      expect(
        session.viewer.visibleRect.width,
        greaterThanOrEqualTo(pageRect.width - 1),
      );
      await tester.tap(find.byTooltip('目录与缩略图'));
      await tester.pumpAndSettle();
      expect(find.text('Child chapter'), findsOneWidget);
      await tester.tap(find.byTooltip('折叠章节'));
      await tester.pump();
      expect(find.text('Child chapter'), findsNothing);
      await tester.tap(find.byTooltip('展开章节'));
      await tester.pump();
      await tester.tap(find.text('Child chapter'));
      await tester.pumpAndSettle();
      expect(session.viewer.pageNumber, 2);
      final width = tester
          .getSize(find.byKey(const Key('reader-sidebar')))
          .width;
      await tester.drag(
        find.byKey(const Key('reader-sidebar-divider')),
        const Offset(90, 0),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byKey(const Key('reader-sidebar'))).width,
        greaterThan(width),
      );
      await tester.binding.setSurfaceSize(const Size(360, 720));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('reader-sidebar-scrim')), findsOneWidget);
      expect(session.viewer.viewSize.width, 360, reason: '窄栏目录改用抽屉，不挤压正文');
      expect(
        tester.getRect(find.byKey(const Key('reader-sidebar'))).right,
        lessThan(tester.getRect(find.byType(PdfViewer)).right),
      );
      for (final paneWidth in [
        720.0,
        719.0,
        520.0,
        519.0,
        360.0,
        359.0,
        240.0,
      ]) {
        if (paneWidth < 360 &&
            find.byKey(const Key('reader-sidebar')).evaluate().isNotEmpty) {
          await tester.tap(find.byTooltip('目录与缩略图'));
          await tester.pumpAndSettle();
        }
        await tester.binding.setSurfaceSize(Size(paneWidth, 720));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '$paneWidth 宽工具栏不应溢出');
        expect(
          tester.getSize(find.byKey(const Key('reader-toolbar'))).height,
          44,
        );
        final viewport = tester.getRect(find.byType(PdfViewer));
        final reader = tester.getRect(find.byType(ReaderPane));
        expect(
          viewport.bottom,
          closeTo(reader.bottom, .01),
          reason: '底部不保留工具栏占位',
        );
        expect(find.byKey(const Key('reader-page-input')), findsOneWidget);
        expect(find.byTooltip('测试文档识别').hitTestable(), findsOneWidget);
        expect(find.textContaining('%'), findsNothing);
        if (paneWidth >= 720) {
          expect(find.byTooltip('选文'), findsOneWidget);
          expect(find.byTooltip('切换阅读工具'), findsNothing);
        } else if (paneWidth >= 360) {
          await tester.tap(find.byTooltip('切换阅读工具'));
          await tester.pumpAndSettle();
          await tester.tap(
            find
                .ancestor(
                  of: find.text('矩形'),
                  matching: find.byWidgetPredicate(
                    (widget) => widget is CheckedPopupMenuItem,
                  ),
                )
                .hitTestable(),
          );
          await tester.pumpAndSettle();
        }
        await tester.tap(find.byTooltip('更多阅读工具'));
        await tester.pumpAndSettle();
        expect(find.text('适合整页'), findsOneWidget);
        if (paneWidth < 520) {
          expect(find.text('放大'), findsOneWidget);
          expect(find.text('下一页'), findsOneWidget);
        }
        if (paneWidth < 360) {
          await tester.tap(
            find
                .ancestor(
                  of: find.text('选文'),
                  matching: find.byWidgetPredicate(
                    (widget) => widget is CheckedPopupMenuItem,
                  ),
                )
                .hitTestable(),
          );
        } else {
          await tester.tap(find.text('适合整页'));
        }
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('更多阅读工具'));
        await tester.pumpAndSettle();
        expect(find.text('识别本页'), findsNothing);
        if (paneWidth < 720) {
          expect(find.text('添加文字批注'), findsOneWidget);
          expect(find.text('添加独立高亮批注'), findsOneWidget);
        }
        if (paneWidth < 360) {
          expect(find.text('摘录到顶层'), findsOneWidget);
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
      }
    } finally {
      await _unmount(tester, session.controller);
      await tester.runAsync(() => directory.delete(recursive: true));
    }
  });
}

Future<
  ({
    ReaderPaneController controller,
    PdfViewerController viewer,
    Map<int, model.TextLayerDraft> layers,
    List<model.PdfPageGeometry> geometry,
  })
>
_mount(
  WidgetTester tester,
  String path,
  void Function(SelectedExcerpt) onExcerpt, {
  void Function(int)? onReadingPageChanged,
  void Function(model.ReadingPosition)? onReadingPositionChanged,
  void Function(int)? onIndexingRequested,
  model.ReadingPosition? initialPosition,
  model.PdfReadingSettings initialPdfSettings =
      const model.PdfReadingSettings(),
  void Function(model.PdfReadingSettings)? onPdfSettingsChanged,
  Widget? outside,
  double outsideWidth = 140,
  bool waitForText = true,
  void Function(ReaderAnnotationDraft)? onAnnotationCreated,
  Widget? documentActions,
  bool enableTextDrag = false,
  List<model.PageTextLayer> textLayers = const [],
  ValueNotifier<Object>? dragContext,
  ThemeData? theme,
  GlobalKey? boundaryKey,
}) async {
  await tester.binding.setSurfaceSize(const Size(900, 750));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final controller = ReaderPaneController();
  final layers = <int, model.TextLayerDraft>{};
  var geometry = <model.PdfPageGeometry>[];
  Widget contents(Object? context) => Row(
    children: [
      Expanded(
        child: ReaderPane(
          revisionId: 'interaction',
          filePath: File(path).absolute.path,
          controller: controller,
          onExcerpt: onExcerpt,
          textLayers: textLayers,
          onAnnotationCreated: onAnnotationCreated,
          documentActions: documentActions,
          enableTextDrag: enableTextDrag,
          textDragContext: context,
          onReadingPageChanged: onReadingPageChanged,
          onReadingPositionChanged: onReadingPositionChanged,
          onIndexingRequested: onIndexingRequested,
          initialPosition: initialPosition,
          initialPdfSettings: initialPdfSettings,
          onPdfSettingsChanged: onPdfSettingsChanged,
          onGeometryLoaded: (value) => geometry = value,
          onNativeTextLayer: (value) async => layers[value.pageIndex] = value,
        ),
      ),
      if (outside != null) SizedBox(width: outsideWidth, child: outside),
    ],
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Scaffold(
        body: RepaintBoundary(
          key: boundaryKey,
          child: dragContext == null
              ? contents(null)
              : ValueListenableBuilder<Object>(
                  valueListenable: dragContext,
                  builder: (_, value, _) => contents(value),
                ),
        ),
      ),
    ),
  );
  await _until(
    tester,
    () => geometry.isNotEmpty && (!waitForText || layers.containsKey(0)),
  );
  final viewer = tester.widget<PdfViewer>(find.byType(PdfViewer)).controller!;
  return (
    controller: controller,
    viewer: viewer,
    layers: layers,
    geometry: geometry,
  );
}

Future<void> _revealScrollThumb(WidgetTester tester) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  final viewport = tester.getRect(find.byType(PdfViewer));
  await mouse.addPointer(location: viewport.center);
  await mouse.moveTo(Offset(viewport.right - 8, viewport.center.dy));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
  await mouse.removePointer();
  await tester.pump();
}

Offset _characterPosition(
  WidgetTester tester,
  PdfViewerController viewer,
  model.TextLayerDraft layer,
  model.PdfPageGeometry geometry,
  int index,
) {
  final fragment = layer.fragments.firstWhere(
    (f) => f.start <= index && f.start + f.length > index,
  );
  final bounds = PdfCoordinateAdapter(geometry)
      .quadInDocument(
        fragment.quad,
        viewer.pages[0],
        viewer.layout.pageLayouts[0],
      )
      .getBounds();
  return tester.getTopLeft(find.byType(PdfViewer)) +
      viewer.documentToLocal(bounds.center);
}

Future<void> _selectHeading(
  WidgetTester tester,
  PdfViewerController viewer,
  model.TextLayerDraft layer,
  model.PdfPageGeometry geometry,
) async {
  await viewer.goToPage(pageNumber: 1, duration: Duration.zero);
  await tester.pumpAndSettle();
  final point = _characterPosition(
    tester,
    viewer,
    layer,
    geometry,
    layer.text.indexOf('OpenNote') + 2,
  );
  await tester.tapAt(point);
  await tester.pump(const Duration(milliseconds: 60));
  await tester.tapAt(point);
  await tester.pump(const Duration(milliseconds: 350));
  expect(find.byKey(const Key('reader-selection-start')), findsOneWidget);
  expect(find.byKey(const Key('reader-selection-end')), findsOneWidget);
}

Future<void> _wheel(WidgetTester tester, Offset delta) async {
  await tester.sendEventToBinding(
    PointerScrollEvent(
      position: tester.getCenter(find.byType(PdfViewer)),
      scrollDelta: delta,
      kind: PointerDeviceKind.mouse,
    ),
  );
  // 建立动画时间起点，不等待过渡完成。
  await tester.pump();
}

Future<void> _until(WidgetTester tester, bool Function() condition) async {
  for (var i = 0; i < 150 && !condition(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(condition(), isTrue);
}

Future<void> _unmount(
  WidgetTester tester,
  ReaderPaneController controller,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  var closed = false;
  controller.drainClosedDocuments().then((_) => closed = true);
  await _until(tester, () => closed);
}

// 测试内生成带真实父子目录的最小 PDF，不改变共享基线资产。
List<int> _outlinePdf({
  bool extended = false,
  bool flat = false,
  bool noOutline = false,
  String? contentOverride,
  String childDestination = '[4 0 R /Fit]',
  String secondPageGeometry = '/MediaBox [0 0 600 800]',
  bool trailingPage = false,
}) {
  final content =
      contentOverride ??
      'BT /F1 24 Tf 72 700 Td (OpenNote reader controls) Tj ET';
  final title = '很长的中文章节标题，用于检查目录拖宽和完整标题提示'.codeUnits
      .map((c) => c.toRadixString(16).padLeft(4, '0'))
      .join();
  final objects = [
    '<< /Type /Catalog /Pages 2 0 R ${noOutline ? '' : '/Outlines 5 0 R'} /Dests << /named-chapter [4 0 R /XYZ null 600 7] >> >>',
    '<< /Type /Pages /Kids [3 0 R 4 0 R ${trailingPage ? '${extended ? 14 : 10} 0 R' : ''}] /Count ${trailingPage ? 3 : 2} >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 600 800] /Resources << /Font << /F1 6 0 R >> >> /Contents 7 0 R >>',
    '<< /Type /Page /Parent 2 0 R $secondPageGeometry /Resources << /Font << /F1 6 0 R >> >> /Contents 7 0 R >>',
    '<< /Type /Outlines /First 8 0 R /Last ${extended ? 13 : 8} 0 R /Count ${extended
        ? 6
        : flat
        ? 1
        : 2} >>',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
    '<< /Length ${content.length} >>\nstream\n$content\nendstream',
    '<< /Title <FEFF$title> /Parent 5 0 R ${extended ? '/Next 11 0 R' : ''} ${flat ? '' : '/First 9 0 R /Last 9 0 R /Count ${extended ? 2 : 1}'} /Dest [3 0 R /Fit] >>',
    '<< /Title (Child chapter) /Parent 8 0 R ${extended ? '/First 10 0 R /Last 10 0 R /Count 1' : ''} ${childDestination == 'none' ? '' : '/Dest $childDestination'} >>',
    if (extended) ...[
      '<< /Title (Grandchild chapter) /Parent 9 0 R /Dest [4 0 R /Fit] >>',
      '<< /Title (Second chapter) /Parent 5 0 R /Prev 8 0 R /Next 13 0 R /First 12 0 R /Last 12 0 R /Count 1 /Dest [3 0 R /Fit] >>',
      '<< /Title (Second child) /Parent 11 0 R /Dest [4 0 R /Fit] >>',
      '<< /Title (Top-level leaf) /Parent 5 0 R /Prev 11 0 R /Dest [3 0 R /Fit] >>',
    ],
    if (trailingPage) '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 600 800] /Resources << /Font << /F1 6 0 R >> >> /Contents 7 0 R >>',
  ];
  final buffer = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(buffer.length);
    buffer.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xref = buffer.length;
  buffer.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
  for (final offset in offsets) {
    buffer.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  buffer.write(
    'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n',
  );
  return ascii.encode(buffer.toString());
}

Future<void> _saveOutlinePreview(
  WidgetTester tester,
  GlobalKey boundaryKey,
  String name,
) async {
  final output = Platform.environment['OPENNOTE_READER_OUTLINE_PREVIEW_DIR'];
  if (output == null) return;
  final boundary =
      boundaryKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = (await tester.runAsync(() => boundary.toImage(pixelRatio: 1)))!;
  try {
    final data = (await tester.runAsync(
      () => image.toByteData(format: ui.ImageByteFormat.png),
    ))!;
    await tester.runAsync(() async {
      final file = File('$output/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(data.buffer.asUint8List());
    });
  } finally {
    image.dispose();
  }
}
