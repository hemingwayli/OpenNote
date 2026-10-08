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
      'opennote-layout-migration-',
    ),
  );
  tearDown(() async => temp.delete(recursive: true));

  for (final version in [1, 2]) {
    test(
      '真实 v$version WAL 库升级 v$currentDatabaseVersion：快照保留旧结构、坐标和已提交数据，旧备份可恢复',
      () async {
        final folder = await Directory('${temp.path}/old/libraries/legacy')
            .create(recursive: true);
        await File('${temp.path}/old/active.json')
            .writeAsString(jsonEncode({'libraryId': 'legacy'}), encoding: utf8);
        final db = _legacy('${folder.path}/library.sqlite', version);
        db.execute('PRAGMA journal_mode=WAL');
        db.execute('PRAGMA wal_autocheckpoint=0');
        db.execute(
          "UPDATE cards SET note='保留 WAL 中的个人备注' WHERE id='card-child'",
        );
        final repo = await OpenNoteRepository.open(
          rootPath: '${temp.path}/old',
        );
        try {
          final snapshot = await repo.loadMap('map');
          expect(snapshot.map.layout, MapLayoutKind.free);
          final node = snapshot.nodes.firstWhere((n) => n.id == 'child');
          expect(
            [node.x, node.y, node.sortIndex, node.branchSide],
            [390.0, 220.0, null, null],
          );
          expect(snapshot.cards['card-child']!.note, '保留 WAL 中的个人备注');
          final original = folder.listSync().whereType<File>().singleWhere(
            (f) => f.path.contains('.before-v$currentDatabaseVersion-'),
          );
          final read = sqlite.sqlite3.open(
            original.path,
            mode: sqlite.OpenMode.readOnly,
          );
          try {
            expect(
              read.select('PRAGMA user_version').single.values.single,
              version,
            );
            expect(_columns(read, 'maps'), isNot(contains('layout_kind')));
            expect(
              read
                  .select("SELECT note FROM cards WHERE id='card-child'")
                  .single['note'],
              '保留 WAL 中的个人备注',
            );
            if (version == 2) {
              expect(
                read
                    .select('SELECT title FROM project_folders')
                    .single['title'],
                '旧分类',
              );
            }
          } finally {
            read.close();
          }
          final backup = '${temp.path}/legacy-$version.onbackup';
          await _archiveDatabase(original.path, backup, version);
          await repo.setMapLayout('map', MapLayoutKind.down);
          await repo.restoreFrom(backup);
          expect((await repo.loadMap('map')).map.layout, MapLayoutKind.free);
          expect(
            (await repo.loadMap('map')).cards['card-child']!.note,
            '保留 WAL 中的个人备注',
          );
          if (version == 2) {
            expect((await repo.listProjectFolders()).single.title, '旧分类');
            expect((await repo.loadProjectResume('project'))!.mapId, 'map');
          }
          await repo.setMapLayout('map', MapLayoutKind.left);
          expect((await repo.loadMap('map')).map.layout, MapLayoutKind.left);
        } finally {
          await repo.close();
          db.close();
        }
      },
    );
  }

  test('v2 第三列迁移失败时前两列和版本一并回滚，原库及一致性快照保留', () async {
    final path = '${temp.path}/broken.sqlite';
    final db = _legacy(path, 2);
    db.execute('ALTER TABLE nodes ADD COLUMN branch_side INTEGER');
    db.close();
    await expectLater(
      upgradeStagedDatabase(path),
      throwsA(isA<sqlite.SqliteException>()),
    );
    final read = sqlite.sqlite3.open(path);
    try {
      expect(read.select('PRAGMA user_version').single.values.single, 2);
      expect(_columns(read, 'maps'), isNot(contains('layout_kind')));
      expect(_columns(read, 'nodes'), isNot(contains('sort_index')));
      expect(
        read
            .select("SELECT title FROM cards WHERE id='card-child'")
            .single['title'],
        '子主题',
      );
      final backups = temp
          .listSync()
          .whereType<File>()
          .where((f) => f.path.contains('.before-v$currentDatabaseVersion-'))
          .toList();
      expect(backups, hasLength(1));
      final original = sqlite.sqlite3.open(backups.single.path);
      try {
        expect(original.select('PRAGMA user_version').single.values.single, 2);
      } finally {
        original.close();
      }
    } finally {
      read.close();
    }
  });

  test('v3 备份缺少布局字段拒绝激活，活动库、会话、历史与指针不变', () async {
    final repo = await OpenNoteRepository.open(
      rootPath: '${temp.path}/current',
    );
    try {
      final project = await repo.createProject('当前数据不能丢失');
      final originalPath = repo.libraryPath;
      final originalSession = repo.sessionId;
      final history = repo.undoEntryCount;
      final pointer = await File('${temp.path}/current/active.json')
          .readAsBytes();
      final brokenPath = '${temp.path}/fake-v3.sqlite';
      final db = _legacy(brokenPath, 2);
      db.execute('PRAGMA user_version=3');
      db.close();
      final backup = '${temp.path}/fake-v3.onbackup';
      await _archiveDatabase(brokenPath, backup, 3);
      await expectLater(
        repo.restoreFrom(backup),
        throwsA(isA<RepositoryException>()),
      );
      expect(repo.libraryPath, originalPath);
      expect(repo.sessionId, originalSession);
      expect(repo.undoEntryCount, history);
      expect(
        await File('${temp.path}/current/active.json').readAsBytes(),
        pointer,
      );
      expect((await repo.listProjects()).single.id, project.id);
      await repo.renameProject(project.id, '恢复失败后仍可保存');
      expect((await repo.listProjects()).single.title, '恢复失败后仍可保存');
    } finally {
      await repo.close();
    }
  });
}

sqlite.Database _legacy(String path, int version) {
  final db = sqlite.sqlite3.open(path);
  for (final statement in legacySchemaV1) {
    db.execute(statement);
  }
  if (version == 2) {
    for (final statement in legacyHomeSchemaV2) {
      db.execute(statement);
    }
  }
  db.execute("INSERT INTO projects VALUES('project','旧学习项目',1,NULL)");
  db.execute("INSERT INTO maps VALUES('map','project','保留旧脑图',NULL)");
  for (final id in ['root', 'child']) {
    db.execute('INSERT INTO cards VALUES(?,?,?,?,?,?,?,NULL,1,NULL)', [
      'card-$id',
      'project',
      id == 'root' ? '中心主题' : '子主题',
      '原文快照',
      '正文内容',
      '个人备注',
      '#F7D976',
    ]);
    db.execute('INSERT INTO nodes VALUES(?,?,?,?,?,?,220,116,0,NULL)', [
      id,
      'map',
      'card-$id',
      id == 'root' ? null : 'root',
      id == 'root' ? 80 : 390,
      id == 'root' ? 80 : 220,
    ]);
  }
  if (version == 2) {
    db.execute("INSERT INTO project_folders VALUES('folder','旧分类',1)");
    db.execute("INSERT INTO project_memberships VALUES('project','folder')");
    db.execute(
      "INSERT INTO project_sessions VALUES('project',123,NULL,NULL,'map','[]')",
    );
  }
  db.execute('PRAGMA user_version=$version');
  return db;
}

Set<Object?> _columns(sqlite.Database db, String table) =>
    db.select('PRAGMA table_info($table)').map((r) => r['name']).toSet();

Future<void> _archiveDatabase(
  String path,
  String destination,
  int version,
) async {
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
