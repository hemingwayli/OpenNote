import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:opennote/data/open_note_repository.dart';
import 'package:opennote/domain/models.dart';
import 'package:opennote/domain/map_clipboard.dart';
import 'package:opennote/domain/summary_geometry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late OpenNoteRepository repo;
  late StudyProject project;
  late MindMap map;
  var next = 0;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('opennote-summary-');
    repo = await OpenNoteRepository.open(rootPath: '${temp.path}/library');
    project = await repo.createProject('概要');
    map = (await repo.listMaps(project.id)).single;
    next = 0;
  });
  tearDown(() async {
    await repo.close();
    await temp.delete(recursive: true);
  });
  Future<ExcerptResult> topic(String title, {String? parent}) =>
      repo.createExcerpt(
        ExcerptDraft(
          projectId: project.id,
          mapId: map.id,
          title: title,
          text: '正文 $title',
          parentNodeId: parent,
          x: 80,
          y: next++ * 180.0,
        ),
      );
  test('同级连续范围及跨分支概要独立卡片，批量一次撤销；新增子主题自动布局', () async {
    final root = await topic('根'), other = await topic('另一根');
    final a = await topic('甲', parent: root.node.id),
        b = await topic('乙', parent: root.node.id),
        c = await topic('丙', parent: root.node.id),
        d = await topic('丁', parent: other.node.id);
    await repo.setMapLayout(map.id, MapLayoutKind.right);
    final count = repo.undoEntryCount;
    final selected = {a.node.id, c.node.id, d.node.id};
    final pending = repo.createSummaries(map.id, selected);
    selected.clear();
    final created = await pending;
    expect(created, hasLength(2));
    expect(repo.undoEntryCount, count + 1);
    var snapshot = await repo.loadMap(map.id);
    final summary = snapshot.summaries.singleWhere(
      (s) => s.parentNodeId == root.node.id,
    );
    expect(summary.nodeIds.toSet(), {a.node.id, b.node.id, c.node.id});
    final summaryNode = snapshot.nodes.singleWhere(
      (n) => n.id == summary.summaryNodeId,
    );
    expect(snapshot.cards[summaryNode.cardId]!.title, '概要');
    final r = snapshot.nodes.singleWhere((n) => n.id == root.node.id);
    expect(r.x, 80);
    expect(r.y, 0);
    await repo.undo();
    expect((await repo.loadMap(map.id)).summaries, isEmpty);
    expect((await repo.loadMap(map.id)).nodes, hasLength(6));
    await repo.redo();
    final child = await repo.insertTopic(summaryNode.id, TopicInsertKind.child);
    snapshot = await repo.loadMap(map.id);
    final childNode = snapshot.nodes.singleWhere((n) => n.id == child.node.id);
    expect(childNode.parentNodeId, summaryNode.id);
    expect(childNode.x, greaterThan(summaryNode.x));
    await repo.updateCard(summaryNode.cardId, title: '中文概要');
    expect(
      (await repo.loadMap(map.id)).cards[summaryNode.cardId]!.title,
      '中文概要',
    );
  });
  test('样式和范围原子保存，陈旧范围和非法输入拒绝，无变化保留重做', () async {
    final root = await topic('根'),
        a = await topic('甲', parent: root.node.id),
        b = await topic('乙', parent: root.node.id);
    await repo.createSummaries(map.id, {a.node.id});
    final s = (await repo.loadMap(map.id)).summaries.single;
    final count = repo.undoEntryCount;
    await repo.updateSummary(
      s.id,
      nodeIds: [a.node.id, b.node.id],
      style: const SummaryStyle(bracket: SummaryBracket.square, dashed: true),
      expectedNodeIds: s.nodeIds,
    );
    expect(repo.undoEntryCount, count + 1);
    await expectLater(
      repo.updateSummary(s.id, nodeIds: [root.node.id]),
      throwsA(anything),
    );
    await expectLater(
      repo.updateSummary(s.id, style: const SummaryStyle(width: double.nan)),
      throwsA(anything),
    );
    await expectLater(
      repo.updateSummary(s.id, expectedNodeIds: s.nodeIds),
      throwsA(anything),
    );
    await expectLater(
      repo.updateSummary(s.id, nodeIds: [s.summaryNodeId]),
      throwsA(anything),
    );
    await repo.undo();
    expect(repo.canRedo, isTrue);
    await repo.updateSummary(
      s.id,
      style: const SummaryStyle(),
      nodeIds: s.nodeIds,
    );
    expect(repo.canRedo, isTrue);
  });
  test('复制范围自动包含概要及子主题；独立卡片、身份映射和一次撤销', () async {
    final root = await topic('根'),
        a = await topic('甲', parent: root.node.id),
        b = await topic('乙', parent: root.node.id);
    final node = (await repo.createSummaries(map.id, {
      a.node.id,
      b.node.id,
    })).single;
    final child = await topic('概要子主题', parent: node);
    final content = MapClipboardContent.capture(await repo.loadMap(map.id), {
      a.node.id,
      b.node.id,
    });
    expect(content.snapshot.nodes.map((n) => n.id).toSet(), {
      a.node.id,
      b.node.id,
      node,
      child.node.id,
    });
    expect(content.snapshot.summaries, hasLength(1));
    expect(content.rootIds, hasLength(3));
    final target = await repo.createMap(project.id, '目标');
    final targetParent = await repo.createExcerpt(
      ExcerptDraft(
        projectId: project.id,
        mapId: target.id,
        title: '目标根',
        text: '',
      ),
    );
    final count = repo.undoEntryCount;
    await repo.pasteTopicCopy(
      content,
      target.id,
      parentNodeId: targetParent.node.id,
    );
    final copied = await repo.loadMap(target.id), s = copied.summaries.single;
    expect(s.summaryNodeId, isNot(node));
    expect(s.nodeIds.toSet().intersection({a.node.id, b.node.id}), isEmpty);
    expect(copied.cards.values.any((c) => c.id == child.card.id), isFalse);
    expect(repo.undoEntryCount, count + 1);
    await repo.undo();
    expect((await repo.loadMap(target.id)).nodes, hasLength(1));
    final direct = await repo.copyBranch(
      root.node.id,
      target.id,
      parentNodeId: targetParent.node.id,
    );
    expect(direct.nodeIds.containsKey(node), isTrue);
    expect((await repo.loadMap(target.id)).summaries, hasLength(1));
  });
  test('整组剪切或整分支移图保留概要身份，部分重挂收缩范围，删除及撤销引用合法', () async {
    final root = await topic('根'), other = await topic('另一根');
    final a = await topic('甲', parent: root.node.id),
        b = await topic('乙', parent: root.node.id);
    final node = (await repo.createSummaries(map.id, {
      a.node.id,
      b.node.id,
    })).single;
    final original = (await repo.loadMap(map.id)).summaries.single;
    await repo.reparentNode(b.node.id, other.node.id);
    expect((await repo.loadMap(map.id)).summaries.single.nodeIds, [a.node.id]);
    await repo.undo();
    final target = await repo.createMap(project.id, '移动目标');
    await repo.moveBranchToMap(root.node.id, target.id);
    expect((await repo.loadMap(map.id)).summaries, isEmpty);
    expect((await repo.loadMap(target.id)).summaries.single.id, original.id);
    await repo.undo();
    final content = MapClipboardContent.capture(await repo.loadMap(map.id), {
      a.node.id,
      b.node.id,
    });
    await repo.pasteTopicMove(content, map.id, parentNodeId: other.node.id);
    expect(
      (await repo.loadMap(map.id)).summaries.single.parentNodeId,
      other.node.id,
    );
    await repo.removeBranch(node);
    expect((await repo.loadMap(map.id)).summaries, isEmpty);
    await repo.undo();
    expect((await repo.loadMap(map.id)).summaries.single.id, original.id);
  });
  test('中间插入主题动态纳入概要，部分重挂保存动态范围；去除括号保留主题', () async {
    await repo.setMapLayout(map.id, MapLayoutKind.free);
    final root = await topic('根'),
        other = await topic('另一根'),
        a = await topic('甲', parent: root.node.id),
        c = await topic('丙', parent: root.node.id);
    await repo.createSummaries(map.id, {a.node.id, c.node.id});
    final b = await topic('乙', parent: root.node.id);
    await repo.moveNode(b.node.id, b.node.x, (a.node.y + c.node.y) / 2);
    final snapshot = await repo.loadMap(map.id), s = snapshot.summaries.single;
    expect(summaryRoots(s, snapshot.nodes, snapshot.summaries), hasLength(3));
    await repo.reparentNode(c.node.id, other.node.id);
    expect((await repo.loadMap(map.id)).summaries.single.nodeIds.toSet(), {
      a.node.id,
      b.node.id,
    });
    await repo.removeSummary(s.id);
    expect(
      (await repo.loadMap(map.id)).nodes.any((n) => n.id == s.summaryNodeId),
      isTrue,
    );
    await repo.undo();
    expect((await repo.loadMap(map.id)).summaries, hasLength(1));
  });
  test('失败触发器整笔回滚，重启／备份／卡片清理／项目清理保留数据合同', () async {
    final root = await topic('根'),
        a = await topic('甲', parent: root.node.id),
        b = await topic('乙', parent: root.node.id);
    final path = '${repo.libraryPath}/library.sqlite';
    final db = sqlite.sqlite3.open(path);
    db.execute(
      "CREATE TRIGGER fail_summary BEFORE INSERT ON summaries BEGIN SELECT RAISE(ABORT,'fail'); END",
    );
    final count = repo.undoEntryCount;
    await expectLater(
      repo.createSummaries(map.id, {a.node.id, b.node.id}),
      throwsA(anything),
    );
    expect((await repo.loadMap(map.id)).nodes, hasLength(3));
    expect((await repo.listCards(project.id)), hasLength(3));
    expect(repo.undoEntryCount, count);
    db.execute('DROP TRIGGER fail_summary');
    db.close();
    final node = (await repo.createSummaries(map.id, {
      a.node.id,
      b.node.id,
    })).single;
    final s = (await repo.loadMap(map.id)).summaries.single;
    await repo.updateSummary(
      s.id,
      style: const SummaryStyle(bracket: SummaryBracket.curve),
    );
    final archive = '${temp.path}/v6.onbackup';
    await repo.backupTo(archive);
    await repo.close();
    repo = await OpenNoteRepository.open(rootPath: '${temp.path}/library');
    expect(
      (await repo.loadMap(map.id)).summaries.single.style.bracket,
      SummaryBracket.curve,
    );
    await repo.removeSummary(s.id);
    await repo.restoreFrom(archive);
    await repo.trashCard(a.card.id);
    final trash = (await repo.listTrash()).singleWhere(
      (t) => t.kind == TrashKind.card,
    );
    await repo.purgeTrash(trash.id, discardSessionHistory: true);
    expect((await repo.loadMap(map.id)).summaries.single.nodeIds, [b.node.id]);
    expect((await repo.loadMap(map.id)).nodes.any((n) => n.id == node), isTrue);
    await repo.trashProject(project.id);
    final projectTrash = (await repo.listTrash()).singleWhere(
      (t) => t.kind == TrashKind.project,
    );
    await repo.purgeTrash(projectTrash.id, discardSessionHistory: true);
    final read = sqlite.sqlite3.open('${repo.libraryPath}/library.sqlite');
    expect(read.select('SELECT * FROM summaries'), isEmpty);
    expect(read.select('PRAGMA foreign_key_check'), isEmpty);
    read.close();
  });
  test('复制为自由主题仍保留概要和子主题，父卡片回收／恢复不丢失范围', () async {
    final root = await topic('根'),
        a = await topic('甲', parent: root.node.id),
        b = await topic('乙', parent: root.node.id);
    final node = (await repo.createSummaries(map.id, {
      a.node.id,
      b.node.id,
    })).single;
    final s = (await repo.loadMap(map.id)).summaries.single;
    await topic('概要子主题', parent: node);
    final content = MapClipboardContent.capture(await repo.loadMap(map.id), {
      a.node.id,
      b.node.id,
    });
    final target = await repo.createMap(project.id, '自由副本');
    await repo.pasteTopicCopy(content, target.id);
    final copy = (await repo.loadMap(target.id)).summaries.single;
    expect(copy.parentNodeId, isNull);
    expect(copy.nodeIds, hasLength(2));
    await repo.trashCard(root.card.id);
    final temporary = (await repo.loadMap(map.id)).summaries.single;
    expect(temporary.id, s.id);
    expect(temporary.parentNodeId, isNull);
    final archive = '${temp.path}/free.onbackup';
    await repo.backupTo(archive);
    await repo.restoreFrom(archive);
    final trash = (await repo.listTrash()).singleWhere(
      (t) => t.kind == TrashKind.card,
    );
    await repo.restoreTrash(trash.id);
    expect(
      (await repo.loadMap(map.id)).summaries.single.parentNodeId,
      root.node.id,
    );
    expect((await repo.loadMap(map.id)).summaries.single.id, s.id);
  });
  test('外框新增和范围重挂排除非显式概要主题，剪贴板不改变原分组范围', () async {
    final root = await topic('根'),
        other = await topic('另一根'),
        a = await topic('甲', parent: root.node.id),
        b = await topic('乙', parent: root.node.id);
    final node = (await repo.createSummaries(map.id, {
      a.node.id,
      b.node.id,
    })).single;
    final box = (await repo.createBoundaries(map.id, {
      a.node.id,
      b.node.id,
    })).single;
    var snapshot = await repo.loadMap(map.id);
    expect(snapshot.boundaries.single.nodeIds.toSet(), {a.node.id, b.node.id});
    final content = MapClipboardContent.capture(snapshot, {
      a.node.id,
      b.node.id,
    });
    expect(content.snapshot.boundaries.single.nodeIds.contains(node), isFalse);
    await repo.reparentNode(b.node.id, other.node.id);
    snapshot = await repo.loadMap(map.id);
    expect(snapshot.boundaries.singleWhere((s) => s.id == box).nodeIds, [
      a.node.id,
    ]);
    expect(snapshot.summaries.single.nodeIds, [a.node.id]);
  });
}
