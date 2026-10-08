import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:opennote/data/open_note_repository.dart';
import 'package:opennote/domain/models.dart';
import 'package:opennote/domain/map_clipboard.dart';
import 'package:opennote/domain/branch_structure.dart';
import 'package:opennote/domain/topic_drop.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late OpenNoteRepository repo;
  late StudyProject project;
  late MindMap map;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('opennote-mixed-');
    repo = await OpenNoteRepository.open(rootPath: '${temp.path}/library');
    project = await repo.createProject('混合结构');
    map = (await repo.listMaps(project.id)).single;
    await repo.setMapLayout(map.id, MapLayoutKind.free);
    map = (await repo.loadMap(map.id)).map;
  });
  tearDown(() async {
    await repo.close();
    await temp.delete(recursive: true);
  });
  Future<MapNode> topic(String title, {String? parent}) async =>
      (await repo.createExcerpt(
        ExcerptDraft(
          projectId: project.id,
          mapId: map.id,
          title: title,
          text: '正文 $title',
          parentNodeId: parent,
        ),
      )).node;
  Future<MapNode> get(String id) async =>
      (await repo.loadMap(map.id)).nodes.singleWhere((n) => n.id == id);
  Future<List<String>> children(String? id) async =>
      ((await repo.loadMap(map.id)).nodes
              .where((n) => n.parentNodeId == id)
              .toList()
            ..sort(compareMapNodes))
          .map((n) => n.id)
          .toList();

  test('结构精确多选固定调用选集、保留内层设置、重置内层一次撤销并保持正文', () async {
    final r = await topic('根'),
        a = await topic('甲', parent: r.id),
        b = await topic('乙', parent: r.id);
    final child = await topic('内层', parent: a.id);
    await repo.setBranchLayout(map.id, {child.id}, MapLayoutKind.left);
    final count = repo.undoEntryCount, selected = {a.id};
    final pending = repo.setBranchLayout(map.id, selected, MapLayoutKind.down);
    selected.add(b.id);
    await pending;
    expect((await get(b.id)).branchLayout, isNull);
    expect((await get(child.id)).branchLayout, MapLayoutKind.left);
    expect(repo.undoEntryCount, count + 1);
    await repo.setBranchLayout(
      map.id,
      {a.id},
      MapLayoutKind.up,
      resetDescendantOverrides: true,
    );
    expect((await get(child.id)).branchLayout, isNull);
    expect((await repo.loadMap(map.id)).cards[a.cardId]!.body, '正文 甲');
    await repo.undo();
    expect((await get(a.id)).branchLayout, MapLayoutKind.down);
    expect((await get(child.id)).branchLayout, MapLayoutKind.left);
    final redo = repo.redoEntryCount;
    await repo.setBranchLayout(map.id, {a.id}, MapLayoutKind.down);
    expect(repo.redoEntryCount, redo, reason: '无变化不能清空重做');
  });
  test('自由图的自动分支支持新建与排序，自动图的自由分支保留手工坐标', () async {
    final r = await topic('根');
    await repo.setBranchLayout(map.id, {r.id}, MapLayoutKind.down);
    final a = (await repo.insertTopic(r.id, TopicInsertKind.child)).node;
    final b = (await repo.insertTopic(a.id, TopicInsertKind.siblingAfter)).node;
    expect((await get(a.id)).sortIndex, 0);
    expect((await get(b.id)).sortIndex, 1);
    expect((await get(a.id)).y, greaterThan((await get(r.id)).y));
    await repo.reorderTopic(b.id, before: true);
    expect(await children(r.id), [b.id, a.id]);
    await repo.setMapLayout(map.id, MapLayoutKind.right);
    await repo.setBranchLayout(map.id, {a.id}, MapLayoutKind.free);
    final c = (await repo.insertTopic(a.id, TopicInsertKind.child)).node;
    await repo.moveNode(c.id, 940, 710);
    final before = await get(c.id), parent = await get(a.id);
    await repo.organizeMap(map.id);
    final after = await get(c.id), nextParent = await get(a.id);
    expect(after.sortIndex, isNull);
    expect(after.x - nextParent.x, before.x - parent.x);
    expect(after.y - nextParent.y, before.y - parent.y);
  });
  test('拖放前后排序或成为子主题均一次保存、撤销恢复层级与位置', () async {
    await repo.setMapLayout(map.id, MapLayoutKind.right);
    final r = await topic('根'),
        a = await topic('甲', parent: r.id),
        b = await topic('乙', parent: r.id),
        c = await topic('丙', parent: r.id);
    final before = await repo.loadMap(map.id), count = repo.undoEntryCount;
    await repo.dropTopic(
      await get(c.id),
      TopicDropTarget(await get(a.id), TopicDropPlacement.before),
    );
    expect(await children(r.id), [c.id, a.id, b.id]);
    expect(repo.undoEntryCount, count + 1);
    await repo.undo();
    expect(await children(r.id), [a.id, b.id, c.id]);
    final restored = await repo.loadMap(map.id);
    expect(
      restored.nodes.map((n) => [n.id, n.parentNodeId, n.sortIndex, n.x, n.y]),
      before.nodes.map((n) => [n.id, n.parentNodeId, n.sortIndex, n.x, n.y]),
    );
    await repo.dropTopic(
      await get(c.id),
      TopicDropTarget(await get(a.id), TopicDropPlacement.child),
    );
    expect((await get(c.id)).parentNodeId, a.id);
    await repo.dropTopic(
      await get(c.id),
      TopicDropTarget(await get(b.id), TopicDropPlacement.after),
    );
    expect(await children(r.id), [a.id, b.id, c.id]);
  });
  test('过期结构与父级、后代循环和自由插序拒绝且保留历史', () async {
    final r = await topic('根'),
        a = await topic('甲', parent: r.id),
        b = await topic('乙', parent: r.id);
    await repo.setMapLayout(map.id, MapLayoutKind.right);
    final stale = await get(b.id);
    await repo.setBranchLayout(map.id, {b.id}, MapLayoutKind.down);
    final count = repo.undoEntryCount;
    await expectLater(
      repo.dropTopic(
        await get(a.id),
        TopicDropTarget(stale, TopicDropPlacement.child),
      ),
      throwsA(isA<RepositoryException>()),
    );
    await expectLater(
      repo.dropTopic(
        await get(r.id),
        TopicDropTarget(await get(a.id), TopicDropPlacement.child),
      ),
      throwsA(isA<RepositoryException>()),
    );
    expect(repo.undoEntryCount, count);
    await repo.setBranchLayout(map.id, {r.id}, MapLayoutKind.free);
    final next = repo.undoEntryCount;
    await expectLater(
      repo.dropTopic(
        await get(a.id),
        TopicDropTarget(await get(b.id), TopicDropPlacement.before),
      ),
      throwsA(isA<RepositoryException>()),
    );
    expect(repo.undoEntryCount, next);
  });
  test('局部双侧分支换边与中心拖放选边，与全图结构独立', () async {
    final r = await topic('根'),
        a = await topic('局部双侧', parent: r.id),
        l = await topic('左', parent: a.id),
        ll = await topic('左子', parent: l.id),
        b = await topic('乙', parent: r.id);
    await repo.setBranchLayout(map.id, {a.id}, MapLayoutKind.mindMap);
    await repo.setBranchSide(ll.id, -1);
    expect((await get(l.id)).branchSide, -1);
    final target = await get(a.id);
    await repo.dropTopic(
      await get(b.id),
      TopicDropTarget(target, TopicDropPlacement.child),
      x: target.x - 300,
      y: target.y,
    );
    expect((await get(b.id)).branchSide, -1);
    expect((await get(b.id)).x, lessThan((await get(a.id)).x));
  });
  test('复制粘贴和跨图剪切保留有效根结构及内层覆盖，撤销恢复原图', () async {
    final r = await topic('根'),
        a = await topic('甲', parent: r.id),
        b = await topic('乙', parent: a.id);
    await repo.setBranchLayout(map.id, {r.id}, MapLayoutKind.down);
    await repo.setBranchLayout(map.id, {b.id}, MapLayoutKind.left);
    final content = MapClipboardContent.capture(await repo.loadMap(map.id), {
      a.id,
    });
    final target = await repo.createMap(project.id, '目标');
    await repo.setMapLayout(target.id, MapLayoutKind.right);
    await repo.pasteTopicCopy(content, target.id);
    var result = await repo.loadMap(target.id);
    expect(
      result.nodes.singleWhere((n) => n.parentNodeId == null).branchLayout,
      MapLayoutKind.down,
    );
    expect(
      result.nodes.singleWhere((n) => n.parentNodeId != null).branchLayout,
      MapLayoutKind.left,
    );
    await repo.pasteTopicMove(content, target.id);
    result = await repo.loadMap(target.id);
    expect(
      result.nodes.singleWhere((n) => n.id == a.id).branchLayout,
      MapLayoutKind.down,
    );
    expect(
      branchLayoutsFor(result.nodes, result.map.layout)[a.id],
      MapLayoutKind.down,
    );
    await repo.undo();
    expect((await get(a.id)).parentNodeId, r.id);
    expect((await get(a.id)).branchLayout, isNull);
  });
  test('SQL 保存失败回滚结构、位置与历史；v8 备份恢复和重启保留混合结构', () async {
    final r = await topic('根'), a = await topic('甲', parent: r.id);
    final path = '${repo.libraryPath}/library.sqlite';
    final db = sqlite.sqlite3.open(path);
    db.execute(
      "CREATE TRIGGER reject_mixed BEFORE UPDATE OF branch_layout ON nodes WHEN NEW.branch_layout='down' BEGIN SELECT RAISE(ABORT,'结构保存失败'); END",
    );
    final count = repo.undoEntryCount, before = await repo.loadMap(map.id);
    await expectLater(
      repo.setBranchLayout(map.id, {r.id}, MapLayoutKind.down),
      throwsA(anything),
    );
    expect(repo.undoEntryCount, count);
    expect((await get(r.id)).branchLayout, isNull);
    expect(
      (await get(a.id)).x,
      before.nodes.singleWhere((n) => n.id == a.id).x,
    );
    db.execute('DROP TRIGGER reject_mixed');
    db.close();
    await repo.setBranchLayout(map.id, {r.id}, MapLayoutKind.down);
    final backup = '${temp.path}/mixed.onbackup';
    await repo.backupTo(backup);
    await repo.setBranchLayout(map.id, {r.id}, MapLayoutKind.up);
    await repo.restoreFrom(backup);
    expect((await get(r.id)).branchLayout, MapLayoutKind.down);
    await repo.close();
    repo = await OpenNoteRepository.open(rootPath: '${temp.path}/library');
    expect((await get(r.id)).branchLayout, MapLayoutKind.down);
  });
}
