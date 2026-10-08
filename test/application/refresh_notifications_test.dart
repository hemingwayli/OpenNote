import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opennote/application/workspace_controller.dart';
import 'package:opennote/data/open_note_repository.dart';
import 'package:opennote/domain/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('后台通知：慢读取期间继续通知不抢占保存，结束后仍补齐刷新', () async {
    final temp = await Directory.systemTemp.createTemp('opennote-refresh-');
    final real = await OpenNoteRepository.open(
      rootPath: '${temp.path}/library',
    );
    final project = await real.createProject('后台通知与保存');
    final map = (await real.listMaps(project.id)).single;
    final card = await real.createExcerpt(
      ExcerptDraft(
        projectId: project.id,
        mapId: map.id,
        title: '读取之前',
        text: '',
        anchors: const [],
      ),
    );
    final delayed = _DelayedMapRepository(real);
    final controller = WorkspaceController(delayed)..project = project;
    Future<void>? refreshing;
    try {
      refreshing = controller.refresh();
      await delayed.entered.future;
      // 使用真实仓储通知；仅延迟读快照以稳定重现 OCR 等后台更新与保存重叠。
      await real.updateCard(card.card.id, title: '慢读取期间的更新');
      await Future<void>.delayed(const Duration(milliseconds: 160));
      expect(delayed.mapReads, 1, reason: '后台通知不能替换尚未完成的前台读取');
      delayed.release.complete();
      await refreshing.timeout(const Duration(seconds: 5));
      expect(controller.map!.cards[card.card.id]!.title, '慢读取期间的更新');
      final deadline = Stopwatch()..start();
      while (delayed.mapReads < 2 && deadline.elapsedMilliseconds < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(delayed.mapReads, 2, reason: '读取期间积累的通知仍在结束后刷新一次');
    } finally {
      if (!delayed.release.isCompleted) delayed.release.complete();
      if (refreshing != null) await refreshing;
      controller.dispose();
      await real.close();
      await temp.delete(recursive: true);
    }
  });
}

/// 查询仍交给真实 SQLite；只控制首次地图读取完成时机。
class _DelayedMapRepository implements OpenNoteRepository {
  _DelayedMapRepository(this.real);
  final OpenNoteRepository real;
  final entered = Completer<void>(), release = Completer<void>();
  int mapReads = 0;
  @override
  String get sessionId => real.sessionId;
  @override
  Stream<int> get changes => real.changes;
  @override
  Future<List<StudyProject>> listProjects({bool includeDeleted = false}) =>
      real.listProjects(includeDeleted: includeDeleted);
  @override
  Future<List<ManagedDocument>> listDocuments(
    String id, {
    bool includeDeleted = false,
  }) => real.listDocuments(id, includeDeleted: includeDeleted);
  @override
  Future<List<MindMap>> listMaps(String id) => real.listMaps(id);
  @override
  Future<List<NoteCard>> listCards(
    String id, {
    bool includeDeleted = false,
    int limit = 10000,
    int offset = 0,
  }) => real.listCards(
    id,
    includeDeleted: includeDeleted,
    limit: limit,
    offset: offset,
  );
  @override
  Future<MapSnapshot> loadMap(String id) async {
    mapReads++;
    if (mapReads == 1) {
      entered.complete();
      await release.future;
    }
    return real.loadMap(id);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
