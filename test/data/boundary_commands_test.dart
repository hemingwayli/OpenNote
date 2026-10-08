import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opennote/data/open_note_repository.dart';
import 'package:opennote/domain/models.dart';
import 'package:opennote/domain/map_clipboard.dart';
import 'package:opennote/domain/boundary_geometry.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late OpenNoteRepository repo;
  late StudyProject project;
  late MindMap map;
  var position = 0;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('opennote-boundary-');
    repo = await OpenNoteRepository.open(rootPath: '${temp.path}/library');
    project = await repo.createProject('外框');
    map = (await repo.listMaps(project.id)).single;
    position = 0;
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
          y: position++ * 180.0,
        ),
      );
  Future<MapBoundary> box(String id) async =>
      (await repo.loadMap(map.id)).boundaries.singleWhere((b) => b.id == id);

  test('连续范围和跨分支分组一次提交，可撤销重做；无变化保留重做', () async {
    final root = await topic('根'), other = await topic('另一分支');
    final a = await topic('甲', parent: root.node.id),
        b = await topic('乙', parent: root.node.id),
        c = await topic('丙', parent: root.node.id),
        d = await topic('丁', parent: other.node.id);
    await repo.setMapLayout(map.id, MapLayoutKind.right);
    final history = repo.undoEntryCount;
    final ids = await repo.createBoundaries(map.id, {
      a.node.id,
      c.node.id,
      d.node.id,
    });
    expect(ids, hasLength(2));
    expect(repo.undoEntryCount, history + 1);
    final snapshot = await repo.loadMap(map.id);
    final range = snapshot.boundaries.singleWhere(
      (b) => b.parentNodeId == root.node.id,
    );
    expect(range.nodeIds.toSet(), {a.node.id, b.node.id, c.node.id});
    await repo.undo();
    expect((await repo.loadMap(map.id)).boundaries, isEmpty);
    await repo.redo();
    expect((await repo.loadMap(map.id)).boundaries, hasLength(2));
    await repo.updateBoundary(
      range.id,
      label: '说明',
      style: const BoundaryStyle(bold: true),
    );
    await repo.undo();
    expect(repo.canRedo, isTrue);
    await repo.updateBoundary(
      range.id,
      label: '',
      style: const BoundaryStyle(),
    );
    expect(repo.canRedo, isTrue);
  });

  test('范围、文字和样式同笔保存，陈旧和跨图范围拒绝且保留历史', () async {
    final root = await topic('根');
    final a = await topic('甲', parent: root.node.id),
        b = await topic('乙', parent: root.node.id),
        c = await topic('丙', parent: root.node.id);
    final id = (await repo.createBoundaries(map.id, {a.node.id})).single;
    final count = repo.undoEntryCount;
    await repo.updateBoundary(
      id,
      label: '中文分组',
      style: const BoundaryStyle(dashed: true),
      nodeIds: [a.node.id, c.node.id],
      expectedNodeIds: [a.node.id],
    );
    expect(repo.undoEntryCount, count + 1);
    expect((await box(id)).nodeIds, hasLength(3));
    await expectLater(
      repo.updateBoundary(id, label: '不应保存', expectedNodeIds: [a.node.id]),
      throwsA(anything),
    );
    await expectLater(
      repo.updateBoundary(id, nodeIds: [root.node.id]),
      throwsA(anything),
    );
    await expectLater(
      repo.updateBoundary(id, style: const BoundaryStyle(width: double.nan)),
      throwsA(anything),
    );
    await expectLater(
      repo.createBoundaries(map.id, {root.node.id, 'missing'}),
      throwsA(anything),
    );
    expect((await box(id)).label, '中文分组');
    expect(repo.undoEntryCount, count + 1);
    await repo.undo();
    expect((await box(id)).nodeIds, [a.node.id]);
    await repo.redo();
    expect((await box(id)).nodeIds.toSet(), {a.node.id, b.node.id, c.node.id});
  });

  test('复制整分支和剪贴板包含独立外框；移动整组保留身份，部分重挂缩小原框', () async {
    final root = await topic('根'), other = await topic('其他');
    final a = await topic('甲', parent: root.node.id),
        b = await topic('乙', parent: root.node.id);
    final id = (await repo.createBoundaries(map.id, {
      a.node.id,
      b.node.id,
    })).single;
    await repo.updateBoundary(
      id,
      label: '知识组',
      style: const BoundaryStyle(shape: BoundaryShape.ellipse),
    );
    final content = MapClipboardContent.capture(await repo.loadMap(map.id), {
      root.node.id,
    });
    expect(content.snapshot.boundaries.single.label, '知识组');
    final target = await repo.createMap(project.id, '目标');
    final copied = await repo.copyBranch(root.node.id, target.id);
    final first = (await repo.loadMap(target.id)).boundaries.single;
    expect(first.id, isNot(id));
    expect(first.nodeIds.toSet(), {
      copied.nodeIds[a.node.id],
      copied.nodeIds[b.node.id],
    });
    await repo.pasteTopicCopy(content, target.id);
    expect((await repo.loadMap(target.id)).boundaries, hasLength(2));
    await repo.reparentNode(a.node.id, other.node.id);
    expect((await box(id)).nodeIds, [b.node.id]);
    await repo.undo();
    expect((await box(id)).nodeIds, hasLength(2));
    await repo.pasteTopicMove(content, target.id);
    expect((await repo.loadMap(map.id)).boundaries, isEmpty);
    expect(
      (await repo.loadMap(target.id)).boundaries.any((b) => b.id == id),
      isTrue,
    );
    await repo.undo();
    expect((await box(id)).nodeIds, hasLength(2));
  });

  test('复制外框写入失败回滚新主题和卡片，保留重做', () async {
    final root = await topic('根'), a = await topic('甲', parent: null);
    await repo.reparentNode(a.node.id, root.node.id);
    await repo.createBoundaries(map.id, {a.node.id});
    await repo.updateCard(root.card.id, note: '撤销');
    await repo.undo();
    final snapshot = await repo.loadMap(map.id), count = repo.undoEntryCount;
    final guard = sqlite.sqlite3.open('${repo.libraryPath}/library.sqlite');
    try {
      guard.execute(
        "CREATE TRIGGER fail_box BEFORE INSERT ON boundaries BEGIN SELECT RAISE(ABORT,'fail'); END",
      );
      await expectLater(
        repo.copyBranch(root.node.id, map.id),
        throwsA(anything),
      );
      expect((await repo.loadMap(map.id)).nodes.length, snapshot.nodes.length);
      expect(await repo.listCards(project.id), hasLength(2));
      expect(repo.undoEntryCount, count);
      expect(repo.canRedo, isTrue);
    } finally {
      guard.close();
    }
  });

  test('删除分支及撤销、重启、备份恢复和永久清理保持外框一致', () async {
    final root = await topic('根'), a = await topic('甲');
    await repo.reparentNode(a.node.id, root.node.id);
    final id = (await repo.createBoundaries(map.id, {a.node.id})).single;
    await repo.updateBoundary(
      id,
      label: '保存分组',
      style: const BoundaryStyle(textSize: 18),
    );
    await repo.removeBranch(a.node.id);
    final hidden = await repo.loadMap(map.id);
    expect(hidden.boundaries, isEmpty);
    await repo.undo();
    expect(
      boundaryRoots(await box(id), (await repo.loadMap(map.id)).nodes),
      hasLength(1),
    );
    final path = '${temp.path}/backup.onbackup';
    await repo.backupTo(path);
    await repo.close();
    repo = await OpenNoteRepository.open(rootPath: '${temp.path}/library');
    expect((await box(id)).label, '保存分组');
    await repo.removeBoundary(id);
    await repo.restoreFrom(path);
    expect((await box(id)).style.textSize, 18);
    await repo.trashProject(project.id);
    final trash = (await repo.listTrash()).singleWhere(
      (t) => t.kind == TrashKind.project,
    );
    await repo.purgeTrash(trash.id, discardSessionHistory: true);
    final read = sqlite.sqlite3.open('${repo.libraryPath}/library.sqlite');
    try {
      expect(read.select('SELECT * FROM boundaries'), isEmpty);
      expect(read.select('PRAGMA foreign_key_check'), isEmpty);
    } finally {
      read.close();
    }
  });

  test('同级分组复制或移动为自由主题时分别保留外框，旧隐藏范围不产生空副本', () async {
    final root = await topic('根'), a = await topic('甲');
    await repo.reparentNode(a.node.id, root.node.id);
    final b = await topic('乙', parent: root.node.id);
    final id = (await repo.createBoundaries(map.id, {
      a.node.id,
      b.node.id,
    })).single;
    await repo.updateBoundary(id, label: '说明跟随');
    final content = MapClipboardContent.capture(await repo.loadMap(map.id), {
      a.node.id,
      b.node.id,
    });
    final target = await repo.createMap(project.id, '自由副本');
    await repo.pasteTopicCopy(content, target.id);
    var boxes = (await repo.loadMap(target.id)).boundaries;
    expect(boxes, hasLength(2));
    expect(
      boxes.every(
        (b) =>
            b.nodeIds.length == 1 &&
            b.parentNodeId == null &&
            b.label == '说明跟随',
      ),
      isTrue,
    );
    await repo.pasteTopicMove(content, target.id);
    expect((await repo.loadMap(map.id)).boundaries, isEmpty);
    boxes = (await repo.loadMap(target.id)).boundaries;
    expect(boxes, hasLength(4));
    expect(boxes.any((b) => b.id == id), isTrue);
    final backup = '${temp.path}/free.onbackup';
    await repo.backupTo(backup);
    await repo.restoreFrom(backup);
    expect((await repo.loadMap(target.id)).boundaries, hasLength(4));
  });

  test('命令捕获调用时范围，新插入的中间主题在重挂后仍属于原框', () async {
    // 本用例按手工坐标定义中间位置，明确使用自由布局。
    await repo.setMapLayout(map.id, MapLayoutKind.free);
    final root = await topic('根'), other = await topic('其他');
    final a = await topic('甲', parent: root.node.id),
        c = await topic('丙', parent: root.node.id);
    final selection = {a.node.id, c.node.id};
    final pending = repo.createBoundaries(map.id, selection);
    selection.clear();
    final id = (await pending).single;
    final b = await topic('乙', parent: root.node.id);
    await repo.moveNode(b.node.id, b.node.x, (a.node.y + c.node.y) / 2);
    expect(
      boundaryRoots(
        await box(id),
        (await repo.loadMap(map.id)).nodes,
      ).map((n) => n.id).toSet(),
      {a.node.id, b.node.id, c.node.id},
    );
    await repo.reparentNode(a.node.id, other.node.id);
    expect((await box(id)).nodeIds.toSet(), {b.node.id, c.node.id});
    final scope = [c.node.id],
        expected = List<String>.of((await box(id)).nodeIds);
    final update = repo.updateBoundary(
      id,
      nodeIds: scope,
      expectedNodeIds: expected,
    );
    scope.clear();
    expected.clear();
    await update;
    expect((await box(id)).nodeIds, [c.node.id]);
    await repo.undo();
    expect((await box(id)).nodeIds.toSet(), {b.node.id, c.node.id});
  });
}
