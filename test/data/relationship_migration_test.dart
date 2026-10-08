import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opennote/data/database.dart';
import 'package:opennote/data/open_note_repository.dart';
import 'package:opennote/domain/models.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../support/legacy_database_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  setUp(
    () async => temp = await Directory.systemTemp.createTemp(
      'opennote-relationship-migration-',
    ),
  );
  tearDown(() async => temp.delete(recursive: true));

  test('真实 v3 WAL 布局库升级 v4 保留全部数据及一致性快照，v3 备份可恢复', () async {
    final folder = await Directory('${temp.path}/old/libraries/legacy')
        .create(recursive: true);
    await File('${temp.path}/old/active.json')
        .writeAsString(jsonEncode({'libraryId': 'legacy'}), encoding: utf8);
    final old = _legacy('${folder.path}/library.sqlite');
    old.execute('PRAGMA journal_mode=WAL');
    old.execute('PRAGMA wal_autocheckpoint=0');
    old.execute("UPDATE cards SET note='WAL 最新内容' WHERE id='card-a'");
    final repo = await OpenNoteRepository.open(rootPath: '${temp.path}/old');
    try {
      final snapshot = await repo.loadMap('map');
      expect(snapshot.map.layout, MapLayoutKind.mindMap);
      expect(snapshot.nodes.firstWhere((n) => n.id == 'b').branchSide, -1);
      expect(snapshot.nodes.firstWhere((n) => n.id == 'b').sortIndex, 2);
      expect(snapshot.cards['card-a']!.note, 'WAL 最新内容');
      expect(snapshot.edges.single.label, isEmpty);
      expect(snapshot.edges.single.style, const RelationshipStyle());
      final backupFile = folder.listSync().whereType<File>().singleWhere(
        (f) => f.path.contains('.before-v$currentDatabaseVersion-'),
      );
      final read = sqlite.sqlite3.open(
        backupFile.path,
        mode: sqlite.OpenMode.readOnly,
      );
      try {
        expect(read.select('PRAGMA user_version').single.values.single, 3);
        expect(_columns(read, 'edges'), isNot(contains('label')));
        expect(
          read
              .select("SELECT note FROM cards WHERE id='card-a'")
              .single['note'],
          'WAL 最新内容',
        );
      } finally {
        read.close();
      }
      final backup = '${temp.path}/v3.onbackup';
      await _archive(backupFile.path, backup, 3);
      await repo.updateAssociation(
        'edge',
        label: '已升级编辑',
        style: const RelationshipStyle(shape: RelationshipShape.curve),
      );
      await repo.restoreFrom(backup);
      final restored = await repo.loadMap('map');
      expect(restored.map.layout, MapLayoutKind.mindMap);
      expect(restored.edges.single.style, const RelationshipStyle());
      await repo.updateAssociation('edge', label: '恢复后可编辑');
      expect((await repo.loadMap('map')).edges.single.label, '恢复后可编辑');
    } finally {
      await repo.close();
      old.close();
    }
  });

  test('v4 第二列迁移冲突回滚第一列和版本，不重建或覆盖原库', () async {
    final path = '${temp.path}/conflict.sqlite';
    final old = _legacy(path);
    old.execute(
      "ALTER TABLE edges ADD COLUMN style_json TEXT NOT NULL DEFAULT '{}'",
    );
    old.close();
    await expectLater(
      upgradeStagedDatabase(path),
      throwsA(isA<sqlite.SqliteException>()),
    );
    final read = sqlite.sqlite3.open(path);
    try {
      expect(read.select('PRAGMA user_version').single.values.single, 3);
      expect(_columns(read, 'edges'), isNot(contains('label')));
      expect(read.select('SELECT id FROM edges').single['id'], 'edge');
      expect(
        temp.listSync().whereType<File>().where(
          (f) => f.path.contains('.before-v$currentDatabaseVersion-'),
        ),
        hasLength(1),
      );
    } finally {
      read.close();
    }
  });

  test('v4 非法关联样式备份拒绝激活，当前库指针、会话和撤销历史不变', () async {
    final repo = await OpenNoteRepository.open(
      rootPath: '${temp.path}/current',
    );
    try {
      final project = await repo.createProject('保留当前项目');
      final path = repo.libraryPath,
          session = repo.sessionId,
          history = repo.undoEntryCount;
      final pointer = await File('${temp.path}/current/active.json')
          .readAsBytes();
      final invalidPath = '${temp.path}/invalid.sqlite';
      final old = _legacy(invalidPath);
      for (final sql in relationshipSchema) {
        old.execute(sql);
      }
      old.execute('PRAGMA user_version=4');
      old.execute("UPDATE edges SET style_json=?", [
        jsonEncode({
          'anchorFrom': {'x': .5, 'y': .5},
        }),
      ]);
      old.close();
      final backup = '${temp.path}/invalid.onbackup';
      await _archive(invalidPath, backup, 4);
      await expectLater(
        repo.restoreFrom(backup),
        throwsA(isA<RepositoryException>()),
      );
      expect(repo.libraryPath, path);
      expect(repo.sessionId, session);
      expect(repo.undoEntryCount, history);
      expect(
        await File('${temp.path}/current/active.json').readAsBytes(),
        pointer,
      );
      expect((await repo.listProjects()).single.id, project.id);
      await repo.renameProject(project.id, '拒绝恢复后仍可保存');
    } finally {
      await repo.close();
    }
  });
}

sqlite.Database _legacy(String path) {
  final db = sqlite.sqlite3.open(path);
  for (final sql in [
    ...legacySchemaV1,
    ...legacyHomeSchemaV2,
    ...legacyMapLayoutSchemaV3,
  ]) {
    db.execute(sql);
  }
  db.execute("INSERT INTO projects VALUES('project','旧项目',1,NULL)");
  db.execute("INSERT INTO maps VALUES('map','project','旧布局',NULL,'mindMap')");
  for (final id in ['a', 'b']) {
    db.execute('INSERT INTO cards VALUES(?,?,?,?,?,?,?,NULL,1,NULL)', [
      'card-$id',
      'project',
      id,
      '快照',
      '正文',
      '备注',
      '#F7D976',
    ]);
    db.execute('INSERT INTO nodes VALUES(?,?,?,?,?,?,220,116,0,NULL,?,?)', [
      id,
      'map',
      'card-$id',
      id == 'b' ? 'a' : null,
      id == 'b' ? -310 : 80,
      120,
      id == 'b' ? 2 : 0,
      id == 'b' ? -1 : null,
    ]);
  }
  db.execute("INSERT INTO edges VALUES('edge','map','a','b')");
  db.execute('PRAGMA user_version=3');
  return db;
}

Set<Object?> _columns(sqlite.Database db, String table) =>
    db.select('PRAGMA table_info($table)').map((r) => r['name']).toSet();
Future<void> _archive(String path, String destination, int version) async {
  final bytes = await File(path).readAsBytes();
  final manifest = utf8.encode(
    jsonEncode({
      'formatVersion': 1,
      'schemaVersion': version,
      'files': [
        {
          'path': 'library.sqlite',
          'size': bytes.length,
          'sha256': sha256.convert(bytes).toString(),
        },
      ],
    }),
  );
  final archive = Archive()
    ..addFile(ArchiveFile('library.sqlite', bytes.length, bytes))
    ..addFile(ArchiveFile('manifest.json', manifest.length, manifest));
  await File(destination).writeAsBytes(ZipEncoder().encode(archive));
}
