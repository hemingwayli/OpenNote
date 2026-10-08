import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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
  var topicOrder = 0;
  setUp(() async {
    topicOrder = 0;
    temp = await Directory.systemTemp.createTemp('opennote-extended-');
    repo = await OpenNoteRepository.open(rootPath: '${temp.path}/library');
    project = await repo.createProject('结构');
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
          y: topicOrder++ * 160,
        ),
      )).node;

  for (final kind in MapLayoutKind.values.where((k) => k.extended)) {
    test('${kind.name} 结构一次撤销重做，新增排序和复制保持身份与正文，重启和完整备份保留', () async {
      final r = await topic('根'),
          a = await topic('甲', parent: r.id),
          b = await topic('乙', parent: r.id);
      final count = repo.undoEntryCount;
      await repo.setMapLayout(map.id, kind);
      final initial = await repo.loadMap(map.id);
      expect(repo.undoEntryCount, count + 1);
      await repo.undo();
      expect((await repo.loadMap(map.id)).map.layout, MapLayoutKind.free);
      await repo.redo();
      expect((await repo.loadMap(map.id)).map.layout, kind);
      final middle = (await repo.insertTopic(
        a.id,
        TopicInsertKind.siblingAfter,
        title: '中间',
      )).node;
      await repo.reorderTopic(b.id, before: true);
      var snapshot = await repo.loadMap(map.id);
      final children =
          snapshot.nodes.where((n) => n.parentNodeId == r.id).toList()
            ..sort(compareMapNodes);
      expect(children.map((n) => n.id), [a.id, b.id, middle.id]);
      expect(snapshot.cards[a.cardId]!.body, '正文 甲');
      final target = await repo.createMap(project.id, '目标');
      final content = MapClipboardContent.capture(snapshot, {r.id});
      final pasted = await repo.pasteTopicCopy(content, target.id);
      final copied = await repo.loadMap(target.id);
      expect(pasted.single.branchLayout, kind);
      expect(copied.nodes, hasLength(4));
      expect(copied.cards.values.map((c) => c.body), contains('正文 甲'));
      final backup = '${temp.path}/v9.onbackup';
      await repo.backupTo(backup);
      await repo.close();
      repo = await OpenNoteRepository.open(rootPath: '${temp.path}/library');
      snapshot = await repo.loadMap(map.id);
      expect(snapshot.map.layout, kind);
      expect(snapshot.nodes.map((n) => n.id).toSet(), {
        r.id,
        a.id,
        b.id,
        middle.id,
      });
      await repo.setMapLayout(map.id, MapLayoutKind.right);
      await repo.restoreFrom(backup);
      expect((await repo.loadMap(map.id)).map.layout, kind);
      expect(initial.nodes.singleWhere((n) => n.id == r.id).x, r.x);
    });
  }
  for (final kind in [
    MapLayoutKind.timeline,
    MapLayoutKind.timelineVertical,
    MapLayoutKind.fishboneRight,
  ]) {
    test('${kind.name} 概要子树和嵌套概要沿自身方向，单独复制概要保持正确方向', () async {
      final r = await topic('根'),
          a = await topic('甲', parent: r.id),
          b = await topic('乙', parent: r.id);
      await repo.setMapLayout(map.id, kind);
      final s = (await repo.createSummaries(map.id, {a.id, b.id})).single;
      final child = await topic('概要子主题', parent: s);
      final nested = (await repo.createSummaries(map.id, {child.id})).single;
      await topic('内层概要子主题', parent: nested);
      final snapshot = await repo.loadMap(map.id);
      final layouts = effectiveBranchLayouts(
        snapshot.nodes,
        kind,
        summaries: snapshot.summaries,
      );
      expect(layouts[s], kind.primaryDirection);
      expect(layouts[nested], kind.primaryDirection);
      final root = snapshot.nodes.singleWhere((n) => n.id == s);
      final c = snapshot.nodes.singleWhere((n) => n.id == child.id);
      if (kind == MapLayoutKind.timelineVertical) {
        expect(c.y, greaterThan(root.y + root.height));
      } else if (kind == MapLayoutKind.fishboneRight) {
        expect(c.x + c.width, lessThan(root.x));
      } else {
        expect(c.x, greaterThan(root.x + root.width));
      }
      final copy = MapClipboardContent.capture(snapshot, {s});
      expect(
        copy.snapshot.nodes.singleWhere((n) => n.id == s).branchLayout,
        kind.primaryDirection,
      );
    });
  }
}
