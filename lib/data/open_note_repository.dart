import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:uuid/uuid.dart';

import '../domain/models.dart';
import '../domain/map_clipboard.dart';
import '../domain/map_layout.dart';
import '../domain/boundary_geometry.dart';
import '../domain/summary_geometry.dart';
import '../domain/topic_style_resolver.dart';
import '../domain/topic_drop.dart';
import 'database.dart';
import '../engines/epub/epub_publication.dart';

part 'backup.dart';
part 'graph_commands.dart';
part 'purge.dart';
part 'text_and_trash.dart';
part 'project_home.dart';
part 'topic_commands.dart';
part 'map_layout_commands.dart';
part 'relationship_commands.dart';
part 'boundary_commands.dart';
part 'summary_commands.dart';
part 'topic_style_commands.dart';
part 'topic_drop_commands.dart';
part 'epub_commands.dart';

typedef _Row = Map<String, Object?>;

/// 应用唯一数据写入入口。所有命令串行提交，成功后才发出变更通知。
class OpenNoteRepository {
  static const candidateBuild = bool.fromEnvironment('OPENNOTE_CANDIDATE');
  static const defaultDataDirectoryName = candidateBuild
      ? 'OpenNote-EPUB-PDF-Candidate'
      : 'OpenNote';
  OpenNoteRepository._(
    this.rootPath,
    this._libraryId,
    this._database,
    this._lock,
  );
  final String rootPath;
  String _libraryId;
  OpenNoteDatabase _database;
  final RandomAccessFile _lock;
  final _changes = StreamController<int>.broadcast();
  final List<_HistoryEntry> _undo = [];
  final List<_HistoryEntry> _redo = [];
  Future<void> _tail = Future.value();
  bool _closed = false;
  int _changeNumber = 0;
  String _sessionId = const Uuid().v4();
  String? lastSafetyBackupPath;

  Stream<int> get changes => _changes.stream;
  String get sessionId => _sessionId;
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  int get undoEntryCount => _undo.length;
  int get redoEntryCount => _redo.length;
  String get libraryPath => p.join(rootPath, 'libraries', _libraryId);

  static Future<OpenNoteRepository> open({String? rootPath}) async {
    String defaultRoot;
    if (rootPath != null) {
      defaultRoot = rootPath;
    } else if (Platform.isWindows) {
      final local = Platform.environment['LOCALAPPDATA'];
      if (local == null || local.isEmpty) _invalid('无法取得 Windows 本地应用资料目录。');
      defaultRoot = p.join(local, defaultDataDirectoryName);
    } else {
      defaultRoot = p.join(
        (await getApplicationSupportDirectory()).path,
        defaultDataDirectoryName,
      );
    }
    final root = p.normalize(p.absolute(defaultRoot));
    await Directory(root).create(recursive: true);
    final lock = await File(p.join(root, 'library.lock'))
        .open(mode: FileMode.append);
    try {
      await lock.lock(FileLock.exclusive);
    } catch (_) {
      await lock.close();
      throw const RepositoryException(
        RepositoryError.conflict,
        '资料库已被另一个 OpenNote 实例打开。',
      );
    }
    try {
      final pointer = File(p.join(root, 'active.json'));
      final previous = File(p.join(root, 'active.previous.json'));
      if (!await pointer.exists() && await previous.exists()) {
        await previous.rename(pointer.path);
      }
      String libraryId;
      var createdLibrary = false;
      if (await pointer.exists()) {
        libraryId =
            (jsonDecode(await pointer.readAsString(encoding: utf8))
                    as Map)['libraryId']
                as String;
        _validateLibraryId(libraryId);
      } else {
        createdLibrary = true;
        libraryId = const Uuid().v4();
        await Directory(p.join(root, 'libraries', libraryId))
            .create(recursive: true);
      }
      final folder = p.join(root, 'libraries', libraryId);
      if (!await Directory(folder).exists()) {
        throw const RepositoryException(
          RepositoryError.corruptBackup,
          '当前资料库目录缺失，禁止新建空库覆盖。',
        );
      }
      if (!createdLibrary &&
          !await File(p.join(folder, 'library.sqlite')).exists()) {
        throw const RepositoryException(
          RepositoryError.corruptBackup,
          '当前资料库数据库缺失，禁止新建空库覆盖。',
        );
      }
      await Directory(p.join(folder, 'resources')).create(recursive: true);
      await Directory(p.join(folder, 'staging')).create(recursive: true);
      await prepareDatabaseUpgrade(p.join(folder, 'library.sqlite'));
      final database = OpenNoteDatabase(p.join(folder, 'library.sqlite'));
      final repo = OpenNoteRepository._(root, libraryId, database, lock);
      try {
        await database.customSelect('SELECT 1').get();
        if (createdLibrary) await _writePointer(root, libraryId);
        await database.customStatement(
          "UPDATE ocr_tasks SET status='queued',session_id=NULL WHERE status='running'",
        );
        // 崩溃遗留暂存文件不属于已提交资源；只清理当前库的暂存目录。
        await for (final entity in Directory(
          p.join(folder, 'staging'),
        ).list(followLinks: false)) {
          if (entity is File || entity is Directory) {
            await entity.delete(recursive: true);
          }
        }
        return repo;
      } catch (_) {
        await database.close();
        rethrow;
      }
    } catch (_) {
      await lock.unlock();
      await lock.close();
      rethrow;
    }
  }

  Future<T> _exclusive<T>(Future<T> Function() action) async {
    final previous = _tail;
    final done = Completer<void>();
    _tail = done.future;
    await previous;
    try {
      if (_closed) {
        throw const RepositoryException(RepositoryError.disposed, '资料库已关闭。');
      }
      return await action();
    } finally {
      done.complete();
    }
  }

  Future<List<_Row>> _rows(
    String sql, [
    List<Object?> values = const [],
  ]) async =>
      (await _database
              .customSelect(
                sql,
                variables: values.map((v) => Variable<Object>(v)).toList(),
              )
              .get())
          .map((r) => Map<String, Object?>.from(r.data))
          .toList();

  Future<_Row> _require(String table, String id, {bool active = false}) async {
    if (!databaseTableNames.contains(table)) throw ArgumentError.value(table);
    final rows = await _rows('SELECT * FROM $table WHERE id = ?', [id]);
    if (rows.isEmpty || (active && rows.single['deleted_at'] != null)) {
      throw RepositoryException(RepositoryError.notFound, '找不到有效的 $table 记录。');
    }
    return rows.single;
  }

  Future<T> _mutate<T>(
    String label,
    Future<T> Function(_Writer writer) action, {
    bool recordUndo = true,
    bool invalidateRedo = true,
    bool notifyChanges = true,
  }) => _exclusive(() async {
    final writer = _Writer(this);
    late T result;
    late List<_RowChange> changes;
    await _database.transaction(() async {
      await _database.customStatement('PRAGMA defer_foreign_keys = ON');
      result = await action(writer);
      changes = await writer.changes();
      if (await _normalizeChangedBoundaries(writer, changes)) {
        changes = await writer.changes();
      }
      if (await _normalizeChangedSummaries(writer, changes)) {
        changes = await writer.changes();
      }
    });
    if (recordUndo && changes.isNotEmpty) {
      _undo.add(_HistoryEntry(label, changes));
      _redo.clear();
    } else if (invalidateRedo && changes.isNotEmpty) {
      _redo.clear();
    }
    if (notifyChanges && changes.isNotEmpty) _notify();
    return result;
  });

  void _notify() {
    if (!_changes.isClosed) _changes.add(++_changeNumber);
  }

  Future<void> close() => _exclusive(() async {
    await _database.close();
    _closed = true;
    await _lock.unlock();
    await _lock.close();
    await _changes.close();
  });

  Future<List<StudyProject>> listProjects({
    bool includeDeleted = false,
  }) => _exclusive(
    () async => (await _rows(
      'SELECT * FROM projects ${includeDeleted ? '' : 'WHERE deleted_at IS NULL'} ORDER BY created_at',
    )).map(_project).toList(),
  );

  Future<StudyProject> createProject(String title, {String? folderId}) =>
      _mutate('新建学习项目', (w) async {
        if (folderId != null) await _require('project_folders', folderId);
        final row = <String, Object?>{
          'id': _id(),
          'title': _title(title),
          'created_at': _now(),
          'deleted_at': null,
        };
        await w.put('projects', row);
        if (folderId != null) {
          await w.put('project_memberships', {
            'id': row['id'],
            'folder_id': folderId,
          });
        }
        await w.put('maps', {
          'id': _id(),
          'project_id': row['id'],
          'title': '脑图 1',
          'layout_kind': MapLayoutKind.right.name,
          'deleted_at': null,
        });
        return _project(row);
      }, recordUndo: false);

  Future<void> renameProject(String projectId, String title) =>
      _mutate('重命名学习项目', (w) async {
        final row = await _require('projects', projectId, active: true);
        final normalized = _title(title);
        if (row['title'] == normalized) return;
        await w.put('projects', {...row, 'title': normalized});
      });

  Future<List<ManagedDocument>> listDocuments(
    String projectId, {
    bool includeDeleted = false,
  }) => _exclusive(
    () async => (await _rows(
      'SELECT documents.*,revisions.format FROM documents JOIN revisions ON revisions.id=documents.active_revision_id WHERE documents.project_id = ? ${includeDeleted ? '' : 'AND documents.deleted_at IS NULL'} ORDER BY documents.title',
      [projectId],
    )).map(_document).toList(),
  );

  Future<ManagedDocument> importPdf({
    required String projectId,
    required String filePath,
    String? title,
    int pageCount = 0,
    List<PdfPageGeometry> pageGeometry = const [],
  }) => _mutate('导入 PDF', (w) async {
    await _require('projects', projectId, active: true);
    if (pageCount < 0) _invalid('页数不能为负数。');
    final source = File(filePath);
    final prefix = await source.open();
    try {
      final header = await prefix.read(1024);
      if (!latin1.decode(header).contains('%PDF-')) _invalid('选中的文件不是 PDF。');
    } finally {
      await prefix.close();
    }
    final resource = await _importResource(w, source, 'pdf', 'pdf');
    final docId = _id();
    final revisionId = _id();
    final doc = <String, Object?>{
      'id': docId,
      'project_id': projectId,
      'title': _title(title ?? p.basenameWithoutExtension(filePath)),
      'active_revision_id': revisionId,
      'deleted_at': null,
    };
    await w.put('documents', doc);
    await w.put('revisions', {
      'id': revisionId,
      'document_id': docId,
      'resource_id': resource.id,
      'content_hash': resource.sha256,
      'page_count': pageCount,
      'geometry': encodeJson(pageGeometry.map((g) => g.toJson()).toList()),
    });
    return _document(doc);
  }, recordUndo: false);

  Future<DocumentRevision> getRevision(String revisionId) => _exclusive(
    () async => _revision(await _require('revisions', revisionId)),
  );

  Future<ManagedDocument> getDocument(String documentId) => _exclusive(
    () async {
      final row=await _require('documents',documentId);
      final revision=await _require('revisions',row['active_revision_id'] as String);
      return _document({...row,'format':revision['format']});
    },
  );

  Future<void> renameDocument(String documentId, String title) =>
      _mutate('重命名 PDF', (w) async {
        final row = await _require('documents', documentId, active: true);
        await _require('projects', row['project_id'] as String, active: true);
        final normalized = _title(title);
        if (row['title'] == normalized) return;
        await w.put('documents', {...row, 'title': normalized});
      });

  Future<void> setRevisionMetadata(
    String revisionId, {
    required int pageCount,
    required List<PdfPageGeometry> pageGeometry,
  }) => _mutate(
    '读取 PDF 页信息',
    (w) async {
      final row = await _require('revisions', revisionId);
      if (pageCount <= 0 ||
          pageGeometry.any(
            (g) => g.pageIndex < 0 || g.pageIndex >= pageCount,
          )) {
        _invalid('PDF 页面信息不合法。');
      }
      if ((row['page_count'] as int) != 0 && row['page_count'] != pageCount) {
        _invalid('已确定的 PDF 页结构不能原地替换。');
      }
      await w.put('revisions', {
        ...row,
        'page_count': pageCount,
        'geometry': encodeJson(pageGeometry.map((g) => g.toJson()).toList()),
      });
    },
    recordUndo: false,
    invalidateRedo: false,
  );

  Future<String> resourcePath(String resourceId) => _exclusive(() async {
    final resource = _resource(await _require('resources', resourceId));
    final path = _safeResourcePath(libraryPath, resource.relativePath);
    if (!await File(path).exists()) {
      throw const RepositoryException(RepositoryError.notFound, '资料库资源文件缺失。');
    }
    return path;
  });

  Future<String> resolveResourcePath(String resourceId) =>
      resourcePath(resourceId);

  Future<List<MindMap>> listMaps(String projectId) => _exclusive(
    () async => (await _rows(
      'SELECT * FROM maps WHERE project_id=? AND deleted_at IS NULL ORDER BY title',
      [projectId],
    )).map(_map).toList(),
  );

  Future<MindMap> createMap(String projectId, String title) =>
      _mutate('新建脑图', (w) async {
        await _require('projects', projectId, active: true);
        final row = <String, Object?>{
          'id': _id(),
          'project_id': projectId,
          'title': _title(title),
          'layout_kind': MapLayoutKind.right.name,
          'deleted_at': null,
        };
        await w.put('maps', row);
        return _map(row);
      }, recordUndo: false);

  Future<void> renameMap(String mapId, String title) =>
      _mutate('重命名脑图', (w) async {
        final row = await _require('maps', mapId, active: true);
        await _require('projects', row['project_id'] as String, active: true);
        final normalized = _title(title);
        if (row['title'] == normalized) return;
        await w.put('maps', {...row, 'title': normalized});
      });

  Future<List<NoteCard>> listCards(
    String projectId, {
    bool includeDeleted = false,
    int limit = 10000,
    int offset = 0,
  }) => _exclusive(
    () async => (await _rows(
      'SELECT * FROM cards WHERE project_id=? ${includeDeleted ? '' : 'AND deleted_at IS NULL'} ORDER BY updated_at DESC LIMIT ? OFFSET ?',
      [projectId, limit, offset],
    )).map(_card).toList(),
  );

  Future<NoteCard> getCard(String cardId) =>
      _exclusive(() async => _card(await _require('cards', cardId)));

  Future<List<SourceAnchor>> getAnchors(String cardId) => _exclusive(
    () async => (await _rows(
      'SELECT * FROM anchors WHERE card_id=? ORDER BY page_index,id',
      [cardId],
    )).map(_anchor).toList(),
  );

  Future<MapSnapshot> loadMap(String mapId) => _exclusive(() async {
    final map = _map(await _require('maps', mapId, active: true));
    final nodes = (await _rows(
      'SELECT n.* FROM nodes n JOIN cards c ON c.id=n.card_id WHERE n.map_id=? AND n.deleted_at IS NULL AND c.deleted_at IS NULL',
      [mapId],
    )).map(_node).toList();
    final cards = (await _rows(
      'SELECT DISTINCT c.* FROM cards c JOIN nodes n ON c.id=n.card_id WHERE n.map_id=? AND n.deleted_at IS NULL AND c.deleted_at IS NULL',
      [mapId],
    )).map(_card).toList();
    final anchors = <String, List<SourceAnchor>>{};
    for (final row in await _rows(
      'SELECT DISTINCT a.* FROM anchors a JOIN nodes n ON a.card_id=n.card_id WHERE n.map_id=? AND n.deleted_at IS NULL',
      [mapId],
    )) {
      final anchor = _anchor(row);
      (anchors[anchor.cardId] ??= []).add(anchor);
    }
    final edges = (await _rows(
      'SELECT e.* FROM edges e JOIN nodes a ON a.id=e.from_node_id JOIN nodes b ON b.id=e.to_node_id WHERE e.map_id=? AND a.deleted_at IS NULL AND b.deleted_at IS NULL',
      [mapId],
    )).map(_edge).toList();
    return MapSnapshot(
      map: map,
      nodes: nodes,
      cards: {for (final c in cards) c.id: c},
      anchors: anchors,
      edges: edges,
      boundaries: (await _rows('SELECT * FROM boundaries WHERE map_id=?', [
        mapId,
      ])).map(_boundary).toList(),
      summaries: (await _rows('SELECT * FROM summaries WHERE map_id=?', [
        mapId,
      ])).map(_summary).toList(),
    );
  });

  Future<void> updateCard(
    String cardId, {
    String? title,
    String? body,
    String? note,
    List<PersonalThought>? thoughts,
    String? color,
  }) => _mutate('编辑卡片', (w) async {
    final row = await _require('cards', cardId, active: true);
    await _updateCardRow(
      w,
      row,
      title: title,
      body: body,
      note: note,
      thoughts: thoughts,
      color: color,
    );
  });

  Future<void> _updateCardRow(
    _Writer w,
    _Row row, {
    String? title,
    String? body,
    String? note,
    List<PersonalThought>? thoughts,
    String? color,
  }) async {
    if (note != null && thoughts != null) {
      throw ArgumentError('个人思考与旧备注不能同时更新');
    }
    final entries =
        thoughts ??
        (note != null && note != row['note']
            ? legacyPersonalThoughts(row['id'] as String, note)
            : null);
    final next = <String, Object?>{
      ...row,
      if (title != null) 'title': _title(title),
      'body': ?body,
      if (entries != null) ...{
        'note': personalThoughtsText(entries),
        'thoughts_json': encodePersonalThoughts(entries),
      },
      'color': ?color,
    };
    final cardChanged = !const [
      'title',
      'body',
      'note',
      'thoughts_json',
      'color',
    ].every((key) => next[key] == row[key]);
    if (cardChanged) {
      next['updated_at'] = _now();
      await w.put('cards', next);
    }
    if (color != null) {
      // 只同步明确归属本卡的标注，与卡片共用事务和撤销记录。
      // 重选当前颜色也能修正旧标注，不按相同原文位置推断关联。
      for (final annotation in await _rows(
        'SELECT * FROM annotations WHERE card_id=?',
        [row['id']],
      )) {
        if (annotation['color'] != color) {
          await w.put('annotations', {...annotation, 'color': color});
        }
      }
    }
  }

  Future<ExcerptResult> createExcerpt(ExcerptDraft draft) =>
      _mutate('创建摘录', (w) async {
        final result = await _createExcerptRows(w, draft);
        await _relayoutMap(w, draft.mapId);
        return ExcerptResult(
          card: result.card,
          node: _node(await _require('nodes', result.node.id, active: true)),
        );
      });

  Future<ExcerptResult> _createExcerptRows(
    _Writer w,
    ExcerptDraft draft,
  ) async {
    await _require('projects', draft.projectId, active: true);
    final map = await _require('maps', draft.mapId, active: true);
    _sameProject(map['project_id'], draft.projectId);
    await _validateParent(draft.mapId, draft.parentNodeId);
    // 新卡片必须沿插入路径可见；展开与摘录共享一次事务及撤销。
    var ancestorId = draft.parentNodeId;
    while (ancestorId != null) {
      final ancestor = await _require('nodes', ancestorId, active: true);
      if (ancestor['collapsed'] == 1) {
        await w.put('nodes', {...ancestor, 'collapsed': 0});
      }
      ancestorId = ancestor['parent_node_id'] as String?;
    }
    final cardId = _id();
    String? imageId;
    if (draft.imageBytes != null) {
      final staged = File(p.join(libraryPath, 'staging', '${_id()}.image'));
      await staged.writeAsBytes(draft.imageBytes!, flush: true);
      imageId = (await _importResource(
        w,
        staged,
        'image',
        draft.imageExtension,
      )).id;
      await staged.delete();
    }
    final card = <String, Object?>{
      'id': cardId,
      'project_id': draft.projectId,
      'title': _title(draft.title),
      'excerpt_snapshot': draft.text,
      'body': draft.text,
      'note': draft.note,
      'thoughts_json': encodePersonalThoughts(
        legacyPersonalThoughts(cardId, draft.note),
      ),
      'color': draft.color,
      'image_resource_id': imageId,
      'updated_at': _now(),
      'deleted_at': null,
    };
    await w.put('cards', card);
    for (final anchor in draft.anchors) {
      await _validateAnchor(anchor, draft.projectId);
      await w.put('anchors', _anchorRow(anchor, cardId));
      if (draft.createHighlight) {
        await w.put('annotations', {
          'id': _id(),
          'revision_id': anchor.revisionId,
          'page_index': anchor.epubLocator == null ? anchor.pageIndex : null,
          'locator_json': anchor.epubLocator?.encode(),
          'quads': _encodeQuads(anchor.quads),
          'kind': imageId == null ? 'highlight' : 'region',
          'text': '',
          'color': draft.color,
          'card_id': cardId,
        });
      }
    }
    final node = <String, Object?>{
      'id': _id(),
      'map_id': draft.mapId,
      'card_id': cardId,
      'parent_node_id': draft.parentNodeId,
      'x': draft.x,
      'y': draft.y,
      'width': 220.0,
      'height': 116.0,
      'collapsed': 0,
      'deleted_at': null,
      'sort_index': await _parentIsStructured(map, draft.parentNodeId)
          ? await _nextTopicIndex(draft.mapId, draft.parentNodeId)
          : null,
      'branch_side': null,
    };
    await w.put('nodes', node);
    return ExcerptResult(card: _card(card), node: _node(node));
  }

  Future<List<AppAnnotation>> listAnnotations(
    String revisionId, {
    int? pageIndex,
  }) => _exclusive(
    () async => (await _rows(
      '''SELECT a.* FROM annotations a WHERE a.revision_id=?
         ${pageIndex == null ? '' : 'AND a.page_index=?'}
         AND (a.card_id IS NULL OR EXISTS (
           SELECT 1 FROM cards c JOIN projects p ON p.id=c.project_id
           JOIN nodes n ON n.card_id=c.id JOIN maps m ON m.id=n.map_id
           WHERE c.id=a.card_id AND c.deleted_at IS NULL AND p.deleted_at IS NULL
             AND n.deleted_at IS NULL AND m.deleted_at IS NULL))''',
      [revisionId, ?pageIndex],
    )).map(_annotation).toList(),
  );

  Future<AppAnnotation> createAnnotation({
    required AnchorDraft anchor,
    String kind = 'highlight',
    String text = '',
    String color = '#F7D976',
  }) => _mutate('添加批注', (w) async {
    if (!{'highlight', 'region', 'note'}.contains(kind)) _invalid('不支持的批注类型。');
    final revision = await _require('revisions', anchor.revisionId);
    final document = await _require(
      'documents',
      revision['document_id'] as String,
    );
    await _validateAnchor(anchor, document['project_id'] as String);
    final row = <String, Object?>{
      'id': _id(),
      'revision_id': anchor.revisionId,
      'page_index': anchor.epubLocator == null ? anchor.pageIndex : null,
      'locator_json': anchor.epubLocator?.encode(),
      'quads': _encodeQuads(anchor.quads),
      'kind': kind,
      'text': text,
      'color': color,
      'card_id': null,
    };
    await w.put('annotations', row);
    return _annotation(row);
  });

  Future<AppAnnotation> addAnnotation({
    required AnchorDraft anchor,
    String kind = 'highlight',
    String text = '',
    String color = '#F7D976',
  }) => createAnnotation(anchor: anchor, kind: kind, text: text, color: color);

  Future<void> updateAnnotation(
    String annotationId, {
    String? text,
    String? color,
  }) => _mutate('编辑批注', (w) async {
    final row = await _require('annotations', annotationId);
    await w.put('annotations', {...row, 'text': ?text, 'color': ?color});
  });

  Future<void> deleteAnnotation(String annotationId) =>
      _mutate('删除批注', (w) async {
        await _require('annotations', annotationId);
        await w.remove('annotations', annotationId);
      });

  Future<void> _validateAnchor(AnchorDraft anchor, String projectId) async {
    final revision = await _require('revisions', anchor.revisionId);
    final doc = await _require('documents', revision['document_id'] as String);
    _sameProject(doc['project_id'], projectId);
    if (revision['format'] == 'epub') {
      final locator = anchor.epubLocator;
      if (locator == null || anchor.quads.isNotEmpty || anchor.textLayerId != null ||
          anchor.textStart != null || anchor.textEnd != null) {
        _invalid('EPUB 来源必须使用内容定位，不得保存 PDF 页面几何。');
      }
      await _validateEpubLocator(revision, locator);
      return;
    }
    if (anchor.epubLocator != null) _invalid('PDF 来源不能绑定 EPUB 定位。');
    _validatePage(revision, anchor.pageIndex);
    _validateQuads(anchor.quads);
    if (anchor.textStart != null || anchor.textEnd != null) {
      if (anchor.textLayerId == null ||
          anchor.textStart == null ||
          anchor.textEnd == null) {
        _invalid('文字范围必须绑定具体文字层版本。');
      }
    }
    if (anchor.textLayerId != null) {
      final layer = await _require('text_layers', anchor.textLayerId!);
      if (layer['revision_id'] != anchor.revisionId ||
          layer['page_index'] != anchor.pageIndex) {
        _invalid('原文锚点与文字层页面不一致。');
      }
      final length = (layer['text'] as String).length;
      if (anchor.textStart != null &&
          (anchor.textStart! < 0 ||
              anchor.textEnd! <= anchor.textStart! ||
              anchor.textEnd! > length)) {
        _invalid('摘录文字范围超出文字层。');
      }
    }
  }

  Future<void> _validateParent(String mapId, String? parentId) async {
    if (parentId == null) return;
    final parent = await _require('nodes', parentId, active: true);
    if (parent['map_id'] != mapId) _invalid('父节点必须位于同一脑图。');
  }

  Future<ResourceRecord> _importResource(
    _Writer writer,
    File source,
    String kind,
    String extension,
  ) async {
    if (!RegExp(r'^[a-zA-Z0-9]{1,8}$').hasMatch(extension)) {
      _invalid('资源扩展名不合法。');
    }
    final staged = File(p.join(libraryPath, 'staging', '${_id()}.resource'));
    await source.copy(staged.path);
    final stagedHandle = await staged.open(mode: FileMode.append);
    try {
      await stagedHandle.flush();
    } finally {
      await stagedHandle.close();
    }
    final hash = await _fileSha256(staged.path);
    final size = await staged.length();
    final existing = await _rows('SELECT * FROM resources WHERE sha256=?', [
      hash,
    ]);
    if (existing.isNotEmpty) {
      final resource = _resource(existing.single);
      final stored = File(
        _safeResourcePath(libraryPath, resource.relativePath),
      );
      if (!await stored.exists() || await _fileSha256(stored.path) != hash) {
        await staged.delete();
        throw const RepositoryException(
          RepositoryError.corruptBackup,
          '已登记的资源损坏，禁止覆盖。',
        );
      }
      await staged.delete();
      return resource;
    }
    final relative = 'resources/$hash.${extension.toLowerCase()}';
    final destination = File(_safeResourcePath(libraryPath, relative));
    if (await destination.exists()) {
      if (await _fileSha256(destination.path) != hash) {
        await staged.delete();
        throw const RepositoryException(
          RepositoryError.corruptBackup,
          '同名资源内容不一致。',
        );
      }
      await staged.delete();
    } else {
      await staged.rename(destination.path);
    }
    final row = <String, Object?>{
      'id': _id(),
      'sha256': hash,
      'kind': kind,
      'size': size,
      'relative_path': relative,
    };
    await writer.put('resources', row);
    return _resource(row);
  }

  Future<String> backupTo(String destination) =>
      _exclusive(() => _backupLibrary(this, destination));

  Future<void> restoreFrom(
    String archivePath, {
    Future<void> Function()? beforeSwitch,
  }) async {
    // 先停掉外部任务，再取得仓储锁；钩子可安全等待最后一笔 OCR 状态写入。
    if (beforeSwitch != null) await beforeSwitch();
    await _exclusive(() => _restoreLibrary(this, archivePath));
  }
}

class _RowChange {
  const _RowChange(this.table, this.id, this.before, this.after);
  final String table;
  final String id;
  final _Row? before;
  final _Row? after;
}

class _HistoryEntry {
  const _HistoryEntry(this.label, this.changes);
  final String label;
  final List<_RowChange> changes;
}

class _Writer {
  _Writer(this.repository);
  final OpenNoteRepository repository;
  final Map<String, _RowChange> _before = {};

  Future<void> _remember(String table, String id) async {
    if (!databaseTableNames.contains(table)) throw ArgumentError.value(table);
    final key = '$table:$id';
    if (_before.containsKey(key)) return;
    final rows = await repository._rows('SELECT * FROM $table WHERE id=?', [
      id,
    ]);
    _before[key] = _RowChange(
      table,
      id,
      rows.isEmpty ? null : rows.single,
      null,
    );
  }

  Future<void> put(String table, _Row row) async {
    final id = row['id'] as String;
    await _remember(table, id);
    await _putRow(repository._database, table, row);
  }

  Future<void> remove(String table, String id) async {
    await _remember(table, id);
    await repository._database.customStatement(
      'DELETE FROM $table WHERE id=?',
      [id],
    );
  }

  Future<List<_RowChange>> changes() async {
    final result = <_RowChange>[];
    for (final entry in _before.values) {
      final rows = await repository._rows(
        'SELECT * FROM ${entry.table} WHERE id=?',
        [entry.id],
      );
      final after = rows.isEmpty ? null : rows.single;
      if (encodeJson(entry.before) != encodeJson(after)) {
        result.add(_RowChange(entry.table, entry.id, entry.before, after));
      }
    }
    return result;
  }
}

Future<void> _putRow(OpenNoteDatabase database, String table, _Row row) async {
  if (!databaseTableNames.contains(table)) throw ArgumentError.value(table);
  final columns = row.keys.toList();
  final assignments = columns
      .where((c) => c != 'id')
      .map((c) => '$c=excluded.$c')
      .join(',');
  await database.customStatement(
    'INSERT INTO $table (${columns.join(',')}) VALUES (${List.filled(columns.length, '?').join(',')}) ON CONFLICT(id) DO UPDATE SET $assignments',
    columns.map((c) => row[c]).toList(),
  );
}

String _id() => const Uuid().v4();

/// 整本 PDF 的 hash 计算也在后台执行，避免占用界面 isolate。
Future<String> _fileSha256(String path) => Isolate.run(
  () async => (await sha256.bind(File(path).openRead()).first).toString(),
);
int _now() => DateTime.now().millisecondsSinceEpoch;
Never _invalid(String message) =>
    throw RepositoryException(RepositoryError.invalidInput, message);
String _title(String title) {
  final result = title.trim();
  if (result.isEmpty) _invalid('名称不能为空。');
  return result;
}

void _sameProject(Object? actual, String expected) {
  if (actual != expected) {
    throw const RepositoryException(
      RepositoryError.wrongProject,
      '记录不属于目标学习项目。',
    );
  }
}

void _validatePage(_Row revision, int page) {
  final count = revision['page_count'] as int;
  if (page < 0 || (count > 0 && page >= count)) _invalid('页码超出 PDF 范围。');
}

void _validateQuads(List<PdfQuad> quads) {
  if (quads.isEmpty ||
      quads.any(
        (q) =>
            q.points.length != 4 ||
            q.points.any((v) => !v.x.isFinite || !v.y.isFinite),
      )) {
    _invalid('原文区域坐标不合法。');
  }
}

DateTime? _date(Object? value) =>
    value == null ? null : DateTime.fromMillisecondsSinceEpoch(value as int);
String _encodeQuads(List<PdfQuad> quads) =>
    encodeJson(quads.map((q) => q.toJson()).toList());
List<PdfQuad> _quads(Object? value) =>
    decodeObjectList(value as String).map(PdfQuad.fromJson).toList();
_Row _anchorRow(AnchorDraft a, String cardId) => {
  'id': _id(),
  'card_id': cardId,
  'revision_id': a.revisionId,
  'page_index': a.epubLocator == null ? a.pageIndex : null,
  'locator_json': a.epubLocator?.encode(),
  'quads': _encodeQuads(a.quads),
  'text_layer_id': a.textLayerId,
  'text_start': a.textStart,
  'text_end': a.textEnd,
  'context': a.context,
};
StudyProject _project(_Row r) => StudyProject(
  id: r['id'] as String,
  title: r['title'] as String,
  createdAt: _date(r['created_at'])!,
  deletedAt: _date(r['deleted_at']),
);
ManagedDocument _document(_Row r) => ManagedDocument(
  id: r['id'] as String,
  projectId: r['project_id'] as String,
  title: r['title'] as String,
  activeRevisionId: r['active_revision_id'] as String,
  deletedAt: _date(r['deleted_at']),
  format:DocumentFormat.values.byName(r['format'] as String? ?? 'pdf'),
);
ResourceRecord _resource(_Row r) => ResourceRecord(
  id: r['id'] as String,
  sha256: r['sha256'] as String,
  kind: r['kind'] as String,
  size: r['size'] as int,
  relativePath: r['relative_path'] as String,
);
DocumentRevision _revision(_Row r) => DocumentRevision(
  id: r['id'] as String,
  documentId: r['document_id'] as String,
  resourceId: r['resource_id'] as String,
  contentHash: r['content_hash'] as String,
  pageCount: r['page_count'] as int,
  format: DocumentFormat.values.byName(r['format'] as String? ?? 'pdf'),
  metadata: Map<String,dynamic>.from(jsonDecode(r['metadata_json'] as String? ?? '{}') as Map),
  pageGeometry: decodeObjectList(r['geometry'] as String)
      .map(PdfPageGeometry.fromJson)
      .toList(),
);
NoteCard _card(_Row r) => NoteCard(
  id: r['id'] as String,
  projectId: r['project_id'] as String,
  title: r['title'] as String,
  excerptSnapshot: r['excerpt_snapshot'] as String,
  body: r['body'] as String,
  note: r['note'] as String,
  thoughtEntries: decodePersonalThoughts(r['thoughts_json'] as String),
  color: r['color'] as String,
  imageResourceId: r['image_resource_id'] as String?,
  deletedAt: _date(r['deleted_at']),
);
SourceAnchor _anchor(_Row r) => SourceAnchor(
  id: r['id'] as String,
  cardId: r['card_id'] as String,
  revisionId: r['revision_id'] as String,
  pageIndex: r['page_index'] as int? ?? 0,
  epubLocator: r['locator_json'] == null ? null : DocumentLocator.decode(r['locator_json'] as String) as EpubLocator,
  quads: _quads(r['quads']),
  textLayerId: r['text_layer_id'] as String?,
  textStart: r['text_start'] as int?,
  textEnd: r['text_end'] as int?,
  context: r['context'] as String,
);
AppAnnotation _annotation(_Row r) => AppAnnotation(
  id: r['id'] as String,
  revisionId: r['revision_id'] as String,
  pageIndex: r['page_index'] as int? ?? 0,
  epubLocator: r['locator_json'] == null ? null : DocumentLocator.decode(r['locator_json'] as String) as EpubLocator,
  quads: _quads(r['quads']),
  kind: r['kind'] as String,
  text: r['text'] as String,
  color: r['color'] as String,
  cardId: r['card_id'] as String?,
);
MindMap _map(_Row r) => MindMap(
  id: r['id'] as String,
  projectId: r['project_id'] as String,
  title: r['title'] as String,
  deletedAt: _date(r['deleted_at']),
  layout: MapLayoutKind.values.byName(r['layout_kind'] as String? ?? 'free'),
  defaultStyle: TopicStyle.fromJson(
    Map<String, dynamic>.from(
      jsonDecode(r['default_style_json'] as String? ?? '{}') as Map,
    ),
  ),
);
MapNode _node(_Row r) => MapNode(
  id: r['id'] as String,
  mapId: r['map_id'] as String,
  cardId: r['card_id'] as String,
  parentNodeId: r['parent_node_id'] as String?,
  x: (r['x'] as num).toDouble(),
  y: (r['y'] as num).toDouble(),
  width: (r['width'] as num).toDouble(),
  height: (r['height'] as num).toDouble(),
  collapsed: r['collapsed'] == 1,
  sortIndex: r['sort_index'] as int?,
  branchLayout: r['branch_layout'] == null
      ? null
      : MapLayoutKind.values.byName(r['branch_layout'] as String),
  branchSide: r['branch_side'] as int?,
  style: r['topic_style_json'] == null
      ? null
      : TopicStyle.fromJson(
          Map<String, dynamic>.from(
            jsonDecode(r['topic_style_json'] as String) as Map,
          ),
        ),
);
MapEdge _edge(_Row r) => MapEdge(
  id: r['id'] as String,
  mapId: r['map_id'] as String,
  fromNodeId: r['from_node_id'] as String,
  toNodeId: r['to_node_id'] as String,
  label: r['label'] as String? ?? '',
  style: RelationshipStyle.fromJson(
    Map<String, dynamic>.from(
      jsonDecode(r['style_json'] as String? ?? '{}') as Map,
    ),
  ),
);
PageTextLayer _layer(_Row r) => PageTextLayer(
  id: r['id'] as String,
  revisionId: r['revision_id'] as String,
  pageIndex: r['page_index'] as int,
  source: TextLayerSource.values.byName(r['source'] as String),
  text: r['text'] as String,
  fragments: decodeObjectList(r['fragments'] as String)
      .map(TextFragment.fromJson)
      .toList(),
  engineVersion: r['engine_version'] as String,
  parameters: Map<String, Object?>.from(
    jsonDecode(r['parameters'] as String) as Map,
  ),
  createdAt: _date(r['created_at'])!,
  isCurrent: r['is_current'] == 1,
);
OcrTask _task(_Row r) => OcrTask(
  id: r['id'] as String,
  revisionId: r['revision_id'] as String,
  pageIndex: r['page_index'] as int,
  modelVersion: r['model_version'] as String,
  status: OcrTaskStatus.values.byName(r['status'] as String),
  error: r['error'] as String,
  sessionId: r['session_id'] as String?,
);
