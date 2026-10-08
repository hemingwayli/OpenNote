import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:opennote/data/database.dart';
import 'package:opennote/data/open_note_repository.dart';

import '../support/legacy_database_fixture.dart';

sqlite.Database legacy(String path) {
  final db = sqlite.sqlite3.open(path);
  for (final sql in [
    ...legacySchemaV1,
    ...legacyHomeSchemaV2,
    ...legacyMapLayoutSchemaV3,
    ...legacyRelationshipSchemaV4,
    ...legacyBoundarySchemaV5,
    ...legacySummarySchemaV6,
    ...legacyTopicStyleSchemaV7,
  ]) {
    db.execute(sql);
  }
  db.execute("INSERT INTO projects VALUES('p','旧项目',1,NULL)");
  db.execute("INSERT INTO maps VALUES('m','p','旧图',NULL,'right','{}')");
  db.execute(
    "INSERT INTO cards VALUES('c','p','主题','快照','正文','备注','#F7D976',NULL,1,NULL)",
  );
  db.execute(
    "INSERT INTO nodes VALUES('n','m','c',NULL,77,88,220,116,0,NULL,0,NULL,'{}')",
  );
  db.execute('PRAGMA user_version=7');
  return db;
}

Future<void> backup(String path, String destination, int version) async {
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('opennote-v8-');
  });
  tearDown(() async {
    await temp.delete(recursive: true);
  });
  test('真实 v7 WAL 快照保留最新正文和样式，v7 备份暂存升级后切换且坐标不变', () async {
    final root = '${temp.path}/library',
        folder = await Directory('$root/libraries/old').create(recursive: true);
    await File('$root/active.json')
        .writeAsString(jsonEncode({'libraryId': 'old'}), encoding: utf8);
    final old = legacy('${folder.path}/library.sqlite');
    old.execute('PRAGMA journal_mode=WAL');
    old.execute('PRAGMA wal_autocheckpoint=0');
    old.execute("UPDATE cards SET body='最新 WAL 正文' WHERE id='c'");
    final repo = await OpenNoteRepository.open(rootPath: root);
    try {
      var snapshot = await repo.loadMap('m');
      expect(snapshot.nodes.single.branchLayout, isNull);
      expect([snapshot.nodes.single.x, snapshot.nodes.single.y], [77, 88]);
      expect(snapshot.nodes.single.style, isNotNull);
      final file = folder.listSync().whereType<File>().singleWhere(
        (f) => f.path.contains('.before-v$currentDatabaseVersion-'),
      );
      final read = sqlite.sqlite3.open(
        file.path,
        mode: sqlite.OpenMode.readOnly,
      );
      expect(read.select('PRAGMA user_version').single.values.single, 7);
      expect(
        read
            .select('PRAGMA table_info(nodes)')
            .any((r) => r['name'] == 'branch_layout'),
        isFalse,
      );
      expect(read.select('SELECT body FROM cards').single['body'], '最新 WAL 正文');
      read.close();
      final archive = '${temp.path}/v7.onbackup';
      await backup(file.path, archive, 7);
      await repo.createProject('临时');
      await repo.restoreFrom(archive);
      snapshot = await repo.loadMap('m');
      expect(snapshot.nodes.single.branchLayout, isNull);
      expect(snapshot.cards['c']!.body, '最新 WAL 正文');
    } finally {
      await repo.close();
      old.close();
    }
  });
  test('v8 升级字段冲突完整回滚，原 v7 内容和样式保持', () async {
    final path = '${temp.path}/conflict.sqlite',
        db = legacy('${temp.path}/conflict.sqlite');
    db.execute('ALTER TABLE nodes ADD COLUMN branch_layout TEXT');
    db.close();
    await expectLater(
      upgradeStagedDatabase(path),
      throwsA(isA<sqlite.SqliteException>()),
    );
    final read = sqlite.sqlite3.open(path);
    expect(read.select('PRAGMA user_version').single.values.single, 7);
    expect(read.select('SELECT body FROM cards').single['body'], '正文');
    expect(
      read
          .select('SELECT topic_style_json FROM nodes')
          .single['topic_style_json'],
      '{}',
    );
    read.close();
  });
  test('缺失或非法 v8 结构字段、未来备份拒绝且当前会话和历史不切换', () async {
    final repo = await OpenNoteRepository.open(
      rootPath: '${temp.path}/current',
    );
    try {
      await repo.createProject('保留');
      final library = repo.libraryPath,
          session = repo.sessionId,
          count = repo.undoEntryCount;
      for (var i = 0; i < 3; i++) {
        final path = '${temp.path}/invalid-$i.sqlite',
            db = legacy('${temp.path}/invalid-$i.sqlite');
        if (i == 1) {
          db.execute('ALTER TABLE nodes ADD COLUMN branch_layout TEXT');
          db.execute("UPDATE nodes SET branch_layout='鱼骨不支持'");
        }
        db.execute('PRAGMA user_version=${i == 2 ? currentDatabaseVersion + 1 : 8}');
        db.close();
        await backup(path, '$path.onbackup', i == 2 ? currentDatabaseVersion + 1 : 8);
        await expectLater(
          repo.restoreFrom('$path.onbackup'),
          throwsA(anything),
        );
        expect(repo.libraryPath, library);
        expect(repo.sessionId, session);
        expect(repo.undoEntryCount, count);
      }
    } finally {
      await repo.close();
    }
  });
}
