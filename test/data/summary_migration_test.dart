import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:opennote/data/database.dart';
import 'package:opennote/data/open_note_repository.dart';

import '../support/legacy_database_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('opennote-summary-migration-');
  });
  tearDown(() async {
    await temp.delete(recursive: true);
  });
  test('真实 v5 WAL 库含旧外框一致性快照；v5 备份暂存升级后才切换', () async {
    final folder = await Directory('${temp.path}/library/libraries/legacy')
        .create(recursive: true);
    await File('${temp.path}/library/active.json')
        .writeAsString(jsonEncode({'libraryId': 'legacy'}), encoding: utf8);
    final old = _legacy('${folder.path}/library.sqlite');
    old.execute('PRAGMA journal_mode=WAL');
    old.execute('PRAGMA wal_autocheckpoint=0');
    old.execute("UPDATE boundaries SET label='WAL 最新外框' WHERE id='box'");
    final repo = await OpenNoteRepository.open(
      rootPath: '${temp.path}/library',
    );
    try {
      expect((await repo.loadMap('map')).boundaries.single.label, 'WAL 最新外框');
      expect((await repo.loadMap('map')).summaries, isEmpty);
      final snapshot = folder.listSync().whereType<File>().singleWhere(
        (f) => f.path.contains('.before-v$currentDatabaseVersion-'),
      );
      final read = sqlite.sqlite3.open(
        snapshot.path,
        mode: sqlite.OpenMode.readOnly,
      );
      expect(read.select('PRAGMA user_version').single.values.single, 5);
      expect(
        read.select('SELECT label FROM boundaries').single['label'],
        'WAL 最新外框',
      );
      expect(
        read.select("SELECT name FROM sqlite_master WHERE name='summaries'"),
        isEmpty,
      );
      read.close();
      final archive = '${temp.path}/v5.onbackup';
      await _archive(snapshot.path, archive, 5);
      await repo.createSummaries('map', {'a', 'b'});
      await repo.restoreFrom(archive);
      expect((await repo.loadMap('map')).summaries, isEmpty);
      await repo.createSummaries('map', {'a', 'b'});
      expect((await repo.loadMap('map')).summaries, hasLength(1));
    } finally {
      await repo.close();
      old.close();
    }
  });
  test('v6 表冲突事务失败保留 v5 版本、旧外框和卡片，不覆盖重建', () async {
    final path = '${temp.path}/conflict.sqlite', db = _legacy(path);
    db.execute('CREATE TABLE summaries(id TEXT)');
    db.close();
    await expectLater(
      upgradeStagedDatabase(path),
      throwsA(isA<sqlite.SqliteException>()),
    );
    final read = sqlite.sqlite3.open(path);
    expect(read.select('PRAGMA user_version').single.values.single, 5);
    expect(read.select('SELECT label FROM boundaries').single['label'], '旧外框');
    expect(read.select('SELECT * FROM cards'), hasLength(3));
    expect(
      read.select("SELECT name FROM sqlite_master WHERE name='summaries_map'"),
      isEmpty,
    );
    read.close();
  });
  test('v6 自引用／跨父范围和非法样式备份拒绝，当前库与历史不切换', () async {
    final repo = await OpenNoteRepository.open(
      rootPath: '${temp.path}/current',
    );
    try {
      await repo.createProject('保留');
      final path = repo.libraryPath,
          session = repo.sessionId,
          count = repo.undoEntryCount;
      for (final payload in ['["root"]', '["a"]']) {
        final invalid = '${temp.path}/invalid-${payload.length}.sqlite',
            db = _legacy(invalid);
        for (final sql in summarySchema) {
          db.execute(sql);
        }
        db.execute('INSERT INTO summaries VALUES(?,?,?,?,?,?)', [
          'summary',
          'map',
          'root',
          'a',
          payload,
          '{}',
        ]);
        db.execute('PRAGMA user_version=6');
        db.close();
        final archive = '$invalid.onbackup';
        await _archive(invalid, archive, 6);
        await expectLater(repo.restoreFrom(archive), throwsA(anything));
        expect(repo.libraryPath, path);
        expect(repo.sessionId, session);
        expect(repo.undoEntryCount, count);
      }
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
    ...legacyBoundarySchemaV5,
  ]) {
    db.execute(sql);
  }
  db.execute("INSERT INTO projects VALUES('project','旧项目',1,NULL)");
  db.execute("INSERT INTO maps VALUES('map','project','旧图',NULL,'right')");
  for (final id in ['root', 'a', 'b']) {
    db.execute('INSERT INTO cards VALUES(?,?,?,?,?,?,?,NULL,1,NULL)', [
      'card-$id',
      'project',
      id,
      '快照',
      '正文',
      '备注',
      '#F7D976',
    ]);
    db.execute('INSERT INTO nodes VALUES(?,?,?,?,0,0,220,116,0,NULL,?,NULL)', [
      id,
      'map',
      'card-$id',
      id == 'root' ? null : 'root',
      id == 'b' ? 1 : 0,
    ]);
  }
  db.execute(
    "INSERT INTO boundaries VALUES('box','map','root','[\"a\",\"b\"]','旧外框','{}')",
  );
  db.execute('PRAGMA user_version=5');
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
