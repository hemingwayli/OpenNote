import '../support/flutter_sdk.dart';

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:opennote/ui/theme/open_note_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:opennote/domain/models.dart' as model;
import 'package:opennote/engines/pdf/pdf_read_engine.dart';
import 'package:opennote/ui/reader/reader_pane.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    Pdfrx.pdfiumModulePath = File('build/windows/x64/runner/Release/pdfium.dll')
        .absolute
        .path;
    await pdfrxInitialize();
    await (FontLoader('MaterialIcons')..addFont(
          File(
            '${flutterSdkPath()}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          ).readAsBytes().then(ByteData.sublistView),
        ))
        .load();
    await (FontLoader('Source Han Sans CN')..addFont(
          File('assets/fonts/source-han-sans/SourceHanSansCN-Regular.otf')
              .readAsBytes()
              .then(ByteData.sublistView),
        ))
        .load();
    await (FontLoader('Segoe UI')..addFont(
          File('C:/Windows/Fonts/segoeui.ttf')
              .readAsBytes()
              .then(ByteData.sublistView),
        ))
        .load();
  });
  testWidgets('回源体验：加载前明确翻页优先于旧阅读位置恢复', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 750));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = ReaderPaneController();
    await controller.goToPage(1);
    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: openNoteTheme(),
          home: Scaffold(
            body: ReaderPane(
              revisionId: 'queued-page',
              filePath: File('tools/fixtures/pdf/rotate_cropbox.pdf')
                  .absolute
                  .path,
              controller: controller,
              onExcerpt: (_) {},
              initialPosition: const model.ReadingPosition(
                revisionId: 'queued-page',
                pageIndex: 3,
                offset: .75,
              ),
            ),
          ),
        ),
      );
      await waitUntil(
        tester,
        () =>
            controller.currentZoom != null &&
            controller.pendingPageIndex == null,
      );
      final viewer = tester
          .widget<PdfViewer>(find.byType(PdfViewer))
          .controller!;
      expect(viewer.visibleRect.overlaps(viewer.layout.pageLayouts[1]), isTrue);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      // 渐进页加载在卸载后须获得一次计时器回调，才能观察到退出状态。
      await tester.pump(const Duration(milliseconds: 200));
      await tester.runAsync(controller.drainClosedDocuments);
    }
  });

  testWidgets('回源体验：各缩放跨页跨文档、长摘录与旋转页只平移，柔和强调淡出', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 750));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = ReaderPaneController();
    var geometry = <model.PdfPageGeometry>[];
    var ready = false;
    PdfViewerController viewer() =>
        tester.widget<PdfViewer>(find.byType(PdfViewer)).controller!;
    Future<void> mount(
      String revision,
      String path, {
      model.ReadingPosition? position,
    }) async {
      ready = false;
      geometry = [];
      await tester.pumpWidget(
        MaterialApp(
          theme: openNoteTheme(),
          home: RepaintBoundary(
            key: const Key('source-screen'),
            child: Scaffold(
              body: ReaderPane(
                key: ValueKey(revision),
                revisionId: revision,
                filePath: File(path).absolute.path,
                controller: controller,
                initialPosition: position,
                onExcerpt: (_) {},
                onGeometryLoaded: (value) => geometry = value,
                onInitialPageReady: () => ready = true,
              ),
            ),
          ),
        ),
      );
      await waitUntil(
        tester,
        // 渐进加载的整份文档完成通知不等于本页导航就绪；待回源也必须已经兑现。
        () =>
            geometry.isNotEmpty &&
            viewer().isReady &&
            controller.currentZoom != null &&
            controller.pendingSourceRequest == null,
        diagnostic: () =>
            'ready=$ready geometry=${geometry.length} viewer=${viewer().isReady} errors=${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).where((t) => t?.contains("失败") == true || t?.contains("无法") == true).toList()}',
      );
    }

    Future<void> navigate(
      List<model.AnchorDraft> anchors, {
      double? zoom,
    }) async {
      var done = false;
      final future = controller
          .jumpToAnchors(anchors, zoom: zoom, cardId: 'source')
          .then((_) => done = true);
      await waitUntil(tester, () => done);
      await future;
      await tester.pump();
    }

    Future<int> overlayPixels(int index) async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final rect = viewer().layout.pageLayouts[index];
      canvas.translate(-rect.left, -rect.top);
      tester
          .widget<PdfViewer>(find.byType(PdfViewer))
          .params
          .pagePaintCallbacks!
          .single(canvas, rect, viewer().pages[index]);
      final picture = recorder.endRecording();
      final image = await tester.runAsync(
        () => picture.toImage(rect.width.ceil(), rect.height.ceil()),
      );
      final bytes = await tester.runAsync(() => image!.toByteData());
      var count = 0;
      for (var i = 3; i < bytes!.lengthInBytes; i += 4) {
        if (bytes.getUint8(i) != 0) count++;
      }
      image!.dispose();
      picture.dispose();
      return count;
    }

    try {
      await mount('reading', 'tools/fixtures/pdf/ui-reading.pdf');
      final layer = await tester.runAsync(
        () => PdfReadEngine.extractNativeText(
          revisionId: 'reading',
          page: viewer().pages[0],
          geometry: geometry[0],
        ),
      );
      final start = layer!.text.indexOf('Reading is more');
      expect(start, greaterThanOrEqualTo(0));
      final quads = layer.fragments
          .where((f) => f.start >= start)
          .take(55)
          .map((f) => f.quad)
          .toList();
      for (final zoom in [.5, 1.19, 2.0]) {
        await viewer().setZoom(
          viewer().visibleRect.center,
          zoom,
          duration: Duration.zero,
        );
        await navigate([
          model.AnchorDraft(revisionId: 'reading', pageIndex: 1, quads: []),
        ]);
        expect(viewer().currentZoom, closeTo(zoom, .000001));
        expect(
          viewer().visibleRect.overlaps(viewer().layout.pageLayouts[1]),
          isTrue,
          reason: '低倍率可同时看到两页，目标页须可见，不能通过放大强制改变页码',
        );
        await navigate([
          model.AnchorDraft(revisionId: 'reading', pageIndex: 0, quads: quads),
        ]);
        expect(viewer().currentZoom, closeTo(zoom, .000001));
        final target = PdfCoordinateAdapter(geometry[0])
            .quadInDocument(
              quads.first,
              viewer().pages[0],
              viewer().layout.pageLayouts[0],
            )
            .getBounds();
        expect(viewer().visibleRect.overlaps(target), isTrue);
        if (zoom == 1.19) {
          expect(await overlayPixels(0), greaterThan(0));
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const Key('source-screen')),
          );
          await tester.pump(const Duration(milliseconds: 100));
          await tester.runAsync(() async {
            final screenshot = await boundary.toImage();
            final png = await screenshot.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final output = File(
              '.local/verification/source-link-fix-20261005/source-focus.png',
            );
            await output.parent.create(recursive: true);
            await output.writeAsBytes(png!.buffer.asUint8List());
            screenshot.dispose();
          });
          await tester.pump(const Duration(milliseconds: 200));
          await tester.pump(const Duration(milliseconds: 300));
          await tester.pump();
          expect(await overlayPixels(0), 0, reason: '临时强调必须淡出，不能长期留下字框');
        }
      }
      // 长范围定位首行，不能为容纳全文而改变比例。
      final box = PdfCoordinateAdapter(geometry[1]).effectiveBox;
      await navigate([
        model.AnchorDraft(
          revisionId: 'reading',
          pageIndex: 1,
          quads: [
            model.PdfQuad.rect(
              box.left + 20,
              box.top + 80,
              box.right - 20,
              box.bottom - 40,
            ),
          ],
        ),
      ]);
      expect(viewer().currentZoom, closeTo(2, .000001));
      final captured = controller.currentZoom;
      await controller.jumpToAnchors(const [
        model.AnchorDraft(revisionId: 'rotated', pageIndex: 1, quads: []),
      ], zoom: captured);
      debugPrint('回源测试：切换文档并恢复旧位置');
      await mount(
        'rotated',
        'tools/fixtures/pdf/rotate_cropbox.pdf',
        position: const model.ReadingPosition(
          revisionId: 'rotated',
          pageIndex: 3,
          offset: .75,
        ),
      );
      await waitUntil(tester, () => controller.pendingAnchors == null);
      debugPrint('回源测试：新文档回源完成');
      expect(viewer().currentZoom, closeTo(2, .000001), reason: '加载新文档后兑现原比例');
      expect(
        viewer().visibleRect.overlaps(viewer().layout.pageLayouts[1]),
        isTrue,
        reason: '回源必须优先于旧文档阅读位置恢复',
      );
      for (var index = 0; index < geometry.length; index++) {
        debugPrint('回源测试：旋转页 $index');
        final box = PdfCoordinateAdapter(geometry[index]).effectiveBox;
        final anchor = model.AnchorDraft(
          revisionId: 'rotated',
          pageIndex: index,
          // 使用裁切框内的固定原页范围，避免与阅读器的原生预读重复取层。
          quads: [
            model.PdfQuad.rect(
              box.left + 20,
              box.top + 30,
              box.left + 90,
              box.top + 45,
            ),
          ],
        );
        await navigate([anchor], zoom: 1.19);
        expect(viewer().currentZoom, closeTo(1.19, .000001));
        if (anchor.quads.isNotEmpty) {
          final target = PdfCoordinateAdapter(geometry[index])
              .quadInDocument(
                anchor.quads.first,
                viewer().pages[index],
                viewer().layout.pageLayouts[index],
              )
              .getBounds();
          expect(viewer().visibleRect.overlaps(target), isTrue);
        }
      }
      controller.clearAfterCardDeletion({'source'});
      debugPrint('回源测试：删除强调');
      await tester.pump();
      expect(await overlayPixels(geometry.length - 1), 0);
      final old = controller.jumpToAnchors(const [
        model.AnchorDraft(revisionId: 'rotated', pageIndex: 0, quads: []),
      ]);
      final latest = controller.jumpToAnchors(const [
        model.AnchorDraft(revisionId: 'rotated', pageIndex: 3, quads: []),
      ]);
      var completed = false;
      final both = Future.wait([old, latest]).then((_) => completed = true);
      debugPrint('回源测试：等待快速连续请求');
      await waitUntil(tester, () => completed);
      await both;
      debugPrint('回源测试：快速请求完成');
      expect(
        viewer().visibleRect.overlaps(viewer().layout.pageLayouts[3]),
        isTrue,
      );
      expect(viewer().currentZoom, closeTo(1.19, .000001));
      expect(tester.takeException(), isNull);
    } finally {
      debugPrint('回源测试：释放文档');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(controller.drainClosedDocuments);
    }
  });
}

Future<void> waitUntil(
  WidgetTester tester,
  bool Function() ready, {
  String Function()? diagnostic,
}) async {
  for (var i = 0; i < 150 && !ready(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(ready(), isTrue, reason: diagnostic?.call());
}
