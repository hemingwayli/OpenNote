import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opennote/data/open_note_repository.dart';
import 'package:opennote/domain/models.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late OpenNoteRepository repo;
  late StudyProject project;
  late MindMap map;
  late ManagedDocument document;
  late AnchorDraft anchor;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('opennote-source-trash-');
    repo = await OpenNoteRepository.open(rootPath: '${temp.path}/library');
    project = await repo.createProject('删除关联测试');
    map = (await repo.listMaps(project.id)).single;
    document = await repo.importPdf(
      projectId: project.id,
      filePath: File('tools/fixtures/pdf/native.pdf').absolute.path,
      pageCount: 2,
    );
    anchor = AnchorDraft(
      revisionId: document.activeRevisionId,
      pageIndex: 0,
      quads: [PdfQuad.rect(20, 100, 180, 120)],
    );
  });
  tearDown(() async {
    await repo.close();
    await temp.delete(recursive: true);
  });
  Future<ExcerptResult> card(String title, {String? parent}) =>
      repo.createExcerpt(
        ExcerptDraft(
          projectId: project.id,
          mapId: map.id,
          title: title,
          text: title,
          parentNodeId: parent,
          anchors: [anchor],
        ),
      );

  test('回收关联：重叠分支与折叠后代一次撤销，独立批注和副本保留', () async {
    final root = await card('父卡');
    final child = await card('子卡', parent: root.node.id);
    final grandchild = await card('孙卡', parent: child.node.id);
    final outside = await card('外部卡');
    final target = await repo.createMap(project.id, '独立副本');
    await repo.copyBranch(root.node.id, target.id);
    await repo.createAnnotation(anchor: anchor);
    await repo.setNodeCollapsed(root.node.id, true);
    final before = await repo.loadMap(map.id);
    final annotations = await repo.listAnnotations(document.activeRevisionId);
    final history = repo.undoEntryCount;
    final deleted = await repo.trashMapTopics(map.id, [
      root.node.id,
      child.node.id,
      root.node.id,
    ]);
    expect(deleted, {root.card.id, child.card.id, grandchild.card.id});
    expect(repo.undoEntryCount, history + 1);
    expect((await repo.loadMap(map.id)).nodes.map((n) => n.id), [
      outside.node.id,
    ]);
    expect(await repo.listTrash(projectId: project.id), hasLength(3));
    expect(
      await repo.listAnnotations(document.activeRevisionId),
      hasLength(annotations.length - 3),
    );
    await repo.undo();
    final restored = await repo.loadMap(map.id);
    expect(
      restored.nodes.map((n) => [n.id, n.parentNodeId, n.x, n.y, n.collapsed]),
      before.nodes.map((n) => [n.id, n.parentNodeId, n.x, n.y, n.collapsed]),
    );
    expect(
      await repo.listAnnotations(document.activeRevisionId),
      hasLength(annotations.length),
    );
    await repo.redo();
    expect(
      await repo.listAnnotations(document.activeRevisionId),
      hasLength(annotations.length - 3),
    );
  });

  test('回收关联：仅当前主题提升子主题并保留结构顺序，回收站可恢复标注', () async {
    await repo.setMapLayout(map.id, MapLayoutKind.right);
    final root = await card('父卡');
    final a = await card('第一子卡', parent: root.node.id);
    final b = await card('第二子卡', parent: root.node.id);
    final c = await card('后续同级');
    final before = await repo.loadMap(map.id);
    final deleted = await repo.trashMapTopics(map.id, [
      root.node.id,
    ], includeDescendants: false);
    expect(deleted, {root.card.id});
    final after = await repo.loadMap(map.id);
    final nodes = after.nodes.toList()..sort(compareMapNodes);
    expect(nodes.map((n) => n.id), [a.node.id, b.node.id, c.node.id]);
    expect(nodes.every((n) => n.parentNodeId == null), isTrue);
    expect(await repo.listAnnotations(document.activeRevisionId), hasLength(3));
    await repo.undo();
    expect(
      (await repo.loadMap(map.id)).nodes
          .map((n) => [n.id, n.parentNodeId, n.sortIndex]),
      before.nodes.map((n) => [n.id, n.parentNodeId, n.sortIndex]),
    );
    await repo.redo();
    await repo.restoreTrash(
      (await repo.listTrash(projectId: project.id)).single.id,
    );
    expect(await repo.listAnnotations(document.activeRevisionId), hasLength(4));
    expect(
      (await repo.loadMap(map.id)).nodes
          .singleWhere((n) => n.id == a.node.id)
          .parentNodeId,
      root.node.id,
    );
  });

  test('回收关联：目标失效整批回滚，历史孤立卡片不回收且黄标隐藏', () async {
    final a = await card('旧摘录');
    final b = await card('保留摘录');
    await repo.createAnnotation(anchor: anchor);
    final history = repo.undoEntryCount;
    await expectLater(
      repo.trashMapTopics(map.id, [a.node.id, 'missing']),
      throwsA(isA<RepositoryException>()),
    );
    expect(repo.undoEntryCount, history);
    expect(await repo.listCards(project.id), hasLength(2));
    await repo.removeBranch(a.node.id);
    expect(await repo.listCards(project.id), hasLength(2));
    expect(await repo.listTrash(projectId: project.id), isEmpty);
    final visible = await repo.listAnnotations(document.activeRevisionId);
    expect(visible, hasLength(2));
    expect(visible.where((a) => a.cardId != null).single.cardId, b.card.id);
    await repo.undo();
    expect(await repo.listAnnotations(document.activeRevisionId), hasLength(3));
    await repo.trashMap(map.id);
    expect(await repo.listAnnotations(document.activeRevisionId), hasLength(1));
  });

  test('回收关联：事务中途写入失败不留下半批删除或撤销记录', () async {
    final a = await card('第一卡');
    final b = await card('第二卡');
    final history = repo.undoEntryCount;
    final db = sqlite.sqlite3.open('${repo.libraryPath}/library.sqlite');
    try {
      db.execute(
        "CREATE TRIGGER fail_card_trash BEFORE UPDATE ON cards WHEN NEW.id='${b.card.id}' AND NEW.deleted_at IS NOT NULL BEGIN SELECT RAISE(ABORT,'fixture write failure'); END",
      );
      await expectLater(
        repo.trashMapTopics(map.id, [a.node.id, b.node.id]),
        throwsA(anything),
      );
      expect(await repo.listCards(project.id), hasLength(2));
      expect((await repo.loadMap(map.id)).nodes, hasLength(2));
      expect(
        await repo.listAnnotations(document.activeRevisionId),
        hasLength(2),
      );
      expect(await repo.listTrash(projectId: project.id), isEmpty);
      expect(repo.undoEntryCount, history);
    } finally {
      db.execute('DROP TRIGGER fail_card_trash');
      db.close();
    }
  });

  test('回收关联：备份恢复保留回收卡片来源及批注，随后恢复卡片重新显示', () async {
    final source = await card('待恢复卡片');
    await repo.trashMapTopics(map.id, [source.node.id]);
    final backup = '${temp.path}/source-link.onbackup';
    await repo.backupTo(backup);
    await repo.restoreFrom(backup);
    expect(await repo.listAnnotations(document.activeRevisionId), isEmpty);
    await repo.restoreTrash(
      (await repo.listTrash(projectId: project.id)).single.id,
    );
    expect(await repo.getAnchors(source.card.id), hasLength(1));
    expect(await repo.listAnnotations(document.activeRevisionId), hasLength(1));
    expect((await repo.loadMap(map.id)).nodes.single.id, source.node.id);
  });
}
