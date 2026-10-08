import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:opennote/data/open_note_repository.dart';
import 'package:opennote/domain/models.dart';
import 'package:opennote/domain/map_clipboard.dart';
import 'package:opennote/domain/topic_style_resolver.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late OpenNoteRepository repo;
  late StudyProject project;
  late MindMap map;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('opennote-topic-style-');
    repo = await OpenNoteRepository.open(rootPath: '${temp.path}/library');
    project = await repo.createProject('格式');
    map = (await repo.listMaps(project.id)).single;
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
          text: '独立正文 $title',
          parentNodeId: parent,
        ),
      );
  final blue = const TopicStyle().copyWith(
    surface: const TopicStyle().surface.copyWith(
      fill: '#EAF1FC',
      textSize: 20,
      italic: true,
    ),
    branch: const BranchStyle(
      path: BranchPath.elbow,
      color: '#3574CB',
      width: 3,
      end: BranchEnd.arrow,
    ),
  );

  test('精确多选与后代格式一次撤销；调用时选集不可变，不修改正文和坐标', () async {
    final root = await topic('根'),
        a = await topic('甲', parent: root.node.id),
        b = await topic('乙');
    final before = await repo.loadMap(map.id), count = repo.undoEntryCount;
    final selected = {root.node.id};
    final pending = repo.setTopicStyle(
      map.id,
      selected,
      blue,
      includeDescendants: true,
    );
    selected.clear();
    await pending;
    var after = await repo.loadMap(map.id);
    expect(after.nodes.singleWhere((n) => n.id == root.node.id).style, blue);
    expect(after.nodes.singleWhere((n) => n.id == a.node.id).style, blue);
    expect(after.nodes.singleWhere((n) => n.id == b.node.id).style, isNull);
    expect(after.cards[a.card.id]!.body, before.cards[a.card.id]!.body);
    expect(
      after.nodes.map((n) => [n.x, n.y]),
      before.nodes.map((n) => [n.x, n.y]),
    );
    expect(repo.undoEntryCount, count + 1);
    await repo.undo();
    expect(
      (await repo.loadMap(map.id)).nodes.every((n) => n.style == null),
      isTrue,
    );
    await repo.redo();
    after = await repo.loadMap(map.id);
    expect(after.nodes.singleWhere((n) => n.id == a.node.id).style, blue);
  });
  test('默认只影响未覆盖主题与新建；重置、无变化和非法目标保留历史', () async {
    final a = await topic('甲'), b = await topic('乙');
    await repo.setTopicStyle(map.id, {a.node.id}, blue);
    final plain = const TopicStyle().copyWith(
      surface: const TopicStyle().surface.copyWith(textSize: 24),
    );
    await repo.setTopicStyle(map.id, {}, plain, makeDefault: true);
    var snapshot = await repo.loadMap(map.id);
    expect(
      topicStyleFor(
        snapshot,
        snapshot.nodes.singleWhere((n) => n.id == a.node.id),
      ),
      blue,
    );
    expect(
      topicStyleFor(
        snapshot,
        snapshot.nodes.singleWhere((n) => n.id == b.node.id),
      ),
      plain,
    );
    final c = await repo.insertTopic(b.node.id, TopicInsertKind.child);
    snapshot = await repo.loadMap(map.id);
    expect(
      topicStyleFor(
        snapshot,
        snapshot.nodes.singleWhere((n) => n.id == c.node.id),
      ),
      plain,
    );
    await repo.setTopicStyle(map.id, {a.node.id}, null);
    expect(
      (await repo.loadMap(map.id)).nodes
          .singleWhere((n) => n.id == a.node.id)
          .style,
      isNull,
    );
    await repo.undo();
    final count = repo.undoEntryCount;
    await repo.setTopicStyle(map.id, {a.node.id}, blue);
    expect(repo.undoEntryCount, count);
    expect(repo.canRedo, isTrue);
    await expectLater(
      repo.setTopicStyle(map.id, {a.node.id, 'missing'}, blue),
      throwsA(anything),
    );
    await expectLater(
      repo.setTopicStyle(
        map.id,
        {a.node.id},
        blue,
        expectedCardIds: {a.node.id: 'replaced'},
      ),
      throwsA(anything),
    );
    expect(repo.undoEntryCount, count);
    expect(repo.canRedo, isTrue);
  });
  test('概要格式写入独立概要对象；子分支继承，移除括号保留主题外观并可撤销', () async {
    final root = await topic('根'), a = await topic('甲', parent: root.node.id);
    final sId = (await repo.createSummaries(map.id, {a.node.id})).single;
    final child = await repo.insertTopic(sId, TopicInsertKind.child);
    await repo.setTopicStyle(map.id, {sId}, blue);
    var snapshot = await repo.loadMap(map.id);
    final summary = snapshot.summaries.single;
    expect(summary.style.topic, blue.surface);
    expect(summary.style.effectiveBranch, blue.branch);
    expect(snapshot.nodes.singleWhere((n) => n.id == sId).style, isNull);
    expect(
      topicStyleFor(
        snapshot,
        snapshot.nodes.singleWhere((n) => n.id == child.node.id),
      ).branch,
      blue.branch,
    );
    await repo.removeSummary(summary.id);
    snapshot = await repo.loadMap(map.id);
    expect(snapshot.nodes.singleWhere((n) => n.id == sId).style, blue);
    await repo.undo();
    snapshot = await repo.loadMap(map.id);
    expect(snapshot.summaries.single.style.topic, blue.surface);
    expect(snapshot.nodes.singleWhere((n) => n.id == sId).style, isNull);
  });
  test('复制、内部剪贴板与跨图移动保留有效外观；副本格式不联动', () async {
    final a = await topic('甲'), b = await topic('乙');
    await repo.setTopicStyle(map.id, {}, blue, makeDefault: true);
    final snapshot = await repo.loadMap(map.id),
        clip = MapClipboardContent.capture(await repo.loadMap(map.id), {
          a.node.id,
        });
    final target = await repo.createMap(project.id, '目标');
    final copy = await repo.copyBranch(a.node.id, target.id);
    var targetSnapshot = await repo.loadMap(target.id);
    expect(topicStyleFor(targetSnapshot, targetSnapshot.nodes.single), blue);
    await repo.setTopicStyle(target.id, {copy.rootNodeId}, const TopicStyle());
    expect(topicStyleFor(snapshot, snapshot.nodes.first), blue);
    final pasted = await repo.pasteTopicCopy(clip, target.id);
    targetSnapshot = await repo.loadMap(target.id);
    expect(
      topicStyleFor(
        targetSnapshot,
        targetSnapshot.nodes.singleWhere((n) => n.id == pasted.single.id),
      ),
      blue,
    );
    await repo.moveBranchToMap(b.node.id, target.id);
    targetSnapshot = await repo.loadMap(target.id);
    expect(
      topicStyleFor(
        targetSnapshot,
        targetSnapshot.nodes.singleWhere((n) => n.id == b.node.id),
      ),
      blue,
    );
    final moveClip = MapClipboardContent.capture(await repo.loadMap(map.id), {
      a.node.id,
    });
    await repo.pasteTopicMove(moveClip, target.id);
    targetSnapshot = await repo.loadMap(target.id);
    expect(
      topicStyleFor(
        targetSnapshot,
        targetSnapshot.nodes.singleWhere((n) => n.id == a.node.id),
      ),
      blue,
    );
  });
  test('中途 SQL 失败原子回滚全部格式和默认；重启及 v7 备份保留格式', () async {
    final a = await topic('甲'), b = await topic('乙');
    final db = sqlite.sqlite3.open('${repo.libraryPath}/library.sqlite');
    db.execute(
      "CREATE TRIGGER reject_style BEFORE UPDATE OF topic_style_json ON nodes WHEN NEW.id='${b.node.id}' BEGIN SELECT RAISE(ABORT,'失败'); END",
    );
    final count = repo.undoEntryCount;
    await expectLater(
      repo.setTopicStyle(
        map.id,
        {a.node.id, b.node.id},
        blue,
        makeDefault: true,
      ),
      throwsA(anything),
    );
    var snapshot = await repo.loadMap(map.id);
    expect(snapshot.nodes.every((n) => n.style == null), isTrue);
    expect(snapshot.map.defaultStyle, const TopicStyle());
    expect(repo.undoEntryCount, count);
    db.execute('DROP TRIGGER reject_style');
    db.close();
    await repo.setTopicStyle(map.id, {a.node.id}, blue, makeDefault: true);
    await repo.close();
    repo = await OpenNoteRepository.open(rootPath: '${temp.path}/library');
    snapshot = await repo.loadMap(map.id);
    expect(snapshot.map.defaultStyle, blue);
    final archive = '${temp.path}/style.onbackup';
    await repo.backupTo(archive);
    await repo.setTopicStyle(map.id, {a.node.id}, const TopicStyle());
    await repo.restoreFrom(archive);
    snapshot = await repo.loadMap(map.id);
    expect(snapshot.nodes.singleWhere((n) => n.id == a.node.id).style, blue);
    expect(snapshot.map.defaultStyle, blue);
  });
}
