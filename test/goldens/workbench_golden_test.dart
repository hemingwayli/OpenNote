import '../support/flutter_sdk.dart';

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opennote/data/open_note_repository.dart';
import 'package:opennote/domain/models.dart' as model;
import 'package:opennote/engines/pdf/pdf_read_engine.dart';
import 'package:opennote/main.dart';
import 'package:opennote/ui/reader/reader_pane.dart';
import 'package:opennote/ui/home/project_cover.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../workspace/workbench_test.dart' as actions;

// 局部编辑器改版只更新对应三张基线；普通运行仍比较全部状态。
final _editorGoldenOnly =
    Platform.environment['OPENNOTE_EDITOR_GOLDENS_ONLY'] == '1';
// 首页视觉改版只更新首页三种状态，避免启动无关工作台回归。
final _homeGoldenOnly =
    Platform.environment['OPENNOTE_HOME_GOLDENS_ONLY'] == '1';

/// 基线只来自真实工作台与原生 PDF；资料库每次重新创建。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Map<String, dynamic> manifest;
  late Directory temporary;
  late OpenNoteRepository repository;
  var repositoryClosed = false;
  final boundaryKey = GlobalKey();

  setUpAll(() async {
    if (!Platform.isWindows) {
      throw StateError('本组基线固定 Windows 字体和原生 PDFium，请在 Windows 执行。');
    }
    manifest = jsonDecode(
      File('test/goldens/baseline-environment.json')
          .readAsStringSync(encoding: utf8),
    ) as Map<String, dynamic>;
    final lock = jsonDecode(
      File('tools/toolchain-lock.json').readAsStringSync(encoding: utf8),
    ) as Map<String, dynamic>;
    expect(lock['flutter']['version'], manifest['flutterVersion']);
    final sdk = flutterSdkPath();
    final fontLoaders = <String, FontLoader>{};
    for (final item in manifest['fonts'] as List) {
      final font = item as Map<String, dynamic>;
      final path = (font['path'] as String).replaceAll('{flutterSdk}', sdk);
      final file = File(path);
      if (!file.existsSync()) throw StateError('缺少基线字体：$path');
      final bytes = await file.readAsBytes();
      expect(
        sha256.convert(bytes).toString(),
        font['sha256'],
        reason: '字体字节须与视觉基线相同',
      );
      final family = font['family'] as String;
      (fontLoaders[family] ??= FontLoader(
        family,
      )).addFont(Future.value(ByteData.sublistView(bytes)));
    }
    for (final loader in fontLoaders.values) {
      await loader.load();
    }
    final pdf = File('tools/fixtures/pdf/ui-reading.pdf');
    expect(
      sha256.convert(await pdf.readAsBytes()).toString(),
      manifest['pdfSha256'],
    );
    Pdfrx.pdfiumModulePath = File('build/windows/x64/runner/Release/pdfium.dll')
        .absolute
        .path;
    await pdfrxInitialize();
  });

  setUp(() async {
    repositoryClosed = false;
    temporary = await Directory.systemTemp.createTemp('opennote-golden-');
    repository = await OpenNoteRepository.open(
      rootPath: '${temporary.path}/library',
    );
  });

  tearDown(() async {
    if (!repositoryClosed) await repository.close();
    await temporary.delete(recursive: true);
  });

  for (final profile in [
    (size: const Size(1920, 1080), dpr: 1.0, label: '1920x1080'),
    (size: const Size(1280, 720), dpr: 1.0, label: '1280x720'),
    (size: const Size(1280, 720), dpr: 1.5, label: '1920x1080-at150'),
  ]) {
    final dpr = profile.dpr;
    testWidgets('真实工作台整页截图 · ${profile.label}', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.view.devicePixelRatio = dpr;
      tester.view.physicalSize = profile.size * dpr;
      final label = profile.label;
      try {
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundaryKey,
            child: OpenNoteApp(startup: Future.value(repository)),
          ),
        );
        await actions.until(
          tester,
          () async =>
              find.byKey(const Key('home-new-project')).evaluate().isNotEmpty,
        );
        await actions.settleUi(tester);
        await _capture(tester, boundaryKey, 'home-empty-$label.png');
        final emptyProject = await actions.real(
          tester,
          () => repository.createProject('新的阅读计划'),
        );
        await actions.openHomeProject(tester, emptyProject.id);
        await _capture(tester, boundaryKey, 'empty-$label.png');
        await tester.pumpWidget(const SizedBox.shrink());
        await actions.settleUi(tester);

        // 从正式仓储 API 写入固定样例，Workbench 收到真实刷新通知。
        final project = await actions.real(
          tester,
          () => repository.createProject('阅读与思考'),
        );
        final folder = await actions.real(
          tester,
          () => repository.createProjectFolder('阅读与研究'),
        );
        await actions.real(
          tester,
          () => repository.moveProjectToFolder(project.id, folder),
        );
        final map = (await actions.real(
          tester,
          () => repository.listMaps(project.id),
        )).single;
        await actions.real(
          tester,
          () => repository.setMapLayout(map.id, model.MapLayoutKind.free),
        );
        await actions.real(
          tester,
          () => repository.renameMap(map.id, '深度阅读 · 概念图'),
        );
        final document = await actions.real(
          tester,
          () => repository.importPdf(
            projectId: project.id,
            filePath: File('tools/fixtures/pdf/ui-reading.pdf').absolute.path,
            pageCount: 2,
          ),
        );
        await actions.real(
          tester,
          () => repository.renameDocument(document.id, '深度阅读与知识连接'),
        );
        // 先用正式引擎提取两页文字，避免截图时队列进度与数据写入造成随机画面。
        final pdf = await actions.real(
          tester,
          () => PdfDocument.openFile(
            File('tools/fixtures/pdf/ui-reading.pdf').absolute.path,
          ),
        );
        try {
          final geometry = await actions.real(
            tester,
            () => PdfReadEngine.loadGeometry(
              pdf,
              filePath: File('tools/fixtures/pdf/ui-reading.pdf').absolute.path,
            ),
          );
          for (var page = 0; page < pdf.pages.length; page++) {
            final text = await actions.real(
              tester,
              () => PdfReadEngine.extractNativeText(
                revisionId: document.activeRevisionId,
                page: pdf.pages[page],
                geometry: geometry[page],
              ),
            );
            await actions.real(
              tester,
              () => repository.saveTextLayer(
                text,
                sessionId: repository.sessionId,
              ),
            );
          }
        } finally {
          await actions.real(tester, pdf.dispose);
        }
        final root = await actions.real(
          tester,
          () => repository.createExcerpt(
            model.ExcerptDraft(
              projectId: project.id,
              mapId: map.id,
              title: '从阅读到理解',
              text: '知识需要通过联系与实践加深理解。\n\n阅读之后，用自己的语言记录核心观点，再把它连接到已有的经验与问题。',
              anchors: const [],
              x: 20,
              y: 230,
            ),
          ),
        );
        await actions.real(
          tester,
          () => repository.updateCard(
            root.card.id,
            note: '原文摘录与个人理解分别保存。\n下次阅读时，先记录问题，再整理联系。',
          ),
        );
        final ideas = [
          ('保留原文上下文', '摘录保留作者的表达，来源帮助我们随时核对细节。', '#B8D2EB'),
          ('用自己的话表达', '把核心观点写成一张独立卡片，让理解变得清晰。', '#C9D9C5'),
          ('建立概念间的联系', '比较两种观点，命名关系，形成可持续扩展的结构。', '#E7D1AC'),
          ('回到原文验证', '带着新的问题重新阅读，在上下文中检查自己的判断。', '#CEC9DF'),
        ];
        for (var i = 0; i < ideas.length; i++) {
          final idea = ideas[i];
          final created = await actions.real(
            tester,
            () => repository.createExcerpt(
              model.ExcerptDraft(
                projectId: project.id,
                mapId: map.id,
                parentNodeId: root.node.id,
                title: idea.$1,
                text: idea.$2,
                anchors: const [],
                x: 300,
                y: 30 + i * 140,
              ),
            ),
          );
          await actions.real(
            tester,
            () => repository.updateCard(created.card.id, color: idea.$3),
          );
        }

        // 重挂载正式应用，让初始项目、文档和脑图走与实际启动相同的路径。
        final dates = sqlite.sqlite3.open(
          '${repository.libraryPath}/library.sqlite',
        );
        dates.execute('UPDATE project_sessions SET last_opened_at = ?', [
          DateTime(2026, 10, 4).millisecondsSinceEpoch,
        ]);
        dates.close();
        for (final title in [
          '设计中的秩序',
          '知识的连接',
          '科学方法与长期思考',
          '信息与系统',
          '写作素材',
          '尚待展开的想法',
        ]) {
          final other = await actions.real(
            tester,
            () => repository.createProject(title, folderId: folder),
          );
          if (['设计中的秩序', '知识的连接', '信息与系统'].contains(title)) {
            await actions.real(
              tester,
              () => repository.importPdf(
                projectId: other.id,
                filePath: File('tools/fixtures/pdf/ui-reading.pdf')
                    .absolute
                    .path,
                pageCount: 2,
              ),
            );
          }
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await actions.settleUi(tester);
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundaryKey,
            child: OpenNoteApp(startup: Future.value(repository)),
          ),
        );
        await actions.until(
          tester,
          () async =>
              find.byKey(Key('project-folder-$folder')).evaluate().isNotEmpty,
        );
        await tester.tap(find.byKey(Key('project-folder-$folder')));
        await actions.until(
          tester,
          () async =>
              find.byKey(const Key('project-results-7')).evaluate().isNotEmpty,
        );
        await actions.until(
          tester,
          () async => find
              .descendant(
                of: find.byType(ProjectCover),
                matching: find.byType(Image),
              )
              .evaluate()
              .isNotEmpty,
        );
        await actions.settleUi(tester);
        await _capture(tester, boundaryKey, 'home-folders-$label.png');
        await actions.openProjectSearch(tester);
        await tester.enterText(find.byKey(const Key('project-search')), '阅读');
        await tester.pump(const Duration(milliseconds: 250));
        await actions.until(
          tester,
          () async =>
              find.text('搜索结果').evaluate().isNotEmpty &&
              find.byKey(const Key('project-results-2')).evaluate().isNotEmpty,
        );
        FocusManager.instance.primaryFocus?.unfocus();
        await actions.settleUi(tester);
        await _capture(tester, boundaryKey, 'home-search-$label.png');
        if (_homeGoldenOnly) return;
        await actions.openHomeProject(tester, project.id);
        await actions.until(tester, () async => actions.readerReady(tester));
        await actions.idle(tester);
        await actions.settleUi(tester);
        final viewer = tester.widget<PdfViewer>(find.byType(PdfViewer));
        expect(viewer.controller!.isReady, isTrue);
        await _capture(tester, boundaryKey, 'canvas-$label.png');

        await actions.clickMapNode(tester, root.node.id);
        // 窄窗口的浮动编辑器会盖住脑图工具，先在可见状态适配画布。
        await tester.tap(find.byTooltip('适合全部卡片'));
        await actions.settleUi(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.f2);
        await actions.until(
          tester,
          () async => find.byKey(const Key('card-body')).evaluate().isNotEmpty,
        );
        await actions.idle(tester);
        // 取消焦点光标，避免系统光标闪烁进入静态截图。
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.tap(find.byTooltip('适合页面宽度'));
        final fitMap = find.byTooltip('适合全部卡片').hitTestable();
        if (fitMap.evaluate().isNotEmpty) {
          // 宽窗口停靠面板改变脑图宽度，按新可见范围再次适配。
          await tester.tap(fitMap);
        }
        await actions.settleUi(tester);
        await _capture(tester, boundaryKey, 'editor-$label.png');
        if (_editorGoldenOnly) return;

        await tester.tap(find.byTooltip('收起编辑'));
        await actions.until(
          tester,
          () async => find.byKey(const Key('card-body')).evaluate().isEmpty,
        );
        await actions.switchMapView(tester, outline: true);
        await actions.idle(tester);
        await actions.settleUi(tester);
        await _capture(tester, boundaryKey, 'outline-$label.png');

        await tester.tap(find.byTooltip('卡片').first);
        await actions.settleUi(tester);
        await _capture(tester, boundaryKey, 'cards-$label.png');

        await tester.tap(find.byTooltip('搜索 Ctrl+F'));
        await actions.settleUi(tester);
        await tester.enterText(find.byKey(const Key('search-input')), '知识');
        await tester.pump(const Duration(milliseconds: 250));
        await actions.until(
          tester,
          () async =>
              find
                  .descendant(
                    of: find.byType(AlertDialog),
                    matching: find.byType(ListTile),
                  )
                  .evaluate()
                  .length ==
              1,
        );
        FocusManager.instance.primaryFocus?.unfocus();
        await actions.settleUi(tester);
        await _capture(tester, boundaryKey, 'search-$label.png');
        await tester.tap(find.text('关闭').last);
        await actions.settleUi(tester);

        await tester.tap(find.byTooltip('资料').first);
        await actions.settleUi(tester);
        await tester.tap(find.byTooltip('新建脑图'));
        await actions.settleUi(tester);
        FocusManager.instance.primaryFocus?.unfocus();
        await actions.settleUi(tester);
        await _capture(tester, boundaryKey, 'naming-$label.png');
        await tester.tap(find.text('取消').last);
        await actions.settleUi(tester);

        await tester.tap(find.byTooltip('资料库操作'));
        await actions.settleUi(tester);
        await tester.tap(find.text('当前项目回收站').last);
        await actions.until(
          tester,
          () async => find.text('回收站为空').evaluate().isNotEmpty,
        );
        await actions.settleUi(tester);
        await _capture(tester, boundaryKey, 'trash-$label.png');
        expect(tester.takeException(), isNull);
      } finally {
        try {
          await _unmount(tester);
          await actions.real(tester, repository.close);
          repositoryClosed = true;
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      }
    });
  }
}

Future<void> _unmount(WidgetTester tester) async {
  final controller = tester
      .widgetList<ReaderPane>(find.byType(ReaderPane))
      .firstOrNull
      ?.controller;
  await tester.pumpWidget(const SizedBox.shrink());
  if (controller != null) {
    var drained = false;
    Object? error;
    controller.drainClosedDocuments().then(
      (_) => drained = true,
      onError: (Object failure) {
        error = failure;
        drained = true;
      },
    );
    await actions.until(tester, () async => drained);
    if (error != null) throw error!;
  }
  await actions.settleUi(tester);
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  if (_editorGoldenOnly && !name.startsWith('editor-')) return;
  if (_homeGoldenOnly && !name.startsWith('home-')) return;
  expect(tester.takeException(), isNull, reason: '截图前不得存在布局或运行异常');
  expect(
    MediaQuery.sizeOf(tester.element(find.byType(Scaffold).first)),
    tester.view.physicalSize / tester.view.devicePixelRatio,
  );
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await actions.real(
    tester,
    () => boundary.toImage(pixelRatio: tester.view.devicePixelRatio),
  );
  try {
    expect(image.width, tester.view.physicalSize.width.toInt());
    expect(image.height, tester.view.physicalSize.height.toInt());
    await expectLater(image, matchesGoldenFile('baselines/$name'));
  } finally {
    image.dispose();
  }
}
