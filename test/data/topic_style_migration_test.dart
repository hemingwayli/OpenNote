import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:opennote/data/database.dart';
import 'package:opennote/data/open_note_repository.dart';
import 'package:opennote/domain/models.dart';

import '../support/legacy_database_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('opennote-format-migration-');
  });
  tearDown(() async {
    await temp.delete(recursive: true);
  });
  test('真实 v6 WAL 快照保留概要和最新正文；旧备份暂存升级到 v7 后才切换', () async {
    final folder = await Directory('${temp.path}/library/libraries/legacy')
        .create(recursive: true);
    await File('${temp.path}/library/active.json')
        .writeAsString(jsonEncode({'libraryId': 'legacy'}), encoding: utf8);
    final old = legacy('${folder.path}/library.sqlite');
    old.execute('PRAGMA journal_mode=WAL');
    old.execute('PRAGMA wal_autocheckpoint=0');
    old.execute("UPDATE cards SET body='最新 WAL 正文' WHERE id='card-a'");
    final repo = await OpenNoteRepository.open(
      rootPath: '${temp.path}/library',
    );
    try {
      var snapshot = await repo.loadMap('map');
      expect(snapshot.cards['card-a']!.body, '最新 WAL 正文');
      expect(snapshot.map.defaultStyle, const TopicStyle());
      expect(snapshot.nodes.every((n) => n.style == null), isTrue);
      expect(snapshot.summaries.single.style.topic.textSize, 18);
      final file = folder.listSync().whereType<File>().singleWhere(
        (f) => f.path.contains('.before-v$currentDatabaseVersion-'),
      );
      final read = sqlite.sqlite3.open(
        file.path,
        mode: sqlite.OpenMode.readOnly,
      );
      expect(read.select('PRAGMA user_version').single.values.single, 6);
      expect(
        read
            .select('PRAGMA table_info(maps)')
            .any((r) => r['name'] == 'default_style_json'),
        isFalse,
      );
      expect(
        read.select("SELECT body FROM cards WHERE id='card-a'").single['body'],
        '最新 WAL 正文',
      );
      read.close();
      final archive = '${temp.path}/v6.onbackup';
      await backup(file.path, archive, 6);
      await repo.setTopicStyle('map', {'a'}, const TopicStyle());
      await repo.restoreFrom(archive);
      snapshot = await repo.loadMap('map');
      expect(snapshot.nodes.singleWhere((n) => n.id == 'a').style, isNull);
      expect(snapshot.summaries.single.style.topic.textSize, 18);
      await repo.setTopicStyle(
        'map',
        {'a'},
        const TopicStyle(),
        makeDefault: true,
      );
    } finally {
      await repo.close();
      old.close();
    }
  });
  test('v7 字段冲突升级失败保留 v6 版本、概要、正文和未新增字段', () async {
    final path = '${temp.path}/conflict.sqlite',
        db = legacy('${temp.path}/conflict.sqlite');
    db.execute(
      "ALTER TABLE maps ADD COLUMN default_style_json TEXT NOT NULL DEFAULT '{}'",
    );
    db.close();
    await expectLater(
      upgradeStagedDatabase(path),
      throwsA(isA<sqlite.SqliteException>()),
    );
    final read = sqlite.sqlite3.open(path);
    expect(read.select('PRAGMA user_version').single.values.single, 6);
    expect(read.select('SELECT * FROM summaries'), hasLength(1));
    expect(
      read.select('SELECT body FROM cards').every((r) => r['body'] == '正文'),
      isTrue,
    );
    expect(
      read
          .select('PRAGMA table_info(nodes)')
          .any((r) => r['name'] == 'topic_style_json'),
      isFalse,
    );
    read.close();
  });
  test('非法 v7 默认格式、节点样式和概要重复格式拒绝；活动库和历史不变化', () async {
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
        for (final statement in topicStyleSchema) {
          db.execute(statement);
        }
        db.execute('PRAGMA user_version=7');
        if (i == 0) {
          db.execute("UPDATE maps SET default_style_json='{\"unknown\":1}'");
        }
        if (i == 1) {
          db.execute(
            "UPDATE nodes SET topic_style_json='{\"surface\":{\"textSize\":99}}' WHERE id='a'",
          );
        }
        if (i == 2) {
          db.execute("UPDATE nodes SET topic_style_json='{}' WHERE id='s'");
        }
        db.close();
        await backup(path, '$path.onbackup', 7);
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

sqlite.Database legacy(String path) {
  final db = sqlite.sqlite3.open(path);
  for (final sql in [
    ...legacySchemaV1,
    ...legacyHomeSchemaV2,
    ...legacyMapLayoutSchemaV3,
    ...legacyRelationshipSchemaV4,
    ...legacyBoundarySchemaV5,
    ...legacySummarySchemaV6,
  ]) {
    db.execute(sql);
  }
  db.execute("INSERT INTO projects VALUES('project','旧项目',1,NULL)");
  db.execute("INSERT INTO maps VALUES('map','project','旧图',NULL,'right')");
  for (final id in ['root', 'a', 'b', 's']) {
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
      ['root', 'a', 'b', 's'].indexOf(id),
    ]);
  }
  db.execute('INSERT INTO summaries VALUES(?,?,?,?,?,?)', [
    'sum',
    'map',
    'root',
    's',
    '["a","b"]',
    '{"topic":{"textSize":18}}',
  ]);
  db.execute('PRAGMA user_version=6');
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
