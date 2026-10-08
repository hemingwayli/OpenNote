part of 'open_note_repository.dart';

extension TextAndTrashCommands on OpenNoteRepository {
  Future<List<PageTextLayer>> loadTextLayers(
    String revisionId, {
    int? pageIndex,
    Iterable<int>? pageIndices,
    bool currentOnly = true,
  }) => _exclusive(() async {
    final pages = pageIndices?.toSet().toList();
    if (pages != null && pages.isEmpty) return <PageTextLayer>[];
    return (await _rows(
      'SELECT * FROM text_layers WHERE revision_id=? ${pageIndex == null ? '' : 'AND page_index=?'} ${pages == null ? '' : 'AND page_index IN (${List.filled(pages.length, '?').join(',')})'} ${currentOnly ? 'AND is_current=1' : ''} ORDER BY page_index,created_at',
      [revisionId, ?pageIndex, ...?pages],
    )).map(_layer).toList();
  });

  Future<PageTextLayer> saveTextLayer(
    TextLayerDraft draft, {
    required String sessionId,
    String? ocrTaskId,
  }) => _mutate(
    '保存页面文字层',
    (w) async {
      _checkSession(sessionId);
      final revision = await _require('revisions', draft.revisionId);
      _validatePage(revision, draft.pageIndex);
      if (draft.engineVersion.trim().isEmpty) _invalid('文字层需要记录引擎版本。');
      for (final fragment in draft.fragments) {
        if (fragment.start < 0 ||
            fragment.length < 0 ||
            fragment.start + fragment.length > draft.text.length ||
            (fragment.confidence != null &&
                (!fragment.confidence!.isFinite ||
                    fragment.confidence! < 0 ||
                    fragment.confidence! > 1))) {
          _invalid('文字范围或置信度不合法。');
        }
        _validateQuads([fragment.quad]);
      }
      _Row? task;
      if (ocrTaskId != null) {
        task = await _require('ocr_tasks', ocrTaskId);
        if (task['session_id'] != sessionId ||
            task['status'] != 'running' ||
            task['revision_id'] != draft.revisionId ||
            task['page_index'] != draft.pageIndex) {
          throw const RepositoryException(
            RepositoryError.staleSession,
            'OCR 任务已失效或已取消。',
          );
        }
      }
      final current = await _rows(
        'SELECT * FROM text_layers WHERE revision_id=? AND page_index=? AND is_current=1',
        [draft.revisionId, draft.pageIndex],
      );
      final encodedFragments = encodeJson(
        draft.fragments.map((f) => f.toJson()).toList(),
      );
      final encodedParameters = encodeJson({
        ...draft.parameters,
        'formatVersion': 1,
      });
      if (current.isNotEmpty) {
        final previous = current.single;
        // 已完成 OCR 页不会被迟到的原生文本回调覆盖。
        if (previous['source'] == 'ocr' &&
            draft.source == TextLayerSource.nativePdf) {
          if (task != null) {
            await w.put('ocr_tasks', {
              ...task,
              'status': 'completed',
              'error': '',
              'updated_at': _now(),
            });
          }
          return _layer(previous);
        }
        if (previous['source'] == draft.source.name &&
            previous['text'] == draft.text &&
            previous['fragments'] == encodedFragments &&
            previous['engine_version'] == draft.engineVersion &&
            previous['parameters'] == encodedParameters) {
          if (task != null) {
            await w.put('ocr_tasks', {
              ...task,
              'status': 'completed',
              'error': '',
              'updated_at': _now(),
            });
          }
          return _layer(previous);
        }
        await w.put('text_layers', {...previous, 'is_current': 0});
      }
      final row = <String, Object?>{
        'id': _id(),
        'revision_id': draft.revisionId,
        'page_index': draft.pageIndex,
        'source': draft.source.name,
        'text': draft.text,
        'fragments': encodedFragments,
        'engine_version': draft.engineVersion,
        'parameters': encodedParameters,
        'created_at': _now(),
        'is_current': 1,
      };
      await w.put('text_layers', row);
      if (task != null) {
        await w.put('ocr_tasks', {
          ...task,
          'status': 'completed',
          'error': '',
          'updated_at': _now(),
        });
      }
      return _layer(row);
    },
    recordUndo: false,
    invalidateRedo: false,
  );

  Future<List<SearchHit>> search(
    String projectId,
    String query, {
    String? documentId,
    int limit = 100,
  }) => _exclusive(() async {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty || limit <= 0) return <SearchHit>[];
    final results = <SearchHit>[];
    if (documentId == null) {
      for (final row in await _rows(
        'SELECT * FROM cards WHERE project_id=? AND deleted_at IS NULL AND (instr(lower(title),?)>0 OR instr(lower(body),?)>0 OR instr(lower(note),?)>0) LIMIT ?',
        [projectId, needle, needle, needle, limit],
      )) {
        final text = '${row['title']}\n${row['body']}\n${row['note']}';
        final start = text.toLowerCase().indexOf(needle);
        results.add(
          SearchHit(
            kind: SearchHitKind.card,
            id: row['id'] as String,
            cardId: row['id'] as String,
            text: _snippet(text, start, needle.length),
            start: start,
            end: start + needle.length,
          ),
        );
      }
    }
    final pages = await _rows(
      'SELECT l.*,d.id AS document_id FROM text_layers l JOIN revisions r ON r.id=l.revision_id JOIN documents d ON d.id=r.document_id WHERE d.project_id=? AND d.deleted_at IS NULL AND l.is_current=1 ${documentId == null ? '' : 'AND d.id=?'} AND instr(lower(l.text),?)>0 ORDER BY d.title,l.page_index LIMIT ?',
      [projectId, ?documentId, needle, limit],
    );
    for (final row in pages) {
      final layer = _layer(row);
      final lower = layer.text.toLowerCase();
      var start = lower.indexOf(needle);
      while (start >= 0 && results.length < limit) {
        final end = start + needle.length;
        final quads = layer.fragments
            .where((f) => f.start < end && f.start + f.length > start)
            .map((f) => f.quad)
            .toList();
        results.add(
          SearchHit(
            kind: SearchHitKind.page,
            id: '${layer.id}:$start',
            documentId: row['document_id'] as String,
            revisionId: layer.revisionId,
            textLayerId: layer.id,
            pageIndex: layer.pageIndex,
            quads: quads,
            text: _snippet(layer.text, start, needle.length),
            start: start,
            end: end,
          ),
        );
        start = lower.indexOf(needle, end);
      }
      if (results.length >= limit) break;
    }
    if (results.length < limit) {
      final chapters = await _rows(
        '''SELECT s.*,d.id AS document_id FROM epub_sections s
        JOIN revisions r ON r.id=s.revision_id JOIN documents d ON d.id=r.document_id
        WHERE d.project_id=? AND d.deleted_at IS NULL AND s.text IS NOT NULL
        ${documentId == null ? '' : 'AND d.id=?'} AND instr(lower(s.text),?)>0
        ORDER BY d.title,s.spine_index LIMIT ?''',
        [projectId, ?documentId, needle, limit],
      );
      for (final row in chapters) {
        final text = row['text'] as String;
        final fragments = decodeObjectList(row['fragments'] as String);
        var start = text.toLowerCase().indexOf(needle);
        while (start >= 0 && results.length < limit) {
          final end = start + needle.length;
          final first = fragments.firstWhere(
            (f) => (f['start'] as int) + (f['length'] as int) > start,
          );
          final last = fragments.lastWhere((f) => (f['start'] as int) < end);
          final locator = EpubLocator(
            href: row['href'] as String,
            cfi: _epubRangeCfi(
              first['cfi'] as String,
              start - (first['start'] as int),
              last['cfi'] as String,
              end - (last['start'] as int),
            ),
            quote: text.substring(start, end),
            prefix: text.substring((start - 32).clamp(0, start), start),
            suffix: text.substring(end, (end + 32).clamp(end, text.length)),
          );
          results.add(
            SearchHit(
              kind: SearchHitKind.page,
              id: '${row['id']}:$start',
              documentId: row['document_id'] as String,
              revisionId: row['revision_id'] as String,
              epubLocator: locator,
              text: _snippet(text, start, needle.length),
              start: start,
              end: end,
            ),
          );
          start = text.toLowerCase().indexOf(needle, end);
        }
        if (results.length >= limit) break;
      }
    }
    if (results.length < limit) {
      for (final row in await _rows(
        '''SELECT o.*,d.id AS document_id FROM epub_image_ocr o
        JOIN revisions r ON r.id=o.revision_id JOIN documents d ON d.id=r.document_id
        WHERE d.project_id=? AND d.deleted_at IS NULL ${documentId == null ? '' : 'AND d.id=?'}
        AND instr(lower(o.text),?)>0 LIMIT ?''',
        [projectId, ?documentId, needle, limit - results.length],
      )) {
        final text = row['text'] as String,
            start = text.toLowerCase().indexOf(needle);
        results.add(
          SearchHit(
            kind: SearchHitKind.page,
            id: row['id'] as String,
            documentId: row['document_id'] as String,
            revisionId: row['revision_id'] as String,
            epubLocator: DocumentLocator.decode(
              row['locator_json'] as String,
            ) as EpubLocator,
            text: _snippet(text, start, needle.length),
            start: start,
            end: start + needle.length,
          ),
        );
      }
    }
    return results;
  });

  Future<PdfReadingSettings> loadPdfReadingSettings(String revisionId) =>
      _exclusive(() async {
        final rows = await _rows(
          'SELECT settings_json FROM reading_positions WHERE id=?',
          [revisionId],
        );
        if (rows.isEmpty) return const PdfReadingSettings();
        final settings = jsonDecode(rows.single['settings_json'] as String) as Map;
        return PdfReadingSettings.fromJson(
          Map<String, dynamic>.from(settings['pdf'] as Map? ?? const {}),
        );
      });

  Future<void> savePdfReadingSettings(
    String revisionId,
    PdfReadingSettings value, {
    required String sessionId,
  }) => _mutate(
    '保存 PDF 目录设置',
    (w) async {
      _checkSession(sessionId);
      final revision = await _require('revisions', revisionId);
      if (revision['format'] != 'pdf') _invalid('目录设置只适用于 PDF。');
      if (!value.sidebarWidth.isFinite ||
          value.sidebarWidth < 120 ||
          value.sidebarWidth > 440) {
        _invalid('PDF 目录宽度不合法。');
      }
      final rows = await _rows('SELECT * FROM reading_positions WHERE id=?', [
        revisionId,
      ]);
      final previous = rows.isEmpty ? null : rows.single;
      final settings = previous == null
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(
              jsonDecode(previous['settings_json'] as String) as Map,
            );
      settings['pdf'] = value.toJson();
      await w.put('reading_positions', {
        'id': revisionId,
        'page_index': previous?['page_index'] ?? 0,
        'offset': previous?['offset'] ?? 0.0,
        'settings_json': encodeJson(settings),
      });
    },
    recordUndo: false,
    invalidateRedo: false,
    notifyChanges: false,
  );

  Future<void> saveReadingPosition(
    String revisionId,
    int pageIndex,
    double offset,
  ) => _mutate(
    '保存阅读位置',
    (w) async {
      final revision = await _require('revisions', revisionId);
      _validatePage(revision, pageIndex);
      if (!offset.isFinite) _invalid('阅读位置不合法。');
      await w.put('reading_positions', {
        'id': revisionId,
        'page_index': pageIndex,
        'offset': offset,
      });
    },
    recordUndo: false,
    invalidateRedo: false,
    notifyChanges: false,
  );

  Future<ReadingPosition?> loadReadingPosition(
    String revisionId,
  ) => _exclusive(() async {
    final rows = await _rows('SELECT * FROM reading_positions WHERE id=?', [
      revisionId,
    ]);
    return rows.isEmpty
        ? null
        : ReadingPosition(
            revisionId: revisionId,
            pageIndex: rows.single['page_index'] as int? ?? 0,
            offset: (rows.single['offset'] as num).toDouble(),
            epubLocator: rows.single['locator_json'] == null
                ? null
                : DocumentLocator.decode(rows.single['locator_json'] as String)
                      as EpubLocator,
            settings: rows.single['locator_json'] == null
                ? const EpubReadingSettings()
                : EpubReadingSettings.fromJson(
                    Map<String, dynamic>.from(
                      jsonDecode(rows.single['settings_json'] as String) as Map,
                    ),
                  ),
          );
  });

  /// 自动索引可只补缺页任务；显式操作默认允许重试失败或取消页。
  Future<List<OcrTask>> enqueueOcr(
    String revisionId,
    Iterable<int> pages, {
    required String modelVersion,
    bool force = false,
    bool retryIncomplete = true,
  }) => _mutate(
    '加入 OCR 队列',
    (w) async {
      final revision = await _require('revisions', revisionId);
      final tasks = <OcrTask>[];
      for (final page in pages.toSet()) {
        _validatePage(revision, page);
        final existing = await _rows(
          'SELECT * FROM ocr_tasks WHERE revision_id=? AND page_index=? AND model_version=?',
          [revisionId, page, modelVersion],
        );
        _Row row;
        if (existing.isNotEmpty) {
          row = existing.single;
          if ((retryIncomplete &&
                  (row['status'] == 'failed' ||
                      row['status'] == 'cancelled')) ||
              (force && row['status'] == 'completed')) {
            row = {
              ...row,
              'status': 'queued',
              'session_id': null,
              'error': '',
              'updated_at': _now(),
            };
            await w.put('ocr_tasks', row);
          }
        } else {
          row = {
            'id': _id(),
            'revision_id': revisionId,
            'page_index': page,
            'model_version': _title(modelVersion),
            'status': 'queued',
            'error': '',
            'session_id': null,
            'updated_at': _now(),
          };
          await w.put('ocr_tasks', row);
        }
        tasks.add(_task(row));
      }
      return tasks;
    },
    recordUndo: false,
    invalidateRedo: false,
  );

  Future<Set<int>> reusableTextPages(
    String revisionId, {
    required String ocrEngineVersion,
  }) => _exclusive(() async {
    final rows = await _rows(
      "SELECT page_index FROM text_layers WHERE revision_id=? AND is_current=1 AND ((source='nativePdf' AND length(text)>0 AND fragments<>'[]') OR (source='ocr' AND engine_version=?))",
      [revisionId, ocrEngineVersion],
    );
    return rows.map((row) => row['page_index'] as int).toSet();
  });

  Future<List<OcrTask>> listOcrTasks({String? revisionId}) => _exclusive(
    () async => (await _rows(
      'SELECT * FROM ocr_tasks ${revisionId == null ? '' : 'WHERE revision_id=?'} ORDER BY updated_at,page_index',
      [?revisionId],
    )).map(_task).toList(),
  );

  Future<OcrTask> claimOcrTask(String taskId, {required String sessionId}) =>
      _mutate(
        '开始 OCR 页',
        (w) async {
          _checkSession(sessionId);
          final row = await _require('ocr_tasks', taskId);
          if (row['status'] != 'queued') {
            throw const RepositoryException(
              RepositoryError.conflict,
              '该 OCR 页已被处理或已取消。',
            );
          }
          final claimed = {
            ...row,
            'status': 'running',
            'session_id': sessionId,
            'error': '',
            'updated_at': _now(),
          };
          await w.put('ocr_tasks', claimed);
          return _task(claimed);
        },
        recordUndo: false,
        invalidateRedo: false,
      );

  Future<void> failOcrTask(
    String taskId,
    String error, {
    required String sessionId,
  }) => _mutate(
    '记录 OCR 失败',
    (w) async {
      _checkSession(sessionId);
      final row = await _require('ocr_tasks', taskId);
      if (row['session_id'] != sessionId || row['status'] != 'running') {
        throw const RepositoryException(
          RepositoryError.staleSession,
          'OCR 任务已失效。',
        );
      }
      await w.put('ocr_tasks', {
        ...row,
        'status': 'failed',
        'error': error,
        'updated_at': _now(),
      });
    },
    recordUndo: false,
    invalidateRedo: false,
  );

  Future<void> cancelOcr({String? revisionId}) => _mutate(
    '取消 OCR 队列',
    (w) async {
      for (final row in await _rows(
        "SELECT * FROM ocr_tasks WHERE status IN ('running','queued') ${revisionId == null ? '' : 'AND revision_id=?'}",
        [?revisionId],
      )) {
        await w.put('ocr_tasks', {
          ...row,
          'status': 'cancelled',
          'updated_at': _now(),
        });
      }
    },
    recordUndo: false,
    invalidateRedo: false,
  );

  void _checkSession(String expected) {
    if (expected != _sessionId) {
      throw const RepositoryException(
        RepositoryError.staleSession,
        '任务所属资料库会话已失效。',
      );
    }
  }

  Future<void> trashDocument(String documentId) =>
      _trashEntity(TrashKind.document, documentId);
  Future<void> trashMap(String mapId) => _trashEntity(TrashKind.map, mapId);
  Future<void> trashProject(String projectId) =>
      _trashEntity(TrashKind.project, projectId);
  Future<void> trashCard(String cardId) => _trashEntity(TrashKind.card, cardId);

  /// 脑图删除同步回收卡片；整批共用事务和一次撤销，不能嵌套独立回收命令。
  Future<Set<String>> trashMapTopics(
    String mapId,
    Iterable<String> nodeIds, {
    bool includeDescendants = true,
  }) {
    final ids = Set<String>.unmodifiable(nodeIds);
    return _mutate('脑图卡片移入回收站', (w) async {
      final selection = await _validatedBatchNodes(mapId, ids);
      if (selection.nodes.isEmpty) return <String>{};
      if (!includeDescendants && ids.length != 1) {
        _invalid('仅删除当前主题时请选择一个主题。');
      }
      final all = await _rows(
        'SELECT * FROM nodes WHERE map_id=? AND deleted_at IS NULL',
        [mapId],
      );
      final affected = <String, _Row>{};
      for (final node in selection.nodes) {
        final branch = includeDescendants
            ? await _summaryBranchRows(all, node['id'] as String)
            : [node];
        for (final item in branch) {
          affected[item['id'] as String] = item;
        }
      }
      // 隐藏后代及概要主题也必须在任何写入前全部校验。
      await _validatedBatchNodes(mapId, affected.keys.toSet());
      final current = selection.nodes.singleOrNull;
      final children = !includeDescendants
          ? (all.where((n) => n['parent_node_id'] == current!['id']).toList()
              ..sort(_compareTopicRows))
          : <_Row>[];
      final siblings = !includeDescendants
          ? (all
                .where((n) => n['parent_node_id'] == current!['parent_node_id'])
                .toList()
              ..sort(_compareTopicRows))
          : <_Row>[];
      final maps = <String>{mapId};
      // 后代先回收，保留被回收节点自身的原层级，供撤销和单卡恢复使用。
      final ordered = affected.values.toList();
      int depth(_Row node) {
        var parent = node['parent_node_id'];
        final seen = <Object?>{node['id']};
        var result = 0;
        while (affected.containsKey(parent)) {
          if (!seen.add(parent)) _invalid('脑图层级存在循环。');
          result++;
          parent = affected[parent]!['parent_node_id'];
        }
        return result;
      }

      ordered.sort((a, b) => depth(b).compareTo(depth(a)));
      for (final node in ordered) {
        maps.addAll(
          await _trashEntityRows(w, TrashKind.card, node['card_id'] as String),
        );
      }
      if (!includeDescendants) {
        for (final child in children) {
          final row = await _require(
            'nodes',
            child['id'] as String,
            active: true,
          );
          if (current!['branch_side'] != null) {
            await w.put('nodes', {
              ...row,
              'branch_side': current['branch_side'],
            });
          }
        }
        final map = await _require('maps', mapId, active: true);
        if (await _parentIsStructured(
          map,
          current!['parent_node_id'] as String?,
        )) {
          final expanded = [
            for (final sibling in siblings)
              if (sibling['id'] == current['id']) ...children else sibling,
          ];
          for (var index = 0; index < expanded.length; index++) {
            final row = await _require(
              'nodes',
              expanded[index]['id'] as String,
              active: true,
            );
            await w.put('nodes', {...row, 'sort_index': index});
          }
        }
      }
      await _relayoutActiveMaps(w, maps);
      return affected.values.map((n) => n['card_id'] as String).toSet();
    });
  }

  Future<void> _trashEntity(TrashKind kind, String id) =>
      _mutate('移入回收站', (w) async {
        final maps = await _trashEntityRows(w, kind, id);
        await _relayoutActiveMaps(w, maps);
      });

  Future<Set<String>> _trashEntityRows(
    _Writer w,
    TrashKind kind,
    String id,
  ) async {
    final affectedMaps = <String>{};
    final table = _trashTable(kind);
    final row = await _require(table, id, active: true);
    final stamp = _now();
    final payload = <String, Object?>{};
    if (kind == TrashKind.document || kind == TrashKind.project) {
      final tasks = await _rows(
        "SELECT t.* FROM ocr_tasks t JOIN revisions r ON r.id=t.revision_id JOIN documents d ON d.id=r.document_id WHERE t.status IN ('queued','running') AND ${kind == TrashKind.document ? 'd.id' : 'd.project_id'}=?",
        [id],
      );
      for (final task in tasks) {
        await w.put('ocr_tasks', {
          ...task,
          'status': 'cancelled',
          'updated_at': stamp,
        });
      }
    }
    if (kind == TrashKind.card) {
      final nodes = await _rows(
        'SELECT * FROM nodes WHERE card_id=? AND deleted_at IS NULL',
        [id],
      );
      final children = <Map<String, Object?>>[];
      for (final node in nodes) {
        final parentId = node['parent_node_id'];
        for (final child in await _rows(
          'SELECT * FROM nodes WHERE parent_node_id=? AND deleted_at IS NULL',
          [node['id']],
        )) {
          children.add({
            'id': child['id'],
            'before': node['id'],
            'after': parentId,
          });
          await w.put('nodes', {...child, 'parent_node_id': parentId});
        }
        await w.put('nodes', {...node, 'deleted_at': stamp});
      }
      payload['children'] = children;
      payload['nodeIds'] = nodes.map((n) => n['id']).toList();
      affectedMaps.addAll(nodes.map((n) => n['map_id'] as String));
    }
    await w.put(table, {...row, 'deleted_at': stamp});
    await w.put('trash', {
      'id': _id(),
      'kind': kind.name,
      'entity_id': id,
      'project_id': kind == TrashKind.project ? id : row['project_id'],
      'title': row['title'],
      'payload': encodeJson(payload),
      'deleted_at': stamp,
    });
    return affectedMaps;
  }

  Future<List<TrashEntry>> listTrash({String? projectId}) => _exclusive(
    () async =>
        (await _rows(
              'SELECT * FROM trash ${projectId == null ? '' : 'WHERE project_id=?'} ORDER BY deleted_at DESC',
              [?projectId],
            ))
            .map(
              (r) => TrashEntry(
                id: r['id'] as String,
                kind: TrashKind.values.byName(r['kind'] as String),
                entityId: r['entity_id'] as String,
                projectId: r['project_id'] as String,
                title: r['title'] as String,
                deletedAt: _date(r['deleted_at'])!,
              ),
            )
            .toList(),
  );

  Future<void> restoreTrash(String trashId) => _mutate('恢复回收站项目', (w) async {
    final trash = await _require('trash', trashId);
    final kind = TrashKind.values.byName(trash['kind'] as String);
    final table = _trashTable(kind);
    final row = await _require(table, trash['entity_id'] as String);
    if (kind != TrashKind.project) {
      await _require('projects', trash['project_id'] as String, active: true);
    }
    if (kind == TrashKind.map) {
      // 回收图中的卡片可能已放入其他图；恢复不能引入共享的有效节点。
      final conflicts = await _rows(
        '''SELECT c.title AS card_title, m.title AS map_title
           FROM nodes restoring
           JOIN cards c ON c.id=restoring.card_id
           JOIN nodes placed ON placed.card_id=restoring.card_id
           JOIN maps m ON m.id=placed.map_id
           WHERE restoring.map_id=? AND restoring.deleted_at IS NULL
             AND c.deleted_at IS NULL AND placed.deleted_at IS NULL
             AND placed.map_id<>restoring.map_id AND m.deleted_at IS NULL
           LIMIT 1''',
        [row['id']],
      );
      if (conflicts.isNotEmpty) {
        final conflict = conflicts.single;
        throw RepositoryException(
          RepositoryError.conflict,
          '无法恢复脑图：卡片“${conflict['card_title']}”已在脑图“${conflict['map_title']}”中。'
          '请先从该脑图移除卡片，再恢复。',
        );
      }
    }
    final cardPayload = kind == TrashKind.card
        ? jsonDecode(trash['payload'] as String) as Map
        : null;
    if (cardPayload != null) {
      final restoringNodeIds = (cardPayload['nodeIds'] as List? ?? const [])
          .cast<String>()
          .toSet();
      // 恢复卡片会同时复原全部历史位置，必须在任何写入前检查有效占用。
      final placements = await _rows(
        '''SELECT n.id, n.deleted_at, m.deleted_at AS map_deleted_at
           FROM nodes n JOIN maps m ON m.id=n.map_id WHERE n.card_id=?''',
        [row['id']],
      );
      final activeCount = placements
          .where(
            (node) =>
                node['map_deleted_at'] == null &&
                (node['deleted_at'] == null ||
                    restoringNodeIds.contains(node['id'])),
          )
          .length;
      if (activeCount > 1) {
        throw RepositoryException(
          RepositoryError.conflict,
          '无法恢复卡片“${row['title']}”：恢复后会出现多个有效脑图节点。'
          '请先将相关脑图移入回收站，或解除已有占用，再恢复。',
        );
      }
    }
    await w.put(table, {...row, 'deleted_at': null});
    if (kind == TrashKind.card) {
      final payload = cardPayload!;
      final affectedMaps = <String>{};
      for (final nodeId in payload['nodeIds'] as List? ?? const []) {
        final node = await _require('nodes', nodeId as String);
        affectedMaps.add(node['map_id'] as String);
        final parents = node['parent_node_id'] == null
            ? <_Row>[]
            : await _rows(
                'SELECT * FROM nodes WHERE id=? AND map_id=? AND deleted_at IS NULL',
                [node['parent_node_id'], node['map_id']],
              );
        final restoredParent = parents.isEmpty
            ? null
            : node['parent_node_id'] as String?;
        await w.put('nodes', {
          ...node,
          'deleted_at': null,
          'parent_node_id': await _wouldCycle(nodeId, restoredParent)
              ? null
              : restoredParent,
        });
      }
      for (final item in payload['children'] as List? ?? const []) {
        final child = item as Map;
        final rows = await _rows(
          'SELECT * FROM nodes WHERE id=? AND deleted_at IS NULL',
          [child['id']],
        );
        if (rows.isNotEmpty &&
            rows.single['parent_node_id'] == child['after']) {
          final parent = await _require('nodes', child['before'] as String);
          if (parent['map_id'] != rows.single['map_id'] ||
              await _wouldCycle(
                child['id'] as String,
                child['before'] as String,
              )) {
            continue;
          }
          await w.put('nodes', {
            ...rows.single,
            'parent_node_id': child['before'],
          });
          affectedMaps.add(rows.single['map_id'] as String);
        }
      }
      await _relayoutActiveMaps(w, affectedMaps);
    }
    await w.remove('trash', trashId);
  });

  Future<bool> _wouldCycle(String nodeId, String? parentId) async {
    final seen = <String>{};
    var cursor = parentId;
    while (cursor != null) {
      if (cursor == nodeId || !seen.add(cursor)) return true;
      final rows = await _rows('SELECT parent_node_id FROM nodes WHERE id=?', [
        cursor,
      ]);
      if (rows.isEmpty) return false;
      cursor = rows.single['parent_node_id'] as String?;
    }
    return false;
  }
}

String _trashTable(TrashKind kind) => switch (kind) {
  TrashKind.project => 'projects',
  TrashKind.document => 'documents',
  TrashKind.card => 'cards',
  TrashKind.map => 'maps',
};

String _snippet(String text, int start, int length) {
  final left = (start - 40).clamp(0, text.length);
  final right = (start + length + 80).clamp(0, text.length);
  return '${left > 0 ? '…' : ''}${text.substring(left, right)}${right < text.length ? '…' : ''}';
}
