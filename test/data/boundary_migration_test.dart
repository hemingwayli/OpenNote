import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opennote/data/database.dart';
import 'package:opennote/data/open_note_repository.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../support/legacy_database_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  setUp(
    () async => temp = await Directory.systemTemp.createTemp(
      'opennote-boundary-migrate-',
    ),
  );
  tearDown(() async => temp.delete(recursive: true));
  test('真实 v4 WAL 库升级 v5 保存一致性快照，v4 备份恢复后外框可编辑', () async {
    final folder = await Directory('${temp.path}/library/libraries/legacy')
        .create(recursive: true);
    await File('${temp.path}/library/active.json')
        .writeAsString(jsonEncode({'libraryId': 'legacy'}), encoding: utf8);
    final old = _legacy('${folder.path}/library.sqlite');
    old.execute('PRAGMA journal_mode=WAL');
    old.execute('PRAGMA wal_autocheckpoint=0');
    old.execute("UPDATE edges SET label='WAL 最新关联' WHERE id='edge'");
    final repo = await OpenNoteRepository.open(
      rootPath: '${temp.path}/library',
    );
    try {
      expect((await repo.loadMap('map')).boundaries, isEmpty);
      expect((await repo.loadMap('map')).edges.single.label, 'WAL 最新关联');
      final file = folder.listSync().whereType<File>().singleWhere(
        (f) => f.path.contains('.before-v$currentDatabaseVersion-'),
      );
      final read = sqlite.sqlite3.open(
        file.path,
        mode: sqlite.OpenMode.readOnly,
      );
      try {
        expect(read.select('PRAGMA user_version').single.values.single, 4);
        expect(
          read.select("SELECT name FROM sqlite_master WHERE name='boundaries'"),
          isEmpty,
        );
        expect(
          read.select('SELECT label FROM edges').single['label'],
          'WAL 最新关联',
        );
      } finally {
        read.close();
      }
      final archive = '${temp.path}/v4.onbackup';
      await _archive(file.path, archive, 4);
      await repo.createBoundaries('map', {'b'});
      await repo.restoreFrom(archive);
      expect((await repo.loadMap('map')).boundaries, isEmpty);
      final id = (await repo.createBoundaries('map', {'b'})).single;
      await repo.updateBoundary(id, label: '恢复后分组');
      expect((await repo.loadMap('map')).boundaries.single.label, '恢复后分组');
    } finally {
      await repo.close();
      old.close();
    }
  });
  test('v5 建表冲突保持 v4 原数据和版本，禁止覆盖重建', () async {
    final path = '${temp.path}/conflict.sqlite';
    final old = _legacy(path);
    old.execute('CREATE TABLE boundaries(id TEXT)');
    old.close();
    await expectLater(
      upgradeStagedDatabase(path),
      throwsA(isA<sqlite.SqliteException>()),
    );
    final read = sqlite.sqlite3.open(path);
    try {
      expect(read.select('PRAGMA user_version').single.values.single, 4);
      expect(read.select('SELECT id FROM edges').single['id'], 'edge');
      expect(
        read.select(
          "SELECT name FROM sqlite_master WHERE name='boundaries_map'",
        ),
        isEmpty,
      );
    } finally {
      read.close();
    }
  });
  test('v5 外框越图或非法样式备份拒绝，活动库和会话保持', () async {
    final repo = await OpenNoteRepository.open(
      rootPath: '${temp.path}/current',
    );
    try {
      await repo.createProject('保留');
      final session = repo.sessionId,
          path = repo.libraryPath,
          count = repo.undoEntryCount;
      final invalid = '${temp.path}/invalid.sqlite', db = _legacy(invalid);
      for (final sql in boundarySchema) {
        db.execute(sql);
      }
      db.execute('PRAGMA user_version=5');
      db.execute(
        "INSERT INTO boundaries VALUES('box','map','a','[\"a\"]','','{}')",
      );
      db.close();
      final archive = '${temp.path}/invalid.onbackup';
      await _archive(invalid, archive, 5);
      await expectLater(repo.restoreFrom(archive), throwsA(anything));
      expect(repo.libraryPath, path);
      expect(repo.sessionId, session);
      expect(repo.undoEntryCount, count);
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
    ...legacyRelationshipSchemaV4,
  ]) {
    db.execute(sql);
  }
  db.execute("INSERT INTO projects VALUES('project','旧项目',1,NULL)");
  db.execute("INSERT INTO maps VALUES('map','project','旧图',NULL,'right')");
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
    db.execute('INSERT INTO nodes VALUES(?,?,?,?,0,0,220,116,0,NULL,0,NULL)', [
      id,
      'map',
      'card-$id',
      id == 'b' ? 'a' : null,
    ]);
  }
  db.execute("INSERT INTO edges VALUES('edge','map','a','b','关系','{}')");
  db.execute('PRAGMA user_version=4');
  return db;
}

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
  await File(destination).writeAsBytes(
    ZipEncoder().encode(
      Archive()
        ..addFile(ArchiveFile('library.sqlite', bytes.length, bytes))
        ..addFile(ArchiveFile('manifest.json', manifest.length, manifest)),
    ),
  );
}
