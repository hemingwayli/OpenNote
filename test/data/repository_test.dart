import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:drift/drift.dart' as drift;
import 'package:flutter_test/flutter_test.dart';
import 'package:opennote/data/open_note_repository.dart';
import 'package:opennote/domain/models.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final oldMultiDatabaseWarning =
      drift.driftRuntimeOptions.dontWarnAboutMultipleDatabases;
  setUpAll(() {
    // 路径迁移测试同时打开不同临时库，各自拥有独立 executor 与目录锁。
    drift.driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });
  tearDownAll(() {
    drift.driftRuntimeOptions.dontWarnAboutMultipleDatabases =
        oldMultiDatabaseWarning;
  });
  late Directory temp;
  late OpenNoteRepository repository;
  late StudyProject project;
  late MindMap map;
  late ManagedDocument document;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('opennote-data-');
    repository = await OpenNoteRepository.open(
      rootPath: p.join(temp.path, 'library'),
    );
    project = await repository.createProject('中文学习项目');
    map = (await repository.listMaps(project.id)).single;
    final pdf = File(p.join(temp.path, '原文.pdf'));
    await pdf.writeAsBytes(_pdfBytes(2));
    document = await repository.importPdf(
      projectId: project.id,
      filePath: pdf.path,
      pageCount: 2,
    );
  });

  tearDown(() async {
    await repository.close();
    await temp.delete(recursive: true);
  });

  Future<PageTextLayer> layer(String text) => repository.saveTextLayer(
    TextLayerDraft(
      revisionId: document.activeRevisionId,
      pageIndex: 0,
      source: TextLayerSource.ocr,
      text: text,
      engineVersion: 'test-ocr-1',
      fragments: [
        TextFragment(
          start: 0,
          length: text.length,
          quad: PdfQuad.rect(20, 100, 200, 120),
          order: 0,
          confidence: .98,
          precision: GeometryPrecision.line,
        ),
      ],
    ),
    sessionId: repository.sessionId,
  );

  Future<ExcerptResult> excerpt(
    String text, {
    String? parent,
    List<AnchorDraft> anchors = const [],
  }) => repository.createExcerpt(
    ExcerptDraft(
      projectId: project.id,
      mapId: map.id,
      title: text,
      text: text,
      parentNodeId: parent,
      anchors: anchors,
    ),
  );

  test('直接重命名项目PDF与脑图保留身份原文关系，独立事务可撤销重做', () async {
    final root = await excerpt(
      '重命名后仍可回源',
      anchors: [
        AnchorDraft(
          revisionId: document.activeRevisionId,
          pageIndex: 0,
          quads: [PdfQuad.rect(10, 20, 40, 50)],
        ),
      ],
    );
    final child = await excerpt('保留子卡片', parent: root.node.id);
    final edge = await repository.addAssociation(root.node.id, child.node.id);
    final originalRevision = await repository.getRevision(
      document.activeRevisionId,
    );
    final originalPath = await repository.resourcePath(
      originalRevision.resourceId,
    );
    final originalBytes = await File(originalPath).readAsBytes();
    final historyBefore = repository.undoEntryCount;

    await repository.renameProject(project.id, '  新学习项目名称  ');
    await repository.renameDocument(document.id, '  新 PDF 标题  ');
    await repository.renameMap(map.id, '  新脑图名称  ');
    expect(repository.undoEntryCount, historyBefore + 3);
    expect((await repository.listProjects()).single.id, project.id);
    expect((await repository.listProjects()).single.title, '新学习项目名称');
    final renamedDocument = await repository.getDocument(document.id);
    expect(renamedDocument.title, '新 PDF 标题');
    expect(renamedDocument.activeRevisionId, document.activeRevisionId);
    final snapshot = await repository.loadMap(map.id);
    expect(snapshot.map.title, '新脑图名称');
    expect(snapshot.nodes.map((n) => n.id).toSet(), {
      root.node.id,
      child.node.id,
    });
    expect(
      snapshot.nodes.singleWhere((n) => n.id == child.node.id).parentNodeId,
      root.node.id,
    );
    expect(snapshot.edges.single.id, edge.id);
    expect(snapshot.cards[root.card.id]!.body, root.card.body);
    expect(
      snapshot.anchors[root.card.id]!.single.revisionId,
      originalRevision.id,
    );
    final revision = await repository.getRevision(document.activeRevisionId);
    expect(revision.resourceId, originalRevision.resourceId);
    expect(revision.contentHash, originalRevision.contentHash);
    expect(await repository.resourcePath(revision.resourceId), originalPath);
    expect(await File(originalPath).readAsBytes(), originalBytes);

    await repository.undo();
    expect((await repository.loadMap(map.id)).map.title, map.title);
    final noOpUndo = repository.undoEntryCount;
    final noOpRedo = repository.redoEntryCount;
    await repository.renameMap(map.id, '  ${map.title}  ');
    expect(repository.undoEntryCount, noOpUndo);
    expect(repository.redoEntryCount, noOpRedo);
    await repository.redo();
    expect((await repository.loadMap(map.id)).map.title, '新脑图名称');

    for (var index = 0; index < 3; index++) {
      await repository.undo();
    }
    expect((await repository.listProjects()).single.title, project.title);
    expect((await repository.getDocument(document.id)).title, document.title);
    expect((await repository.loadMap(map.id)).map.title, map.title);
    expect(repository.undoEntryCount, historyBefore);
    for (var index = 0; index < 3; index++) {
      await repository.redo();
    }
    expect((await repository.listProjects()).single.title, '新学习项目名称');
    expect((await repository.getDocument(document.id)).title, '新 PDF 标题');
    expect((await repository.loadMap(map.id)).map.title, '新脑图名称');
    expect(repository.undoEntryCount, historyBefore + 3);
    expect(await File(originalPath).readAsBytes(), originalBytes);
  });

  test('重命名拒绝空标题与非活动实体，失败不改变名称或会话历史', () async {
    final commands = <Future<void> Function(String)>[
      (title) => repository.renameProject(project.id, title),
      (title) => repository.renameDocument(document.id, title),
      (title) => repository.renameMap(map.id, title),
    ];
    final historyBefore = repository.undoEntryCount;
    for (final command in commands) {
      await expectLater(
        command(' \t\r\n '),
        throwsA(
          isA<RepositoryException>().having(
            (error) => error.code,
            'code',
            RepositoryError.invalidInput,
          ),
        ),
      );
    }
    expect(repository.undoEntryCount, historyBefore);
    expect((await repository.listProjects()).single.title, project.title);
    expect((await repository.getDocument(document.id)).title, document.title);
    expect((await repository.loadMap(map.id)).map.title, map.title);

    await repository.trashDocument(document.id);
    await repository.trashMap(map.id);
    for (final command in commands.skip(1)) {
      await expectLater(
        command('不应写入'),
        throwsA(
          isA<RepositoryException>().having(
            (error) => error.code,
            'code',
            RepositoryError.notFound,
          ),
        ),
      );
    }
    for (final entry in await repository.listTrash()) {
      await repository.restoreTrash(entry.id);
    }
    await repository.trashProject(project.id);
    final historyAfterTrash = repository.undoEntryCount;
    for (final command in commands) {
      await expectLater(
        command('项目已回收时不应写入'),
        throwsA(
          isA<RepositoryException>().having(
            (error) => error.code,
            'code',
            RepositoryError.notFound,
          ),
        ),
      );
    }
    expect(repository.undoEntryCount, historyAfterTrash);
    expect(
      (await repository.listProjects(includeDeleted: true)).single.title,
      project.title,
    );
    expect((await repository.getDocument(document.id)).title, document.title);
  });

  test('重识别保留旧锚点和用户编辑，单字中文搜索可定位', () async {
    final original = await layer('中文原文 English book');
    final result = await excerpt(
      '中文原文',
      anchors: [
        AnchorDraft(
          revisionId: document.activeRevisionId,
          pageIndex: 0,
          quads: [PdfQuad.rect(20, 100, 200, 120)],
          textLayerId: original.id,
          textStart: 0,
          textEnd: 4,
        ),
      ],
    );
    await repository.updateCard(result.card.id, body: '自己的正文', note: '自己的批注');
    final refreshed = await layer('中文修正 English book');
    expect(refreshed.id, isNot(original.id));
    final anchor = (await repository.getAnchors(result.card.id)).single;
    expect(anchor.textLayerId, original.id);
    final card = await repository.getCard(result.card.id);
    expect(card.excerptSnapshot, '中文原文');
    expect(card.body, '自己的正文');
    expect(card.note, '自己的批注');
    final hits = await repository.search(
      project.id,
      '中',
      documentId: document.id,
    );
    expect(hits.single.textLayerId, refreshed.id);
    expect(hits.single.pageIndex, 0);
    expect(hits.single.quads, isNotEmpty);
    expect(
      (await repository.search(
        project.id,
        'ENGLISH',
        documentId: document.id,
      )).single.start,
      5,
    );
  });

  test('自动保存业务字段相同不改时间戳、不创建undo、不清redo或触发changes', () async {
    final result = await excerpt('保持正文');
    int savedTimestamp() {
      final db = sqlite3.open(
        p.join(repository.libraryPath, 'library.sqlite'),
        mode: OpenMode.readOnly,
      );
      try {
        return db.select('SELECT updated_at FROM cards WHERE id=?', [
              result.card.id,
            ]).single['updated_at']
            as int;
      } finally {
        db.close();
      }
    }

    final originalTimestamp = savedTimestamp();
    final originalUndo = repository.undoEntryCount;
    var notifications = 0;
    final subscription = repository.changes.listen((_) => notifications++);
    try {
      await repository.updateCard(
        result.card.id,
        title: '  ${result.card.title}  ',
        body: result.card.body,
        note: result.card.note,
        color: result.card.color,
      );
      await Future<void>.delayed(Duration.zero);
      expect(savedTimestamp(), originalTimestamp);
      expect(repository.undoEntryCount, originalUndo);
      expect(notifications, 0);
      await repository.updateCard(result.card.id, body: '真实编辑');
      await repository.undo();
      final afterUndoTimestamp = savedTimestamp();
      final undoCount = repository.undoEntryCount;
      final redoCount = repository.redoEntryCount;
      await Future<void>.delayed(Duration.zero);
      final afterUndoNotifications = notifications;
      await repository.updateCard(result.card.id, body: '保持正文');
      await Future<void>.delayed(Duration.zero);
      expect(savedTimestamp(), afterUndoTimestamp);
      expect(repository.undoEntryCount, undoCount);
      expect(repository.redoEntryCount, redoCount);
      expect(notifications, afterUndoNotifications);
      await repository.redo();
      expect((await repository.getCard(result.card.id)).body, '真实编辑');
    } finally {
      await subscription.cancel();
    }
  });

  test('跨项目复制分支：卡片、锚点、文档独立，仅复制内部关联', () async {
    final textLayer = await layer('source');
    final root = await excerpt(
      'root',
      anchors: [
        AnchorDraft(
          revisionId: document.activeRevisionId,
          pageIndex: 0,
          quads: [PdfQuad.rect(1, 2, 3, 4)],
          textLayerId: textLayer.id,
          textStart: 0,
          textEnd: 6,
        ),
      ],
    );
    final child = await excerpt('child', parent: root.node.id);
    final outside = await excerpt('outside');
    await repository.addAssociation(root.node.id, child.node.id);
    await repository.addAssociation(child.node.id, outside.node.id);
    final target = await repository.createProject('另一项目');
    final targetMap = (await repository.listMaps(target.id)).single;
    final copied = await repository.copyBranch(root.node.id, targetMap.id);
    expect(copied.cardIds.length, 2);
    final snapshot = await repository.loadMap(targetMap.id);
    expect(snapshot.nodes.length, 2);
    expect(snapshot.edges.length, 1);
    final copiedCardId = copied.cardIds[root.card.id]!;
    await repository.updateCard(copiedCardId, body: '只修改副本');
    expect((await repository.getCard(root.card.id)).body, 'root');
    final copiedAnchor = (await repository.getAnchors(copiedCardId)).single;
    expect(
      copiedAnchor.id,
      isNot((await repository.getAnchors(root.card.id)).single.id),
    );
    expect(copiedAnchor.revisionId, isNot(document.activeRevisionId));
    expect(copiedAnchor.textLayerId, isNot(textLayer.id));
    final originalRevision = await repository.getRevision(
      document.activeRevisionId,
    );
    final copiedRevision = await repository.getRevision(
      copiedAnchor.revisionId,
    );
    expect(copiedRevision.resourceId, originalRevision.resourceId);
    final copiedAnnotations = await repository.listAnnotations(
      copiedAnchor.revisionId,
    );
    await repository.updateAnnotation(
      copiedAnnotations.single.id,
      text: '副本批注',
    );
    expect(
      (await repository.listAnnotations(document.activeRevisionId)).single.text,
      isEmpty,
    );
  });

  test('重挂拒绝环，整个分支移动与移除可原子撤销', () async {
    await repository.setMapLayout(map.id, MapLayoutKind.free);
    final root = await excerpt('parent');
    final child = await excerpt('child', parent: root.node.id);
    await expectLater(
      repository.reparentNode(root.node.id, child.node.id),
      throwsA(
        isA<RepositoryException>().having(
          (e) => e.code,
          'code',
          RepositoryError.cycle,
        ),
      ),
    );
    await repository.moveNode(root.node.id, 120, 80);
    var nodes = (await repository.loadMap(map.id)).nodes;
    expect(nodes.singleWhere((n) => n.id == child.node.id).x, 120);
    await repository.undo();
    expect(
      (await repository.loadMap(map.id)).nodes
          .singleWhere((n) => n.id == root.node.id)
          .x,
      0,
    );
    await repository.redo();
    final edge1 = await repository.addAssociation(root.node.id, child.node.id);
    final edge2 = await repository.addAssociation(child.node.id, root.node.id);
    expect(edge1.id, edge2.id);
    await repository.removeBranch(root.node.id);
    expect((await repository.loadMap(map.id)).nodes, isEmpty);
    expect((await repository.listCards(project.id)).length, 2);
    await repository.undo();
    final restored = await repository.loadMap(map.id);
    expect(restored.nodes.length, 2);
    expect(restored.edges.length, 1);
  });

  test('失效锚点导致整个摘录回滚，独立批注不需要卡片', () async {
    final textLayer = await layer('text');
    await expectLater(
      excerpt(
        'bad',
        anchors: [
          AnchorDraft(
            revisionId: document.activeRevisionId,
            pageIndex: 0,
            quads: [PdfQuad.rect(0, 0, 1, 1)],
            textLayerId: textLayer.id,
            textStart: 0,
            textEnd: 99,
          ),
        ],
      ),
      throwsA(isA<RepositoryException>()),
    );
    expect(await repository.listCards(project.id), isEmpty);
    expect((await repository.loadMap(map.id)).nodes, isEmpty);
    final annotation = await repository.addAnnotation(
      anchor: AnchorDraft(
        revisionId: document.activeRevisionId,
        pageIndex: 1,
        quads: [PdfQuad.rect(10, 10, 40, 40)],
      ),
      kind: 'note',
      text: '未生成卡片的备注',
    );
    expect(annotation.cardId, isNull);
    expect(
      (await repository.listAnnotations(document.activeRevisionId)).single.text,
      '未生成卡片的备注',
    );
  });

  test('同项目跨图移动保留身份，内部关联迁移和批量布局一次撤销', () async {
    await repository.setMapLayout(map.id, MapLayoutKind.free);
    final root = await excerpt('move-root');
    final child = await excerpt('move-child', parent: root.node.id);
    final outside = await excerpt('outside');
    await repository.addAssociation(root.node.id, child.node.id);
    await repository.addAssociation(child.node.id, outside.node.id);
    final destination = await repository.createMap(project.id, '目标脑图');
    await repository.setMapLayout(destination.id, MapLayoutKind.free);
    await repository.moveBranchToMap(root.node.id, destination.id);
    var target = await repository.loadMap(destination.id);
    expect(target.nodes.map((n) => n.id).toSet(), {
      root.node.id,
      child.node.id,
    });
    expect(target.cards.keys.toSet(), {root.card.id, child.card.id});
    expect(target.edges.length, 1);
    expect((await repository.loadMap(map.id)).edges, isEmpty);
    await repository.layoutNodes(destination.id, {
      root.node.id: const PdfPoint(200, 50),
      child.node.id: const PdfPoint(450, 70),
    });
    expect(
      (await repository.loadMap(destination.id)).nodes
          .singleWhere((n) => n.id == child.node.id)
          .x,
      450,
    );
    await repository.undo();
    expect(
      (await repository.loadMap(destination.id)).nodes
          .singleWhere((n) => n.id == child.node.id)
          .x,
      0,
    );
    await repository.undo();
    expect((await repository.loadMap(map.id)).nodes.length, 3);
    expect((await repository.loadMap(map.id)).edges.length, 2);
    expect((await repository.loadMap(destination.id)).nodes, isEmpty);
  });

  test('恢复脑图拒绝已放入另一有效图的卡片，失败原子且解除占用后可恢复', () async {
    final root = await excerpt('待恢复冲突卡片');
    final child = await excerpt('不冲突子卡片', parent: root.node.id);
    final edge = await repository.addAssociation(root.node.id, child.node.id);
    final destination = await repository.createMap(project.id, '脑图 B');
    await repository.trashMap(map.id);
    final trash = (await repository.listTrash()).single;
    final placed = await repository.placeCard(
      root.card.id,
      destination.id,
      x: 30,
      y: 60,
    );
    await repository.updateCard(root.card.id, note: '在脑图 B 中编辑的备注');
    final historyBeforeRestore = repository.undoEntryCount;

    await expectLater(
      repository.restoreTrash(trash.id),
      throwsA(
        isA<RepositoryException>().having(
          (error) => error.code,
          'code',
          RepositoryError.conflict,
        ),
      ),
    );
    expect(repository.undoEntryCount, historyBeforeRestore);
    expect((await repository.listMaps(project.id)).map((m) => m.id), [
      destination.id,
    ]);
    expect((await repository.listTrash()).single.id, trash.id);
    await expectLater(
      repository.loadMap(map.id),
      throwsA(
        isA<RepositoryException>().having(
          (error) => error.code,
          'code',
          RepositoryError.notFound,
        ),
      ),
    );
    final unchanged = await repository.loadMap(destination.id);
    expect(unchanged.nodes.single.id, placed.id);
    expect(unchanged.nodes.single.x, 30);
    expect(unchanged.nodes.single.y, 60);
    expect(unchanged.cards[root.card.id]!.note, '在脑图 B 中编辑的备注');
    expect((await repository.listCards(project.id)).length, 2);

    await repository.removeBranch(placed.id);
    await repository.restoreTrash(trash.id);
    final restored = await repository.loadMap(map.id);
    expect(restored.nodes.map((n) => n.id).toSet(), {
      root.node.id,
      child.node.id,
    });
    expect(
      restored.nodes.singleWhere((n) => n.id == child.node.id).parentNodeId,
      root.node.id,
    );
    expect(restored.edges.single.id, edge.id);
    expect(restored.cards[root.card.id]!.note, '在脑图 B 中编辑的备注');
    expect((await repository.loadMap(destination.id)).nodes, isEmpty);
    expect(await repository.listTrash(), isEmpty);

    await repository.undo();
    expect((await repository.listTrash()).single.id, trash.id);
    expect((await repository.listMaps(project.id)).single.id, destination.id);
    await repository.redo();
    expect((await repository.loadMap(map.id)).nodes.length, 2);
    expect(await repository.listTrash(), isEmpty);
  });

  test('恢复卡片拒绝历史节点在两张有效图中同时复原，冲突原子且回收一图后可恢复', () async {
    final root = await excerpt('跨历史脑图恢复的卡片');
    final child = await excerpt('脑图 A 中的子卡片', parent: root.node.id);
    final edge = await repository.addAssociation(root.node.id, child.node.id);
    final destination = await repository.createMap(project.id, '脑图 B');
    await repository.trashMap(map.id);
    final originalMapTrash = (await repository.listTrash()).single;
    final placed = await repository.placeCard(root.card.id, destination.id);
    final otherChild = await repository.createExcerpt(
      ExcerptDraft(
        projectId: project.id,
        mapId: destination.id,
        title: '脑图 B 中的子卡片',
        text: '脑图 B 中的子卡片',
        parentNodeId: placed.id,
      ),
    );
    final otherEdge = await repository.addAssociation(
      placed.id,
      otherChild.node.id,
    );
    await repository.trashCard(root.card.id);
    final cardTrash = (await repository.listTrash()).singleWhere(
      (entry) => entry.kind == TrashKind.card,
    );
    // 卡片已回收，因此恢复 A 时不会与 B 的卡片形成有效占用。
    await repository.restoreTrash(originalMapTrash.id);

    Map<String, List<Map<String, Object?>>> persistedRows() {
      final db = sqlite3.open(
        p.join(repository.libraryPath, 'library.sqlite'),
        mode: OpenMode.readOnly,
      );
      try {
        return {
          for (final table in [
            'cards',
            'nodes',
            'maps',
            'trash',
            'edges',
            'anchors',
          ])
            table: db
                .select('SELECT * FROM $table ORDER BY id')
                .map((row) => Map<String, Object?>.from(row))
                .toList(),
        };
      } finally {
        db.close();
      }
    }

    int activePlacementCount() {
      final db = sqlite3.open(
        p.join(repository.libraryPath, 'library.sqlite'),
        mode: OpenMode.readOnly,
      );
      try {
        return db
                .select(
                  '''SELECT COUNT(*) AS count FROM nodes n
                 JOIN cards c ON c.id=n.card_id JOIN maps m ON m.id=n.map_id
                 WHERE n.card_id=? AND n.deleted_at IS NULL
                   AND c.deleted_at IS NULL AND m.deleted_at IS NULL''',
                  [root.card.id],
                )
                .single['count']
            as int;
      } finally {
        db.close();
      }
    }

    final beforeRestore = persistedRows();
    final undoBeforeRestore = repository.undoEntryCount;
    final redoBeforeRestore = repository.redoEntryCount;
    expect(activePlacementCount(), 0);
    await expectLater(
      repository.restoreTrash(cardTrash.id),
      throwsA(
        isA<RepositoryException>()
            .having((error) => error.code, 'code', RepositoryError.conflict)
            .having((error) => error.message, 'message', contains('回收站')),
      ),
    );
    expect(persistedRows(), beforeRestore);
    expect(repository.undoEntryCount, undoBeforeRestore);
    expect(repository.redoEntryCount, redoBeforeRestore);
    expect((await repository.listTrash()).single.id, cardTrash.id);
    expect(activePlacementCount(), 0);

    await repository.trashMap(destination.id);
    final destinationTrash = (await repository.listTrash()).singleWhere(
      (entry) => entry.kind == TrashKind.map,
    );
    await repository.restoreTrash(cardTrash.id);
    expect(activePlacementCount(), 1);
    final restored = await repository.loadMap(map.id);
    expect(restored.nodes.map((node) => node.id).toSet(), {
      root.node.id,
      child.node.id,
    });
    expect(
      restored.nodes
          .singleWhere((node) => node.id == child.node.id)
          .parentNodeId,
      root.node.id,
    );
    expect(restored.edges.single.id, edge.id);
    // 两份历史节点都完整复原，B 仍在回收站，不静默丢掉它的历史位置。
    final restoredRows = persistedRows();
    final restoredCardNodes = restoredRows['nodes']!
        .where((row) => row['card_id'] == root.card.id)
        .toList();
    expect(restoredCardNodes.map((row) => row['id']).toSet(), {
      root.node.id,
      placed.id,
    });
    expect(restoredCardNodes.every((row) => row['deleted_at'] == null), isTrue);
    expect(
      restoredRows['nodes']!.singleWhere(
        (row) => row['id'] == otherChild.node.id,
      )['parent_node_id'],
      placed.id,
    );
    expect(
      restoredRows['edges']!.any((row) => row['id'] == otherEdge.id),
      isTrue,
    );
    final undoBeforeMapRestore = repository.undoEntryCount;
    final redoBeforeMapRestore = repository.redoEntryCount;
    await expectLater(
      repository.restoreTrash(destinationTrash.id),
      throwsA(
        isA<RepositoryException>().having(
          (error) => error.code,
          'code',
          RepositoryError.conflict,
        ),
      ),
    );
    expect(persistedRows(), restoredRows);
    expect(repository.undoEntryCount, undoBeforeMapRestore);
    expect(repository.redoEntryCount, redoBeforeMapRestore);
    expect(activePlacementCount(), 1);

    await repository.undo();
    expect(activePlacementCount(), 0);
    expect(
      (await repository.listTrash()).any((entry) => entry.id == cardTrash.id),
      isTrue,
    );
    await repository.redo();
    expect(persistedRows(), restoredRows);
    expect(activePlacementCount(), 1);
  });

  test('折叠主题路径中新建摘录展开祖先，单次撤销恢复折叠并移除完整摘录', () async {
    final ancestor = await excerpt('折叠祖主题');
    final parent = await excerpt('折叠父主题', parent: ancestor.node.id);
    final unrelated = await excerpt('保持折叠的其他主题');
    await repository.setNodeCollapsed(ancestor.node.id, true);
    await repository.setNodeCollapsed(parent.node.id, true);
    await repository.setNodeCollapsed(unrelated.node.id, true);
    final historyBeforeExcerpt = repository.undoEntryCount;

    final result = await excerpt(
      '新摘录必须可见',
      parent: parent.node.id,
      anchors: [
        AnchorDraft(
          revisionId: document.activeRevisionId,
          pageIndex: 0,
          quads: [PdfQuad.rect(10, 20, 40, 50)],
        ),
      ],
    );
    final expanded = await repository.loadMap(map.id);
    expect(
      expanded.nodes.singleWhere((n) => n.id == ancestor.node.id).collapsed,
      isFalse,
    );
    expect(
      expanded.nodes.singleWhere((n) => n.id == parent.node.id).collapsed,
      isFalse,
    );
    expect(
      expanded.nodes.singleWhere((n) => n.id == unrelated.node.id).collapsed,
      isTrue,
    );
    expect(result.node.parentNodeId, parent.node.id);
    expect(
      expanded.anchors[result.card.id]!.single.revisionId,
      document.activeRevisionId,
    );
    expect(repository.undoEntryCount, historyBeforeExcerpt + 1);

    await repository.undo();
    final undone = await repository.loadMap(map.id);
    expect(undone.nodes.map((n) => n.id).toSet(), {
      ancestor.node.id,
      parent.node.id,
      unrelated.node.id,
    });
    expect(undone.nodes.every((n) => n.collapsed), isTrue);
    expect(undone.cards.containsKey(result.card.id), isFalse);
    expect(await repository.getAnchors(result.card.id), isEmpty);
    expect(
      await repository.listAnnotations(document.activeRevisionId),
      isEmpty,
    );
    expect((await repository.listCards(project.id)).length, 3);
    expect(repository.undoEntryCount, historyBeforeExcerpt);

    await repository.redo();
    final redone = await repository.loadMap(map.id);
    expect(redone.nodes.length, 4);
    expect(
      redone.nodes.singleWhere((n) => n.id == ancestor.node.id).collapsed,
      isFalse,
    );
    expect(
      redone.nodes.singleWhere((n) => n.id == parent.node.id).collapsed,
      isFalse,
    );
    expect(
      redone.nodes.singleWhere((n) => n.id == unrelated.node.id).collapsed,
      isTrue,
    );
    expect(redone.cards[result.card.id]!.body, '新摘录必须可见');
    expect(
      redone.anchors[result.card.id]!.single.revisionId,
      document.activeRevisionId,
    );
    expect(repository.undoEntryCount, historyBeforeExcerpt + 1);
  });

  test('回收子卡片后移除父分支，恢复子卡片不会悬空引用', () async {
    final parent = await excerpt('父节点');
    final child = await excerpt('待回收子节点', parent: parent.node.id);
    final grandchild = await excerpt('孙节点', parent: child.node.id);
    await repository.trashCard(child.card.id);
    expect(
      (await repository.loadMap(map.id)).nodes
          .singleWhere((n) => n.id == grandchild.node.id)
          .parentNodeId,
      parent.node.id,
    );
    await repository.removeBranch(parent.node.id);
    expect((await repository.loadMap(map.id)).nodes, isEmpty);
    await repository.restoreTrash((await repository.listTrash()).single.id);
    final restored = (await repository.loadMap(map.id)).nodes.single;
    expect(restored.id, child.node.id);
    expect(restored.parentNodeId, isNull);
    expect((await repository.listCards(project.id)).length, 3);
  });

  test('恢复前钩子可等待仓储取消任务，不发生锁内死锁', () async {
    await repository.enqueueOcr(document.activeRevisionId, [
      0,
    ], modelVersion: 'fixture-model');
    final backup = p.join(temp.path, 'hook.opennote');
    await repository.backupTo(backup);
    await repository
        .restoreFrom(backup, beforeSwitch: () => repository.cancelOcr())
        .timeout(const Duration(seconds: 10));
    expect(
      (await repository.listOcrTasks()).single.status,
      OcrTaskStatus.queued,
    );
  });

  test('回收站跨重启保留，删除 PDF 不损坏卡片回源', () async {
    final result = await excerpt(
      '保留',
      anchors: [
        AnchorDraft(
          revisionId: document.activeRevisionId,
          pageIndex: 0,
          quads: [PdfQuad.rect(1, 2, 3, 4)],
        ),
      ],
    );
    await repository.trashDocument(document.id);
    expect(await repository.listDocuments(project.id), isEmpty);
    final anchor = (await repository.getAnchors(result.card.id)).single;
    final revision = await repository.getRevision(anchor.revisionId);
    expect(
      await File(await repository.resolveResourcePath(revision.resourceId))
          .exists(),
      isTrue,
    );
    await repository.close();
    repository = await OpenNoteRepository.open(
      rootPath: p.join(temp.path, 'library'),
    );
    expect(repository.canUndo, isFalse);
    final trash = await repository.listTrash();
    expect(trash.single.kind, TrashKind.document);
    await repository.restoreTrash(trash.single.id);
    expect((await repository.listDocuments(project.id)).single.id, document.id);
  });

  test('全库备份恢复可迁移路径，生成安全备份并拒绝旧 OCR 结果', () async {
    await layer('离线文本');
    final result = await excerpt('备份卡片');
    final backup = p.join(temp.path, '完整备份.opennote');
    await repository.backupTo(backup);
    await repository.updateCard(result.card.id, note: '备份之后新增');
    final oldSession = repository.sessionId;
    await repository.restoreFrom(backup);
    expect((await repository.getCard(result.card.id)).note, isEmpty);
    expect(repository.sessionId, isNot(oldSession));
    expect(repository.canUndo, isFalse);
    expect(await File(repository.lastSafetyBackupPath!).exists(), isTrue);
    await expectLater(
      repository.saveTextLayer(
        TextLayerDraft(
          revisionId: document.activeRevisionId,
          pageIndex: 0,
          source: TextLayerSource.ocr,
          text: '迟到旧结果',
          fragments: const [],
          engineVersion: 'test',
        ),
        sessionId: oldSession,
      ),
      throwsA(
        isA<RepositoryException>().having(
          (e) => e.code,
          'code',
          RepositoryError.staleSession,
        ),
      ),
    );
    final other = await OpenNoteRepository.open(
      rootPath: p.join(temp.path, '另一台机器'),
    );
    try {
      await other.restoreFrom(repository.lastSafetyBackupPath!);
      expect((await other.getCard(result.card.id)).note, '备份之后新增');
      final revision = await other.getRevision(document.activeRevisionId);
      expect(
        await File(await other.resourcePath(revision.resourceId)).exists(),
        isTrue,
      );
      expect(
        (await other.loadTextLayers(document.activeRevisionId)).single.text,
        '离线文本',
      );
    } finally {
      await other.close();
    }
  });

  test('破损清单与 ZIP 路径穿越不能覆盖当前库', () async {
    final result = await excerpt('当前有效数据');
    final backup = p.join(temp.path, 'valid.opennote');
    await repository.backupTo(backup);
    final bytes = await File(backup).readAsBytes();
    final original = ZipDecoder().decodeBytes(bytes);
    final invalid = Archive();
    for (final file in original) {
      if (file.name == 'manifest.json') {
        final manifest = jsonDecode(utf8.decode(file.readBytes()!)) as Map;
        (manifest['files'] as List).first['sha256'] = '0' * 64;
        final encoded = utf8.encode(jsonEncode(manifest));
        invalid.addFile(ArchiveFile(file.name, encoded.length, encoded));
      } else {
        invalid.addFile(file);
      }
    }
    final broken = File(p.join(temp.path, 'broken.opennote'));
    await broken.writeAsBytes(ZipEncoder().encode(invalid));
    final session = repository.sessionId;
    await expectLater(
      repository.restoreFrom(broken.path),
      throwsA(isA<RepositoryException>()),
    );
    expect(repository.sessionId, session);
    expect((await repository.getCard(result.card.id)).title, '当前有效数据');
    final traversal = Archive()
      ..addFile(ArchiveFile('../outside.txt', 4, utf8.encode('bad!')));
    final unsafe = File(p.join(temp.path, 'unsafe.opennote'));
    await unsafe.writeAsBytes(ZipEncoder().encode(traversal));
    await expectLater(
      repository.restoreFrom(unsafe.path),
      throwsA(isA<RepositoryException>()),
    );
    expect(await File(p.join(temp.path, 'outside.txt')).exists(), isFalse);
  });

  test('自动OCR入队仅补缺页且并发保留失败取消状态，显式请求可重试', () async {
    final original = (await repository.enqueueOcr(document.activeRevisionId, [
      0,
    ], modelVersion: 'admission-contract')).single;
    await repository.claimOcrTask(original.id, sessionId: repository.sessionId);
    await repository.failOcrTask(
      original.id,
      '保留的失败原因',
      sessionId: repository.sessionId,
    );
    final admitted = await repository.enqueueOcr(
      document.activeRevisionId,
      [0, 1],
      modelVersion: 'admission-contract',
      retryIncomplete: false,
    );
    expect(admitted[0].id, original.id);
    expect(admitted[0].status, OcrTaskStatus.failed);
    expect(admitted[0].error, '保留的失败原因');
    expect(admitted[1].status, OcrTaskStatus.queued);
    await repository.cancelOcr(revisionId: document.activeRevisionId);
    final before = await repository.listOcrTasks();
    final historyBefore = repository.undoEntryCount;

    final concurrent = await Future.wait([
      repository.enqueueOcr(
        document.activeRevisionId,
        [0, 1],
        modelVersion: 'admission-contract',
        retryIncomplete: false,
      ),
      repository.enqueueOcr(
        document.activeRevisionId,
        [0, 1],
        modelVersion: 'admission-contract',
        retryIncomplete: false,
      ),
    ]);
    for (final result in concurrent) {
      expect(result.map((task) => task.id), admitted.map((task) => task.id));
      expect(result.map((task) => task.status), [
        OcrTaskStatus.failed,
        OcrTaskStatus.cancelled,
      ]);
      expect(result[0].error, '保留的失败原因');
    }
    final after = await repository.listOcrTasks();
    expect(after.length, 2);
    for (final originalTask in before) {
      final preserved = after.singleWhere((task) => task.id == originalTask.id);
      expect(preserved.status, originalTask.status);
      expect(preserved.error, originalTask.error);
      expect(preserved.sessionId, originalTask.sessionId);
    }
    expect(repository.undoEntryCount, historyBefore);

    final explicit = await repository.enqueueOcr(document.activeRevisionId, [
      0,
      1,
    ], modelVersion: 'admission-contract');
    expect(explicit.map((task) => task.id), admitted.map((task) => task.id));
    expect(
      explicit.every((task) => task.status == OcrTaskStatus.queued),
      isTrue,
    );
    expect(explicit.every((task) => task.error.isEmpty), isTrue);
    expect(explicit.every((task) => task.sessionId == null), isTrue);
  });

  test('OCR 页状态取消、续跑与完成提交保持一致', () async {
    final tasks = await repository.enqueueOcr(document.activeRevisionId, [
      0,
      1,
    ], modelVersion: 'fixture-model');
    await repository.claimOcrTask(tasks[0].id, sessionId: repository.sessionId);
    await repository.cancelOcr(revisionId: document.activeRevisionId);
    await expectLater(
      repository.saveTextLayer(
        TextLayerDraft(
          revisionId: document.activeRevisionId,
          pageIndex: 0,
          source: TextLayerSource.ocr,
          text: '已取消结果',
          fragments: const [],
          engineVersion: 'fixture-model',
        ),
        sessionId: repository.sessionId,
        ocrTaskId: tasks[0].id,
      ),
      throwsA(
        isA<RepositoryException>().having(
          (e) => e.code,
          'code',
          RepositoryError.staleSession,
        ),
      ),
    );
    final resumed = await repository.enqueueOcr(document.activeRevisionId, [
      0,
    ], modelVersion: 'fixture-model');
    expect(resumed.single.id, tasks[0].id);
    await repository.claimOcrTask(tasks[0].id, sessionId: repository.sessionId);
    await repository.saveTextLayer(
      TextLayerDraft(
        revisionId: document.activeRevisionId,
        pageIndex: 0,
        source: TextLayerSource.ocr,
        text: '完成文字',
        fragments: const [],
        engineVersion: 'fixture-model',
      ),
      sessionId: repository.sessionId,
      ocrTaskId: tasks[0].id,
    );
    expect(
      (await repository.listOcrTasks())
          .firstWhere((t) => t.id == tasks[0].id)
          .status,
      OcrTaskStatus.completed,
    );
  });

  test('全书队列允许原生文字完成任务，同版本强制重识别保留历史层', () async {
    final original = await layer('保留的 OCR 层');
    final tasks = await repository.enqueueOcr(document.activeRevisionId, [
      0,
      1,
    ], modelVersion: 'model-v1');
    await repository.claimOcrTask(tasks[0].id, sessionId: repository.sessionId);
    final retained = await repository.saveTextLayer(
      TextLayerDraft(
        revisionId: document.activeRevisionId,
        pageIndex: 0,
        source: TextLayerSource.nativePdf,
        text: '迟到的原生文字',
        fragments: const [],
        engineVersion: 'pdfium',
      ),
      sessionId: repository.sessionId,
      ocrTaskId: tasks[0].id,
    );
    expect(retained.id, original.id);
    expect(
      (await repository.listOcrTasks())
          .firstWhere((t) => t.id == tasks[0].id)
          .status,
      OcrTaskStatus.completed,
    );
    final forced = await repository.enqueueOcr(
      document.activeRevisionId,
      [0],
      modelVersion: 'model-v1',
      force: true,
    );
    expect(forced.single.status, OcrTaskStatus.queued);
    expect(forced.single.sessionId, isNull);
    expect(
      (await repository.loadTextLayers(document.activeRevisionId)).single.id,
      original.id,
    );
    await repository.claimOcrTask(tasks[0].id, sessionId: repository.sessionId);
    expect(
      (await repository.enqueueOcr(
        document.activeRevisionId,
        [0],
        modelVersion: 'model-v1',
        force: true,
      )).single.status,
      OcrTaskStatus.running,
    );
    await repository.saveTextLayer(
      TextLayerDraft(
        revisionId: document.activeRevisionId,
        pageIndex: 0,
        source: TextLayerSource.ocr,
        text: '新的 OCR 层',
        fragments: const [],
        engineVersion: 'model-v2',
      ),
      sessionId: repository.sessionId,
      ocrTaskId: tasks[0].id,
    );
    await repository.claimOcrTask(tasks[1].id, sessionId: repository.sessionId);
    await repository.saveTextLayer(
      TextLayerDraft(
        revisionId: document.activeRevisionId,
        pageIndex: 1,
        source: TextLayerSource.nativePdf,
        text: 'Native',
        engineVersion: 'pdfium',
        fragments: [
          TextFragment(
            start: 0,
            length: 6,
            quad: PdfQuad.rect(0, 0, 60, 12),
            order: 0,
            precision: GeometryPrecision.character,
          ),
        ],
      ),
      sessionId: repository.sessionId,
      ocrTaskId: tasks[1].id,
    );
    expect(
      await repository.reusableTextPages(
        document.activeRevisionId,
        ocrEngineVersion: 'model-v2',
      ),
      {0, 1},
    );
    expect(
      await repository.reusableTextPages(
        document.activeRevisionId,
        ocrEngineVersion: 'other-model',
      ),
      {1},
    );
    expect(
      (await repository.loadTextLayers(
        document.activeRevisionId,
        pageIndex: 0,
        currentOnly: false,
      )).length,
      2,
    );
    expect(
      (await repository.listOcrTasks()).every(
        (t) => t.status == OcrTaskStatus.completed,
      ),
      isTrue,
    );
  });

  test('永久清理拒绝正常与回收卡片回源引用，独立备份不占用活动资源', () async {
    final result = await excerpt(
      '回源卡片',
      anchors: [
        AnchorDraft(
          revisionId: document.activeRevisionId,
          pageIndex: 0,
          quads: [PdfQuad.rect(10, 10, 30, 30)],
        ),
      ],
    );
    final revision = await repository.getRevision(document.activeRevisionId);
    final resourceFile = File(
      await repository.resourcePath(revision.resourceId),
    );
    await repository.trashDocument(document.id);
    final docTrash = (await repository.listTrash()).single;
    expect(
      (await repository.previewTrashPurge(
        docTrash.id,
        discardSessionHistory: true,
      )).canPurge,
      isFalse,
    );
    await expectLater(
      repository.purgeTrash(docTrash.id, discardSessionHistory: true),
      throwsA(
        isA<RepositoryException>().having(
          (e) => e.code,
          'code',
          RepositoryError.referenced,
        ),
      ),
    );
    await repository.trashCard(result.card.id);
    expect(
      (await repository.previewTrashPurge(
        docTrash.id,
        discardSessionHistory: true,
      )).canPurge,
      isFalse,
    );
    final backup = p.join(temp.path, '永久清理前完整备份.opennote');
    await repository.backupTo(backup);
    final cardTrash = (await repository.listTrash()).firstWhere(
      (t) => t.kind == TrashKind.card,
    );
    final defaultPreview = await repository.previewTrashPurge(cardTrash.id);
    expect(defaultPreview.canPurge, isFalse);
    expect(defaultPreview.blockers.join(), contains('撤销'));
    await repository.purgeTrash(cardTrash.id, discardSessionHistory: true);
    expect(repository.canUndo, isFalse);
    expect(repository.canRedo, isFalse);
    final preview = await repository.previewTrashPurge(docTrash.id);
    expect(preview.canPurge, isTrue);
    expect(preview.resourceCount, 1);
    expect(preview.reclaimableBytes, greaterThan(0));
    final purged = await repository.purgeTrash(docTrash.id);
    expect(purged.pendingResourcePaths, isEmpty);
    expect(await resourceFile.exists(), isFalse);
    final portable = await OpenNoteRepository.open(
      rootPath: p.join(temp.path, 'portable'),
    );
    try {
      await portable.restoreFrom(backup);
      final restored = await portable.getRevision(document.activeRevisionId);
      expect(
        await File(await portable.resourcePath(restored.resourceId)).exists(),
        isTrue,
      );
      expect(
        (await portable.getAnchors(result.card.id)).single.revisionId,
        restored.id,
      );
      expect((await portable.listTrash()).length, 2);
    } finally {
      await portable.close();
    }
  });

  test('永久清理脑图保留卡片并修复回收站恢复所需的旧节点记录', () async {
    final parent = await excerpt('父卡片');
    final child = await excerpt('回收子卡片', parent: parent.node.id);
    final aliveChild = await excerpt('存活孙卡片', parent: child.node.id);
    await repository.trashCard(child.card.id);
    await repository.trashMap(map.id);
    final entries = await repository.listTrash();
    final mapTrash = entries.firstWhere((t) => t.kind == TrashKind.map);
    final result = await repository.purgeTrash(
      mapTrash.id,
      discardSessionHistory: true,
    );
    expect(result.mapCount, 1);
    expect(result.cardCount, 0);
    expect(
      (await repository.listCards(project.id, includeDeleted: true)).length,
      3,
    );
    await repository.restoreTrash(
      entries.firstWhere((t) => t.kind == TrashKind.card).id,
    );
    expect((await repository.getCard(child.card.id)).deletedAt, isNull);
    final newMap = await repository.createMap(project.id, '新脑图');
    await repository.placeCard(child.card.id, newMap.id);
    await repository.placeCard(aliveChild.card.id, newMap.id);
    expect((await repository.loadMap(newMap.id)).nodes.length, 2);
    final backup = p.join(temp.path, '清理脑图后.opennote');
    await repository.backupTo(backup);
    await repository.restoreFrom(backup);
    expect((await repository.loadMap(newMap.id)).nodes.length, 2);
  });

  test('永久清理项目只删除自己的逻辑实体，跨项目共享原文件保留', () async {
    final source = await excerpt(
      '跨项目卡片',
      anchors: [
        AnchorDraft(
          revisionId: document.activeRevisionId,
          pageIndex: 0,
          quads: [PdfQuad.rect(0, 0, 30, 12)],
        ),
      ],
    );
    final target = await repository.createProject('目标项目');
    final targetMap = (await repository.listMaps(target.id)).single;
    final copy = await repository.copyBranch(source.node.id, targetMap.id);
    final copyAnchor = (await repository.getAnchors(
      copy.cardIds[source.card.id]!,
    )).single;
    final copyRevision = await repository.getRevision(copyAnchor.revisionId);
    final sharedFile = File(
      await repository.resourcePath(copyRevision.resourceId),
    );
    await repository.trashCard(source.card.id);
    await repository.trashProject(project.id);
    final entry = (await repository.listTrash()).firstWhere(
      (t) => t.kind == TrashKind.project,
    );
    final preview = await repository.previewTrashPurge(
      entry.id,
      discardSessionHistory: true,
    );
    expect(preview.canPurge, isTrue);
    expect(preview.resourceCount, 0);
    await repository.purgeTrash(entry.id, discardSessionHistory: true);
    expect((await repository.listProjects()).single.id, target.id);
    expect(await repository.listTrash(), isEmpty);
    expect(await sharedFile.exists(), isTrue);
    expect(
      (await repository.getAnchors(copy.cardIds[source.card.id]!))
          .single
          .revisionId,
      copyRevision.id,
    );
    final backup = p.join(temp.path, '清理项目后.opennote');
    await repository.backupTo(backup);
    await repository.restoreFrom(backup);
    expect(
      (await repository.loadMap(targetMap.id)).nodes.single.id,
      copy.rootNodeId,
    );
  });

  test('摘录事务中断遗留的托管图片可重试回收，存活原 PDF 不受影响', () async {
    final revision = await repository.getRevision(document.activeRevisionId);
    final source = File(await repository.resourcePath(revision.resourceId));
    final resourceDirectory = Directory(
      p.join(repository.libraryPath, 'resources'),
    );
    await expectLater(
      repository.createExcerpt(
        ExcerptDraft(
          projectId: project.id,
          mapId: map.id,
          title: '无效图片摘录',
          text: '',
          imageBytes: Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10]),
          anchors: [
            AnchorDraft(
              revisionId: 'missing',
              pageIndex: 0,
              quads: [PdfQuad.rect(0, 0, 10, 10)],
            ),
          ],
        ),
      ),
      throwsA(isA<RepositoryException>()),
    );
    expect(await resourceDirectory.list().length, 2);
    expect(await repository.retryResourceCleanup(), isEmpty);
    expect(await resourceDirectory.list().length, 1);
    expect(await source.exists(), isTrue);
    expect(await repository.listCards(project.id), isEmpty);
  });

  test('撤销图片摘录后资源仍供重做使用，资源回收不会删掉历史引用', () async {
    final result = await repository.createExcerpt(
      ExcerptDraft(
        projectId: project.id,
        mapId: map.id,
        title: '图片摘录',
        text: '',
        imageBytes: Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10]),
      ),
    );
    final resourceId = result.card.imageResourceId!;
    final image = File(await repository.resourcePath(resourceId));
    await repository.undo();
    expect(await repository.listCards(project.id), isEmpty);
    expect(await repository.retryResourceCleanup(), isEmpty);
    expect(await image.exists(), isTrue);
    await repository.redo();
    expect(
      (await repository.getCard(result.card.id)).imageResourceId,
      resourceId,
    );
    expect(await repository.resourcePath(resourceId), image.path);
    expect(await image.exists(), isTrue);
  });

  test('容量基线：5000 张卡片、500 个节点、1000 页文档可读取搜索', () async {
    final pdf = File(p.join(temp.path, '1000页.pdf'));
    await pdf.writeAsBytes(_pdfBytes(1000));
    final longDoc = await repository.importPdf(
      projectId: project.id,
      filePath: pdf.path,
      pageCount: 1000,
    );
    final databasePath = p.join(repository.libraryPath, 'library.sqlite');
    await repository.close();
    final db = sqlite3.open(databasePath);
    try {
      db.execute('PRAGMA foreign_keys=ON');
      db.execute('BEGIN');
      final card = db.prepare(
        'INSERT INTO cards(id,project_id,title,excerpt_snapshot,body,note,color,updated_at) VALUES(?,?,?,?,?,?,?,?)',
      );
      final node = db.prepare(
        'INSERT INTO nodes(id,map_id,card_id,x,y,width,height,collapsed) VALUES(?,?,?,?,?,?,?,?)',
      );
      try {
        for (var i = 0; i < 5000; i++) {
          card.execute([
            'card-$i',
            project.id,
            '卡片$i',
            '',
            '第$i张中文印刷书知识摘录',
            '',
            '#F7D976',
            i,
          ]);
          if (i < 500) {
            node.execute([
              'node-$i',
              map.id,
              'card-$i',
              i.toDouble(),
              0.0,
              220.0,
              116.0,
              0,
            ]);
          }
        }
      } finally {
        card.close();
        node.close();
      }
      db.execute('COMMIT');
    } finally {
      db.close();
    }
    repository = await OpenNoteRepository.open(
      rootPath: p.join(temp.path, 'library'),
    );
    expect((await repository.listCards(project.id)).length, 5000);
    expect((await repository.loadMap(map.id)).nodes.length, 500);
    expect(
      (await repository.getRevision(longDoc.activeRevisionId)).pageCount,
      1000,
    );
    expect((await repository.search(project.id, '中文', limit: 20)).length, 20);
  }, timeout: const Timeout(Duration(minutes: 2)));
}

List<int> _pdfBytes(int pages) {
  final objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Count $pages /Kids [${List.generate(pages, (i) => '${i + 3} 0 R').join(' ')}] >>',
    ...List.generate(
      pages,
      (_) => '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << >> >>',
    ),
  ];
  final content = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[0];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(content.length);
    content.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xref = content.length;
  content.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
  for (final offset in offsets.skip(1)) {
    content.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  content.write(
    'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF',
  );
  return ascii.encode(content.toString());
}
