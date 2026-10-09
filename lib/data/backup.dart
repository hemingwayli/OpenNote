part of 'open_note_repository.dart';

void _validateLibraryId(String value) {
  if (!RegExp(r'^[a-zA-Z0-9-]{1,64}$').hasMatch(value)) {
    throw const RepositoryException(RepositoryError.corruptBackup, '资料库标识不合法。');
  }
}

String _safeResourcePath(String library, String relative) {
  if (relative.contains('\\') ||
      p.posix.isAbsolute(relative) ||
      p.posix.normalize(relative) != relative ||
      !relative.startsWith('resources/') ||
      relative
          .split('/')
          .any((part) => part.isEmpty || part == '..' || part.contains(':'))) {
    throw const RepositoryException(
      RepositoryError.corruptBackup,
      '资料库资源路径不合法。',
    );
  }
  final result = p.normalize(p.joinAll([library, ...relative.split('/')]));
  if (!p.isWithin(library, result)) {
    throw const RepositoryException(
      RepositoryError.corruptBackup,
      '资源路径超出资料库。',
    );
  }
  return result;
}

Future<void> _writePointer(String root, String libraryId) async {
  _validateLibraryId(libraryId);
  final target = File(p.join(root, 'active.json'));
  final previous = File(p.join(root, 'active.previous.json'));
  final pending = File(p.join(root, 'active.${_id()}.pending'));
  await pending.writeAsString(
    encodeJson({'formatVersion': 1, 'libraryId': libraryId}),
    encoding: utf8,
    flush: true,
  );
  if (await target.exists()) {
    if (await previous.exists()) await previous.delete();
    await target.rename(previous.path);
  }
  await pending.rename(target.path);
}

Future<String> _backupLibrary(
  OpenNoteRepository repo,
  String destination,
) async {
  final target = p.normalize(p.absolute(destination));
  if (p.isWithin(repo.libraryPath, target) ||
      p.equals(target, repo.libraryPath)) {
    _invalid('备份不能放在当前运行资料库目录内。');
  }
  await Directory(p.dirname(target)).create(recursive: true);
  final snapshot = p.join(repo.libraryPath, 'staging', '${_id()}.sqlite');
  final pending = '$target.${_id()}.partial';
  try {
    // VACUUM INTO 从活动 WAL 数据库生成一致性独立快照，绝不直接复制活动 .db。
    await repo._database.customStatement('VACUUM INTO ?', [snapshot]);
    final resources = await repo._rows('SELECT * FROM resources ORDER BY id');
    await _runBackupWorker(repo.libraryPath, snapshot, resources, pending);
    await File(pending).rename(target);
    return target;
  } finally {
    if (await File(snapshot).exists()) await File(snapshot).delete();
    if (await File(pending).exists()) await File(pending).delete();
  }
}

Future<void> _runBackupWorker(
  String library,
  String snapshot,
  List<_Row> resources,
  String destination,
) =>
    Isolate.run(() => _encodeBackup(library, snapshot, resources, destination));

Future<void> _encodeBackup(
  String library,
  String snapshot,
  List<_Row> resources,
  String destination,
) async {
  final entries = <Map<String, Object?>>[];
  final database = File(snapshot);
  entries.add({
    'path': 'library.sqlite',
    'sha256': (await sha256.bind(database.openRead()).first).toString(),
    'size': await database.length(),
  });
  for (final row in resources) {
    final file = File(
      _safeResourcePath(library, row['relative_path'] as String),
    );
    if (!await file.exists() ||
        await file.length() != row['size'] ||
        (await sha256.bind(file.openRead()).first).toString() !=
            row['sha256']) {
      throw const RepositoryException(
        RepositoryError.corruptBackup,
        '资源缺失或哈希不匹配，备份已取消。',
      );
    }
    entries.add({
      'path': row['relative_path'],
      'sha256': row['sha256'],
      'size': row['size'],
    });
  }
  final manifest = utf8.encode(
    encodeJson({
      'formatVersion': 1,
      'schemaVersion': currentDatabaseVersion,
      'applicationVersion': '0.1.2',
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'includesRecycleBin': true,
      'files': entries,
    }),
  );
  final encoder = ZipFileEncoder();
  encoder.create(destination);
  try {
    encoder.addArchiveFile(
      ArchiveFile('manifest.json', manifest.length, manifest),
    );
    await encoder.addFile(database, 'library.sqlite');
    for (final row in resources) {
      // PDF 与截图通常已压缩，流式存入 ZIP，避免重复压缩整本书。
      await encoder.addFile(
        File(_safeResourcePath(library, row['relative_path'] as String)),
        row['relative_path'] as String,
        ZipFileEncoder.store,
      );
    }
  } finally {
    await encoder.close();
  }
}

Future<void> _restoreLibrary(
  OpenNoteRepository repo,
  String archivePath,
) async {
  final newId = _id();
  final stage = p.join(repo.rootPath, 'libraries', newId);
  await Directory(stage).create(recursive: true);
  try {
    await _runRestoreWorker(p.absolute(archivePath), stage);
    // 无 PDF／图片的资料库归档没有资源目录项，恢复后仍需可导入和永久清理。
    await Directory(p.join(stage, 'resources')).create(recursive: true);
    // 在激活前完成旧备份升级；失败不触碰当前资料库。
    final databasePath = p.join(stage, 'library.sqlite');
    await upgradeStagedDatabase(databasePath);
  } catch (error) {
    await Directory(stage).delete(recursive: true);
    if (error is RepositoryException) rethrow;
    throw RepositoryException(
      RepositoryError.corruptBackup,
      '备份无法解析或校验失败：$error',
    );
  }
  final safetyBackup = p.join(
    repo.rootPath,
    'backups',
    'before-restore-${_id()}.opennote',
  );
  await _backupLibrary(repo, safetyBackup);
  repo.lastSafetyBackupPath = safetyBackup;
  final oldId = repo._libraryId;
  final oldSession = repo._sessionId;
  repo._sessionId = _id();
  await repo._database.close();
  OpenNoteDatabase? next;
  try {
    await _writePointer(repo.rootPath, newId);
    await Directory(p.join(stage, 'staging')).create(recursive: true);
    next = OpenNoteDatabase(p.join(stage, 'library.sqlite'));
    await next.customSelect('SELECT 1').get();
    await next.customStatement(
      "UPDATE ocr_tasks SET status='queued',session_id=NULL WHERE status='running'",
    );
    repo._database = next;
    repo._libraryId = newId;
    repo._undo.clear();
    repo._redo.clear();
    repo._notify();
  } catch (_) {
    if (next != null) await next.close();
    await _writePointer(repo.rootPath, oldId);
    repo._database = OpenNoteDatabase(
      p.join(repo.rootPath, 'libraries', oldId, 'library.sqlite'),
    );
    await repo._database.customSelect('SELECT 1').get();
    repo._sessionId = oldSession;
    rethrow;
  }
}

Future<void> _runRestoreWorker(String archivePath, String stage) =>
    Isolate.run(() => _extractAndValidate(archivePath, stage));

Future<void> _extractAndValidate(String archivePath, String stage) async {
  final input = InputFileStream(archivePath);
  try {
    final archive = ZipDecoder().decodeStream(input, verify: true);
    final byName = <String, ArchiveFile>{};
    for (final file in archive) {
      final name = file.name;
      if (file.isSymbolicLink ||
          name.contains('\\') ||
          name.contains(':') ||
          p.posix.isAbsolute(name) ||
          p.posix.normalize(name) != name ||
          name.split('/').any((s) => s == '..' || s.isEmpty) ||
          byName.containsKey(name)) {
        throw const RepositoryException(
          RepositoryError.corruptBackup,
          '备份包含非法路径、链接或重复文件。',
        );
      }
      if (file.isFile) byName[name] = file;
    }
    final manifestFile = byName['manifest.json'];
    if (manifestFile == null || manifestFile.size > 16 * 1024 * 1024) {
      throw const RepositoryException(
        RepositoryError.corruptBackup,
        '备份清单缺失或过大。',
      );
    }
    final manifest = jsonDecode(utf8.decode(manifestFile.readBytes()!)) as Map;
    if (manifest['formatVersion'] != 1 ||
        ![1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11].contains(manifest['schemaVersion'])) {
      throw const RepositoryException(
        RepositoryError.unsupportedVersion,
        '不支持此备份或数据库版本。',
      );
    }
    final entries = (manifest['files'] as List)
        .map((e) => Map<String, Object?>.from(e as Map))
        .toList();
    final expectedNames = <String>{'manifest.json'};
    for (final entry in entries) {
      final name = entry['path'] as String;
      if (name != 'library.sqlite') _safeResourcePath(stage, name);
      if (!expectedNames.add(name)) {
        throw const RepositoryException(
          RepositoryError.corruptBackup,
          '备份清单存在重复资源。',
        );
      }
      final file = byName[name];
      if (file == null || file.size != entry['size'] || !file.isFile) {
        throw const RepositoryException(
          RepositoryError.corruptBackup,
          '备份资源缺失或大小不匹配。',
        );
      }
      final target = name == 'library.sqlite'
          ? p.join(stage, name)
          : _safeResourcePath(stage, name);
      await Directory(p.dirname(target)).create(recursive: true);
      final output = OutputFileStream(target);
      try {
        file.writeContent(output);
      } finally {
        output.closeSync();
      }
      final extracted = File(target);
      if (await extracted.length() != entry['size'] ||
          (await sha256.bind(extracted.openRead()).first).toString() !=
              entry['sha256']) {
        throw const RepositoryException(
          RepositoryError.corruptBackup,
          '备份资源哈希不匹配。',
        );
      }
    }
    if (!expectedNames.contains('library.sqlite') ||
        expectedNames.length != byName.length) {
      throw const RepositoryException(
        RepositoryError.corruptBackup,
        '备份文件与清单不一致。',
      );
    }
    await _validateRestoredDatabase(
      stage,
      entries,
      manifest['schemaVersion'] as int,
    );
  } finally {
    input.closeSync();
  }
}

Future<void> _validateRestoredDatabase(
  String stage,
  List<_Row> entries,
  int declaredVersion,
) async {
  final database = sqlite.sqlite3.open(
    p.join(stage, 'library.sqlite'),
    mode: sqlite.OpenMode.readOnly,
  );
  try {
    final version =
        database.select('PRAGMA user_version').single.values.single as int;
    if (![1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11].contains(version) ||
        version != declaredVersion) {
      throw const RepositoryException(
        RepositoryError.unsupportedVersion,
        '数据库版本不受支持。',
      );
    }
    if (database.select('PRAGMA integrity_check').single.values.single !=
            'ok' ||
        database.select('PRAGMA foreign_key_check').isNotEmpty) {
      throw const RepositoryException(
        RepositoryError.corruptBackup,
        '数据库完整性或引用校验失败。',
      );
    }
    final tables = database
        .select(
          "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
        )
        .map((r) => r['name'] as String)
        .toSet();
    if(version>=11) {
      try {
        if(!tables.containsAll({'epub_sections','epub_image_ocr'})) throw const FormatException('EPUB 表缺失');
        for(final table in ['anchors','annotations','reading_positions']) {
          final join=table=='reading_positions'?'t.id':'t.revision_id';
          for(final row in database.select('SELECT t.*,r.format,r.metadata_json FROM $table t JOIN revisions r ON r.id=$join')) {
            if(row['format']=='epub') {
              final locator=DocumentLocator.decode(row['locator_json'] as String) as EpubLocator;
              if(row['page_index']!=null || database.select('SELECT id FROM epub_sections WHERE revision_id=? AND href=?',
                [table=='reading_positions'?row['id']:row['revision_id'],locator.href]).isEmpty) {
                throw const FormatException('EPUB 来源章节不一致');
              }
              if(table=='reading_positions') EpubReadingSettings.fromJson(Map<String,dynamic>.from(jsonDecode(row['settings_json'] as String) as Map));
            } else if(row['format']!='pdf' || row['locator_json']!=null || row['page_index'] is! int) {
              throw const FormatException('PDF 来源格式不一致');
            }
          }
        }
        for(final row in database.select('SELECT * FROM epub_sections')) {
          if(!isLocalPublicationPath(row['href'] as String)) throw const FormatException('EPUB 章节路径越界');
          if(row['text']!=null) _validateEpubFragments(row['text'] as String,decodeObjectList(row['fragments'] as String));
        }
        for(final row in database.select('SELECT * FROM epub_image_ocr')) {
          final locator=DocumentLocator.decode(row['locator_json'] as String) as EpubLocator;
          if(database.select('SELECT id FROM epub_sections WHERE revision_id=? AND href=?',[row['revision_id'],locator.href]).isEmpty) {
            throw const FormatException('图片 OCR 来源章节不一致');
          }
          final result=jsonDecode(row['result_json'] as String);
          if(result is! Map || row['engine_version'].toString().isEmpty) throw const FormatException('OCR 溯源结果不合法');
        }
      } catch(_) {
        throw const RepositoryException(RepositoryError.corruptBackup,'备份 EPUB 来源、阅读状态或文字索引无效。');
      }
    }
    final allowedLayouts = version >= 9
        ? persistedMapLayouts
        : legacyPersistedMapLayouts;
    if (version >= 10) {
      if (!database
          .select('PRAGMA table_info(cards)')
          .any((row) => row['name'] == 'thoughts_json')) {
        throw const RepositoryException(
          RepositoryError.corruptBackup,
          '备份缺少个人思考字段。',
        );
      }
      try {
        for (final row in database.select(
          'SELECT note,thoughts_json FROM cards',
        )) {
          final thoughts = decodePersonalThoughts(
            row['thoughts_json'] as String,
          );
          if (personalThoughtsText(thoughts) != row['note']) {
            throw const FormatException('个人思考与预览内容不一致');
          }
        }
      } catch (_) {
        throw const RepositoryException(
          RepositoryError.corruptBackup,
          '备份个人思考内容无效。',
        );
      }
    }
    if (version >= 8) {
      if (!database
              .select('PRAGMA table_info(nodes)')
              .any((r) => r['name'] == 'branch_layout') ||
          database
              .select(
                'SELECT id FROM nodes WHERE branch_layout IS NOT NULL AND branch_layout NOT IN ($allowedLayouts) LIMIT 1',
              )
              .isNotEmpty) {
        throw const RepositoryException(
          RepositoryError.corruptBackup,
          '分支结构字段无效。',
        );
      }
    }
    if (version >= 7) {
      final mapColumns = database
          .select('PRAGMA table_info(maps)')
          .map((r) => r['name'])
          .toSet();
      final nodeColumns = database
          .select('PRAGMA table_info(nodes)')
          .map((r) => r['name'])
          .toSet();
      if (!mapColumns.contains('default_style_json') ||
          !nodeColumns.contains('topic_style_json')) {
        throw const RepositoryException(
          RepositoryError.corruptBackup,
          '主题格式字段不完整。',
        );
      }
      try {
        for (final row in database.select(
          'SELECT default_style_json FROM maps',
        )) {
          TopicStyle.fromJson(
            Map<String, dynamic>.from(
              jsonDecode(row['default_style_json'] as String) as Map,
            ),
          );
        }
        for (final row in database.select(
          'SELECT topic_style_json FROM nodes WHERE topic_style_json IS NOT NULL',
        )) {
          TopicStyle.fromJson(
            Map<String, dynamic>.from(
              jsonDecode(row['topic_style_json'] as String) as Map,
            ),
          );
        }
        if (database
            .select(
              'SELECT nodes.id FROM nodes JOIN summaries ON summaries.summary_node_id=nodes.id WHERE nodes.topic_style_json IS NOT NULL LIMIT 1',
            )
            .isNotEmpty) {
          throw const FormatException('概要主题存在重复格式');
        }
      } catch (_) {
        throw const RepositoryException(
          RepositoryError.corruptBackup,
          '备份主题格式无效。',
        );
      }
    }
    final expectedTables = version == 1
        ? legacyDatabaseTableNames
        : version < 5
        ? preBoundaryDatabaseTableNames
        : version < 6
        ? preSummaryDatabaseTableNames
        : version < 11 ? preEpubDatabaseTableNames : databaseTableNames;
    if (tables.length != expectedTables.length ||
        !tables.containsAll(expectedTables)) {
      throw const RepositoryException(
        RepositoryError.corruptBackup,
        '数据库表结构不完整。',
      );
    }
    if (version >= 3) {
      final mapColumns = database
          .select('PRAGMA table_info(maps)')
          .map((row) => row['name'])
          .toSet();
      final nodeColumns = database
          .select('PRAGMA table_info(nodes)')
          .map((row) => row['name'])
          .toSet();
      if (!mapColumns.contains('layout_kind') ||
          !nodeColumns.containsAll({'sort_index', 'branch_side'})) {
        throw const RepositoryException(
          RepositoryError.corruptBackup,
          '备份缺少脑图结构字段。',
        );
      }
      if (database
              .select(
                'SELECT id FROM maps WHERE layout_kind NOT IN ($allowedLayouts) OR layout_kind IS NULL LIMIT 1',
              )
              .isNotEmpty ||
          database
              .select(
                "SELECT id FROM nodes WHERE (sort_index IS NOT NULL AND (typeof(sort_index)<>'integer' OR sort_index<0)) OR (branch_side IS NOT NULL AND branch_side NOT IN (-1,1)) LIMIT 1",
              )
              .isNotEmpty) {
        throw const RepositoryException(
          RepositoryError.corruptBackup,
          '备份的脑图结构记录无效。',
        );
      }
    }
    if (version >= 4) {
      final columns = database
          .select('PRAGMA table_info(edges)')
          .map((r) => r['name'])
          .toSet();
      if (!columns.containsAll({'label', 'style_json'})) {
        throw const RepositoryException(
          RepositoryError.corruptBackup,
          '备份缺少关联线字段。',
        );
      }
      for (final edge in database.select(
        'SELECT label,style_json FROM edges',
      )) {
        if (edge['label'] is! String ||
            (edge['label'] as String).length > 1000 ||
            edge['style_json'] is! String) {
          throw const RepositoryException(
            RepositoryError.corruptBackup,
            '关联说明无效。',
          );
        }
        RelationshipStyle.fromJson(
          Map<String, dynamic>.from(
            jsonDecode(edge['style_json'] as String) as Map,
          ),
        );
      }
    }
    if (version >= 5) {
      final columns = database
          .select('PRAGMA table_info(boundaries)')
          .map((r) => r['name'])
          .toSet();
      if (!columns.containsAll({
        'id',
        'map_id',
        'parent_node_id',
        'node_ids',
        'label',
        'style_json',
      })) {
        throw const RepositoryException(
          RepositoryError.corruptBackup,
          '备份缺少外框字段。',
        );
      }
      final nodes = {
        for (final n in database.select(
          'SELECT id,map_id,parent_node_id FROM nodes',
        ))
          n['id']: n,
      };
      final maps = database
          .select('SELECT id FROM maps')
          .map((m) => m['id'])
          .toSet();
      for (final row in database.select('SELECT * FROM boundaries')) {
        final boundary = _boundary(Map<String, Object?>.from(row));
        if (!maps.contains(boundary.mapId) ||
            boundary.nodeIds.isEmpty ||
            boundary.nodeIds.toSet().length != boundary.nodeIds.length ||
            boundary.label.length > 1000 ||
            boundary.parentNodeId == null && boundary.nodeIds.length > 1 ||
            boundary.nodeIds.any(
              (id) =>
                  nodes[id] == null ||
                  nodes[id]!['map_id'] != boundary.mapId ||
                  nodes[id]!['parent_node_id'] != boundary.parentNodeId,
            )) {
          throw const RepositoryException(
            RepositoryError.corruptBackup,
            '外框范围或脑图引用无效。',
          );
        }
      }
    }
    if (version >= 6) {
      final columns = database
          .select('PRAGMA table_info(summaries)')
          .map((r) => r['name'])
          .toSet();
      if (!columns.containsAll({
        'id',
        'map_id',
        'parent_node_id',
        'summary_node_id',
        'node_ids',
        'style_json',
      })) {
        throw const RepositoryException(
          RepositoryError.corruptBackup,
          '备份缺少概要字段。',
        );
      }
      final nodes = {
        for (final n in database.select(
          'SELECT id,map_id,parent_node_id FROM nodes',
        ))
          n['id']: n,
      };
      final summaries = database
          .select('SELECT * FROM summaries')
          .map((r) => _summary(Map<String, Object?>.from(r)))
          .toList();
      final auxiliary = summaries.map((s) => s.summaryNodeId).toSet();
      if (auxiliary.length != summaries.length) {
        throw const RepositoryException(
          RepositoryError.corruptBackup,
          '概要主题重复。',
        );
      }
      for (final s in summaries) {
        final topic = nodes[s.summaryNodeId];
        if (topic == null ||
            topic['map_id'] != s.mapId ||
            topic['parent_node_id'] != s.parentNodeId ||
            s.nodeIds.isEmpty ||
            s.nodeIds.toSet().length != s.nodeIds.length ||
            s.nodeIds.any(
              (id) =>
                  auxiliary.contains(id) ||
                  nodes[id] == null ||
                  nodes[id]!['map_id'] != s.mapId ||
                  nodes[id]!['parent_node_id'] != s.parentNodeId,
            )) {
          throw const RepositoryException(
            RepositoryError.corruptBackup,
            '概要范围或主题引用无效。',
          );
        }
      }
    }
    for (final query in [
      if (version >= 2) ...[
        'SELECT s.id FROM project_sessions s JOIN documents d ON d.id=s.active_document_id WHERE s.id<>d.project_id LIMIT 1',
        'SELECT s.id FROM project_sessions s JOIN documents d ON d.id=s.last_read_document_id WHERE s.id<>d.project_id LIMIT 1',
        'SELECT s.id FROM project_sessions s JOIN maps m ON m.id=s.map_id WHERE s.id<>m.project_id LIMIT 1',
      ],
      'SELECT n.id FROM nodes n JOIN maps m ON m.id=n.map_id JOIN cards c ON c.id=n.card_id WHERE m.project_id<>c.project_id LIMIT 1',
      'SELECT n.id FROM nodes n JOIN nodes p ON p.id=n.parent_node_id WHERE n.map_id<>p.map_id LIMIT 1',
      'SELECT e.id FROM edges e JOIN nodes a ON a.id=e.from_node_id JOIN nodes b ON b.id=e.to_node_id WHERE e.map_id<>a.map_id OR e.map_id<>b.map_id LIMIT 1',
      'SELECT a.id FROM anchors a JOIN cards c ON c.id=a.card_id JOIN revisions r ON r.id=a.revision_id JOIN documents d ON d.id=r.document_id WHERE c.project_id<>d.project_id LIMIT 1',
      'SELECT d.id FROM documents d JOIN revisions r ON r.id=d.active_revision_id WHERE d.id<>r.document_id LIMIT 1',
      'SELECT r.id FROM revisions r JOIN resources a ON a.id=r.resource_id WHERE r.content_hash<>a.sha256 LIMIT 1',
      'SELECT a.id FROM anchors a JOIN text_layers l ON l.id=a.text_layer_id WHERE a.revision_id<>l.revision_id OR a.page_index<>l.page_index LIMIT 1',
    ]) {
      if (database.select(query).isNotEmpty) {
        throw const RepositoryException(
          RepositoryError.corruptBackup,
          '项目、页面或脑图引用语义不一致。',
        );
      }
    }
    final resourceEntries = {for (final e in entries) e['path'] as String: e};
    if (version >= 2) {
      for (final row in database.select(
        'SELECT id,opened_document_ids FROM project_sessions',
      )) {
        final ids = jsonDecode(row['opened_document_ids'] as String);
        if (ids is! List ||
            ids.any((id) => id is! String) ||
            ids.toSet().length != ids.length) {
          throw const RepositoryException(
            RepositoryError.corruptBackup,
            '项目阅读标签记录无效。',
          );
        }
        for (final id in ids) {
          final linked = database.select(
            'SELECT project_id FROM documents WHERE id=?',
            [id],
          );
          if (linked.isNotEmpty && linked.single['project_id'] != row['id']) {
            throw const RepositoryException(
              RepositoryError.corruptBackup,
              '项目阅读标签跨项目引用。',
            );
          }
        }
      }
    }
    final resources = database.select('SELECT * FROM resources');
    if (resources.length + 1 != entries.length) {
      throw const RepositoryException(
        RepositoryError.corruptBackup,
        '数据库资源清单与备份不一致。',
      );
    }
    for (final row in resources) {
      final entry = resourceEntries[row['relative_path']];
      if (entry == null ||
          entry['sha256'] != row['sha256'] ||
          entry['size'] != row['size']) {
        throw const RepositoryException(
          RepositoryError.corruptBackup,
          '数据库资源记录与备份不一致。',
        );
      }
    }
    final nodes = database.select('SELECT id,parent_node_id FROM nodes');
    final parents = {
      for (final row in nodes)
        row['id'] as String: row['parent_node_id'] as String?,
    };
    final completed = <String>{};
    for (final nodeId in parents.keys) {
      final path = <String>{};
      String? cursor = nodeId;
      while (cursor != null && !completed.contains(cursor)) {
        if (!path.add(cursor)) {
          throw const RepositoryException(
            RepositoryError.corruptBackup,
            '备份脑图包含层级循环。',
          );
        }
        cursor = parents[cursor];
      }
      completed.addAll(path);
    }
  } finally {
    database.close();
  }
}
