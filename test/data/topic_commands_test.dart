import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:opennote/data/open_note_repository.dart';
import 'package:opennote/domain/map_clipboard.dart';
import 'package:opennote/domain/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late OpenNoteRepository repo;
  late StudyProject project;
  late MindMap map;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('opennote-topics-');
    repo = await OpenNoteRepository.open(rootPath: '${temp.path}/library');
    project = await repo.createProject('键盘脑图');
    map = (await repo.listMaps(project.id)).single;
    await repo.setMapLayout(map.id, MapLayoutKind.free);
    map = (await repo.loadMap(map.id)).map;
  });
  tearDown(() async {
    await repo.close();
    await temp.delete(recursive: true);
  });
  Future<ExcerptResult> topic(String title, {String? parent, double y = 0}) =>
      repo.createExcerpt(
        ExcerptDraft(
          projectId: project.id,
          mapId: map.id,
          title: title,
          text: '$title 正文',
          note: '个人备注',
          parentNodeId: parent,
          x: parent == null ? 80 : 370,
          y: y,
        ),
      );

  test('快速插入：同级前后让整条分支让位，含隐藏后代并一次撤销', () async {
    final root = await topic('根');
    final a = await topic('A', parent: root.node.id, y: 0);
    final child = await topic('A 子', parent: a.node.id, y: 140);
    final b = await topic('B', parent: root.node.id, y: 280);
    await repo.setNodeCollapsed(a.node.id, true);
    final before = await repo.loadMap(map.id);
    final history = repo.undoEntryCount;
    final inserted = await repo.insertTopic(
      a.node.id,
      TopicInsertKind.siblingAfter,
    );
    var after = await repo.loadMap(map.id);
    expect(inserted.node.parentNodeId, root.node.id);
    expect(inserted.node.y, greaterThan(child.node.y + child.node.height));
    expect(
      after.nodes.firstWhere((n) => n.id == b.node.id).y,
      greaterThan(inserted.node.y + inserted.node.height),
    );
    expect(inserted.card.body, isEmpty);
    expect(inserted.card.note, isEmpty);
    expect(repo.undoEntryCount, history + 1);
    await repo.undo();
    expect(_geometry(await repo.loadMap(map.id)), _geometry(before));
    await repo.redo();
    expect(_geometry(await repo.loadMap(map.id)), _geometry(after));
    final previous = await repo.insertTopic(
      a.node.id,
      TopicInsertKind.siblingBefore,
    );
    after = await repo.loadMap(map.id);
    expect(
      previous.node.y,
      lessThan(after.nodes.firstWhere((n) => n.id == a.node.id).y),
    );
    expect(
      after.nodes.firstWhere((n) => n.id == child.node.id).parentNodeId,
      a.node.id,
    );
  });

  test('上层主题及仅删当前主题保留子树、卡片和一次撤销', () async {
    final root = await topic('根');
    final child = await topic('子', parent: root.node.id, y: 140);
    final leaf = await topic('孙', parent: child.node.id, y: 280);
    final edge = await repo.addAssociation(child.node.id, leaf.node.id);
    final before = await repo.loadMap(map.id);
    final upper = await repo.insertTopic(child.node.id, TopicInsertKind.parent);
    var now = await repo.loadMap(map.id);
    expect(upper.node.parentNodeId, root.node.id);
    expect(
      now.nodes.firstWhere((n) => n.id == child.node.id).parentNodeId,
      upper.node.id,
    );
    expect(
      now.nodes.firstWhere((n) => n.id == leaf.node.id).x -
          now.nodes.firstWhere((n) => n.id == child.node.id).x,
      leaf.node.x - child.node.x,
    );
    await repo.undo();
    expect(_geometry(await repo.loadMap(map.id)), _geometry(before));
    final history = repo.undoEntryCount;
    await repo.removeTopicOnly(child.node.id);
    now = await repo.loadMap(map.id);
    expect(now.nodes.any((n) => n.id == child.node.id), isFalse);
    expect(
      now.nodes.firstWhere((n) => n.id == leaf.node.id).parentNodeId,
      root.node.id,
    );
    expect((await repo.getCard(child.card.id)).body, child.card.body);
    expect(now.edges.any((e) => e.id == edge.id), isFalse);
    expect(repo.undoEntryCount, history + 1);
    await repo.undo();
    expect(_geometry(await repo.loadMap(map.id)), _geometry(before));
  });

  test('同级排序移动整个分支，保持后代相对坐标并可撤销', () async {
    final root = await topic('根');
    final a = await topic('A', parent: root.node.id, y: 0);
    final leaf = await topic('子', parent: a.node.id, y: 140);
    final b = await topic('B', parent: root.node.id, y: 280);
    final before = await repo.loadMap(map.id);
    await repo.reorderTopic(b.node.id, before: true);
    final after = await repo.loadMap(map.id);
    final byId = {for (final n in after.nodes) n.id: n};
    expect(byId[b.node.id]!.y, lessThan(byId[a.node.id]!.y));
    expect(byId[leaf.node.id]!.y - byId[a.node.id]!.y, 140);
    expect(byId[leaf.node.id]!.parentNodeId, a.node.id);
    await repo.undo();
    expect(_geometry(await repo.loadMap(map.id)), _geometry(before));
  });

  test('复制粘贴捕获旧正文与备注，父子去重并保留内部关联和独立身份', () async {
    final root = await topic('根');
    final child = await topic('子', parent: root.node.id, y: 140);
    final outside = await topic('外', y: 500);
    await repo.addAssociation(root.node.id, child.node.id);
    await repo.addAssociation(child.node.id, outside.node.id);
    final clipboard = MapClipboardContent.capture(await repo.loadMap(map.id), {
      root.node.id,
      child.node.id,
    });
    expect(clipboard.rootIds, [root.node.id]);
    expect(clipboard.text, '根\n\t子');
    await repo.updateCard(root.card.id, body: '原卡后来修改', note: '后来备注');
    final history = repo.undoEntryCount;
    final roots = await repo.pasteTopicCopy(
      clipboard,
      map.id,
      parentNodeId: outside.node.id,
    );
    var after = await repo.loadMap(map.id);
    final copyRoot = roots.single;
    final copyChild = after.nodes.singleWhere(
      (n) => n.parentNodeId == copyRoot.id,
    );
    expect(copyRoot.cardId, isNot(root.card.id));
    expect(after.cards[copyRoot.cardId]!.body, '根 正文');
    expect(after.cards[copyRoot.cardId]!.note, '个人备注');
    expect(copyRoot.parentNodeId, outside.node.id);
    expect(
      after.edges.where(
        (e) => e.fromNodeId == copyRoot.id || e.toNodeId == copyRoot.id,
      ),
      hasLength(1),
    );
    expect(
      after.edges.any(
        (e) =>
            e.fromNodeId == outside.node.id && e.toNodeId == copyChild.id ||
            e.toNodeId == outside.node.id && e.fromNodeId == copyChild.id,
      ),
      isFalse,
    );
    expect(repo.undoEntryCount, history + 1);
    await repo.updateCard(copyRoot.cardId, body: '独立修改');
    expect((await repo.getCard(root.card.id)).body, '原卡后来修改');
    await repo.undo();
    await repo.undo();
    after = await repo.loadMap(map.id);
    expect(after.nodes, hasLength(3));
    expect((await repo.listCards(project.id)), hasLength(3));
  });

  test('剪切移动保留身份及内部关联，循环和陈旧结构均不改原数据', () async {
    final root = await topic('根');
    final child = await topic('子', parent: root.node.id, y: 140);
    await repo.addAssociation(root.node.id, child.node.id);
    final content = MapClipboardContent.capture(await repo.loadMap(map.id), {
      root.node.id,
    });
    final before = await repo.loadMap(map.id);
    final history = repo.undoEntryCount;
    await expectLater(
      repo.pasteTopicMove(content, map.id, parentNodeId: child.node.id),
      throwsA(isA<RepositoryException>()),
    );
    expect(repo.undoEntryCount, history);
    expect(_geometry(await repo.loadMap(map.id)), _geometry(before));
    final target = await repo.createMap(project.id, '另一脑图');
    await repo.pasteTopicMove(content, target.id);
    expect((await repo.loadMap(map.id)).nodes, isEmpty);
    final moved = await repo.loadMap(target.id);
    expect(moved.nodes.map((n) => n.id).toSet(), {root.node.id, child.node.id});
    expect(moved.edges, hasLength(1));
    await repo.undo();
    expect(_geometry(await repo.loadMap(map.id)), _geometry(before));
    await topic('后来增加', parent: child.node.id, y: 280);
    final beforeFailure = repo.undoEntryCount;
    await expectLater(
      repo.pasteTopicMove(content, target.id),
      throwsA(isA<RepositoryException>()),
    );
    expect(repo.undoEntryCount, beforeFailure);
    expect((await repo.loadMap(map.id)).nodes, hasLength(3));
    expect((await repo.loadMap(target.id)).nodes, isEmpty);
  });

  test('文本大纲一次粘贴建立层级，错误缩进事务回滚且不产生撤销', () async {
    final lines = parseTopicOutline('根一\r\n\t子一\n\t\t孙一\n根二\n    - 子二');
    expect(lines.map((l) => l.depth), [0, 1, 2, 0, 1]);
    final history = repo.undoEntryCount;
    final roots = await repo.pasteTopicOutline(map.id, lines);
    expect(roots, hasLength(2));
    final snapshot = await repo.loadMap(map.id);
    final byTitle = {
      for (final n in snapshot.nodes) snapshot.cards[n.cardId]!.title: n,
    };
    expect(byTitle['孙一']!.parentNodeId, byTitle['子一']!.id);
    expect(byTitle['子二']!.parentNodeId, byTitle['根二']!.id);
    expect(repo.undoEntryCount, history + 1);
    await repo.undo();
    expect((await repo.loadMap(map.id)).nodes, isEmpty);
    expect(await repo.listCards(project.id), isEmpty);
    final failureHistory = repo.undoEntryCount;
    await expectLater(
      repo.pasteTopicOutline(map.id, [
        const TopicTextLine('根', 0),
        const TopicTextLine('错误', 3),
      ]),
      throwsA(isA<RepositoryException>()),
    );
    expect(repo.undoEntryCount, failureHistory);
    expect(await repo.listCards(project.id), isEmpty);
    expect(() => parseTopicOutline('根\n\t\t跳级'), throwsFormatException);
  });

  test('复制到其他项目保留 PDF 来源，重新生成文档与锚点身份', () async {
    final file = File('${temp.path}/source.pdf');
    await file.writeAsString('%PDF-1.7\n% fixture\n', encoding: utf8);
    final doc = await repo.importPdf(
      projectId: project.id,
      filePath: file.path,
      pageCount: 1,
    );
    final original = await repo.createExcerpt(
      ExcerptDraft(
        projectId: project.id,
        mapId: map.id,
        title: '原文摘录',
        text: '不可变原文',
        anchors: [
          AnchorDraft(
            revisionId: doc.activeRevisionId,
            pageIndex: 0,
            quads: [PdfQuad.rect(10, 10, 80, 20)],
            context: '上下文',
          ),
        ],
        createHighlight: false,
      ),
    );
    final copy = MapClipboardContent.capture(await repo.loadMap(map.id), {
      original.node.id,
    });
    final target = await repo.createProject('跨项目');
    final targetMap = (await repo.listMaps(target.id)).single;
    final pasted = (await repo.pasteTopicCopy(copy, targetMap.id)).single;
    final anchors = await repo.getAnchors(pasted.cardId);
    expect(anchors.single.revisionId, isNot(doc.activeRevisionId));
    expect(anchors.single.context, '上下文');
    expect(
      anchors.single.quads.single.toJson(),
      PdfQuad.rect(10, 10, 80, 20).toJson(),
    );
    final copiedDocs = await repo.listDocuments(target.id);
    expect(copiedDocs, hasLength(1));
    expect(
      (await repo.getRevision(copiedDocs.single.activeRevisionId)).resourceId,
      (await repo.getRevision(doc.activeRevisionId)).resourceId,
    );
    expect((await repo.getCard(pasted.cardId)).excerptSnapshot, '不可变原文');
  });
}

Map<String, (String?, double, double)> _geometry(MapSnapshot map) => {
  for (final node in map.nodes) node.id: (node.parentNodeId, node.x, node.y),
};
