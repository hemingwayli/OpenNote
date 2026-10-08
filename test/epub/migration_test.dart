import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:opennote/data/database.dart';

void main() {
  late Directory root;
  late String path;
  const quads =
      '[{"points":[{"x":1.0,"y":8.0},{"x":9.0,"y":8.0},{"x":9.0,"y":2.0},{"x":1.0,"y":2.0}]}]';
  setUp(() async {
    root = await Directory.systemTemp.createTemp('opennote-v10-');
    path = '${root.path}/library.sqlite';
    final database = sqlite3.open(path);
    try {
      for (final sql in jsonDecode(
        await File('test/epub/fixtures/schema-v10.json').readAsString(),
      ) as List) {
        database.execute(sql as String);
      }
      database.execute('PRAGMA user_version=10');
      database.execute('PRAGMA journal_mode=WAL');
      database.execute("INSERT INTO projects VALUES ('p','项目',1,NULL)");
      database.execute(
        "INSERT INTO resources VALUES ('resource','hash','pdf',0,'resources/hash.pdf')",
      );
      database.execute(
        "INSERT INTO documents VALUES ('doc','p','原文','revision',NULL)",
      );
      database.execute(
        "INSERT INTO revisions VALUES ('revision','doc','resource','hash',2,'[]')",
      );
      database.execute(
        "INSERT INTO cards (id,project_id,title,excerpt_snapshot,body,note,color,updated_at,thoughts_json) VALUES ('card','p','原卡','原文','正文','','#F7D976',1,'[]')",
      );
      database.execute(
        "INSERT INTO anchors VALUES ('anchor','card','revision',1,?,NULL,NULL,NULL,'来源上下文')",
        [quads],
      );
      database.execute(
        "INSERT INTO annotations VALUES ('annotation','revision',1,?,'highlight','','#F7D976','card')",
        [quads],
      );
      database.execute(
        "INSERT INTO reading_positions VALUES ('revision',1,0.75)",
      );
    } finally {
      database.close();
    }
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });
  test('真实 v10 SQL 升级保留 PDF 身份几何与 WAL 一致性快照', () async {
    await upgradeStagedDatabase(path);
    final database = sqlite3.open(path);
    try {
      expect(database.select('PRAGMA user_version').single.values.single, 11);
      final anchor = database.select('SELECT * FROM anchors').single;
      expect(anchor['id'], 'anchor');
      expect(anchor['page_index'], 1);
      expect(anchor['quads'], quads);
      expect(anchor['locator_json'], isNull);
      expect(
        database.select('SELECT format FROM revisions').single['format'],
        'pdf',
      );
      expect(database.select('SELECT body FROM cards').single['body'], '正文');
      expect(
        database
            .select('SELECT offset FROM reading_positions')
            .single['offset'],
        0.75,
      );
      expect(database.select('PRAGMA foreign_key_check'), isEmpty);
    } finally {
      database.close();
    }
    final snapshot = root.listSync().whereType<File>().singleWhere(
      (f) => f.path.contains('.before-v11-'),
    );
    final old = sqlite3.open(snapshot.path);
    try {
      expect(old.select('PRAGMA user_version').single.values.single, 10);
      expect(old.select('SELECT quads FROM anchors').single['quads'], quads);
    } finally {
      old.close();
    }
  });
  test('迁移中途失败回滚原表、版本与用户内容', () async {
    final old = sqlite3.open(path);
    old.execute('CREATE TABLE epub_sections (id TEXT PRIMARY KEY)');
    old.close();
    await expectLater(
      upgradeStagedDatabase(path),
      throwsA(isA<SqliteException>()),
    );
    final database = sqlite3.open(path);
    try {
      expect(database.select('PRAGMA user_version').single.values.single, 10);
      expect(
        database.select('SELECT quads FROM anchors').single['quads'],
        quads,
      );
      expect(
        database
            .select('PRAGMA table_info(revisions)')
            .any((r) => r['name'] == 'format'),
        isFalse,
      );
      expect(database.select('SELECT body FROM cards').single['body'], '正文');
    } finally {
      database.close();
    }
  });
  test('自定义来源触发器保留并拒绝自动重建', () async {
    final old = sqlite3.open(path);
    old.execute(
      'CREATE TRIGGER user_anchor AFTER INSERT ON anchors BEGIN SELECT 1; END',
    );
    old.close();
    await expectLater(upgradeStagedDatabase(path), throwsStateError);
    final database = sqlite3.open(path);
    try {
      expect(
        database
            .select("SELECT name FROM sqlite_master WHERE name='user_anchor'")
            .length,
        1,
      );
      expect(database.select('PRAGMA user_version').single.values.single, 10);
    } finally {
      database.close();
    }
  });
}
