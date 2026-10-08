part of 'open_note_repository.dart';

extension PermanentTrashCommands on OpenNoteRepository {
  Future<TrashPurgePreview> previewTrashPurge(
    String trashId, {
    bool discardSessionHistory = false,
  }) => _exclusive(() async {
    final plan = await _planPurge(trashId, discardSessionHistory);
    return plan.preview();
  });

  /// 不可撤销。只有显式选择时才清空本次会话的撤销、重做记录。
  Future<TrashPurgePreview> purgeTrash(
    String trashId, {
    bool discardSessionHistory = false,
  }) => _exclusive(() async {
    final plan = await _planPurge(trashId, discardSessionHistory);
    if (plan.blockers.isNotEmpty) {
      throw RepositoryException(
        RepositoryError.referenced,
        plan.blockers.join('\n'),
      );
    }
    await _database.transaction(() async {
      await _database.customStatement('PRAGMA defer_foreign_keys = ON');
      final nodeIds = plan.ids['nodes'] ?? <String>{};
      if (nodeIds.isNotEmpty) {
        for (final row in await _rows('SELECT * FROM summaries')) {
          if ((plan.ids['summaries'] ?? {}).contains(row['id'])) continue;
          final s = _summary(row);
          final retained = s.nodeIds
              .where((id) => !nodeIds.contains(id))
              .toList();
          final parent = nodeIds.contains(s.parentNodeId)
              ? null
              : s.parentNodeId;
          {
            await _database.customStatement(
              'UPDATE summaries SET node_ids=?,parent_node_id=? WHERE id=?',
              [encodeJson(retained), parent, s.id],
            );
          }
        }
        for (final row in await _rows('SELECT * FROM boundaries')) {
          if ((plan.ids['boundaries'] ?? {}).contains(row['id'])) continue;
          final boundary = _boundary(row);
          final retained = boundary.nodeIds
              .where((id) => !nodeIds.contains(id))
              .toList();
          if (retained.isEmpty) continue; // 已列入清理计划。
          if (nodeIds.contains(boundary.parentNodeId) && retained.length > 1) {
            for (final id in retained.skip(1)) {
              await _putRow(_database, 'boundaries', {
                ...row,
                'id': _id(),
                'parent_node_id': null,
                'node_ids': encodeJson([id]),
              });
            }
            retained.removeRange(1, retained.length);
          }
          await _database.customStatement(
            'UPDATE boundaries SET node_ids=?,parent_node_id=? WHERE id=?',
            [
              encodeJson(retained),
              nodeIds.contains(boundary.parentNodeId)
                  ? null
                  : boundary.parentNodeId,
              boundary.id,
            ],
          );
        }
        // 回收卡片的旧父节点也可能指向即将被永久移除的脑图节点。
        for (final batch in _purgeBatches(nodeIds)) {
          final slots = List.filled(batch.length, '?').join(',');
          await _database.customStatement(
            'UPDATE nodes SET parent_node_id=NULL WHERE parent_node_id IN ($slots)',
            batch,
          );
        }
        for (final trash in await _rows(
          "SELECT * FROM trash WHERE kind='card'",
        )) {
          if (plan.ids['trash']!.contains(trash['id'])) continue;
          final payload = Map<String, dynamic>.from(
            jsonDecode(trash['payload'] as String) as Map,
          );
          payload['nodeIds'] = (payload['nodeIds'] as List? ?? const [])
              .where((id) => !nodeIds.contains(id))
              .toList();
          payload['children'] = (payload['children'] as List? ?? const [])
              .where((entry) => !(entry as Map).values.any(nodeIds.contains))
              .toList();
          await _database.customStatement(
            'UPDATE trash SET payload=? WHERE id=?',
            [encodeJson(payload), trash['id']],
          );
        }
      }
      for (final table in const [
        'summaries',
        'boundaries',
        'edges',
        'nodes',
        'annotations',
        'anchors',
        'cards',
        'maps',
        'text_layers',
        'ocr_tasks',
        'reading_positions',
        'documents',
        'revisions',
        'trash',
        'projects',
        'resources',
      ]) {
        final ids = plan.ids[table] ?? <String>{};
        if (ids.isEmpty) continue;
        for (final batch in _purgeBatches(ids)) {
          await _database.customStatement(
            'DELETE FROM $table WHERE id IN (${List.filled(batch.length, '?').join(',')})',
            batch,
          );
        }
      }
      final removedDocuments = plan.ids['documents'] ?? <String>{};
      if (removedDocuments.isNotEmpty) {
        for (final row in await _rows(
          'SELECT id,opened_document_ids FROM project_sessions',
        )) {
          final ids = (jsonDecode(row['opened_document_ids'] as String) as List)
              .cast<String>();
          if (ids.any(removedDocuments.contains)) {
            await _database.customStatement(
              'UPDATE project_sessions SET opened_document_ids=? WHERE id=?',
              [
                encodeJson(
                  ids.where((id) => !removedDocuments.contains(id)).toList(),
                ),
                row['id'],
              ],
            );
          }
        }
      }
    });
    if (discardSessionHistory) {
      _undo.clear();
      _redo.clear();
    }
    _notify();
    // SQL 提交后才删除物理文件。中断留下孤立文件，可安全地重试回收。
    final pending = await _cleanupResourceFiles();
    return plan.preview(pendingResourcePaths: pending);
  });

  /// 只清理无 SQL、回收站或会话历史引用的、内容 hash 正确的托管文件。
  Future<List<String>> retryResourceCleanup() =>
      _exclusive(_cleanupResourceFiles);

  Future<_PurgePlan> _planPurge(String trashId, bool discardHistory) async {
    final trash = await _require('trash', trashId);
    final kind = TrashKind.values.byName(trash['kind'] as String);
    final entity = await _require(
      _trashTable(kind),
      trash['entity_id'] as String,
    );
    if (entity['deleted_at'] == null) _invalid('只能永久清理回收站中的项目。');
    final plan = _PurgePlan();
    plan.add('trash', trashId);
    plan.add(_trashTable(kind), entity['id'] as String);
    if (kind == TrashKind.project) {
      for (final table in const ['cards', 'maps', 'documents', 'trash']) {
        for (final row in await _rows(
          'SELECT id FROM $table WHERE project_id=?',
          [entity['id']],
        )) {
          plan.add(table, row['id'] as String);
        }
      }
    }
    final cards = plan.ids['cards'] ?? <String>{};
    final maps = plan.ids['maps'] ?? <String>{};
    final documents = plan.ids['documents'] ?? <String>{};
    for (final row in await _purgeRows(
      'revisions',
      'document_id',
      documents,
      columns: 'id,resource_id',
    )) {
      plan.add('revisions', row['id'] as String);
      plan.resourceCandidates.add(row['resource_id'] as String);
    }
    for (final row in await _purgeRows(
      'cards',
      'id',
      cards,
      columns: 'id,image_resource_id',
    )) {
      final resource = row['image_resource_id'] as String?;
      if (resource != null) plan.resourceCandidates.add(resource);
    }
    for (final row in [
      ...await _purgeRows('nodes', 'map_id', maps),
      ...await _purgeRows('nodes', 'card_id', cards),
    ]) {
      plan.add('nodes', row['id'] as String);
    }
    final nodes = plan.ids['nodes'] ?? <String>{};
    for (final row in await _rows('SELECT * FROM summaries')) {
      final s = _summary(row);
      if (maps.contains(s.mapId) ||
          nodes.contains(s.summaryNodeId) ||
          s.nodeIds.every(nodes.contains)) {
        plan.add('summaries', s.id);
      }
    }
    for (final row in await _rows('SELECT * FROM boundaries')) {
      final boundary = _boundary(row);
      if (maps.contains(boundary.mapId) ||
          boundary.nodeIds.every(nodes.contains)) {
        plan.add('boundaries', boundary.id);
      }
    }
    for (final column in const ['from_node_id', 'to_node_id']) {
      for (final row in await _purgeRows('edges', column, nodes)) {
        plan.add('edges', row['id'] as String);
      }
    }
    final revisions = plan.ids['revisions'] ?? <String>{};
    for (final row in await _purgeRows(
      'anchors',
      'revision_id',
      revisions,
      columns: 'id,card_id',
    )) {
      if (!cards.contains(row['card_id'])) {
        plan.blockers.add('PDF 仍被正常卡片或回收站卡片引用，必须保留原文回源。');
        break;
      }
    }
    for (final table in const [
      'text_layers',
      'ocr_tasks',
      'reading_positions',
      'annotations',
    ]) {
      final column = table == 'reading_positions' ? 'id' : 'revision_id';
      for (final row in await _purgeRows(table, column, revisions)) {
        plan.add(table, row['id'] as String);
      }
    }
    for (final table in const ['anchors', 'annotations']) {
      for (final row in await _purgeRows(table, 'card_id', cards)) {
        plan.add(table, row['id'] as String);
      }
    }
    final allIds = plan.ids.values.expand((ids) => ids).toSet();
    if (!discardHistory && _historyReferences(allIds)) {
      plan.blockers.add('本次会话的撤销或重做记录仍引用此项目；永久清理需要清空会话历史。');
    }
    for (final resourceId in plan.resourceCandidates) {
      final revisionRefs = await _rows(
        'SELECT id FROM revisions WHERE resource_id=?',
        [resourceId],
      );
      final cardRefs = await _rows(
        'SELECT id FROM cards WHERE image_resource_id=?',
        [resourceId],
      );
      if (revisionRefs.any((r) => !revisions.contains(r['id'])) ||
          cardRefs.any((r) => !cards.contains(r['id']))) {
        continue;
      }
      final resource = await _require('resources', resourceId);
      if (!discardHistory &&
          _historyReferences({
            resourceId,
            resource['sha256'] as String,
            resource['relative_path'] as String,
          })) {
        continue;
      }
      plan.add('resources', resourceId);
      plan.reclaimableBytes += resource['size'] as int;
    }
    return plan;
  }

  Future<List<_Row>> _purgeRows(
    String table,
    String column,
    Set<String> ids, {
    String columns = 'id',
  }) async {
    if (ids.isEmpty) return [];
    final rows = <_Row>[];
    for (final batch in _purgeBatches(ids)) {
      rows.addAll(
        await _rows(
          'SELECT $columns FROM $table WHERE $column IN (${List.filled(batch.length, '?').join(',')})',
          batch,
        ),
      );
    }
    return rows;
  }

  bool _historyReferences(Set<String> ids) {
    if (ids.isEmpty) return false;
    bool contains(Object? value) {
      if (value is Map) return value.values.any(contains);
      if (value is Iterable) return value.any(contains);
      if (value is! String) return false;
      if (ids.contains(value)) return true;
      if (value.startsWith('{') || value.startsWith('[')) {
        try {
          return contains(jsonDecode(value));
        } on FormatException {
          return false;
        }
      }
      return false;
    }

    return [..._undo, ..._redo].any(
      (entry) => entry.changes.any(
        (change) =>
            ids.contains(change.id) ||
            contains(change.before) ||
            contains(change.after),
      ),
    );
  }

  Future<List<String>> _cleanupResourceFiles() async {
    // 上次清理因撤销引用而保留的资源，历史结束后可以继续回收。
    final unused = await _rows(
      'SELECT a.* FROM resources a WHERE NOT EXISTS (SELECT 1 FROM revisions r WHERE r.resource_id=a.id) AND NOT EXISTS (SELECT 1 FROM cards c WHERE c.image_resource_id=a.id) AND NOT EXISTS (SELECT 1 FROM epub_image_ocr o WHERE o.image_resource_id=a.id)',
    );
    await _database.transaction(() async {
      for (final resource in unused) {
        if (_historyReferences({
          resource['id'] as String,
          resource['sha256'] as String,
          resource['relative_path'] as String,
        })) {
          continue;
        }
        await _database.customStatement('DELETE FROM resources WHERE id=?', [
          resource['id'],
        ]);
      }
    });
    final registered = (await _rows('SELECT relative_path FROM resources'))
        .map((r) => r['relative_path'] as String)
        .toSet();
    final pending = <String>[];
    final directory = Directory(p.join(libraryPath, 'resources'));
    final names = RegExp(r'^([a-f0-9]{64})\.([a-z0-9]{1,12})$');
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      final match = names.firstMatch(p.basename(entity.path));
      if (match == null) continue;
      final relative = 'resources/${p.basename(entity.path)}';
      final hash = match.group(1)!;
      if (registered.contains(relative) ||
          _historyReferences({relative, hash})) {
        continue;
      }
      try {
        if (await _fileSha256(entity.path) != hash) {
          pending.add(relative);
          continue;
        }
        await File(_safeResourcePath(libraryPath, relative)).delete();
      } on FileSystemException {
        pending.add(relative);
      }
    }
    return pending;
  }
}

class _PurgePlan {
  final ids = <String, Set<String>>{};
  final resourceCandidates = <String>{};
  final blockers = <String>[];
  int reclaimableBytes = 0;
  void add(String table, String id) => (ids[table] ??= {}).add(id);
  TrashPurgePreview preview({List<String> pendingResourcePaths = const []}) =>
      TrashPurgePreview(
        blockers: List.unmodifiable(blockers),
        cardCount: ids['cards']?.length ?? 0,
        documentCount: ids['documents']?.length ?? 0,
        mapCount: ids['maps']?.length ?? 0,
        resourceCount: ids['resources']?.length ?? 0,
        reclaimableBytes: reclaimableBytes,
        pendingResourcePaths: pendingResourcePaths,
      );
}

Iterable<List<String>> _purgeBatches(Set<String> ids) sync* {
  final values = ids.toList();
  for (var start = 0; start < values.length; start += 512) {
    final end = start + 512 < values.length ? start + 512 : values.length;
    yield values.sublist(start, end);
  }
}
