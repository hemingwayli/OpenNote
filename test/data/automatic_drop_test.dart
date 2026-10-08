import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opennote/data/open_note_repository.dart';
import 'package:opennote/domain/models.dart';
import 'package:opennote/domain/topic_drop.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late OpenNoteRepository repo;
  late StudyProject project;
  late MindMap map;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('opennote-auto-drop-');
    repo = await OpenNoteRepository.open(rootPath: '${temp.path}/library');
    project = await repo.createProject('自动排版');
    map = (await repo.listMaps(project.id)).single;
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
          note: '备注 $title',
          parentNodeId: parent,
          x: 80,
          y: 100,
        ),
      )).node;
  Future<MapNode> get(String id) async =>
      (await repo.loadMap(map.id)).nodes.singleWhere((n) => n.id == id);
  Future<void> drop(String source, String parent) async => repo.dropTopic(
    await get(source),
    TopicDropTarget(await get(parent), TopicDropPlacement.child),
    // 模拟把主题放在父卡片内部；保存后必须由布局坐标接管。
    x: (await get(parent)).x + 20,
    y: (await get(parent)).y + 20,
  );

  test('自动排版默认：模型、项目初始图与新建图均向右，历史自由值保留', () async {
    expect(
      const MindMap(id: 'new', projectId: 'p', title: '新图').layout,
      MapLayoutKind.right,
    );
    expect(map.layout, MapLayoutKind.right);
    final created = await repo.createMap(project.id, '新建图');
    expect(created.layout, MapLayoutKind.right);
    final db = sqlite.sqlite3.open('${repo.libraryPath}/library.sqlite');
    try {
      // 缺失布局的旧写入仍保留数据库的历史自由语义，不能静默解释成自动。
      db.execute('INSERT INTO maps(id,project_id,title) VALUES(?,?,?)', [
        'legacy-free',
        project.id,
        '历史自由图',
      ]);
    } finally {
      db.close();
    }
    expect((await repo.loadMap('legacy-free')).map.layout, MapLayoutKind.free);
    await repo.setMapLayout(created.id, MapLayoutKind.free);
    final backup = '${temp.path}/free.onbackup';
    await repo.backupTo(backup);
    await repo.setMapLayout(created.id, MapLayoutKind.left);
    await repo.restoreFrom(backup);
    expect((await repo.loadMap(created.id)).map.layout, MapLayoutKind.free);
    await repo.close();
    repo = await OpenNoteRepository.open(rootPath: '${temp.path}/library');
    expect((await repo.loadMap(map.id)).map.layout, MapLayoutKind.right);
    expect((await repo.loadMap(created.id)).map.layout, MapLayoutKind.free);
  });

  test('自动排版默认：新增子主题自动排列，同级无重叠并保留内容', () async {
    final root = await topic('根');
    final a = await topic('甲', parent: root.id);
    final b = await topic('乙', parent: root.id);
    final snapshot = await repo.loadMap(map.id);
    final parent = snapshot.nodes.singleWhere((n) => n.id == root.id);
    final children =
        snapshot.nodes.where((n) => n.parentNodeId == root.id).toList()
          ..sort(compareMapNodes);
    expect(children.map((n) => n.id), [a.id, b.id]);
    expect(children.every((n) => n.x >= parent.x + parent.width + 72), isTrue);
    expect(overlap(children.first, children.last), isFalse);
    expect(snapshot.cards[a.cardId]!.body, '正文 甲');
    expect(snapshot.cards[a.cardId]!.note, '备注 甲');
  });

  test('自动拖放：自由父级只整理目标子树，保留独立位置与内层结构并一次撤销', () async {
    await repo.setMapLayout(map.id, MapLayoutKind.free);
    final parent = await topic('目标父级');
    final first = await topic('已有子卡', parent: parent.id);
    final source = await topic('拖入卡片');
    final child = await topic('拖入后代', parent: source.id);
    final outside = await topic('独立分支');
    await repo.moveNode(parent.id, 100, 300);
    await repo.moveNode(first.id, 200, 350);
    await repo.moveNode(source.id, 800, 300);
    await repo.moveNode(outside.id, 40, 1100);
    await repo.setBranchLayout(map.id, {source.id}, MapLayoutKind.down);
    final before = await repo.loadMap(map.id);
    final count = repo.undoEntryCount;
    await drop(source.id, parent.id);
    final after = await repo.loadMap(map.id);
    final p = await get(parent.id), s = await get(source.id);
    expect(after.map.layout, MapLayoutKind.free);
    expect(p.branchLayout, MapLayoutKind.right);
    expect([p.x, p.y], [100, 300]);
    expect(s.parentNodeId, parent.id);
    expect(s.branchLayout, MapLayoutKind.down);
    expect(s.sortIndex, 1);
    expect(s.x, greaterThanOrEqualTo(p.x + p.width + 72));
    expect(overlap(await get(first.id), s), isFalse);
    expect((await get(child.id)).y, greaterThan(s.y + s.height));
    final oldOutside = before.nodes.singleWhere((n) => n.id == outside.id);
    expect(
      [(await get(outside.id)).x, (await get(outside.id)).y],
      [oldOutside.x, oldOutside.y],
    );
    expect(repo.undoEntryCount, count + 1);
    await repo.undo();
    expect(geometry(await repo.loadMap(map.id)), geometry(before));
    await repo.redo();
    expect(geometry(await repo.loadMap(map.id)), geometry(after));
  });

  test('自动拖放：折叠父级展开，现有顺序保留，重复挂接不留下落点', () async {
    final p = await topic('父级');
    final a = await topic('已有一', parent: p.id);
    final b = await topic('已有二', parent: p.id);
    final s = await topic('拖入');
    await repo.setNodeCollapsed(p.id, true);
    final count = repo.undoEntryCount;
    await drop(s.id, p.id);
    final after = await repo.loadMap(map.id);
    expect((await get(p.id)).collapsed, isFalse);
    final children = after.nodes.where((n) => n.parentNodeId == p.id).toList()
      ..sort(compareMapNodes);
    expect(children.map((n) => n.id), [a.id, b.id, s.id]);
    for (var i = 0; i < children.length; i++) {
      for (var j = i + 1; j < children.length; j++) {
        expect(overlap(children[i], children[j]), isFalse);
      }
    }
    expect(repo.undoEntryCount, count + 1);
    await drop(s.id, p.id);
    expect(geometry(await repo.loadMap(map.id)), geometry(after));
    expect(repo.undoEntryCount, count + 1, reason: '相同末尾挂接不能产生空撤销');
    await repo.undo();
    expect((await get(p.id)).collapsed, isTrue);
    expect((await get(s.id)).parentNodeId, isNull);
  });

  for (final kind in [
    MapLayoutKind.left,
    MapLayoutKind.down,
    MapLayoutKind.up,
    MapLayoutKind.mindMap,
  ]) {
    test('自动拖放方向：${kind.name} 保持目标方向并平移整枝', () async {
      await repo.setMapLayout(map.id, kind);
      final p = await topic('父级');
      final s = await topic('拖入');
      final c = await topic('后代', parent: s.id);
      await drop(s.id, p.id);
      final parent = await get(p.id), source = await get(s.id);
      expect(source.parentNodeId, parent.id);
      expect(overlap(source, parent), isFalse);
      expect((await get(c.id)).parentNodeId, source.id);
      switch (kind) {
        case MapLayoutKind.left:
          expect(source.x + source.width, lessThan(parent.x));
        case MapLayoutKind.up:
          expect(source.y + source.height, lessThan(parent.y));
        case MapLayoutKind.down:
          expect(source.y, greaterThan(parent.y + parent.height));
        default:
          expect(source.x, greaterThan(parent.x + parent.width));
      }
    });
  }

  test('自动拖放：保存失败回滚目标结构、层级、全部位置及历史', () async {
    await repo.setMapLayout(map.id, MapLayoutKind.free);
    final parent = await topic('目标');
    final source = await topic('拖入');
    await repo.moveNode(source.id, 700, 600);
    final before = await repo.loadMap(map.id), count = repo.undoEntryCount;
    final db = sqlite.sqlite3.open('${repo.libraryPath}/library.sqlite');
    try {
      db.execute(
        "CREATE TRIGGER reject_auto_drop BEFORE UPDATE ON nodes WHEN NEW.id='${source.id}' AND NEW.parent_node_id='${parent.id}' BEGIN SELECT RAISE(ABORT,'自动拖放保存失败'); END",
      );
      await expectLater(drop(source.id, parent.id), throwsA(anything));
      expect(geometry(await repo.loadMap(map.id)), geometry(before));
      expect(repo.undoEntryCount, count);
    } finally {
      db.execute('DROP TRIGGER reject_auto_drop');
      db.close();
    }
  });

  test('自动拖放：过期目标、自身和后代挂接均拒绝且保留重做', () async {
    final parent = await topic('父级');
    final child = await topic('后代', parent: parent.id);
    final source = await topic('拖入');
    final oldTarget = await get(parent.id);
    await repo.setBranchLayout(map.id, {parent.id}, MapLayoutKind.down);
    await expectLater(
      repo.dropTopic(
        await get(source.id),
        TopicDropTarget(oldTarget, TopicDropPlacement.child),
      ),
      throwsA(isA<RepositoryException>()),
    );
    await repo.undo();
    final before = await repo.loadMap(map.id), count = repo.undoEntryCount;
    await expectLater(
      drop(parent.id, parent.id),
      throwsA(isA<RepositoryException>()),
    );
    await expectLater(
      drop(parent.id, child.id),
      throwsA(isA<RepositoryException>()),
    );
    expect(geometry(await repo.loadMap(map.id)), geometry(before));
    expect(repo.undoEntryCount, count);
    expect(repo.canRedo, isTrue);
  });
}

bool overlap(MapNode a, MapNode b) =>
    a.x < b.x + b.width &&
    a.x + a.width > b.x &&
    a.y < b.y + b.height &&
    a.y + a.height > b.y;

List<Object?> geometry(MapSnapshot snapshot) {
  final nodes = snapshot.nodes.toList()..sort((a, b) => a.id.compareTo(b.id));
  return [
    snapshot.map.layout,
    for (final n in nodes)
      [
        n.id,
        n.parentNodeId,
        n.sortIndex,
        n.branchSide,
        n.branchLayout,
        n.x,
        n.y,
        n.collapsed,
      ],
  ];
}
