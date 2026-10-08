import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:opennote/application/ocr_queue.dart';
import 'package:opennote/data/open_note_repository.dart';
import 'package:opennote/domain/models.dart';
import 'package:opennote/engines/ocr/ocr_service.dart';
import 'package:opennote/engines/pdf/pdf_read_engine.dart';
import 'package:opennote/engines/pdf/pdf_text_selection.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;
  late OpenNoteRepository repo;
  late OcrQueueController queue;
  late StudyProject project;
  late ManagedDocument imported;

  setUpAll(() async {
    if (!Platform.isWindows) return;
    final dll = File('build/windows/x64/runner/Release/pdfium.dll');
    if (dll.existsSync()) Pdfrx.pdfiumModulePath = dll.absolute.path;
    await pdfrxInitialize();
  });
  setUp(() async {
    if (!Platform.isWindows) return;
    temporary = await Directory.systemTemp.createTemp('opennote-ocr-contract-');
    repo = await OpenNoteRepository.open(rootPath: temporary.path);
    project = await repo.createProject('OCR 闭环验证');
    imported = await repo.importPdf(
      projectId: project.id,
      filePath: File('test/ocr/fixtures/scanned_rotated.pdf').absolute.path,
    );
    queue = OcrQueueController(
      repo,
      serviceFactory: () => NativeOcrService.create(
        libraryPath: File('native/build/Release/opennote_ocr.dll')
            .absolute
            .path,
        modelDirectory: Directory('assets/ocr/models/PP-OCRv6_small')
            .absolute
            .path,
      ),
    );
  });
  tearDown(() async {
    if (!Platform.isWindows) return;
    await queue.disposeAsync();
    await repo.close();
    await temporary.delete(recursive: true);
  });

  test(
    '真实扫描 PDF 经队列生成可搜索选文、摘录卡片和原始页坐标',
    () async {
      final startedPages = <int>[];
      queue.addListener(() {
        final page = queue.currentPageIndex;
        if (page != null && !startedPages.contains(page)) {
          startedPages.add(page);
        }
      });
      await queue.enqueueRevision(imported.activeRevisionId, priorityPage: 3);
      await queue.drain();
      expect(queue.lastError, isNull);
      expect(startedPages.first, 3);
      expect(queue.completedCount, 4);
      expect(queue.pendingCount, 0);
      final revision = await repo.getRevision(imported.activeRevisionId);
      expect(revision.pageGeometry.map((g) => g.rotation), [0, 90, 180, 270]);
      expect(revision.pageGeometry.every((g) => g.userUnit == 2), isTrue);
      final layers = await repo.loadTextLayers(revision.id);
      expect(layers, hasLength(4));
      for (final layer in layers) {
        expect(layer.source, TextLayerSource.ocr);
        expect(layer.text, contains('离线阅读与知识整理'));
        expect(
          layer.text,
          contains('OpenNote keeps your documents on this device.'),
        );
        final box = PdfCoordinateAdapter(revision.pageGeometry[layer.pageIndex])
            .effectiveBox;
        for (final fragment in layer.fragments) {
          expect(fragment.precision, GeometryPrecision.approximateCharacter);
          expect(
            fragment.start + fragment.length,
            lessThanOrEqualTo(layer.text.length),
          );
          for (final point in fragment.quad.points) {
            expect(point.x, inInclusiveRange(box.left - .01, box.right + .01));
            expect(point.y, inInclusiveRange(box.top - .01, box.bottom + .01));
          }
        }
      }
      final hits = await repo.search(project.id, '知识整理');
      expect(hits, hasLength(4));
      expect(hits.every((hit) => hit.quads.isNotEmpty), isTrue);
      final pdfDocument = await PdfDocument.openFile(
        await repo.resourcePath(revision.resourceId),
      );
      try {
        // 已知字形框：微软雅黑45px，短语起于原图x=320、y=105，末端x=500、y=149。
        for (final hit in hits) {
          final page = pdfDocument.pages[hit.pageIndex!];
          await page.ensureLoaded();
          final adapter = PdfCoordinateAdapter(
            revision.pageGeometry[hit.pageIndex!],
          );
          final boxes = hit.quads
              .map(
                (quad) => adapter
                    .quadInDocument(
                      quad,
                      page,
                      const Rect.fromLTWH(0, 0, 1800, 1200),
                    )
                    .getBounds(),
              )
              .toList();
          final bounds = boxes.reduce((a, b) => a.expandToInclude(b));
          expect(bounds.left, closeTo(320, 12));
          expect(bounds.right, closeTo(500, 12));
          expect(bounds.top, closeTo(105, 12));
          expect(bounds.bottom, closeTo(149, 12));
        }
        final page = pdfDocument.pages.first;
        const quad = [
          OcrPoint(100, 100),
          OcrPoint(180, 100),
          OcrPoint(180, 150),
          OcrPoint(100, 150),
        ];
        final surrogate = ocrResultToTextLayer(
          revisionId: revision.id,
          page: page,
          geometry: revision.pageGeometry.first,
          result: OcrResult(
            width: 1800,
            height: 1200,
            elapsedMs: 0,
            model: 'test-index-only',
            engine: 'test',
            lines: [
              OcrLine(
                order: 0,
                text: 'A𠀀B',
                confidence: 1,
                detectionConfidence: 1,
                quad: quad,
                precision: 'detectedLine',
                characters: [
                  OcrCharacter(
                    text: 'A',
                    confidence: 1,
                    quad: quad,
                    precision: 'approximateCtcAlignment',
                  ),
                  OcrCharacter(
                    text: '𠀀',
                    confidence: 1,
                    quad: quad,
                    precision: 'approximateCtcAlignment',
                  ),
                  OcrCharacter(
                    text: 'B',
                    confidence: 1,
                    quad: quad,
                    precision: 'approximateCtcAlignment',
                  ),
                ],
              ),
            ],
          ),
        );
        expect(surrogate.fragments.map((f) => [f.start, f.length]), [
          [0, 1],
          [1, 2],
          [3, 1],
        ]);
      } finally {
        await pdfDocument.dispose();
      }
      final first = layers.first;
      final start = first.text.indexOf('知识整理');
      final anchors = selectTextAcrossPages(
        revisionId: revision.id,
        a: PdfSelectionPoint(first.pageIndex, start, start + 4),
        b: PdfSelectionPoint(first.pageIndex, start, start + 4),
        layerForPage: (_) => PdfSelectableText.fromPersisted(first),
      );
      expect(anchors.single.context, '知识整理');
      final map = (await repo.listMaps(project.id)).first;
      final excerpt = await repo.createExcerpt(
        ExcerptDraft(
          projectId: project.id,
          mapId: map.id,
          title: 'OCR 摘录',
          text: anchors.single.context,
          anchors: anchors,
        ),
      );
      final stored = (await repo.getAnchors(excerpt.card.id)).single;
      expect(stored.revisionId, revision.id);
      expect(stored.textLayerId, first.id);
      expect(stored.context, '知识整理');
      expect(stored.quads, hasLength(4));
      expect(
        (await repo.listOcrTasks()).every(
          (task) => task.status == OcrTaskStatus.completed,
        ),
        isTrue,
      );
      await queue.enqueuePage(revision.id, first.pageIndex);
      await queue.drain();
      expect(queue.lastError, isNull);
      final rerun = (await repo.loadTextLayers(
        revision.id,
        pageIndex: first.pageIndex,
      )).single;
      expect(rerun.id, isNot(first.id));
      expect(
        await repo.loadTextLayers(
          revision.id,
          pageIndex: first.pageIndex,
          currentOnly: false,
        ),
        hasLength(2),
      );
      final unchangedAnchor = (await repo.getAnchors(excerpt.card.id)).single;
      expect(unchangedAnchor.textLayerId, first.id);
      expect(unchangedAnchor.context, '知识整理');
      final report = File('tools/ocr/validation/pdf-queue-report.json');
      await report.parent.create(recursive: true);
      await report.writeAsString(
        jsonEncode({
          'fixture': 'scanned_rotated.pdf',
          'rotations': [0, 90, 180, 270],
          'cropOrigin': [40, 60],
          'userUnit': 2,
          'completedPages': layers.length,
          'searchHits': hits.length,
          'excerpt': stored.context,
          'geometryPrecision': 'approximateCharacter',
          'elapsedMs': layers
              .map((layer) => layer.parameters['elapsedMs'])
              .toList(),
          'rerunPreservesOldAnchor': true,
          'scope': 'Controlled image-only PDF fixture, app pipeline+selection helper+storage; no UI gesture or real-book quality claim.',
        }),
        encoding: utf8,
      );
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    '真实竖排印刷书扫描主列顺序正确，跨列摘录保留字框与原文锚点',
    () async {
      final real = await repo.importPdf(
        projectId: project.id,
        filePath: File(
          'test/ocr/fixtures/real-books/chinese-page20-image-only.pdf',
        ).absolute.path,
      );
      await queue.enqueueRevision(real.activeRevisionId);
      await queue.drain();
      expect(queue.lastError, isNull);
      final layer = (await repo.loadTextLayers(real.activeRevisionId)).single;
      await File('tools/ocr/validation/real-book-layer-debug.json')
          .writeAsString(
            jsonEncode({'text': layer.text, 'parameters': layer.parameters}),
            encoding: utf8,
          );
      expect(layer.parameters['writingDirection'], 'verticalRtl');
      expect(layer.parameters['readingOrder'], 'basicVerticalColumns');
      expect(layer.text.indexOf('十一征'), greaterThanOrEqualTo(0));
      expect(
        layer.text.indexOf('五興五衰'),
        greaterThan(layer.text.indexOf('十一征')),
      );
      expect(
        layer.text.indexOf('復奉之歸於亳'),
        greaterThan(layer.text.indexOf('五興五衰')),
      );
      final start = layer.text.indexOf('國號商');
      final end = layer.text.indexOf('復奉之歸於亳') + '復奉之歸於亳'.length;
      expect(start, greaterThanOrEqualTo(0));
      final selection = selectTextAcrossPages(
        revisionId: real.activeRevisionId,
        a: PdfSelectionPoint(0, start, start + 1),
        b: PdfSelectionPoint(0, end - 1, end),
        layerForPage: (_) => PdfSelectableText.fromPersisted(layer),
      );
      expect(selection.single.context, startsWith('國號商\n'));
      expect(selection.single.context, contains('五興五衰'));
      expect(selection.single.context, endsWith('復奉之歸於亳'));
      expect(selection.single.context, isNot(contains('商之五興')));
      final map = (await repo.listMaps(project.id)).first;
      final excerpt = await repo.createExcerpt(
        ExcerptDraft(
          projectId: project.id,
          mapId: map.id,
          title: '真實竪排書跨列摘錄',
          text: selection.single.context,
          anchors: selection,
        ),
      );
      final anchor = (await repo.getAnchors(excerpt.card.id)).single;
      expect(anchor.textLayerId, layer.id);
      expect(anchor.context, selection.single.context);
      expect(anchor.quads, isNotEmpty);
      expect(
        layer.fragments.every(
          (f) => f.precision == GeometryPrecision.approximateCharacter,
        ),
        isTrue,
      );
      await File('tools/ocr/validation/real-book-queue-report.json')
          .writeAsString(
            jsonEncode({
              'fixture': 'Original 1920 printed scan JPEG embedded unchanged in image-only PDF',
              'direction': layer.parameters['writingDirection'],
              'elapsedNativeMs': layer.parameters['elapsedMs'],
              'columnOrderVerified': true,
              'excerpt': anchor.context,
              'anchorSaved': true,
              'quadCount': anchor.quads.length,
              'scope': 'True original scan through PDF render, native OCR, persisted layer, selection helper and excerpt; no UI mouse gesture claim.',
            }),
            encoding: utf8,
          );
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    '文字处理状态：原生PDF自动索引与复用完成页，不以空闲冒充就绪',
    () async {
      await queue.disposeAsync();
      queue = OcrQueueController(
        repo,
        serviceFactory: () async => throw StateError('原生文字页不应初始化 OCR'),
      );
      final native = await repo.importPdf(
        projectId: project.id,
        filePath: File('tools/fixtures/pdf/rotate_cropbox.pdf').absolute.path,
      );
      expect(queue.statusForRevision(native.activeRevisionId, pageCount: 4).isReady, isFalse);
      await queue.enqueueRevision(native.activeRevisionId);
      await queue.drain();
      expect(queue.lastError, isNull);
      final layers = await repo.loadTextLayers(native.activeRevisionId);
      expect(layers, hasLength(4));
      expect(
        layers.every((layer) => layer.source == TextLayerSource.nativePdf),
        isTrue,
      );
      expect(
        (await repo.listOcrTasks(revisionId: native.activeRevisionId))
            .every((task) => task.status == OcrTaskStatus.completed),
        isTrue,
      );
      final status = queue.statusForRevision(native.activeRevisionId);
      expect(status.totalPages, 4);
      expect(status.completedPages, 4);
      expect(status.isReady, isTrue);
      expect(status.label, '文字已就绪');
      await queue.enqueueRevision(native.activeRevisionId, retryIncomplete: false);
      await queue.drain();
      expect(queue.statusForRevision(native.activeRevisionId).completedPages, 4);
      expect((await repo.loadTextLayers(native.activeRevisionId)).map((layer) => layer.id),
          layers.map((layer) => layer.id));
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('阅读优先级：当前页、附近页按距离领取，翻页立即更新剩余队列', () async {
    await queue.disposeAsync();
    queue = OcrQueueController(
      repo,
      serviceFactory: () async => throw StateError('本测试只使用原生页'),
    );
    final native = await repo.importPdf(
      projectId: project.id,
      filePath: File('tools/fixtures/pdf/rotate_cropbox.pdf').absolute.path,
    );
    final order = <int>[];
    queue.addListener(() {
      final page = queue.currentPageIndex;
      if (page != null && !order.contains(page)) order.add(page);
    });
    await queue.enqueueRevision(native.activeRevisionId, priorityPage: 1);
    await queue.drain();
    expect(queue.lastError, isNull);
    expect(order, [1, 2, 0, 3]);
    final originalLayers = await repo.loadTextLayers(native.activeRevisionId);
    order.clear();
    // 已完成页翻阅只调整优先级，不创建任务、不强制重识别。
    queue.prioritizeReadingPage(native.activeRevisionId, 3);
    await queue.resumePending();
    await queue.drain();
    expect(order, isEmpty);
    expect(
      (await repo.loadTextLayers(native.activeRevisionId)).map((l) => l.id),
      originalLayers.map((l) => l.id),
    );

    final secondProject = await repo.createProject('翻页调度');
    final second = await repo.importPdf(
      projectId: secondProject.id,
      filePath: File('tools/fixtures/pdf/rotate_cropbox.pdf').absolute.path,
    );
    queue.addListener(() {
      if (queue.currentPageIndex == 3 && order.length == 1) {
        queue.prioritizeReadingPage(second.activeRevisionId, 0);
      }
    });
    await queue.enqueueRevision(second.activeRevisionId, priorityPage: 3);
    await queue.drain();
    expect(queue.lastError, isNull);
    expect(order, [3, 0, 1, 2]);
  }, skip: !Platform.isWindows);

  test(
    '混合PDF逐页优先保存精确原生层，空文字扫描页才OCR',
    () async {
      final mixed = await repo.importPdf(
        projectId: project.id,
        filePath: File('tools/fixtures/pdf/mixed.pdf').absolute.path,
      );
      await queue.enqueueRevision(mixed.activeRevisionId);
      await queue.drain();
      expect(queue.lastError, isNull);
      final layers = await repo.loadTextLayers(mixed.activeRevisionId);
      expect(layers.map((layer) => layer.source), [
        TextLayerSource.nativePdf,
        TextLayerSource.ocr,
        TextLayerSource.nativePdf,
      ]);
      expect(layers[0].text, contains('Mixed document native page'));
      expect(layers[2].text, contains('Mixed document final page'));
      expect(
        layers[0].fragments.every(
          (f) => f.precision == GeometryPrecision.character,
        ),
        isTrue,
      );
      expect(
        layers[2].fragments.every(
          (f) => f.precision == GeometryPrecision.character,
        ),
        isTrue,
      );
      expect(
        (await repo.listOcrTasks(revisionId: mixed.activeRevisionId))
            .every((task) => task.status == OcrTaskStatus.completed),
        isTrue,
      );
      expect(
        await repo.search(project.id, 'Mixed document final page'),
        isNotEmpty,
      );
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    '正常释放保留待处理扫描页，重开资料库自动续跑且复用已完成层',
    () async {
      await queue.disposeAsync();
      final factoryEntered = Completer<void>();
      final releaseFactory = Completer<void>();
      Future<NativeOcrService> createService() => NativeOcrService.create(
        libraryPath: File('native/build/Release/opennote_ocr.dll')
            .absolute
            .path,
        modelDirectory: Directory('assets/ocr/models/PP-OCRv6_small')
            .absolute
            .path,
      );
      queue = OcrQueueController(
        repo,
        serviceFactory: () async {
          factoryEntered.complete();
          await releaseFactory.future;
          return createService();
        },
      );
      final revisionId = imported.activeRevisionId;
      try {
        await queue.enqueueRevision(revisionId);
        await factoryEntered.future.timeout(const Duration(seconds: 30));
        final before = await repo.listOcrTasks(revisionId: revisionId);
        expect(
          before.where((task) => task.status == OcrTaskStatus.running),
          hasLength(1),
        );
        expect(
          before.where((task) => task.status == OcrTaskStatus.queued),
          hasLength(3),
        );
        // 当前页已经领取；在真实 OCR 初始化前关闭，确定保留的是持久任务。
        final shutdown = queue.disposeAsync();
        releaseFactory.complete();
        await shutdown;
      } finally {
        // 断言失败时也释放工厂，避免 teardown 等待未完成的真实工作循环。
        if (!releaseFactory.isCompleted) releaseFactory.complete();
      }
      final retained = await repo.listOcrTasks(revisionId: revisionId);
      expect(
        retained.where((task) => task.status == OcrTaskStatus.queued),
        hasLength(3),
      );
      expect(
        retained.where((task) => task.status == OcrTaskStatus.cancelled),
        isEmpty,
      );
      final completed = await repo.loadTextLayers(revisionId);
      expect(completed, hasLength(1));
      expect(completed.single.source, TextLayerSource.ocr);
      final previousLayerId = completed.single.id;
      final previousSession = repo.sessionId;
      await repo.close();
      repo = await OpenNoteRepository.open(rootPath: temporary.path);
      expect(repo.sessionId, isNot(previousSession));
      queue = OcrQueueController(repo, serviceFactory: createService);
      await queue.resumePending();
      await queue.drain();
      expect(queue.lastError, isNull);
      expect(
        (await repo.listOcrTasks(revisionId: revisionId))
            .every((task) => task.status == OcrTaskStatus.completed),
        isTrue,
      );
      final restored = await repo.loadTextLayers(revisionId);
      expect(restored, hasLength(4));
      expect(restored.map((layer) => layer.id), contains(previousLayerId));
      expect(await repo.search(project.id, '离线阅读与知识整理'), isNotEmpty);
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    '暂停排空后不接受新页，恢复只启动保留的queued任务',
    () async {
      await queue.enqueueRevision(imported.activeRevisionId);
      await queue.pauseAndDrain();
      expect(queue.isPaused, isTrue);
      expect(queue.isBusy, isFalse);
      await expectLater(
        queue.enqueuePage(imported.activeRevisionId, 0),
        throwsStateError,
      );
      await queue.resume();
      await queue.drain();
      expect(queue.lastError, isNull);
      expect(queue.completedCount, 4);
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    '仅页数已知的持久queued跨重启恢复会补齐真实PDF页框',
    () async {
      await queue.disposeAsync();
      final native = await repo.importPdf(
        projectId: project.id,
        filePath: File('tools/fixtures/pdf/native.pdf').absolute.path,
        pageCount: 2,
      );
      await repo.enqueueOcr(native.activeRevisionId, [
        1,
      ], modelVersion: OcrQueueController.modelVersion);
      final previousSession = repo.sessionId;
      await repo.close();
      repo = await OpenNoteRepository.open(rootPath: temporary.path);
      expect(repo.sessionId, isNot(previousSession));
      final pendingRevision = await repo.getRevision(native.activeRevisionId);
      expect(pendingRevision.pageCount, 2);
      expect(pendingRevision.pageGeometry, isEmpty);
      var initializedOcr = false;
      queue = OcrQueueController(
        repo,
        serviceFactory: () async {
          initializedOcr = true;
          throw const OcrException('原生PDF恢复不应初始化OCR');
        },
      );
      await queue.resumePending();
      await queue.drain();
      expect(queue.lastError, isNull);
      final readyRevision = await repo.getRevision(native.activeRevisionId);
      expect(readyRevision.pageGeometry, hasLength(2));
      final tasks = await repo.listOcrTasks(
        revisionId: native.activeRevisionId,
      );
      expect(tasks.single.status, OcrTaskStatus.completed);
      final layers = await repo.loadTextLayers(native.activeRevisionId);
      expect(layers.single.pageIndex, 1);
      expect(layers.single.source, TextLayerSource.nativePdf);
      expect(layers.single.fragments, isNotEmpty);
      expect(initializedOcr, isFalse);
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    '文字处理状态：分别恢复当前文档失败取消页，保留已完成层与其他文档失败',
    () async {
      await queue.disposeAsync();
      var initializedOcr = false;
      queue = OcrQueueController(
        repo,
        serviceFactory: () async {
          initializedOcr = true;
          throw const OcrException('原生文字重试不应初始化OCR');
        },
      );
      final native = await repo.importPdf(
        projectId: project.id,
        filePath: File('tools/fixtures/pdf/rotate_cropbox.pdf').absolute.path,
      );
      final revisionId = native.activeRevisionId;
      await queue.enqueueRevision(revisionId);
      await queue.drain();
      final before = await repo.loadTextLayers(revisionId);
      expect(before, hasLength(4));
      final completedLayer = before.singleWhere(
        (layer) => layer.pageIndex == 0,
      );
      final failed = (await repo.enqueueOcr(
        revisionId,
        [1],
        modelVersion: OcrQueueController.modelVersion,
        force: true,
      )).single;
      await repo.claimOcrTask(failed.id, sessionId: repo.sessionId);
      await repo.failOcrTask(failed.id, '可重试故障', sessionId: repo.sessionId);
      await repo.enqueueOcr(
        revisionId,
        [2],
        modelVersion: OcrQueueController.modelVersion,
        force: true,
      );
      await repo.cancelOcr(revisionId: revisionId);
      final otherFailed = (await repo.enqueueOcr(imported.activeRevisionId, [
        0,
      ], modelVersion: OcrQueueController.modelVersion)).single;
      await repo.claimOcrTask(otherFailed.id, sessionId: repo.sessionId);
      await repo.failOcrTask(
        otherFailed.id,
        '其他文档故障',
        sessionId: repo.sessionId,
      );
      // 恢复/刷新不偷偷重排失败和取消；按钮计数绑定当前文档。
      await queue.resumePending();
      await queue.drain();
      expect(queue.retryableCountForRevision(revisionId), 2);
      expect(queue.retryableCountForRevision(imported.activeRevisionId), 1);
      expect(await repo.loadTextLayers(revisionId), hasLength(4));
      final status = queue.statusForRevision(revisionId);
      expect(status.completedPages, 2);
      expect(status.failedPages, 1);
      expect(status.cancelledPages, 1);
      expect(status.isReady, isFalse);
      expect(status.error, '可重试故障');
      expect(queue.statusForRevision(imported.activeRevisionId, pageCount: 4).error, '其他文档故障');
      await queue.retryRevision(revisionId, status: OcrTaskStatus.failed);
      await queue.drain();
      final retried = queue.statusForRevision(revisionId);
      expect(retried.completedPages, 3);
      expect(retried.failedPages, 0);
      expect(retried.cancelledPages, 1);
      expect(retried.isReady, isFalse);
      await queue.retryRevision(revisionId, status: OcrTaskStatus.cancelled);
      await queue.drain();
      expect(queue.lastError, isNull);
      expect(queue.retryableCountForRevision(revisionId), 0);
      expect(queue.statusForRevision(revisionId).isReady, isTrue);
      expect(queue.retryableCountForRevision(imported.activeRevisionId), 1);
      final layers = await repo.loadTextLayers(revisionId);
      expect(layers, hasLength(4));
      expect(
        layers.singleWhere((layer) => layer.pageIndex == 0).id,
        completedLayer.id,
      );
      for (final page in [1, 2]) {
        expect(
          layers.singleWhere((layer) => layer.pageIndex == page).id,
          isNot(before.singleWhere((layer) => layer.pageIndex == page).id),
        );
      }
      expect(
        layers.singleWhere((layer) => layer.pageIndex == 3).id,
        before.singleWhere((layer) => layer.pageIndex == 3).id,
      );
      final history = await repo.loadTextLayers(revisionId, currentOnly: false);
      expect(history, hasLength(6));
      expect(
        history.where((layer) => !layer.isCurrent).map((layer) => layer.id),
        unorderedEquals(
          before
              .where((layer) => layer.pageIndex == 1 || layer.pageIndex == 2)
              .map((layer) => layer.id),
        ),
      );
      expect(
        layers.every((layer) => layer.source == TextLayerSource.nativePdf),
        isTrue,
      );
      final otherTasks = await repo.listOcrTasks(
        revisionId: imported.activeRevisionId,
      );
      expect(otherTasks.single.status, OcrTaskStatus.failed);
      expect(initializedOcr, isFalse);
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    '文字处理状态：取消仅影响目标文档，运行页释放后其他文档继续自动处理',
    () async {
      await queue.disposeAsync();
      final factoryEntered = Completer<void>();
      final releaseFactory = Completer<void>();
      queue = OcrQueueController(repo, serviceFactory: () async {
        factoryEntered.complete();
        await releaseFactory.future;
        throw const OcrException('被取消的初始化不应提交失败结果');
      });
      try {
        await queue.enqueueRevision(imported.activeRevisionId);
        await factoryEntered.future.timeout(const Duration(seconds: 30));
        final other = await repo.importPdf(projectId: project.id,
            filePath: File('tools/fixtures/pdf/rotate_cropbox.pdf').absolute.path);
        await queue.enqueueRevision(other.activeRevisionId);
        await queue.cancel(revisionId: other.activeRevisionId);
        expect(queue.statusForRevision(other.activeRevisionId).cancelledPages, 4);
        expect(queue.statusForRevision(imported.activeRevisionId).pendingPages, 4);
        expect(queue.currentTask?.revisionId, imported.activeRevisionId);
        await queue.retryRevision(other.activeRevisionId, status: OcrTaskStatus.cancelled);
        var cancelled = false;
        final cancellation = queue.cancel(revisionId: imported.activeRevisionId)
            .then((_) => cancelled = true);
        while ((await repo.listOcrTasks(revisionId: imported.activeRevisionId))
            .any((task) => task.status != OcrTaskStatus.cancelled)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(cancelled, isFalse, reason: '取消完成前须等待旧运行页释放');
        expect(queue.statusForRevision(imported.activeRevisionId).isCancelling, isTrue);
        await expectLater(queue.retryRevision(imported.activeRevisionId,
            status: OcrTaskStatus.cancelled), throwsStateError);
        releaseFactory.complete();
        await cancellation.timeout(const Duration(seconds: 30));
        await queue.drain();
        expect(queue.statusForRevision(imported.activeRevisionId).cancelledPages, 4);
        expect(queue.statusForRevision(imported.activeRevisionId).isReady, isFalse);
        expect(await repo.loadTextLayers(imported.activeRevisionId), isEmpty);
        expect(queue.statusForRevision(other.activeRevisionId).isReady, isTrue);
        expect(await repo.loadTextLayers(other.activeRevisionId), hasLength(4));
        expect(queue.lastError, isNull);
      } finally {
        if (!releaseFactory.isCompleted) releaseFactory.complete();
      }
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    '取消运行页阻止迟到提交，之后显式重试当前页',
    () async {
      await queue.enqueueRevision(imported.activeRevisionId);
      while (!queue.isRunning && queue.isBusy) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await queue.cancel();
      expect(queue.pendingCount, 0);
      expect(queue.cancelledCount, 4);
      expect(await repo.loadTextLayers(imported.activeRevisionId), isEmpty);
      await queue.enqueuePage(imported.activeRevisionId, 0);
      await queue.drain();
      expect(queue.lastError, isNull);
      expect(
        await repo.loadTextLayers(imported.activeRevisionId),
        hasLength(1),
      );
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
