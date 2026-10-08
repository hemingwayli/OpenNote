import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opennote/data/open_note_repository.dart';
import 'package:opennote/domain/map_clipboard.dart';
import 'package:opennote/domain/models.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late OpenNoteRepository repo;
  late StudyProject project;
  late MindMap map;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('opennote-map-layout-');
    repo = await OpenNoteRepository.open(rootPath: '${temp.path}/library');
    project = await repo.createProject('结构与来源');
    map = (await repo.listMaps(project.id)).single;
    // 这些用例验证从旧自由布局切换结构，显式建立原始手工位置夹具。
    await repo.setMapLayout(map.id, MapLayoutKind.free);
    map = (await repo.loadMap(map.id)).map;
  });
  tearDown(() async {
    await repo.close();
    await temp.delete(recursive: true);
  });
  Future<ExcerptResult> topic(
    String title, {
    String? parent,
    double y = 0,
    List<AnchorDraft> anchors = const [],
  }) => repo.createExcerpt(
    ExcerptDraft(
      projectId: project.id,
      mapId: map.id,
      title: title,
      text: '$title 正文',
      note: '个人备注',
      parentNodeId: parent,
      x: 80,
      y: y,
      anchors: anchors,
      createHighlight: false,
    ),
  );

  test('布局保存、单次撤销重做、重启及 v3 完整备份保留来源和双侧方向', () async {
    final document = await repo.importPdf(
      projectId: project.id,
      filePath: File('tools/fixtures/pdf/native.pdf').absolute.path,
    );
    final root = await topic('中心');
    final a = await topic(
      '摘录',
      parent: root.node.id,
      anchors: [
        AnchorDraft(
          revisionId: document.activeRevisionId,
          pageIndex: 0,
          quads: [PdfQuad.rect(10, 10, 40, 30)],
          context: '原文',
        ),
      ],
    );
    await topic('独立笔记', parent: root.node.id, y: 150);
    final before = await repo.loadMap(map.id);
    final history = repo.undoEntryCount;
    await repo.setMapLayout(map.id, MapLayoutKind.mindMap);
    final structured = await repo.loadMap(map.id);
    expect(repo.undoEntryCount, history + 1);
    expect(structured.map.layout, MapLayoutKind.mindMap);
    expect(
      structured.nodes
          .where((n) => n.parentNodeId != null)
          .map((n) => n.branchSide)
          .toSet(),
      {-1, 1},
    );
    expect(structured.cards[a.card.id]!.body, a.card.body);
    expect(
      structured.anchors[a.card.id]!.single.revisionId,
      document.activeRevisionId,
    );
    await repo.undo();
    expect(_state(await repo.loadMap(map.id)), _state(before));
    await repo.redo();
    expect(_state(await repo.loadMap(map.id)), _state(structured));
    final backup = '${temp.path}/layout.onbackup';
    await repo.backupTo(backup);
    await repo.close();
    repo = await OpenNoteRepository.open(rootPath: '${temp.path}/library');
    expect(_state(await repo.loadMap(map.id)), _state(structured));
    await repo.setMapLayout(map.id, MapLayoutKind.up);
    await repo.restoreFrom(backup);
    expect(_state(await repo.loadMap(map.id)), _state(structured));
    expect(
      (await repo.loadMap(map.id)).anchors[a.card.id]!.single.context,
      '原文',
    );
  });

  test('上下组织结构新增、同级前后、上层、仅删节点和大纲复制沿用逻辑顺序', () async {
    final root = await topic('根');
    final a = await topic('A', parent: root.node.id);
    final b = await topic('B', parent: root.node.id, y: 150);
    await repo.setMapLayout(map.id, MapLayoutKind.down);
    final inserted = await repo.insertTopic(
      a.node.id,
      TopicInsertKind.siblingAfter,
      title: '中间',
    );
    final first = await repo.insertTopic(
      a.node.id,
      TopicInsertKind.siblingBefore,
      title: '最前',
    );
    var snapshot = await repo.loadMap(map.id);
    expect(_titles(snapshot, root.node.id), ['最前', 'A', '中间', 'B']);
    expect(
      _find(snapshot, first.node.id).x,
      lessThan(_find(snapshot, inserted.node.id).x),
    );
    await repo.reorderTopic(b.node.id, before: true);
    snapshot = await repo.loadMap(map.id);
    expect(_titles(snapshot, root.node.id), ['最前', 'A', 'B', '中间']);
    final parent = await repo.insertTopic(
      a.node.id,
      TopicInsertKind.parent,
      title: '新父',
    );
    snapshot = await repo.loadMap(map.id);
    expect(_titles(snapshot, root.node.id), ['最前', '新父', 'B', '中间']);
    expect(
      _find(snapshot, a.node.id).y,
      greaterThan(_find(snapshot, parent.node.id).y),
    );
    await repo.removeTopicOnly(parent.node.id);
    snapshot = await repo.loadMap(map.id);
    expect(_titles(snapshot, root.node.id), ['最前', 'A', 'B', '中间']);
    expect(snapshot.cards[a.card.id]!.note, '个人备注');
    await repo.setMapLayout(map.id, MapLayoutKind.up);
    snapshot = await repo.loadMap(map.id);
    expect(_titles(snapshot, root.node.id), ['最前', 'A', 'B', '中间']);
    expect(
      MapClipboardContent.capture(snapshot, {root.node.id}).text,
      '根\n\t最前\n\tA\n\tB\n\t中间',
    );
  });

  test('双侧同级新增继承方向，后代命令移动整枝；结构不改节点身份和备注', () async {
    final root = await topic('中心');
    final a = await topic('左枝', parent: root.node.id);
    final child = await topic('后代', parent: a.node.id);
    await topic('右枝', parent: root.node.id, y: 150);
    await repo.setMapLayout(map.id, MapLayoutKind.mindMap);
    await repo.setBranchSide(a.node.id, -1);
    final sibling = await repo.insertTopic(
      a.node.id,
      TopicInsertKind.siblingAfter,
    );
    var snapshot = await repo.loadMap(map.id);
    expect(_find(snapshot, sibling.node.id).branchSide, -1);
    expect(
      _find(snapshot, child.node.id).x,
      lessThan(_find(snapshot, a.node.id).x),
    );
    final history = repo.undoEntryCount;
    await repo.setBranchSide(child.node.id, 1);
    snapshot = await repo.loadMap(map.id);
    expect(repo.undoEntryCount, history + 1);
    expect(_find(snapshot, a.node.id).branchSide, 1);
    expect(
      _find(snapshot, child.node.id).x,
      greaterThan(_find(snapshot, a.node.id).x),
    );
    expect(snapshot.cards[child.card.id]!.note, '个人备注');
    await repo.undo();
    expect(_find(await repo.loadMap(map.id), a.node.id).branchSide, -1);
  });

  test('结构下放置、独立分支复制及剪切跨图迁移均重新排布，转回自由保留位置', () async {
    final root = await topic('根');
    final a = await topic('A', parent: root.node.id);
    await topic('后代', parent: a.node.id);
    await repo.setMapLayout(map.id, MapLayoutKind.left);
    final copy = await repo.copyBranch(
      a.node.id,
      map.id,
      parentNodeId: root.node.id,
    );
    var snapshot = await repo.loadMap(map.id);
    expect(_titles(snapshot, root.node.id), ['A', 'A']);
    expect(copy.cardIds[a.card.id], isNot(a.card.id));
    final copied = MapClipboardContent.capture(snapshot, {copy.rootNodeId});
    final target = await repo.createMap(project.id, '向下');
    await repo.setMapLayout(target.id, MapLayoutKind.down);
    final pasted = await repo.pasteTopicCopy(copied, target.id);
    expect(
      (await repo.loadMap(target.id)).nodes.every((n) => n.sortIndex != null),
      isTrue,
    );
    await repo.removeBranch(pasted.single.id);
    await repo.placeCard(
      (await repo.listCards(project.id))
          .firstWhere(
            (c) =>
                c.title == 'A' &&
                c.id != a.card.id &&
                c.id != copy.cardIds[a.card.id],
          )
          .id,
      target.id,
    );
    final cut = MapClipboardContent.capture(snapshot, {a.node.id});
    await repo.pasteTopicMove(cut, target.id);
    expect(
      (await repo.loadMap(map.id)).nodes.any((n) => n.id == a.node.id),
      isFalse,
    );
    expect(
      _find(await repo.loadMap(target.id), a.node.id).sortIndex,
      isNotNull,
    );
    await repo.setMapLayout(target.id, MapLayoutKind.free);
    final free = await repo.loadMap(target.id);
    expect(
      free.nodes
          .where((n) => n.parentNodeId == null)
          .every((n) => n.sortIndex == null),
      isTrue,
    );
    expect(
      _find(free, a.node.id).branchLayout,
      MapLayoutKind.left,
      reason: '全图切换保留复制／跨图移动时固定的分支结构',
    );
    expect(
      free.nodes
          .where((n) => n.parentNodeId == a.node.id)
          .every((n) => n.sortIndex != null),
      isTrue,
    );
    await repo.pasteTopicMove(
      MapClipboardContent.capture(await repo.loadMap(map.id), {
        copy.rootNodeId,
      }),
      target.id,
    );
    expect(
      (await repo.loadMap(target.id)).nodes
          .where((n) => n.parentNodeId == null)
          .every((n) => n.sortIndex == null),
      isTrue,
    );
    snapshot = await repo.loadMap(target.id);
    await repo.setMapLayout(target.id, MapLayoutKind.free);
    expect(_state(await repo.loadMap(target.id)), _state(snapshot));
  });

  test('展开深度、删除恢复卡片和隐藏位置在同一结构事务中可撤销', () async {
    final root = await topic('根');
    final a = await topic('A', parent: root.node.id);
    final b = await topic('B', parent: a.node.id);
    final c = await topic('C', parent: b.node.id);
    await repo.setMapLayout(map.id, MapLayoutKind.right);
    final before = await repo.loadMap(map.id);
    final history = repo.undoEntryCount;
    await repo.setMapVisibleDepth(map.id, 1);
    var snapshot = await repo.loadMap(map.id);
    expect(repo.undoEntryCount, history + 1);
    expect(_find(snapshot, root.node.id).collapsed, isFalse);
    expect(_find(snapshot, a.node.id).collapsed, isTrue);
    expect(_find(snapshot, b.node.id).x, _find(before, b.node.id).x);
    expect(_find(snapshot, c.node.id).y, _find(before, c.node.id).y);
    await repo.undo();
    expect(_state(await repo.loadMap(map.id)), _state(before));
    await repo.setMapVisibleDepth(map.id, 0);
    await repo.setMapVisibleDepth(map.id, null);
    expect(
      (await repo.loadMap(map.id)).nodes.every((n) => !n.collapsed),
      isTrue,
    );
    await repo.trashCard(a.card.id);
    snapshot = await repo.loadMap(map.id);
    expect(_find(snapshot, b.node.id).parentNodeId, root.node.id);
    await repo.restoreTrash((await repo.listTrash()).single.id);
    snapshot = await repo.loadMap(map.id);
    expect(_find(snapshot, b.node.id).parentNodeId, a.node.id);
    expect(_find(snapshot, c.node.id).parentNodeId, b.node.id);
    expect(snapshot.cards[a.card.id]!.body, 'A 正文');
  });

  test('布局写入中途 SQLite 拒绝时模式与全部位置回滚，失效项目拒绝命令', () async {
    final root = await topic('根');
    final a = await topic('A', parent: root.node.id);
    final before = await repo.loadMap(map.id);
    final history = repo.undoEntryCount;
    final db = sqlite.sqlite3.open('${repo.libraryPath}/library.sqlite');
    try {
      db.execute(
        "CREATE TRIGGER reject_layout BEFORE UPDATE ON nodes WHEN NEW.id='${a.node.id}' BEGIN SELECT RAISE(ABORT,'test layout failure'); END",
      );
      await expectLater(
        repo.setMapLayout(map.id, MapLayoutKind.left),
        throwsA(
          predicate<Object>(
            (error) => error.toString().contains('test layout failure'),
            'SQLite 触发器明确拒绝布局写入',
          ),
        ),
      );
      expect(_state(await repo.loadMap(map.id)), _state(before));
      expect(repo.undoEntryCount, history);
      db.execute('DROP TRIGGER reject_layout');
    } finally {
      db.close();
    }
    await repo.setMapLayout(map.id, MapLayoutKind.left);
    await repo.trashProject(project.id);
    await expectLater(
      repo.setMapLayout(map.id, MapLayoutKind.down),
      throwsA(isA<RepositoryException>()),
    );
    await expectLater(
      repo.setMapVisibleDepth(map.id, 1),
      throwsA(isA<RepositoryException>()),
    );
    await expectLater(
      repo.setBranchSide(root.node.id, 1),
      throwsA(isA<RepositoryException>()),
    );
  });
}

MapNode _find(MapSnapshot snapshot, String id) =>
    snapshot.nodes.firstWhere((n) => n.id == id);
List<String> _titles(MapSnapshot snapshot, String parent) =>
    (snapshot.nodes.where((n) => n.parentNodeId == parent).toList()
          ..sort(compareMapNodes))
        .map((n) => snapshot.cards[n.cardId]!.title)
        .toList();
Object _state(MapSnapshot snapshot) => [
  snapshot.map.layout,
  {
    for (final n in snapshot.nodes)
      n.id: [n.parentNodeId, n.x, n.y, n.sortIndex, n.branchSide, n.collapsed],
  },
];
