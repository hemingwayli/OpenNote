import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:opennote/data/database.dart';
import 'package:opennote/data/open_note_repository.dart';
import 'package:opennote/domain/models.dart';

import '../support/legacy_database_fixture.dart';
import 'mixed_structure_migration_test.dart' as v7;

sqlite.Database legacy8(String path) {
  final db = v7.legacy(path);
  for (final sql in legacyMixedStructureSchemaV8) {
    db.execute(sql);
  }
  db.execute('PRAGMA user_version=8');
  for (final (id, parent, order) in [
    ('a', 'n', 0),
    ('b', 'n', 1),
    ('s', 'n', 2),
    ('h', 's', 0),
  ]) {
    db.execute(
      'INSERT INTO nodes(id,map_id,card_id,parent_node_id,x,y,width,height,collapsed,sort_index,branch_layout) VALUES(?,?,?,?,0,0,220,116,0,?,?)',
      [id, 'm', 'c', parent, order, id == 'a' ? 'down' : null],
    );
  }
  db.execute("INSERT INTO edges VALUES('e','m','a','b','关系','{}')");
  db.execute(
    "INSERT INTO boundaries VALUES('f','m','n','[\"a\",\"b\"]','范围','{}')",
  );
  db.execute(
    "INSERT INTO summaries VALUES('u','m','n','s','[\"a\",\"b\"]','{}')",
  );
  db.execute(
    "INSERT INTO project_sessions(id,last_opened_at,map_id) VALUES('p',123,'m')",
  );
  return db;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  setUp(
    () async => temp = await Directory.systemTemp.createTemp('opennote-v9-'),
  );
  tearDown(() async => temp.delete(recursive: true));

  test('真实 v8 WAL 在线升级保留节点、父引用、关系、概要和会话，原库快照包含 WAL', () async {
    final root = '${temp.path}/library';
    final folder = await Directory('$root/libraries/old')
        .create(recursive: true);
    await File('$root/active.json')
        .writeAsString(jsonEncode({'libraryId': 'old'}), encoding: utf8);
    final old = legacy8('${folder.path}/library.sqlite');
    old.execute('PRAGMA journal_mode=WAL');
    old.execute('PRAGMA wal_autocheckpoint=0');
    old.execute("UPDATE cards SET body='WAL 最新正文' WHERE id='c'");
    final repo = await OpenNoteRepository.open(rootPath: root);
    try {
      final snapshot = await repo.loadMap('m');
      expect(snapshot.nodes, hasLength(5));
      expect(
        snapshot.nodes.singleWhere((n) => n.id == 'a').branchLayout,
        MapLayoutKind.down,
      );
      expect(snapshot.nodes.singleWhere((n) => n.id == 'h').parentNodeId, 's');
      expect(snapshot.edges.single.id, 'e');
      expect(snapshot.boundaries.single.id, 'f');
      expect(snapshot.summaries.single.summaryNodeId, 's');
      expect(snapshot.cards['c']!.body, 'WAL 最新正文');
      final current = sqlite.sqlite3.open('${folder.path}/library.sqlite');
      expect(
        current.select('PRAGMA user_version').single.values.single,
        currentDatabaseVersion,
      );
      expect(current.select('PRAGMA foreign_key_check'), isEmpty);
      expect(
        current.select('SELECT map_id FROM project_sessions').single['map_id'],
        'm',
      );
      expect(
        current
            .select(
              "SELECT COUNT(*) AS n FROM sqlite_master WHERE name IN ('maps_project','nodes_map','nodes_parent')",
            )
            .single['n'],
        3,
      );
      current.close();
      final before = folder.listSync().whereType<File>().singleWhere(
        (f) => f.path.contains('.before-v$currentDatabaseVersion-'),
      );
      final read = sqlite.sqlite3.open(
        before.path,
        mode: sqlite.OpenMode.readOnly,
      );
      expect(read.select('PRAGMA user_version').single.values.single, 8);
      expect(read.select('SELECT body FROM cards').single['body'], 'WAL 最新正文');
      read.close();
      final backup = '${temp.path}/v8.onbackup';
      await v7.backup(before.path, backup, 8);
      await repo.setMapLayout('m', MapLayoutKind.timeline);
      await repo.restoreFrom(backup);
      expect((await repo.loadMap('m')).map.layout, MapLayoutKind.right);
      expect((await repo.loadMap('m')).summaries.single.id, 'u');
    } finally {
      await repo.close();
      old.close();
    }
  });

  test('v9 重建冲突回滚原表与版本，不删除任何引用', () async {
    final path = '${temp.path}/conflict.sqlite';
    final db = legacy8(path);
    db.execute('CREATE TABLE nodes_v9(id TEXT)');
    db.close();
    await expectLater(
      upgradeStagedDatabase(path),
      throwsA(isA<sqlite.SqliteException>()),
    );
    final read = sqlite.sqlite3.open(path);
    expect(read.select('PRAGMA user_version').single.values.single, 8);
    expect(read.select('SELECT COUNT(*) AS n FROM nodes').single['n'], 5);
    expect(
      read
          .select('SELECT summary_node_id FROM summaries')
          .single['summary_node_id'],
      's',
    );
    expect(
      read.select("SELECT name FROM sqlite_master WHERE name='maps_v9'"),
      isEmpty,
    );
    read.close();
  });

  for (final unexpected in [
    'CREATE TRIGGER unknown_layout AFTER UPDATE ON maps BEGIN SELECT 1; END',
    'CREATE INDEX unknown_layout ON nodes(x)',
    'ALTER TABLE nodes ADD COLUMN extra_user_data TEXT',
    "UPDATE nodes SET parent_node_id='missing' WHERE id='a'",
  ]) {
    test('v9 非标准对象、未知字段或坏引用拒绝升级且保留旧库：$unexpected', () async {
      final path = '${temp.path}/unsafe.sqlite';
      final db = legacy8(path);
      db.execute(unexpected);
      db.close();
      await expectLater(upgradeStagedDatabase(path), throwsStateError);
      final read = sqlite.sqlite3.open(path);
      expect(read.select('PRAGMA user_version').single.values.single, 8);
      expect(read.select('SELECT COUNT(*) AS n FROM nodes').single['n'], 5);
      read.close();
    });
  }

  test('v9 约束接受全部新结构并拒绝未知结构，暂存升级仍恢复外键完整性', () async {
    final path = '${temp.path}/valid.sqlite';
    legacy8(path).close();
    await upgradeStagedDatabase(path);
    final read = sqlite.sqlite3.open(path);
    for (final kind in MapLayoutKind.values) {
      read.execute('UPDATE maps SET layout_kind=?', [kind.name]);
      read.execute('UPDATE nodes SET branch_layout=?', [kind.name]);
    }
    expect(
      () => read.execute("UPDATE maps SET layout_kind='invalid'"),
      throwsA(isA<sqlite.SqliteException>()),
    );
    expect(
      () => read.execute("UPDATE nodes SET branch_layout='invalid'"),
      throwsA(isA<sqlite.SqliteException>()),
    );
    expect(read.select('PRAGMA foreign_key_check'), isEmpty);
    read.close();
  });

  test('v8 备份不能冒用新结构名称，恢复失败保持当前资料库会话与内容', () async {
    final path = '${temp.path}/invalid-v8.sqlite';
    final db = legacy8(path);
    db.execute('PRAGMA ignore_check_constraints=ON');
    db.execute("UPDATE nodes SET branch_layout='timeline' WHERE id='n'");
    db.close();
    final archive = '${temp.path}/invalid-v8.onbackup';
    await v7.backup(path, archive, 8);
    final repo = await OpenNoteRepository.open(
      rootPath: '${temp.path}/current',
    );
    try {
      final project = await repo.createProject('当前正常项目');
      final session = repo.sessionId;
      await expectLater(
        repo.restoreFrom(archive),
        throwsA(isA<RepositoryException>()),
      );
      expect(repo.sessionId, session);
      expect((await repo.listProjects()).single.id, project.id);
    } finally {
      await repo.close();
    }
  });
}
