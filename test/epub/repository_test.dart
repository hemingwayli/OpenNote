import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:opennote/data/open_note_repository.dart';
import 'package:opennote/domain/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late OpenNoteRepository repository;
  late StudyProject project;
  late MindMap map;
  late ManagedDocument document;
  const locator = EpubLocator(
    href: 'OPS/ch1.xhtml',
    cfi: 'epubcfi(/6/2!/4/4,/1:0,/1:2)',
    quote: '中文',
  );
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('opennote-epub-');
    repository = await OpenNoteRepository.open(rootPath: directory.path);
    project = await repository.createProject('混合学习');
    map = await repository.createMap(project.id, '脑图');
    document = await repository.importEpub(
      projectId: project.id,
      filePath: 'tools/fixtures/epub/epub3-reflow.epub',
    );
  });
  tearDown(() async {
    await repository.close();
    await directory.delete(recursive: true);
  });
  Future<ExcerptResult> excerpt() => repository.createExcerpt(
    ExcerptDraft(
      projectId: project.id,
      mapId: map.id,
      title: '中文摘录',
      text: '中文',
      anchors: [
        AnchorDraft(
          revisionId: document.activeRevisionId,
          epubLocator: locator,
        ),
      ],
    ),
  );

  test('原件哈希不变且 EPUB 不伪造 PDF 页面', () async {
    final revision = await repository.getRevision(document.activeRevisionId);
    expect(revision.format, DocumentFormat.epub);
    expect(
      (await repository.listDocuments(project.id)).single.format,
      DocumentFormat.epub,
    );
    expect(
      (await repository.getDocument(document.id)).format,
      DocumentFormat.epub,
    );
    expect(revision.pageCount, 0);
    expect(revision.pageGeometry, isEmpty);
    final path = await repository.resourcePath(revision.resourceId);
    expect(
      sha256.convert(await File(path).readAsBytes()),
      sha256.convert(
        await File('tools/fixtures/epub/epub3-reflow.epub').readAsBytes(),
      ),
    );
  });
  test('摘录批注与改色在同一事务并可撤销', () async {
    final result = await excerpt();
    final anchors = await repository.getAnchors(result.card.id);
    expect(anchors.single.epubLocator!.toJson(), locator.toJson());
    expect(
      (await repository.listAnnotations(document.activeRevisionId))
          .single
          .epubLocator!
          .toJson(),
      locator.toJson(),
    );
    await repository.updateCard(result.card.id, color: '#D97758');
    expect(
      (await repository.listAnnotations(document.activeRevisionId))
          .single
          .color,
      '#D97758',
    );
    await repository.undo();
    expect((await repository.getCard(result.card.id)).color, result.card.color);
  });
  test('拒绝 EPUB 的 PDF 坐标及错误章节来源', () async {
    expect(
      () => repository.createAnnotation(
        anchor: AnchorDraft(
          revisionId: document.activeRevisionId,
          pageIndex: 0,
          quads: [PdfQuad.rect(0, 0, 10, 10)],
        ),
      ),
      throwsA(isA<RepositoryException>()),
    );
    expect(
      () => repository.createAnnotation(
        anchor: AnchorDraft(
          revisionId: document.activeRevisionId,
          epubLocator: const EpubLocator(
            href: 'missing.xhtml',
            cfi: 'epubcfi(/6/2!/4/1:0)',
          ),
        ),
      ),
      throwsA(isA<RepositoryException>()),
    );
  });
  test('持久正文索引支持单中文字及 CFI 搜索', () async {
    await repository.saveEpubSection(document.activeRevisionId, {
      'index': 0,
      'href': 'OPS/ch1.xhtml',
      'text': '中文搜索正文',
      'fragments': [
        {'start': 0, 'length': 6, 'cfi': 'epubcfi(/6/2!/4/4/1:0)'},
      ],
    }, sessionId: repository.sessionId);
    final hit = (await repository.search(
      project.id,
      '文',
      documentId: document.id,
    )).first;
    expect(hit.pageIndex, isNull);
    expect(hit.epubLocator!.quote, '文');
    expect(hit.epubLocator!.cfi, 'epubcfi(/6/2!/4/4,/1:1,/1:2)');
    expect(await repository.indexedEpubSections(document.activeRevisionId), [
      0,
    ]);
  });
  test('阅读设置和来源随完整备份恢复', () async {
    final result = await excerpt();
    await repository.saveEpubPosition(
      ReadingPosition(
        revisionId: document.activeRevisionId,
        epubLocator: locator,
        settings: const EpubReadingSettings(
          fontSize: 24,
          paginated: true,
          fixedZoom: 1.8,
        ),
      ),
      sessionId: repository.sessionId,
    );
    final backup = await repository.backupTo('${directory.path}/test.zip');
    await repository.restoreFrom(backup);
    expect(
      (await repository.getAnchors(result.card.id)).single.epubLocator!.quote,
      '中文',
    );
    final position = await repository.loadReadingPosition(
      document.activeRevisionId,
    );
    expect(position!.epubLocator!.cfi, locator.cfi);
    expect(position.settings.fontSize, 24);
    expect(position.settings.paginated, isTrue);
    expect(position.settings.fixedZoom, 1.8);
    expect(
      await File(
        await repository.resourcePath(
          (await repository.getRevision(document.activeRevisionId)).resourceId,
        ),
      ).exists(),
      isTrue,
    );
  });
  test('跨项目复制保留独立卡片及 EPUB 版本来源', () async {
    final source = await excerpt();
    final target = await repository.createProject('目标');
    final targetMap = await repository.createMap(target.id, '目标脑图');
    final copy = await repository.copyBranch(source.node.id, targetMap.id);
    final cardId = copy.cardIds[source.card.id]!;
    final anchor = (await repository.getAnchors(cardId)).single;
    expect(anchor.revisionId, isNot(document.activeRevisionId));
    expect(anchor.epubLocator!.toJson(), locator.toJson());
    await repository.updateCard(cardId, body: '独立内容');
    expect((await repository.getCard(source.card.id)).body, isNot('独立内容'));
  });
  test('旧会话无法提交正文和阅读位置', () async {
    final session = repository.sessionId;
    final backup = await repository.backupTo('${directory.path}/session.zip');
    await repository.restoreFrom(backup);
    expect(
      () => repository.saveEpubPosition(
        ReadingPosition(
          revisionId: document.activeRevisionId,
          epubLocator: locator,
        ),
        sessionId: session,
      ),
      throwsA(isA<RepositoryException>()),
    );
  });
}
