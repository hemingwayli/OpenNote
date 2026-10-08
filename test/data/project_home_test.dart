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
  late OpenNoteRepository repo;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('opennote-project-home-');
    repo = await OpenNoteRepository.open(rootPath: temp.path);
  });
  tearDown(() async {
    await repo.close();
    await temp.delete(recursive: true);
  });

  test('分类分页聚合、全局字面搜索与文件夹删除撤销不覆盖最近阅读', () async {
    final folder = await repo.createProjectFolder('研究');
    final project = await repo.createProject('研究_100%', folderId: folder);
    await repo.createProject('其他项目');
    final page = await repo.queryProjectPage(folderId: folder);
    expect(page.total, 1);
    expect(page.items.single.mapCount, 1);
    expect(
      (await repo.queryProjectPage(query: '_100%', unclassified: true)).total,
      1,
    );
    await repo.saveProjectResume(
      project.id,
      openedDocumentIds: [],
      markOpened: true,
    );
    final recent = (await repo.loadProjectResume(project.id))!.lastOpenedAt;
    await repo.deleteProjectFolder(folder);
    expect((await repo.queryProjectPage(unclassified: true)).total, 2);
    await repo.undo();
    expect((await repo.queryProjectPage(folderId: folder)).total, 1);
    expect((await repo.loadProjectResume(project.id))!.lastOpenedAt, recent);
    await repo.redo();
    expect(await repo.listProjectFolders(), isEmpty);
  });

  test('导航记录不占撤销并保留重做，最近封面、标签和分类随备份恢复', () async {
    final folder = await repo.createProjectFolder('阅读');
    final project = await repo.createProject('项目', folderId: folder);
    final first = await repo.importPdf(
      projectId: project.id,
      filePath: File('tools/fixtures/pdf/native.pdf').absolute.path,
      title: 'A',
    );
    final second = await repo.importPdf(
      projectId: project.id,
      filePath: File('tools/fixtures/pdf/ui-reading.pdf').absolute.path,
      title: 'B',
    );
    await repo.renameProject(project.id, '修改标题');
    await repo.undo();
    final history = repo.undoEntryCount;
    await repo.saveProjectResume(
      project.id,
      activeDocumentId: second.id,
      openedDocumentIds: [second.id, first.id],
      successfullyReadDocumentId: second.id,
      markOpened: true,
    );
    expect(repo.undoEntryCount, history);
    expect(repo.canRedo, isTrue);
    final revision = await repo.getRevision(second.activeRevisionId);
    expect(
      (await repo.queryProjectPage()).items.single.coverHash,
      revision.contentHash,
    );
    final backup = '${temp.path}/copy.onbackup';
    await repo.backupTo(backup);
    await repo.deleteProjectFolder(folder);
    await repo.restoreFrom(backup);
    expect((await repo.listProjectFolders()).single.title, '阅读');
    expect((await repo.loadProjectResume(project.id))!.openedDocumentIds, [
      second.id,
      first.id,
    ]);
    await repo.trashDocument(second.id);
    expect(
      (await repo.queryProjectPage()).items.single.coverHash,
      (await repo.getRevision(first.activeRevisionId)).contentHash,
    );
    final trash = (await repo.listTrash()).single;
    await repo.purgeTrash(trash.id, discardSessionHistory: true);
    final state = (await repo.loadProjectResume(project.id))!;
    expect(state.openedDocumentIds, [first.id]);
    expect(state.lastReadDocumentId, isNull);
  });

  test('项目回收恢复保留分类，永久清理级联移除导航数据', () async {
    final folder = await repo.createProjectFolder('分类');
    final project = await repo.createProject('项目', folderId: folder);
    await repo.saveProjectResume(
      project.id,
      openedDocumentIds: [],
      markOpened: true,
    );
    await repo.trashProject(project.id);
    expect((await repo.queryProjectPage()).total, 0);
    final entry = (await repo.listTrash()).single;
    await repo.restoreTrash(entry.id);
    expect((await repo.queryProjectPage(folderId: folder)).total, 1);
    await repo.trashProject(project.id);
    await repo.purgeTrash(
      (await repo.listTrash()).single.id,
      discardSessionHistory: true,
    );
    expect(await repo.loadProjectResume(project.id), isNull);
  });

  test('v1 WAL 数据升级前快照完整，旧备份在暂存区升级后激活', () async {
    final old = await Directory('${temp.path}/old/libraries/legacy')
        .create(recursive: true);
    await File('${temp.path}/old/active.json')
        .writeAsString(jsonEncode({'libraryId': 'legacy'}));
    final path = '${old.path}/library.sqlite';
    final db = sqlite.sqlite3.open(path);
    db.execute('PRAGMA journal_mode=WAL');
    for (final statement in legacySchemaV1) {
      db.execute(statement);
    }
    db.execute('PRAGMA user_version=1');
    db.execute("INSERT INTO projects VALUES('old','旧项目',1,NULL)");
    final upgraded = await OpenNoteRepository.open(
      rootPath: '${temp.path}/old',
    );
    try {
      expect(
        (await upgraded.queryProjectPage(unclassified: true))
            .items
            .single
            .project
            .title,
        '旧项目',
      );
      final snapshot = old.listSync().whereType<File>().singleWhere(
        (f) => f.path.contains('.before-v$currentDatabaseVersion-'),
      );
      final read = sqlite.sqlite3.open(
        snapshot.path,
        mode: sqlite.OpenMode.readOnly,
      );
      expect(read.select('PRAGMA user_version').single.values.single, 1);
      expect(read.select('SELECT title FROM projects').single['title'], '旧项目');
      read.close();
      final bytes = await snapshot.readAsBytes();
      final manifest = utf8.encode(
        jsonEncode({
          'formatVersion': 1,
          'schemaVersion': 1,
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
      final backup = File('${temp.path}/legacy.onbackup');
      await backup.writeAsBytes(ZipEncoder().encode(archive));
      await repo.restoreFrom(backup.path);
      expect((await repo.queryProjectPage()).items.single.project.title, '旧项目');
      expect(await repo.createProjectFolder('已升级'), isNotEmpty);
    } finally {
      await upgraded.close();
      db.close();
    }
  });

  test('升级中途失败事务回滚，原库和一致性快照保留', () async {
    final path = '${temp.path}/broken-v1.sqlite';
    final db = sqlite.sqlite3.open(path);
    for (final statement in legacySchemaV1) {
      db.execute(statement);
    }
    db.execute("INSERT INTO projects VALUES('old','不能丢失',1,NULL)");
    // 制造第二张新增表冲突，确认第一张表的创建也会回滚。
    db.execute('CREATE TABLE project_memberships (id TEXT PRIMARY KEY)');
    db.execute('PRAGMA user_version=1');
    db.close();
    await expectLater(
      upgradeStagedDatabase(path),
      throwsA(isA<sqlite.SqliteException>()),
    );
    final read = sqlite.sqlite3.open(path);
    try {
      expect(read.select('PRAGMA user_version').single.values.single, 1);
      expect(read.select('SELECT title FROM projects').single['title'], '不能丢失');
      expect(
        read.select(
          "SELECT name FROM sqlite_master WHERE name='project_folders'",
        ),
        isEmpty,
      );
      expect(
        temp.listSync().where(
          (f) => f.path.contains(
            'broken-v1.sqlite.before-v$currentDatabaseVersion-',
          ),
        ),
        hasLength(1),
      );
    } finally {
      read.close();
    }
  });

  test('5000 项目分页数量和排序稳定，不加载正文', () async {
    final path = '${repo.libraryPath}/library.sqlite';
    final db = sqlite.sqlite3.open(path);
    try {
      db.execute('BEGIN');
      final statement = db.prepare('INSERT INTO projects VALUES(?,?,?,NULL)');
      try {
        for (var i = 0; i < 5000; i++) {
          statement.execute(['p$i', '项目 ${i.toString().padLeft(4, '0')}', i]);
        }
      } finally {
        statement.close();
      }
      db.execute('COMMIT');
    } finally {
      db.close();
    }
    final first = await repo.queryProjectPage(
      limit: 60,
      sort: ProjectSort.name,
    );
    final second = await repo.queryProjectPage(
      limit: 60,
      offset: 60,
      sort: ProjectSort.name,
    );
    expect(first.total, 5000);
    expect(first.items.length, 60);
    expect(second.items.first.project.title, '项目 0060');
    expect(
      first.items
          .map((p) => p.project.id)
          .toSet()
          .intersection(second.items.map((p) => p.project.id).toSet()),
      isEmpty,
    );
  });
}
