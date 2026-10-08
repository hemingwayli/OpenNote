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
    temp = await Directory.systemTemp.createTemp('opennote-relationships-');
    repo = await OpenNoteRepository.open(rootPath: '${temp.path}/library');
    project = await repo.createProject('关联编辑');
    map = (await repo.listMaps(project.id)).single;
  });
  tearDown(() async {
    await repo.close();
    await temp.delete(recursive: true);
  });
  Future<ExcerptResult> topic(String title, {String? parent, String? mapId}) =>
      repo.createExcerpt(
        ExcerptDraft(
          projectId: project.id,
          mapId: mapId ?? map.id,
          title: title,
          text: title,
          parentNodeId: parent,
          x: 80,
          y: 120,
        ),
      );
  Future<MapEdge> edge(String id) async =>
      (await repo.loadMap(map.id)).edges.singleWhere((e) => e.id == id);

  test('关联说明和样式原子提交、一次撤销重做，语义无变化保留重做', () async {
    final a = await topic('甲'), b = await topic('乙');
    final relation = await repo.addAssociation(a.node.id, b.node.id);
    final count = repo.undoEntryCount;
    await repo.updateAssociation(relation.id, label: '影响关系', style: _style);
    expect(repo.undoEntryCount, count + 1);
    expect((await edge(relation.id)).label, '影响关系');
    expect((await edge(relation.id)).style, _style);
    await repo.undo();
    expect((await edge(relation.id)).label, isEmpty);
    expect((await edge(relation.id)).style, const RelationshipStyle());
    expect(repo.canRedo, isTrue);
    await repo.updateAssociation(
      relation.id,
      label: '',
      style: const RelationshipStyle(),
    );
    expect(repo.canRedo, isTrue);
    await repo.redo();
    expect((await edge(relation.id)).style, _style);
  });

  test('重连保留关联身份、说明和箭头语义；手动端点定位可撤销', () async {
    final nodes = [await topic('甲'), await topic('乙'), await topic('丙')]
      ..sort((a, b) => a.node.id.compareTo(b.node.id));
    final relation = await repo.addAssociation(
      nodes[1].node.id,
      nodes[2].node.id,
    );
    await repo.updateAssociation(relation.id, label: '仍是同一关系', style: _style);
    final history = repo.undoEntryCount;
    await repo.reconnectAssociation(
      relation.id,
      nodes[2].node.id,
      nodes[0].node.id,
      anchor: const PdfPoint(1, .2),
      expectedFromNodeId: relation.fromNodeId,
      expectedToNodeId: relation.toNodeId,
    );
    final after = await edge(relation.id);
    expect(after.fromNodeId, nodes[0].node.id);
    expect(after.toNodeId, nodes[1].node.id);
    expect(after.label, '仍是同一关系');
    expect(after.style.startArrow, _style.endArrow);
    expect(after.style.endArrow, _style.startArrow);
    expect(after.style.anchorFrom!.toJson(), {'x': 1.0, 'y': .2});
    expect(after.style.controlFrom!.toJson(), _style.controlTo!.toJson());
    expect(repo.undoEntryCount, history + 1);
    await repo.undo();
    expect((await edge(relation.id)).style, _style);
    expect((await edge(relation.id)).toNodeId, relation.toNodeId);
    await repo.redo();
    expect((await edge(relation.id)).style, after.style);
  });

  test('重复、自连、跨图、陈旧端点、回收站和非法样式均不改数据或历史', () async {
    final a = await topic('甲'), b = await topic('乙'), c = await topic('丙');
    final otherMap = await repo.createMap(project.id, '其他图');
    final outside = await topic('图外', mapId: otherMap.id);
    final relation = await repo.addAssociation(a.node.id, b.node.id);
    await repo.addAssociation(a.node.id, c.node.id);
    final history = repo.undoEntryCount;
    final failures = [
      () => repo.reconnectAssociation(relation.id, b.node.id, a.node.id),
      () => repo.reconnectAssociation(relation.id, b.node.id, c.node.id),
      () => repo.reconnectAssociation(relation.id, b.node.id, outside.node.id),
      () => repo.updateAssociation(
        relation.id,
        label: '不应保存',
        expectedFromNodeId: '过期',
      ),
      () => repo.updateAssociation(relation.id, label: '长' * 1001),
      () => repo.updateAssociation(
        relation.id,
        style: const RelationshipStyle(anchorFrom: PdfPoint(.5, .5)),
      ),
    ];
    for (final operation in failures) {
      await expectLater(operation(), throwsA(isA<Exception>()));
      expect(repo.undoEntryCount, history);
      expect((await edge(relation.id)).label, isEmpty);
    }
    await repo.trashMap(map.id);
    final afterTrash = repo.undoEntryCount;
    await expectLater(
      repo.updateAssociation(relation.id, label: '失效'),
      throwsA(isA<RepositoryException>()),
    );
    expect(repo.undoEntryCount, afterTrash);
  });

  test('复制分支和剪贴板复制保持命名主题对应的箭头与控制点，不依赖新 ID 排序', () async {
    final a = await topic('源头'), b = await topic('结果', parent: a.node.id);
    final relation = await repo.addAssociation(a.node.id, b.node.id);
    final sourceStyle = relation.fromNodeId == a.node.id
        ? _style
        : _style.flipped();
    await repo.updateAssociation(relation.id, label: '决定', style: sourceStyle);
    final snapshot = await repo.loadMap(map.id);
    final target = await repo.createMap(project.id, '复制目的');
    final copied = await repo.copyBranch(a.node.id, target.id);
    final copyRoot = copied.rootNodeId;
    _checkCopy(await repo.loadMap(target.id), copyRoot);
    final content = MapClipboardContent.capture(snapshot, {a.node.id});
    for (var i = 0; i < 3; i++) {
      final roots = await repo.pasteTopicCopy(content, target.id);
      _checkCopy(await repo.loadMap(target.id), roots.single.id);
    }
  });

  test('关联创建自由主题与连线一次提交、撤销无残留，失效目标整批拒绝', () async {
    await repo.setMapLayout(map.id, MapLayoutKind.free);
    final source = await topic('关联起点');
    final before = repo.undoEntryCount;
    final created = await repo.createAssociatedTopic(
      map.id,
      const PdfPoint(500, 220),
      fromNodeId: source.node.id,
    );
    expect(created.node.parentNodeId, isNull);
    expect([created.node.x, created.node.y], [500.0, 220.0]);
    expect(repo.undoEntryCount, before + 1);
    expect((await repo.loadMap(map.id)).edges, hasLength(1));
    await repo.undo();
    expect((await repo.loadMap(map.id)).nodes, hasLength(1));
    expect(await repo.listCards(project.id), hasLength(1));
    expect(repo.canRedo, isTrue);
    await expectLater(
      repo.createAssociatedTopic(
        map.id,
        const PdfPoint(1, 1),
        fromNodeId: '失效',
      ),
      throwsA(isA<RepositoryException>()),
    );
    expect(repo.canRedo, isTrue);
    await expectLater(
      repo.createAssociatedTopic(map.id, const PdfPoint(double.nan, 1)),
      throwsA(isA<RepositoryException>()),
    );
    expect((await repo.loadMap(map.id)).nodes, hasLength(1));
    await repo.redo();
    expect((await repo.loadMap(map.id)).edges.single.toNodeId, isNotEmpty);
    final free = await repo.createAssociatedTopic(
      map.id,
      const PdfPoint(-180, 340),
    );
    expect(free.node.parentNodeId, isNull);
    expect((await repo.loadMap(map.id)).edges, hasLength(1));
  });

  test('关联写入失败时新自由主题与卡片一并回滚，重做记录保留', () async {
    final source = await topic('原主题');
    await repo.updateCard(source.card.id, note: '制造可重做操作');
    await repo.undo();
    final history = repo.undoEntryCount;
    final guard = sqlite.sqlite3.open('${repo.libraryPath}/library.sqlite');
    try {
      guard.execute(
        "CREATE TRIGGER reject_relation BEFORE INSERT ON edges BEGIN SELECT RAISE(FAIL, '模拟关联创建失败'); END;",
      );
      await expectLater(
        repo.createAssociatedTopic(
          map.id,
          const PdfPoint(480, 220),
          fromNodeId: source.node.id,
        ),
        throwsA(anything),
      );
      expect(repo.undoEntryCount, history);
      expect(repo.canRedo, isTrue);
      expect((await repo.loadMap(map.id)).nodes, hasLength(1));
      expect((await repo.loadMap(map.id)).edges, isEmpty);
      expect(await repo.listCards(project.id), hasLength(1));
    } finally {
      guard.close();
    }
  });

  test('保存重启及 v4 备份恢复保留曲线、锚点、说明和文字样式', () async {
    final a = await topic('甲'), b = await topic('乙');
    final relation = await repo.addAssociation(a.node.id, b.node.id);
    await repo.updateAssociation(relation.id, label: '多行\n中文关系', style: _style);
    final backup = '${temp.path}/relationships.onbackup';
    await repo.backupTo(backup);
    await repo.close();
    repo = await OpenNoteRepository.open(rootPath: '${temp.path}/library');
    expect((await edge(relation.id)).style, _style);
    await repo.updateAssociation(
      relation.id,
      label: '后续修改',
      style: const RelationshipStyle(),
    );
    await repo.restoreFrom(backup);
    expect((await edge(relation.id)).label, '多行\n中文关系');
    expect((await edge(relation.id)).style, _style);
    await repo.removeAssociation(relation.id);
    await repo.undo();
    expect((await edge(relation.id)).style, _style);
  });
}

const _style = RelationshipStyle(
  shape: RelationshipShape.curve,
  color: '#3574CB',
  colorSource: RelationshipColorSource.from,
  width: 2.5,
  dashed: false,
  startArrow: RelationshipArrow.circle,
  endArrow: RelationshipArrow.triangle,
  labelFont: 'Microsoft YaHei',
  labelSize: 18,
  labelBold: true,
  labelItalic: true,
  controlFrom: PdfPoint(80, -50),
  controlTo: PdfPoint(-60, 90),
  anchorFrom: PdfPoint(1, .4),
  anchorTo: PdfPoint(0, .6),
  labelOffset: PdfPoint(12, -28),
);

void _checkCopy(MapSnapshot snapshot, String root) {
  final child = snapshot.nodes.singleWhere((n) => n.parentNodeId == root);
  final relation = snapshot.edges.singleWhere(
    (e) => {e.fromNodeId, e.toNodeId}.containsAll({root, child.id}),
  );
  expect(relation.label, '决定');
  final oriented = relation.fromNodeId == root
      ? relation.style
      : relation.style.flipped();
  expect(oriented, _style);
  expect(snapshot.cards[child.cardId]!.title, '结果');
}
