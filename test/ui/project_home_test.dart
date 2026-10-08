import '../support/flutter_sdk.dart';

import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:ui' show SemanticsAction;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opennote/data/open_note_repository.dart';
import 'package:opennote/domain/models.dart';
import 'package:opennote/main.dart';
import 'package:opennote/ui/home/project_cover.dart';
import 'package:opennote/ui/home/project_home.dart';
import 'package:opennote/ui/theme/open_note_theme.dart';
import 'package:opennote/ui/workspace/workbench.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../workspace/workbench_test.dart' as actions;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late OpenNoteRepository repo;
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
    await (FontLoader('Segoe UI')..addFont(
          File('C:/Windows/Fonts/segoeui.ttf')
              .readAsBytes()
              .then(ByteData.sublistView),
        ))
        .load();
  });
  setUp(() async {
    repositoryClosed = false;
    temp = await Directory.systemTemp.createTemp('opennote-home-ui-');
    repo = await OpenNoteRepository.open(rootPath: temp.path);
  });
  tearDown(() async {
    if (!repositoryClosed) await repo.close();
    await temp.delete(recursive: true);
  });
  Future<void> mount(WidgetTester tester, {double width = 1280}) async {
    await tester.binding.setSurfaceSize(Size(width, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await actions.settleUi(tester);
      if (!repositoryClosed) await actions.real(tester, repo.close);
      repositoryClosed = true;
    });
    await tester.pumpWidget(
      RepaintBoundary(
        key: captureKey,
        child: OpenNoteApp(startup: Future.value(repo)),
      ),
    );
    await actions.until(
      tester,
      () async =>
          find.byKey(const Key('home-new-project')).evaluate().isNotEmpty,
    );
    await actions.settleUi(tester);
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await actions.settleUi(tester);
  }

  testWidgets('首页分类入口：回收站收进菜单，忙碌和失败不显示蓝条且内容稳定', (tester) async {
    addTearDown(() async {
      await unmount(tester);
      if (!repositoryClosed) await actions.real(tester, repo.close);
      repositoryClosed = true;
    });
    final project = await actions.real(
      tester,
      () => repo.createProject('安静的项目首页'),
    );
    for (final width in [1280.0, 640.0]) {
      await tester.binding.setSurfaceSize(Size(width, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final pending = Completer<void>(), failure = Completer<void>();
      final invoked = <String>[];
      final covers = ProjectCoverCache('${temp.path}/covers-${width.toInt()}');
      try {
        await tester.pumpWidget(
          RepaintBoundary(
            key: captureKey,
            child: MaterialApp(
              theme: openNoteTheme(),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(1.25)),
                child: child!,
              ),
              home: ProjectHome(
                repository: repo,
                covers: covers,
                onOpenProject: (_) async {},
                onLibraryAction: (action) async {
                  invoked.add(action);
                  await (action == 'trash' ? pending.future : failure.future);
                },
              ),
            ),
          ),
        );
        await actions.until(
          tester,
          () async => find
              .byKey(Key('project-card-${project.id}'))
              .evaluate()
              .isNotEmpty,
        );
        await actions.settleUi(tester);
        expect(find.byTooltip('回收站'), findsNothing);
        expect(find.text('回收站'), findsNothing, reason: '首页没有独立常驻入口');
        expect(find.byType(LinearProgressIndicator), findsNothing);
        final card = find.byKey(Key('project-card-${project.id}'));
        final original = tester.getRect(card);
        if (width < 760) {
          await tester.tap(find.byTooltip('项目文件夹'));
          await actions.settleUi(tester);
        }
        final more = find.byTooltip('资料库设置');
        final hitArea = tester.getSize(more);
        expect(hitArea.width, greaterThanOrEqualTo(36));
        expect(hitArea.height, greaterThanOrEqualTo(36));
        await tester.tap(more);
        await actions.settleUi(tester);
        final trash = find.text('回收站');
        expect(trash, findsOneWidget);
        expect(find.text('完整备份…'), findsOneWidget);
        expect(find.text('恢复整个资料库…'), findsOneWidget);
        if (width == 1280) {
          await actions.capture(
            tester,
            captureKey,
            'home-quiet-20261006/home-menu-1280.png',
          );
        }
        Focus.of(tester.element(trash)).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await actions.until(tester, () async => invoked.isNotEmpty);
        await tester.pump();
        expect(invoked, ['trash'], reason: '菜单键盘操作仍可进入回收站');
        expect(find.byType(LinearProgressIndicator), findsNothing);
        expect(tester.getRect(card), original, reason: '等待操作不会挤动项目内容');
        expect(
          tester
              .widget<IconButton>(find.byKey(const Key('home-new-project')))
              .onPressed,
          isNull,
        );
        pending.complete();
        await actions.until(
          tester,
          () async => tester
              .widget<PopupMenuButton<String>>(
                find.byType(PopupMenuButton<String>).last,
              )
              .enabled,
        );
        await actions.settleUi(tester);
        await tester.tap(more);
        await actions.settleUi(tester);
        await tester.tap(find.text('完整备份…'));
        await actions.until(tester, () async => invoked.length == 2);
        failure.completeError(StateError('演示备份失败'));
        await actions.until(
          tester,
          () async => find.textContaining('演示备份失败').evaluate().isNotEmpty,
        );
        expect(find.text('重试'), findsOneWidget, reason: '错误反馈仍清楚并可重试');
        expect(find.byType(LinearProgressIndicator), findsNothing);
        expect(
          (await actions.real(tester, repo.listProjects)).single.id,
          project.id,
        );
        expect(tester.takeException(), isNull);
      } finally {
        if (!pending.isCompleted) pending.complete();
        if (!failure.isCompleted) failure.complete();
        await unmount(tester);
        covers.dispose();
      }
    }
  });

  testWidgets('首页紧凑工具栏：搜索跨窄屏保留草稿焦点，排序与清空可用', (tester) async {
    await actions.real(tester, () => repo.createProject('阅读排版'));
    await actions.real(tester, () => repo.createProject('其他项目'));
    await mount(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    final search = find.byKey(const Key('project-search'));
    final field = tester.widget<TextField>(search);
    await tester.enterText(search, '阅读');
    await tester.pump(const Duration(milliseconds: 200));
    await actions.until(
      tester,
      () async => find.text('其他项目').evaluate().isEmpty,
    );
    tester.binding.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(
      tester.binding.platformDispatcher.clearTextScaleFactorTestValue,
    );
    for (final width in [640.0, 480.0, 1280.0]) {
      await tester.binding.setSurfaceSize(Size(width, 800));
      await actions.settleUi(tester);
      final current = tester.widget<TextField>(search);
      expect(current.controller, same(field.controller));
      expect(current.focusNode!.hasFocus, isTrue);
      expect(current.controller!.text, '阅读');
      expect(
        find.byKey(const Key('home-new-project')).hitTestable(),
        findsOneWidget,
      );
      expect(find.byTooltip('排序：最近打开').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    await tester.tap(find.byTooltip('排序：最近打开'));
    await actions.settleUi(tester);
    await tester.tap(
      find.ancestor(
        of: find.text('项目名称'),
        matching: find.byType(CheckedPopupMenuItem<ProjectSort>),
      ),
    );
    await actions.settleUi(tester);
    expect(find.byTooltip('排序：项目名称'), findsOneWidget);
    expect(tester.widget<TextField>(search).controller!.text, '阅读');
    await tester.tap(find.byTooltip('清除搜索'));
    await tester.pump(const Duration(milliseconds: 200));
    await actions.until(
      tester,
      () async => find.text('其他项目').evaluate().isNotEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('项目封面加载后仍是可打开的按钮，管理菜单独立响应', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      final project = await actions.real(
        tester,
        () => repo.createProject('封面项目'),
      );
      await actions.real(
        tester,
        () => repo.importPdf(
          projectId: project.id,
          filePath: File('tools/fixtures/pdf/native.pdf').absolute.path,
          pageCount: 2,
        ),
      );
      final covers = ProjectCoverCache(
        '${temp.path}/semantics-covers',
        renderer: (_, _) async => base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=',
        ),
      );
      addTearDown(covers.dispose);
      var opened = 0;
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: ProjectHome(
            repository: repo,
            covers: covers,
            onOpenProject: (id) async {
              expect(id, project.id);
              opened++;
            },
            onLibraryAction: (_) async {},
          ),
        ),
      );
      await actions.until(
        tester,
        () async => find.byType(Image).evaluate().isNotEmpty,
      );
      await actions.settleUi(tester);
      final card = find.byKey(Key('project-card-${project.id}'));
      final node = tester.getSemantics(card);
      expect(
        node,
        isSemantics(
          identifier: 'project-card-${project.id}',
          isButton: true,
          isImage: false,
          isEnabled: true,
          hasTapAction: true,
        ),
      );
      node.owner!.performAction(node.id, SemanticsAction.tap);
      await actions.until(tester, () async => opened == 1);
      await actions.settleUi(tester);
      await tester.tap(find.byTooltip('管理项目 封面项目'));
      await actions.settleUi(tester);
      expect(find.text('重命名'), findsOneWidget);
      expect(opened, 1);
      await unmount(tester);
      await actions.real(tester, repo.close);
      repositoryClosed = true;
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('只有一个项目也先显示首页，草稿失败不离开，成功返回后可继续编辑', (tester) async {
    final project = await actions.real(
      tester,
      () => repo.createProject('阅读项目'),
    );
    final map = (await actions.real(
      tester,
      () => repo.listMaps(project.id),
    )).single;
    final card = await actions.real(
      tester,
      () => repo.createExcerpt(
        ExcerptDraft(
          projectId: project.id,
          mapId: map.id,
          text: '正文',
          title: '知识卡片',
          anchors: const [],
          x: 80,
          y: 80,
        ),
      ),
    );
    await mount(tester);
    expect(find.byType(Workbench), findsNothing);
    await tester.tap(find.byKey(Key('project-card-${project.id}')));
    await tester.tap(find.byKey(Key('project-card-${project.id}')));
    await actions.until(
      tester,
      () async =>
          find.byKey(Key('map-node-${card.node.id}')).evaluate().isNotEmpty,
    );
    expect(find.byTooltip('新建学习项目'), findsNothing);
    expect(find.byType(DropdownButton<String>), findsNothing);
    await actions.clickMapNode(tester, card.node.id);
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await actions.until(
      tester,
      () async => find.byKey(const Key('card-body')).evaluate().isNotEmpty,
    );
    final db = sqlite.sqlite3.open('${repo.libraryPath}/library.sqlite');
    db.execute(
      "CREATE TRIGGER deny_home_save BEFORE UPDATE ON cards BEGIN SELECT RAISE(ABORT,'拒绝保存'); END",
    );
    await tester.enterText(find.byKey(const Key('card-body')), '返回首页前的中文草稿');
    await tester.tap(find.byKey(const Key('return-project-home')));
    await actions.until(
      tester,
      () async => find.textContaining('拒绝保存').evaluate().isNotEmpty,
    );
    expect(find.byType(Workbench), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('card-body')))
          .controller!
          .text,
      '返回首页前的中文草稿',
    );
    db.execute('DROP TRIGGER deny_home_save');
    db.close();
    await tester.tap(find.byKey(const Key('return-project-home')));
    await actions.until(
      tester,
      () async => find.byType(Workbench).evaluate().isEmpty,
    );
    expect(
      (await actions.real(tester, () => repo.getCard(card.card.id))).body,
      '返回首页前的中文草稿',
    );
    await actions.until(
      tester,
      () async =>
          find.byKey(Key('project-card-${project.id}')).evaluate().isNotEmpty,
    );
    await tester.tap(find.byKey(Key('project-card-${project.id}')));
    await actions.until(
      tester,
      () async =>
          find.byKey(Key('map-node-${card.node.id}')).evaluate().isNotEmpty,
    );
    await actions.clickMapNode(tester, card.node.id);
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await actions.until(
      tester,
      () async => find.byKey(const Key('card-body')).evaluate().isNotEmpty,
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('card-body')))
          .controller!
          .text,
      '返回首页前的中文草稿',
    );
    await tester.tap(find.byKey(const Key('return-project-home')));
    await actions.until(
      tester,
      () async => find.byType(Workbench).evaluate().isEmpty,
    );
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('分类和全局搜索保留滚动位置，5000项目只构建可见卡片', (tester) async {
    final folder = await actions.real(
      tester,
      () => repo.createProjectFolder('研究'),
    );
    final db = sqlite.sqlite3.open('${repo.libraryPath}/library.sqlite');
    db.execute('BEGIN');
    for (var i = 0; i < 5000; i++) {
      db.execute('INSERT INTO projects VALUES(?,?,?,NULL)', [
        'p$i',
        '项目 ${i.toString().padLeft(4, '0')}',
        i,
      ]);
      if (i < 80) {
        db.execute('INSERT INTO project_memberships VALUES(?,?)', [
          'p$i',
          folder,
        ]);
      }
    }
    db.execute('COMMIT');
    db.close();
    await mount(tester, width: 900);
    expect(
      find
          .byWidgetPredicate(
            (w) =>
                w.key is ValueKey<String> &&
                (w.key as ValueKey<String>).value.startsWith('project-card-'),
          )
          .evaluate()
          .length,
      lessThan(30),
    );
    await tester.tap(find.byKey(Key('project-folder-$folder')));
    await actions.until(
      tester,
      () async =>
          find.byKey(const Key('project-results-80')).evaluate().isNotEmpty,
    );
    final scrollable = find.descendant(
      of: find.byKey(const Key('project-grid-scroll')),
      matching: find.byType(Scrollable),
    );
    await tester.drag(scrollable, const Offset(0, -500));
    await tester.pumpAndSettle();
    final offset = tester.state<ScrollableState>(scrollable).position.pixels;
    expect(offset, greaterThan(100));
    await actions.openProjectSearch(tester);
    await tester.enterText(find.byKey(const Key('project-search')), '项目 4999');
    await tester.pump(const Duration(milliseconds: 220));
    await actions.until(
      tester,
      () async =>
          find.byKey(const Key('project-results-1')).evaluate().isNotEmpty,
    );
    expect(find.byKey(const Key('project-card-p4999')), findsOneWidget);
    await actions.openProjectSearch(tester);
    await tester.enterText(find.byKey(const Key('project-search')), '');
    await tester.pump(const Duration(milliseconds: 220));
    await actions.until(
      tester,
      () async =>
          find.byKey(const Key('project-results-80')).evaluate().isNotEmpty,
    );
    await tester.pump();
    expect(
      tester.state<ScrollableState>(scrollable).position.pixels,
      closeTo(offset, 1),
    );
    await actions.openProjectSearch(tester);
    await tester.enterText(find.byKey(const Key('project-search')), '尚未提交的搜索');
    await tester.tap(find.byKey(const Key('project-folder-all')));
    await tester.pump(const Duration(milliseconds: 220));
    await actions.until(
      tester,
      () async =>
          find.byKey(const Key('project-results-5000')).evaluate().isNotEmpty,
    );
    expect(
      tester
          .widget<TextField>(
            find.byKey(const Key('project-search'), skipOffstage: false),
          )
          .controller!
          .text,
      isEmpty,
    );
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('首页分类内创建、菜单改名移动、删除文件夹与项目回收恢复', (tester) async {
    final folder = await actions.real(
      tester,
      () => repo.createProjectFolder('课程'),
    );
    final target = await actions.real(
      tester,
      () => repo.createProjectFolder('研究'),
    );
    await mount(tester, width: 900);
    await tester.tap(find.byKey(Key('project-folder-$folder')));
    await actions.settleUi(tester);
    await actions.ctrl(tester, LogicalKeyboardKey.keyN);
    await actions.settleUi(tester);
    final input = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(input, '长中文项目名称：从阅读到理解再到知识连接');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '创建'));
    await actions.until(
      tester,
      () async => find.byType(Workbench).evaluate().isNotEmpty,
    );
    final project = (await actions.real(tester, repo.listProjects)).single;
    expect(
      (await actions.real(
        tester,
        () => repo.queryProjectPage(folderId: folder),
      )).total,
      1,
    );
    expect(
      await actions.real(tester, () => repo.listMaps(project.id)),
      hasLength(1),
    );
    await actions.returnHome(tester);
    await tester.tap(find.byTooltip('管理项目 ${project.title}'));
    await actions.settleUi(tester);
    await tester.tap(find.text('重命名'));
    await actions.settleUi(tester);
    await tester.enterText(input, '同名项目');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await actions.until(
      tester,
      () async => find.byTooltip('管理项目 同名项目').evaluate().isNotEmpty,
    );
    expect(find.byType(Workbench), findsNothing, reason: '卡片菜单不得打开项目');
    await actions.settleUi(tester);
    await tester.tap(find.byTooltip('管理项目 同名项目'));
    await actions.settleUi(tester);
    await tester.tap(find.text('移动到文件夹…'));
    await actions.settleUi(tester);
    await tester.tap(
      find.descendant(of: find.byType(SimpleDialog), matching: find.text('研究')),
    );
    await actions.until(
      tester,
      () async => (await repo.queryProjectPage(folderId: target)).total == 1,
    );
    await actions.settleUi(tester);
    await tester.tap(find.byTooltip('管理文件夹 研究'));
    await actions.settleUi(tester);
    await tester.tap(find.text('删除文件夹'));
    await actions.settleUi(tester);
    await tester.tap(find.widgetWithText(FilledButton, '删除文件夹'));
    await actions.until(
      tester,
      () async => (await repo.queryProjectPage(unclassified: true)).total == 1,
    );
    await actions.settleUi(tester);
    await tester.tap(find.byKey(const Key('project-folder-unclassified')));
    await actions.settleUi(tester);
    await tester.tap(find.byTooltip('管理项目 同名项目'));
    await actions.settleUi(tester);
    await tester.tap(find.text('移入回收站'));
    await actions.settleUi(tester);
    expect(find.textContaining('0 份文档、1 张脑图、0 张卡片'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '移入回收站'));
    await actions.until(
      tester,
      () async => (await repo.listProjects()).isEmpty,
    );
    await actions.settleUi(tester);
    await tester.tap(find.byTooltip('资料库设置'));
    await actions.settleUi(tester);
    await tester.tap(find.text('回收站'));
    await actions.until(
      tester,
      () async => find.widgetWithText(TextButton, '恢复').evaluate().isNotEmpty,
    );
    await actions.settleUi(tester);
    expect(
      find.byType(LinearProgressIndicator),
      findsNothing,
      reason: '回收站等待用户选择时，首页背景没有忙碌蓝条',
    );
    await actions.capture(
      tester,
      captureKey,
      'home-quiet-20261006/trash-dialog-900.png',
    );
    await tester.tap(find.widgetWithText(TextButton, '恢复'));
    await actions.until(
      tester,
      () async => find.text('回收站为空').evaluate().isNotEmpty,
    );
    await tester.tap(find.widgetWithText(TextButton, '关闭'));
    await actions.settleUi(tester);
    expect(
      (await actions.real(tester, repo.listProjects)).single.title,
      '同名项目',
    );
    final duplicate = await actions.real(
      tester,
      () => repo.createProject('同名项目'),
    );
    await actions.until(
      tester,
      () async =>
          find.byKey(Key('project-card-${duplicate.id}')).evaluate().isNotEmpty,
    );
    expect(find.text('同名项目'), findsNWidgets(2));
    tester.platformDispatcher.textScaleFactorTestValue = 1.25;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pump();
    expect(tester.takeException(), isNull);
    await actions.ctrl(tester, LogicalKeyboardKey.keyF);
    await tester.pump();
    expect(
      tester
          .widget<TextField>(
            find.byKey(const Key('project-search'), skipOffstage: false),
          )
          .focusNode!
          .hasFocus,
      isTrue,
    );
    final cover = find.descendant(
      of: find.byKey(Key('project-card-${project.id}')),
      matching: find.byType(ProjectCover),
    );
    Focus.of(tester.element(cover)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await actions.until(
      tester,
      () async => find.byType(Workbench).evaluate().isNotEmpty,
    );
    await actions.returnHome(tester);
    await unmount(tester);
  });

  testWidgets('返回与退出竞争等待同一草稿提交，资料库只在退出时关闭', (tester) async {
    final project = await actions.real(
      tester,
      () => repo.createProject('退出竞争'),
    );
    final map = (await actions.real(
      tester,
      () => repo.listMaps(project.id),
    )).single;
    final card = await actions.real(
      tester,
      () => repo.createExcerpt(
        ExcerptDraft(
          projectId: project.id,
          mapId: map.id,
          text: '原正文',
          title: '待编辑',
          anchors: const [],
          x: 80,
          y: 80,
        ),
      ),
    );
    await mount(tester);
    await actions.openHomeProject(tester, project.id);
    await actions.clickMapNode(tester, card.node.id);
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await actions.until(
      tester,
      () async => find.byKey(const Key('card-body')).evaluate().isNotEmpty,
    );
    await tester.enterText(find.byKey(const Key('card-body')), '竞争期间必须保存的正文');
    final db = sqlite.sqlite3.open('${repo.libraryPath}/library.sqlite');
    try {
      db.execute('BEGIN IMMEDIATE');
      await tester.tap(find.byKey(const Key('return-project-home')));
      await tester.pump();
      final exit = tester.binding.handleRequestAppExit();
      await tester.pump();
      expect(find.byType(Workbench), findsOneWidget);
      db.execute('ROLLBACK');
      final response = await actions.real(tester, () => exit);
      expect(response.name, 'exit');
      repositoryClosed = true;
    } finally {
      db.close();
    }
    await unmount(tester);
    final reopened = await actions.real(
      tester,
      () => OpenNoteRepository.open(rootPath: temp.path),
    );
    try {
      expect(
        (await actions.real(tester, () => reopened.getCard(card.card.id))).body,
        '竞争期间必须保存的正文',
      );
      expect(
        await actions.real(
          tester,
          () => reopened.loadProjectResume(project.id),
        ),
        isNotNull,
      );
    } finally {
      await actions.real(tester, reopened.close);
    }
    expect(tester.takeException(), isNull);
  });

  test('封面最多两路并发，离屏排队取消，缓存复用且释放过期结果', () async {
    final started = <String>[];
    final pending = <String, Completer<Uint8List>>{};
    final cache = ProjectCoverCache(
      '${temp.path}/covers',
      renderer: (path, width) {
        started.add(path);
        return (pending[path] = Completer<Uint8List>()).future;
      },
    );
    final a = cache.acquire('a', 'a', 300);
    final b = cache.acquire('b', 'b', 300);
    final c = cache.acquire('c', 'c', 300);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(started, ['a', 'b']);
    expect(cache.activeRenderCount, 2);
    cache.release('c', 300);
    expect(await c, isNull);
    pending['a']!.complete(Uint8List.fromList([1]));
    pending['b']!.complete(Uint8List.fromList([2]));
    expect(await a, [1]);
    expect(await b, [2]);
    cache.release('a', 300);
    cache.release('b', 300);
    expect(await cache.acquire('a', 'a', 300), [1]);
    expect(started, ['a', 'b']);
    cache.dispose();
    final lateResult = Completer<Uint8List>();
    final obsolete = ProjectCoverCache(
      '${temp.path}/old-session',
      renderer: (_, _) => lateResult.future,
    );
    final oldRequest = obsolete.acquire('late', 'late', 300);
    obsolete.dispose();
    lateResult.complete(Uint8List.fromList([3]));
    expect(await oldRequest, isNull);
    expect(await obsolete.acquire('unused', 'unused', 300), isNull);
  });

  test('同一封面渲染失败后可重试，旧请求释放不取消新请求', () async {
    var attempts = 0;
    final cache = ProjectCoverCache(
      '${temp.path}/retry',
      renderer: (_, _) async {
        if (++attempts == 1) throw StateError('渲染失败');
        return Uint8List.fromList([1, 2]);
      },
    );
    final first = cache.acquire('pdf', 'hash', 300);
    final shared = cache.acquire('pdf', 'hash', 300);
    await expectLater(first, throwsStateError);
    await expectLater(shared, throwsStateError);
    final retry = cache.acquire('pdf', 'hash', 300);
    cache.release('hash', 300, request: first);
    cache.release('hash', 300, request: shared);
    expect(await retry, [1, 2]);
    expect(attempts, 2);
    cache.dispose();
  });
}
