import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:opennote/application/ocr_queue.dart';
import 'package:opennote/data/open_note_repository.dart';
import 'package:opennote/domain/models.dart' as model;
import 'package:opennote/engines/ocr/ocr_service.dart';
import 'package:opennote/engines/pdf/pdf_read_engine.dart';
import 'package:opennote/ui/reader/reader_pane.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final dll = File('build/windows/x64/runner/Release/pdfium.dll');
    if (dll.existsSync()) Pdfrx.pdfiumModulePath = dll.absolute.path;
    await pdfrxInitialize();
  });

  for (final scenario in [
    (
      name: '阅读器生命周期：加载中卸载释放迟到原生句柄与实际文件',
      replace: false,
      loaded: false,
      sameState: false,
      switchController: false,
      sameFile: false,
      sameRevision: false,
      closeBody: false,
    ),
    (
      name: '阅读器生命周期：加载中换文档释放迟到原生句柄，新文档仍可导航',
      replace: true,
      loaded: false,
      sameState: false,
      switchController: false,
      sameFile: false,
      sameRevision: false,
      closeBody: false,
    ),
    (
      name: '阅读器生命周期：已加载文档卸载后排空真实关闭与文件句柄',
      replace: false,
      loaded: true,
      sameState: false,
      switchController: false,
      sameFile: false,
      sameRevision: false,
      closeBody: false,
    ),
    (
      name: '阅读器生命周期：同State只换路径并换绑控制器，双方排空旧文档',
      replace: true,
      loaded: false,
      sameState: true,
      switchController: true,
      sameFile: false,
      sameRevision: true,
      closeBody: false,
    ),
    (
      name: '阅读器生命周期：同State同路径换修订独立持有文档，不提前关闭新文档',
      replace: true,
      loaded: false,
      sameState: true,
      switchController: false,
      sameFile: true,
      sameRevision: false,
      closeBody: false,
    ),
    (
      name: '阅读器生命周期：正文关闭保留Reader与页码状态，真实释放文件并可重新打开',
      replace: false,
      loaded: true,
      sameState: true,
      switchController: false,
      sameFile: false,
      sameRevision: false,
      closeBody: true,
    ),
  ]) {
    testWidgets(scenario.name, (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 750));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      late Directory temporary;
      late File first;
      late File second;
      await tester.runAsync(() async {
        // 两份临时副本都使用真实的四页原生 PDF，不改正式 fixture。
        temporary = await Directory.systemTemp.createTemp(
          'opennote-reader-lifecycle-',
        );
        final source = File('tools/fixtures/pdf/rotate_cropbox.pdf');
        first = await source.copy('${temporary.path}/first.pdf');
        second = await source.copy('${temporary.path}/second.pdf');
        await pdfrxFlutterInitialize();
      });
      final controller = ReaderPaneController();
      final replacementController = scenario.switchController
          ? ReaderPaneController()
          : controller;
      var replacementUsesNewController = !scenario.switchController;
      final entry = PdfrxEntryFunctions.instance;
      expect(entry.backendType, PdfrxBackendType.pdfium);
      final release = Completer<void>();
      Future<void>? suspension;
      var workerSuspended = false;
      var suspensionFinished = false;
      Object? suspensionError;
      Future<PdfDownloadReport?>? loading;
      PdfDocument? lateDocument;
      PdfDocument? replacementDocument;
      Object? loadingError;
      var loadFinished = false;
      var oldReady = false;
      var replacementReady = false;
      final prepared = <(String, int)>[];
      Widget reader(
        String revision,
        File file, {
        bool replacement = false,
        bool closing = false,
      }) => MaterialApp(
        home: Scaffold(
          body: ReaderPane(
            key: scenario.sameState
                ? const ValueKey('lifecycle-same-state')
                : ValueKey(revision),
            revisionId: revision,
            filePath: file.path,
            closing: closing,
            controller: replacement && replacementUsesNewController
                ? replacementController
                : controller,
            onExcerpt: (_) {},
            onInitialPageReady: () {
              if (replacement) {
                replacementReady = true;
              } else {
                oldReady = true;
              }
            },
            onNativeTextLayer: (layer) async {
              prepared.add((replacement ? 'second' : 'first', layer.pageIndex));
            },
          ),
        ),
      );
      try {
        if (!scenario.loaded) {
          await tester.runAsync(() async {
            // 公开 worker 门闩只暂停实际 FPDF_LoadDocument，不替换原生文档。
            suspension = entry.suspendPdfiumWorkerDuringAction<void>(() {
              workerSuspended = true;
              return release.future;
            });
            unawaited(
              suspension!.then<void>(
                (_) {
                  suspensionFinished = true;
                },
                onError: (Object error, StackTrace _) {
                  suspensionError = error;
                  suspensionFinished = true;
                },
              ),
            );
          });
        }
        // 门闩跨真实 IO 与测试时钟，持续 pump；不能在 runAsync 内等待 FakeAsync Future。
        if (!scenario.loaded) {
          await _pumpUntil(tester, () => workerSuspended || suspensionFinished);
          expect(suspensionError, isNull);
          expect(workerSuspended, isTrue, reason: '必须收到实际 PDFium worker 暂停确认');
        }
        await tester.pumpWidget(reader('lifecycle-first', first));
        await tester.pump();
        final firstState = tester.state(find.byType(ReaderPane));
        final pageFieldState = scenario.closeBody
            ? tester.state(find.byType(TextField))
            : null;
        final pageEditableFinder = find.descendant(
          of: find.byType(TextField),
          matching: find.byType(EditableText),
        );
        final pageEditableState = scenario.closeBody
            ? tester.state(pageEditableFinder)
            : null;
        final viewer = tester.widget<PdfViewer>(find.byType(PdfViewer));
        final listenable = viewer.documentRef.resolveListenable();
        // 观察当前真实 Viewer 的公开加载 Future，不添加会保活文档的 listener。
        loading = listenable.load();
        unawaited(
          loading.then<void>(
            (_) {
              lateDocument = listenable.document;
              loadingError = listenable.error;
              loadFinished = true;
            },
            onError: (Object error, StackTrace _) {
              loadingError = error;
              loadFinished = true;
            },
          ),
        );
        await tester.pump();
        if (scenario.loaded) {
          await _pumpUntil(
            tester,
            () => loadFinished && oldReady && prepared.contains(('first', 0)),
          );
          expect((lateDocument as dynamic).isDisposed, isFalse);
        } else {
          expect(listenable.document, isNull);
          expect(oldReady, isFalse);
          expect(loadFinished, isFalse, reason: '必须实际卸载尚未完成加载的 Reader');
        }
        final oldCallbacks = prepared
            .where((item) => item.$1 == 'first')
            .length;
        await tester.pumpWidget(
          scenario.closeBody
              ? reader('lifecycle-first', first, closing: true)
              : scenario.replace
              ? reader(
                  scenario.sameRevision
                      ? 'lifecycle-first'
                      : 'lifecycle-second',
                  scenario.sameFile ? first : second,
                  replacement: true,
                )
              : const SizedBox.shrink(),
        );
        await tester.pump();
        if (scenario.switchController) {
          final secondRef = tester
              .widget<PdfViewer>(find.byType(PdfViewer))
              .documentRef
              .key;
          // 旧关闭仍被门闩挡住；仅换 controller 不重开当前文档，却须继承待关闭任务。
          replacementUsesNewController = true;
          await tester.pumpWidget(
            reader(
              scenario.sameRevision ? 'lifecycle-first' : 'lifecycle-second',
              scenario.sameFile ? first : second,
              replacement: true,
            ),
          );
          await tester.pump();
          expect(
            tester.widget<PdfViewer>(find.byType(PdfViewer)).documentRef.key,
            secondRef,
          );
        }
        if (scenario.closeBody) {
          expect(find.byType(PdfViewer), findsNothing);
          expect(
            find.byKey(const ValueKey('reader-closing-document')),
            findsOneWidget,
          );
          expect(
            tester.widget<ReaderPane>(find.byType(ReaderPane)).closing,
            isTrue,
          );
          expect(
            identical(tester.state(find.byType(ReaderPane)), firstState),
            isTrue,
          );
          expect(
            identical(tester.state(find.byType(TextField)), pageFieldState),
            isTrue,
          );
          expect(
            identical(tester.state(pageEditableFinder), pageEditableState),
            isTrue,
          );
        }
        if (scenario.sameState && !scenario.closeBody) {
          expect(
            identical(tester.state(find.byType(ReaderPane)), firstState),
            isTrue,
          );
          expect(
            tester.widget<PdfViewer>(find.byType(PdfViewer)).documentRef.key,
            isNot(viewer.documentRef.key),
            reason: '同State/同路径也必须建立新的独立关闭所有权',
          );
        }
        var drainFinished = false;
        Object? drainError;
        var replacementDrainFinished = !scenario.switchController;
        unawaited(
          controller.drainClosedDocuments().then<void>(
            (_) {
              drainFinished = true;
            },
            onError: (Object error, StackTrace _) {
              drainError = error;
              drainFinished = true;
            },
          ),
        );
        if (scenario.switchController) {
          unawaited(
            replacementController.drainClosedDocuments().then<void>(
              (_) {
                replacementDrainFinished = true;
              },
              onError: (Object error, StackTrace _) {
                drainError = error;
                replacementDrainFinished = true;
              },
            ),
          );
        }
        await tester.pump();
        if (!scenario.loaded) {
          expect(drainFinished, isFalse, reason: '未返回的原生打开仍须等待真实关闭');
          expect(replacementDrainFinished, !scenario.switchController);
          release.complete();
          await _pumpUntil(tester, () => suspensionFinished);
        }
        expect(suspensionError, isNull);
        await _pumpUntil(
          tester,
          () => loadFinished && drainFinished && replacementDrainFinished,
        );
        expect(drainError, isNull);
        expect(loadingError, isNull);
        expect(lateDocument, isNotNull, reason: '必须取得真实 PDFium 返回的迟到文档');
        expect(oldReady, scenario.loaded);
        expect(
          prepared.where((item) => item.$1 == 'first').length,
          oldCallbacks,
          reason: '迟到文档不能继续触发已经卸载的 Reader 回调',
        );
        if (scenario.replace) {
          await _pumpUntil(
            tester,
            () => replacementReady && prepared.contains(('second', 0)),
          );
          final currentViewer = tester.widget<PdfViewer>(
            find.byType(PdfViewer),
          );
          replacementDocument = currentViewer.documentRef
              .resolveListenable()
              .document;
          expect(replacementDocument, isNotNull);
          expect(identical(replacementDocument, lateDocument), isFalse);
          expect((replacementDocument as dynamic).isDisposed, isFalse);
          final navigation = replacementController.goToPage(3);
          await tester.pumpAndSettle();
          await navigation;
          await _pumpUntil(
            tester,
            () =>
                currentViewer.controller!.pageNumber == 4 &&
                prepared.contains(('second', 3)),
          );
          if (scenario.sameFile) {
            // 新 Reader 仍在使用同一路径；先确认未被旧所有者误关，再卸载它。
            await tester.pumpWidget(const SizedBox.shrink());
            await _drainReaderDocuments(tester, replacementController);
            expect((replacementDocument as dynamic).isDisposed, isTrue);
          }
        }
        FileSystemException? fileReleaseError;
        File? renamed;
        await tester.runAsync(() async {
          // 只排空已经发生的 worker 操作；业务断言前不主动 dispose 文档。
          await entry.compute<int, int>(_readerLifecycleBarrier, 0);
          try {
            renamed = await first.rename('${first.path}.released');
          } on FileSystemException catch (error) {
            fileReleaseError = error;
          }
        });
        final nativeDisposed = (lateDocument as dynamic).isDisposed as bool;
        expect(
          nativeDisposed,
          isTrue,
          reason:
              '已经卸载的迟到真实文档必须释放；实际文件重命名结果：'
              '${fileReleaseError ?? renamed?.path}',
        );
        expect(fileReleaseError, isNull, reason: '旧文档原生句柄关闭后临时副本应可实际重命名');
        expect(renamed!.existsSync(), isTrue);
        expect(tester.takeException(), isNull);
        if (scenario.closeBody) {
          // 真实重命名已证明旧句柄释放，再将原字节移回并重新显示同一 Reader。
          await tester.runAsync(() async {
            await renamed!.rename(first.path);
          });
          oldReady = false;
          await tester.pumpWidget(reader('lifecycle-first', first));
          await _pumpUntil(
            tester,
            () =>
                oldReady &&
                prepared.where((item) => item.$1 == 'first').length >
                    oldCallbacks,
          );
          expect(
            identical(tester.state(find.byType(ReaderPane)), firstState),
            isTrue,
          );
          expect(
            identical(tester.state(find.byType(TextField)), pageFieldState),
            isTrue,
          );
          expect(
            identical(tester.state(pageEditableFinder), pageEditableState),
            isTrue,
          );
          final resumedViewer = tester.widget<PdfViewer>(
            find.byType(PdfViewer),
          );
          replacementDocument = resumedViewer.documentRef
              .resolveListenable()
              .document;
          expect(replacementDocument, isNotNull);
          expect(identical(replacementDocument, lateDocument), isFalse);
          expect((replacementDocument as dynamic).isDisposed, isFalse);
          final navigation = controller.goToPage(3);
          await tester.pumpAndSettle();
          await navigation;
          await _pumpUntil(
            tester,
            () =>
                resumedViewer.controller!.pageNumber == 4 &&
                prepared.contains(('first', 3)),
          );
          expect(tester.takeException(), isNull);
        }
      } finally {
        if (!release.isCompleted) release.complete();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        if (suspension != null && !suspensionFinished) {
          await _pumpUntil(tester, () => suspensionFinished);
        }
        if (loading != null && !loadFinished) {
          await _pumpUntil(tester, () => loadFinished);
        }
        await _drainReaderDocuments(tester, controller);
        if (!identical(controller, replacementController)) {
          await _drainReaderDocuments(tester, replacementController);
        }
        await tester.runAsync(() async {
          // 无论 RED/通过都关闭真实文档，只在业务断言之后用于清理。
          await lateDocument?.dispose();
          await replacementDocument?.dispose();
          await entry.compute<int, int>(_readerLifecycleBarrier, 0);
          await temporary.delete(recursive: true);
        });
      }
    });
  }

  testWidgets('阅读器生命周期：真实打开失败没有原生文档，不阻塞卸载排空', (tester) async {
    late Directory temporary;
    await tester.runAsync(() async {
      temporary = await Directory.systemTemp.createTemp(
        'opennote-reader-open-error-',
      );
      await pdfrxFlutterInitialize();
    });
    final controller = ReaderPaneController();
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReaderPane(
              revisionId: 'missing-native-document',
              filePath: '${temporary.path}/not-created.pdf',
              controller: controller,
              onExcerpt: (_) {},
            ),
          ),
        ),
      );
      final listenable = tester
          .widget<PdfViewer>(find.byType(PdfViewer))
          .documentRef
          .resolveListenable();
      await _pumpUntil(tester, () => listenable.error != null);
      await tester.pump();
      expect(listenable.document, isNull);
      expect(find.text('无法打开 PDF'), findsOneWidget);
      expect(find.text(listenable.error.toString()), findsOneWidget);
      final errorScroll = find.byKey(
        const ValueKey('reader-load-error-scroll'),
      );
      expect(errorScroll, findsOneWidget);
      final scrollable = tester.state<ScrollableState>(
        find.descendant(of: errorScroll, matching: find.byType(Scrollable)),
      );
      expect(scrollable.position.axisDirection, AxisDirection.down);
      if (scrollable.position.maxScrollExtent > 0) {
        await tester.drag(errorScroll, const Offset(0, -100));
        await tester.pumpAndSettle();
        expect(scrollable.position.pixels, greaterThan(0));
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await _drainReaderDocuments(tester, controller);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await _drainReaderDocuments(tester, controller);
      await tester.runAsync(() async {
        await PdfrxEntryFunctions.instance.compute<int, int>(
          _readerLifecycleBarrier,
          0,
        );
        await temporary.delete(recursive: true);
      });
    }
  });

  test('阅读器生命周期：关闭排空等待并发任务且持续传播关闭错误', () async {
    final controller = ReaderPaneController();
    final failed = Completer<void>();
    final pending = Completer<void>();
    final error = StateError('关闭回调真实失败');
    controller.trackClosedDocument(failed.future);
    controller.trackClosedDocument(pending.future);
    var finished = false;
    Object? captured;
    final draining = controller.drainClosedDocuments().then<void>(
      (_) {
        finished = true;
      },
      onError: (Object value, StackTrace _) {
        captured = value;
        finished = true;
      },
    );
    failed.completeError(error, StackTrace.current);
    await Future<void>.value();
    expect(finished, isFalse, reason: '其中一个关闭失败也须等另一个已登记关闭完成');
    pending.complete();
    await draining;
    expect(finished, isTrue);
    expect(captured, same(error));
    await expectLater(controller.drainClosedDocuments(), throwsA(same(error)));
  });

  testWidgets('阅读器只准备可见页附近文字，翻页再准备新页', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 750));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = ReaderPaneController();
    final prepared = <int>{};
    var ready = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReaderPane(
            revisionId: 'visible-pages',
            filePath: File('tools/fixtures/pdf/rotate_cropbox.pdf')
                .absolute
                .path,
            controller: controller,
            onExcerpt: (_) {},
            onInitialPageReady: () => ready = true,
            onNativeTextLayer: (layer) async => prepared.add(layer.pageIndex),
          ),
        ),
      ),
    );
    await _pumpUntil(tester, () => ready && prepared.length >= 2);
    // 留出真实 PDF 文本提取时间，确保没有隐藏的全文遍历继续准备远处页。
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(prepared, unorderedEquals([0, 1]));
    final navigation = controller.goToPage(3);
    await tester.pumpAndSettle();
    await navigation;
    await _pumpUntil(tester, () => prepared.containsAll([2, 3]));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
  });

  testWidgets('打开未索引的历史原生PDF由持久队列补齐全文搜索', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 750));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    late Directory temporary;
    late OpenNoteRepository repo;
    late model.StudyProject project;
    late model.DocumentRevision revision;
    late String filePath;
    await tester.runAsync(() async {
      temporary = await Directory.systemTemp.createTemp(
        'opennote-reader-index-',
      );
      repo = await OpenNoteRepository.open(rootPath: temporary.path);
      project = await repo.createProject('历史文档索引');
      final document = await repo.importPdf(
        projectId: project.id,
        filePath: File('tools/fixtures/pdf/rotate_cropbox.pdf').absolute.path,
      );
      revision = await repo.getRevision(document.activeRevisionId);
      filePath = await repo.resourcePath(revision.resourceId);
      expect(await repo.listOcrTasks(), isEmpty);
      expect(await repo.loadTextLayers(revision.id), isEmpty);
    });
    var initializedOcr = false;
    final queue = OcrQueueController(
      repo,
      serviceFactory: () async {
        initializedOcr = true;
        throw const OcrException('原生文档索引不应加载OCR模型');
      },
    );
    final requestedPages = <int>{};
    Future<void>? indexing;
    var indexRequests = 0;
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReaderPane(
              revisionId: revision.id,
              filePath: filePath,
              onExcerpt: (_) {},
              onTextLayerRequested: (page) {
                requestedPages.add(page);
                return repo.loadTextLayers(revision.id, pageIndex: page);
              },
              onNativeTextLayer: (draft) async {
                await repo.saveTextLayer(draft, sessionId: repo.sessionId);
              },
              onIndexingRequested: (page) {
                indexRequests++;
                indexing = queue.enqueueRevision(
                  revision.id,
                  priorityPage: page,
                  retryIncomplete: false,
                );
              },
            ),
          ),
        ),
      );
      await _pumpUntil(tester, () => indexRequests == 1);
      await _drainQueue(tester, queue, [indexing!]);
      await tester.runAsync(() async {
        expect(queue.lastError, isNull);
        expect(await repo.loadTextLayers(revision.id), hasLength(4));
        final hits = await repo.search(project.id, '原生文字');
        expect(hits, hasLength(4));
        expect(hits.any((hit) => hit.pageIndex == 3), isTrue);
        expect(
          (await repo.listOcrTasks()).every(
            (task) => task.status == model.OcrTaskStatus.completed,
          ),
          isTrue,
        );
      });
      await tester.pump();
      expect(requestedPages, isNotEmpty);
      expect(requestedPages.every((page) => page <= 1), isTrue);
      expect(indexRequests, 1);
      expect(initializedOcr, isFalse);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await _drainQueue(tester, queue, [if (indexing != null) indexing!]);
      await tester.runAsync(() async {
        await queue.disposeAsync();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await repo.close();
        await temporary.delete(recursive: true);
      });
    }
  });

  testWidgets('重新打开扫描PDF保留失败取消任务，分别重试与继续才恢复', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 750));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    late Directory temporary;
    late OpenNoteRepository repo;
    late model.DocumentRevision revision;
    late String filePath;
    await tester.runAsync(() async {
      temporary = await Directory.systemTemp.createTemp(
        'opennote-reader-cancel-',
      );
      repo = await OpenNoteRepository.open(rootPath: temporary.path);
      final project = await repo.createProject('显式取消回归');
      final document = await repo.importPdf(
        projectId: project.id,
        filePath: File('test/ocr/fixtures/scanned_rotated.pdf').absolute.path,
      );
      revision = await repo.getRevision(document.activeRevisionId);
      filePath = await repo.resourcePath(revision.resourceId);
      final geometry = await PdfReadEngine.loadSourceGeometry(filePath);
      await repo.setRevisionMetadata(
        revision.id,
        pageCount: geometry.length,
        pageGeometry: geometry,
      );
      revision = await repo.getRevision(revision.id);
      final tasks = await repo.enqueueOcr(revision.id, [
        0,
        1,
        2,
        3,
      ], modelVersion: OcrQueueController.modelVersion);
      final failed = tasks.singleWhere((task) => task.pageIndex == 1);
      await repo.claimOcrTask(failed.id, sessionId: repo.sessionId);
      await repo.failOcrTask(failed.id, '可重试测试故障', sessionId: repo.sessionId);
      await repo.cancelOcr(revisionId: revision.id);
    });
    var initializedOcr = 0;
    final queue = OcrQueueController(
      repo,
      serviceFactory: () {
        initializedOcr++;
        return NativeOcrService.create(
          libraryPath: File('native/build/Release/opennote_ocr.dll')
              .absolute
              .path,
          modelDirectory: Directory('assets/ocr/models/PP-OCRv6_small')
              .absolute
              .path,
        );
      },
    );
    Future<void>? indexing;
    var indexRequests = 0;
    var initialReady = 0;
    final requestedPages = <int>{};
    final admissions = <Future<void>>[];
    Widget reader(int opening) => MaterialApp(
      home: Scaffold(
        body: ReaderPane(
          key: ValueKey(opening),
          revisionId: revision.id,
          filePath: filePath,
          pageGeometry: revision.pageGeometry,
          onExcerpt: (_) {},
          onInitialPageReady: () => initialReady++,
          onTextLayerRequested: (page) {
            requestedPages.add(page);
            return repo.loadTextLayers(revision.id, pageIndex: page);
          },
          onIndexingRequested: (page) {
            indexRequests++;
            indexing = queue.enqueueRevision(
              revision.id,
              priorityPage: page,
              retryIncomplete: false,
            );
            admissions.add(indexing!);
          },
        ),
      ),
    );
    try {
      for (var opening = 1; opening <= 2; opening++) {
        requestedPages.clear();
        await tester.pumpWidget(reader(opening));
        await _pumpUntil(
          tester,
          () =>
              indexRequests == opening &&
              initialReady == opening &&
              requestedPages.contains(1),
        );
        await _drainQueue(tester, queue, admissions);
        await tester.runAsync(() async {
          final tasks = await repo.listOcrTasks(revisionId: revision.id);
          expect(
            tasks.where((task) => task.status == model.OcrTaskStatus.failed),
            hasLength(1),
          );
          expect(
            tasks.where((task) => task.status == model.OcrTaskStatus.cancelled),
            hasLength(3),
          );
          expect(await repo.loadTextLayers(revision.id), isEmpty);
        });
        expect(initializedOcr, 0);
      }
      await tester.tap(find.byTooltip('更多阅读工具'));
      await tester.pumpAndSettle();
      expect(find.text('识别本页'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      admissions.add(queue.retryRevision(revision.id, status: model.OcrTaskStatus.failed));
      await _drainQueue(tester, queue, admissions);
      await tester.runAsync(() async {
        expect(queue.lastError, isNull);
        final layers = await repo.loadTextLayers(revision.id);
        expect(layers, hasLength(1));
        expect(layers.single.pageIndex, 1);
        expect(layers.single.source, model.TextLayerSource.ocr);
        expect(layers.single.text, contains('离线阅读与知识整理'));
        expect(queue.retryableCountForRevision(revision.id), 3);
      });
      final retry = queue.retryRevision(revision.id, status: model.OcrTaskStatus.cancelled);
      admissions.add(retry);
      await _drainQueue(tester, queue, admissions);
      await tester.runAsync(() async {
        expect(queue.lastError, isNull);
        expect(await repo.loadTextLayers(revision.id), hasLength(4));
        expect(queue.retryableCountForRevision(revision.id), 0);
      });
      expect(initializedOcr, 1);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await _drainQueue(tester, queue, admissions);
      await tester.runAsync(() async {
        await queue.disposeAsync();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await repo.close();
        await temporary.delete(recursive: true);
      });
    }
  });

  testWidgets('真实PDF阅读器：加载前回源、鼠标选文摘录、点击高亮与窄分屏', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 750));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final changes = ValueNotifier(0);
    final controller = ReaderPaneController();
    var layers = <model.PageTextLayer>[];
    var annotations = <model.AppAnnotation>[];
    var geometry = <model.PdfPageGeometry>[];
    final excerpts = <SelectedExcerpt>[];
    final createdAnnotations = <ReaderAnnotationDraft>[];
    final activated = <model.AppAnnotation>[];
    var initialPageReadyCount = 0;
    var paneWidth = 700.0;
    await controller.jumpToAnchors([
      const model.AnchorDraft(revisionId: 'fixture', pageIndex: 1, quads: []),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<int>(
            valueListenable: changes,
            builder: (context, value, _) => Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: paneWidth,
                child: ReaderPane(
                  revisionId: 'fixture',
                  filePath: File('tools/fixtures/pdf/native.pdf').absolute.path,
                  controller: controller,
                  textLayers: layers,
                  annotations: annotations,
                  onExcerpt: excerpts.add,
                  onAnnotationCreated: createdAnnotations.add,
                  onAnnotationActivated: activated.add,
                  onInitialPageReady: () => initialPageReadyCount++,
                  onGeometryLoaded: (value) {
                    geometry = value;
                  },
                  onNativeTextLayer: (draft) async {
                    layers = [
                      ...layers.where(
                        (item) => item.pageIndex != draft.pageIndex,
                      ),
                      model.PageTextLayer(
                        id: 'layer-${draft.pageIndex}',
                        revisionId: draft.revisionId,
                        pageIndex: draft.pageIndex,
                        source: draft.source,
                        text: draft.text,
                        fragments: draft.fragments,
                        engineVersion: draft.engineVersion,
                        createdAt: DateTime.now().toUtc(),
                        parameters: draft.parameters,
                      ),
                    ];
                    changes.value++;
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );

    for (
      var attempt = 0;
      attempt < 100 && (layers.length < 2 || initialPageReadyCount == 0);
      attempt++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(layers, hasLength(2));
    expect(geometry, hasLength(2));
    expect(initialPageReadyCount, 1);
    expect(tester.takeException(), isNull);
    final viewer = tester.widget<PdfViewer>(find.byType(PdfViewer)).controller!;
    expect(viewer.pageNumber, 2, reason: '文档ready后应兑现加载前的回源请求');

    final beforeScroll = viewer.visibleRect.top;
    await tester.sendEventToBinding(
      PointerScrollEvent(
        kind: ui.PointerDeviceKind.mouse,
        position: tester.getCenter(find.byType(PdfViewer)),
        scrollDelta: const Offset(0, -80),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      viewer.visibleRect.top,
      lessThan(beforeScroll - 10),
      reason: '选文覆盖层不能吞掉鼠标滚轮',
    );

    final navigation = controller.goToPage(0);
    await tester.pumpAndSettle();
    await navigation;
    final layer = layers.firstWhere((item) => item.pageIndex == 0);
    final headingStart = layer.text.indexOf('OpenNote');
    final first = layer.fragments.firstWhere(
      (item) => item.start == headingStart,
    );
    final last = layer.fragments.firstWhere(
      (item) => item.start == headingStart + 7,
    );
    final adapter = PdfCoordinateAdapter(geometry[0]);
    Offset position(model.TextFragment fragment) {
      final center = adapter
          .quadInDocument(
            fragment.quad,
            viewer.pages[0],
            viewer.layout.pageLayouts[0],
          )
          .getBounds()
          .center;
      return tester.getTopLeft(find.byType(PdfViewer)) +
          viewer.documentToLocal(center);
    }

    final gesture = await tester.startGesture(
      position(first),
      kind: ui.PointerDeviceKind.mouse,
    );
    await gesture.moveTo(position(last));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    await tester.tap(find.byTooltip('摘录到顶层'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    expect(excerpts, hasLength(1));
    expect(excerpts.single.text, 'OpenNote');
    expect(excerpts.single.anchors.single.pageIndex, 0);
    expect(excerpts.single.anchors.single.textLayerId, 'layer-0');
    expect(excerpts.single.anchors.single.textStart, headingStart);
    expect(excerpts.single.anchors.single.textEnd, headingStart + 8);

    await tester.tap(find.byTooltip('更多阅读工具'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加文字批注'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      '独立文字批注',
    );
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(createdAnnotations.single.text, '独立文字批注');
    expect(createdAnnotations.single.kind, 'note');
    expect(tester.takeException(), isNull, reason: '文字批注退出动画期间控制器应保持有效');

    annotations = [
      model.AppAnnotation(
        id: 'annotation',
        revisionId: 'fixture',
        pageIndex: 0,
        quads: excerpts.single.anchors.single.quads,
        kind: 'highlight',
        text: '',
        color: '#F7D976',
        cardId: 'card',
      ),
    ];
    changes.value++;
    await tester.pump();
    await tester.tapAt(position(first));
    await tester.pump();
    expect(activated.single.cardId, 'card');

    paneWidth = 360;
    changes.value++;
    await tester.pump();
    expect(tester.takeException(), isNull, reason: '窄分屏工具栏不应RenderFlex溢出');
    await tester.tap(find.byTooltip('目录与缩略图'));
    await tester.pump();
    expect(tester.takeException(), isNull, reason: '窄分屏展开目录后工具栏仍应可用');
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
    expect(find.text('矩形'), findsNothing);
    expect(
      find.descendant(
        of: find.byTooltip('切换阅读工具'),
        matching: find.byIcon(Icons.crop),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    expect(initialPageReadyCount, 1, reason: '文档文字层和布局更新不得重复报告首屏就绪');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    changes.dispose();
  });

  testWidgets('真实PDF文内链接：三种工具点击、拖动摘录、批注优先与连续导航', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 750));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final changes = ValueNotifier(0);
    final controller = ReaderPaneController();
    var layers = <model.PageTextLayer>[];
    var annotations = <model.AppAnnotation>[];
    var geometry = <model.PdfPageGeometry>[];
    var ready = false;
    final excerpts = <SelectedExcerpt>[];
    final activated = <model.AppAnnotation>[];
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<int>(
              valueListenable: changes,
              builder: (context, value, _) => ReaderPane(
                revisionId: 'links-fixture',
                filePath: File('tools/fixtures/pdf/links.pdf').absolute.path,
                controller: controller,
                textLayers: layers,
                annotations: annotations,
                onExcerpt: excerpts.add,
                onAnnotationActivated: activated.add,
                onInitialPageReady: () => ready = true,
                onGeometryLoaded: (value) => geometry = value,
                onNativeTextLayer: (draft) async {
                  layers = [
                    ...layers.where(
                      (item) => item.pageIndex != draft.pageIndex,
                    ),
                    model.PageTextLayer(
                      id: 'links-layer-${draft.pageIndex}',
                      revisionId: draft.revisionId,
                      pageIndex: draft.pageIndex,
                      source: draft.source,
                      text: draft.text,
                      fragments: draft.fragments,
                      engineVersion: draft.engineVersion,
                      createdAt: DateTime.now().toUtc(),
                      parameters: draft.parameters,
                    ),
                  ];
                  changes.value++;
                },
              ),
            ),
          ),
        ),
      );
      await _pumpUntil(tester, () => ready && layers.length == 2);
      final viewer = tester
          .widget<PdfViewer>(find.byType(PdfViewer))
          .controller!;
      late List<PdfLink> links;
      await tester.runAsync(() async {
        links = await viewer.pages[0].loadLinks(enableAutoLinkDetection: false);
      });
      // 只使用 PDFium 从真正 /Link 字典读出的链接，不调用模拟 onLinkTap。
      expect(links, hasLength(4));
      final jump = links.firstWhere(
        (link) => link.dest != null && link.rects.single.bottom == 690,
      );
      final covered = links.firstWhere(
        (link) => link.dest != null && link.rects.single.bottom == 620,
      );
      final external = links.singleWhere((link) => link.url != null);
      final incomplete = links.singleWhere(
        (link) => link.rects.single.bottom == 320,
      );
      expect(jump.dest!.pageNumber, 2);
      expect(jump.rects.single.left, 70);
      expect(jump.rects.single.top, 724);
      expect(external.url.toString(), 'https://example.org/opennote-fixture');
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump();

      Offset position(PdfLink link) {
        final documentRect = link.rects.single.toRectInDocument(
          page: viewer.pages[0],
          pageRect: viewer.layout.pageLayouts[0],
        );
        return tester.getTopLeft(find.byType(PdfViewer)) +
            viewer.documentToLocal(documentRect.center);
      }

      Future<void> firstPage() async {
        var completed = false;
        final navigation = controller.goToPage(0).then((_) => completed = true);
        await _pumpUntil(tester, () => completed && viewer.pageNumber == 1);
        await navigation;
      }

      Future<void> makeVisible(PdfLink link) async {
        final documentRect = link.rects.single.toRectInDocument(
          page: viewer.pages[0],
          pageRect: viewer.layout.pageLayouts[0],
        );
        await viewer.ensureVisible(documentRect, duration: Duration.zero);
        await tester.pump();
        expect(
          tester.getRect(find.byType(PdfViewer)).contains(position(link)),
          isTrue,
          reason: '链接必须先滚入当前视口，再通过真实区域点击',
        );
      }

      Finder toolButton(String label) => find.byTooltip(label);

      for (final tool in ['选文', '矩形', '移动']) {
        await tester.tap(toolButton(tool));
        await tester.pump();
        await firstPage();
        await makeVisible(jump);
        await tester.tapAt(position(jump));
        await _pumpUntil(tester, () => viewer.pageNumber == 2);
        expect(find.text('已跳转到第 2 页'), findsNothing);
        expect(excerpts, isEmpty, reason: '$tool 模式单击链接不能创建摘录');
        await tester.pump(const Duration(milliseconds: 350));
      }

      final coveredRect = covered.rects.single;
      annotations = [
        model.AppAnnotation(
          id: 'covered-link-annotation',
          revisionId: 'links-fixture',
          pageIndex: 0,
          quads: [
            model.PdfQuad.rect(
              coveredRect.left,
              coveredRect.bottom,
              coveredRect.right,
              coveredRect.top,
            ),
          ],
          kind: 'highlight',
          text: '',
          color: '#F7D976',
          cardId: 'covered-card',
        ),
      ];
      changes.value++;
      await tester.pump();
      for (final tool in ['选文', '矩形', '移动']) {
        await tester.tap(toolButton(tool));
        await tester.pump();
        await firstPage();
        await makeVisible(covered);
        final hover = await tester.createGesture(
          kind: ui.PointerDeviceKind.mouse,
        );
        await hover.addPointer(location: position(covered));
        await hover.moveTo(position(covered));
        await tester.pump();
        expect(
          tester.binding.mouseTracker.debugDeviceActiveCursor(1),
          tool == '矩形' ? SystemMouseCursors.precise : SystemMouseCursors.click,
        );
        await hover.removePointer();
        final previous = activated.length;
        await tester.tapAt(position(covered));
        await _pumpUntil(
          tester,
          () => activated.length == previous + 1 || viewer.pageNumber == 2,
        );
        expect(activated, hasLength(previous + 1));
        expect(activated.last.cardId, 'covered-card');
        expect(viewer.pageNumber, 1, reason: '应用批注优先于重叠的页面链接');
        await tester.pump(const Duration(milliseconds: 350));
      }

      await tester.tap(toolButton('选文'));
      await tester.pump();
      await firstPage();
      final layer = layers.singleWhere((item) => item.pageIndex == 0);
      final headingStart = layer.text.indexOf('Jump');
      expect(headingStart, isNonNegative);
      final adapter = PdfCoordinateAdapter(geometry[0]);
      Offset character(int index) {
        final fragment = layer.fragments.firstWhere(
          (item) => item.start == index,
        );
        final bounds = adapter.quadInDocument(
          fragment.quad,
          viewer.pages[0],
          viewer.layout.pageLayouts[0],
        );
        return tester.getTopLeft(find.byType(PdfViewer)) +
            viewer.documentToLocal(bounds.getBounds().center);
      }

      final selection = await tester.startGesture(
        character(headingStart),
        kind: ui.PointerDeviceKind.mouse,
      );
      await selection.moveTo(character(headingStart + 3));
      await tester.pump();
      await selection.up();
      await tester.pump();
      expect(viewer.pageNumber, 1, reason: '从链接文字开始拖动仍是选文');
      await tester.tap(find.byTooltip('摘录到顶层'));
      await _pumpUntil(tester, () => excerpts.length == 1);
      expect(excerpts.single.text, 'Jump');
      expect(excerpts.single.anchors.single.pageIndex, 0);
      expect(excerpts.single.anchors.single.textLayerId, 'links-layer-0');

      await tester.tap(toolButton('矩形'));
      await tester.pump();
      final center = position(jump);
      final rectangle = await tester.startGesture(
        center - const Offset(45, 8),
        kind: ui.PointerDeviceKind.mouse,
      );
      await rectangle.moveTo(center + const Offset(45, 8));
      await tester.pump();
      await rectangle.up();
      await tester.pump();
      expect(viewer.pageNumber, 1, reason: '从链接区域开始矩形拖动不能跳页');
      await tester.tap(find.byTooltip('摘录到顶层'));
      await _pumpUntil(tester, () => excerpts.length == 2);
      expect(excerpts.last.imageBytes, isNotEmpty);
      expect(excerpts.last.imageBytes!.take(8), [
        137,
        80,
        78,
        71,
        13,
        10,
        26,
        10,
      ]);
      expect(excerpts.last.anchors.single.pageIndex, 0);

      await tester.tap(toolButton('移动'));
      await tester.pump();
      await firstPage();
      final linkDocumentRect = jump.rects.single.toRectInDocument(
        page: viewer.pages[0],
        pageRect: viewer.layout.pageLayouts[0],
      );
      await viewer.zoomUp(
        zoomCenter: linkDocumentRect.center,
        duration: Duration.zero,
      );
      await tester.pump();
      final beforePan = viewer.value.storage[13];
      final panStart = position(jump);
      expect(
        (tester.getTopLeft(find.byType(PdfViewer)) &
                tester.getSize(find.byType(PdfViewer)))
            .contains(panStart),
        isTrue,
        reason: '真实平移手势必须从当前可见链接区域开始',
      );
      final pan = await tester.startGesture(
        panStart,
        kind: ui.PointerDeviceKind.mouse,
      );
      await pan.moveBy(const Offset(0, -20));
      await tester.pump();
      await pan.moveBy(const Offset(0, -20));
      await tester.pump();
      expect(
        viewer.value.storage[13],
        isNot(closeTo(beforePan, 0.1)),
        reason: '移动工具的点击覆盖层不能阻止 Viewer 实际平移',
      );
      await pan.up();
      await tester.pumpAndSettle();
      expect(viewer.pageNumber, 1, reason: '从链接区域开始移动手势不能变成单击跳页');

      await tester.tap(toolButton('选文'));
      await tester.pump();
      await firstPage();
      await makeVisible(incomplete);
      await tester.tapAt(position(incomplete));
      await _pumpUntil(
        tester,
        () =>
            find.text('无法跳转到该文内链接').evaluate().isNotEmpty ||
            find.text('此链接没有可用的文内目标').evaluate().isNotEmpty ||
            viewer.pageNumber == 2,
      );
      expect(viewer.pageNumber, 1);
      await makeVisible(external);
      await tester.tapAt(position(external));
      await tester.pump();
      expect(
        find.text('暂不支持打开外部链接：https://example.org/opennote-fixture'),
        findsOneWidget,
      );
      expect(viewer.pageNumber, 1, reason: '外部链接不能伪装成已打开或跳到其它页面');

      for (var index = 0; index < 3; index++) {
        await makeVisible(jump);
        await tester.tapAt(position(jump));
        await firstPage();
        await tester.pump(const Duration(milliseconds: 350));
      }
      expect(viewer.pageNumber, 1, reason: '文内链接后立即导航应完成两个即时跳转');
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      changes.dispose();
    }
  });
}

// 独立函数不捕获测试的 WidgetTester/Completer，可安全传到实际 PDFium worker。
int _readerLifecycleBarrier(int value) => value;

Future<void> _drainReaderDocuments(
  WidgetTester tester,
  ReaderPaneController controller,
) async {
  var finished = false;
  Object? error;
  StackTrace? stack;
  unawaited(
    controller.drainClosedDocuments().then<void>(
      (_) {
        finished = true;
      },
      onError: (Object value, StackTrace trace) {
        error = value;
        stack = trace;
        finished = true;
      },
    ),
  );
  await _pumpUntil(tester, () => finished);
  if (error != null) Error.throwWithStackTrace(error!, stack!);
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; attempt < 500 && !condition(); attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(condition(), isTrue, reason: '真实 PDF/持久队列应在有界等待内完成');
}

Future<void> _drainQueue(
  WidgetTester tester,
  OcrQueueController queue,
  Iterable<Future<void>> admissions,
) async {
  var admitted = false;
  Object? error;
  StackTrace? stack;
  unawaited(
    Future.wait(admissions).then(
      (_) => admitted = true,
      onError: (Object value, StackTrace trace) {
        error = value;
        stack = trace;
        admitted = true;
      },
    ),
  );
  // Widget触发的原生轮询属于测试时钟，须持续pump；真实IO同时在runAsync中推进。
  await _pumpUntil(tester, () => admitted && !queue.isBusy);
  if (error != null) Error.throwWithStackTrace(error!, stack!);
  await tester.runAsync(queue.drain);
}
