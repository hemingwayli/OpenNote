import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opennote/data/database.dart';
import 'package:opennote/data/open_note_repository.dart';
import 'package:opennote/domain/map_clipboard.dart';
import 'package:opennote/domain/models.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'extended_structure_migration_test.dart' as v8;
import 'mixed_structure_migration_test.dart' as archives;

// 冻结 v9 升级后的旧卡片表；思考迁移样例没有 thoughts_json 字段。
sqlite.Database legacy9(String path) {
  final db = v8.legacy8(path);
  for (final table in ['maps', 'nodes']) {
    final original =
        db.select('SELECT sql FROM sqlite_master WHERE type=? AND name=?', [
              'table',
              table,
            ]).single['sql']
            as String;
    final updated = original.replaceAll(
      "'free','right','left','mindMap','down','up'",
      "'free','right','left','mindMap','down','up','treeRight','treeLeft','braceRight','braceLeft','timeline','timelineVertical','fishboneLeft','fishboneRight'",
    );
    // 仅扩展冻结旧库的 CHECK；卡片表始终来自冻结 v1 表结构。
    db.execute(
      updated.replaceFirst('CREATE TABLE $table', 'CREATE TABLE ${table}_v9'),
    );
    db.execute('INSERT INTO ${table}_v9 SELECT * FROM $table');
  }
  db.execute('DROP TABLE nodes');
  db.execute('DROP TABLE maps');
  db.execute('ALTER TABLE maps_v9 RENAME TO maps');
  db.execute('ALTER TABLE nodes_v9 RENAME TO nodes');
  db.execute('CREATE INDEX maps_project ON maps(project_id,deleted_at)');
  db.execute('CREATE INDEX nodes_map ON nodes(map_id,deleted_at)');
  db.execute('CREATE INDEX nodes_parent ON nodes(parent_node_id)');
  db.execute('PRAGMA user_version=9');
  return db;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('opennote-thoughts-');
  });
  tearDown(() async => temp.delete(recursive: true));

  test('个人思考：多行原文按条往返且重复身份拒绝保存', () {
    const thoughts = [
      PersonalThought(id: 'a', text: '第一段\n\n第二段'),
      PersonalThought(id: 'b', text: '中文、English 与 "引号"'),
    ];
    expect(decodePersonalThoughts(encodePersonalThoughts(thoughts)), thoughts);
    expect(legacyPersonalThoughts('c', '旧备注\n第二行').single.text, '旧备注\n第二行');
    expect(
      () => encodePersonalThoughts([thoughts.first, thoughts.first]),
      throwsFormatException,
    );
    expect(
      () => decodePersonalThoughts('[{"id":"a","text":3}]'),
      throwsFormatException,
    );
  });

  test('个人思考：多条保存、单条删除与撤销重做、搜索、独立复制及备份恢复', () async {
    final repo = await OpenNoteRepository.open(rootPath: '${temp.path}/new');
    var repoClosed = false;
    try {
      final project = await repo.createProject('思考资料库');
      final map = (await repo.listMaps(project.id)).single;
      final original = await repo.createExcerpt(
        ExcerptDraft(
          projectId: project.id,
          mapId: map.id,
          title: '卡片',
          text: '正文与原文保持',
          note: '旧备注\n完整多行',
          anchors: const [],
        ),
      );
      final first = original.card.thoughts.single;
      final thoughts = [
        first,
        const PersonalThought(id: 'second', text: '第二条独立关键词'),
        const PersonalThought(id: 'third', text: '第三条\n\n仍是同一条'),
      ];
      await repo.updateCard(original.card.id, thoughts: thoughts);
      final history = repo.undoEntryCount;
      await repo.updateCard(original.card.id, thoughts: thoughts);
      expect(repo.undoEntryCount, history, reason: '内容相同不增加保存历史');
      expect((await repo.getCard(original.card.id)).thoughts, thoughts);
      expect(
        (await repo.search(project.id, '独立关键词')).single.cardId,
        original.card.id,
      );
      await repo.updateCard(original.card.id, body: '只改正文');
      expect((await repo.getCard(original.card.id)).thoughts, thoughts);
      await repo.updateCard(original.card.id, thoughts: [first, thoughts.last]);
      expect((await repo.getCard(original.card.id)).thoughts, [
        first,
        thoughts.last,
      ]);
      await repo.undo();
      expect((await repo.getCard(original.card.id)).thoughts, thoughts);
      await repo.redo();
      expect((await repo.getCard(original.card.id)).thoughts, [
        first,
        thoughts.last,
      ]);
      await repo.undo();
      final content = MapClipboardContent.capture(await repo.loadMap(map.id), {
        original.node.id,
      });
      final copied = (await repo.pasteTopicCopy(content, map.id)).single;
      final copyCard = await repo.getCard(copied.cardId);
      expect(copyCard.thoughts.map((t) => t.text), thoughts.map((t) => t.text));
      expect(
        copyCard.thoughts
            .map((t) => t.id)
            .toSet()
            .intersection(thoughts.map((t) => t.id).toSet()),
        isEmpty,
      );
      await repo.updateCard(copied.cardId, thoughts: const []);
      expect((await repo.getCard(original.card.id)).thoughts, thoughts);
      final backup = '${temp.path}/thoughts.onbackup';
      await repo.backupTo(backup);
      await repo.updateCard(original.card.id, thoughts: const []);
      await repo.restoreFrom(backup);
      final restored = await repo.getCard(original.card.id);
      expect(restored.thoughts, thoughts);
      expect(restored.note, personalThoughtsText(thoughts));
      expect(restored.excerptSnapshot, '正文与原文保持');
      expect(restored.body, '只改正文');
      final cardId = original.card.id;
      await repo.close();
      repoClosed = true;
      final reopened = await OpenNoteRepository.open(
        rootPath: '${temp.path}/new',
      );
      try {
        expect((await reopened.getCard(cardId)).thoughts, thoughts);
      } finally {
        await reopened.close();
      }
    } finally {
      if (!repoClosed) await repo.close();
    }
  });

  test('个人思考：真实 v9 WAL 升级保留整条旧备注与安全快照，旧备份可恢复', () async {
    final root = '${temp.path}/old';
    final folder = await Directory('$root/libraries/legacy')
        .create(recursive: true);
    await File('$root/active.json')
        .writeAsString(jsonEncode({'libraryId': 'legacy'}), encoding: utf8);
    final old = legacy9('${folder.path}/library.sqlite');
    old.execute('PRAGMA journal_mode=WAL');
    old.execute('PRAGMA wal_autocheckpoint=0');
    const text = 'WAL 中的旧备注\n\n完整保留一条 "思考"';
    old.execute('UPDATE cards SET note=? WHERE id=?', [text, 'c']);
    final repo = await OpenNoteRepository.open(rootPath: root);
    try {
      final card = await repo.getCard('c');
      expect(card.thoughts, [
        const PersonalThought(id: 'c:thought', text: text),
      ]);
      expect(card.note, text);
      final before = folder.listSync().whereType<File>().singleWhere(
        (file) => file.path.contains('.before-v$currentDatabaseVersion-'),
      );
      final snapshot = sqlite.sqlite3.open(
        before.path,
        mode: sqlite.OpenMode.readOnly,
      );
      try {
        expect(snapshot.select('PRAGMA user_version').single.values.single, 9);
        expect(
          snapshot
              .select('PRAGMA table_info(cards)')
              .any((row) => row['name'] == 'thoughts_json'),
          isFalse,
        );
        expect(
          snapshot.select('SELECT note FROM cards WHERE id=?', [
            'c',
          ]).single['note'],
          text,
        );
      } finally {
        snapshot.close();
      }
      final backup = '${temp.path}/v9.onbackup';
      await archives.backup(before.path, backup, 9);
      await repo.updateCard('c', thoughts: const []);
      await repo.restoreFrom(backup);
      expect((await repo.getCard('c')).thoughts.single.text, text);
    } finally {
      await repo.close();
      old.close();
    }
  });

  test('个人思考：v10 字段冲突升级回滚，保留旧备注与版本', () async {
    final path = '${temp.path}/conflict.sqlite';
    final old = legacy9(path);
    old.execute('ALTER TABLE cards ADD COLUMN thoughts_json TEXT');
    old.close();
    await expectLater(
      upgradeStagedDatabase(path),
      throwsA(isA<sqlite.SqliteException>()),
    );
    final read = sqlite.sqlite3.open(path);
    try {
      expect(read.select('PRAGMA user_version').single.values.single, 9);
      expect(read.select('SELECT note FROM cards').single['note'], '备注');
    } finally {
      read.close();
    }
  });

  test('个人思考：内容身份损坏的备份拒绝替换当前资料库', () async {
    final repo = await OpenNoteRepository.open(rootPath: '${temp.path}/active');
    try {
      final project = await repo.createProject('保留有效库');
      final map = (await repo.listMaps(project.id)).single;
      final card = (await repo.createExcerpt(
        ExcerptDraft(
          projectId: project.id,
          mapId: map.id,
          title: '保留卡片',
          text: '',
          note: '有效思考',
          anchors: const [],
        ),
      )).card;
      final backup = '${temp.path}/valid.onbackup';
      await repo.backupTo(backup);
      final archive = ZipDecoder().decodeBytes(
        await File(backup).readAsBytes(),
      );
      final dbFile = File('${temp.path}/tampered.sqlite');
      await dbFile.writeAsBytes(
        archive.findFile('library.sqlite')!.readBytes()!,
      );
      final db = sqlite.sqlite3.open(dbFile.path);
      db.execute('UPDATE cards SET thoughts_json=?', [
        '[{"id":"same","text":"有效思考"},{"id":"same","text":"重复"}]',
      ]);
      db.close();
      final bytes = await dbFile.readAsBytes();
      final manifest = jsonDecode(
        utf8.decode(archive.findFile('manifest.json')!.readBytes()!),
      ) as Map;
      final item = (manifest['files'] as List).singleWhere(
        (item) => item['path'] == 'library.sqlite',
      );
      item['size'] = bytes.length;
      item['sha256'] = sha256.convert(bytes).toString();
      final manifestBytes = utf8.encode(jsonEncode(manifest));
      final corrupted = Archive()
        ..addFile(ArchiveFile('library.sqlite', bytes.length, bytes))
        ..addFile(
          ArchiveFile('manifest.json', manifestBytes.length, manifestBytes),
        );
      final broken = File('${temp.path}/invalid.onbackup');
      await broken.writeAsBytes(ZipEncoder().encode(corrupted));
      final session = repo.sessionId;
      await expectLater(
        repo.restoreFrom(broken.path),
        throwsA(
          isA<RepositoryException>().having(
            (e) => e.code,
            'code',
            RepositoryError.corruptBackup,
          ),
        ),
      );
      expect(repo.sessionId, session);
      expect((await repo.getCard(card.id)).thoughts.single.text, '有效思考');
    } finally {
      await repo.close();
    }
  });
}
