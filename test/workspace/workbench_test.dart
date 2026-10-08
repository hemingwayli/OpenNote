import '../support/flutter_sdk.dart';

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as material_ui;
import 'package:opennote/data/open_note_repository.dart';
import 'package:opennote/application/ocr_queue.dart';
import 'package:opennote/domain/models.dart' as model;
import 'package:opennote/engines/ocr/ocr_service.dart';
import 'package:opennote/engines/pdf/pdf_read_engine.dart';
import 'package:opennote/ui/reader/reader_pane.dart';
import 'package:opennote/ui/map/mind_map_pane.dart';
import 'package:opennote/ui/map/map_outline_pane.dart';
import 'package:opennote/ui/workspace/card_editor.dart';
import 'package:opennote/ui/workspace/workbench.dart';
import 'package:opennote/ui/workspace/workspace_library.dart';
import 'package:opennote/ui/workspace/workbench_layout.dart';
import 'package:opennote/platform/window_fullscreen.dart';
import 'package:opennote/ui/home/app_shell.dart';
import 'package:opennote/ui/theme/open_note_theme.dart';
import 'package:opennote/ui/theme/open_note_view_switch.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:uuid/uuid.dart';

import '../support/file_selector_fixture.dart';
import '../support/map_context_menu.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late OpenNoteRepository repository;
  late FixtureFileSelector selector;
  late FileSelectorPlatform originalSelector;
  var repositoryClosed = false;
  final captureKey = GlobalKey();

  setUpAll(() async {
    Pdfrx.pdfiumModulePath = File('build/windows/x64/runner/Release/pdfium.dll')
        .absolute
        .path;
    await pdfrxInitialize();
    final sdk = flutterSdkPath();
    await (FontLoader('MaterialIcons')..addFont(
          File(
            '$sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          ).readAsBytes().then(ByteData.sublistView),
        ))
        .load();
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
      final file = File('C:/Windows/Fonts/${font.value}');
      if (file.existsSync()) {
        await (FontLoader(
          font.key,
        )..addFont(file.readAsBytes().then(ByteData.sublistView))).load();
      }
    }
  });

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('opennote-workbench-');
    repositoryClosed = false;
    repository = await OpenNoteRepository.open(
      rootPath: '${temp.path}/library',
    );
    originalSelector = FileSelectorPlatform.instance;
    selector = FixtureFileSelector();
    FileSelectorPlatform.instance = selector;
  });

  tearDown(() async {
    FileSelectorPlatform.instance = originalSelector;
    if (!repositoryClosed) await repository.close();
    await temp.delete(recursive: true);
  });

  Future<void> unmount(WidgetTester tester) async {
    final readerController = tester
        .widgetList<ReaderPane>(find.byType(ReaderPane, skipOffstage: false))
        .firstOrNull
        ?.controller;
    try {
      await tester.pumpWidget(const SizedBox.shrink());
      if (readerController != null) {
        var drained = false;
        Object? failure;
        StackTrace? trace;
        readerController.drainClosedDocuments().then(
          (_) {
            drained = true;
          },
          onError: (Object error, StackTrace stack) {
            failure = error;
            trace = stack;
            drained = true;
          },
        );
        // 原生关闭结果可能回到FakeAsync，持续绘制有界等待，不能在runAsync里死等。
        await until(tester, () async => drained);
        if (failure != null) Error.throwWithStackTrace(failure!, trace!);
      }
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(1920, 1080),
    double textScale = 1,
  }) async {
    final initialProject = (await real(
      tester,
      repository.listProjects,
    )).firstOrNull;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() async {
      await unmount(tester);
      await settleUi(tester);
      if (!repositoryClosed) {
        await real(tester, repository.close);
        repositoryClosed = true;
      }
    });
    await tester.pumpWidget(
      RepaintBoundary(
        key: captureKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: openNoteTheme(),
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            material_ui.GlobalMaterialLocalizations.delegate,
          ],
          builder: (context, child) => material_ui.Theme(
            data: material_ui.ThemeData.light(),
            child: MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
          ),
          home: OpenNoteShell(
            repository: repository,
            initialProjectId: initialProject?.id,
            ocrServiceFactory: () => NativeOcrService.create(
              libraryPath: File('native/build/Release/opennote_ocr.dll')
                  .absolute
                  .path,
              modelDirectory: Directory('assets/ocr/models/PP-OCRv6_small')
                  .absolute
                  .path,
              threads: 2,
            ),
          ),
        ),
      ),
    );
    await advance(tester);
  }

  Future<
    ({
      model.StudyProject project,
      model.MindMap map,
      model.ManagedDocument document,
      model.ExcerptResult parent,
      model.ExcerptResult source,
    })
  >
  outlineFixture(WidgetTester tester) async {
    final project = await real(tester, () => repository.createProject('图与大纲'));
    final map = (await real(
      tester,
      () => repository.listMaps(project.id),
    )).single;
    await real(
      tester,
      () => repository.setMapLayout(map.id, model.MapLayoutKind.free),
    );
    final document = await real(
      tester,
      () => repository.importPdf(
        projectId: project.id,
        filePath: File('tools/fixtures/pdf/native.pdf').absolute.path,
        pageCount: 2,
      ),
    );
    await mount(tester);
    await until(
      tester,
      () async =>
          readerReady(tester) &&
          (await repository.loadTextLayers(document.activeRevisionId)).length ==
              2,
    );
    final layer = (await real(
      tester,
      () => repository.loadTextLayers(document.activeRevisionId),
    )).singleWhere((value) => value.pageIndex == 0);
    final start = layer.text.indexOf('OpenNote');
    expect(start, greaterThanOrEqualTo(0));
    final parent = await real(
      tester,
      () => repository.createExcerpt(
        model.ExcerptDraft(
          projectId: project.id,
          mapId: map.id,
          title: '控制论中的反馈与科学方法',
          text: List.filled(8, '反馈帮助我们对照目标与实际结果，并通过观察、修正和再次验证完善认识。').join('\n'),
          anchors: const [],
          x: 80,
          y: 80,
        ),
      ),
    );
    final source = await real(
      tester,
      () => repository.createExcerpt(
        model.ExcerptDraft(
          projectId: project.id,
          mapId: map.id,
          parentNodeId: parent.node.id,
          title: '英文原文摘录与回源',
          text: 'OpenNote',
          anchors: [
            model.AnchorDraft(
              revisionId: document.activeRevisionId,
              pageIndex: 0,
              quads: layer.fragments
                  .where(
                    (value) =>
                        value.start < start + 8 &&
                        value.start + value.length > start,
                  )
                  .map((value) => value.quad)
                  .toList(),
              textLayerId: layer.id,
              textStart: start,
              textEnd: start + 8,
              context: 'OpenNote',
            ),
          ],
          x: 410,
          y: 80,
          createHighlight: true,
        ),
      ),
    );
    return (
      project: project,
      map: map,
      document: document,
      parent: parent,
      source: source,
    );
  }

  for (final width in [1920.0, 900.0]) {
    testWidgets('文字拖入工作台：${width.toInt()} 宽完整事务、来源、父级、选区和单次撤销', (tester) async {
      final project = await real(
        tester,
        () => repository.createProject('文字拖入'),
      );
      final map = (await real(
        tester,
        () => repository.listMaps(project.id),
      )).single;
      await real(
        tester,
        () => repository.setMapLayout(map.id, model.MapLayoutKind.free),
      );
      final parent = await real(
        tester,
        () => repository.createExcerpt(
          model.ExcerptDraft(
            projectId: project.id,
            mapId: map.id,
            title: '父主题',
            text: '目标正文',
            anchors: const [],
            x: 80,
            y: 80,
          ),
        ),
      );
      final document = await real(
        tester,
        () => repository.importPdf(
          projectId: project.id,
          filePath: File('tools/fixtures/pdf/native.pdf').absolute.path,
          pageCount: 2,
        ),
      );
      await mount(
        tester,
        size: Size(width, 1080),
        textScale: width == 900 ? 1.25 : 1,
      );
      await until(
        tester,
        () async =>
            readerReady(tester) &&
            (await repository.loadTextLayers(document.activeRevisionId))
                    .length ==
                2,
      );
      await idle(tester);
      final layer = (await real(
        tester,
        () => repository.loadTextLayers(document.activeRevisionId),
      )).singleWhere((l) => l.pageIndex == 0);
      final revision = await real(
        tester,
        () => repository.getRevision(document.activeRevisionId),
      );
      final fragment = layer.fragments.firstWhere(
        (f) => f.start == layer.text.indexOf('OpenNote') + 2,
      );
      final graph = tester
          .widget<MindMapPane>(find.byType(MindMapPane))
          .controller!;
      graph.setView(scale: .75, worldTopLeft: const Offset(-100, -80));
      await tester.pump();

      Future<TestGesture> dragSelection() async {
        await selectText(tester, repository, document, layer, 'OpenNote');
        expect(find.byKey(const Key('reader-selection-start')), findsOneWidget);
        final point = quadPosition(tester, document, fragment.quad, revision);
        final held = await tester.startGesture(
          point,
          kind: ui.PointerDeviceKind.mouse,
        );
        await held.moveBy(const Offset(24, 0));
        await tester.pump();
        expect(
          find.byKey(const Key('reader-text-drag-preview')),
          findsOneWidget,
        );
        return held;
      }

      final history = repository.undoEntryCount;
      final first = await dragSelection();
      final pane = tester.getRect(find.byType(MindMapPane));
      final blank = pane.topLeft + const Offset(140, 400);
      await first.moveTo(blank);
      await tester.pump();
      expect(find.text('创建顶层卡片'), findsOneWidget);
      await first.up();
      await until(
        tester,
        () async => (await repository.loadMap(map.id)).nodes.length == 2,
      );
      await until(
        tester,
        () async =>
            find.byKey(const Key('reader-selection-start')).evaluate().isEmpty,
      );
      await idle(tester);
      var snapshot = await real(tester, () => repository.loadMap(map.id));
      final top = snapshot.nodes.singleWhere((n) => n.id != parent.node.id);
      expect(top.parentNodeId, isNull);
      expect(top.x, closeTo(-100 + 140 / .75, .01));
      expect(top.y, closeTo(-80 + 400 / .75, .01));
      expect(snapshot.cards[top.cardId]!.body, 'OpenNote');
      expect(
        tester.widget<MindMapPane>(find.byType(MindMapPane)).selectedNodeId,
        top.id,
      );
      expect(repository.undoEntryCount, history + 1);
      final anchors = await real(
        tester,
        () => repository.getAnchors(top.cardId),
      );
      expect(anchors.single.textLayerId, layer.id);
      expect(anchors.single.textStart, layer.text.indexOf('OpenNote'));
      expect(anchors.single.textEnd, layer.text.indexOf('OpenNote') + 8);
      final highlights = await real(
        tester,
        () => repository.listAnnotations(document.activeRevisionId),
      );
      expect(highlights.single.cardId, top.cardId);
      await capture(
        tester,
        captureKey,
        'text-excerpt-20261006/workbench-${width.toInt()}-saved.png',
      );

      if (width == 900) {
        await real(
          tester,
          () => repository.setMapLayout(map.id, model.MapLayoutKind.right),
        );
        await until(
          tester,
          () async =>
              tester
                  .widget<MindMapPane>(find.byType(MindMapPane))
                  .snapshot
                  .map
                  .layout ==
              model.MapLayoutKind.right,
        );
        graph.fitAll();
        await tester.pump();
      }
      final beforeChild = repository.undoEntryCount;
      final second = await dragSelection();
      final childDrag = tester
          .widget<Draggable<ReaderExcerptDrag>>(
            find.byType(Draggable<ReaderExcerptDrag>).first,
          )
          .data!;
      await second.moveTo(
        tester.getCenter(find.byKey(ValueKey('map-node-${parent.node.id}'))),
      );
      await tester.pump();
      expect(find.text('加入子主题'), findsOneWidget);
      await capture(
        tester,
        captureKey,
        'text-excerpt-20261006/workbench-${width.toInt()}-drag-child.png',
      );
      await second.up();
      await until(
        tester,
        () async => (await repository.loadMap(map.id)).nodes.length == 3,
      );
      await until(
        tester,
        () async =>
            find.byKey(const Key('reader-selection-start')).evaluate().isEmpty,
      );
      await idle(tester);
      snapshot = await real(tester, () => repository.loadMap(map.id));
      final child = snapshot.nodes.singleWhere(
        (n) => n.id != parent.node.id && n.id != top.id,
      );
      expect(child.parentNodeId, parent.node.id);
      if (width == 900) {
        final arrangedParent = snapshot.nodes.singleWhere(
          (n) => n.id == parent.node.id,
        );
        expect(
          child.x,
          greaterThan(arrangedParent.x + arrangedParent.width),
          reason: '自动布局接管落点，子主题不能停留在父卡片内部',
        );
      }
      expect(
        tester.widget<MindMapPane>(find.byType(MindMapPane)).selectedNodeId,
        child.id,
      );
      expect(repository.undoEntryCount, beforeChild + 1);
      expect(
        (await real(
          tester,
          () => repository.getAnchors(child.cardId),
        )).single.textLayerId,
        childDrag.anchors.single.textLayerId,
      );
      await ctrl(tester, LogicalKeyboardKey.keyZ);
      await until(
        tester,
        () async => (await repository.loadMap(map.id)).nodes.length == 2,
      );
      expect(
        (await real(
          tester,
          () => repository.listAnnotations(document.activeRevisionId),
        )).single.cardId,
        top.cardId,
      );
      expect(tester.takeException(), isNull);
      await unmount(tester);
    });
  }

  testWidgets('文字拖入工作台：真实保存失败完整回滚，选区可重试且隐藏画布取消旧拖动', (tester) async {
    final project = await real(tester, () => repository.createProject('文字回滚'));
    final map = (await real(
      tester,
      () => repository.listMaps(project.id),
    )).single;
    final document = await real(
      tester,
      () => repository.importPdf(
        projectId: project.id,
        filePath: File('tools/fixtures/pdf/native.pdf').absolute.path,
        pageCount: 2,
      ),
    );
    await mount(tester);
    await until(
      tester,
      () async =>
          readerReady(tester) &&
          (await repository.loadTextLayers(document.activeRevisionId)).length ==
              2,
    );
    await idle(tester);
    final layer = (await real(
      tester,
      () => repository.loadTextLayers(document.activeRevisionId),
    )).first;
    final revision = await real(
      tester,
      () => repository.getRevision(document.activeRevisionId),
    );
    final fragment = layer.fragments.firstWhere(
      (f) => f.start == layer.text.indexOf('OpenNote') + 2,
    );
    final database = sqlite.sqlite3.open(
      '${repository.libraryPath}/library.sqlite',
    );
    database.execute(
      "CREATE TRIGGER reject_text_drop BEFORE INSERT ON cards BEGIN SELECT RAISE(ABORT, '验证摘录保存失败'); END",
    );
    final history = repository.undoEntryCount;
    await selectText(tester, repository, document, layer, 'OpenNote');
    Future<TestGesture> start() async {
      final held = await tester.startGesture(
        quadPosition(tester, document, fragment.quad, revision),
        kind: ui.PointerDeviceKind.mouse,
      );
      await held.moveBy(const Offset(24, 0));
      await tester.pump();
      expect(find.byKey(const Key('reader-text-drag-preview')), findsOneWidget);
      return held;
    }

    try {
      final rejected = await start();
      await rejected.moveTo(tester.getCenter(find.byType(MindMapPane)));
      await rejected.up();
      await until(
        tester,
        () async => find.textContaining('验证摘录保存失败').evaluate().isNotEmpty,
      );
      expect(
        (await real(tester, () => repository.loadMap(map.id))).nodes,
        isEmpty,
      );
      expect(
        await real(tester, () => repository.listCards(project.id)),
        isEmpty,
      );
      expect(
        await real(
          tester,
          () => repository.listAnnotations(document.activeRevisionId),
        ),
        isEmpty,
      );
      expect(repository.undoEntryCount, history);
      expect(find.byKey(const Key('reader-selection-start')), findsOneWidget);
      expect(find.byKey(const Key('reader-text-drag-preview')), findsNothing);
      database.execute('DROP TRIGGER reject_text_drop');
      final retry = await start();
      await retry.moveTo(tester.getCenter(find.byType(MindMapPane)));
      await retry.up();
      await until(
        tester,
        () async => (await repository.loadMap(map.id)).nodes.length == 1,
      );
      await until(
        tester,
        () async =>
            find.byKey(const Key('reader-selection-start')).evaluate().isEmpty,
      );
      expect(repository.undoEntryCount, history + 1);
      await idle(tester);
      await selectText(tester, repository, document, layer, 'OpenNote');
      final stale = await start();
      // 在鼠标仍按下时经正式页头命令切换大纲，旧拖动必须失效。
      await tester.tap(find.byTooltip('大纲').last);
      await tester.pump();
      await until(
        tester,
        () async => find.byType(MapOutlinePane).evaluate().isNotEmpty,
      );
      await stale.moveTo(tester.getCenter(find.byType(MapOutlinePane)));
      await stale.up();
      await tester.pump();
      expect(
        (await real(tester, () => repository.loadMap(map.id))).nodes,
        hasLength(1),
      );
      expect(repository.undoEntryCount, history + 1);
      expect(find.byKey(const Key('reader-text-drag-preview')), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      database.close();
      await unmount(tester);
    }
  });

  testWidgets('界面精简：保存浮层计时、失败保留与切卡片项目隔离且画布不跳动', (tester) async {
    final project = await real(tester, () => repository.createProject('安静反馈'));
    final map = (await real(
      tester,
      () => repository.listMaps(project.id),
    )).single;
    final cards = <model.ExcerptResult>[];
    for (var i = 0; i < 2; i++) {
      cards.add(
        await real(
          tester,
          () => repository.createExcerpt(
            model.ExcerptDraft(
              projectId: project.id,
              mapId: map.id,
              title: '主题$i',
              text: '正文',
              anchors: const [],
              x: 80 + i * 300,
              y: 80,
            ),
          ),
        ),
      );
    }
    await mount(tester);
    await until(
      tester,
      () async => find
          .byKey(ValueKey('map-node-${cards.first.node.id}'))
          .evaluate()
          .isNotEmpty,
    );
    expect(find.byKey(const Key('workspace-save-feedback')), findsNothing);
    await clickMapNode(tester, cards.first.node.id);
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await until(
      tester,
      () async => find.byType(CardEditor).evaluate().isNotEmpty,
    );
    final oldEditor = tester.widget<CardEditor>(find.byType(CardEditor));
    final canvas = tester.getRect(find.byType(MindMapPane));
    oldEditor.onSaveState('待保存…');
    await tester.pump();
    expect(find.text('待保存…'), findsOneWidget);
    expect(tester.getRect(find.byType(MindMapPane)), canvas);
    oldEditor.onSaveState('正在保存…');
    await tester.pump();
    expect(find.text('正在保存…'), findsOneWidget);
    oldEditor.onSaveState('资料已保存');
    await tester.pump(const Duration(milliseconds: 1400));
    expect(find.text('资料已保存'), findsOneWidget);
    oldEditor.onSaveState('待保存…');
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('待保存…'), findsOneWidget, reason: '旧成功计时器不能清掉新草稿状态');
    oldEditor.onSaveState('保存失败：测试故障');
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('保存失败：测试故障'), findsOneWidget);
    oldEditor.onSaveState('资料已保存');
    await tester.pump(const Duration(milliseconds: 1501));
    expect(find.byKey(const Key('workspace-save-feedback')), findsNothing);
    expect(tester.getRect(find.byType(MindMapPane)), canvas);
    oldEditor.onSaveState('资料已保存');
    await clickMapNode(tester, cards.last.node.id);
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await until(
      tester,
      () async =>
          tester.widget<CardEditor>(find.byType(CardEditor)).card.id ==
          cards.last.card.id,
    );
    final editor = tester.widget<CardEditor>(find.byType(CardEditor));
    editor.onSaveState('待保存…');
    oldEditor.onSaveState('保存失败：迟到的旧卡片');
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('待保存…'), findsOneWidget);
    expect(find.text('保存失败：迟到的旧卡片'), findsNothing);
    final nextProject = await real(
      tester,
      () => repository.createProject('新反馈项目'),
    );
    final nextMap = (await real(
      tester,
      () => repository.listMaps(nextProject.id),
    )).single;
    final nextCard = await real(
      tester,
      () => repository.createExcerpt(
        model.ExcerptDraft(
          projectId: nextProject.id,
          mapId: nextMap.id,
          title: '新项目主题',
          text: '新正文',
          anchors: const [],
          x: 80,
          y: 80,
        ),
      ),
    );
    editor.onSaveState('资料已保存');
    await returnHome(tester);
    await openHomeProject(tester, nextProject.id);
    expect(find.byKey(const Key('workspace-save-feedback')), findsNothing);
    await clickMapNode(tester, nextCard.node.id);
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await until(
      tester,
      () async => find.byType(CardEditor).evaluate().isNotEmpty,
    );
    final nextEditor = tester.widget<CardEditor>(find.byType(CardEditor));
    nextEditor.onSaveState('待保存…');
    editor.onSaveState('保存失败：迟到的旧项目');
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('待保存…'), findsOneWidget);
    expect(find.text('保存失败：迟到的旧项目'), findsNothing);
    await unmount(tester);
  });

  testWidgets('文字处理状态：自动启动、失败重试、取消后继续及当前文档进度', (tester) async {
    final project = await real(tester, () => repository.createProject('识别入口'));
    final queue = _UiOcrQueue(repository);
    var queueCleaned = false;
    await tester.binding.setSurfaceSize(const Size(900, 720));
    tester.platformDispatcher.textScaleFactorTestValue = 1.25;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() async {
      if (!queueCleaned) {
        await unmount(tester);
        await real(tester, queue.disposeAsync);
      }
      if (!repositoryClosed) {
        await real(tester, repository.close);
        repositoryClosed = true;
      }
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: openNoteTheme(),
        home: Workbench(
          repository: repository,
          projectId: project.id,
          ocr: queue,
          controller: WorkbenchController(),
          onReturnHome: () async {},
        ),
      ),
    );
    await until(
      tester,
      () async =>
          find.byKey(const Key('workspace-map-header')).evaluate().isNotEmpty,
    );
    // 入口测试先收起空阅读区，避免把原生文档关闭及后台识别混入显示合同。
    await tester.tap(find.byTooltip('显示 / 收起文档'));
    await tester.pump();
    await tester.binding.setSurfaceSize(const Size(600, 720));
    await tester.pump();
    await tester.tap(find.byKey(const Key('workspace-more-actions')));
    await settleUi(tester);
    expect(
      find.widgetWithText(CheckedPopupMenuItem<String>, '文档阅读'),
      findsOneWidget,
    );
    expect(
      find.widgetWithText(CheckedPopupMenuItem<String>, '脑图'),
      findsOneWidget,
    );
    final pdfMenuItem = find.widgetWithText(
      CheckedPopupMenuItem<String>,
      '文档阅读',
    );
    expect(
      tester.widget<CheckedPopupMenuItem<String>>(pdfMenuItem).checked,
      isFalse,
    );
    await tester.tap(pdfMenuItem);
    await settleUi(tester);
    await tester.tap(find.byKey(const Key('workspace-more-actions')));
    await settleUi(tester);
    expect(
      tester.widget<CheckedPopupMenuItem<String>>(pdfMenuItem).checked,
      isTrue,
    );
    await tester.tap(pdfMenuItem);
    await settleUi(tester);
    queue.publish(busy: true);
    selector.importPaths = [
      File('tools/fixtures/pdf/native.pdf').absolute.path,
    ];
    // 一体式窗口在 600 宽时将辅助资料入口收进更多菜单。
    await tester.tap(find.byKey(const Key('workspace-more-actions')));
    await settleUi(tester);
    await tester.tap(find.text('资料面板'));
    await settleUi(tester);
    await tester.tap(find.byKey(const Key('workspace-library-import-pdf')));
    await until(
      tester,
      () async => (await repository.listDocuments(project.id)).length == 1,
    );
    await idle(tester);
    final document = (await real(
      tester,
      () => repository.listDocuments(project.id),
    )).single;
    tester.state<ScaffoldState>(find.byType(Scaffold)).closeDrawer();
    await settleUi(tester);
    expect(find.byType(ReaderPane), findsNothing);
    await tester.tap(find.byKey(const Key('workspace-ocr-menu')));
    await settleUi(tester);
    expect(find.text('识别全文'), findsNothing);
    expect(find.text('文字处理中 1/2 页'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settleUi(tester);
    expect(queue.requested, document.activeRevisionId);
    queue.failedPages = 1;
    queue.publish(busy: false, error: '测试识别故障');
    await tester.pump();
    await tester.tap(find.byKey(const Key('workspace-ocr-menu')));
    await settleUi(tester);
    expect(find.text('测试识别故障'), findsOneWidget);
    expect(find.text('文字处理失败 1 页'), findsOneWidget);
    await tester.tap(find.text('重试失败页面（1 页）'));
    await settleUi(tester);
    expect(queue.retried, document.activeRevisionId);
    expect(queue.retriedStatus, model.OcrTaskStatus.failed);
    queue.publish(busy: true);
    await tester.pump();
    expect(find.byKey(const Key('workspace-ocr-menu')), findsOneWidget);
    await tester.tap(find.byKey(const Key('workspace-ocr-menu')));
    await settleUi(tester);
    expect(find.text('文字处理中 1/2 页'), findsOneWidget);
    await tester.tap(find.text('取消处理'));
    await settleUi(tester);
    expect(queue.cancelled, isTrue);
    expect(queue.cancelledRevision, document.activeRevisionId);
    expect(find.byKey(const Key('workspace-ocr-menu')), findsOneWidget);
    expect(find.byTooltip('文字已就绪'), findsNothing);
    await tester.tap(find.byKey(const Key('workspace-ocr-menu')));
    await settleUi(tester);
    expect(find.text('处理已取消，剩余 1 页'), findsOneWidget);
    await tester.tap(find.text('继续处理（1 页）'));
    await settleUi(tester);
    expect(queue.retriedStatus, model.OcrTaskStatus.cancelled);

    // 其他文档的任务和错误不能冒充当前文档的状态。
    queue.requested = '其他文档';
    queue.failedPages = 1;
    queue.publish(busy: false, error: '其他文档故障');
    await tester.pump();
    expect(find.byKey(const Key('workspace-ocr-menu')), findsNothing);
    queue.requested = document.activeRevisionId;
    queue.failedPages = 0;
    queue.completedPages = 2;
    queue.publish(busy: false);
    await tester.pump();
    expect(
      find.byKey(const Key('workspace-ocr-menu')),
      findsNothing,
      reason: '当前文档完成后收起页头活动入口',
    );
    expect(find.text('文字识别完成'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('文字识别完成'), findsNothing);
    await tester.tap(find.byKey(const Key('workspace-more-actions')));
    await settleUi(tester);
    await tester.tap(find.text('文字识别状态'));
    await settleUi(tester);
    expect(find.text('文字已就绪'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '关闭'));
    await settleUi(tester);
    await tester.tap(find.byKey(const Key('workspace-more-actions')));
    await settleUi(tester);
    await tester.tap(find.widgetWithText(CheckedPopupMenuItem<String>, '文档阅读'));
    await until(tester, () async => readerReady(tester));
    await until(
      tester,
      () async =>
          (await repository.loadTextLayers(document.activeRevisionId)).length ==
          2,
    );
    expect(
      tester.widget<ReaderPane>(find.byType(ReaderPane)).documentActions,
      isNull,
      reason: '阅读器内也移除已完成按钮，不留固定占位',
    );
    queue.failedPages = 1;
    queue.completedPages = 1;
    queue.publish(busy: false, error: '阅读区识别失败');
    await tester.pump();
    expect(find.byKey(const Key('workspace-ocr-menu')), findsOneWidget);
    queue.failedPages = 0;
    queue.completedPages = 2;
    queue.publish(busy: false);
    await tester.pump();
    expect(find.byKey(const Key('workspace-ocr-menu')), findsNothing);
    expect(
      tester.widget<ReaderPane>(find.byType(ReaderPane)).documentActions,
      isNull,
    );
    expect(tester.takeException(), isNull);
    await idle(tester);
    await unmount(tester);
    await real(tester, queue.disposeAsync);
    queueCleaned = true;
    // 在 FakeAsync 仍可推进时排空后台写入，避免框架收尾等待尚未完成的库关闭。
    await real(tester, repository.close);
    repositoryClosed = true;
  });

  Future<
    ({
      model.StudyProject project,
      model.MindMap map,
      List<model.ExcerptResult> cards,
    })
  >
  panelFixture(WidgetTester tester) async {
    final project = await real(tester, () => repository.createProject('常驻面板'));
    final map = (await real(
      tester,
      () => repository.listMaps(project.id),
    )).single;
    await real(
      tester,
      () => repository.setMapLayout(map.id, model.MapLayoutKind.free),
    );
    final cards = <model.ExcerptResult>[];
    for (var i = 0; i < 3; i++) {
      cards.add(
        await real(
          tester,
          () => repository.createExcerpt(
            model.ExcerptDraft(
              projectId: project.id,
              mapId: map.id,
              title: '常驻主题$i',
              text: '原正文$i',
              anchors: const [],
              x: 80 + i * 300,
              y: 80,
            ),
          ),
        ),
      );
    }
    await mount(tester);
    await clickMapNode(tester, cards.first.node.id);
    await completedMapMouseClick(
      tester,
      cards.first.node.id,
      const Duration(seconds: 10),
    );
    await completedMapMouseClick(
      tester,
      cards.first.node.id,
      const Duration(milliseconds: 10200),
    );
    await until(
      tester,
      () async => find.byType(CardEditor).evaluate().isNotEmpty,
    );
    await idle(tester);
    return (project: project, map: map, cards: cards);
  }

  testWidgets('常驻卡片面板：单击先保存多条草稿，空白PDF视图切换不关闭，切图删除显示空面板', (tester) async {
    final fixture = await panelFixture(tester);
    final first = fixture.cards.first;
    final second = fixture.cards[1];
    tester
        .widget<MindMapPane>(find.byType(MindMapPane))
        .controller!
        .centerOnNode(second.node.id);
    await advance(tester);
    final canvas = tester.getRect(find.byType(MindMapPane));
    await tester.enterText(find.byKey(const Key('card-title')), '切卡前的新标题');
    await tester.enterText(find.byKey(const Key('card-body')), '切卡前的正文');
    await tester.enterText(find.byKey(const Key('card-note')), '第一条尚未自动保存');
    await tester.tap(find.byTooltip('添加个人思考'));
    await tester.pump();
    final thoughts = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.focusNode?.debugLabel == 'OpenNote 个人思考',
    );
    await tester.enterText(thoughts.last, '第二条尚未自动保存');
    await completedMapMouseClick(
      tester,
      second.node.id,
      const Duration(seconds: 12),
    );
    await until(
      tester,
      () async =>
          tester.widget<CardEditor>(find.byType(CardEditor)).card.id ==
          second.card.id,
    );
    final saved = await real(tester, () => repository.getCard(first.card.id));
    expect(saved.title, '切卡前的新标题');
    expect(saved.body, '切卡前的正文');
    expect(saved.thoughts.map((value) => value.text), [
      '第一条尚未自动保存',
      '第二条尚未自动保存',
    ]);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('card-body')))
          .focusNode!
          .hasFocus,
      isFalse,
    );
    expect(tester.getRect(find.byType(MindMapPane)), canvas);
    final secondState = tester.state(find.byType(CardEditor));
    final point =
        tester.getBottomRight(find.byType(MindMapPane)) - const Offset(20, 90);
    for (final card in fixture.cards) {
      expect(
        tester
            .getRect(find.byKey(ValueKey('map-node-${card.node.id}')))
            .contains(point),
        isFalse,
        reason: '清空选择必须点击真实空白，不能误点其他卡片',
      );
    }
    await tester.tapAt(point, kind: ui.PointerDeviceKind.mouse);
    await until(
      tester,
      () async =>
          tester.widget<MindMapPane>(find.byType(MindMapPane)).selectedNodeId ==
          null,
    );
    expect(tester.state(find.byType(CardEditor)), same(secondState));
    expect(
      tester.widget<CardEditor>(find.byType(CardEditor)).card.id,
      second.card.id,
    );
    final history = repository.undoEntryCount;
    await tester.tap(find.byTooltip('显示 / 收起文档'));
    await tester.pump();
    await switchMapView(tester, outline: true);
    await switchMapView(tester, outline: false);
    expect(tester.state(find.byType(CardEditor)), same(secondState));
    expect(repository.undoEntryCount, history);
    final otherMap = await real(
      tester,
      () => repository.createMap(fixture.project.id, '新的空脑图'),
    );
    await until(
      tester,
      () async =>
          find.widgetWithText(ListTile, otherMap.title).evaluate().isNotEmpty,
    );
    await tester.tap(find.widgetWithText(ListTile, otherMap.title));
    await until(
      tester,
      () async => find.byType(CardEditorPlaceholder).evaluate().isNotEmpty,
    );
    expect(find.byKey(const Key('workspace-card-editor')), findsOneWidget);
    expect(find.text('请选择卡片'), findsOneWidget);
    await tester.tap(find.widgetWithText(ListTile, fixture.map.title));
    await until(
      tester,
      () async =>
          tester
              .widget<MindMapPane>(find.byType(MindMapPane))
              .snapshot
              .map
              .id ==
          fixture.map.id,
    );
    await clickMapNode(tester, second.node.id);
    expect(
      tester.widget<CardEditor>(find.byType(CardEditor)).card.id,
      second.card.id,
    );
    await tester.tap(find.byTooltip('收起编辑'));
    await until(
      tester,
      () async =>
          find.byKey(const Key('workspace-card-editor')).evaluate().isEmpty,
    );
    await clickMapNode(tester, first.node.id);
    expect(find.byType(CardEditor), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await until(
      tester,
      () async => find.byType(CardEditor).evaluate().isNotEmpty,
    );
    await tester.tap(find.byType(MindMapPane));
    await clickMapNode(tester, first.node.id);
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await until(
      tester,
      () async => find.byType(CardEditorPlaceholder).evaluate().isNotEmpty,
    );
    expect(find.byKey(const Key('workspace-card-editor')), findsOneWidget);
    await returnHome(tester);
    await openHomeProject(tester, fixture.project.id);
    expect(find.byKey(const Key('workspace-card-editor')), findsNothing);
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('常驻卡片面板：切卡与关闭保存失败保留原卡草稿，修复后重试', (tester) async {
    final fixture = await panelFixture(tester);
    final first = fixture.cards.first;
    final second = fixture.cards[1];
    tester
        .widget<MindMapPane>(find.byType(MindMapPane))
        .controller!
        .centerOnNode(second.node.id);
    await advance(tester);
    final db = sqlite.sqlite3.open('${repository.libraryPath}/library.sqlite');
    try {
      db.execute(
        "CREATE TRIGGER reject_panel_save BEFORE UPDATE OF body ON cards "
        "WHEN OLD.id='${first.card.id}' BEGIN SELECT RAISE(ABORT, '验证面板保存失败'); END",
      );
      await tester.enterText(find.byKey(const Key('card-body')), '不能丢失的正文');
      await tester.enterText(find.byKey(const Key('card-note')), '不能丢失的个人思考');
      await completedMapMouseClick(
        tester,
        second.node.id,
        const Duration(seconds: 13),
      );
      await until(
        tester,
        () async => find.textContaining('验证面板保存失败').evaluate().isNotEmpty,
      );
      expect(
        tester.widget<CardEditor>(find.byType(CardEditor)).card.id,
        first.card.id,
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('card-body')))
            .controller!
            .text,
        '不能丢失的正文',
      );
      await tester.tap(find.byTooltip('关闭错误提示'));
      await tester.pump();
      await tester.tap(find.byTooltip('收起编辑'));
      await idle(tester);
      expect(find.byType(CardEditor), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('card-note')))
            .controller!
            .text,
        '不能丢失的个人思考',
      );
      await until(
        tester,
        () async => find.byTooltip('关闭错误提示').evaluate().isNotEmpty,
      );
      // 局部关闭不显示全局忙碌；明确等第二次失败回滚后再解除故障注入。
      db.execute('DROP TRIGGER reject_panel_save');
      await tester.tap(find.byTooltip('关闭错误提示'));
      await tester.pump();
      await tester.tap(find.byTooltip('收起编辑'));
      await until(
        tester,
        () async =>
            find.byKey(const Key('workspace-card-editor')).evaluate().isEmpty,
      );
      final saved = await real(tester, () => repository.getCard(first.card.id));
      expect(saved.body, '不能丢失的正文');
      expect(saved.thoughts.single.text, '不能丢失的个人思考');
    } finally {
      db.close();
    }
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('常驻卡片面板：排队快速切卡不抢焦点，旧改色请求与恢复会话失效', (tester) async {
    final fixture = await panelFixture(tester);
    final oldEditor = tester.widget<CardEditor>(find.byType(CardEditor));
    final flush = oldEditor.controller.flushDelegate!;
    final gate = Completer<void>();
    oldEditor.controller.flushDelegate = () async {
      await gate.future;
      await flush();
    };
    await tester.enterText(find.byKey(const Key('card-body')), '排队前必须保存');
    final pane = tester.widget<MindMapPane>(find.byType(MindMapPane));
    pane.onSelect(
      pane.snapshot.nodes.singleWhere(
        (node) => node.id == fixture.cards[1].node.id,
      ),
    );
    pane.onSelect(
      pane.snapshot.nodes.singleWhere(
        (node) => node.id == fixture.cards[2].node.id,
      ),
    );
    gate.complete();
    await until(
      tester,
      () async =>
          tester.widget<CardEditor>(find.byType(CardEditor)).card.id ==
          fixture.cards[2].card.id,
    );
    expect(
      (await real(
        tester,
        () => repository.getCard(fixture.cards.first.card.id),
      )).body,
      '排队前必须保存',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('card-body')))
          .focusNode!
          .hasFocus,
      isFalse,
    );
    final history = repository.undoEntryCount;
    await expectLater(oldEditor.onColorChanged!('#80B9EB'), throwsStateError);
    expect(repository.undoEntryCount, history);
    final currentEditor = tester.widget<CardEditor>(find.byType(CardEditor));
    final backup = '${temp.path}/panel-session.onbackup';
    await real(tester, () => repository.backupTo(backup));
    await real(tester, () => repository.restoreFrom(backup));
    await until(tester, () async => find.byType(Workbench).evaluate().isEmpty);
    await expectLater(
      currentEditor.onColorChanged!('#91C69A'),
      throwsStateError,
    );
    expect(repository.undoEntryCount, 0);
    expect(
      (await real(
        tester,
        () => repository.getCard(fixture.cards[2].card.id),
      )).color,
      fixture.cards[2].card.color,
    );
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('已有卡双击工作台：首击回源第二击正文焦点且旧草稿保存到原卡', (tester) async {
    final fixture = await outlineFixture(tester);
    await clickMapNode(tester, fixture.parent.node.id);
    expect(find.byTooltip('摘录到${fixture.parent.card.title}'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await until(
      tester,
      () async => find.byType(CardEditor).evaluate().isNotEmpty,
    );
    await idle(tester);
    tester
        .widget<MindMapPane>(find.byType(MindMapPane))
        .controller!
        .centerOnNode(fixture.source.node.id);
    await advance(tester);
    final viewer = tester.widget<PdfViewer>(find.byType(PdfViewer)).controller!;
    await real(
      tester,
      () => viewer.goToPage(pageNumber: 2, duration: Duration.zero),
    );
    await until(tester, () async => viewer.pageNumber == 2);
    final history = repository.undoEntryCount;
    await tester.enterText(find.byKey(const Key('card-body')), '500ms草稿只属于原卡');
    await completedMapMouseClick(
      tester,
      fixture.source.node.id,
      const Duration(seconds: 1),
    );
    await until(tester, () async => viewer.pageNumber == 1);
    await idle(tester);
    expect(
      tester.widget<CardEditor>(find.byType(CardEditor)).card.id,
      fixture.source.card.id,
    );
    expect(find.byTooltip('摘录到${fixture.source.card.title}'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('card-body')))
          .focusNode!
          .hasFocus,
      isFalse,
    );
    expect(
      (await real(
        tester,
        () => repository.getCard(fixture.parent.card.id),
      )).body,
      '500ms草稿只属于原卡',
    );
    expect(
      (await real(
        tester,
        () => repository.getCard(fixture.source.card.id),
      )).body,
      'OpenNote',
    );
    // 同一次双击中先观察原生首击导航，再移回第二页，区分第二击是否重复回源。
    await real(
      tester,
      () => viewer.goToPage(pageNumber: 2, duration: Duration.zero),
    );
    await until(tester, () async => viewer.pageNumber == 2);
    await completedMapMouseClick(
      tester,
      fixture.source.node.id,
      const Duration(milliseconds: 1200),
    );
    await until(
      tester,
      () async =>
          tester.widget<CardEditor>(find.byType(CardEditor)).card.id ==
              fixture.source.card.id &&
          tester
              .widget<TextField>(find.byKey(const Key('card-body')))
              .focusNode!
              .hasFocus,
    );
    await idle(tester);
    expect(viewer.pageNumber, 2, reason: '完成第二击只编辑明确卡片，不重复首击回源');
    expect(repository.undoEntryCount, history + 1, reason: '编辑焦点不生成业务历史');
    final editorState = tester.state(find.byType(CardEditor));
    await tester.tap(
      find.byKey(const Key('card-note')),
      kind: ui.PointerDeviceKind.mouse,
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('card-body')))
          .focusNode!
          .hasFocus,
      isFalse,
    );
    await completedMapMouseClick(
      tester,
      fixture.source.node.id,
      const Duration(seconds: 2),
    );
    await idle(tester);
    await completedMapMouseClick(
      tester,
      fixture.source.node.id,
      const Duration(milliseconds: 2200),
    );
    await until(
      tester,
      () async => tester
          .widget<TextField>(find.byKey(const Key('card-body')))
          .focusNode!
          .hasFocus,
    );
    expect(
      tester.state(find.byType(CardEditor)),
      same(editorState),
      reason: '同卡重复编辑复用实际编辑器和正文State',
    );
    await idle(tester);
    await tester.pump();
    expect(
      tester.getCenter(find.byType(PdfViewer)).dx,
      lessThan(tester.getCenter(find.byType(MindMapPane)).dx),
    );
    final imageName = 'workbench-existing-double-body-${const Uuid().v4()}.png';
    await capture(tester, captureKey, imageName);
    debugPrint(
      'existing-double-body screenshot=${File('.local/verification/$imageName').absolute.path}',
    );
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('已有卡双击工作台：打开后立即鼠标输入备注不会写入正文', (tester) async {
    final fixture = await outlineFixture(tester);
    final original = await real(
      tester,
      () => repository.getCard(fixture.source.card.id),
    );
    final originalAnchor = (await real(
      tester,
      () => repository.getAnchors(fixture.source.card.id),
    )).single;
    final history = repository.undoEntryCount;
    await until(
      tester,
      () async =>
          find.byType(MindMapPane).evaluate().isNotEmpty &&
          tester
              .widget<MindMapPane>(find.byType(MindMapPane))
              .snapshot
              .nodes
              .any((node) => node.id == fixture.source.node.id),
    );
    await idle(tester);
    final pane = tester.widget<MindMapPane>(find.byType(MindMapPane));
    pane.controller!.centerOnNode(fixture.source.node.id);
    await advance(tester);
    await tester.pump();
    await until(
      tester,
      () async => find
          .byKey(Key('map-node-${fixture.source.node.id}'))
          .evaluate()
          .isNotEmpty,
    );
    debugPrint(
      'immediate-note initial nodeRect=${tester.getRect(find.byKey(Key('map-node-${fixture.source.node.id}')))} paneRect=${tester.getRect(find.byType(MindMapPane))}',
    );
    await completedMapMouseClick(
      tester,
      fixture.source.node.id,
      const Duration(seconds: 20),
    );
    await idle(tester);
    await completedMapMouseClick(
      tester,
      fixture.source.node.id,
      const Duration(milliseconds: 20200),
    );
    // 看见编辑器就实际点击备注，不替迟到的正文焦点增加额外等待。
    await until(
      tester,
      () async => find.byType(CardEditor).evaluate().isNotEmpty,
    );
    expect(
      tester.widget<CardEditor>(find.byType(CardEditor)).card.id,
      fixture.source.card.id,
    );
    final noteField = find.byKey(const Key('card-note'));
    final point = tester.getCenter(noteField);
    expect(
      tester
          .getRect(find.byKey(const Key('workspace-card-editor')))
          .contains(point),
      isTrue,
    );
    await tester.tap(noteField, kind: ui.PointerDeviceKind.mouse);
    await tester.pump();
    tester.testTextInput.enterText('立即鼠标输入的独立备注');
    await tester.pump();
    await tester.tap(find.byTooltip('收起编辑'), kind: ui.PointerDeviceKind.mouse);
    await until(tester, () async => find.byType(CardEditor).evaluate().isEmpty);
    await idle(tester);
    final saved = await real(
      tester,
      () => repository.getCard(fixture.source.card.id),
    );
    debugPrint(
      'immediate-note SQLite body=${saved.body} note=${saved.note} excerpt=${saved.excerptSnapshot}',
    );
    expect(saved.note, '立即鼠标输入的独立备注', reason: '鼠标选中的备注框必须拥有真实TextInput连接');
    expect(saved.body, original.body, reason: '迟到的正文焦点不能把备注输入写入正文');
    expect(saved.excerptSnapshot, original.excerptSnapshot);
    expect(saved.title, original.title);
    expect(repository.undoEntryCount, history + 1);
    final anchor = (await real(
      tester,
      () => repository.getAnchors(fixture.source.card.id),
    )).single;
    expect(anchor.id, originalAnchor.id);
    expect(anchor.revisionId, originalAnchor.revisionId);
    expect(anchor.pageIndex, originalAnchor.pageIndex);
    expect(anchor.textLayerId, originalAnchor.textLayerId);
    expect(anchor.textStart, originalAnchor.textStart);
    expect(anchor.textEnd, originalAnchor.textEnd);
    expect(
      anchor.quads.map((quad) => quad.toJson()),
      originalAnchor.quads.map((quad) => quad.toJson()),
    );
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  for (final staleKind in ['切图', '恢复会话', '回收卡片']) {
    testWidgets('已有卡双击工作台：排队明确编辑遇到$staleKind拒绝旧目标且后续可编辑', (tester) async {
      final fixture = await outlineFixture(tester);
      final otherMap = await real(
        tester,
        () => repository.createMap(fixture.project.id, '排队后的另一图'),
      );
      final other = await real(
        tester,
        () => repository.createExcerpt(
          model.ExcerptDraft(
            projectId: fixture.project.id,
            mapId: otherMap.id,
            title: '另一图有效卡',
            text: '另一图正文',
            anchors: const [],
            x: 80,
            y: 80,
          ),
        ),
      );
      final backup = '${temp.path}/explicit-edit.onbackup';
      if (staleKind == '恢复会话') {
        await real(tester, () => repository.backupTo(backup));
      }
      await clickMapNode(tester, fixture.parent.node.id);
      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await until(
        tester,
        () async => find.byType(CardEditor).evaluate().isNotEmpty,
      );
      await idle(tester);
      final pane = tester.widget<MindMapPane>(find.byType(MindMapPane));
      final session = repository.sessionId;
      final database = sqlite.sqlite3.open(
        '${repository.libraryPath}/library.sqlite',
      );
      var locked = false;
      Future<void>? invalidation;
      Future<void>? initialFlush;
      try {
        database.execute('BEGIN IMMEDIATE');
        locked = true;
        await tester.enterText(
          find.byKey(const Key('card-body')),
          '旧卡接受编辑前的草稿',
        );
        final oldEditorState = tester.state(find.byType(CardEditor));
        final oldBodyFocus = tester
            .widget<TextField>(find.byKey(const Key('card-body')))
            .focusNode!;
        final oldBodyHasFocus = oldBodyFocus.hasFocus;
        if (staleKind == '切图') {
          // 真正资料列表命令先入工作台队列；明确编辑事件仍来自旧图的正式回调。
          await tester.tap(
            find.widgetWithText(ListTile, '排队后的另一图'),
            kind: ui.PointerDeviceKind.mouse,
          );
          await tester.pump();
        } else {
          // 先排一个真实草稿保存，再将恢复/回收放入SQLite队列，避免I/O时序偶然性。
          initialFlush = tester
              .widget<CardEditor>(find.byType(CardEditor))
              .controller
              .flush();
          await tester.pump();
          invalidation = staleKind == '恢复会话'
              ? repository.restoreFrom(backup)
              : repository.trashCard(fixture.source.card.id);
        }
        pane.onAction(fixture.source.node, 'edit');
        await tester.pump();
        database.execute('ROLLBACK');
        locked = false;
        final flushToWait = initialFlush;
        if (flushToWait != null) await real(tester, () => flushToWait);
        final invalidationToWait = invalidation;
        if (invalidationToWait != null) {
          await real(tester, () => invalidationToWait);
        }
        if (staleKind == '恢复会话') {
          await until(
            tester,
            () async => find.byType(Workbench).evaluate().isEmpty,
          );
        } else {
          await until(
            tester,
            () async => find
                .textContaining(staleKind == '回收卡片' ? '目标卡片已变更' : '目标脑图已切换')
                .evaluate()
                .isNotEmpty,
          );
          await idle(tester);
        }
        final remainingEditor = tester
            .widgetList<CardEditor>(find.byType(CardEditor))
            .firstOrNull;
        expect(remainingEditor?.card.id, isNot(fixture.source.card.id));
        final remainingBody = tester
            .widgetList<TextField>(find.byKey(const Key('card-body')))
            .firstOrNull;
        if (staleKind == '回收卡片') {
          expect(remainingEditor?.card.id, fixture.parent.card.id);
          expect(tester.state(find.byType(CardEditor)), same(oldEditorState));
          expect(remainingBody?.focusNode, same(oldBodyFocus));
          expect(
            remainingBody?.focusNode?.hasFocus,
            oldBodyHasFocus,
            reason: '拒绝已回收的来源卡片不应改变仍有效父卡的编辑焦点',
          );
        } else {
          expect(remainingBody?.focusNode?.hasFocus ?? false, isFalse);
        }
        if (staleKind == '恢复会话') {
          expect(repository.sessionId, isNot(session));
          expect(
            (await real(
              tester,
              () => repository.getCard(fixture.parent.card.id),
            )).body,
            fixture.parent.card.body,
          );
          expect(repository.undoEntryCount, 0);
        } else {
          expect(
            (await real(
              tester,
              () => repository.getCard(fixture.parent.card.id),
            )).body,
            '旧卡接受编辑前的草稿',
          );
        }
        final validNode = staleKind == '切图' ? other.node : fixture.parent.node;
        if (staleKind == '恢复会话') {
          await openHomeProject(tester, fixture.project.id);
        }
        await clickMapNode(tester, validNode.id);
        await tester.sendKeyEvent(LogicalKeyboardKey.f2);
        await until(
          tester,
          () async =>
              find.byType(CardEditor).evaluate().isNotEmpty &&
              tester.widget<CardEditor>(find.byType(CardEditor)).card.id ==
                  validNode.cardId &&
              tester
                  .widget<TextField>(find.byKey(const Key('card-body')))
                  .focusNode!
                  .hasFocus,
        );
        expect(tester.takeException(), isNull);
      } finally {
        if (locked) database.execute('ROLLBACK');
        database.close();
        await unmount(tester);
      }
    });
  }

  for (final secondaryRemoval in [false, true]) {
    testWidgets(
      '已有卡双击工作台：晚来${secondaryRemoval ? 'Ctrl取消次选' : '同卡单击'}取消旧正文焦点意图',
      (tester) async {
        final fixture = await outlineFixture(tester);
        await clickMapNode(tester, fixture.parent.node.id);
        if (secondaryRemoval) {
          await ctrlClickNode(
            tester,
            fixture.source.node.id,
            expected: {fixture.parent.node.id, fixture.source.node.id},
            primary: fixture.source.node.id,
          );
          await ctrlClickNode(
            tester,
            fixture.parent.node.id,
            expected: {fixture.source.node.id},
            primary: fixture.source.node.id,
          );
          await ctrlClickNode(
            tester,
            fixture.parent.node.id,
            expected: {fixture.source.node.id, fixture.parent.node.id},
            primary: fixture.parent.node.id,
          );
        }
        final selected = tester.widget<MindMapPane>(find.byType(MindMapPane));
        selected.onAction(fixture.parent.node, 'editSelected');
        await until(
          tester,
          () async => find.byType(CardEditor).evaluate().isNotEmpty,
        );
        await idle(tester);
        selected.controller!.centerOnNode(
          secondaryRemoval ? fixture.source.node.id : fixture.parent.node.id,
        );
        await advance(tester);
        final database = sqlite.sqlite3.open(
          '${repository.libraryPath}/library.sqlite',
        );
        var locked = false;
        try {
          database.execute('BEGIN IMMEDIATE');
          locked = true;
          await tester.enterText(
            find.byKey(const Key('card-body')),
            '焦点排队的原卡正文',
          );
          tester
              .widget<MindMapPane>(find.byType(MindMapPane))
              .onAction(fixture.parent.node, 'editSelected');
          if (secondaryRemoval) {
            await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
          }
          await completedMapMouseClick(
            tester,
            secondaryRemoval ? fixture.source.node.id : fixture.parent.node.id,
            const Duration(seconds: 10),
          );
          if (secondaryRemoval) {
            await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
          }
          database.execute('ROLLBACK');
          locked = false;
          await idle(tester);
          await tester.pump();
          final current = tester.widget<MindMapPane>(find.byType(MindMapPane));
          expect(current.selectedNodeId, fixture.parent.node.id);
          expect(current.selectedNodeIds, {fixture.parent.node.id});
          expect(FocusManager.instance.primaryFocus?.debugLabel, 'OpenNote 脑图');
          expect(
            tester
                .widget<TextField>(find.byKey(const Key('card-body')))
                .focusNode!
                .hasFocus,
            isFalse,
          );
          await tester.sendKeyEvent(LogicalKeyboardKey.f2);
          await until(
            tester,
            () async => tester
                .widget<TextField>(find.byKey(const Key('card-body')))
                .focusNode!
                .hasFocus,
          );
          expect(tester.takeException(), isNull);
        } finally {
          if (HardwareKeyboard.instance.isControlPressed) {
            await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
          }
          if (locked) database.execute('ROLLBACK');
          database.close();
          await unmount(tester);
        }
      },
    );
  }

  testWidgets('多选工作台：Ctrl完整点击跨画布大纲保持主选且不自动回源', (tester) async {
    final fixture = await outlineFixture(tester);
    await clickMapNode(tester, fixture.parent.node.id);
    final viewer = tester.widget<PdfViewer>(find.byType(PdfViewer)).controller!;
    await real(
      tester,
      () => viewer.goToPage(pageNumber: 2, duration: Duration.zero),
    );
    await until(tester, () async => viewer.pageNumber == 2);
    final history = repository.undoEntryCount;
    await ctrlClickNode(
      tester,
      fixture.source.node.id,
      expected: {fixture.parent.node.id, fixture.source.node.id},
      primary: fixture.source.node.id,
      releaseBeforeUp: true,
    );
    expect(viewer.pageNumber, 2, reason: 'Ctrl在pointer-down捕获，提前松开也不能自动回源');
    expect(find.byTooltip('已选 2 项'), findsOneWidget);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'OpenNote 脑图');
    await switchMapView(tester, outline: true);
    expect(
      tester
          .widget<MapOutlinePane>(find.byType(MapOutlinePane))
          .selectedNodeIds,
      unorderedEquals([fixture.parent.node.id, fixture.source.node.id]),
    );
    await ctrlClickNode(
      tester,
      fixture.parent.node.id,
      outline: true,
      expected: {fixture.source.node.id},
      primary: fixture.source.node.id,
    );
    await ctrlClickNode(
      tester,
      fixture.parent.node.id,
      outline: true,
      releaseBeforeUp: true,
      expected: {fixture.source.node.id, fixture.parent.node.id},
      primary: fixture.parent.node.id,
    );
    expect(viewer.pageNumber, 2);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'OpenNote 脑图大纲');
    await switchMapView(tester, outline: false);
    final pane = tester.widget<MindMapPane>(find.byType(MindMapPane));
    expect(
      pane.selectedNodeIds,
      unorderedEquals([fixture.source.node.id, fixture.parent.node.id]),
    );
    expect(pane.selectedNodeId, fixture.parent.node.id);
    expect(repository.undoEntryCount, history, reason: '多选和视图切换不产生业务历史');
    await clickMapNode(tester, fixture.source.node.id);
    await until(tester, () async => viewer.pageNumber == 1);
    expect(
      tester.widget<MindMapPane>(find.byType(MindMapPane)).selectedNodeIds,
      {fixture.source.node.id},
    );
    final oldEditor = await real(
      tester,
      () => repository.createExcerpt(
        model.ExcerptDraft(
          projectId: fixture.project.id,
          mapId: fixture.map.id,
          title: '快速Ctrl前的独立编辑卡',
          text: '旧编辑正文',
          anchors: const [],
          x: 80,
          y: 500,
        ),
      ),
    );
    await real(tester, () => repository.removeBranch(oldEditor.node.id));
    await tester.tap(find.byTooltip('卡片'));
    final oldEditorEntry = find.widgetWithText(ListTile, '快速Ctrl前的独立编辑卡');
    await until(tester, () async => oldEditorEntry.evaluate().isNotEmpty);
    await tester.tap(oldEditorEntry, kind: ui.PointerDeviceKind.mouse);
    await until(
      tester,
      () async =>
          find.byType(CardEditor).evaluate().isNotEmpty &&
          tester.widget<CardEditor>(find.byType(CardEditor)).card.id ==
              oldEditor.card.id,
    );
    await idle(tester);
    expect(
      tester.widget<MindMapPane>(find.byType(MindMapPane)).selectedNodeIds,
      isEmpty,
      reason: '项目中的未放置卡片可编辑，但不虚构脑图选择',
    );
    final rapidPane = find.byType(MindMapPane);
    tester.widget<MindMapPane>(rapidPane).controller!.fitAll();
    await advance(tester);
    await tester.pump();
    final first = find.byKey(Key('map-node-${fixture.parent.node.id}'));
    final second = find.byKey(Key('map-node-${fixture.source.node.id}'));
    final firstPoint = tester.getCenter(first);
    final secondPoint = tester.getCenter(second);
    for (final point in [firstPoint, secondPoint]) {
      expect(tester.getRect(rapidPane).contains(point), isTrue);
    }
    await real(
      tester,
      () => viewer.goToPage(pageNumber: 2, duration: Duration.zero),
    );
    await until(tester, () async => viewer.pageNumber == 2);
    final beforeRapid = repository.undoEntryCount;
    await tester.enterText(
      find.byKey(const Key('card-body')),
      '快速Ctrl只提交原卡的未保存正文',
    );
    expect(
      (await real(tester, () => repository.getCard(oldEditor.card.id))).body,
      '旧编辑正文',
      reason: '快速输入之前草稿尚未到自动保存时刻',
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    try {
      expect(
        tester
            .hitTestOnBinding(firstPoint)
            .path
            .any(
              (entry) => identical(entry.target, tester.renderObject(first)),
            ),
        isTrue,
      );
      final firstClick = await tester.startGesture(
        firstPoint,
        kind: ui.PointerDeviceKind.mouse,
      );
      await firstClick.up();
      await tester.pump();
      // 两次完整点击之间只绘制一帧，不等提交、选中反馈或idle。
      expect(
        tester
            .hitTestOnBinding(secondPoint)
            .path
            .any(
              (entry) => identical(entry.target, tester.renderObject(second)),
            ),
        isTrue,
      );
      final secondClick = await tester.startGesture(
        secondPoint,
        kind: ui.PointerDeviceKind.mouse,
      );
      await secondClick.up();
      await tester.pump();
    } finally {
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    }
    await until(
      tester,
      () async =>
          setEquals(tester.widget<MindMapPane>(rapidPane).selectedNodeIds, {
            fixture.parent.node.id,
            fixture.source.node.id,
          }) &&
          tester.widget<MindMapPane>(rapidPane).selectedNodeId ==
              fixture.source.node.id &&
          (await repository.getCard(oldEditor.card.id)).body ==
              '快速Ctrl只提交原卡的未保存正文',
    );
    await idle(tester);
    expect(viewer.pageNumber, 2, reason: '连续Ctrl完整点击均不能自动回源');
    expect(repository.undoEntryCount, beforeRapid + 1);
    expect(
      (await real(
        tester,
        () => repository.getCard(fixture.parent.card.id),
      )).body,
      fixture.parent.card.body,
    );
    expect(
      (await real(
        tester,
        () => repository.getCard(fixture.source.card.id),
      )).body,
      'OpenNote',
    );
    expect(
      tester.widget<CardEditor>(find.byType(CardEditor)).card.id,
      fixture.source.card.id,
    );
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('多选工作台：新增先编辑标题，F2正文后普通或Ctrl重选不抢焦点', (tester) async {
    final fixture = await outlineFixture(tester);
    await clickMapNode(tester, fixture.parent.node.id);
    await tester.sendKeyEvent(LogicalKeyboardKey.insert);
    await until(
      tester,
      () async =>
          (await repository.loadMap(fixture.map.id)).nodes.length == 3 &&
          find.byKey(const ValueKey('map-title-input')).evaluate().isNotEmpty,
    );
    await idle(tester);
    final newNode =
        (await real(
          tester,
          () => repository.loadMap(fixture.map.id),
        )).nodes.singleWhere(
          (node) =>
              node.id != fixture.parent.node.id &&
              node.id != fixture.source.node.id,
        );
    bool bodyFocused() => tester
        .widget<EditableText>(
          find.descendant(
            of: find.byKey(const Key('card-body')),
            matching: find.byType(EditableText),
          ),
        )
        .focusNode
        .hasFocus;
    final title = find.descendant(
      of: find.byKey(const ValueKey('map-title-input')),
      matching: find.byType(EditableText),
    );
    expect(
      tester.widget<EditableText>(title).focusNode.hasFocus,
      isTrue,
      reason: '新建先编辑主题标题',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await until(
      tester,
      () async =>
          find.byType(CardEditor).evaluate().isNotEmpty &&
          tester.widget<CardEditor>(find.byType(CardEditor)).card.id ==
              newNode.cardId,
    );
    expect(bodyFocused(), isTrue, reason: 'F2 保留正文焦点语义');
    await clickMapNode(tester, fixture.parent.node.id);
    await clickMapNode(tester, newNode.id);
    await tester.pump();
    expect(bodyFocused(), isFalse);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'OpenNote 脑图');
    await clickMapNode(tester, fixture.parent.node.id);
    await ctrlClickNode(
      tester,
      newNode.id,
      expected: {fixture.parent.node.id, newNode.id},
      primary: newNode.id,
    );
    expect(bodyFocused(), isFalse);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'OpenNote 脑图');
    await switchMapView(tester, outline: true);
    await clickOutlineNode(tester, fixture.parent.node.id);
    await ctrlClickNode(
      tester,
      newNode.id,
      outline: true,
      expected: {fixture.parent.node.id, newNode.id},
      primary: newNode.id,
    );
    expect(bodyFocused(), isFalse);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'OpenNote 脑图大纲');
    expect(find.byType(CardEditor), findsOneWidget);
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('多选工作台：改色先提交草稿并一次撤销，PDF标注同步与副本独立且窄窗可读', (tester) async {
    final fixture = await outlineFixture(tester);
    await real(
      tester,
      () => repository.updateCard(fixture.parent.card.id, color: '#91C69A'),
    );
    final copy = await real(
      tester,
      () => repository.copyBranch(
        fixture.source.node.id,
        fixture.map.id,
        offsetX: 0,
        offsetY: 300,
      ),
    );
    final copyCardId = copy.cardIds[fixture.source.card.id]!;
    final annotation = (await real(
      tester,
      () => repository.listAnnotations(fixture.document.activeRevisionId),
    )).single;
    await clickMapNode(tester, fixture.parent.node.id);
    await ctrlClickNode(
      tester,
      fixture.source.node.id,
      expected: {fixture.parent.node.id, fixture.source.node.id},
      primary: fixture.source.node.id,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await until(
      tester,
      () async => find.byType(CardEditor).evaluate().isNotEmpty,
    );
    await idle(tester);
    expect(
      tester.widget<MindMapPane>(find.byType(MindMapPane)).selectedNodeIds,
      unorderedEquals([fixture.parent.node.id, fixture.source.node.id]),
    );
    expect(
      tester.widget<CardEditor>(find.byType(CardEditor)).card.id,
      fixture.source.card.id,
    );
    final editorState = tester.state(find.byType(CardEditor));
    await tester.enterText(
      find.byKey(const Key('card-body')),
      '多选改色前尚未自动保存的正文',
    );
    expect(
      (await real(
        tester,
        () => repository.getCard(fixture.source.card.id),
      )).body,
      'OpenNote',
    );
    final history = repository.undoEntryCount;
    await selectedMenuAction(tester, '所选卡片颜色…');
    await until(
      tester,
      () async =>
          find.text('所选 2 张卡片的颜色').evaluate().isNotEmpty &&
          (await repository.getCard(fixture.source.card.id)).body ==
              '多选改色前尚未自动保存的正文',
    );
    expect(repository.undoEntryCount, history + 1, reason: '只有正在编辑的草稿先提交');
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('正在提交…'), findsNothing);
    expect(find.text('资料已保存'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(SimpleDialog),
        matching: find.byIcon(Icons.check),
      ),
      findsNothing,
      reason: '混合颜色不标成一致颜色',
    );
    await tester.tap(
      find.byKey(const Key('card-color-#80B9EB')),
      kind: ui.PointerDeviceKind.mouse,
    );
    await until(
      tester,
      () async =>
          (await repository.getCard(fixture.source.card.id)).color ==
              '#80B9EB' &&
          (await repository.getCard(fixture.parent.card.id)).color == '#80B9EB',
    );
    await idle(tester);
    expect(repository.undoEntryCount, history + 2, reason: '两卡改色只有一次业务事务');
    expect(find.byType(SnackBar), findsNothing, reason: '改色通过卡片本身反馈');
    expect(tester.state(find.byType(CardEditor)), same(editorState));
    expect(
      (await real(tester, () => repository.getCard(copyCardId))).color,
      fixture.source.card.color,
    );
    expect(
      (await real(tester, () => repository.getCard(copyCardId))).body,
      'OpenNote',
    );
    final savedAnnotation = (await real(
      tester,
      () => repository.listAnnotations(fixture.document.activeRevisionId),
    )).single;
    expect(savedAnnotation.color, '#80B9EB');
    expect(savedAnnotation.id, annotation.id);
    await tester.tap(find.byTooltip('撤销 Ctrl+Z'));
    await until(
      tester,
      () async =>
          (await repository.getCard(fixture.parent.card.id)).color ==
              '#91C69A' &&
          (await repository.getCard(fixture.source.card.id)).color ==
              fixture.source.card.color,
    );
    await idle(tester);
    expect(
      (await real(
        tester,
        () => repository.getCard(fixture.source.card.id),
      )).body,
      '多选改色前尚未自动保存的正文',
    );
    expect(repository.undoEntryCount, history + 1);
    await tester.binding.setSurfaceSize(const Size(1600, 900));
    await tester.pump();
    await tester.drag(
      find.byKey(const Key('workspace-divider')),
      const Offset(600, 0),
    );
    await tester.pump();
    expect(tester.getSize(find.byType(MindMapPane)).width, closeTo(280, .1));
    expect(
      tester
          .getRect(find.byKey(const Key('workspace-map-header')))
          .contains(
            tester.getCenter(find.byKey(const Key('workspace-selected-menu'))),
          ),
      isTrue,
    );
    expect(tester.takeException(), isNull, reason: '停靠编辑器时280逻辑像素的多选标题栏不能溢出');
    await tester.tap(find.byTooltip('重做 Ctrl+Y'));
    await until(
      tester,
      () async =>
          (await repository.getCard(fixture.parent.card.id)).color == '#80B9EB',
    );
    await idle(tester);
    await tester.tap(find.byTooltip('收起编辑'));
    await until(tester, () async => find.byType(CardEditor).evaluate().isEmpty);
    await idle(tester);
    await switchMapView(tester, outline: true);
    tester
        .widget<ReaderPane>(find.byType(ReaderPane))
        .controller!
        .clearHighlights();
    var viewer = tester.widget<PdfViewer>(find.byType(PdfViewer)).controller!;
    await real(
      tester,
      () => viewer.goTo(
        viewer.calcMatrixForFit(pageNumber: 1)!,
        duration: Duration.zero,
      ),
    );
    await settleUi(tester);
    expect(
      tester.getCenter(find.byType(PdfViewer)).dx,
      lessThan(tester.getCenter(find.byType(MapOutlinePane)).dx),
    );
    expect(tester.takeException(), isNull);
    await capture(tester, captureKey, 'workbench-multi-selection-1280x720.png');
    await tester.binding.setSurfaceSize(null);
    tester.view.devicePixelRatio = 1.5;
    tester.view.physicalSize = const Size(1350, 1080);
    await tester.pump();
    expect(
      MediaQuery.sizeOf(tester.element(find.byType(Workbench))),
      const Size(900, 720),
    );
    expect(find.byTooltip('已选 2 项'), findsOneWidget);
    expect(
      tester
          .getRect(find.byKey(const Key('workspace-map-header')))
          .contains(
            tester.getCenter(find.byKey(const Key('workspace-selected-menu'))),
          ),
      isTrue,
    );
    viewer = tester.widget<PdfViewer>(find.byType(PdfViewer)).controller!;
    await real(
      tester,
      () => viewer.goTo(
        viewer.calcMatrixForFit(pageNumber: 1)!,
        duration: Duration.zero,
      ),
    );
    await settleUi(tester);
    expect(tester.takeException(), isNull);
    await capture(
      tester,
      captureKey,
      'workbench-multi-selection-1350x1080-at150.png',
      pixelRatio: 1.5,
    );
    tester.view.physicalSize = const Size(960, 1080);
    await tester.pump();
    expect(
      MediaQuery.sizeOf(tester.element(find.byType(Workbench))),
      const Size(640, 720),
    );
    expect(tester.getSize(find.byType(MapOutlinePane)).width, lessThan(260));
    expect(
      tester
          .getRect(find.byKey(const Key('workspace-map-header')))
          .contains(
            tester.getCenter(find.byKey(const Key('workspace-selected-menu'))),
          ),
      isTrue,
    );
    expect(
      tester.takeException(),
      isNull,
      reason: '150% DPI且脑图区小于260逻辑像素仍无标题栏溢出',
    );
    tester.view.resetDevicePixelRatio();
    tester.view.resetPhysicalSize();
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    await unmount(tester);
  });

  testWidgets('删除联动工作台：Ctrl+Delete仅回收当前卡片，提升子主题并可撤销', (tester) async {
    final fixture = await outlineFixture(tester);
    await clickMapNode(tester, fixture.parent.node.id);
    await idle(tester);
    final history = repository.undoEntryCount;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await until(
      tester,
      () async => (await repository.loadMap(fixture.map.id)).nodes.length == 1,
    );
    await idle(tester);
    final snapshot = await real(
      tester,
      () => repository.loadMap(fixture.map.id),
    );
    expect(snapshot.nodes.single.id, fixture.source.node.id);
    expect(snapshot.nodes.single.parentNodeId, isNull);
    expect(
      (await real(
        tester,
        () => repository.listCards(fixture.project.id),
      )).single.id,
      fixture.source.card.id,
    );
    expect(
      (await real(
        tester,
        () => repository.listTrash(projectId: fixture.project.id),
      )).single.entityId,
      fixture.parent.card.id,
    );
    expect(repository.undoEntryCount, history + 1);
    await tester.tap(find.byTooltip('撤销 Ctrl+Z'));
    await until(
      tester,
      () async => (await repository.loadMap(fixture.map.id)).nodes.length == 2,
    );
    await idle(tester);
    expect(
      (await real(
        tester,
        () => repository.loadMap(fixture.map.id),
      )).nodes.singleWhere((n) => n.id == fixture.source.node.id).parentNodeId,
      fixture.parent.node.id,
    );
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('多选工作台：批量折叠精确节点与删除祖先后代各一次撤销', (tester) async {
    final fixture = await outlineFixture(tester);
    await real(
      tester,
      () => repository.setNodeCollapsed(fixture.source.node.id, true),
    );
    await clickMapNode(tester, fixture.parent.node.id);
    await ctrlClickNode(
      tester,
      fixture.source.node.id,
      expected: {fixture.parent.node.id, fixture.source.node.id},
      primary: fixture.source.node.id,
    );
    final history = repository.undoEntryCount;
    await selectedMenuAction(tester, '折叠所选节点');
    await until(
      tester,
      () async =>
          (await repository.loadMap(fixture.map.id)).nodes
              .every((node) => node.collapsed),
    );
    await idle(tester);
    expect(repository.undoEntryCount, history + 1);
    expect(find.byType(SnackBar), findsNothing, reason: '折叠不显示底部成功提示');
    expect(
      tester.widget<MindMapPane>(find.byType(MindMapPane)).selectedNodeIds,
      unorderedEquals([fixture.parent.node.id, fixture.source.node.id]),
    );
    await tester.tap(find.byTooltip('撤销 Ctrl+Z'));
    await until(
      tester,
      () async =>
          !(await repository.loadMap(fixture.map.id)).nodes
              .singleWhere((node) => node.id == fixture.parent.node.id)
              .collapsed,
    );
    await idle(tester);
    expect(
      (await real(tester, () => repository.loadMap(fixture.map.id))).nodes
          .singleWhere((node) => node.id == fixture.source.node.id)
          .collapsed,
      isTrue,
    );
    await selectedMenuAction(tester, '展开所选节点');
    await until(
      tester,
      () async =>
          (await repository.loadMap(fixture.map.id)).nodes
              .every((node) => !node.collapsed),
    );
    await idle(tester);
    expect(repository.undoEntryCount, history + 1);
    await clickMapNode(tester, fixture.parent.node.id);
    expect(find.byType(SnackBar), findsNothing, reason: '展开不显示底部成功提示');
    await ctrlClickNode(
      tester,
      fixture.source.node.id,
      expected: {fixture.parent.node.id, fixture.source.node.id},
      primary: fixture.source.node.id,
    );
    final beforeDelete = repository.undoEntryCount;
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await until(
      tester,
      () async => (await repository.loadMap(fixture.map.id)).nodes.isEmpty,
    );
    await idle(tester);
    await until(tester, () async {
      final pane = tester.widget<MindMapPane>(find.byType(MindMapPane));
      return pane.snapshot.nodes.isEmpty &&
          (pane.selectedNodeIds?.isEmpty ?? false);
    });
    expect(find.byType(SnackBar), findsNothing, reason: '删除后通过画布和数量反馈');
    expect(
      repository.undoEntryCount,
      beforeDelete + 1,
      reason: '选择祖先和后代时仅删除一次分支并集',
    );
    expect(
      (await real(
        tester,
        () => repository.listCards(fixture.project.id),
      )).map((card) => card.id),
      isEmpty,
    );
    expect(
      await real(
        tester,
        () => repository.listTrash(projectId: fixture.project.id),
      ),
      hasLength(2),
    );
    expect(
      await real(
        tester,
        () => repository.listAnnotations(fixture.document.activeRevisionId),
      ),
      isEmpty,
    );
    expect(
      tester.widget<MindMapPane>(find.byType(MindMapPane)).selectedNodeIds,
      isEmpty,
    );
    await tester.tap(find.byTooltip('撤销 Ctrl+Z'));
    await until(
      tester,
      () async => (await repository.loadMap(fixture.map.id)).nodes.length == 2,
    );
    await idle(tester);
    final restored = await real(
      tester,
      () => repository.loadMap(fixture.map.id),
    );
    expect(
      restored.nodes
          .singleWhere((node) => node.id == fixture.source.node.id)
          .parentNodeId,
      fixture.parent.node.id,
    );
    expect(restored.nodes.every((node) => !node.collapsed), isTrue);
    expect(repository.undoEntryCount, beforeDelete);
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('多选工作台：整组拖动含后代只一次撤销，SQLite拒绝末节点时全部回滚', (tester) async {
    final fixture = await outlineFixture(tester);
    final other = await real(
      tester,
      () => repository.createExcerpt(
        model.ExcerptDraft(
          projectId: fixture.project.id,
          mapId: fixture.map.id,
          title: '一同移动的独立主题',
          text: '',
          anchors: const [],
          x: 80,
          y: 340,
        ),
      ),
    );
    await clickMapNode(tester, fixture.parent.node.id);
    await ctrlClickNode(
      tester,
      other.node.id,
      expected: {fixture.parent.node.id, other.node.id},
      primary: other.node.id,
    );
    final paneFinder = find.byType(MindMapPane);
    final graph = tester.widget<MindMapPane>(paneFinder).controller!;
    graph.fitAll();
    await advance(tester);
    final original = await real(
      tester,
      () => repository.loadMap(fixture.map.id),
    );
    final before = {for (final node in original.nodes) node.id: node};
    final history = repository.undoEntryCount;
    Future<void> dragGroup() async {
      final finder = find.byKey(Key('map-node-${fixture.parent.node.id}'));
      final point = tester.getCenter(finder);
      expect(tester.getRect(paneFinder).contains(point), isTrue);
      expect(
        tester
            .hitTestOnBinding(point)
            .path
            .any(
              (entry) => identical(entry.target, tester.renderObject(finder)),
            ),
        isTrue,
      );
      final gesture = await tester.startGesture(
        point,
        kind: ui.PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(30, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(60, 45));
      await tester.pump();
      await gesture.up();
      await tester.pump();
    }

    await dragGroup();
    await until(
      tester,
      () async =>
          (await repository.loadMap(fixture.map.id)).nodes
              .singleWhere((node) => node.id == fixture.parent.node.id)
              .x !=
          before[fixture.parent.node.id]!.x,
    );
    await idle(tester);
    final moved = await real(tester, () => repository.loadMap(fixture.map.id));
    final first = moved.nodes.singleWhere(
      (node) => node.id == fixture.parent.node.id,
    );
    final dx = first.x - before[first.id]!.x;
    final dy = first.y - before[first.id]!.y;
    expect(dx.abs() + dy.abs(), greaterThan(1));
    for (final node in moved.nodes) {
      expect(node.x - before[node.id]!.x, closeTo(dx, .01));
      expect(node.y - before[node.id]!.y, closeTo(dy, .01));
      expect(
        node.parentNodeId,
        before[node.id]!.parentNodeId,
        reason: '多根拖动只移位，不重挂',
      );
    }
    expect(repository.undoEntryCount, history + 1);
    expect(
      tester.widget<MindMapPane>(paneFinder).selectedNodeIds,
      unorderedEquals([fixture.parent.node.id, other.node.id]),
    );
    await tester.tap(find.byTooltip('撤销 Ctrl+Z'));
    await until(
      tester,
      () async => (await repository.loadMap(fixture.map.id)).nodes.every(
        (node) => node.x == before[node.id]!.x && node.y == before[node.id]!.y,
      ),
    );
    await idle(tester);
    expect(repository.undoEntryCount, history);
    await until(tester, () async {
      final shown = tester.widget<MindMapPane>(paneFinder).snapshot.nodes;
      return shown.length == before.length &&
          shown.every(
            (node) =>
                node.x == before[node.id]!.x && node.y == before[node.id]!.y,
          );
    });
    graph.fitAll();
    await advance(tester);
    final visualBefore = {
      for (final node in original.nodes)
        node.id:
            tester.getCenter(find.byKey(Key('map-node-${node.id}'))) -
            tester.getTopLeft(paneFinder),
    };
    final layoutBefore = {
      for (final node in original.nodes)
        node.id: tester.widget<Positioned>(
          find.byKey(Key('map-position-${node.id}')),
        ),
    };
    final database = sqlite.sqlite3.open(
      '${repository.libraryPath}/library.sqlite',
    );
    try {
      database.execute(
        "CREATE TRIGGER reject_group_last BEFORE UPDATE OF x, y ON nodes WHEN OLD.id = '${other.node.id}' BEGIN SELECT RAISE(FAIL, '验证整组最后节点失败'); END;",
      );
      await dragGroup();
      await until(
        tester,
        () async => find.textContaining('验证整组最后节点失败').evaluate().isNotEmpty,
      );
      await idle(tester);
      await until(tester, () async {
        final shown = tester.widget<MindMapPane>(paneFinder).snapshot.nodes;
        return find
                .descendant(
                  of: paneFinder,
                  matching: find.byType(LinearProgressIndicator),
                )
                .evaluate()
                .isEmpty &&
            shown.length == before.length &&
            shown.every(
              (node) =>
                  node.x == before[node.id]!.x && node.y == before[node.id]!.y,
            );
      });
      await tester.pump();
      final rejected = await real(
        tester,
        () => repository.loadMap(fixture.map.id),
      );
      final paneRect = tester.getRect(paneFinder);
      final currentPane = tester.widget<MindMapPane>(paneFinder);
      for (final node in rejected.nodes) {
        final positioned = tester.widget<Positioned>(
          find.byKey(Key('map-position-${node.id}')),
        );
        final snapshotNode = currentPane.snapshot.nodes.singleWhere(
          (value) => value.id == node.id,
        );
        final visual =
            tester.getCenter(find.byKey(Key('map-node-${node.id}'))) -
            paneRect.topLeft;
        debugPrint(
          'group-rollback node=${node.id} visualBefore=${visualBefore[node.id]} visualAfter=$visual '
          'paneRect=$paneRect scale=${currentPane.controller!.scale} '
          'positionBefore=(${layoutBefore[node.id]!.left},${layoutBefore[node.id]!.top}) '
          'positionAfter=(${positioned.left},${positioned.top}) '
          'original=(${before[node.id]!.x},${before[node.id]!.y}) '
          'snapshot=(${snapshotNode.x},${snapshotNode.y}) SQLite=(${node.x},${node.y})',
        );
      }
      for (final node in rejected.nodes) {
        expect(node.x, before[node.id]!.x);
        expect(node.y, before[node.id]!.y);
        final visual =
            tester.getCenter(find.byKey(Key('map-node-${node.id}'))) -
            tester.getTopLeft(paneFinder);
        expect(
          (visual - visualBefore[node.id]!).distance,
          lessThan(1),
          reason: '整组失败后不能留住部分临时坐标',
        );
      }
      expect(repository.undoEntryCount, history);
      expect(
        tester.widget<MindMapPane>(paneFinder).selectedNodeIds,
        unorderedEquals([fixture.parent.node.id, other.node.id]),
      );
      database.execute('DROP TRIGGER reject_group_last');
      await dragGroup();
      await until(
        tester,
        () async =>
            (await repository.loadMap(fixture.map.id)).nodes
                .singleWhere((node) => node.id == other.node.id)
                .x !=
            before[other.node.id]!.x,
      );
      await idle(tester);
      expect(
        repository.undoEntryCount,
        history + 1,
        reason: '失败后队列仍可提交一次完整整组移动',
      );
      expect(tester.takeException(), isNull);
    } finally {
      database.close();
      await unmount(tester);
    }
  });

  testWidgets('多选工作台：改色对话框遇到资料库会话切换不写入新资料库', (tester) async {
    final fixture = await outlineFixture(tester);
    await clickMapNode(tester, fixture.parent.node.id);
    await ctrlClickNode(
      tester,
      fixture.source.node.id,
      expected: {fixture.parent.node.id, fixture.source.node.id},
      primary: fixture.source.node.id,
    );
    final backup = '${temp.path}/selection.onbackup';
    await real(tester, () => repository.backupTo(backup));
    await selectedMenuAction(tester, '所选卡片颜色…');
    await until(
      tester,
      () async => find.text('所选 2 张卡片的颜色').evaluate().isNotEmpty,
    );
    final session = repository.sessionId;
    // 模拟对话框等待期间的真实资料库恢复，验证已接受命令仍绑定原会话。
    await real(tester, () => repository.restoreFrom(backup));
    expect(repository.sessionId, isNot(session));
    await tester.tap(
      find.byKey(const Key('card-color-#80B9EB')),
      kind: ui.PointerDeviceKind.mouse,
    );
    await until(tester, () async => find.byType(Workbench).evaluate().isEmpty);
    expect(
      (await real(
        tester,
        () => repository.getCard(fixture.parent.card.id),
      )).color,
      fixture.parent.card.color,
    );
    expect(
      (await real(
        tester,
        () => repository.getCard(fixture.source.card.id),
      )).color,
      fixture.source.card.color,
    );
    expect(repository.undoEntryCount, 0, reason: '原会话命令不能写入恢复后的资料库');
    await openHomeProject(tester, fixture.project.id);
    await until(
      tester,
      () async =>
          find.byType(ReaderPane).evaluate().isNotEmpty &&
          tester.widget<ReaderPane>(find.byType(ReaderPane)).key ==
              ValueKey(
                '${repository.sessionId}:${fixture.document.activeRevisionId}',
              ) &&
          readerReady(tester),
    );
    expect(tester.takeException(), isNull);
    final document = tester
        .widget<PdfViewer>(find.byType(PdfViewer))
        .controller!
        .document;
    final pdfPath = tester.widget<ReaderPane>(find.byType(ReaderPane)).filePath;
    await unmount(tester);
    expect((document as dynamic).isDisposed, isTrue);
    await real(tester, () async {
      final moved = await File(pdfPath).rename('$pdfPath.session-close-check');
      await moved.rename(pdfPath);
    });
  });

  Future<void> queuedSelectionShortcut(
    WidgetTester tester,
    LogicalKeyboardKey shortcut,
  ) async {
    final fixture = await outlineFixture(tester);
    // 两个独立分支才能区分删除旧选集和删除Ctrl之后的最新选集。
    await real(
      tester,
      () => repository.reparentNode(fixture.source.node.id, null),
    );
    await clickMapNode(tester, fixture.parent.node.id);
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await until(
      tester,
      () async => find.byType(CardEditor).evaluate().isNotEmpty,
    );
    await idle(tester);
    final paneFinder = find.byType(MindMapPane);
    tester
        .widget<MindMapPane>(paneFinder)
        .controller!
        .centerOnNode(fixture.source.node.id);
    await advance(tester);
    await tester.pump();
    final sourceFinder = find.byKey(Key('map-node-${fixture.source.node.id}'));
    final point = tester.getCenter(sourceFinder);
    expect(tester.getRect(paneFinder).contains(point), isTrue);
    expect(
      tester
          .hitTestOnBinding(point)
          .path
          .any(
            (entry) =>
                identical(entry.target, tester.renderObject(sourceFinder)),
          ),
      isTrue,
    );
    final history = repository.undoEntryCount;
    final database = sqlite.sqlite3.open(
      '${repository.libraryPath}/library.sqlite',
    );
    var locked = false;
    try {
      database.execute('PRAGMA busy_timeout = 1000');
      database.execute('BEGIN IMMEDIATE');
      locked = true;
      final held = Stopwatch()..start();
      await tester.enterText(
        find.byKey(const Key('card-body')),
        '选择排队时只保存原编辑卡',
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      try {
        final click = await tester.startGesture(
          point,
          kind: ui.PointerDeviceKind.mouse,
        );
        await tester.pump();
        await click.up();
        await tester.pump();
      } finally {
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      }
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'OpenNote 脑图');
      // 写锁尚未释放：不等selection/idle，紧接实际键盘事件。
      await tester.sendKeyEvent(shortcut);
      await tester.pump();
      expect(
        held.elapsedMilliseconds,
        lessThan(4000),
        reason: '锁仅覆盖有界输入，不能让SQLite的5秒等待本身制造业务RED',
      );
      database.execute('ROLLBACK');
      locked = false;
      await idle(tester);
      expect(
        (await real(
          tester,
          () => repository.getCard(fixture.parent.card.id),
        )).body,
        '选择排队时只保存原编辑卡',
      );
      expect(
        (await real(
          tester,
          () => repository.getCard(fixture.source.card.id),
        )).body,
        'OpenNote',
      );
      if (shortcut == LogicalKeyboardKey.delete) {
        final remaining = await real(
          tester,
          () => repository.loadMap(fixture.map.id),
        );
        expect(
          remaining.nodes,
          isEmpty,
          reason: 'Ctrl后的两个独立分支应按最新选择一起删除，不能只删旧主选',
        );
        expect(repository.undoEntryCount, history + 2, reason: '草稿和整组选集删除分别一笔');
        expect(
          (await real(
            tester,
            () => repository.listCards(fixture.project.id),
          )).length,
          0,
        );
        expect(
          await real(
            tester,
            () => repository.listTrash(projectId: fixture.project.id),
          ),
          hasLength(2),
        );
      } else {
        await until(
          tester,
          () async =>
              tester.widget<CardEditor>(find.byType(CardEditor)).card.id ==
                  fixture.source.card.id &&
              tester.widget<MindMapPane>(paneFinder).selectedNodeId ==
                  fixture.source.node.id,
        );
        final pane = tester.widget<MindMapPane>(paneFinder);
        expect(
          pane.selectedNodeIds,
          unorderedEquals([fixture.parent.node.id, fixture.source.node.id]),
          reason: 'F2在先前选择执行后打开最新主选，不能把组清成单选',
        );
        expect(pane.selectedNodeId, fixture.source.node.id);
        expect(
          tester.widget<CardEditor>(find.byType(CardEditor)).card.id,
          fixture.source.card.id,
        );
        await until(
          tester,
          () async => tester
              .widget<TextField>(find.byKey(const Key('card-body')))
              .focusNode!
              .hasFocus,
        );
        expect(repository.undoEntryCount, history + 1);
      }
      expect(tester.takeException(), isNull);
    } finally {
      if (locked) database.execute('ROLLBACK');
      database.close();
      await unmount(tester);
    }
  }

  testWidgets('多选工作台：Ctrl排队后立即Delete使用最新选择集合', (tester) async {
    await queuedSelectionShortcut(tester, LogicalKeyboardKey.delete);
  });

  testWidgets('多选工作台：Ctrl排队后立即F2保持最新选择集合和主选', (tester) async {
    await queuedSelectionShortcut(tester, LogicalKeyboardKey.f2);
  });

  testWidgets('画布与大纲切换保留相机和共用编辑器草稿，视图不写业务历史', (tester) async {
    final fixture = await outlineFixture(tester);
    await clickMapNode(tester, fixture.source.node.id);
    final canvas = find.byType(MindMapPane);
    final canvasState = tester.state(canvas);
    final graph = tester.widget<MindMapPane>(canvas).controller!;
    graph.setView(scale: .7, worldTopLeft: const Offset(-180, -100));
    await tester.pump();
    final parentPosition = tester.getTopLeft(
      find.byKey(Key('map-node-${fixture.parent.node.id}')),
    );
    final history = repository.undoEntryCount;
    await switchMapView(tester, outline: true);
    expect(
      tester.widget<MapOutlinePane>(find.byType(MapOutlinePane)).selectedNodeId,
      fixture.source.node.id,
    );
    expect(
      tester
          .widget<Semantics>(
            find.byKey(Key('outline-node-${fixture.source.node.id}')),
          )
          .properties
          .selected,
      isTrue,
    );
    await switchMapView(tester, outline: false);
    expect(tester.state(canvas), same(canvasState));
    expect(graph.scale, closeTo(.7, .001));
    expect(
      (tester.getTopLeft(
                find.byKey(Key('map-node-${fixture.parent.node.id}')),
              ) -
              parentPosition)
          .distance,
      lessThan(.01),
    );
    expect(repository.undoEntryCount, history);
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await until(
      tester,
      () async => find.byType(CardEditor).evaluate().isNotEmpty,
    );
    await idle(tester);
    final editorState = tester.state(find.byType(CardEditor));
    final controller = tester
        .widget<TextField>(find.byKey(const Key('card-body')))
        .controller!;
    final historyBeforeDraft = repository.undoEntryCount;
    await tester.enterText(find.byKey(const Key('card-body')), '画布和大纲共享的未保存正文');
    await switchMapView(tester, outline: true);
    await switchMapView(tester, outline: false);
    await switchMapView(tester, outline: true);
    expect(tester.state(find.byType(CardEditor)), same(editorState));
    expect(
      tester.widget<TextField>(find.byKey(const Key('card-body'))).controller,
      same(controller),
    );
    expect(controller.text, '画布和大纲共享的未保存正文');
    expect(
      (await real(
        tester,
        () => repository.getCard(fixture.source.card.id),
      )).body,
      'OpenNote',
    );
    expect(repository.undoEntryCount, historyBeforeDraft);
    await clickOutlineNode(tester, fixture.parent.node.id);
    await until(
      tester,
      () async =>
          (await repository.getCard(fixture.source.card.id)).body ==
              '画布和大纲共享的未保存正文' &&
          tester.widget<CardEditor>(find.byType(CardEditor)).card.id ==
              fixture.parent.card.id,
    );
    await idle(tester);
    expect(find.byType(CardEditor), findsOneWidget);
    expect(repository.undoEntryCount, historyBeforeDraft + 1);
    expect(
      tester
          .widget<MindMapPane>(find.byType(MindMapPane, skipOffstage: false))
          .selectedNodeId,
      fixture.parent.node.id,
    );
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('大纲与画布共用选中折叠和实际PDF回源，中文长正文可阅读', (tester) async {
    final fixture = await outlineFixture(tester);
    await clickMapNode(tester, fixture.parent.node.id);
    await switchMapView(tester, outline: true);
    expect(
      tester.widget<MapOutlinePane>(find.byType(MapOutlinePane)).selectedNodeId,
      fixture.parent.node.id,
    );
    final history = repository.undoEntryCount;
    await tester.tap(find.byKey(const Key('outline-show-body')));
    await tester.pump();
    final parentBody = find.byKey(
      Key('outline-body-${fixture.parent.node.id}'),
    );
    expect(tester.widget<Text>(parentBody).data, fixture.parent.card.body);
    expect(tester.getSize(parentBody).height, greaterThan(100));
    expect(repository.undoEntryCount, history);
    var viewer = tester.widget<PdfViewer>(find.byType(PdfViewer)).controller!;
    await real(
      tester,
      () => viewer.goToPage(pageNumber: 2, duration: Duration.zero),
    );
    await until(tester, () async => viewer.pageNumber == 2);
    await clickOutlineNode(tester, fixture.source.node.id);
    await until(
      tester,
      () async =>
          readerReady(tester) &&
          viewer.pageNumber == 1 &&
          tester
                  .widget<MindMapPane>(
                    find.byType(MindMapPane, skipOffstage: false),
                  )
                  .selectedNodeId ==
              fixture.source.node.id,
    );
    expect(find.byType(CardEditor), findsNothing, reason: '自动回源不强制打开编辑器');
    await switchMapView(tester, outline: false);
    expect(
      tester.widget<MindMapPane>(find.byType(MindMapPane)).selectedNodeId,
      fixture.source.node.id,
    );
    expect(
      tester
          .widget<Semantics>(
            find
                .descendant(
                  of: find.byKey(Key('map-node-${fixture.source.node.id}')),
                  matching: find.byType(Semantics),
                )
                .first,
          )
          .properties
          .selected,
      isTrue,
    );
    await switchMapView(tester, outline: true);
    await tester.tap(
      find.byKey(Key('outline-collapse-${fixture.parent.node.id}')),
    );
    await until(
      tester,
      () async =>
          (await repository.loadMap(fixture.map.id)).nodes
              .singleWhere((value) => value.id == fixture.parent.node.id)
              .collapsed &&
          find
              .byKey(Key('outline-node-${fixture.source.node.id}'))
              .evaluate()
              .isEmpty,
    );
    await idle(tester);
    await switchMapView(tester, outline: false);
    expect(find.byKey(Key('map-node-${fixture.source.node.id}')), findsNothing);
    await clickMapNode(tester, fixture.parent.node.id);
    await tester.tap(find.byKey(Key('map-collapse-${fixture.parent.node.id}')));
    await until(
      tester,
      () async =>
          !(await repository.loadMap(fixture.map.id)).nodes
              .singleWhere((value) => value.id == fixture.parent.node.id)
              .collapsed,
    );
    await idle(tester);
    tester.widget<MindMapPane>(find.byType(MindMapPane)).controller!.fitAll();
    await tester.pump();
    await switchMapView(tester, outline: true);
    await until(
      tester,
      () async => find
          .byKey(Key('outline-node-${fixture.source.node.id}'))
          .evaluate()
          .isNotEmpty,
    );
    expect(
      tester.widget<Text>(parentBody).data,
      fixture.parent.card.body,
      reason: '大纲正文模式也保留在同一视图子树',
    );
    viewer = tester.widget<PdfViewer>(find.byType(PdfViewer)).controller!;
    await real(
      tester,
      () => viewer.goToPage(pageNumber: 2, duration: Duration.zero),
    );
    await until(tester, () async => viewer.pageNumber == 2);
    await tester.tap(
      find.byKey(Key('outline-source-${fixture.source.node.id}')),
    );
    await until(
      tester,
      () async =>
          viewer.pageNumber == 1 &&
          tester
                  .widget<MapOutlinePane>(find.byType(MapOutlinePane))
                  .selectedNodeId ==
              fixture.source.node.id,
    );
    await idle(tester);
    await tester.tap(find.byKey(Key('outline-menu-${fixture.source.node.id}')));
    await settleUi(tester);
    await tester.tap(find.text('编辑卡片'));
    await until(
      tester,
      () async => find.byType(CardEditor).evaluate().isNotEmpty,
    );
    expect(
      tester.widget<CardEditor>(find.byType(CardEditor)).card.id,
      fixture.source.card.id,
    );
    await tester.enterText(find.byKey(const Key('card-note')), '大纲菜单编辑的独立备注');
    await tester.tap(find.byTooltip('收起编辑'));
    await until(
      tester,
      () async =>
          find.byType(CardEditor).evaluate().isEmpty &&
          (await repository.getCard(fixture.source.card.id)).note ==
              '大纲菜单编辑的独立备注',
    );
    await idle(tester);
    expect(
      (await real(
        tester,
        () => repository.getCard(fixture.parent.card.id),
      )).body,
      fixture.parent.card.body,
    );
    final anchors = await real(
      tester,
      () => repository.getAnchors(fixture.source.card.id),
    );
    expect(anchors, hasLength(1));
    expect(anchors.single.revisionId, fixture.document.activeRevisionId);
    expect(anchors.single.pageIndex, 0);
    final snapshot = await real(
      tester,
      () => repository.loadMap(fixture.map.id),
    );
    expect(
      snapshot.nodes
          .singleWhere((value) => value.id == fixture.source.node.id)
          .parentNodeId,
      fixture.parent.node.id,
    );
    tester
        .widget<ReaderPane>(find.byType(ReaderPane))
        .controller!
        .clearHighlights();
    final fit = viewer.calcMatrixForFit(pageNumber: 1);
    expect(fit, isNotNull);
    await real(tester, () => viewer.goTo(fit, duration: Duration.zero));
    await settleUi(tester);
    expect(tester.takeException(), isNull);
    await capture(tester, captureKey, 'workbench-outline-reading-1280x720.png');
    await unmount(tester);
  });

  testWidgets('扩展结构工作台：示意图选择先保存草稿，时间线提交与撤销保持原文来源', (tester) async {
    final fixture = await outlineFixture(tester);
    final graph = tester
        .widget<MindMapPane>(find.byType(MindMapPane))
        .controller!;
    graph.editTitle(fixture.parent.node.id);
    await until(
      tester,
      () async =>
          find.byKey(const ValueKey('map-title-input')).evaluate().isNotEmpty,
    );
    await tester.enterText(
      find.byKey(const ValueKey('map-title-input')),
      '选择结构前的中文草稿',
    );
    await openMapStructureMenu(tester);
    await until(
      tester,
      () async => find.text('更多结构…').hitTestable().evaluate().isNotEmpty,
    );
    await tester.tap(find.text('更多结构…').hitTestable());
    final tile = find.byKey(const ValueKey('structure-timeline'));
    await until(tester, () async => tile.evaluate().isNotEmpty);
    await tester.ensureVisible(tile);
    await tester.pump();
    await tester.tap(tile);
    await tester.pumpAndSettle();
    await capture(tester, captureKey, 'xmind-structure-chooser-1920x1080.png');
    final afterDraft = repository.undoEntryCount;
    await tester.tap(find.byKey(const ValueKey('confirm-map-structure')));
    await until(
      tester,
      () async =>
          tester
              .widget<MindMapPane>(find.byType(MindMapPane))
              .snapshot
              .map
              .layout ==
          model.MapLayoutKind.timeline,
    );
    final snapshot = await real(
      tester,
      () => repository.loadMap(fixture.map.id),
    );
    expect(repository.undoEntryCount, afterDraft + 1);
    expect(snapshot.cards[fixture.parent.card.id]!.title, '选择结构前的中文草稿');
    expect(
      snapshot.anchors[fixture.source.card.id]!.single.revisionId,
      fixture.document.activeRevisionId,
    );
    await idle(tester);
    await capture(tester, captureKey, 'xmind-timeline-workbench-1920x1080.png');
    await real(tester, repository.undo);
    await until(
      tester,
      () async =>
          tester
              .widget<MindMapPane>(find.byType(MindMapPane))
              .snapshot
              .map
              .layout ==
          model.MapLayoutKind.free,
    );
    expect(
      (await real(
        tester,
        () => repository.loadMap(fixture.map.id),
      )).cards[fixture.parent.card.id]!.title,
      '选择结构前的中文草稿',
    );
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('脑图结构工作台：切换先保存标题、新增沿用布局、整批失败保留原结构', (tester) async {
    final fixture = await outlineFixture(tester);
    Future<void> chooseStructure(String label) async {
      await openMapStructureMenu(tester);
      final matches = find.text(label);
      await until(
        tester,
        () async =>
            matches.evaluate().isNotEmpty &&
            tester
                .hitTestOnBinding(tester.getCenter(matches.last))
                .path
                .any(
                  (entry) => identical(
                    entry.target,
                    tester.renderObject(matches.last),
                  ),
                ),
      );
      await tester.tap(matches.last);
    }

    await chooseStructure('自动整理');
    await until(
      tester,
      () async =>
          tester
              .widget<MindMapPane>(find.byType(MindMapPane))
              .snapshot
              .map
              .layout ==
          model.MapLayoutKind.right,
    );
    final graph = tester
        .widget<MindMapPane>(find.byType(MindMapPane))
        .controller!;
    graph.editTitle(fixture.parent.node.id);
    await until(
      tester,
      () async =>
          find.byKey(const ValueKey('map-title-input')).evaluate().isNotEmpty,
    );
    await tester.enterText(
      find.byKey(const ValueKey('map-title-input')),
      '结构切换保存中文标题',
    );
    await chooseStructure('组织结构 · 向下');
    await until(
      tester,
      () async =>
          tester
              .widget<MindMapPane>(find.byType(MindMapPane))
              .snapshot
              .map
              .layout ==
          model.MapLayoutKind.down,
    );
    var snapshot = await real(tester, () => repository.loadMap(fixture.map.id));
    expect(snapshot.cards[fixture.parent.card.id]!.title, '结构切换保存中文标题');
    expect(
      snapshot.anchors[fixture.source.card.id]!.single.revisionId,
      fixture.document.activeRevisionId,
    );
    await idle(tester);
    final viewport = tester.getRect(
      find.descendant(
        of: find.byType(MindMapPane),
        matching: find.byType(InteractiveViewer),
      ),
    );
    final visibleBounds = tester
        .getRect(find.byKey(Key('map-node-${fixture.parent.node.id}')))
        .expandToInclude(
          tester.getRect(find.byKey(Key('map-node-${fixture.source.node.id}'))),
        );
    expect(
      (visibleBounds.center - viewport.center).distance,
      lessThan(2),
      reason: '切换结构后的适配必须使用已提交的新坐标',
    );
    await capture(tester, captureKey, 'xmind-organization-down-1920x1080.png');
    await clickMapNode(tester, fixture.parent.node.id);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await until(
      tester,
      () async =>
          find.byKey(const ValueKey('map-title-input')).evaluate().isNotEmpty,
    );
    await tester.enterText(
      find.byKey(const ValueKey('map-title-input')),
      '新增组织主题',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await until(
      tester,
      () async =>
          find.byKey(const ValueKey('map-title-input')).evaluate().isEmpty,
    );
    snapshot = await real(tester, () => repository.loadMap(fixture.map.id));
    final inserted = snapshot.nodes.singleWhere(
      (n) => snapshot.cards[n.cardId]!.title == '新增组织主题',
    );
    final root = snapshot.nodes.singleWhere(
      (n) => n.id == fixture.parent.node.id,
    );
    expect(inserted.parentNodeId, root.id);
    expect(inserted.y, greaterThan(root.y + root.height));
    await chooseStructure('双侧脑图');
    await until(
      tester,
      () async =>
          tester
              .widget<MindMapPane>(find.byType(MindMapPane))
              .snapshot
              .map
              .layout ==
          model.MapLayoutKind.mindMap,
    );
    await idle(tester);
    await capture(tester, captureKey, 'xmind-mindmap-1920x1080.png');
    final db = sqlite.sqlite3.open('${repository.libraryPath}/library.sqlite');
    try {
      db.execute(
        "CREATE TRIGGER reject_structure BEFORE UPDATE ON nodes WHEN NEW.id='${inserted.id}' BEGIN SELECT RAISE(ABORT,'test layout save failure'); END",
      );
      await chooseStructure('逻辑图 · 向左');
      await until(
        tester,
        () async => find
            .textContaining('test layout save failure')
            .evaluate()
            .isNotEmpty,
      );
      expect(
        tester
            .widget<MindMapPane>(find.byType(MindMapPane))
            .snapshot
            .map
            .layout,
        model.MapLayoutKind.mindMap,
      );
      expect(
        (await real(
          tester,
          () => repository.loadMap(fixture.map.id),
        )).map.layout,
        model.MapLayoutKind.mindMap,
      );
      db.execute('DROP TRIGGER reject_structure');
    } finally {
      db.close();
    }
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('主题快捷创建先编辑标题，F2正文与文本焦点保持正确', (tester) async {
    final project = await real(tester, () => repository.createProject('快捷主题'));
    final map = (await real(
      tester,
      () => repository.listMaps(project.id),
    )).single;
    await real(
      tester,
      () => repository.setMapLayout(map.id, model.MapLayoutKind.free),
    );
    final parent = await real(
      tester,
      () => repository.createExcerpt(
        model.ExcerptDraft(
          projectId: project.id,
          mapId: map.id,
          title: '父主题',
          text: '',
          anchors: const [],
          x: 80,
          y: 80,
        ),
      ),
    );
    await mount(tester);
    await clickMapNode(tester, parent.node.id);
    await tester.sendKeyEvent(LogicalKeyboardKey.insert);
    await until(
      tester,
      () async =>
          (await repository.listCards(project.id)).length == 2 &&
          find.byKey(const Key('map-title-input')).evaluate().isNotEmpty,
    );
    await idle(tester);
    final child = (await real(
      tester,
      () => repository.listCards(project.id),
    )).singleWhere((card) => card.id != parent.card.id);
    var snapshot = await real(tester, () => repository.loadMap(map.id));
    final childNode = snapshot.nodes.singleWhere(
      (node) => node.cardId == child.id,
    );
    expect(childNode.parentNodeId, parent.node.id);
    expect(child.title, '新主题');
    expect(child.body, isEmpty);
    expect(child.note, isEmpty);
    expect(await real(tester, () => repository.getAnchors(child.id)), isEmpty);
    expect(find.byType(CardEditor), findsNothing);
    await tester.enterText(find.byKey(const Key('map-title-input')), '键盘子主题');
    await tester.pump();
    await capture(tester, captureKey, 'xmind-inline-title-1920x1080.png');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await until(
      tester,
      () async =>
          (await repository.getCard(child.id)).title == '键盘子主题' &&
          find.byKey(const Key('map-title-input')).evaluate().isEmpty,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await until(
      tester,
      () async => find.byType(CardEditor).evaluate().isNotEmpty,
    );
    expect(find.byType(CardEditor), findsOneWidget);
    expect(
      tester
          .widget<EditableText>(
            find.descendant(
              of: find.byKey(const Key('card-body')),
              matching: find.byType(EditableText),
            ),
          )
          .focusNode
          .hasFocus,
      isTrue,
    );
    await tester.enterText(find.byKey(const Key('card-body')), '子主题正文');
    expect(
      tester.widget<CardEditor>(find.byType(CardEditor)).card.id,
      child.id,
    );
    final bodyField = tester.widget<TextField>(
      find.byKey(const Key('card-body')),
    );
    bodyField.controller!.selection = TextSelection.collapsed(
      offset: bodyField.controller!.text.length,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.insert);
    await tester.pump(const Duration(milliseconds: 550));
    await until(
      tester,
      () async => (await repository.getCard(child.id)).body.startsWith('子主题正文'),
    );
    expect(
      (await real(tester, () => repository.listCards(project.id))).length,
      2,
      reason: '正文焦点内Enter和Insert不能变成脑图创建命令',
    );
    await tester.tap(find.byTooltip('收起编辑'));
    await until(tester, () async => find.byType(CardEditor).evaluate().isEmpty);
    await clickMapNode(tester, childNode.id);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await until(
      tester,
      () async =>
          (await repository.listCards(project.id)).length == 3 &&
          find.byKey(const Key('map-title-input')).evaluate().isNotEmpty,
    );
    await idle(tester);
    final sibling = (await real(
      tester,
      () => repository.listCards(project.id),
    )).singleWhere((card) => card.id != parent.card.id && card.id != child.id);
    snapshot = await real(tester, () => repository.loadMap(map.id));
    final siblingNode = snapshot.nodes.singleWhere(
      (node) => node.cardId == sibling.id,
    );
    expect(siblingNode.parentNodeId, parent.node.id);
    expect(siblingNode.id, isNot(childNode.id));
    expect(sibling.id, isNot(child.id));
    expect(
      tester.widget<MindMapPane>(find.byType(MindMapPane)).selectedNodeId,
      siblingNode.id,
    );
    expect(
      tester
          .widget<EditableText>(
            find.descendant(
              of: find.byKey(const Key('map-title-input')),
              matching: find.byType(EditableText),
            ),
          )
          .focusNode
          .hasFocus,
      isTrue,
    );
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('空白双击新建顶层主题，画布落点与切换草稿跨重启保留', (tester) async {
    final project = await real(tester, () => repository.createProject('双击主题'));
    final map = (await real(
      tester,
      () => repository.listMaps(project.id),
    )).single;
    await real(
      tester,
      () => repository.setMapLayout(map.id, model.MapLayoutKind.free),
    );
    final parent = await real(
      tester,
      () => repository.createExcerpt(
        model.ExcerptDraft(
          projectId: project.id,
          mapId: map.id,
          title: '已选主题',
          text: '',
          anchors: const [],
          x: 80,
          y: 80,
        ),
      ),
    );
    await mount(tester);
    await clickMapNode(tester, parent.node.id);
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await until(
      tester,
      () async => find.byType(CardEditor).evaluate().isNotEmpty,
    );
    await idle(tester);
    const topLeft = Offset(-500, -300);
    const scale = .5;
    tester
        .widget<MindMapPane>(find.byType(MindMapPane))
        .controller!
        .setView(scale: scale, worldTopLeft: topLeft);
    await tester.pump();
    final viewport = tester.getRect(find.byType(MindMapPane));
    final localPoint = Offset(viewport.width * .75, viewport.height * .7);
    final point = viewport.topLeft + localPoint;
    final expectedWorld = topLeft + localPoint / scale;
    expect(viewport.contains(point), isTrue);
    expect(
      tester
          .hitTestOnBinding(point)
          .path
          .any(
            (entry) => identical(
              entry.target,
              tester.renderObject(find.byKey(const Key('map-background'))),
            ),
          ),
      isTrue,
      reason: '双击必须真实命中空白画布，而不是卡片或浮动菜单',
    );
    await tester.enterText(find.byKey(const Key('card-body')), '父主题待保存正文');
    expect(
      (await real(tester, () => repository.getCard(parent.card.id))).body,
      isEmpty,
    );
    await tester.tapAt(point, kind: ui.PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(point, kind: ui.PointerDeviceKind.mouse);
    await until(
      tester,
      () async =>
          (await repository.listCards(project.id)).length == 2 &&
          find.byType(CardEditor).evaluate().isNotEmpty &&
          tester.widget<CardEditor>(find.byType(CardEditor)).card.id !=
              parent.card.id,
    );
    await idle(tester);
    final created = (await real(
      tester,
      () => repository.listCards(project.id),
    )).singleWhere((card) => card.id != parent.card.id);
    final snapshot = await real(tester, () => repository.loadMap(map.id));
    final node = snapshot.nodes.singleWhere(
      (node) => node.cardId == created.id,
    );
    expect(node.parentNodeId, isNull, reason: '空白双击不继承之前选中卡片的父目标');
    expect(node.x, closeTo(expectedWorld.dx, .01));
    expect(node.y, closeTo(expectedWorld.dy, .01));
    expect(created.title, '新主题');
    expect(
      await real(tester, () => repository.getAnchors(created.id)),
      isEmpty,
    );
    expect(
      (await real(tester, () => repository.getCard(parent.card.id))).body,
      '父主题待保存正文',
    );
    expect(find.byType(CardEditor), findsOneWidget);
    expect(
      tester
          .widget<EditableText>(
            find.descendant(
              of: find.byKey(const Key('map-title-input')),
              matching: find.byType(EditableText),
            ),
          )
          .focusNode
          .hasFocus,
      isTrue,
      reason: '已有编辑器切换到新主题时标题编辑须获得焦点',
    );
    expect(find.byKey(const Key('map-title-input')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await until(
      tester,
      () async => find.byKey(const Key('map-title-input')).evaluate().isEmpty,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await until(
      tester,
      () async => tester
          .widget<EditableText>(
            find.descendant(
              of: find.byKey(const Key('card-body')),
              matching: find.byType(EditableText),
            ),
          )
          .focusNode
          .hasFocus,
    );
    await tester.enterText(find.byKey(const Key('card-body')), '双击主题尚未到自动保存时间');
    await tester.tap(find.byTooltip('收起编辑'));
    await until(tester, () async => find.byType(CardEditor).evaluate().isEmpty);
    await idle(tester);
    expect(
      (await real(tester, () => repository.getCard(created.id))).body,
      '双击主题尚未到自动保存时间',
    );
    expect(tester.takeException(), isNull);
    await unmount(tester);
    await real(tester, repository.close);
    repositoryClosed = true;
    final reopened = await real(
      tester,
      () => OpenNoteRepository.open(rootPath: '${temp.path}/library'),
    );
    try {
      final restored = await real(tester, () => reopened.loadMap(map.id));
      final restoredNode = restored.nodes.singleWhere(
        (value) => value.id == node.id,
      );
      expect(restoredNode.parentNodeId, isNull);
      expect(restoredNode.x, closeTo(expectedWorld.dx, .01));
      expect(restoredNode.y, closeTo(expectedWorld.dy, .01));
      expect(restored.cards[created.id]!.body, '双击主题尚未到自动保存时间');
      expect(restored.cards[parent.card.id]!.body, '父主题待保存正文');
    } finally {
      await real(tester, reopened.close);
    }
  });

  Future<({model.MindMap map, model.MapEdge edge})> relationshipFixture(
    WidgetTester tester,
  ) async {
    final project = await real(
      tester,
      () => repository.createProject('关系编辑会话'),
    );
    final map = (await real(
      tester,
      () => repository.listMaps(project.id),
    )).single;
    await real(
      tester,
      () => repository.setMapLayout(map.id, model.MapLayoutKind.free),
    );
    final topics = <model.ExcerptResult>[];
    for (var i = 0; i < 2; i++) {
      topics.add(
        await real(
          tester,
          () => repository.createExcerpt(
            model.ExcerptDraft(
              projectId: project.id,
              mapId: map.id,
              title: i == 0 ? '研究问题' : '研究结论',
              text: '完整正文继续保留',
              x: 80 + 340.0 * i,
              y: 80,
            ),
          ),
        ),
      );
    }
    final edge = await real(
      tester,
      () => repository.addAssociation(topics[0].node.id, topics[1].node.id),
    );
    await real(
      tester,
      () => repository.updateAssociation(edge.id, label: '支持'),
    );
    await mount(tester);
    await until(
      tester,
      () async => find
          .byKey(ValueKey('relationship-label-${edge.id}'))
          .evaluate()
          .isNotEmpty,
    );
    return (map: map, edge: edge);
  }

  Future<void> editRelationship(WidgetTester tester, String id) async {
    await tester.tap(find.byKey(ValueKey('relationship-label-$id')));
    await tester.pump(const Duration(milliseconds: 350));
    await until(
      tester,
      () async => find.byTooltip('编辑关系说明').evaluate().isNotEmpty,
    );
    await tester.tap(find.byTooltip('编辑关系说明'));
    await until(
      tester,
      () async => find
          .byKey(const Key('relationship-label-editor'))
          .evaluate()
          .isNotEmpty,
    );
  }

  testWidgets('关联工作台：空白创建终点与关联同一次撤销，保留原主题和正文', (tester) async {
    final fixture = await relationshipFixture(tester);
    final snapshot = await real(
      tester,
      () => repository.loadMap(fixture.map.id),
    );
    final source = snapshot.nodes.first;
    await clickMapNode(tester, source.id);
    await mapCanvasToolAction(tester, 'tool:association');
    await until(
      tester,
      () async => find
          .byKey(const ValueKey('map-association-mode'))
          .evaluate()
          .isNotEmpty,
    );
    final before = repository.undoEntryCount;
    final pane = tester.getRect(find.byType(MindMapPane));
    await tester.tapAt(pane.bottomRight - const Offset(120, 120));
    await until(
      tester,
      () async => (await repository.loadMap(fixture.map.id)).nodes.length == 3,
    );
    var after = await real(tester, () => repository.loadMap(fixture.map.id));
    final created = after.nodes.singleWhere(
      (n) => !snapshot.nodes.any((old) => old.id == n.id),
    );
    expect(created.parentNodeId, isNull);
    expect(
      after.edges.any(
        (e) => {e.fromNodeId, e.toNodeId}.containsAll({source.id, created.id}),
      ),
      isTrue,
    );
    expect(repository.undoEntryCount, before + 1);
    await tester.tap(find.byTooltip('撤销 Ctrl+Z'));
    await until(
      tester,
      () async => (await repository.loadMap(fixture.map.id)).nodes.length == 2,
    );
    after = await real(tester, () => repository.loadMap(fixture.map.id));
    expect(after.edges.single.id, fixture.edge.id);
    expect(after.cards[source.cardId]!.body, '完整正文继续保留');
    await unmount(tester);
  });

  testWidgets('概要工作台：工具条创建、标题保存和 Tab 子主题，一次命令一次撤销', (tester) async {
    final fixture = await relationshipFixture(tester);
    await tester.tap(find.byTooltip('适合全部卡片'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(ValueKey('map-node-${fixture.edge.fromNodeId}')),
    );
    await idle(tester);
    final before = repository.undoEntryCount;
    await mapCanvasToolAction(tester, 'tool:summary');
    await until(
      tester,
      () => Future.value(
        find.byKey(const Key('map-title-input')).evaluate().isNotEmpty,
      ),
    );
    var snapshot = await real(tester, () => repository.loadMap(fixture.map.id));
    final summary = snapshot.summaries.single;
    final topic = snapshot.nodes.singleWhere(
      (n) => n.id == summary.summaryNodeId,
    );
    expect(repository.undoEntryCount, before + 1);
    await tester.enterText(find.byKey(const Key('map-title-input')), '概括研究结论');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await until(
      tester,
      () async => (await repository.getCard(topic.cardId)).title == '概括研究结论',
    );
    await until(
      tester,
      () => Future.value(
        find.byKey(const Key('map-title-input')).evaluate().isEmpty &&
            find
                .byWidgetPredicate(
                  (w) =>
                      w is IconButton &&
                      w.key == const ValueKey('map-new-topic') &&
                      w.onPressed != null,
                )
                .evaluate()
                .isNotEmpty,
      ),
    );
    await idle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await until(
      tester,
      () async =>
          (await repository.loadMap(fixture.map.id)).nodes
              .any((n) => n.parentNodeId == topic.id),
    );
    await idle(tester);
    snapshot = await real(tester, () => repository.loadMap(fixture.map.id));
    expect(snapshot.summaries.single.id, summary.id);
    expect(
      snapshot.nodes.where((n) => n.parentNodeId == topic.id),
      hasLength(1),
    );
    await unmount(tester);
  });

  testWidgets('概要工作台：正式样式窗口保存和撤销，标题草稿切视图保存且无全局进度', (tester) async {
    final fixture = await relationshipFixture(tester);
    final ids = await real(
      tester,
      () =>
          repository.createSummaries(fixture.map.id, {fixture.edge.fromNodeId}),
    );
    await until(
      tester,
      () => Future.value(
        find.byKey(ValueKey('map-node-${ids.single}')).evaluate().isNotEmpty,
      ),
    );
    await tester.tap(find.byTooltip('适合全部卡片'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('map-node-${ids.single}')));
    await idle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await until(
      tester,
      () => Future.value(
        find.byKey(const Key('map-title-input')).evaluate().isNotEmpty,
      ),
    );
    await tester.enterText(find.byKey(const Key('map-title-input')), '概要草稿切换');
    await tester.tap(find.byTooltip('大纲').last);
    await until(
      tester,
      () => Future.value(find.byType(MapOutlinePane).evaluate().isNotEmpty),
    );
    var snapshot = await real(tester, () => repository.loadMap(fixture.map.id));
    final topic = snapshot.nodes.singleWhere((n) => n.id == ids.single);
    expect(snapshot.cards[topic.cardId]!.title, '概要草稿切换');
    await tester.tap(find.byTooltip('画布').last);
    await until(
      tester,
      () => Future.value(find.byTooltip('概要样式与范围').evaluate().isNotEmpty),
    );
    await idle(tester);
    final before = repository.undoEntryCount;
    await tester.tap(find.byTooltip('概要样式与范围'));
    await until(
      tester,
      () => Future.value(find.text('概要括号').evaluate().isNotEmpty),
    );
    expect(find.byType(LinearProgressIndicator), findsNothing);
    await settleUi(tester);
    await capture(tester, captureKey, 'xmind-summary-style-workbench-1920.png');
    await tester.tap(find.text('花括号').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('方括号').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await idle(tester);
    await until(
      tester,
      () async =>
          (await repository.loadMap(fixture.map.id))
              .summaries
              .single
              .style
              .bracket ==
          model.SummaryBracket.square,
    );
    expect(repository.undoEntryCount, before + 1);
    await until(
      tester,
      () => Future.value(
        tester.widget<MindMapPane>(find.byType(MindMapPane)).canCreate,
      ),
    );
    await settleUi(tester);
    await capture(tester, captureKey, 'xmind-summary-workbench-1920.png');
    await real(tester, repository.undo);
    snapshot = await real(tester, () => repository.loadMap(fixture.map.id));
    expect(snapshot.summaries.single.style.bracket, model.SummaryBracket.brace);
    await unmount(tester);
  });

  testWidgets('格式工作台：多选及子主题格式与默认同一次撤销，正式页签可用且不闪全局进度', (tester) async {
    final fixture = await relationshipFixture(tester);
    final child = await real(
      tester,
      () => repository.insertTopic(
        fixture.edge.fromNodeId,
        model.TopicInsertKind.child,
      ),
    );
    // 自由布局的新增子主题会与夹具的第二个自由主题重叠，先摆开再验证鼠标多选。
    await real(tester, () => repository.moveNode(child.node.id, 420, 300));
    await until(
      tester,
      () async => find
          .byKey(ValueKey('map-node-${child.node.id}'))
          .evaluate()
          .isNotEmpty,
    );
    await tester.tap(find.byTooltip('适合全部卡片'));
    await tester.pumpAndSettle();
    await clickMapNode(tester, fixture.edge.fromNodeId);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await clickMapNode(tester, fixture.edge.toNodeId);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await idle(tester);
    expect(
      tester.widget<MindMapPane>(find.byType(MindMapPane)).selectedNodeIds,
      {fixture.edge.fromNodeId, fixture.edge.toNodeId},
    );
    final before = repository.undoEntryCount;
    await mapNodeMenuAction(tester, group: 'styleMenu', action: 'topicStyle');
    await until(
      tester,
      () async => find.text('同时应用到子主题').evaluate().isNotEmpty,
    );
    await settleUi(tester);
    expect(find.text('2 个主题'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    await tester.enterText(
      find.byKey(const ValueKey('topic-style-填充颜色')),
      '#EAF1FC',
    );
    // 先完成颜色输入的光标滚动，再滚到字号，避免输入框的迟到回源覆盖滚动位置。
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await Scrollable.ensureVisible(
      tester.element(find.byKey(const ValueKey('topic-style-字号'))),
      alignment: .5,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('topic-style-字号')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('20').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('分支'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('topic-style-连线形状')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('折线').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('同时应用到子主题'));
    await tester.tap(find.text('设为本图默认格式'));
    await settleUi(tester);
    await capture(tester, captureKey, 'xmind-topic-style-workbench-1920.png');
    await tester.tap(find.text('保存'));
    await idle(tester);
    await until(
      tester,
      () async =>
          (await repository.loadMap(fixture.map.id)).nodes
              .every((n) => n.style?.surface.fill == '#EAF1FC'),
    );
    final snapshot = await real(
      tester,
      () => repository.loadMap(fixture.map.id),
    );
    expect(
      snapshot.nodes.every((n) => n.style!.surface.textSize == 20),
      isTrue,
    );
    expect(
      snapshot.nodes.every(
        (n) => n.style!.branch.path == model.BranchPath.elbow,
      ),
      isTrue,
    );
    expect(snapshot.map.defaultStyle.surface.fill, '#EAF1FC');
    expect(
      snapshot.cards.values.every(
        (c) => c.title == '新主题' || c.body == '完整正文继续保留',
      ),
      isTrue,
    );
    expect(repository.undoEntryCount, before + 1);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    await tester.tap(find.byTooltip('适合全部卡片'));
    await settleUi(tester);
    await capture(tester, captureKey, 'xmind-topic-format-workbench-1920.png');
    await real(tester, repository.undo);
    final restored = await real(
      tester,
      () => repository.loadMap(fixture.map.id),
    );
    expect(restored.nodes.every((n) => n.style == null), isTrue);
    expect(restored.map.defaultStyle, const model.TopicStyle());
    await unmount(tester);
  });

  testWidgets('格式工作台：默认格式从脑图菜单修改；标题草稿先保存，大纲格式与画布一致', (tester) async {
    final fixture = await relationshipFixture(tester);
    await tester.tap(find.byTooltip('适合全部卡片'));
    await tester.pumpAndSettle();
    await clickMapNode(tester, fixture.edge.fromNodeId);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await until(
      tester,
      () async =>
          find.byKey(const Key('map-title-input')).evaluate().isNotEmpty,
    );
    await tester.enterText(
      find.byKey(const Key('map-title-input')),
      '格式操作前的草稿',
    );
    await openMapStructureMenu(tester);
    final defaultMenuItem = find.text('脑图默认格式…').hitTestable();
    // 标题光标会持续安排帧，等待菜单可操作即可，不以停止所有动画作为条件。
    await until(tester, () async => defaultMenuItem.evaluate().isNotEmpty);
    await tester.tap(defaultMenuItem);
    await until(tester, () async => find.text('脑图默认格式').evaluate().isNotEmpty);
    await settleUi(tester);
    final snapshot = await real(
      tester,
      () => repository.loadMap(fixture.map.id),
    );
    final node = snapshot.nodes.singleWhere(
      (n) => n.id == fixture.edge.fromNodeId,
    );
    expect(snapshot.cards[node.cardId]!.title, '格式操作前的草稿');
    await tester.ensureVisible(find.byKey(const ValueKey('topic-style-文字颜色')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('topic-style-文字颜色')),
      '#C58035',
    );
    await tester.tap(find.text('保存'));
    await idle(tester);
    await until(
      tester,
      () async =>
          (await repository.loadMap(fixture.map.id))
              .map
              .defaultStyle
              .surface
              .textColor ==
          '#C58035',
    );
    await tester.tap(find.byTooltip('大纲').last);
    await until(
      tester,
      () async =>
          find
              .byKey(ValueKey('outline-title-${node.id}'))
              .evaluate()
              .isNotEmpty &&
          tester
                  .widget<Text>(
                    find.byKey(ValueKey('outline-title-${node.id}')),
                  )
                  .style!
                  .color ==
              const Color(0xffc58035),
    );
    final title = tester.widget<Text>(
      find.byKey(ValueKey('outline-title-${node.id}')),
    );
    expect(title.style!.color, const Color(0xffc58035));
    expect(title.style!.fontSize, 15);
    await settleUi(tester);
    await capture(tester, captureKey, 'xmind-topic-format-outline-1920.png');
    await unmount(tester);
  });

  testWidgets('混合结构工作台：精确多选先保存标题，结构一次撤销且大纲入口一致', (tester) async {
    final fixture = await relationshipFixture(tester);
    await tester.tap(find.byTooltip('适合全部卡片'));
    await settleUi(tester);
    await clickMapNode(tester, fixture.edge.fromNodeId);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await clickMapNode(tester, fixture.edge.toNodeId);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await idle(tester);
    final controller = tester
        .widget<MindMapPane>(find.byType(MindMapPane))
        .controller!;
    controller.editTitle(fixture.edge.fromNodeId);
    await until(
      tester,
      () async =>
          find.byKey(const ValueKey('map-title-input')).evaluate().isNotEmpty,
    );
    await tester.enterText(
      find.byKey(const ValueKey('map-title-input')),
      '分支结构前的中文草稿',
    );
    await openMapStructureMenu(tester);
    final menu = find.text('所选主题分支结构…').hitTestable();
    await until(tester, () async => menu.evaluate().isNotEmpty);
    await tester.tap(menu);
    await until(
      tester,
      () async => find
          .byKey(const ValueKey('branch-structure-choice'))
          .evaluate()
          .isNotEmpty,
    );
    final flushed = await real(
      tester,
      () => repository.loadMap(fixture.map.id),
    );
    expect(
      flushed
          .cards[flushed.nodes
              .singleWhere((n) => n.id == fixture.edge.fromNodeId)
              .cardId]!
          .title,
      '分支结构前的中文草稿',
    );
    expect(find.textContaining('所选 2 个主题'), findsOneWidget);
    final count = repository.undoEntryCount;
    await settleUi(tester);
    await tester.tap(find.byKey(const ValueKey('branch-structure-choice')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(model.MapLayoutKind.down.label).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await until(
      tester,
      () async =>
          (await repository.loadMap(fixture.map.id)).nodes
              .every((n) => n.branchLayout == model.MapLayoutKind.down),
    );
    expect(repository.undoEntryCount, count + 1);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    await tester.tap(find.byTooltip('大纲').last);
    await until(
      tester,
      () async =>
          find.byType(MapOutlinePane).evaluate().isNotEmpty &&
          tester
              .widget<MapOutlinePane>(find.byType(MapOutlinePane))
              .snapshot
              .nodes
              .every((n) => n.branchLayout == model.MapLayoutKind.down),
    );
    final outline = tester.widget<MapOutlinePane>(find.byType(MapOutlinePane));
    expect(outline.selectedNodeIds, {
      fixture.edge.fromNodeId,
      fixture.edge.toNodeId,
    });
    await ctrl(tester, LogicalKeyboardKey.keyZ);
    await until(
      tester,
      () async =>
          (await repository.loadMap(fixture.map.id)).nodes
              .every((n) => n.branchLayout == null),
    );
    expect(
      (await real(
        tester,
        () => repository.loadMap(fixture.map.id),
      )).cards.values.any((c) => c.title == '分支结构前的中文草稿'),
      isTrue,
    );
    await unmount(tester);
  });

  for (final narrow in [false, true]) {
    testWidgets(
      '自动布局归位工作台：${narrow ? '900宽与1.25倍文字' : '1920宽'}根节点平移、普通节点与多选归位不写坐标或撤销记录',
      (tester) async {
        final project = await real(
          tester,
          () => repository.createProject('自动布局拖动归位'),
        );
        final map = (await real(
          tester,
          () => repository.listMaps(project.id),
        )).single;
        final root = await real(
          tester,
          () => repository.createExcerpt(
            model.ExcerptDraft(
              projectId: project.id,
              mapId: map.id,
              title: '自动排列的主主题',
              text: '主主题正文',
              x: 80,
              y: 120,
            ),
          ),
        );
        final child = await real(
          tester,
          () =>
              repository.insertTopic(root.node.id, model.TopicInsertKind.child),
        );
        final other = await real(
          tester,
          () => repository.createExcerpt(
            model.ExcerptDraft(
              projectId: project.id,
              mapId: map.id,
              title: '另一个独立主主题',
              text: '',
              x: 80,
              y: 540,
            ),
          ),
        );
        final otherChild = await real(
          tester,
          () => repository.insertTopic(
            other.node.id,
            model.TopicInsertKind.child,
          ),
        );
        final before = await real(tester, () => repository.loadMap(map.id));
        final history = repository.undoEntryCount;
        await mount(tester);
        if (narrow) {
          await tester.binding.setSurfaceSize(const Size(900, 720));
          tester.platformDispatcher.textScaleFactorTestValue = 1.25;
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        }
        final paneFinder = find.byType(MindMapPane);
        await until(tester, () async => paneFinder.evaluate().isNotEmpty);
        final graph = tester.widget<MindMapPane>(paneFinder).controller!;
        graph.fitAll();
        await settleUi(tester);
        expect(find.byKey(const ValueKey('map-canvas-toolbar')), findsNothing);
        final toolbarFinder = find.byKey(
          const ValueKey('map-viewport-controls'),
        );
        final toolbar = tester.getRect(toolbarFinder);
        final canvas = tester.getRect(paneFinder);
        expect(canvas.right - toolbar.right, 12);
        expect(canvas.bottom - toolbar.bottom, 12);
        expect(toolbar.left, greaterThanOrEqualTo(canvas.left));
        for (final label in ['新建主题 Ctrl+N', '更多脑图工具', '适合全部卡片']) {
          expect(
            canvas.contains(tester.getCenter(find.byTooltip(label))),
            isTrue,
          );
        }
        expect(find.byTooltip('放大脑图'), findsNothing);
        expect(find.byTooltip('缩小脑图'), findsNothing);
        await openMapToolsMenu(tester);
        for (final label in ['框选卡片', '关联卡片', '添加外框', '添加概要']) {
          expect(find.text(label).hitTestable(), findsOneWidget);
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await waitForMapToolsClosed(tester);
        final scale = graph.scale;
        Future<Offset> dragToBlank(String id, {bool panCanvas = false}) async {
          final node = find.byKey(ValueKey('map-node-$id'));
          final original = tester.getRect(node);
          final held = await tester.startGesture(
            tester.getCenter(node),
            kind: ui.PointerDeviceKind.mouse,
          );
          await held.moveBy(const Offset(24, 0));
          await advance(tester);
          await held.moveBy(const Offset(40, 20));
          await tester.pump();
          final delta = tester.getRect(node).topLeft - original.topLeft;
          if (panCanvas) {
            expect(delta.distance, greaterThan(20));
          } else {
            expect(tester.getRect(node).left, closeTo(original.left + 64, .1));
          }
          await held.up();
          await tester.pump();
          await idle(tester);
          expect(
            tester.getRect(node),
            rectMoreOrLessEquals(
              panCanvas ? original.shift(delta) : original,
              epsilon: .000001,
            ),
          );
          expect(tester.getRect(toolbarFinder), toolbar);
          expect(find.byType(LinearProgressIndicator), findsNothing);
          return delta;
        }

        await dragToBlank(root.node.id, panCanvas: true);
        await dragToBlank(child.node.id);
        await clickMapNode(tester, root.node.id);
        await ctrlClickNode(
          tester,
          other.node.id,
          expected: {root.node.id, other.node.id},
          primary: other.node.id,
        );
        graph.fitAll();
        await advance(tester);
        final otherRect = tester.getRect(
          find.byKey(ValueKey('map-node-${other.node.id}')),
        );
        final panDelta = await dragToBlank(root.node.id, panCanvas: true);
        expect(
          tester.getRect(find.byKey(ValueKey('map-node-${other.node.id}'))),
          rectMoreOrLessEquals(otherRect.shift(panDelta), epsilon: .000001),
        );
        expect(tester.widget<MindMapPane>(paneFinder).selectedNodeIds, {
          root.node.id,
          other.node.id,
        });
        await clickMapNode(tester, child.node.id);
        await ctrlClickNode(
          tester,
          otherChild.node.id,
          expected: {child.node.id, otherChild.node.id},
          primary: otherChild.node.id,
        );
        graph.fitAll();
        await advance(tester);
        final otherChildRect = tester.getRect(
          find.byKey(ValueKey('map-node-${otherChild.node.id}')),
        );
        await dragToBlank(child.node.id);
        expect(
          tester.getRect(
            find.byKey(ValueKey('map-node-${otherChild.node.id}')),
          ),
          otherChildRect,
        );
        expect(repository.undoEntryCount, history);
        final saved = await real(tester, () => repository.loadMap(map.id));
        expect(
          saved.nodes.map((n) => [n.id, n.parentNodeId, n.x, n.y, n.sortIndex]),
          before.nodes.map(
            (n) => [n.id, n.parentNodeId, n.x, n.y, n.sortIndex],
          ),
        );
        expect(graph.scale, scale);
        await capture(
          tester,
          captureKey,
          'map-interaction-${narrow ? '900-text125' : '1920'}.png',
        );
        expect(tester.takeException(), isNull);
        await unmount(tester);
      },
    );
  }

  for (final free in [false, true]) {
    testWidgets('自动拖入工作台：${free ? '自由分支' : '默认自动'}成为子卡后按保存位置绘制，撤销且工具栏稳定', (
      tester,
    ) async {
      final project = await real(
        tester,
        () => repository.createProject('拖入自动排版'),
      );
      final map = (await real(
        tester,
        () => repository.listMaps(project.id),
      )).single;
      expect(map.layout, model.MapLayoutKind.right);
      if (free) {
        await real(
          tester,
          () => repository.setMapLayout(map.id, model.MapLayoutKind.free),
        );
      }
      Future<model.ExcerptResult> topic(
        String title,
        double x,
        double y, {
        String? parent,
      }) => real(
        tester,
        () => repository.createExcerpt(
          model.ExcerptDraft(
            projectId: project.id,
            mapId: map.id,
            title: title,
            text: '正文 $title',
            parentNodeId: parent,
            x: x,
            y: y,
          ),
        ),
      );
      final parent = await topic('知识整理', 80, 120);
      await topic('已有知识点', 400, 120, parent: parent.node.id);
      final originalParent = free
          ? null
          : (await topic('来源主主题', 80, 540)).node.id;
      final source = await topic(
        '拖入后应自动排列',
        free ? 80 : 400,
        540,
        parent: originalParent,
      );
      final child = await topic('随分支排列的后代', 400, 540, parent: source.node.id);
      await topic('独立知识区', 80, 1000);
      final before = await real(tester, () => repository.loadMap(map.id));
      final count = repository.undoEntryCount;
      await mount(tester);
      final paneFinder = find.byType(MindMapPane);
      final sourceFinder = find.byKey(ValueKey('map-node-${source.node.id}'));
      final parentFinder = find.byKey(ValueKey('map-node-${parent.node.id}'));
      await until(tester, () async => sourceFinder.evaluate().isNotEmpty);
      await tester.tap(find.byTooltip('适合全部卡片'));
      await settleUi(tester);
      final tools = tester.getRect(find.byTooltip('返回项目主页'));
      final viewScale = tester
          .widget<MindMapPane>(paneFinder)
          .controller!
          .scale;
      final held = await tester.startGesture(
        tester.getCenter(sourceFinder),
        kind: ui.PointerDeviceKind.mouse,
      );
      await held.moveBy(const Offset(25, 0));
      await tester.pump();
      await held.moveTo(tester.getCenter(parentFinder));
      await tester.pump();
      expect(find.text('加入子主题'), findsOneWidget);
      expect(tester.getRect(find.byTooltip('返回项目主页')), tools);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      await held.up();
      await until(
        tester,
        () async =>
            (await repository.loadMap(map.id)).nodes
                    .singleWhere((n) => n.id == source.node.id)
                    .parentNodeId ==
                parent.node.id &&
            tester
                    .widget<MindMapPane>(paneFinder)
                    .snapshot
                    .nodes
                    .singleWhere((n) => n.id == source.node.id)
                    .parentNodeId ==
                parent.node.id,
      );
      await idle(tester);
      final saved = await real(tester, () => repository.loadMap(map.id));
      final s = saved.nodes.singleWhere((n) => n.id == source.node.id);
      final p = saved.nodes.singleWhere((n) => n.id == parent.node.id);
      expect(s.x, greaterThanOrEqualTo(p.x + p.width + 72));
      expect(
        saved.nodes.singleWhere((n) => n.id == child.node.id).parentNodeId,
        s.id,
      );
      final sRect = tester.getRect(sourceFinder),
          pRect = tester.getRect(parentFinder);
      expect(sRect.overlaps(pRect), isFalse, reason: '提交帧不能残留覆盖父卡片的鼠标落点');
      final scale = sRect.width / s.width;
      expect(sRect.left - pRect.left, closeTo((s.x - p.x) * scale, .1));
      expect(sRect.top - pRect.top, closeTo((s.y - p.y) * scale, .1));
      expect(repository.undoEntryCount, count + 1);
      expect(tester.getRect(find.byTooltip('返回项目主页')), tools);
      expect(
        tester.widget<MindMapPane>(paneFinder).controller!.scale,
        viewScale,
      );
      expect(
        tester.widget<MindMapPane>(paneFinder).selectedNodeId,
        source.node.id,
      );
      expect(find.byType(LinearProgressIndicator), findsNothing);
      if (!free) {
        await capture(tester, captureKey, 'map-auto-drop-complete-1920.png');
      }
      await ctrl(tester, LogicalKeyboardKey.keyZ);
      await until(
        tester,
        () async =>
            (await repository.loadMap(map.id)).nodes
                .singleWhere((n) => n.id == source.node.id)
                .parentNodeId ==
            originalParent,
      );
      final restored = await real(tester, () => repository.loadMap(map.id));
      expect(restored.map.layout, before.map.layout);
      expect(
        restored.nodes.map(
          (n) => [n.id, n.parentNodeId, n.x, n.y, n.branchLayout, n.sortIndex],
        ),
        before.nodes.map(
          (n) => [n.id, n.parentNodeId, n.x, n.y, n.branchLayout, n.sortIndex],
        ),
      );
      expect(tester.takeException(), isNull);
      await unmount(tester);
    });
  }

  testWidgets('混合结构工作台：鼠标同级插入一次保存、失败回滚且工具栏不闪动', (tester) async {
    final fixture = await relationshipFixture(tester);
    await real(
      tester,
      () => repository.setMapLayout(fixture.map.id, model.MapLayoutKind.right),
    );
    final root = fixture.edge.fromNodeId;
    final a = await real(
      tester,
      () => repository.insertTopic(root, model.TopicInsertKind.child),
    );
    final b = await real(
      tester,
      () =>
          repository.insertTopic(a.node.id, model.TopicInsertKind.siblingAfter),
    );
    final c = await real(
      tester,
      () =>
          repository.insertTopic(b.node.id, model.TopicInsertKind.siblingAfter),
    );
    await real(
      tester,
      () => repository.setBranchLayout(fixture.map.id, {
        a.node.id,
      }, model.MapLayoutKind.down),
    );
    await real(
      tester,
      () => repository.insertTopic(a.node.id, model.TopicInsertKind.child),
    );
    final paneFinder = find.byType(MindMapPane);
    await until(
      tester,
      () async => tester
          .widget<MindMapPane>(paneFinder)
          .snapshot
          .nodes
          .any((n) => n.id == c.node.id),
    );
    await tester.tap(find.byTooltip('适合全部卡片'));
    await settleUi(tester);
    final tools = tester.getRect(find.byTooltip('返回项目主页'));
    final history = repository.undoEntryCount;
    final originalRect = tester.getRect(
      find.byKey(ValueKey('map-node-${c.node.id}')),
    );
    final originalInCanvas = originalRect.shift(-tester.getTopLeft(paneFinder));
    Future<void> dropBefore(
      String source,
      String target, {
      bool screenshot = false,
    }) async {
      final targetRect = tester.getRect(
        find.byKey(ValueKey('map-node-$target')),
      );
      final held = await tester.startGesture(
        tester.getCenter(find.byKey(ValueKey('map-node-$source'))),
        kind: ui.PointerDeviceKind.mouse,
      );
      await held.moveBy(const Offset(25, 0));
      await tester.pump();
      await held.moveTo(Offset(targetRect.center.dx, targetRect.top + 4));
      await tester.pump();
      expect(find.text('插入前面'), findsOneWidget);
      expect(find.byKey(const ValueKey('map-drop-insertion')), findsOneWidget);
      expect(tester.getRect(find.byTooltip('返回项目主页')), tools);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      if (screenshot) {
        await capture(
          tester,
          captureKey,
          'xmind-mixed-structure-drop-1920.png',
        );
      }
      await held.up();
      await idle(tester);
    }

    await dropBefore(c.node.id, a.node.id, screenshot: true);
    await until(
      tester,
      () async =>
          (await repository.loadMap(fixture.map.id)).nodes
              .singleWhere((n) => n.id == c.node.id)
              .sortIndex ==
          0,
    );
    expect(repository.undoEntryCount, history + 1);
    expect(tester.getRect(find.byTooltip('返回项目主页')), tools);
    await ctrl(tester, LogicalKeyboardKey.keyZ);
    await until(
      tester,
      () async =>
          (await repository.loadMap(fixture.map.id)).nodes
              .singleWhere((n) => n.id == c.node.id)
              .sortIndex ==
          2,
    );
    final db = await real(
      tester,
      () async =>
          sqlite.sqlite3.open('${repository.libraryPath}/library.sqlite'),
    );
    await real(
      tester,
      () async => db.execute(
        "CREATE TRIGGER reject_drop BEFORE UPDATE ON nodes WHEN NEW.id='${c.node.id}' AND NEW.sort_index=0 BEGIN SELECT RAISE(ABORT,'拖放保存失败'); END",
      ),
    );
    await until(
      tester,
      () async =>
          find.byType(LinearProgressIndicator).evaluate().isEmpty &&
          tester
                  .widget<MindMapPane>(paneFinder)
                  .snapshot
                  .nodes
                  .singleWhere((n) => n.id == c.node.id)
                  .sortIndex ==
              2,
    );
    await idle(tester);
    expect(
      tester.getRect(find.byKey(ValueKey('map-node-${c.node.id}'))),
      originalRect,
      reason: '立即撤销后按保存坐标绘制，不能残留上一手势的预览位置',
    );
    await dropBefore(c.node.id, a.node.id);
    await until(
      tester,
      () async => find.textContaining('拖放保存失败').evaluate().isNotEmpty,
    );
    await advance(tester);
    expect(repository.undoEntryCount, history);
    final rejected = await real(
      tester,
      () => repository.loadMap(fixture.map.id),
    );
    expect(rejected.nodes.singleWhere((n) => n.id == c.node.id).sortIndex, 2);
    // 错误栏会移动整个内容区；节点必须回到原来的画布坐标。
    expect(
      tester
          .getRect(find.byKey(ValueKey('map-node-${c.node.id}')))
          .shift(-tester.getTopLeft(paneFinder)),
      originalInCanvas,
      reason: '保存失败后恢复原位置并继续接受拖动',
    );
    expect(tester.getRect(find.byTooltip('返回项目主页')), tools);
    await real(tester, () async {
      db.execute('DROP TRIGGER reject_drop');
      db.close();
    });
    await unmount(tester);
  });

  Future<({model.MindMap map, String id})> boundaryFixture(
    WidgetTester tester,
  ) async {
    final fixture = await relationshipFixture(tester);
    final ids = await real(
      tester,
      () => repository.createBoundaries(fixture.map.id, {
        fixture.edge.fromNodeId,
      }),
    );
    await real(
      tester,
      () => repository.updateBoundary(ids.single, label: '分组说明'),
    );
    await until(
      tester,
      () async => find
          .byKey(ValueKey('boundary-label-${ids.single}'))
          .evaluate()
          .isNotEmpty,
    );
    return (map: fixture.map, id: ids.single);
  }

  Future<void> editBoundary(WidgetTester tester, String id) async {
    await tester.tap(find.byKey(ValueKey('boundary-label-$id')));
    await tester.pump(const Duration(milliseconds: 350));
    await until(
      tester,
      () async => find.byTooltip('编辑外框说明').evaluate().isNotEmpty,
    );
    await tester.tap(find.byTooltip('编辑外框说明'));
    await until(
      tester,
      () async =>
          find.byKey(const Key('boundary-label-editor')).evaluate().isNotEmpty,
    );
  }

  testWidgets('外框工作台：切换大纲及返回主页保存草稿，一次编辑一次撤销', (tester) async {
    final fixture = await boundaryFixture(tester),
        before = repository.undoEntryCount;
    await editBoundary(tester, fixture.id);
    await tester.enterText(
      find.byKey(const Key('boundary-label-editor')),
      '切换前的分组说明',
    );
    await tester.tap(find.byTooltip('大纲').last);
    await idle(tester);
    await until(
      tester,
      () async => tester
          .widget<OpenNoteViewSwitch>(find.byKey(const Key('map-view-switch')))
          .value,
    );
    await until(
      tester,
      () async =>
          (await repository.loadMap(fixture.map.id)).boundaries.single.label ==
          '切换前的分组说明',
    );
    expect(repository.undoEntryCount, before + 1);
    await tester.tap(find.byTooltip('画布').last);
    await idle(tester);
    await until(
      tester,
      () async => !tester
          .widget<OpenNoteViewSwitch>(find.byKey(const Key('map-view-switch')))
          .value,
    );
    await editBoundary(tester, fixture.id);
    await tester.enterText(
      find.byKey(const Key('boundary-label-editor')),
      '返回前分组草稿',
    );
    await tester.tap(find.byTooltip('返回项目主页'));
    await until(tester, () async => find.byType(Workbench).evaluate().isEmpty);
    expect(
      (await real(
        tester,
        () => repository.loadMap(fixture.map.id),
      )).boundaries.single.label,
      '返回前分组草稿',
    );
    expect(repository.undoEntryCount, before + 2);
    await real(tester, repository.undo);
    expect(
      (await real(
        tester,
        () => repository.loadMap(fixture.map.id),
      )).boundaries.single.label,
      '切换前的分组说明',
    );
    await unmount(tester);
  });
  testWidgets('外框工作台：保存失败留在原位，恢复后返回可重试', (tester) async {
    final fixture = await boundaryFixture(tester);
    await editBoundary(tester, fixture.id);
    await tester.enterText(
      find.byKey(const Key('boundary-label-editor')),
      '不可丢失的分组草稿',
    );
    final guard = sqlite.sqlite3.open(
      '${repository.libraryPath}/library.sqlite',
    );
    try {
      guard.execute(
        "CREATE TRIGGER reject_boundary BEFORE UPDATE OF label ON boundaries BEGIN SELECT RAISE(FAIL,'验证外框保存失败'); END",
      );
      await tester.tap(find.byTooltip('返回项目主页'));
      await until(
        tester,
        () => Future.value(
          find.textContaining('验证外框保存失败').evaluate().isNotEmpty ||
              find.textContaining('待完成操作失败').evaluate().isNotEmpty,
        ),
      );
      expect(find.byType(Workbench), findsOneWidget);
      expect(
        tester
            .widget<MindMapPane>(find.byType(MindMapPane))
            .controller!
            .boundaryDraft!
            .label,
        '不可丢失的分组草稿',
      );
      expect(
        (await real(
          tester,
          () => repository.loadMap(fixture.map.id),
        )).boundaries.single.label,
        '分组说明',
      );
      guard.execute('DROP TRIGGER reject_boundary');
      await until(
        tester,
        () => Future.value(
          tester.widget<MindMapPane>(find.byType(MindMapPane)).canCreate,
        ),
      );
      await tester.tap(find.byTooltip('返回项目主页'));
      await until(
        tester,
        () => Future.value(find.byType(Workbench).evaluate().isEmpty),
      );
      expect(
        (await real(
          tester,
          () => repository.loadMap(fixture.map.id),
        )).boundaries.single.label,
        '不可丢失的分组草稿',
      );
      await unmount(tester);
    } finally {
      guard.close();
    }
  });
  testWidgets('外框工作台：正式样式弹窗原子保存、撤销且不显示忙碌进度', (tester) async {
    final fixture = await boundaryFixture(tester),
        before = repository.undoEntryCount;
    await tester.tap(find.byKey(ValueKey('boundary-label-${fixture.id}')));
    await tester.pump(const Duration(milliseconds: 350));
    await until(
      tester,
      () => Future.value(find.byTooltip('外框样式与范围').evaluate().isNotEmpty),
    );
    await tester.tap(find.byTooltip('外框样式与范围'));
    await until(
      tester,
      () => Future.value(
        find.byKey(const Key('boundary-description')).evaluate().isNotEmpty,
      ),
    );
    expect(find.byType(LinearProgressIndicator), findsNothing);
    await settleUi(tester);
    await capture(
      tester,
      captureKey,
      'xmind-boundary-style-workbench-1920.png',
    );
    await tester.enterText(
      find.byKey(const Key('boundary-description')),
      '样式分组',
    );
    await tester.tap(find.text('保存'));
    await idle(tester);
    await until(
      tester,
      () async =>
          (await repository.loadMap(fixture.map.id)).boundaries.single.label ==
          '样式分组',
    );
    expect(repository.undoEntryCount, before + 1);
    await until(
      tester,
      () async =>
          find.text('样式分组').evaluate().isNotEmpty &&
          tester.widget<MindMapPane>(find.byType(MindMapPane)).canCreate,
    );
    await until(
      tester,
      () async =>
          tester
              .widget<IconButton>(
                find.byWidgetPredicate(
                  (widget) =>
                      widget is IconButton && widget.tooltip == '适合全部卡片',
                ),
              )
              .onPressed !=
          null,
    );
    await capture(tester, captureKey, 'xmind-boundary-workbench-1920.png');
    await real(tester, repository.undo);
    expect(
      (await real(
        tester,
        () => repository.loadMap(fixture.map.id),
      )).boundaries.single.label,
      '分组说明',
    );
    await unmount(tester);
  });

  testWidgets('关联工作台：说明草稿视图切换和返回主页各保存一次，撤销不混入导航', (tester) async {
    final fixture = await relationshipFixture(tester);
    final before = repository.undoEntryCount;
    await editRelationship(tester, fixture.edge.id);
    await tester.enterText(
      find.byKey(const Key('relationship-label-editor')),
      '切换前的中文关系',
    );
    await tester.tap(find.byTooltip('大纲').last);
    await until(
      tester,
      () async => find.byType(MapOutlinePane).evaluate().isNotEmpty,
    );
    expect(
      (await real(
        tester,
        () => repository.loadMap(fixture.map.id),
      )).edges.single.label,
      '切换前的中文关系',
    );
    expect(repository.undoEntryCount, before + 1);
    await tester.tap(find.byTooltip('画布').last);
    await until(
      tester,
      () async => find
          .byKey(ValueKey('relationship-label-${fixture.edge.id}'))
          .evaluate()
          .isNotEmpty,
    );
    await editRelationship(tester, fixture.edge.id);
    await tester.enterText(
      find.byKey(const Key('relationship-label-editor')),
      '返回主页前的草稿',
    );
    await tester.tap(find.byTooltip('返回项目主页'));
    await until(tester, () async => find.byType(Workbench).evaluate().isEmpty);
    expect(
      (await real(
        tester,
        () => repository.loadMap(fixture.map.id),
      )).edges.single.label,
      '返回主页前的草稿',
    );
    expect(repository.undoEntryCount, before + 2);
    await real(tester, repository.undo);
    expect(
      (await real(
        tester,
        () => repository.loadMap(fixture.map.id),
      )).edges.single.label,
      '切换前的中文关系',
    );
    await unmount(tester);
  });

  testWidgets('关联工作台：保存失败不离开或丢草稿，修复后返回可重试', (tester) async {
    final fixture = await relationshipFixture(tester);
    await editRelationship(tester, fixture.edge.id);
    await tester.enterText(
      find.byKey(const Key('relationship-label-editor')),
      '不能丢失的关系草稿',
    );
    final guard = sqlite.sqlite3.open(
      '${repository.libraryPath}/library.sqlite',
    );
    try {
      guard.execute(
        "CREATE TRIGGER reject_relationship BEFORE UPDATE OF label ON edges BEGIN SELECT RAISE(FAIL, '验证关联保存失败'); END;",
      );
      await tester.tap(find.byTooltip('返回项目主页'));
      await until(
        tester,
        () async =>
            find.textContaining('待完成操作失败').evaluate().isNotEmpty ||
            find.textContaining('验证关联保存失败').evaluate().isNotEmpty,
      );
      expect(find.byType(Workbench), findsOneWidget);
      expect(
        find.byKey(const Key('relationship-label-editor')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<MindMapPane>(find.byType(MindMapPane))
            .controller!
            .relationshipDraft!
            .label,
        '不能丢失的关系草稿',
      );
      expect(
        (await real(
          tester,
          () => repository.loadMap(fixture.map.id),
        )).edges.single.label,
        '支持',
      );
      guard.execute('DROP TRIGGER reject_relationship');
      await until(
        tester,
        () async =>
            tester.widget<MindMapPane>(find.byType(MindMapPane)).canCreate,
      );
      await tester.tap(find.byTooltip('返回项目主页'));
      await until(
        tester,
        () async => find.byType(Workbench).evaluate().isEmpty,
      );
      expect(
        (await real(
          tester,
          () => repository.loadMap(fixture.map.id),
        )).edges.single.label,
        '不能丢失的关系草稿',
      );
      await unmount(tester);
    } finally {
      guard.close();
    }
  });

  testWidgets('关联工作台：样式弹窗说明与线条原子保存、撤销恢复两者', (tester) async {
    final fixture = await relationshipFixture(tester);
    await tester.tap(
      find.byKey(ValueKey('relationship-label-${fixture.edge.id}')),
    );
    await tester.pump(const Duration(milliseconds: 350));
    await until(
      tester,
      () async => find.byTooltip('关联线样式').evaluate().isNotEmpty,
    );
    await tester.tap(find.byTooltip('关联线样式'));
    await until(
      tester,
      () async => find
          .byKey(const Key('relationship-description'))
          .evaluate()
          .isNotEmpty,
    );
    await tester.enterText(
      find.byKey(const Key('relationship-description')),
      '决定性的影响',
    );
    await tester.enterText(
      find.byKey(const Key('relationship-line-color')),
      '#3574CB',
    );
    await settleUi(tester);
    expect(
      find.descendant(
        of: find.byType(MindMapPane),
        matching: find.byType(LinearProgressIndicator),
      ),
      findsNothing,
      reason: '样式弹窗等待用户输入时不显示保存进度',
    );
    await capture(
      tester,
      captureKey,
      'xmind-relationship-style-workbench-1920.png',
    );
    final before = repository.undoEntryCount;
    await tester.tap(find.byKey(const Key('relationship-style-save')));
    await until(
      tester,
      () async =>
          (await repository.loadMap(fixture.map.id)).edges.single.label ==
          '决定性的影响',
    );
    expect(repository.undoEntryCount, before + 1);
    expect(
      (await real(
        tester,
        () => repository.loadMap(fixture.map.id),
      )).edges.single.style.color,
      '#3574CB',
    );
    await tester.tap(find.byTooltip('撤销 Ctrl+Z'));
    await until(
      tester,
      () async =>
          (await repository.loadMap(fixture.map.id)).edges.single.label == '支持',
    );
    expect(
      (await real(
        tester,
        () => repository.loadMap(fixture.map.id),
      )).edges.single.style.color,
      '#C58035',
    );
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('画布标题草稿返回主页时保存，空标题失败保留工作台并允许重试', (tester) async {
    final project = await real(tester, () => repository.createProject('标题会话'));
    final map = (await real(
      tester,
      () => repository.listMaps(project.id),
    )).single;
    await real(
      tester,
      () => repository.setMapLayout(map.id, model.MapLayoutKind.free),
    );
    final topic = await real(
      tester,
      () => repository.createExcerpt(
        model.ExcerptDraft(
          projectId: project.id,
          mapId: map.id,
          title: '原主题',
          text: '保留正文',
          x: 80,
          y: 80,
        ),
      ),
    );
    await mount(tester);
    await clickMapNode(tester, topic.node.id);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await until(
      tester,
      () async =>
          find.byKey(const Key('map-title-input')).evaluate().isNotEmpty,
    );
    await tester.enterText(find.byKey(const Key('map-title-input')), '');
    await tester.tap(find.byTooltip('返回项目主页'));
    await until(
      tester,
      () async =>
          find.byType(Workbench).evaluate().isNotEmpty &&
          tester.widget<MindMapPane>(find.byType(MindMapPane)).canCreate,
    );
    expect(find.byKey(const Key('map-title-input')), findsOneWidget);
    expect(
      (await real(tester, () => repository.getCard(topic.card.id))).title,
      '原主题',
    );
    await settleUi(tester);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('map-title-input')))
          .readOnly,
      isFalse,
    );
    await tester.enterText(
      find.byKey(const Key('map-title-input')),
      '修正后的中文标题',
    );
    expect(
      tester
          .widget<MindMapPane>(find.byType(MindMapPane))
          .controller!
          .titleDraft!
          .title,
      '修正后的中文标题',
    );
    await tester.tap(find.byTooltip('返回项目主页'));
    await until(tester, () async => find.byType(Workbench).evaluate().isEmpty);
    final saved = await real(tester, () => repository.getCard(topic.card.id));
    expect(saved.title, '修正后的中文标题');
    expect(saved.body, '保留正文');
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('大纲连续建主题与视图切换保存标题，失败不切换且返回主页提交草稿', (tester) async {
    final project = await real(tester, () => repository.createProject('大纲编辑'));
    final map = (await real(
      tester,
      () => repository.listMaps(project.id),
    )).single;
    await real(
      tester,
      () => repository.setMapLayout(map.id, model.MapLayoutKind.free),
    );
    final parent = await real(
      tester,
      () => repository.createExcerpt(
        model.ExcerptDraft(
          projectId: project.id,
          mapId: map.id,
          title: '大纲父主题',
          text: '父主题正文',
          x: 80,
          y: 80,
        ),
      ),
    );
    await mount(tester);
    await clickMapNode(tester, parent.node.id);
    await switchMapView(tester, outline: true);
    await clickOutlineNode(tester, parent.node.id);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    final outlineInput = find.byKey(const Key('outline-title-input'));
    await until(
      tester,
      () async =>
          outlineInput.evaluate().isNotEmpty &&
          (await repository.listCards(project.id)).length == 2,
    );
    await idle(tester);
    final child = (await real(
      tester,
      () => repository.listCards(project.id),
    )).singleWhere((card) => card.id != parent.card.id);
    final childNode = (await real(
      tester,
      () => repository.loadMap(map.id),
    )).nodes.singleWhere((node) => node.cardId == child.id);
    expect(childNode.parentNodeId, parent.node.id);
    expect(
      tester.widget<MapOutlinePane>(find.byType(MapOutlinePane)).selectedNodeId,
      childNode.id,
    );
    expect(tester.widget<TextField>(outlineInput).focusNode!.hasFocus, isTrue);
    await tester.enterText(outlineInput, '大纲中文子主题');
    await tester.pump();
    await capture(tester, captureKey, 'xmind-outline-title-1920x1080.png');
    await switchMapView(tester, outline: false);
    expect(
      (await real(tester, () => repository.getCard(child.id))).title,
      '大纲中文子主题',
    );
    await clickMapNode(tester, childNode.id);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    final canvasInput = find.byKey(const Key('map-title-input'));
    await until(tester, () async => canvasInput.evaluate().isNotEmpty);
    await tester.enterText(canvasInput, '');
    await tester.tap(
      find
          .descendant(
            of: find.byKey(const Key('map-view-switch')),
            matching: find.byType(TextButton),
          )
          .at(1),
    );
    await until(
      tester,
      () async =>
          tester.widget<MindMapPane>(find.byType(MindMapPane)).canCreate,
    );
    await settleUi(tester);
    expect(find.byType(MapOutlinePane), findsNothing);
    expect(canvasInput, findsOneWidget);
    expect(
      (await real(tester, () => repository.getCard(child.id))).title,
      '大纲中文子主题',
    );
    // 错误浮层覆盖工具条；通过真实关闭入口再修正草稿。
    expect(find.text('名称不能为空。'), findsWidgets);
    await until(
      tester,
      () => Future.value(!tester.widget<TextField>(canvasInput).readOnly),
    );
    await tester.enterText(canvasInput, '修正后的主题');
    await tester.pump();
    expect(tester.widget<TextField>(canvasInput).controller!.text, '修正后的主题');
    await tester.tap(find.byTooltip('关闭错误提示'));
    await idle(tester);
    await switchMapView(tester, outline: true);
    await clickOutlineNode(tester, childNode.id);
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await until(
      tester,
      () async => find.byType(CardEditor).evaluate().isNotEmpty,
    );
    expect(
      tester.widget<CardEditor>(find.byType(CardEditor)).card.id,
      child.id,
    );
    await tester.enterText(find.byKey(const Key('card-body')), '独立子主题正文');
    await clickOutlineNode(tester, childNode.id);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await until(tester, () async => outlineInput.evaluate().isNotEmpty);
    await tester.enterText(outlineInput, '离开前大纲草稿');
    await tester.tap(find.byTooltip('返回项目主页'));
    await until(tester, () async => find.byType(Workbench).evaluate().isEmpty);
    final saved = await real(tester, () => repository.getCard(child.id));
    expect(saved.title, '离开前大纲草稿');
    expect(saved.body, '独立子主题正文');
    expect(
      (await real(tester, () => repository.getCard(parent.card.id))).body,
      '父主题正文',
    );
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('脑图剪贴板复制捕获草稿，粘贴与撤销在工作台保持独立卡片', (tester) async {
    String? clipboardText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboardText = (call.arguments as Map)['text'] as String?;
        }
        if (call.method == 'Clipboard.getData') return {'text': clipboardText};
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final project = await real(
      tester,
      () => repository.createProject('剪贴板工作台'),
    );
    final map = (await real(
      tester,
      () => repository.listMaps(project.id),
    )).single;
    await real(
      tester,
      () => repository.setMapLayout(map.id, model.MapLayoutKind.free),
    );
    final source = await real(
      tester,
      () => repository.createExcerpt(
        model.ExcerptDraft(
          projectId: project.id,
          mapId: map.id,
          title: '复制主题',
          text: '旧正文',
          x: 80,
          y: 80,
        ),
      ),
    );
    await mount(tester);
    await clickMapNode(tester, source.node.id);
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await until(
      tester,
      () async => find.byType(CardEditor).evaluate().isNotEmpty,
    );
    await tester.enterText(find.byKey(const Key('card-body')), '复制时尚未自动保存的正文');
    await clickMapNode(tester, source.node.id);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await until(
      tester,
      () async =>
          (await repository.getCard(source.card.id)).body == '复制时尚未自动保存的正文',
    );
    await idle(tester);
    // 系统剪贴板已经完成的复制信号，不能只依据选择完成就开始粘贴。
    await until(
      tester,
      () async => find.textContaining('已复制 1 个主题').evaluate().isNotEmpty,
    );
    expect(find.byType(SnackBar), findsNothing);
    final feedback = find.byKey(const Key('map-clipboard-feedback'));
    final header = tester.getRect(
      find.byKey(const Key('workspace-map-header')),
    );
    final headerBefore = header;
    expect(tester.getRect(feedback).top, closeTo(header.bottom + 56, .01));
    expect(
      tester
          .getRect(feedback)
          .overlaps(
            tester.getRect(find.byKey(const ValueKey('map-viewport-controls'))),
          ),
      isFalse,
      reason: '复制提示不得覆盖脑图创作工具',
    );
    expect(tester.getSize(feedback).width, lessThanOrEqualTo(320));
    await capture(tester, captureKey, 'quiet-clipboard-feedback-1920.png');
    await tester.pump(const Duration(seconds: 2));
    expect(feedback, findsNothing, reason: '轻量复制提示短暂显示后自动消失');
    expect(
      tester.getRect(find.byKey(const Key('workspace-map-header'))),
      headerBefore,
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await until(
      tester,
      () async => find.text('分支已准备剪切，粘贴成功后移动').evaluate().isNotEmpty,
    );
    expect(find.byType(SnackBar), findsNothing);
    // 再次复制取消剪切意图，同时替换提示；粘贴仍创建独立副本。
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await until(
      tester,
      () async => find.textContaining('已复制 1 个主题').evaluate().isNotEmpty,
    );
    expect(find.text('分支已准备剪切，粘贴成功后移动'), findsNothing);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await until(
      tester,
      () async => (await repository.listCards(project.id)).length == 2,
    );
    await idle(tester);
    var snapshot = await real(tester, () => repository.loadMap(map.id));
    final copy = snapshot.nodes.singleWhere((n) => n.id != source.node.id);
    expect(copy.parentNodeId, source.node.id);
    expect(snapshot.cards[copy.cardId]!.body, '复制时尚未自动保存的正文');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await until(
      tester,
      () async => (await repository.listCards(project.id)).length == 1,
    );
    snapshot = await real(tester, () => repository.loadMap(map.id));
    expect(snapshot.nodes.single.id, source.node.id);
    expect(snapshot.cards[source.card.id]!.body, '复制时尚未自动保存的正文');
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('Xmind 折叠快捷键真实写入：递归一次撤销，数字展开保留深层状态', (tester) async {
    final project = await real(
      tester,
      () => repository.createProject('Xmind 折叠'),
    );
    final map = (await real(
      tester,
      () => repository.listMaps(project.id),
    )).single;
    await real(
      tester,
      () => repository.setMapLayout(map.id, model.MapLayoutKind.free),
    );
    Future<model.ExcerptResult> create(
      String title,
      double x, {
      String? parent,
    }) => real(
      tester,
      () => repository.createExcerpt(
        model.ExcerptDraft(
          projectId: project.id,
          mapId: map.id,
          title: title,
          text: '',
          anchors: const [],
          parentNodeId: parent,
          x: x,
          y: 80,
        ),
      ),
    );
    final root = await create('父主题', 80);
    final child = await create('子主题', 400, parent: root.node.id);
    final grand = await create('孙主题', 720, parent: child.node.id);
    await mount(tester);
    await clickMapNode(tester, root.node.id);
    final history = repository.undoEntryCount;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.slash);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await until(tester, () async => repository.undoEntryCount == history + 1);
    var snapshot = await real(tester, () => repository.loadMap(map.id));
    expect(
      snapshot.nodes.singleWhere((n) => n.id == root.node.id).collapsed,
      isTrue,
    );
    expect(
      snapshot.nodes.singleWhere((n) => n.id == child.node.id).collapsed,
      isTrue,
    );
    await idle(tester);
    await tester.tap(find.byKey(Key('map-collapse-${root.node.id}')));
    await until(tester, () async => repository.undoEntryCount == history + 2);
    await idle(tester);
    snapshot = await real(tester, () => repository.loadMap(map.id));
    expect(
      snapshot.nodes.singleWhere((n) => n.id == root.node.id).collapsed,
      isFalse,
    );
    expect(
      snapshot.nodes.singleWhere((n) => n.id == child.node.id).collapsed,
      isTrue,
    );
    await until(
      tester,
      () async => !tester
          .widget<MindMapPane>(find.byType(MindMapPane))
          .snapshot
          .nodes
          .singleWhere((n) => n.id == root.node.id)
          .collapsed,
    );
    // 工作台分屏会将子主题排在视口外；显式总览后再验证可见层级。
    tester.widget<MindMapPane>(find.byType(MindMapPane)).controller!.fitAll();
    await tester.pump();
    expect(find.byKey(Key('map-node-${child.node.id}')), findsOneWidget);
    expect(find.byKey(Key('map-node-${grand.node.id}')), findsNothing);
    await tester.tap(find.byTooltip('撤销 Ctrl+Z'));
    await until(tester, () async => repository.undoEntryCount == history + 1);
    await until(
      tester,
      () async => tester
          .widget<MindMapPane>(find.byType(MindMapPane))
          .snapshot
          .nodes
          .singleWhere((n) => n.id == root.node.id)
          .collapsed,
    );
    await idle(tester);
    await tester.tap(find.byTooltip('撤销 Ctrl+Z'));
    await until(tester, () async => repository.undoEntryCount == history);
    snapshot = await real(tester, () => repository.loadMap(map.id));
    expect(snapshot.nodes.every((n) => !n.collapsed), isTrue);
    await unmount(tester);
  });

  testWidgets('快速两次折叠读取最新状态，每次切换可分别撤销', (tester) async {
    final project = await real(tester, () => repository.createProject('折叠顺序'));
    final map = (await real(
      tester,
      () => repository.listMaps(project.id),
    )).single;
    await real(
      tester,
      () => repository.setMapLayout(map.id, model.MapLayoutKind.free),
    );
    final parent = await real(
      tester,
      () => repository.createExcerpt(
        model.ExcerptDraft(
          projectId: project.id,
          mapId: map.id,
          title: '折叠父主题',
          text: '',
          anchors: const [],
          x: 80,
          y: 80,
        ),
      ),
    );
    final child = await real(
      tester,
      () => repository.createExcerpt(
        model.ExcerptDraft(
          projectId: project.id,
          mapId: map.id,
          parentNodeId: parent.node.id,
          title: '折叠子主题',
          text: '',
          anchors: const [],
          x: 410,
          y: 80,
        ),
      ),
    );
    await mount(tester);
    await clickMapNode(tester, parent.node.id);
    final toggle = find.byKey(Key('map-collapse-${parent.node.id}'));
    final point = tester.getCenter(toggle);
    expect(tester.getRect(find.byType(MindMapPane)).contains(point), isTrue);
    expect(
      tester
          .hitTestOnBinding(point)
          .path
          .any((entry) => identical(entry.target, tester.renderObject(toggle))),
      isTrue,
    );
    final before = repository.undoEntryCount;
    // 两次实际鼠标动作间不重建，确保两次回调都来自同一旧界面快照。
    await tester.tapAt(point, kind: ui.PointerDeviceKind.mouse);
    await tester.tapAt(point, kind: ui.PointerDeviceKind.mouse);
    await until(
      tester,
      () async =>
          repository.undoEntryCount == before + 2 &&
          !(await repository.loadMap(map.id)).nodes
              .singleWhere((n) => n.id == parent.node.id)
              .collapsed,
    );
    await idle(tester);
    tester.widget<MindMapPane>(find.byType(MindMapPane)).controller!.fitAll();
    await tester.pump();
    await until(
      tester,
      () async =>
          !tester
              .widget<MindMapPane>(find.byType(MindMapPane))
              .snapshot
              .nodes
              .singleWhere((n) => n.id == parent.node.id)
              .collapsed &&
          find.byKey(Key('map-node-${child.node.id}')).evaluate().isNotEmpty,
    );
    expect(find.byKey(Key('map-node-${child.node.id}')), findsOneWidget);
    await tester.tap(find.byTooltip('撤销 Ctrl+Z'));
    await until(
      tester,
      () async =>
          (await repository.loadMap(map.id)).nodes
              .singleWhere((n) => n.id == parent.node.id)
              .collapsed,
    );
    await idle(tester);
    await until(
      tester,
      () async =>
          tester
              .widget<MindMapPane>(find.byType(MindMapPane))
              .snapshot
              .nodes
              .singleWhere((n) => n.id == parent.node.id)
              .collapsed &&
          find.byKey(Key('map-node-${child.node.id}')).evaluate().isEmpty,
    );
    expect(find.byKey(Key('map-node-${child.node.id}')), findsNothing);
    await tester.tap(find.byTooltip('撤销 Ctrl+Z'));
    await until(
      tester,
      () async =>
          !(await repository.loadMap(map.id)).nodes
              .singleWhere((n) => n.id == parent.node.id)
              .collapsed,
    );
    await idle(tester);
    tester.widget<MindMapPane>(find.byType(MindMapPane)).controller!.fitAll();
    await tester.pump();
    await until(
      tester,
      () async =>
          !tester
              .widget<MindMapPane>(find.byType(MindMapPane))
              .snapshot
              .nodes
              .singleWhere((n) => n.id == parent.node.id)
              .collapsed &&
          find.byKey(Key('map-node-${child.node.id}')).evaluate().isNotEmpty,
    );
    expect(find.byKey(Key('map-node-${child.node.id}')), findsOneWidget);
    final saved = await real(tester, () => repository.loadMap(map.id));
    expect(
      saved.nodes.singleWhere((n) => n.id == child.node.id).parentNodeId,
      parent.node.id,
    );
    expect(
      saved.nodes.map((n) => n.id),
      unorderedEquals([parent.node.id, child.node.id]),
    );
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('常驻卡片面板：顶部色板取消不写入，改色先保存思考并同步真实PDF与撤销', (tester) async {
    final fixture = await outlineFixture(tester);
    await clickMapNode(tester, fixture.source.node.id);
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await until(
      tester,
      () async => find.byType(CardEditor).evaluate().isNotEmpty,
    );
    await idle(tester);
    final editorState = tester.state(find.byType(CardEditor));
    final viewer = tester.widget<PdfViewer>(find.byType(PdfViewer)).controller!;
    final zoom = viewer.currentZoom;
    final page = viewer.pageNumber;
    final history = repository.undoEntryCount;
    final button = find.byKey(const Key('card-editor-color'));
    final green = find.byKey(const ValueKey('card-color-#91C69A'));
    await tester.tap(button);
    await until(tester, () async => green.hitTestable().evaluate().isNotEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await until(tester, () async => green.evaluate().isEmpty);
    expect(repository.undoEntryCount, history);
    await tester.enterText(find.byKey(const Key('card-body')), '顶部改色前的正文草稿');
    await tester.enterText(find.byKey(const Key('card-note')), '顶部改色前的个人思考');
    final note = tester.widget<TextField>(find.byKey(const Key('card-note')));
    await tester.tap(button);
    await until(tester, () async => green.hitTestable().evaluate().isNotEmpty);
    await tester.tap(green);
    await until(
      tester,
      () async =>
          (await repository.getCard(fixture.source.card.id)).color ==
              '#91C69A' &&
          tester
                  .widget<ReaderPane>(find.byType(ReaderPane))
                  .annotations
                  .singleWhere(
                    (annotation) => annotation.cardId == fixture.source.card.id,
                  )
                  .color ==
              '#91C69A',
    );
    await idle(tester);
    final saved = await real(
      tester,
      () => repository.getCard(fixture.source.card.id),
    );
    expect(saved.body, '顶部改色前的正文草稿');
    expect(saved.thoughts.single.text, '顶部改色前的个人思考');
    expect(
      repository.undoEntryCount,
      history + 2,
      reason: '先提交文字草稿，再将卡片和PDF颜色作为同一笔',
    );
    expect(tester.state(find.byType(CardEditor)), same(editorState));
    expect(
      tester.widget<TextField>(find.byKey(const Key('card-note'))).controller,
      same(note.controller),
    );
    await settleUi(tester);
    expect(note.focusNode!.hasFocus, isTrue);
    expect(viewer.currentZoom, zoom);
    expect(viewer.pageNumber, page);
    await capture(
      tester,
      captureKey,
      'sticky-card-panel/card-pdf-color-1920.png',
    );
    await tester.tap(find.byTooltip('撤销 Ctrl+Z'));
    await until(
      tester,
      () async =>
          (await repository.getCard(fixture.source.card.id)).color ==
              fixture.source.card.color &&
          tester
                  .widget<ReaderPane>(find.byType(ReaderPane))
                  .annotations
                  .singleWhere(
                    (annotation) => annotation.cardId == fixture.source.card.id,
                  )
                  .color ==
              fixture.source.card.color,
    );
    expect(
      (await real(
        tester,
        () => repository.getCard(fixture.source.card.id),
      )).body,
      saved.body,
    );
    await tester.tap(find.byTooltip('重做 Ctrl+Y'));
    await until(
      tester,
      () async =>
          (await repository.getCard(fixture.source.card.id)).color == '#91C69A',
    );
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    tester.platformDispatcher.textScaleFactorTestValue = 1.25;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pump();
    expect(tester.state(find.byType(CardEditor)), same(editorState));
    await tester.tap(button);
    await until(tester, () async => green.hitTestable().evaluate().isNotEmpty);
    expect(tester.takeException(), isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await until(tester, () async => green.evaluate().isEmpty);
    await tester.tap(find.byTooltip('收起编辑'));
    await until(tester, () async => find.byType(CardEditor).evaluate().isEmpty);
    await unmount(tester);
  });

  testWidgets('卡片颜色先提交草稿，PDF标注同步与独立副本保持原值并可撤销', (tester) async {
    final project = await real(tester, () => repository.createProject('颜色独立'));
    final map = (await real(
      tester,
      () => repository.listMaps(project.id),
    )).single;
    await real(
      tester,
      () => repository.setMapLayout(map.id, model.MapLayoutKind.free),
    );
    final document = await real(
      tester,
      () => repository.importPdf(
        projectId: project.id,
        filePath: File('tools/fixtures/pdf/native.pdf').absolute.path,
        pageCount: 2,
      ),
    );
    await mount(tester);
    await until(
      tester,
      () async =>
          readerReady(tester) &&
          (await repository.loadTextLayers(document.activeRevisionId)).length ==
              2,
    );
    final layer = (await real(
      tester,
      () => repository.loadTextLayers(document.activeRevisionId),
    )).singleWhere((value) => value.pageIndex == 0);
    final start = layer.text.indexOf('OpenNote');
    expect(start, greaterThanOrEqualTo(0));
    final quads = layer.fragments
        .where(
          (fragment) =>
              fragment.start < start + 8 &&
              fragment.start + fragment.length > start,
        )
        .map((fragment) => fragment.quad)
        .toList();
    final excerpt = await real(
      tester,
      () => repository.createExcerpt(
        model.ExcerptDraft(
          projectId: project.id,
          mapId: map.id,
          title: '原文颜色卡片',
          text: 'OpenNote',
          anchors: [
            model.AnchorDraft(
              revisionId: document.activeRevisionId,
              pageIndex: 0,
              quads: quads,
              textLayerId: layer.id,
              textStart: start,
              textEnd: start + 8,
              context: 'OpenNote',
            ),
          ],
          x: 80,
          y: 80,
          createHighlight: true,
        ),
      ),
    );
    final copy = await real(
      tester,
      () => repository.copyBranch(
        excerpt.node.id,
        map.id,
        offsetX: 500,
        offsetY: 0,
      ),
    );
    final copyCardId = copy.cardIds[excerpt.card.id]!;
    final originalColor = excerpt.card.color;
    final originalAnnotation = (await real(
      tester,
      () => repository.listAnnotations(document.activeRevisionId),
    )).single;
    await clickMapNode(tester, excerpt.node.id);
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await until(
      tester,
      () async => find.byKey(const Key('card-body')).evaluate().isNotEmpty,
    );
    await idle(tester);
    final editorState = tester.state(find.byType(CardEditor));
    await tester.enterText(find.byKey(const Key('card-body')), '改色前尚未自动保存的正文');
    await tester.pump();
    expect(find.text('待保存…'), findsOneWidget);
    expect(
      (await real(tester, () => repository.getCard(excerpt.card.id))).body,
      'OpenNote',
    );
    await mapNodeMenuAction(tester, group: 'styleMenu', action: 'color');
    await until(
      tester,
      () async =>
          find.byType(SimpleDialog).evaluate().isNotEmpty &&
          (await repository.getCard(excerpt.card.id)).body == '改色前尚未自动保存的正文',
    );
    expect(
      (await real(tester, () => repository.getCard(excerpt.card.id))).color,
      originalColor,
    );
    await settleUi(tester);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('正在提交…'), findsNothing);
    expect(find.text('资料已保存'), findsOneWidget);
    await capture(tester, captureKey, 'quiet-card-color-dialog-1920.png');
    await tester.tap(
      find.byKey(const Key('card-color-#80B9EB')),
      kind: ui.PointerDeviceKind.mouse,
    );
    await until(
      tester,
      () async =>
          (await repository.getCard(excerpt.card.id)).color == '#80B9EB' &&
          find.byType(SimpleDialog).evaluate().isEmpty,
    );
    await idle(tester);
    expect(tester.state(find.byType(CardEditor)), same(editorState));
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('card-body')))
          .controller!
          .text,
      '改色前尚未自动保存的正文',
    );
    var copiedCard = await real(tester, () => repository.getCard(copyCardId));
    expect(copiedCard.body, 'OpenNote');
    expect(copiedCard.color, originalColor);
    var annotation = (await real(
      tester,
      () => repository.listAnnotations(document.activeRevisionId),
    )).single;
    expect(annotation.id, originalAnnotation.id);
    expect(annotation.color, '#80B9EB');
    expect(annotation.cardId, excerpt.card.id);
    await tester.tap(find.byTooltip('撤销 Ctrl+Z'));
    await until(
      tester,
      () async =>
          (await repository.getCard(excerpt.card.id)).color == originalColor,
    );
    await idle(tester);
    expect(
      (await real(tester, () => repository.getCard(excerpt.card.id))).body,
      '改色前尚未自动保存的正文',
    );
    await tester.tap(find.byTooltip('重做 Ctrl+Y'));
    await until(
      tester,
      () async =>
          (await repository.getCard(excerpt.card.id)).color == '#80B9EB',
    );
    await idle(tester);
    await tester.tap(find.byTooltip('收起编辑'));
    await until(tester, () async => find.byType(CardEditor).evaluate().isEmpty);
    await idle(tester);
    tester.widget<MindMapPane>(find.byType(MindMapPane)).controller!.fitAll();
    tester
        .widget<ReaderPane>(find.byType(ReaderPane))
        .controller!
        .clearHighlights();
    var viewer = tester.widget<PdfViewer>(find.byType(PdfViewer)).controller!;
    var fit = viewer.calcMatrixForFit(pageNumber: 1);
    expect(fit, isNotNull);
    await real(tester, () => viewer.goTo(fit, duration: Duration.zero));
    await settleUi(tester);
    expect(
      tester.getCenter(find.byType(PdfViewer)).dx,
      lessThan(tester.getCenter(find.byType(MindMapPane)).dx),
    );
    expect(tester.takeException(), isNull);
    await capture(
      tester,
      captureKey,
      'workbench-card-color-reading-1280x720.png',
    );
    await tester.binding.setSurfaceSize(null);
    tester.view.devicePixelRatio = 1.5;
    tester.view.physicalSize = const Size(1920, 1080);
    await tester.pump();
    expect(
      MediaQuery.sizeOf(tester.element(find.byType(Workbench))),
      const Size(1280, 720),
    );
    viewer = tester.widget<PdfViewer>(find.byType(PdfViewer)).controller!;
    fit = viewer.calcMatrixForFit(pageNumber: 1);
    expect(fit, isNotNull);
    await real(tester, () => viewer.goTo(fit, duration: Duration.zero));
    await settleUi(tester);
    expect(tester.takeException(), isNull);
    await capture(
      tester,
      captureKey,
      'workbench-card-color-reading-1920x1080-at150.png',
      pixelRatio: 1.5,
    );
    tester.view.resetDevicePixelRatio();
    tester.view.resetPhysicalSize();
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    await tester.pump();
    await unmount(tester);
    await real(tester, repository.close);
    repositoryClosed = true;
    final reopened = await real(
      tester,
      () => OpenNoteRepository.open(rootPath: '${temp.path}/library'),
    );
    try {
      final saved = await real(tester, () => reopened.getCard(excerpt.card.id));
      expect(saved.color, '#80B9EB');
      expect(saved.body, '改色前尚未自动保存的正文');
      copiedCard = await real(tester, () => reopened.getCard(copyCardId));
      expect(copiedCard.color, originalColor);
      expect(copiedCard.body, 'OpenNote');
      annotation = (await real(
        tester,
        () => reopened.listAnnotations(document.activeRevisionId),
      )).single;
      expect(annotation.id, originalAnnotation.id);
      expect(annotation.color, '#80B9EB');
    } finally {
      await real(tester, reopened.close);
    }
  });

  testWidgets('阅读器关闭边界：退出等待真实加载文档释放并提交草稿', (tester) async {
    final fixture = await outlineFixture(tester);
    await clickMapNode(tester, fixture.source.node.id);
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await until(
      tester,
      () async => find.byType(CardEditor).evaluate().isNotEmpty,
    );
    await idle(tester);
    final loaded = tester
        .widget<PdfViewer>(find.byType(PdfViewer))
        .controller!
        .document;
    final readerFinder = find.byType(ReaderPane);
    final readerState = tester.state(readerFinder);
    final pageFieldFinder = find.descendant(
      of: readerFinder,
      matching: find.byType(TextField),
    );
    final pageFieldState = tester.state(pageFieldFinder);
    final pageEditableFinder = find.descendant(
      of: pageFieldFinder,
      matching: find.byType(EditableText),
    );
    final pageEditableState = tester.state(pageEditableFinder);
    final pdfPath = tester.widget<ReaderPane>(readerFinder).filePath;
    await tester.enterText(find.byKey(const Key('card-body')), '退出前待提交正文');
    await tester.enterText(find.byKey(const Key('card-note')), '退出前的第一条思考');
    await tester.tap(find.byTooltip('添加个人思考'));
    await tester.pump();
    await tester.enterText(
      find
          .byWidgetPredicate(
            (widget) =>
                widget is TextField &&
                widget.focusNode?.debugLabel == 'OpenNote 个人思考',
          )
          .last,
      '退出前的第二条思考',
    );
    expect(
      (await real(
        tester,
        () => repository.getCard(fixture.source.card.id),
      )).body,
      'OpenNote',
    );
    final response = await real(tester, tester.binding.handleRequestAppExit);
    expect(response, ui.AppExitResponse.exit);
    repositoryClosed = true;
    expect(readerFinder, findsOneWidget);
    expect(tester.state(readerFinder), same(readerState));
    expect(tester.state(pageFieldFinder), same(pageFieldState));
    expect(tester.state(pageEditableFinder), same(pageEditableState));
    expect(tester.widget<ReaderPane>(readerFinder).closing, isTrue);
    expect(find.byType(PdfViewer), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const Key('reader-closing-document')),
        matching: find.text('正在关闭文档…'),
      ),
      findsOneWidget,
    );
    expect((loaded as dynamic).isDisposed, isTrue);
    // 返回exit前必须真正关闭Windows文件句柄，立即重命名后恢复原路径。
    await real(tester, () async {
      final moved = await File(pdfPath).rename('$pdfPath.exit-close-check');
      await moved.rename(pdfPath);
    });
    expect(tester.takeException(), isNull);
    await unmount(tester);
    final reopened = await real(
      tester,
      () => OpenNoteRepository.open(rootPath: '${temp.path}/library'),
    );
    try {
      expect(
        (await real(
          tester,
          () => reopened.getCard(fixture.source.card.id),
        )).body,
        '退出前待提交正文',
      );
      expect(
        (await real(
          tester,
          () => reopened.getCard(fixture.source.card.id),
        )).thoughts.map((thought) => thought.text),
        ['退出前的第一条思考', '退出前的第二条思考'],
      );
      expect(
        await real(tester, () => reopened.getAnchors(fixture.source.card.id)),
        hasLength(1),
      );
      expect(File(pdfPath).existsSync(), isTrue);
    } finally {
      await real(tester, reopened.close);
    }
  });

  testWidgets('关闭前排空已接受的PDF导入，重新打开保留文档', (tester) async {
    final project = await real(tester, () => repository.createProject('退出保存'));
    await mount(tester);
    await idle(tester);
    selector.importPaths = [
      File('tools/verification/fixtures/long-book-1000.pdf').absolute.path,
    ];
    await tester.runAsync(() => tester.tap(find.byTooltip('添加文档')));
    await tester.pump();
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const Key('workspace-library-import-pdf')),
          )
          .onPressed,
      isNull,
      reason: '在 PDF 解析和导入尚未完成、入口禁用时请求退出',
    );
    final response = await real(tester, tester.binding.handleRequestAppExit);
    expect(response, ui.AppExitResponse.exit);
    repositoryClosed = true;
    await unmount(tester);
    final reopened = await real(
      tester,
      () => OpenNoteRepository.open(rootPath: '${temp.path}/library'),
    );
    try {
      final documents = await real(
        tester,
        () => reopened.listDocuments(project.id),
      );
      expect(documents, hasLength(1), reason: '关闭前接受的导入必须提交，而不是关闭资料库后丢弃');
      final revision = await real(
        tester,
        () => reopened.getRevision(documents.single.activeRevisionId),
      );
      expect(revision.pageCount, 1000);
      final resource = await real(
        tester,
        () => reopened.resourcePath(revision.resourceId),
      );
      expect(File(resource).existsSync(), isTrue);
      expect(tester.takeException(), isNull);
    } finally {
      await real(tester, reopened.close);
    }
  });

  Future<
    ({
      model.StudyProject project,
      model.MindMap map,
      model.ExcerptResult parent,
      model.ExcerptResult other,
    })
  >
  heldDragFixture(
    WidgetTester tester, {
    required String title,
    required bool attached,
  }) async {
    final project = await real(tester, () => repository.createProject(title));
    final map = (await real(
      tester,
      () => repository.listMaps(project.id),
    )).single;
    await real(
      tester,
      () => repository.setMapLayout(map.id, model.MapLayoutKind.free),
    );
    final parent = await real(
      tester,
      () => repository.createExcerpt(
        model.ExcerptDraft(
          projectId: project.id,
          mapId: map.id,
          title: '拖动父主题',
          text: '',
          anchors: const [],
          x: 40,
          y: 70,
        ),
      ),
    );
    final other = await real(
      tester,
      () => repository.createExcerpt(
        model.ExcerptDraft(
          projectId: project.id,
          mapId: map.id,
          parentNodeId: attached ? parent.node.id : null,
          title: attached ? '最后创建的子主题' : '最后创建的目标主题',
          text: '',
          anchors: const [],
          x: 220,
          y: 250,
        ),
      ),
    );
    return (project: project, map: map, parent: parent, other: other);
  }

  Future<TestGesture> beginHeldBranchDrag(
    WidgetTester tester,
    String nodeId,
  ) async {
    await clickMapNode(tester, nodeId);
    final paneFinder = find.byType(MindMapPane);
    tester
        .widget<MindMapPane>(paneFinder)
        .controller!
        .setView(scale: .75, worldTopLeft: Offset.zero);
    await advance(tester);
    await idle(tester);
    final node = find.byKey(Key('map-node-$nodeId'));
    final start = tester.getCenter(node);
    expect(tester.getRect(paneFinder).contains(start), isTrue);
    expect(
      tester
          .hitTestOnBinding(start)
          .path
          .any((entry) => identical(entry.target, tester.renderObject(node))),
      isTrue,
    );
    final held = await tester.startGesture(
      start,
      kind: ui.PointerDeviceKind.mouse,
    );
    await held.moveBy(const Offset(30, 0));
    await tester.pump();
    await held.moveBy(const Offset(55, 35));
    await tester.pump();
    // 等待选中同步到工作台，验证 CtrlZ 与拖动提交仍保持正确顺序。
    await idle(tester);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'OpenNote 脑图');
    expect(tester.widget<MindMapPane>(paneFinder).selectedNodeId, nodeId);
    return held;
  }

  Future<void> createAfterInvalidatedDrag(
    WidgetTester tester,
    model.StudyProject project,
    model.MindMap map,
    String parentId,
  ) async {
    await clickMapNode(tester, parentId);
    final existingCards = await real(
      tester,
      () => repository.listCards(project.id),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.insert);
    await until(
      tester,
      () async =>
          (await repository.listCards(project.id)).length ==
              existingCards.length + 1 &&
          find.byKey(const Key('map-title-editor')).evaluate().isNotEmpty,
    );
    await tester.enterText(
      find.byKey(const Key('map-title-editor')),
      '拖动失效后的新主题',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await until(
      tester,
      () async => find.byKey(const Key('map-title-editor')).evaluate().isEmpty,
    );
    await idle(tester);
    final latest = await real(tester, () => repository.loadMap(map.id));
    final added = latest.nodes.singleWhere(
      (node) => !existingCards.any((card) => card.id == node.cardId),
    );
    expect(added.parentNodeId, parentId);
    expect(latest.cards[added.cardId]!.title, '拖动失效后的新主题');
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await until(
      tester,
      () async => find.byKey(const Key('card-body')).evaluate().isNotEmpty,
    );
    expect(
      tester.widget<CardEditor>(find.byType(CardEditor)).card.id,
      added.cardId,
    );
    expect(tester.takeException(), isNull);
  }

  testWidgets('框选工作台：抬起后立即Delete使用最新选集，单次撤销恢复两条分支', (tester) async {
    final project = await real(tester, () => repository.createProject('框选工作台'));
    final map = (await real(
      tester,
      () => repository.listMaps(project.id),
    )).single;
    await real(
      tester,
      () => repository.setMapLayout(map.id, model.MapLayoutKind.free),
    );
    final topics = <model.ExcerptResult>[];
    for (final placement in [
      ('阅读材料', 80.0, 80.0),
      ('整理问题', 80.0, 260.0),
      ('保留主题', 450.0, 80.0),
    ]) {
      topics.add(
        await real(
          tester,
          () => repository.createExcerpt(
            model.ExcerptDraft(
              projectId: project.id,
              mapId: map.id,
              title: placement.$1,
              text: '',
              x: placement.$2,
              y: placement.$3,
            ),
          ),
        ),
      );
    }
    await mount(tester);
    final pane = find.byType(MindMapPane);
    await until(tester, () async => pane.evaluate().isNotEmpty);
    await idle(tester);
    final graph = tester.widget<MindMapPane>(pane).controller!;
    graph.setView(scale: 1, worldTopLeft: const Offset(-50, -50));
    await tester.pump();
    await mapCanvasToolAction(tester, 'tool:marquee');
    await tester.pump();
    final origin = tester.getTopLeft(pane);
    final drag = await tester.startGesture(
      origin + const Offset(80, 80),
      kind: ui.PointerDeviceKind.mouse,
    );
    await drag.moveTo(origin + const Offset(180, 180));
    await tester.pump();
    await drag.moveTo(origin + const Offset(420, 460));
    await tester.pump();
    final history = repository.undoEntryCount;
    await capture(tester, captureKey, 'xmind-marquee-1920x1080.png');
    await drag.up();
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await until(
      tester,
      () async => (await repository.loadMap(map.id)).nodes.length == 1,
    );
    await idle(tester);
    expect(
      (await real(tester, () => repository.loadMap(map.id))).nodes.single.id,
      topics.last.node.id,
    );
    expect(repository.undoEntryCount, history + 1);
    expect(
      (await real(tester, () => repository.listCards(project.id))).length,
      1,
    );
    expect(
      await real(tester, () => repository.listTrash(projectId: project.id)),
      hasLength(2),
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await until(
      tester,
      () async => (await repository.loadMap(map.id)).nodes.length == 3,
    );
    await idle(tester);
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('根节点平移工作台：整图平移保留选择，SQLite坐标和撤销历史均不变', (tester) async {
    final fixture = await heldDragFixture(
      tester,
      title: '根节点平移工作台',
      attached: true,
    );
    await real(
      tester,
      () => repository.createExcerpt(
        model.ExcerptDraft(
          projectId: fixture.project.id,
          mapId: fixture.map.id,
          title: '另一个独立根节点',
          text: '',
          anchors: const [],
          x: 400,
          y: 200,
        ),
      ),
    );
    await real(
      tester,
      () => repository.setMapLayout(fixture.map.id, model.MapLayoutKind.right),
    );
    final savedBefore = await real(
      tester,
      () => repository.loadMap(fixture.map.id),
    );
    final history = repository.undoEntryCount;
    await mount(tester);
    final pane = find.byType(MindMapPane);
    await until(
      tester,
      () async =>
          pane.evaluate().isNotEmpty &&
          tester.widget<MindMapPane>(pane).snapshot.nodes.length ==
              savedBefore.nodes.length,
    );
    await idle(tester);
    final widgetBefore = tester.widget<MindMapPane>(pane);
    widgetBefore.controller!.setView(
      scale: .5,
      worldTopLeft: const Offset(-100, -80),
    );
    await advance(tester);
    final bounds = tester.getRect(pane);
    final before = {
      for (final node in savedBefore.nodes)
        node.id: tester.getRect(find.byKey(Key('map-node-${node.id}'))),
    };
    final root = find.byKey(Key('map-node-${fixture.parent.node.id}'));
    final drag = await tester.startGesture(
      tester.getRect(root).topLeft + const Offset(20, 20),
      kind: ui.PointerDeviceKind.mouse,
    );
    await tester.pump();
    await until(
      tester,
      () async =>
          tester.widget<MindMapPane>(pane).selectedNodeId ==
          fixture.parent.node.id,
    );
    await drag.moveBy(const Offset(30, 0));
    await advance(tester);
    await drag.moveBy(const Offset(45, 25));
    await advance(tester);
    final delta =
        tester.getRect(root).topLeft - before[fixture.parent.node.id]!.topLeft;
    expect(delta.distance, greaterThan(20));
    for (final entry in before.entries) {
      expect(
        tester.getRect(find.byKey(Key('map-node-${entry.key}'))),
        rectMoreOrLessEquals(entry.value.shift(delta), epsilon: .000001),
      );
    }
    expect(tester.getRect(pane), bounds);
    expect(
      identical(
        tester.widget<MindMapPane>(pane).snapshot,
        widgetBefore.snapshot,
      ),
      isTrue,
    );
    expect(find.byKey(const Key('map-drop-target')), findsNothing);
    await drag.up();
    await idle(tester);
    final savedAfter = await real(
      tester,
      () => repository.loadMap(fixture.map.id),
    );
    for (final node in savedBefore.nodes) {
      final latest = savedAfter.nodes.firstWhere(
        (value) => value.id == node.id,
      );
      expect(
        (latest.x, latest.y, latest.parentNodeId, latest.sortIndex),
        (node.x, node.y, node.parentNodeId, node.sortIndex),
      );
    }
    expect(repository.undoEntryCount, history, reason: '视图平移没有业务保存或撤销记录');
    expect(
      tester.widget<MindMapPane>(pane).selectedNodeId,
      fixture.parent.node.id,
    );
    expect(tester.widget<MindMapPane>(pane).controller!.scale, .5);
    expect(
      tester.getRect(root),
      rectMoreOrLessEquals(
        before[fixture.parent.node.id]!.shift(delta),
        epsilon: .000001,
      ),
    );
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('拖动布局稳定：按下和拖动不闪烁全局按钮，提交不挤动内容区', (tester) async {
    final fixture = await heldDragFixture(
      tester,
      title: '拖动窗口稳定',
      attached: false,
    );
    await mount(tester);
    await until(
      tester,
      () async => find
          .byKey(Key('map-node-${fixture.parent.node.id}'))
          .evaluate()
          .isNotEmpty,
    );
    await idle(tester);
    final pane = find.byType(MindMapPane);
    tester
        .widget<MindMapPane>(pane)
        .controller!
        .setView(scale: .75, worldTopLeft: Offset.zero);
    await advance(tester);
    final bounds = tester.getRect(pane);
    final snapshot = tester.widget<MindMapPane>(pane).snapshot;
    final searchButton = find.byWidgetPredicate(
      (widget) => widget is IconButton && widget.tooltip == '搜索 Ctrl+F',
    );
    void expectStable() {
      expect(tester.getRect(pane), bounds, reason: '忙碌提示不能改变内容区位置或高度');
      final onPressed = tester.widget<IconButton>(searchButton).onPressed;
      expect(onPressed, isNotNull, reason: '选中、拖动预览及局部保存不应禁用全局工具栏');
    }

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(Key('map-node-${fixture.parent.node.id}'))),
      kind: ui.PointerDeviceKind.mouse,
    );
    await tester.pump();
    expectStable();
    await until(tester, () async {
      expectStable();
      return tester.widget<MindMapPane>(pane).selectedNodeId ==
          fixture.parent.node.id;
    });
    for (var i = 0; i < 6; i++) {
      await gesture.moveBy(const Offset(18, 4));
      await advance(tester);
      expectStable();
    }
    expect(
      identical(tester.widget<MindMapPane>(pane).snapshot, snapshot),
      isTrue,
      reason: '选中和拖动预览不应重新加载整张脑图',
    );
    await gesture.up();
    await tester.pump();
    expectStable();
    await until(tester, () async {
      expectStable();
      final latest = await repository.loadMap(fixture.map.id);
      return latest.nodes
              .firstWhere((node) => node.id == fixture.parent.node.id)
              .x !=
          fixture.parent.node.x;
    });
    await idle(tester);
    expectStable();
    await unmount(tester);
  });

  for (final rejected in [false, true]) {
    testWidgets('拖动局部保存与离开：${rejected ? '失败留在工作台' : '等待写入后离开'}', (
      tester,
    ) async {
      final fixture = await heldDragFixture(
        tester,
        title: '拖动后立即返回',
        attached: false,
      );
      final database = sqlite.sqlite3.open(
        '${repository.libraryPath}/library.sqlite',
      );
      if (rejected) {
        // 在挂载前布置拒绝条件，避免与首页导航元数据的后台写入争锁。
        database.execute(
          "CREATE TRIGGER reject_leave_move BEFORE UPDATE OF x, y ON nodes BEGIN SELECT RAISE(FAIL, '验证返回前移动失败'); END;",
        );
      }
      await mount(tester);
      await until(
        tester,
        () async => find
            .byKey(Key('map-node-${fixture.parent.node.id}'))
            .evaluate()
            .isNotEmpty,
      );
      await idle(tester);
      final pane = tester.widget<MindMapPane>(find.byType(MindMapPane));
      pane.controller!.setView(scale: .75, worldTopLeft: Offset.zero);
      await advance(tester);
      final history = repository.undoEntryCount;
      try {
        final gesture = await tester.startGesture(
          tester.getCenter(
            find.byKey(Key('map-node-${fixture.parent.node.id}')),
          ),
          kind: ui.PointerDeviceKind.mouse,
        );
        await gesture.moveBy(const Offset(30, 0));
        await advance(tester);
        await gesture.moveBy(const Offset(80, 20));
        await advance(tester);
        await gesture.up();

        // 松手的本地命令已接受但尚未让出异步帧，此时立即离开仍必须等待它。
        final controller = tester
            .widget<Workbench>(find.byType(Workbench))
            .controller;
        var completed = false;
        Object? failure;
        controller.prepareToLeave().then<void>(
          (_) {
            completed = true;
          },
          onError: (Object error) {
            failure = error;
            completed = true;
          },
        );
        await until(tester, () async => completed);
        final saved = (await real(
          tester,
          () => repository.loadMap(fixture.map.id),
        )).nodes.firstWhere((node) => node.id == fixture.parent.node.id);
        if (rejected) {
          expect(failure, isNotNull);
          expect(saved.x, fixture.parent.node.x);
          expect(saved.y, fixture.parent.node.y);
          expect(repository.undoEntryCount, history);
          expect(find.byType(Workbench), findsOneWidget);
          // 失败取消离开，移除拒绝条件后允许重试同一个保存入口。
          database.execute('DROP TRIGGER reject_leave_move');
          var retried = false;
          Object? retryFailure;
          tester
              .widget<MindMapPane>(find.byType(MindMapPane))
              .onMove(saved.id, saved.x + 10, saved.y)
              .then<void>(
                (_) {
                  retried = true;
                },
                onError: (Object error) {
                  retryFailure = error;
                  retried = true;
                },
              );
          await until(tester, () async => retried);
          expect(retryFailure, isNull);
          expect(
            (await real(
              tester,
              () => repository.loadMap(fixture.map.id),
            )).nodes.firstWhere((node) => node.id == saved.id).x,
            saved.x + 10,
          );
        } else {
          expect(failure, isNull);
          expect(saved.x, greaterThan(fixture.parent.node.x));
          expect(saved.y, greaterThan(fixture.parent.node.y));
          expect(repository.undoEntryCount, history + 1);
        }
        expect(tester.takeException(), isNull);
      } finally {
        database.close();
        await unmount(tester);
      }
    });
  }

  testWidgets('拖动失效回归：按住父分支撤销子创建后松手无异常', (tester) async {
    final fixture = await heldDragFixture(
      tester,
      title: '拖动撤销子创建',
      attached: true,
    );
    await mount(tester);
    final held = await beginHeldBranchDrag(tester, fixture.parent.node.id);
    var released = false;
    try {
      final history = repository.undoEntryCount;
      await ctrl(tester, LogicalKeyboardKey.keyZ);
      await until(
        tester,
        () async =>
            !(await repository.loadMap(fixture.map.id)).nodes
                .any((node) => node.id == fixture.other.node.id) &&
            !tester
                .widget<MindMapPane>(find.byType(MindMapPane))
                .snapshot
                .nodes
                .any((node) => node.id == fixture.other.node.id),
      );
      expect(repository.undoEntryCount, history - 1);
      await held.up();
      released = true;
      await idle(tester);
      await advance(tester);
      final actualException = tester.takeException();
      debugPrint('held-child-undo exception: $actualException');
      expect(actualException, isNull, reason: '父主题手势仍存活，旧子ID必须在快照失效时取消而非松手取空');
      final saved = (await real(
        tester,
        () => repository.loadMap(fixture.map.id),
      )).nodes.single;
      expect(saved.id, fixture.parent.node.id);
      expect(saved.x, fixture.parent.node.x);
      expect(saved.y, fixture.parent.node.y);
      expect(repository.undoEntryCount, history - 1);
      expect(find.byKey(const Key('map-drop-target')), findsNothing);
      await createAfterInvalidatedDrag(
        tester,
        fixture.project,
        fixture.map,
        fixture.parent.node.id,
      );
    } finally {
      if (!released) await held.cancel();
      await unmount(tester);
    }
  });

  testWidgets('拖动失效回归：按住重挂提示撤销目标创建后不读空目标', (tester) async {
    final fixture = await heldDragFixture(
      tester,
      title: '拖动撤销重挂目标',
      attached: false,
    );
    await mount(tester);
    final held = await beginHeldBranchDrag(tester, fixture.parent.node.id);
    var released = false;
    try {
      final target = find.byKey(Key('map-node-${fixture.other.node.id}'));
      final point = tester.getCenter(target);
      expect(tester.getRect(find.byType(MindMapPane)).contains(point), isTrue);
      await held.moveTo(point);
      await tester.pump();
      expect(find.byKey(const Key('map-drop-target')), findsOneWidget);
      expect(find.text('加入子主题'), findsOneWidget);
      await idle(tester);
      final history = repository.undoEntryCount;
      await ctrl(tester, LogicalKeyboardKey.keyZ);
      await until(
        tester,
        () async =>
            !(await repository.loadMap(fixture.map.id)).nodes
                .any((node) => node.id == fixture.other.node.id) &&
            !tester
                .widget<MindMapPane>(find.byType(MindMapPane))
                .snapshot
                .nodes
                .any((node) => node.id == fixture.other.node.id),
      );
      // 在松手前收集真实build异常，不能让mouseup重建后的画面掩盖空目标读取。
      final frameException = tester.takeException();
      debugPrint('held-target-undo frame exception: $frameException');
      await held.up();
      released = true;
      await idle(tester);
      final endException = tester.takeException();
      debugPrint('held-target-undo end exception: $endException');
      expect(frameException, isNull, reason: '目标删除后的第一帧必须清除重挂提示');
      expect(endException, isNull, reason: '释放旧手势不能提交已删除的父目标');
      final saved = (await real(
        tester,
        () => repository.loadMap(fixture.map.id),
      )).nodes.single;
      expect(saved.parentNodeId, isNull);
      expect(saved.x, fixture.parent.node.x);
      expect(saved.y, fixture.parent.node.y);
      expect(repository.undoEntryCount, history - 1);
      expect(find.byKey(const Key('map-drop-target')), findsNothing);
      await createAfterInvalidatedDrag(
        tester,
        fixture.project,
        fixture.map,
        fixture.parent.node.id,
      );
    } finally {
      if (!released) await held.cancel();
      await unmount(tester);
    }
  });

  testWidgets('拖动失效回归：按住分支撤销子重挂后预览与SQLite坐标一致', (tester) async {
    final fixture = await heldDragFixture(
      tester,
      title: '拖动撤销子重挂',
      attached: false,
    );
    // 最后一个业务命令是把既有子节点挂到父级，撤销只改变层级而不删除节点。
    await real(
      tester,
      () => repository.reparentNode(
        fixture.other.node.id,
        fixture.parent.node.id,
      ),
    );
    await mount(tester);
    await clickMapNode(tester, fixture.parent.node.id);
    final paneFinder = find.byType(MindMapPane);
    tester
        .widget<MindMapPane>(paneFinder)
        .controller!
        .setView(scale: .75, worldTopLeft: Offset.zero);
    await advance(tester);
    final childFinder = find.byKey(Key('map-node-${fixture.other.node.id}'));
    final beforeChild =
        tester.getCenter(childFinder) - tester.getTopLeft(paneFinder);
    final held = await beginHeldBranchDrag(tester, fixture.parent.node.id);
    var released = false;
    try {
      final history = repository.undoEntryCount;
      await ctrl(tester, LogicalKeyboardKey.keyZ);
      await until(tester, () async {
        final latest = await repository.loadMap(fixture.map.id);
        final child = latest.nodes.singleWhere(
          (node) => node.id == fixture.other.node.id,
        );
        final shown = tester
            .widget<MindMapPane>(paneFinder)
            .snapshot
            .nodes
            .singleWhere((node) => node.id == fixture.other.node.id);
        return child.parentNodeId == null && shown.parentNodeId == null;
      });
      expect(repository.undoEntryCount, history - 1);
      await held.up();
      released = true;
      await idle(tester);
      await advance(tester);
      final actualException = tester.takeException();
      debugPrint('held-reparent-undo exception: $actualException');
      expect(actualException, isNull);
      final latest = await real(
        tester,
        () => repository.loadMap(fixture.map.id),
      );
      final savedChild = latest.nodes.singleWhere(
        (node) => node.id == fixture.other.node.id,
      );
      final savedParent = latest.nodes.singleWhere(
        (node) => node.id == fixture.parent.node.id,
      );
      final afterChild =
          tester.getCenter(childFinder) - tester.getTopLeft(paneFinder);
      debugPrint(
        'held-reparent-undo child visualDelta=${afterChild - beforeChild}; '
        'SQLite=(${savedChild.x},${savedChild.y}); history=$history→${repository.undoEntryCount}',
      );
      expect(savedChild.parentNodeId, isNull);
      expect(savedChild.x, fixture.other.node.x);
      expect(savedChild.y, fixture.other.node.y);
      expect(
        (afterChild - beforeChild).distance,
        lessThan(1),
        reason: '脱离拖动分支的子主题不能被旧pendingPositions持续移动',
      );
      expect(savedParent.x, fixture.parent.node.x);
      expect(savedParent.y, fixture.parent.node.y);
      expect(repository.undoEntryCount, history - 1);
      await createAfterInvalidatedDrag(
        tester,
        fixture.project,
        fixture.map,
        fixture.parent.node.id,
      );
    } finally {
      if (!released) await held.cancel();
      await unmount(tester);
    }
  });

  testWidgets('真实SQLite拒绝移动时，画布回滚并继续接受后续命令', (tester) async {
    final project = await real(tester, () => repository.createProject('失败回滚'));
    final map = (await real(
      tester,
      () => repository.listMaps(project.id),
    )).single;
    await real(
      tester,
      () => repository.setMapLayout(map.id, model.MapLayoutKind.free),
    );
    final excerpt = await real(
      tester,
      () => repository.createExcerpt(
        model.ExcerptDraft(
          projectId: project.id,
          mapId: map.id,
          title: '验证移动失败',
          text: '',
          anchors: const [],
          x: 80,
          y: 80,
        ),
      ),
    );
    await mount(tester);
    final nodeFinder = find.byKey(Key('map-node-${excerpt.node.id}'));
    await until(tester, () async => nodeFinder.evaluate().isNotEmpty);
    await idle(tester);
    final pane = tester.widget<MindMapPane>(find.byType(MindMapPane));
    pane.controller!.setView(scale: 1);
    await tester.pump();
    final before = tester.getCenter(nodeFinder);
    final relativeBefore = before - tester.getTopLeft(find.byType(MindMapPane));
    final undoBefore = repository.undoEntryCount;
    final database = sqlite.sqlite3.open(
      '${repository.libraryPath}/library.sqlite',
    );
    try {
      database.execute(
        "CREATE TRIGGER reject_test_move BEFORE UPDATE OF x, y ON nodes BEGIN SELECT RAISE(FAIL, '验证移动写入失败'); END;",
      );
      final gesture = await tester.startGesture(
        before,
        kind: ui.PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(30, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(100, 40));
      await tester.pump();
      await gesture.up();
      await until(
        tester,
        () async => find.textContaining('验证移动写入失败').evaluate().isNotEmpty,
      );
      await idle(tester);
      await advance(tester);
      expect(find.textContaining('验证移动写入失败'), findsWidgets);
      final relativeAfter =
          tester.getCenter(nodeFinder) -
          tester.getTopLeft(find.byType(MindMapPane));
      // 错误栏会把整个脑图下移；验证节点相对画布的位置，而非窗口坐标。
      expect(
        (relativeAfter - relativeBefore).distance,
        lessThan(1),
        reason: '失败不能被工作台吞掉而留住未提交的临时位置',
      );
      final saved = (await real(
        tester,
        () => repository.loadMap(map.id),
      )).nodes.single;
      expect(saved.x, excerpt.node.x);
      expect(saved.y, excerpt.node.y);
      expect(repository.undoEntryCount, undoBefore);
      database.execute('DROP TRIGGER reject_test_move');
      await tester.drag(nodeFinder, const Offset(100, 50));
      await until(
        tester,
        () async =>
            (await repository.loadMap(map.id)).nodes.single.x != excerpt.node.x,
      );
      expect(repository.undoEntryCount, undoBefore + 1);
      expect(tester.takeException(), isNull);
    } finally {
      database.close();
      await unmount(tester);
    }
  });

  testWidgets('卡片菜单精简：工作台单击不弹工具，右键编辑保存和删除分支撤销可用', (tester) async {
    final project = await real(
      tester,
      () => repository.createProject('简洁卡片操作'),
    );
    final map = (await real(
      tester,
      () => repository.listMaps(project.id),
    )).single;
    final root = await real(
      tester,
      () => repository.createExcerpt(
        model.ExcerptDraft(
          projectId: project.id,
          mapId: map.id,
          title: '根卡片',
          text: '初始正文',
          note: '第一条思考',
          anchors: const [],
        ),
      ),
    );
    final child = await real(
      tester,
      () => repository.createExcerpt(
        model.ExcerptDraft(
          projectId: project.id,
          mapId: map.id,
          title: '子卡片',
          text: '子卡片正文',
          parentNodeId: root.node.id,
          anchors: const [],
        ),
      ),
    );
    await mount(tester);
    await clickMapNode(tester, root.node.id);
    expect(find.byKey(const ValueKey('map-card-actions')), findsNothing);
    expect(find.byType(PopupMenuItem<String>), findsNothing);
    expect(find.byType(CardEditor), findsNothing);
    await mapNodeMenuAction(tester, nodeId: root.node.id, action: 'edit');
    await until(
      tester,
      () async => find.byType(CardEditor).evaluate().isNotEmpty,
    );
    expect(
      tester.widget<CardEditor>(find.byType(CardEditor)).card.id,
      root.card.id,
    );
    await tester.enterText(find.byKey(const Key('card-body')), '菜单编辑后正文');
    await tester.enterText(find.byKey(const Key('card-note')), '菜单编辑后思考');
    await tester.tap(find.byTooltip('收起编辑'));
    await until(
      tester,
      () async =>
          find.byType(CardEditor).evaluate().isEmpty &&
          (await repository.getCard(root.card.id)).note == '菜单编辑后思考',
    );
    await idle(tester);
    final history = repository.undoEntryCount;
    await mapNodeMenuAction(
      tester,
      nodeId: root.node.id,
      action: 'removeBranch',
    );
    await until(
      tester,
      () async => (await repository.loadMap(map.id)).nodes.isEmpty,
    );
    expect(repository.undoEntryCount, history + 1);
    await idle(tester);
    await tester.tap(find.byTooltip('撤销 Ctrl+Z'));
    await until(
      tester,
      () async => (await repository.loadMap(map.id)).nodes.length == 2,
    );
    final restored = await real(tester, () => repository.loadMap(map.id));
    expect(restored.nodes.map((node) => node.id).toSet(), {
      root.node.id,
      child.node.id,
    });
    expect(restored.cards[root.card.id]!.body, '菜单编辑后正文');
    expect(restored.cards[root.card.id]!.thoughts.single.text, '菜单编辑后思考');
    await clickMapNode(tester, root.node.id);
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await until(
      tester,
      () async => find.byType(CardEditor).evaluate().isNotEmpty,
    );
    expect(
      tester.widget<CardEditor>(find.byType(CardEditor)).card.id,
      root.card.id,
    );
    expect(find.byKey(const ValueKey('map-card-actions')), findsNothing);
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('个人思考：工作台多条草稿跨尺寸与关闭提交，重开及删除撤销保留条目', (tester) async {
    final project = await real(
      tester,
      () => repository.createProject('多条个人思考'),
    );
    final map = (await real(
      tester,
      () => repository.listMaps(project.id),
    )).single;
    final created = await real(
      tester,
      () => repository.createExcerpt(
        model.ExcerptDraft(
          projectId: project.id,
          mapId: map.id,
          title: '思考卡片',
          text: '正文保持',
          note: '原有个人备注',
          anchors: const [],
        ),
      ),
    );
    await mount(tester);
    await clickMapNode(tester, created.node.id);
    await idle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await until(
      tester,
      () async => find.byType(CardEditor).evaluate().isNotEmpty,
    );
    await idle(tester);
    await tester.enterText(find.byKey(const Key('card-note')), '第一条个人思考');
    await tester.tap(find.byTooltip('添加个人思考'));
    await tester.pump();
    final secondField = find
        .byWidgetPredicate(
          (widget) =>
              widget is TextField &&
              widget.focusNode?.debugLabel == 'OpenNote 个人思考',
        )
        .last;
    await tester.enterText(secondField, '第二条未到自动保存时间');
    final field = tester.widget<TextField>(secondField);
    final editorState = tester.state(find.byType(CardEditor));
    await tester.binding.setSurfaceSize(const Size(900, 700));
    await tester.pump();
    expect(tester.state(find.byType(CardEditor)), same(editorState));
    expect(
      tester.widget<TextField>(secondField).controller,
      same(field.controller),
    );
    expect(field.focusNode!.hasFocus, isTrue);
    await tester.tap(find.byTooltip('收起编辑'));
    await until(
      tester,
      () async =>
          find.byType(CardEditor).evaluate().isEmpty &&
          (await repository.getCard(created.card.id)).thoughts.length == 2,
    );
    final saved = await real(tester, () => repository.getCard(created.card.id));
    expect(saved.thoughts.map((t) => t.text), ['第一条个人思考', '第二条未到自动保存时间']);
    expect(saved.body, '正文保持');
    expect(saved.excerptSnapshot, '正文保持');
    await idle(tester);
    await clickMapNode(tester, created.node.id);
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await until(
      tester,
      () async => find.byType(CardEditor).evaluate().isNotEmpty,
    );
    await idle(tester);
    final restoredFields = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.focusNode?.debugLabel == 'OpenNote 个人思考',
    );
    expect(restoredFields, findsNWidgets(2));
    expect(
      tester.widget<TextField>(restoredFields.last).controller!.text,
      saved.thoughts.last.text,
    );
    await tester.tap(restoredFields.first);
    await tester.pump();
    await tester.tap(find.byTooltip('删除这条思考').first);
    await tester.pump(const Duration(milliseconds: 550));
    await until(
      tester,
      () async =>
          (await repository.getCard(created.card.id)).thoughts.length == 1,
    );
    expect(
      (await real(
        tester,
        () => repository.getCard(created.card.id),
      )).thoughts.single.id,
      saved.thoughts.last.id,
    );
    await idle(tester);
    await tester.tap(find.byTooltip('撤销 Ctrl+Z'));
    await until(
      tester,
      () async =>
          (await repository.getCard(created.card.id)).thoughts.length == 2 &&
          restoredFields.evaluate().length == 2,
    );
    expect(
      (await real(tester, () => repository.getCard(created.card.id))).thoughts,
      saved.thoughts,
    );
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  void mockFullscreen(Future<bool> Function(bool enabled) handler) {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(WindowFullscreen.channel, (call) {
      if (call.method == 'setChromeRegions') return Future<bool>.value(false);
      expectSync(call.method, 'setFullscreen');
      return handler(call.arguments as bool);
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(WindowFullscreen.channel, null),
    );
  }

  bool immersive(WidgetTester tester) =>
      tester.widget<WorkbenchLayout>(find.byType(WorkbenchLayout)).immersive;

  Future<void> enterImmersive(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('workspace-immersive-reading')));
    await until(tester, () async => immersive(tester));
    await advance(tester);
  }

  testWidgets('沉浸式阅读：阅读位置、脑图、分栏和脏草稿跨尺寸与退出保持', (tester) async {
    final calls = <bool>[];
    mockFullscreen((enabled) async {
      calls.add(enabled);
      return enabled;
    });
    final fixture = await outlineFixture(tester);
    await idle(tester);
    final pane = find.byType(MindMapPane);
    final graph = tester.widget<MindMapPane>(pane).controller!;
    graph.centerOnNode(fixture.parent.node.id);
    await advance(tester);
    await clickMapNode(tester, fixture.parent.node.id);
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await until(
      tester,
      () async => find.byType(CardEditor).evaluate().isNotEmpty,
    );
    await idle(tester);
    final readerState = tester.state(find.byType(ReaderPane));
    final graphState = tester.state(pane);
    final editorState = tester.state(find.byType(CardEditor));
    final body = tester.widget<TextField>(find.byKey(const Key('card-body')));
    final bodyController = body.controller!;
    final viewer = tester.widget<PdfViewer>(find.byType(PdfViewer)).controller!;
    await real(
      tester,
      () => viewer.goToPosition(
        documentOffset: const Offset(30, 180),
        zoom: 1.6,
        duration: Duration.zero,
      ),
    );
    await advance(tester);
    final position = viewer.visibleRect.topLeft;
    final page = viewer.pageNumber;
    final split = tester
        .widget<WorkbenchSplit>(find.byType(WorkbenchSplit))
        .fraction;
    graph.setView(scale: .75, worldTopLeft: const Offset(-100, -80));
    await advance(tester);
    final mapPosition =
        tester.getTopLeft(
          find.byKey(Key('map-node-${fixture.parent.node.id}')),
        ) -
        tester.getTopLeft(pane);
    await tester.enterText(find.byKey(const Key('card-body')), '沉浸切换中的未提交正文');
    final selection = bodyController.selection;
    await enterImmersive(tester);
    expect(find.byTooltip('返回项目主页'), findsNothing);
    expect(find.byTooltip('添加文档'), findsNothing);
    expect(find.byTooltip('沉浸式阅读'), findsNothing);
    expect(find.text('按 Esc 退出沉浸式阅读'), findsOneWidget);
    expect(tester.getRect(find.byType(WorkbenchLayout)).topLeft, Offset.zero);
    expect(tester.state(find.byType(ReaderPane)), same(readerState));
    expect(tester.state(pane), same(graphState));
    expect(graph.scale, .75);
    expect(
      tester.getTopLeft(find.byKey(Key('map-node-${fixture.parent.node.id}'))) -
          tester.getTopLeft(pane),
      mapPosition,
    );
    expect(tester.state(find.byType(CardEditor)), same(editorState));
    expect(viewer.currentZoom, closeTo(1.6, .001));
    expect(viewer.pageNumber, page);
    expect(viewer.visibleRect.top, closeTo(position.dy, .01));
    expect(
      tester.widget<WorkbenchSplit>(find.byType(WorkbenchSplit)).fraction,
      split,
    );
    expect(bodyController.text, '沉浸切换中的未提交正文');
    expect(bodyController.selection, selection);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('card-body')))
          .focusNode!
          .hasFocus,
      isTrue,
      reason: '隐藏顶栏后恢复进入前的内容焦点',
    );
    await tester.binding.setSurfaceSize(const Size(900, 700));
    await tester.pump();
    expect(tester.state(find.byType(CardEditor)), same(editorState));
    expect(
      tester.widget<TextField>(find.byKey(const Key('card-body'))).controller,
      same(bodyController),
    );
    await tester.binding.setSurfaceSize(const Size(1920, 1080));
    await tester.pump();
    await tester.tap(find.byKey(const Key('card-body')));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await until(tester, () async => !immersive(tester));
    expect(find.byTooltip('添加文档'), findsOneWidget);
    expect(find.byTooltip('沉浸式阅读'), findsOneWidget);
    expect(tester.state(find.byType(ReaderPane)), same(readerState));
    expect(tester.state(find.byType(CardEditor)), same(editorState));
    expect(bodyController.text, '沉浸切换中的未提交正文');
    expect(calls, [true, false]);
    await until(
      tester,
      () async =>
          (await repository.getCard(fixture.parent.card.id)).body ==
          bodyController.text,
    );
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('沉浸式阅读：进入与退出失败保持实际布局且可重试', (tester) async {
    await real(tester, () => repository.createProject('全屏故障'));
    var reject = true;
    final calls = <bool>[];
    mockFullscreen((enabled) async {
      calls.add(enabled);
      if (reject) {
        throw PlatformException(code: 'fullscreen-failed', message: '切换测试故障');
      }
      return enabled;
    });
    await mount(tester);
    await idle(tester);
    await tester.tap(find.byKey(const Key('workspace-immersive-reading')));
    await until(
      tester,
      () async => find.textContaining('切换测试故障').evaluate().isNotEmpty,
    );
    expect(immersive(tester), isFalse);
    expect(find.byTooltip('添加文档'), findsOneWidget);
    reject = false;
    await enterImmersive(tester);
    reject = true;
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await advance(tester);
    expect(immersive(tester), isTrue);
    expect(calls, [true, true, false]);
    reject = false;
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await until(tester, () async => !immersive(tester));
    expect(calls, [true, true, false, false]);
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('沉浸式阅读：切换等待期间 Esc 排队退出且按钮禁止重复提交', (tester) async {
    await real(tester, () => repository.createProject('全屏队列'));
    final entered = Completer<bool>();
    final calls = <bool>[];
    mockFullscreen((enabled) {
      calls.add(enabled);
      return enabled ? entered.future : Future.value(false);
    });
    await mount(tester);
    await idle(tester);
    await tester.tap(find.byKey(const Key('workspace-immersive-reading')));
    await tester.pump();
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const Key('workspace-immersive-reading')),
          )
          .onPressed,
      isNull,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(calls, [true]);
    entered.complete(true);
    await until(tester, () async => calls.length == 2 && !immersive(tester));
    expect(calls, [true, false]);
    expect(find.text('按 Esc 退出沉浸式阅读'), findsNothing);
    await unmount(tester);
  });

  testWidgets('沉浸式阅读：脑图拖动与菜单先取消，下一次 Esc 退出', (tester) async {
    final calls = <bool>[];
    mockFullscreen((enabled) async {
      calls.add(enabled);
      return enabled;
    });
    final fixture = await heldDragFixture(
      tester,
      title: '全屏取消',
      attached: false,
    );
    await mount(tester);
    await until(
      tester,
      () async => find
          .byKey(Key('map-node-${fixture.parent.node.id}'))
          .evaluate()
          .isNotEmpty,
    );
    await idle(tester);
    final graph = tester
        .widget<MindMapPane>(find.byType(MindMapPane))
        .controller!;
    graph.centerOnNode(fixture.parent.node.id);
    await advance(tester);
    await enterImmersive(tester);
    await openMapStructureMenu(tester);
    await settleUi(tester);
    await capture(tester, captureKey, 'map-tools-immersive-menu-1920.png');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settleUi(tester);
    expect(find.byKey(const Key('context-menu-main')), findsOneWidget);
    expect(immersive(tester), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settleUi(tester);
    expect(immersive(tester), isTrue);
    final node = find.byKey(Key('map-node-${fixture.parent.node.id}'));
    final before = tester.getRect(node);
    final history = repository.undoEntryCount;
    final gesture = await tester.startGesture(
      tester.getCenter(node),
      kind: ui.PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(35, 20));
    await advance(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await advance(tester);
    expect(immersive(tester), isTrue);
    await gesture.up();
    await advance(tester);
    expect(tester.getRect(node), rectMoreOrLessEquals(before));
    expect(repository.undoEntryCount, history);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await until(tester, () async => !immersive(tester));
    expect(calls, [true, false]);
    await unmount(tester);
  });

  testWidgets('沉浸式阅读：PDF 选区先取消，下一次 Esc 退出', (tester) async {
    final calls = <bool>[];
    mockFullscreen((enabled) async {
      calls.add(enabled);
      return enabled;
    });
    final fixture = await outlineFixture(tester);
    await idle(tester);
    await enterImmersive(tester);
    final layer = (await real(
      tester,
      () => repository.loadTextLayers(fixture.document.activeRevisionId),
    )).singleWhere((value) => value.pageIndex == 0);
    await selectText(tester, repository, fixture.document, layer, 'OpenNote');
    expect(find.byKey(const Key('reader-selection-start')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await advance(tester);
    expect(find.byKey(const Key('reader-selection-start')), findsNothing);
    expect(immersive(tester), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await until(tester, () async => !immersive(tester));
    expect(calls, [true, false]);
    await unmount(tester);
  });

  testWidgets('沉浸式阅读：重复进出与返回首页恢复窗口并保留原资料栏选择', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1920, 1080);
    await real(tester, () => repository.createProject('全屏离开'));
    final calls = <bool>[];
    mockFullscreen((enabled) async {
      calls.add(enabled);
      return enabled;
    });
    await mount(tester);
    await idle(tester);
    await tester.tap(find.byTooltip('资料面板'));
    await tester.pump();
    expect(find.byTooltip('添加文档'), findsNothing);
    await enterImmersive(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await until(tester, () async => !immersive(tester));
    expect(find.byTooltip('添加文档'), findsNothing);
    await enterImmersive(tester);
    final workbench = tester.widget<Workbench>(find.byType(Workbench));
    await real(tester, workbench.onReturnHome);
    await until(tester, () async => find.byType(Workbench).evaluate().isEmpty);
    expect(calls, [true, false, true, false]);
    expect(find.byKey(const Key('home-new-project')), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('卡片脏草稿跨停靠和浮动尺寸保留，自动保存及关闭提交真实资料库', (tester) async {
    final project = await real(tester, () => repository.createProject('窗口编辑'));
    final map = (await real(
      tester,
      () => repository.listMaps(project.id),
    )).single;
    await real(
      tester,
      () => repository.setMapLayout(map.id, model.MapLayoutKind.free),
    );
    final excerpt = await real(
      tester,
      () => repository.createExcerpt(
        model.ExcerptDraft(
          projectId: project.id,
          mapId: map.id,
          title: '窗口草稿',
          text: '原正文',
          anchors: const [],
          x: 80,
          y: 80,
        ),
      ),
    );
    await tester.binding.setSurfaceSize(const Size(1920, 1080));
    await mount(tester);
    final nodeFinder = find.byKey(Key('map-node-${excerpt.node.id}'));
    await until(tester, () async => nodeFinder.evaluate().isNotEmpty);
    await idle(tester);
    tester
        .widget<MindMapPane>(find.byType(MindMapPane))
        .controller!
        .centerOnNode(excerpt.node.id);
    await advance(tester);
    expect(
      tester
          .getRect(find.byType(MindMapPane))
          .contains(tester.getCenter(nodeFinder)),
      isTrue,
      reason: '使用真实脑图相机定位后，鼠标必须命中可见卡片',
    );
    await tester.tap(nodeFinder, kind: ui.PointerDeviceKind.mouse);
    await until(
      tester,
      () async =>
          tester.widget<MindMapPane>(find.byType(MindMapPane)).selectedNodeId ==
              excerpt.node.id &&
          tester.widget<MindMapPane>(find.byType(MindMapPane)).selectedNodeId !=
              null,
    );
    await idle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await until(
      tester,
      () async => find.byType(CardEditor).evaluate().isNotEmpty,
    );
    await idle(tester);
    final editorState = tester.state(find.byType(CardEditor));
    final textController = tester
        .widget<TextField>(find.byKey(const Key('card-body')))
        .controller;
    await tester.enterText(find.byKey(const Key('card-body')), '缩放前尚未提交的正文');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.binding.setSurfaceSize(const Size(900, 700));
    await tester.pump();
    expect(find.byType(CardEditor), findsOneWidget);
    expect(tester.state(find.byType(CardEditor)), same(editorState));
    expect(
      tester.widget<TextField>(find.byKey(const Key('card-body'))).controller,
      same(textController),
    );
    expect(textController!.text, '缩放前尚未提交的正文');
    final floating = tester.getRect(
      find.byKey(const Key('workspace-card-editor')),
    );
    expect(floating.width, 360);
    expect(floating.right, 884);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('card-body')))
          .focusNode!
          .hasFocus,
      isTrue,
      reason: '从停靠切换到浮动后，正文焦点保留',
    );
    await tester.binding.setSurfaceSize(const Size(1920, 1080));
    await tester.pump();
    expect(tester.state(find.byType(CardEditor)), same(editorState));
    expect(textController.text, '缩放前尚未提交的正文');
    await tester.pump(const Duration(milliseconds: 550));
    await until(
      tester,
      () async =>
          (await repository.getCard(excerpt.card.id)).body == '缩放前尚未提交的正文',
    );
    await tester.enterText(
      find.byKey(const Key('card-note')),
      '关闭前不足自动保存间隔的备注',
    );
    await tester.tap(find.byTooltip('收起编辑'));
    await until(
      tester,
      () async =>
          find.byType(CardEditor).evaluate().isEmpty &&
          (await repository.getCard(excerpt.card.id)).note == '关闭前不足自动保存间隔的备注',
    );
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('900逻辑像素窗口首次打开卡片编辑即可输入并自动保存', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.25;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final project = await real(
      tester,
      () => repository.createProject('窄窗首次编辑'),
    );
    final map = (await real(
      tester,
      () => repository.listMaps(project.id),
    )).single;
    await real(
      tester,
      () => repository.setMapLayout(map.id, model.MapLayoutKind.free),
    );
    final excerpt = await real(
      tester,
      () => repository.createExcerpt(
        model.ExcerptDraft(
          projectId: project.id,
          mapId: map.id,
          title: '窄窗卡片',
          text: '',
          anchors: const [],
          x: 80,
          y: 80,
        ),
      ),
    );
    await mount(tester);
    await tester.binding.setSurfaceSize(const Size(900, 700));
    await tester.pump();
    final nodeFinder = find.byKey(Key('map-node-${excerpt.node.id}'));
    await until(tester, () async => nodeFinder.evaluate().isNotEmpty);
    await idle(tester);
    tester
        .widget<MindMapPane>(find.byType(MindMapPane))
        .controller!
        .centerOnNode(excerpt.node.id);
    await advance(tester);
    expect(
      tester
          .getRect(find.byType(MindMapPane))
          .contains(tester.getCenter(nodeFinder)),
      isTrue,
      reason: '窄窗真实鼠标点击之前必须把卡片定位到当前视口',
    );
    await tester.tap(nodeFinder, kind: ui.PointerDeviceKind.mouse);
    await idle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await until(
      tester,
      () async => find.byKey(const Key('card-body')).evaluate().isNotEmpty,
    );
    await tester.enterText(find.byKey(const Key('card-body')), '窄窗也能编辑');
    await tester.pump(const Duration(milliseconds: 550));
    await until(
      tester,
      () async => (await repository.getCard(excerpt.card.id)).body == '窄窗也能编辑',
    );
    expect(find.byType(CardEditor), findsOneWidget);
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('四种图文联动按方向定位真实PDF与卡片，自动跳转不打开编辑器', (tester) async {
    final project = await real(tester, () => repository.createProject('联动方向'));
    final map = (await real(
      tester,
      () => repository.listMaps(project.id),
    )).single;
    await real(
      tester,
      () => repository.setMapLayout(map.id, model.MapLayoutKind.free),
    );
    final document = await real(
      tester,
      () => repository.importPdf(
        projectId: project.id,
        filePath: File('tools/fixtures/pdf/native.pdf').absolute.path,
        pageCount: 2,
      ),
    );
    await mount(tester);
    await until(
      tester,
      () async =>
          readerReady(tester) &&
          (await repository.loadTextLayers(document.activeRevisionId)).length ==
              2,
    );
    final layers = await real(
      tester,
      () => repository.loadTextLayers(document.activeRevisionId),
    );
    final layer = layers.singleWhere((value) => value.pageIndex == 0);
    final start = layer.text.indexOf('OpenNote');
    expect(start, greaterThanOrEqualTo(0));
    final quads = layer.fragments
        .where(
          (fragment) =>
              fragment.start < start + 8 &&
              fragment.start + fragment.length > start,
        )
        .map((fragment) => fragment.quad)
        .toList();
    final excerpt = await real(
      tester,
      () => repository.createExcerpt(
        model.ExcerptDraft(
          projectId: project.id,
          mapId: map.id,
          title: '原文联动卡片',
          text: 'OpenNote',
          anchors: [
            model.AnchorDraft(
              revisionId: document.activeRevisionId,
              pageIndex: 0,
              quads: quads,
              textLayerId: layer.id,
              textStart: start,
              textEnd: start + 8,
              context: 'OpenNote',
            ),
          ],
          x: 80,
          y: 80,
          createHighlight: true,
        ),
      ),
    );
    final theme = await real(
      tester,
      () => repository.createExcerpt(
        model.ExcerptDraft(
          projectId: project.id,
          mapId: map.id,
          title: '无来源主题',
          text: '',
          anchors: const [],
          x: 440,
          y: 80,
        ),
      ),
    );
    final nodeFinder = find.byKey(Key('map-node-${excerpt.node.id}'));
    await until(tester, () async => nodeFinder.evaluate().isNotEmpty);
    final annotation = (await real(
      tester,
      () => repository.listAnnotations(document.activeRevisionId),
    )).singleWhere((value) => value.cardId == excerpt.card.id);
    final revision = await real(
      tester,
      () => repository.getRevision(document.activeRevisionId),
    );
    expect(find.byTooltip('图文联动：双向联动'), findsOneWidget);
    for (final mode in [
      ('双向联动', true, true),
      ('文档定位脑图', false, true),
      ('脑图定位文档', true, false),
      ('关闭联动', false, false),
    ]) {
      await idle(tester);
      await tester.tap(find.byKey(const Key('workspace-view-link-mode')));
      await settleUi(tester);
      await tester.tap(
        find.ancestor(
          of: find.text(mode.$1),
          matching: find.byWidgetPredicate(
            (widget) => widget is CheckedPopupMenuItem,
          ),
        ),
      );
      await settleUi(tester);
      await real(
        tester,
        () => tester
            .widget<ReaderPane>(find.byType(ReaderPane))
            .controller!
            .goToPage(1),
      );
      await until(
        tester,
        () async =>
            tester
                .widget<PdfViewer>(find.byType(PdfViewer))
                .controller!
                .pageNumber ==
            2,
      );
      tester
          .widget<MindMapPane>(find.byType(MindMapPane))
          .controller!
          .centerOnNode(excerpt.node.id);
      await advance(tester);
      await tester.pump();
      expect(
        tester
            .getRect(find.byType(MindMapPane))
            .contains(tester.getCenter(nodeFinder)),
        isTrue,
      );
      await tester.tap(nodeFinder, kind: ui.PointerDeviceKind.mouse);
      await advance(tester);
      await idle(tester);
      await settleUi(tester);
      expect(
        tester.widget<PdfViewer>(find.byType(PdfViewer)).controller!.pageNumber,
        mode.$2 ? 1 : 2,
        reason: '${mode.$1}的脑图到文档方向',
      );
      expect(find.byType(CardEditor), findsNothing);
      await real(
        tester,
        () => tester
            .widget<ReaderPane>(find.byType(ReaderPane))
            .controller!
            .goToPage(0),
      );
      await until(
        tester,
        () async =>
            tester
                .widget<PdfViewer>(find.byType(PdfViewer))
                .controller!
                .pageNumber ==
            1,
      );
      final backgroundPoint =
          tester.getBottomRight(find.byType(MindMapPane)) -
          const Offset(15, 80);
      expect(
        tester
            .getRect(find.byKey(const ValueKey('map-viewport-controls')))
            .contains(backgroundPoint),
        isFalse,
        reason: '清空选择落点在缩放工具组之外',
      );
      expect(tester.getRect(nodeFinder).contains(backgroundPoint), isFalse);
      expect(
        tester
            .hitTestOnBinding(backgroundPoint)
            .path
            .any(
              (entry) => identical(
                entry.target,
                tester.renderObject(find.byType(MindMapPane)),
              ),
            ),
        isTrue,
        reason: '清空选择的真实鼠标必须命中脑图背景，不能点击浮动菜单',
      );
      await tester.tapAt(backgroundPoint, kind: ui.PointerDeviceKind.mouse);
      await advance(tester);
      await until(
        tester,
        () async =>
            tester
                .widget<MindMapPane>(find.byType(MindMapPane))
                .selectedNodeId ==
            null,
      );
      await idle(tester);
      await tester.tapAt(
        quadPosition(tester, document, annotation.quads.first, revision),
      );
      await idle(tester);
      await settleUi(tester);
      expect(
        tester.widget<MindMapPane>(find.byType(MindMapPane)).selectedNodeId,
        mode.$3 ? excerpt.node.id : null,
        reason: '${mode.$1}的文档到脑图方向',
      );
      expect(find.byType(CardEditor), findsNothing);
      expect(tester.takeException(), isNull);
    }
    await tester.tap(find.byKey(const Key('workspace-view-link-mode')));
    await settleUi(tester);
    await tester.tap(
      find.ancestor(
        of: find.text('双向联动'),
        matching: find.byWidgetPredicate(
          (widget) => widget is CheckedPopupMenuItem,
        ),
      ),
    );
    await settleUi(tester);
    for (final hasQuads in [true, false]) {
      final source = hasQuads ? excerpt : theme;
      await idle(tester);
      final reader = tester
          .widget<ReaderPane>(find.byType(ReaderPane))
          .controller!;
      final viewer = tester
          .widget<PdfViewer>(find.byType(PdfViewer))
          .controller!;
      await real(tester, () => reader.goToPage(1));
      expect(viewer.pageNumber, 2);
      final sourceFinder = find.byKey(Key('map-node-${source.node.id}'));
      tester
          .widget<MindMapPane>(find.byType(MindMapPane))
          .controller!
          .centerOnNode(source.node.id);
      await advance(tester);
      await tester.pump();
      final sourceCenter = tester.getCenter(sourceFinder);
      expect(
        tester.getRect(find.byType(MindMapPane)).contains(sourceCenter),
        isTrue,
      );
      expect(
        tester
            .hitTestOnBinding(sourceCenter)
            .path
            .any(
              (entry) =>
                  identical(entry.target, tester.renderObject(sourceFinder)),
            ),
        isTrue,
      );
      final startingZoom = viewer.currentZoom;
      final startingY = viewer.value.storage[13];
      var followedNavigation = false;
      var followingFinished = false;
      Object? followingError;
      var initialFinished = hasQuads;
      Object? initialError;
      void followSourceImmediately() {
        if (followedNavigation ||
            ((viewer.currentZoom - startingZoom).abs() < startingZoom * .05 &&
                (viewer.value.storage[13] - startingY).abs() < 40)) {
          return;
        }
        followedNavigation = true;
        // 来源矩阵刚改变就接受下一次阅读导航，不先等工作台空闲。
        unawaited(
          Future<void>.microtask(() async {
            viewer.removeListener(followSourceImmediately);
            try {
              await reader.goToPage(1);
            } catch (error) {
              followingError = error;
            } finally {
              followingFinished = true;
            }
          }),
        );
      }

      viewer.addListener(followSourceImmediately);
      try {
        await tester.tap(sourceFinder, kind: ui.PointerDeviceKind.mouse);
        if (!hasQuads) {
          // 页级定位属于阅读控制器接口，不写入要求有效区域的持久锚点。
          unawaited(
            reader
                .jumpToAnchors([
                  model.AnchorDraft(
                    revisionId: document.activeRevisionId,
                    pageIndex: 0,
                    quads: const [],
                  ),
                ])
                .then<void>(
                  (_) {
                    initialFinished = true;
                  },
                  onError: (Object error) {
                    initialError = error;
                    initialFinished = true;
                  },
                ),
          );
        }
        await until(tester, () async => followedNavigation, attempts: 100);
        await until(tester, () async => followingFinished, attempts: 100);
        await until(tester, () async => initialFinished, attempts: 100);
        expect(followingError, isNull);
        expect(initialError, isNull);
        expect(viewer.pageNumber, 2);
        await tester.tapAt(
          tester.getBottomRight(find.byType(MindMapPane)) -
              const Offset(15, 80),
          kind: ui.PointerDeviceKind.mouse,
        );
        await until(
          tester,
          () async =>
              tester
                  .widget<MindMapPane>(find.byType(MindMapPane))
                  .selectedNodeId ==
              null,
          attempts: 100,
        );
        await idle(tester);
        // Flutter 3.47 双击识别器的尾部计时器按测试时钟排空。
        await tester.pump(const Duration(milliseconds: 350));
        expect(find.byType(CardEditor), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        viewer.removeListener(followSourceImmediately);
      }
    }
    await real(
      tester,
      () => tester
          .widget<ReaderPane>(find.byType(ReaderPane))
          .controller!
          .goToPage(1),
    );
    tester
        .widget<MindMapPane>(find.byType(MindMapPane))
        .controller!
        .centerOnNode(theme.node.id);
    await advance(tester);
    await tester.pump();
    final themeFinder = find.byKey(Key('map-node-${theme.node.id}'));
    final themeCenter = tester.getCenter(themeFinder);
    expect(
      tester.getRect(find.byType(MindMapPane)).contains(themeCenter),
      isTrue,
      reason: '无来源主题验证也必须执行真实可见卡片点击',
    );
    expect(
      tester
          .hitTestOnBinding(themeCenter)
          .path
          .any(
            (entry) =>
                identical(entry.target, tester.renderObject(themeFinder)),
          ),
      isTrue,
    );
    await tester.tap(themeFinder, kind: ui.PointerDeviceKind.mouse);
    await until(
      tester,
      () async =>
          tester.widget<MindMapPane>(find.byType(MindMapPane)).selectedNodeId ==
          theme.node.id,
    );
    await idle(tester);
    expect(
      tester.widget<PdfViewer>(find.byType(PdfViewer)).controller!.pageNumber,
      2,
    );
    expect(find.text('主题卡片没有原文来源'), findsNothing);
    expect(find.byType(CardEditor), findsNothing);
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('真实工作台：项目导入、选文、保存、双向回源、单字搜索、删PDF与备份恢复', (tester) async {
    await mount(tester);
    await tester.tap(find.byKey(const Key('home-new-project')));
    await settleUi(tester);
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      '集成阅读项目',
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '创建'));
    await until(
      tester,
      () async => (await repository.listProjects()).length == 1,
    );
    final project = (await real(tester, repository.listProjects)).single;
    final readingMap = (await real(
      tester,
      () => repository.listMaps(project.id),
    )).single;
    await real(
      tester,
      () => repository.setMapLayout(readingMap.id, model.MapLayoutKind.free),
    );
    await until(
      tester,
      () async =>
          find.byTooltip('新建主题 Ctrl+N').evaluate().isNotEmpty &&
          find.byType(LinearProgressIndicator).evaluate().isEmpty,
    );

    selector.importPaths = [
      File('tools/fixtures/pdf/native.pdf').absolute.path,
    ];
    await tester.tap(find.byTooltip('添加文档'));
    await until(
      tester,
      () async => (await repository.listDocuments(project.id)).length == 1,
    );
    final document = (await real(
      tester,
      () => repository.listDocuments(project.id),
    )).single;
    await until(
      tester,
      () async =>
          (await repository.loadTextLayers(document.activeRevisionId)).length ==
              2 &&
          readerReady(tester),
    );
    final layers = (await real(
      tester,
      () => repository.loadTextLayers(document.activeRevisionId),
    ));
    final layer = layers.singleWhere((layer) => layer.pageIndex == 0);
    await idle(tester);
    expect(
      tester.getCenter(find.byType(PdfViewer)).dx,
      lessThan(tester.getCenter(find.byType(MindMapPane)).dx),
      reason: '用户指定 PDF 在左、脑图在右',
    );
    await selectText(tester, repository, document, layer, 'OpenNote');
    expect(
      tester.widget<IconButton>(excerptButton()).onPressed,
      isNotNull,
      reason: '真实文字拖选必须形成选区',
    );
    await tester.tap(excerptButton());
    await until(
      tester,
      () async => (await repository.listCards(project.id)).length == 1,
    );
    var card = (await real(
      tester,
      () => repository.listCards(project.id),
    )).single;
    final anchors = (await real(tester, () => repository.getAnchors(card.id)));
    expect(card.excerptSnapshot, 'OpenNote');
    final savedLayers = await real(
      tester,
      () => repository.loadTextLayers(
        document.activeRevisionId,
        currentOnly: false,
      ),
    );
    final anchorLayer = savedLayers.singleWhere(
      (value) => value.id == anchors.single.textLayerId,
    );
    expect(
      anchorLayer.text.substring(
        anchors.single.textStart!,
        anchors.single.textEnd!,
      ),
      'OpenNote',
    );
    expect(
      (await real(
        tester,
        () => repository.listAnnotations(document.activeRevisionId),
      )).single.cardId,
      card.id,
    );

    await until(
      tester,
      () async =>
          tester.widget<MindMapPane>(find.byType(MindMapPane)).selectedNodeId !=
          null,
    );
    await idle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await until(
      tester,
      () async => find.byKey(const Key('card-body')).evaluate().isNotEmpty,
    );
    await idle(tester);
    await tester.enterText(find.byKey(const Key('card-body')), '独立编辑的卡片正文');
    await tester.enterText(find.byKey(const Key('card-note')), '个人备注自动保存');
    await tester.pump(const Duration(milliseconds: 550));
    await until(
      tester,
      () async => (await repository.getCard(card.id)).note == '个人备注自动保存',
    );
    card = await real(tester, () => repository.getCard(card.id));
    expect(card.body, '独立编辑的卡片正文');
    expect(card.excerptSnapshot, 'OpenNote');
    expect(tester.takeException(), isNull);
    await settleUi(tester);
    await capture(tester, captureKey, 'workbench-1280x720.png');

    // 输入框的 Ctrl+Z 不得消耗资料库命令历史。
    await tester.tap(find.byKey(const Key('card-note')));
    expect(repository.canRedo, isFalse);
    await ctrl(tester, LogicalKeyboardKey.keyZ);
    await advance(tester, milliseconds: 20, pumpDuration: Duration.zero);
    expect(repository.canRedo, isFalse, reason: '文本焦点的撤销应由 EditableText 处理');
    await tester.enterText(find.byKey(const Key('card-note')), '个人备注自动保存');
    await tester.pump(const Duration(milliseconds: 550));
    await advance(tester);

    final map = (await real(
      tester,
      () => repository.listMaps(project.id),
    )).single;
    final node = (await real(
      tester,
      () => repository.loadMap(map.id),
    )).nodes.single;
    await tester.tap(
      find.byKey(Key('map-node-${node.id}')),
      kind: ui.PointerDeviceKind.mouse,
    );
    await tester.pump();
    await idle(tester);
    await ctrl(tester, LogicalKeyboardKey.keyZ);
    await advance(tester);
    await until(tester, () async => repository.canRedo);
    expect(
      (await real(tester, () => repository.getCard(card.id))).body,
      'OpenNote',
    );
    await idle(tester);
    await ctrl(tester, LogicalKeyboardKey.keyY);
    await until(
      tester,
      () async => (await repository.getCard(card.id)).body == '独立编辑的卡片正文',
    );
    await idle(tester);

    await tester.tap(
      find.byKey(Key('map-node-${node.id}')),
      kind: ui.PointerDeviceKind.mouse,
    );
    await until(
      tester,
      () async =>
          tester.widget<MindMapPane>(find.byType(MindMapPane)).selectedNodeId !=
          null,
    );
    await idle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await until(
      tester,
      () async => find.byKey(const Key('card-body')).evaluate().isNotEmpty,
    );
    await idle(tester);

    // 125% DPI 的逻辑窗口等价尺寸：所有核心面板继续可用。
    await tester.binding.setSurfaceSize(const Size(1024, 576));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byType(PdfViewer), findsOneWidget);
    expect(find.byKey(const Key('card-body')), findsOneWidget);
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    await tester.pump();
    await tester.binding.setSurfaceSize(null);
    tester.view.devicePixelRatio = 1.5;
    tester.view.physicalSize = const Size(1920, 1080);
    await tester.pump();
    expect(
      MediaQuery.sizeOf(tester.element(find.byType(Workbench))),
      const Size(1280, 720),
    );
    expect(tester.takeException(), isNull);
    await capture(
      tester,
      captureKey,
      'workbench-1920x1080-at150.png',
      pixelRatio: 1.5,
    );
    tester.view.resetDevicePixelRatio();
    tester.view.resetPhysicalSize();
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    await tester.pump();

    await tester.tap(
      find.descendant(
        of: find.byType(CardEditor),
        matching: find.byTooltip('回到原文'),
      ),
    );
    await until(tester, () async => readerReady(tester));
    await tester.tap(find.byTooltip('收起编辑'));
    await until(
      tester,
      () async => find.byKey(const Key('card-body')).evaluate().isEmpty,
    );
    final annotation = (await real(
      tester,
      () => repository.listAnnotations(document.activeRevisionId),
    )).single;
    await tester.tapAt(
      quadPosition(
        tester,
        document,
        annotation.quads.first,
        (await real(
          tester,
          () => repository.getRevision(document.activeRevisionId),
        ))!,
      ),
    );
    await until(
      tester,
      () async =>
          tester.widget<MindMapPane>(find.byType(MindMapPane)).selectedNodeId ==
          node.id,
    );
    expect(
      find.byType(CardEditor),
      findsNothing,
      reason: '点击文档摘录只联动定位，不强制进入编辑',
    );
    await idle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await until(
      tester,
      () async => find.byKey(const Key('card-body')).evaluate().isNotEmpty,
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('card-body')))
          .controller!
          .text,
      card.body,
    );

    await idle(tester);
    await tester.tap(find.byTooltip('搜索 Ctrl+F'));
    await settleUi(tester);
    await tester.enterText(find.byKey(const Key('search-input')), '原');
    await tester.pump(const Duration(milliseconds: 200));
    await until(
      tester,
      () async => find.text('原文 · 第 1 页').evaluate().isNotEmpty,
    );
    await tester.tap(
      find
          .ancestor(
            of: find.text('原文 · 第 1 页'),
            matching: find.byType(ListTile),
          )
          .first,
    );
    await until(
      tester,
      () async =>
          find.byKey(const Key('search-input')).evaluate().isEmpty &&
          readerReady(tester),
    );

    // 资料移入回收站后，摘录保留原文版本和资源，卡片仍可真实回源。
    final tile = find
        .ancestor(
          of: find.text(document.title),
          matching: find.byType(ListTile),
        )
        .first;
    await tester.tap(
      find.descendant(of: tile, matching: find.byType(PopupMenuButton<String>)),
    );
    await settleUi(tester);
    await tester.tap(find.text('移入回收站'));
    await until(
      tester,
      () async => (await repository.listDocuments(project.id)).isEmpty,
    );
    await idle(tester);
    await tester.tap(
      find.descendant(
        of: find.byType(CardEditor),
        matching: find.byTooltip('回到原文'),
      ),
    );
    await advance(tester);
    expect(readerReady(tester), isTrue);
    expect(
      (await real(tester, () => repository.getAnchors(card.id))).single.id,
      anchors.single.id,
    );

    selector.backupPath = '${temp.path}/完整备份.onbackup';
    await returnHome(tester);
    await menu(tester, '完整备份…');
    await until(tester, () async => File(selector.backupPath!).existsSync());
    await until(
      tester,
      () async => find.byType(LinearProgressIndicator).evaluate().isEmpty,
    );
    await openHomeProject(tester, project.id);
    await clickMapNode(tester, node.id);
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await until(
      tester,
      () async => find
          .descendant(
            of: find.byType(CardEditor),
            matching: find.byTooltip('回到原文'),
          )
          .evaluate()
          .isNotEmpty,
    );
    await tester.tap(
      find.descendant(
        of: find.byType(CardEditor),
        matching: find.byTooltip('回到原文'),
      ),
    );
    await until(tester, () async => readerReady(tester));
    await tester.enterText(find.byKey(const Key('card-note')), '备份之后的改动');
    await tester.pump(const Duration(milliseconds: 550));
    await until(
      tester,
      () async => (await repository.getCard(card.id)).note == '备份之后的改动',
    );
    final oldSession = repository.sessionId;
    final oldPdfPath = tester
        .widget<ReaderPane>(find.byType(ReaderPane))
        .filePath;
    final oldPdfDocument = tester
        .widget<PdfViewer>(find.byType(PdfViewer))
        .controller!
        .document;
    selector.restorePath = selector.backupPath;
    await returnHome(tester);
    await menu(tester, '恢复整个资料库…');
    await settleUi(tester);
    await tester.tap(find.widgetWithText(FilledButton, '恢复'));
    await until(
      tester,
      () async =>
          repository.sessionId != oldSession &&
          find.byType(LinearProgressIndicator).evaluate().isEmpty &&
          find.byKey(const Key('home-new-project')).evaluate().isNotEmpty &&
          tester
                  .widget<IconButton>(find.byKey(const Key('home-new-project')))
                  .onPressed !=
              null,
    );
    expect(repository.canUndo, isFalse);
    expect(repository.canRedo, isFalse);
    expect(
      (await real(tester, () => repository.getCard(card.id))).note,
      '个人备注自动保存',
    );
    expect(
      find.byKey(const Key('card-body')),
      findsNothing,
      reason: '恢复资料库后旧卡片编辑状态必须清空',
    );
    expect(
      await real(tester, () => repository.getAnchors(card.id)),
      hasLength(1),
    );
    expect((oldPdfDocument as dynamic).isDisposed, isTrue);
    await real(tester, () async {
      final moved = await File(oldPdfPath)
          .rename('$oldPdfPath.restore-close-check');
      await moved.rename(oldPdfPath);
    });
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('PDF导航：项目数量控制标签行，添加入口与阅读会话保持', (tester) async {
    final project = await real(tester, () => repository.createProject('PDF导航'));
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1920, 1080);
    await mount(tester);
    await idle(tester);
    expect(find.byKey(const Key('workspace-document-tabs')), findsNothing);
    expect(find.byTooltip('导入文档'), findsNothing);
    expect(find.widgetWithText(FilledButton, '添加文档'), findsOneWidget);
    await tester.tap(find.byTooltip('添加文档'));
    await settleUi(tester);
    expect(
      await real(tester, () => repository.listDocuments(project.id)),
      isEmpty,
    );

    selector.importPaths = [
      File('tools/fixtures/pdf/native.pdf').absolute.path,
    ];
    await tester.tap(find.byTooltip('添加文档'));
    await until(tester, () async => readerReady(tester));
    await idle(tester);
    expect(find.byKey(const Key('workspace-document-tabs')), findsNothing);
    final state = tester.state(find.byType(ReaderPane));
    final viewer = tester.widget<PdfViewer>(find.byType(PdfViewer)).controller!;
    await real(
      tester,
      () => viewer.goToPage(pageNumber: 2, duration: Duration.zero),
    );
    await real(
      tester,
      () => viewer.setZoom(
        viewer.visibleRect.center,
        1.25,
        duration: Duration.zero,
      ),
    );
    await tester.pumpAndSettle();
    final position = viewer.visibleRect;
    final first = (await real(
      tester,
      () => repository.listDocuments(project.id),
    )).single;
    final copy = await real(
      tester,
      () => File('tools/fixtures/pdf/native.pdf').copy('${temp.path}/第二份.pdf'),
    );
    final second = await real(
      tester,
      () => repository.importPdf(
        projectId: project.id,
        filePath: copy.path,
        pageCount: 2,
      ),
    );
    await until(
      tester,
      () async => find
          .byKey(const Key('workspace-document-tabs'))
          .evaluate()
          .isNotEmpty,
    );
    expect(find.byKey(Key('document-tab-${first.id}')), findsOneWidget);
    expect(
      find.byKey(Key('document-tab-${second.id}')),
      findsNothing,
      reason: '项目有两份资料但只打开一份时仍显示标签行',
    );
    expect(tester.state(find.byType(ReaderPane)), same(state));
    expect(viewer.currentZoom, closeTo(1.25, .001));
    expect(viewer.pageNumber, 2);
    await real(tester, () => repository.trashDocument(second.id));
    await until(
      tester,
      () async =>
          find.byKey(const Key('workspace-document-tabs')).evaluate().isEmpty,
    );
    expect(tester.state(find.byType(ReaderPane)), same(state));
    expect(viewer.currentZoom, closeTo(1.25, .001));
    expect(viewer.pageNumber, 2);
    expect(viewer.visibleRect.left, closeTo(position.left, .01));
    await tester.tap(find.byTooltip('资料面板'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('添加文档'), findsNothing);
    expect(find.byTooltip('导入文档'), findsNothing);
    await tester.tap(find.byTooltip('资料面板'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('添加文档'), findsOneWidget);
    selector.importPaths = [];
    await tester.tap(find.byTooltip('添加文档'));
    await settleUi(tester);
    expect(
      await real(tester, () => repository.listDocuments(project.id)),
      hasLength(1),
    );
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('PDF 目录记忆：不同文档分别恢复开关与宽度，返回项目和重启仍保留', (tester) async {
    final project = await real(tester, () => repository.createProject('目录偏好'));
    final fixture = File('tools/fixtures/pdf/native.pdf').absolute;
    final documents = <model.ManagedDocument>[];
    for (final name in ['目录甲', '目录乙']) {
      final copy = await real(
        tester,
        () => fixture.copy('${temp.path}/$name.pdf'),
      );
      documents.add(
        await real(
          tester,
          () => repository.importPdf(
            projectId: project.id,
            filePath: copy.path,
            pageCount: 2,
          ),
        ),
      );
    }
    await mount(tester);
    await until(tester, () async => readerReady(tester));
    final first = documents.firstWhere(
      (document) =>
          document.activeRevisionId ==
          tester.widget<ReaderPane>(find.byType(ReaderPane)).revisionId,
    );
    final second = documents.firstWhere((document) => document.id != first.id);
    final sidebar = find.byKey(const Key('reader-sidebar'));
    Future<model.PdfReadingSettings> saved(model.ManagedDocument document) =>
        repository.loadPdfReadingSettings(document.activeRevisionId);
    Future<void> select(model.ManagedDocument document) async {
      await tester.tap(find.widgetWithText(ListTile, document.title));
      await until(
        tester,
        () async =>
            readerReady(tester) &&
            tester.widget<ReaderPane>(find.byType(ReaderPane)).revisionId ==
                document.activeRevisionId,
      );
      await idle(tester);
    }

    expect(sidebar, findsNothing);
    await tester.tap(find.byTooltip('目录与缩略图'));
    await tester.pump();
    await tester.drag(
      find.byKey(const Key('reader-sidebar-divider')),
      const Offset(80, 0),
    );
    await tester.pump();
    final firstWidth = tester.getSize(sidebar).width;
    expect(firstWidth, greaterThan(220));
    await until(tester, () async {
      final value = await saved(first);
      return value.sidebarVisible && value.sidebarWidth == firstWidth;
    });
    await select(second);
    expect(sidebar, findsNothing, reason: '新 PDF 不继承另一个 PDF 的目录状态');
    await tester.tap(find.byTooltip('目录与缩略图'));
    await tester.pump();
    await tester.drag(
      find.byKey(const Key('reader-sidebar-divider')),
      const Offset(-50, 0),
    );
    await tester.pump();
    final secondWidth = tester.getSize(sidebar).width;
    expect(secondWidth, lessThan(220));
    await tester.tap(find.byTooltip('目录与缩略图'));
    await tester.pump();
    await until(tester, () async {
      final value = await saved(second);
      return !value.sidebarVisible && value.sidebarWidth == secondWidth;
    });
    await select(first);
    expect(tester.getSize(sidebar).width, firstWidth);
    await returnHome(tester);
    await openHomeProject(tester, project.id);
    await until(tester, () async => readerReady(tester));
    expect(tester.getSize(sidebar).width, firstWidth);
    await select(second);
    expect(sidebar, findsNothing);
    await tester.tap(find.byTooltip('目录与缩略图'));
    await tester.pump();
    expect(tester.getSize(sidebar).width, secondWidth);
    await until(tester, () async => (await saved(second)).sidebarVisible);
    await returnHome(tester);
    await unmount(tester);
    final root = repository.rootPath;
    await real(tester, repository.close);
    repositoryClosed = true;
    repository = await real(
      tester,
      () => OpenNoteRepository.open(rootPath: root),
    );
    repositoryClosed = false;
    await mount(tester);
    await until(tester, () async => readerReady(tester));
    expect(
      tester.widget<ReaderPane>(find.byType(ReaderPane)).revisionId,
      second.activeRevisionId,
    );
    expect(tester.getSize(sidebar).width, secondWidth);
    await select(first);
    expect(tester.getSize(sidebar).width, firstWidth);
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('工作台精简标题：单 PDF 阅读区上移、单脑图隐藏标题且加号可以新建', (tester) async {
    final project = await real(
      tester,
      () => repository.createProject('单项阅读布局'),
    );
    final map = (await real(
      tester,
      () => repository.listMaps(project.id),
    )).single;
    final fixture = File('tools/fixtures/pdf/native.pdf').absolute;
    final geometry = await real(
      tester,
      () => PdfReadEngine.loadSourceGeometry(fixture.path),
    );
    final document = await real(
      tester,
      () => repository.importPdf(
        projectId: project.id,
        filePath: fixture.path,
        pageCount: geometry.length,
        pageGeometry: geometry,
      ),
    );
    await mount(tester);
    await until(tester, () async => readerReady(tester));
    await idle(tester);
    final header = find.byKey(const Key('workspace-map-header'));
    final reader = find.byType(ReaderPane);
    expect(find.byKey(const Key('workspace-document-tabs')), findsNothing);
    expect(
      tester.getTopLeft(reader).dy,
      tester.getTopLeft(header).dy,
      reason: '单 PDF 不再占用额外 40 像素的文件名行',
    );
    expect(
      find.descendant(of: header, matching: find.text(map.title)),
      findsNothing,
    );
    expect(find.byTooltip('画布'), findsOneWidget);
    expect(find.byTooltip('大纲'), findsOneWidget);
    final newTopic = find.byKey(const ValueKey('map-new-topic'));
    expect(tester.widget(newTopic), isA<IconButton>());
    expect(
      find.descendant(of: newTopic, matching: find.byIcon(Icons.add)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: newTopic, matching: find.byType(Text)),
      findsNothing,
    );
    expect(tester.getSize(newTopic), const Size(36, 36));
    await settleUi(tester);
    await capture(tester, captureKey, 'workbench-single-item-1920x1080.png');
    await tester.tap(newTopic);
    await until(
      tester,
      () async =>
          (await repository.loadMap(map.id)).nodes.length == 1 &&
          find.byType(CardEditor).evaluate().isNotEmpty,
    );
    expect(
      tester.widget<ReaderPane>(reader).revisionId,
      document.activeRevisionId,
    );
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('工作台精简标题：多 PDF 保留文件标签、多脑图保留当前标题', (tester) async {
    final project = await real(
      tester,
      () => repository.createProject('多项阅读布局'),
    );
    final map = await real(
      tester,
      () => repository.createMap(project.id, '第二脑图'),
    );
    final fixture = File('tools/fixtures/pdf/native.pdf').absolute;
    final geometry = await real(
      tester,
      () => PdfReadEngine.loadSourceGeometry(fixture.path),
    );
    final documents = <model.ManagedDocument>[];
    for (final title in ['第一资料', '第二资料']) {
      final copy = await real(
        tester,
        () => fixture.copy('${temp.path}/$title.pdf'),
      );
      documents.add(
        await real(
          tester,
          () => repository.importPdf(
            projectId: project.id,
            filePath: copy.path,
            pageCount: geometry.length,
            pageGeometry: geometry,
          ),
        ),
      );
    }
    await mount(tester);
    await until(tester, () async => readerReady(tester));
    await idle(tester);
    final header = find.byKey(const Key('workspace-map-header'));
    final selectedMap = tester
        .widget<MindMapPane>(find.byType(MindMapPane))
        .snapshot
        .map;
    expect(
      find.descendant(of: header, matching: find.text(selectedMap.title)),
      findsOneWidget,
    );
    expect(find.byKey(const Key('workspace-document-tabs')), findsOneWidget);
    expect(
      tester.getTopLeft(find.byType(ReaderPane)).dy,
      tester.getTopLeft(header).dy + 40,
    );
    await tester.tap(find.widgetWithText(ListTile, map.title));
    await until(
      tester,
      () async =>
          tester
              .widget<MindMapPane>(find.byType(MindMapPane))
              .snapshot
              .map
              .id ==
          map.id,
    );
    expect(
      find.descendant(of: header, matching: find.text(map.title)),
      findsOneWidget,
    );
    final current = tester
        .widget<ReaderPane>(find.byType(ReaderPane))
        .revisionId;
    final other = documents.firstWhere(
      (document) => document.activeRevisionId != current,
    );
    await tester.tap(find.widgetWithText(ListTile, other.title));
    await until(
      tester,
      () async =>
          readerReady(tester) &&
          tester.widget<ReaderPane>(find.byType(ReaderPane)).revisionId ==
              other.activeRevisionId,
    );
    expect(find.byKey(Key('document-tab-${other.id}')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('文档标签按打开集合关闭重开与鼠标排序，资料和阅读位置保持', (tester) async {
    final project = await real(tester, () => repository.createProject('标签管理'));
    final fixture = File('tools/fixtures/pdf/native.pdf').absolute;
    final geometry = await real(
      tester,
      () => PdfReadEngine.loadSourceGeometry(fixture.path),
    );
    final documents = <model.ManagedDocument>[];
    for (final name in ['甲文档', '乙文档', '丙文档']) {
      final copy = await real(
        tester,
        () => fixture.copy('${temp.path}/$name.pdf'),
      );
      documents.add(
        await real(
          tester,
          () => repository.importPdf(
            projectId: project.id,
            filePath: copy.path,
            pageCount: geometry.length,
            pageGeometry: geometry,
          ),
        ),
      );
    }
    await mount(tester);
    await until(tester, () async => readerReady(tester));
    await idle(tester);
    final initiallyOpened = documents.firstWhere(
      (item) =>
          item.activeRevisionId ==
          tester.widget<ReaderPane>(find.byType(ReaderPane)).revisionId,
    );
    final other = documents.firstWhere((item) => item.id != initiallyOpened.id);
    final unopened = documents.firstWhere(
      (item) => item.id != initiallyOpened.id && item.id != other.id,
    );
    expect(find.byKey(Key('document-tab-${unopened.id}')), findsNothing);
    final history = repository.undoEntryCount;
    await tester.tap(find.widgetWithText(ListTile, other.title));
    await until(
      tester,
      () async =>
          readerReady(tester) &&
          tester.widget<ReaderPane>(find.byType(ReaderPane)).revisionId ==
              other.activeRevisionId,
    );
    await idle(tester);
    expect(
      find.byKey(Key('document-tab-${initiallyOpened.id}')),
      findsOneWidget,
    );
    expect(find.byKey(Key('document-tab-${other.id}')), findsOneWidget);
    expect(find.byKey(Key('document-tab-${unopened.id}')), findsNothing);
    final drag = await tester.startGesture(
      tester.getCenter(
        find.byKey(Key('document-tab-drag-${initiallyOpened.id}')),
      ),
      kind: ui.PointerDeviceKind.mouse,
    );
    await tester.pump();
    // 连续鼠标输入经过相邻标签的插入区，不用单次大跳跃跳过拖动判定。
    for (var frame = 0; frame < 12; frame++) {
      await drag.moveBy(const Offset(20, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      tester.binding.mouseTracker.debugDeviceActiveCursor(1),
      SystemMouseCursors.grabbing,
    );
    await drag.up();
    await settleUi(tester);
    expect(
      tester.binding.mouseTracker.debugDeviceActiveCursor(1),
      isNot(SystemMouseCursors.grabbing),
    );
    expect(
      tester.getTopLeft(find.byKey(Key('document-tab-${other.id}'))).dx,
      lessThan(
        tester
            .getTopLeft(find.byKey(Key('document-tab-${initiallyOpened.id}')))
            .dx,
      ),
    );
    final reader = tester.widget<ReaderPane>(find.byType(ReaderPane));
    await real(tester, () => reader.controller!.goToPage(1));
    await until(
      tester,
      () async =>
          (await repository.loadReadingPosition(other.activeRevisionId))
              ?.pageIndex ==
          1,
    );
    await returnHome(tester);
    final resume = (await real(
      tester,
      () => repository.loadProjectResume(project.id),
    ))!;
    expect(resume.openedDocumentIds, [other.id, initiallyOpened.id]);
    expect(resume.activeDocumentId, other.id);
    await openHomeProject(tester, project.id);
    await until(tester, () async => readerReady(tester));
    expect(
      tester.widget<ReaderPane>(find.byType(ReaderPane)).revisionId,
      other.activeRevisionId,
    );
    expect(
      tester
          .widget<ReaderPane>(find.byType(ReaderPane))
          .initialPosition
          ?.pageIndex,
      1,
    );
    expect(
      tester.getTopLeft(find.byKey(Key('document-tab-${other.id}'))).dx,
      lessThan(
        tester
            .getTopLeft(find.byKey(Key('document-tab-${initiallyOpened.id}')))
            .dx,
      ),
    );
    await tester.tap(find.byKey(Key('document-tab-close-${other.id}')));
    await until(
      tester,
      () async =>
          readerReady(tester) &&
          tester.widget<ReaderPane>(find.byType(ReaderPane)).revisionId ==
              initiallyOpened.activeRevisionId,
    );
    await idle(tester);
    await tester.tap(
      find.byKey(Key('document-tab-close-${initiallyOpened.id}')),
    );
    await until(tester, () async => find.byType(ReaderPane).evaluate().isEmpty);
    expect(
      await real(tester, () => repository.listDocuments(project.id)),
      hasLength(3),
    );
    await idle(tester);
    await tester.tap(find.widgetWithText(ListTile, other.title));
    await until(tester, () async => readerReady(tester));
    expect(
      tester
          .widget<ReaderPane>(find.byType(ReaderPane))
          .initialPosition
          ?.pageIndex,
      1,
    );
    expect(repository.undoEntryCount, history, reason: '标签管理不改变业务撤销历史');
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('真实工作台重命名项目文档脑图并撤销，当前标题同步且引用保持', (tester) async {
    final project = await real(tester, () => repository.createProject('原项目'));
    final fixture = File('tools/fixtures/pdf/native.pdf').absolute;
    final geometry = await real(
      tester,
      () => PdfReadEngine.loadSourceGeometry(fixture.path),
    );
    final document = await real(
      tester,
      () => repository.importPdf(
        projectId: project.id,
        filePath: fixture.path,
        pageCount: geometry.length,
        pageGeometry: geometry,
      ),
    );
    final map = (await real(
      tester,
      () => repository.listMaps(project.id),
    )).single;
    await real(
      tester,
      () => repository.setMapLayout(map.id, model.MapLayoutKind.free),
    );
    await mount(tester);
    await until(tester, () async => readerReady(tester));
    await returnHome(tester);
    await until(
      tester,
      () => Future.value(
        find.byTooltip('管理项目 原项目').hitTestable().evaluate().isNotEmpty,
      ),
    );
    await tester.tap(find.byTooltip('管理项目 原项目'));
    await settleUi(tester);
    await tester.tap(find.text('重命名'));
    await settleUi(tester);
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      '新项目',
    );
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await until(
      tester,
      () async =>
          (await repository.listProjects()).single.title == '新项目' &&
          find.text('新项目').evaluate().isNotEmpty,
    );
    await openHomeProject(tester, project.id);
    expect(find.text('新项目'), findsWidgets);
    await tester.tap(find.byKey(Key('document-menu-${document.id}')));
    await settleUi(tester);
    await tester.tap(find.text('重命名…'));
    await settleUi(tester);
    final input = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    expect(tester.widget<TextField>(input).controller!.text, document.title);
    await tester.enterText(input, '重命名书籍');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await until(
      tester,
      () async =>
          tester.widget<ReaderPane>(find.byType(ReaderPane)).title == '重命名书籍',
    );
    expect(
      find.descendant(
        of: find.byType(WorkspaceLibrary),
        matching: find.text('重命名书籍'),
      ),
      findsOneWidget,
    );
    await idle(tester);
    await tester.tap(find.byKey(Key('map-menu-${map.id}')));
    await settleUi(tester);
    await tester.tap(find.text('重命名…'));
    await settleUi(tester);
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      '新脑图',
    );
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await until(
      tester,
      () async =>
          tester
              .widget<MindMapPane>(find.byType(MindMapPane))
              .snapshot
              .map
              .title ==
          '新脑图',
    );
    await idle(tester);
    await tester.tap(find.byTooltip('撤销 Ctrl+Z'));
    await until(
      tester,
      () async =>
          tester
              .widget<MindMapPane>(find.byType(MindMapPane))
              .snapshot
              .map
              .title ==
          map.title,
    );
    await idle(tester);
    await tester.tap(find.byTooltip('撤销 Ctrl+Z'));
    await until(
      tester,
      () async =>
          tester.widget<ReaderPane>(find.byType(ReaderPane)).title ==
          document.title,
    );
    expect(
      (await real(
        tester,
        () => repository.listDocuments(project.id),
      )).single.id,
      document.id,
    );
    expect(
      (await real(
        tester,
        () => repository.getRevision(document.activeRevisionId),
      )).id,
      document.activeRevisionId,
    );
    final filter = find.byKey(const Key('workspace-library-filter'));
    await tester.tap(find.byTooltip('筛选资料'));
    await tester.pump();
    await tester.enterText(filter, '没有此项');
    await tester.pump();
    expect(find.widgetWithText(ListTile, document.title), findsNothing);
    expect(find.widgetWithText(ListTile, map.title), findsNothing);
    expect(find.text('没有匹配的文档'), findsOneWidget);
    await tester.tap(find.byTooltip('清除搜索'));
    await tester.pump();
    expect(find.widgetWithText(ListTile, document.title), findsOneWidget);
    expect(find.widgetWithText(ListTile, map.title), findsOneWidget);
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('真实扫描PDF：返回首页继续OCR，重新进入后选文与搜索回源', (tester) async {
    final project = await real(tester, () => repository.createProject('扫描书'));
    await mount(tester);
    selector.importPaths = [
      File('test/ocr/fixtures/scanned_rotated.pdf').absolute.path,
    ];
    await idle(tester);
    await tester.tap(find.byTooltip('添加文档'));
    await until(
      tester,
      () async => (await repository.listDocuments(project.id)).length == 1,
    );
    final document = (await real(
      tester,
      () => repository.listDocuments(project.id),
    )).single;
    await returnHome(tester);
    await until(
      tester,
      () async =>
          (await repository.loadTextLayers(document.activeRevisionId))
              .where((l) => l.source == model.TextLayerSource.ocr)
              .length ==
          4,
      attempts: 1000,
    );
    final layers = (await real(
      tester,
      () => repository.loadTextLayers(document.activeRevisionId),
    ));
    final layer = layers.singleWhere((layer) => layer.pageIndex == 0);
    expect(layer.text, contains('知识整理'));
    expect(layer.text, contains('OpenNote'));
    expect(find.byType(Workbench), findsNothing);
    await openHomeProject(tester, project.id);
    await until(tester, () async => readerReady(tester));
    await idle(tester);
    await selectText(tester, repository, document, layer, '知识整理');
    await tester.tap(excerptButton());
    await until(
      tester,
      () async => (await repository.listCards(project.id)).length == 1,
    );
    final card = (await real(
      tester,
      () => repository.listCards(project.id),
    )).single;
    expect(card.excerptSnapshot, '知识整理');
    expect(
      (await real(
        tester,
        () => repository.getAnchors(card.id),
      )).single.textLayerId,
      layer.id,
    );
    await idle(tester);
    await tester.tap(find.byTooltip('搜索 Ctrl+F'));
    await settleUi(tester);
    await tester.enterText(find.byKey(const Key('search-input')), '知');
    await tester.pump(const Duration(milliseconds: 200));
    await until(
      tester,
      () async =>
          find.byKey(const Key('search-result-0')).evaluate().isNotEmpty &&
          find.byType(LinearProgressIndicator).evaluate().isEmpty,
    );
    // 列表按需构建，数据库结果数与滚动后的第四页分别验证。
    expect(
      await real(tester, () => repository.search(project.id, '知')),
      hasLength(5),
    );
    await tester.scrollUntilVisible(
      find.text('原文 · 第 4 页'),
      180,
      scrollable: find.descendant(
        of: find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(ListView),
        ),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.tap(
      find.ancestor(
        of: find.text('原文 · 第 4 页'),
        matching: find.byType(ListTile),
      ),
    );
    await until(
      tester,
      () async =>
          readerReady(tester) &&
          tester
                  .widget<PdfViewer>(find.byType(PdfViewer))
                  .controller!
                  .pageNumber ==
              4,
    );
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });
}

bool readerReady(WidgetTester tester) {
  final found = find.byType(PdfViewer).evaluate();
  return found.length == 1 &&
      tester.widget<PdfViewer>(find.byType(PdfViewer)).controller?.isReady ==
          true;
}

Future<void> switchMapView(WidgetTester tester, {required bool outline}) async {
  final selector = find.byKey(const Key('map-view-switch'));
  if (tester.widget(selector) is! PopupMenuButton<bool>) {
    final button = find
        .descendant(of: selector, matching: find.byType(TextButton))
        .at(outline ? 1 : 0)
        .hitTestable();
    await until(tester, () => Future.value(button.evaluate().length == 1));
    await tester.tap(button);
  } else {
    await tester.tap(selector);
    await tester.pump();
    final item = find
        .widgetWithText(PopupMenuItem<bool>, outline ? '大纲' : '画布')
        .hitTestable();
    await until(tester, () async => item.evaluate().length == 1);
    await tester.tap(item);
  }
  await tester.pump();
  await until(
    tester,
    () async => outline
        ? find.byType(MapOutlinePane).evaluate().isNotEmpty
        : find.byType(MindMapPane).evaluate().isNotEmpty,
  );
}

Future<void> ctrlClickNode(
  WidgetTester tester,
  String nodeId, {
  required Set<String> expected,
  required String? primary,
  bool outline = false,
  bool releaseBeforeUp = false,
}) async {
  await idle(tester);
  if (!outline) {
    tester
        .widget<MindMapPane>(find.byType(MindMapPane))
        .controller!
        .centerOnNode(nodeId);
    await advance(tester);
    await tester.pump();
  }
  final finder = find.byKey(Key('${outline ? 'outline' : 'map'}-node-$nodeId'));
  await until(tester, () async => finder.evaluate().isNotEmpty);
  final pane = outline ? find.byType(MapOutlinePane) : find.byType(MindMapPane);
  final point = tester.getCenter(finder);
  expect(tester.getRect(pane).contains(point), isTrue);
  expect(
    tester
        .hitTestOnBinding(point)
        .path
        .any((entry) => identical(entry.target, tester.renderObject(finder))),
    isTrue,
  );
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  final gesture = await tester.startGesture(
    point,
    kind: ui.PointerDeviceKind.mouse,
  );
  var released = false;
  try {
    await tester.pump();
    if (releaseBeforeUp) {
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    }
    await gesture.up();
    released = true;
    if (!releaseBeforeUp) {
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    }
    await until(tester, () async {
      final values = outline
          ? tester.widget<MapOutlinePane>(pane).selectedNodeIds
          : tester.widget<MindMapPane>(pane).selectedNodeIds;
      final currentPrimary = outline
          ? tester.widget<MapOutlinePane>(pane).selectedNodeId
          : tester.widget<MindMapPane>(pane).selectedNodeId;
      return setEquals(values, expected) && currentPrimary == primary;
    });
    await idle(tester);
  } finally {
    if (!released) await gesture.cancel();
    if (HardwareKeyboard.instance.isControlPressed) {
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    }
  }
}

Future<void> selectedMenuAction(WidgetTester tester, String label) async {
  await idle(tester);
  final menu = find.byKey(const Key('workspace-selected-menu'));
  final header = find.byKey(const Key('workspace-map-header'));
  expect(tester.getRect(header).contains(tester.getCenter(menu)), isTrue);
  await tester.tap(menu, kind: ui.PointerDeviceKind.mouse);
  await tester.pump();
  final item = find.widgetWithText(PopupMenuItem<String>, label).hitTestable();
  await until(tester, () async => item.evaluate().length == 1);
  await tester.tap(item, kind: ui.PointerDeviceKind.mouse);
  await tester.pump();
}

Future<void> clickOutlineNode(WidgetTester tester, String nodeId) async {
  final row = find.byKey(Key('outline-node-$nodeId'));
  await until(tester, () async => row.evaluate().isNotEmpty);
  final point = tester.getCenter(row);
  expect(tester.getRect(find.byType(MapOutlinePane)).contains(point), isTrue);
  expect(
    tester
        .hitTestOnBinding(point)
        .path
        .any((entry) => identical(entry.target, tester.renderObject(row))),
    isTrue,
  );
  await tester.tap(row, kind: ui.PointerDeviceKind.mouse);
  await until(
    tester,
    () async =>
        tester
            .widget<MapOutlinePane>(find.byType(MapOutlinePane))
            .selectedNodeId ==
        nodeId,
  );
  await idle(tester);
}

Future<void> clickMapNode(WidgetTester tester, String nodeId) async {
  await until(
    tester,
    () async =>
        find.byType(MindMapPane).evaluate().isNotEmpty &&
        tester
            .widget<MindMapPane>(find.byType(MindMapPane))
            .snapshot
            .nodes
            .any((node) => node.id == nodeId),
  );
  await idle(tester);
  tester
      .widget<MindMapPane>(find.byType(MindMapPane))
      .controller!
      .centerOnNode(nodeId);
  await advance(tester);
  await tester.pump();
  final node = find.byKey(Key('map-node-$nodeId'));
  final center = tester.getCenter(node);
  expect(tester.getRect(find.byType(MindMapPane)).contains(center), isTrue);
  expect(
    tester
        .hitTestOnBinding(center)
        .path
        .any((entry) => identical(entry.target, tester.renderObject(node))),
    isTrue,
  );
  await tester.tap(node, kind: ui.PointerDeviceKind.mouse);
  await until(
    tester,
    () async =>
        tester.widget<MindMapPane>(find.byType(MindMapPane)).selectedNodeId ==
        nodeId,
  );
  await idle(tester);
}

Future<void> completedMapMouseClick(
  WidgetTester tester,
  String nodeId,
  Duration timeStamp,
) async {
  final node = find.byKey(Key('map-node-$nodeId'));
  final point = tester.getCenter(node);
  expect(tester.getRect(find.byType(MindMapPane)).contains(point), isTrue);
  expect(
    tester
        .hitTestOnBinding(point)
        .path
        .any((entry) => identical(entry.target, tester.renderObject(node))),
    isTrue,
    reason: '真实鼠标必须命中卡片，不能命中悬浮工具条',
  );
  final gesture = await tester.createGesture(kind: ui.PointerDeviceKind.mouse);
  await gesture.down(point, timeStamp: timeStamp);
  await tester.pump();
  await gesture.up(timeStamp: timeStamp + const Duration(milliseconds: 10));
  await tester.pump();
}

Future<void> advance(
  WidgetTester tester, {
  int milliseconds = 30,
  Duration pumpDuration = const Duration(milliseconds: 16),
}) async {
  await tester.runAsync(
    () => Future<void>.delayed(Duration(milliseconds: milliseconds)),
  );
  await tester.pump(pumpDuration);
}

Future<void> until(
  WidgetTester tester,
  Future<bool> Function() condition, {
  int attempts = 300,
}) async {
  for (var index = 0; index < attempts; index++) {
    if (await real(tester, condition) == true) return;
    await advance(tester);
  }
  debugPrint(
    tester
        .widgetList<Text>(find.byType(Text))
        .map((widget) => widget.data)
        .whereType<String>()
        .join(' | '),
  );
  expect(await real(tester, condition), isTrue, reason: '真实异步流程未在限定等待内到达目标状态');
}

Future<T> real<T>(WidgetTester tester, Future<T> Function() action) async {
  var done = false;
  late T value;
  Object? failure;
  StackTrace? trace;
  await tester.runAsync(() async {
    action().then(
      (result) {
        value = result;
        done = true;
      },
      onError: (Object error, StackTrace stack) {
        failure = error;
        trace = stack;
        done = true;
      },
    );
  });
  final waiting = Stopwatch()..start();
  // 按真实时间限定等待；长书有上千次 I/O，不能把一次帧轮询当作一次业务操作。
  while (!done && waiting.elapsed < const Duration(seconds: 60)) {
    await advance(tester, milliseconds: 5);
  }
  if (failure != null) Error.throwWithStackTrace(failure!, trace!);
  if (!done) throw StateError('资料库异步任务未完成，真实等待 ${waiting.elapsed}');
  return value;
}

Future<void> ctrl(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
}

Future<void> settleUi(WidgetTester tester) async {
  // 等待有限的路由动画，同时允许实际数据库、PDF 和 OCR I/O 推进。
  for (var index = 0; index < 25; index++) {
    await advance(tester);
  }
}

Future<void> capture(
  WidgetTester tester,
  GlobalKey key,
  String name, {
  double pixelRatio = 1,
}) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await real(
    tester,
    () => boundary.toImage(pixelRatio: pixelRatio),
  );
  try {
    final png = (await real(
      tester,
      () => image.toByteData(format: ui.ImageByteFormat.png),
    ))!;
    await real(tester, () async {
      final directory = await Directory('.local/verification')
          .create(recursive: true);
      await File('${directory.path}/$name')
          .writeAsBytes(png.buffer.asUint8List());
    });
  } finally {
    image.dispose();
  }
}

Future<void> idle(WidgetTester tester) async {
  // 先把刚接受命令的忙碌状态绘制出来，不能用上一帧按钮状态判定已经完成。
  await tester.pump();
  await until(tester, () async {
    final icon = find.byWidgetPredicate(
      (widget) => widget is IconButton && widget.tooltip == '搜索 Ctrl+F',
    );
    return tester.widget<IconButton>(icon).onPressed != null;
  });
}

Future<void> menu(WidgetTester tester, String label) async {
  final home = find.byType(Workbench).evaluate().isEmpty;
  if (!home) await idle(tester);
  await tester.tap(find.byTooltip(home ? '资料库设置' : '资料库操作'));
  await settleUi(tester);
  await tester.tap(find.text(!home && label == '回收站' ? '当前项目回收站' : label));
  await tester.pump();
}

Future<void> returnHome(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('return-project-home')));
  await until(tester, () async => find.byType(Workbench).evaluate().isEmpty);
  await settleUi(tester);
  await until(
    tester,
    () async =>
        find.byKey(const Key('home-new-project')).evaluate().isNotEmpty &&
        find.byType(LinearProgressIndicator).evaluate().isEmpty,
  );
}

/// 只替换队列显示与用户命令；本组验证识别入口，不执行原生 OCR。
class _UiOcrQueue extends OcrQueueController {
  _UiOcrQueue(super.repository);
  bool busy = false;
  int failedPages = 0;
  int cancelledPages = 0;
  int completedPages = 1;
  String? requested, retried;
  String? cancelledRevision;
  model.OcrTaskStatus? retriedStatus;
  bool cancelled = false;
  @override
  bool get isBusy => busy;
  @override
  int get completedCount => 1;
  @override
  int get totalCount => 2;
  @override
  double get progress => .5;
  @override
  OcrDocumentStatus statusForRevision(String revisionId, {int pageCount = 0}) =>
      revisionId != requested
      ? OcrDocumentStatus(totalPages: pageCount, completedPages: 0)
      : OcrDocumentStatus(
          totalPages: 2,
          completedPages: completedPages,
          pendingPages: busy ? 1 : 0,
          failedPages: failedPages,
          cancelledPages: cancelledPages,
          error: lastError,
        );
  @override
  Future<void> enqueueRevision(
    String revisionId, {
    int? priorityPage,
    bool retryIncomplete = true,
  }) async {
    requested = revisionId;
  }

  @override
  Future<void> retryRevision(
    String revisionId, {
    model.OcrTaskStatus? status,
  }) async {
    retried = revisionId;
    retriedStatus = status;
    if (status == model.OcrTaskStatus.failed) failedPages = 0;
    if (status == model.OcrTaskStatus.cancelled) cancelledPages = 0;
    publish(busy: true);
  }

  @override
  Future<void> cancel({String? revisionId}) async {
    cancelled = true;
    cancelledRevision = revisionId;
    cancelledPages = 1;
    publish(busy: false);
  }

  void publish({required bool busy, String? error}) {
    this.busy = busy;
    lastError = error;
    notifyListeners();
  }

  @override
  Future<void> disposeAsync() {
    // 断言失败也要释放替身模拟的忙碌状态，避免清理阶段永远等候不存在的 OCR 作业。
    busy = false;
    return super.disposeAsync();
  }
}

Finder excerptButton() => find.byWidgetPredicate(
  (widget) =>
      widget is IconButton && (widget.tooltip?.startsWith('摘录到') ?? false),
);

Future<void> openProjectSearch(WidgetTester tester) async {
  if (find.byKey(const Key('project-search')).evaluate().isEmpty) {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(find.byKey(const Key('project-search')), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('project-search')))
          .focusNode!
          .hasFocus,
      isTrue,
    );
  }
}

Future<void> openHomeProject(WidgetTester tester, String projectId) async {
  final card = find.byKey(Key('project-card-$projectId'));
  await until(
    tester,
    () async =>
        card.evaluate().isNotEmpty &&
        tester.widget<InkWell>(card).onTap != null,
  );
  await tester.tap(card);
  await until(tester, () async => find.byType(Workbench).evaluate().isNotEmpty);
  await settleUi(tester);
}

Offset quadPosition(
  WidgetTester tester,
  model.ManagedDocument document,
  model.PdfQuad quad,
  model.DocumentRevision revision, {
  int pageIndex = 0,
}) {
  final viewer = tester.widget<PdfViewer>(find.byType(PdfViewer)).controller!;
  final adapter = PdfCoordinateAdapter(revision.pageGeometry[pageIndex]);
  final center = adapter
      .quadInDocument(
        quad,
        viewer.pages[pageIndex],
        viewer.layout.pageLayouts[pageIndex],
      )
      .getBounds()
      .center;
  return tester.getTopLeft(find.byType(PdfViewer)) +
      viewer.documentToLocal(center);
}

Future<void> selectText(
  WidgetTester tester,
  OpenNoteRepository repository,
  model.ManagedDocument document,
  model.PageTextLayer layer,
  String text,
) async {
  final pane = tester.widget<ReaderPane>(find.byType(ReaderPane));
  await real(tester, () => pane.controller!.goToPage(layer.pageIndex));
  await advance(tester);
  final revision = (await real(
    tester,
    () => repository.getRevision(document.activeRevisionId),
  ));
  final start = layer.text.indexOf(text);
  expect(start, greaterThanOrEqualTo(0));
  final first = layer.fragments.firstWhere(
    (fragment) =>
        fragment.start <= start && fragment.start + fragment.length > start,
  );
  final last = layer.fragments.firstWhere(
    (fragment) =>
        fragment.start <= start + text.length - 1 &&
        fragment.start + fragment.length > start + text.length - 1,
  );
  final gesture = await tester.startGesture(
    quadPosition(
      tester,
      document,
      first.quad,
      revision,
      pageIndex: layer.pageIndex,
    ),
    kind: ui.PointerDeviceKind.mouse,
  );
  await gesture.moveTo(
    quadPosition(
      tester,
      document,
      last.quad,
      revision,
      pageIndex: layer.pageIndex,
    ),
  );
  await tester.pump();
  await gesture.up();
  await tester.pump();
}
