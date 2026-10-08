part of 'open_note_repository.dart';

extension GraphCommands on OpenNoteRepository {
  Future<BranchCopyResult> copyBranch(
    String nodeId,
    String targetMapId, {
    String? parentNodeId,
    double offsetX = 48,
    double offsetY = 48,
  }) => _mutate('复制分支', (w) async {
    final sourceRoot = await _require('nodes', nodeId, active: true);
    final sourceMap = await _require(
      'maps',
      sourceRoot['map_id'] as String,
      active: true,
    );
    final targetMap = await _require('maps', targetMapId, active: true);
    final targetProject = targetMap['project_id'] as String;
    await _require('projects', targetProject, active: true);
    await _validateParent(targetMapId, parentNodeId);
    final sourceNodes = await _rows(
      'SELECT * FROM nodes WHERE map_id=? AND deleted_at IS NULL',
      [sourceMap['id']],
    );
    final branch = await _summaryBranchRows(sourceNodes, nodeId);
    final sourceStyles = await _effectiveTopicStyles(sourceMap, sourceNodes);
    final sourceSummaryTopics = await _boundaryAuxiliaryRoots(
      sourceMap['id'] as String,
    );
    final nodeIds = {for (final n in branch) n['id'] as String: _id()};
    final cardIds = <String, String>{};
    final sourceLayouts = await _effectiveTopicLayouts(sourceMap, sourceNodes);
    for (final n in branch) {
      final originalId = n['card_id'] as String;
      if (cardIds.containsKey(originalId)) continue;
      final card = await _require('cards', originalId, active: true);
      final copyId = _id();
      cardIds[originalId] = copyId;
      await w.put('cards', {
        ...card,
        'id': copyId,
        'project_id': targetProject,
        'updated_at': _now(),
        'deleted_at': null,
      });
    }
    final revisionIds = <String, String>{};
    final layerIds = <String, String>{};
    final documentIds = <String, String>{};
    final crossProject = sourceMap['project_id'] != targetProject;
    for (final originalCardId in cardIds.keys) {
      for (final anchor in await _rows(
        'SELECT * FROM anchors WHERE card_id=?',
        [originalCardId],
      )) {
        final revisionId = anchor['revision_id'] as String;
        if (crossProject && !revisionIds.containsKey(revisionId)) {
          final revision = await _require('revisions', revisionId);
          final docId = revision['document_id'] as String;
          if (!documentIds.containsKey(docId)) {
            await _copyDocument(
              w,
              docId,
              targetProject,
              documentIds,
              revisionIds,
              layerIds,
              cardIds,
            );
          }
        }
        await w.put('anchors', {
          ...anchor,
          'id': _id(),
          'card_id': cardIds[originalCardId],
          if (crossProject) 'revision_id': revisionIds[revisionId],
          if (crossProject && anchor['text_layer_id'] != null)
            'text_layer_id': layerIds[anchor['text_layer_id']],
        });
      }
    }
    for (final n in branch) {
      final originalParent = n['parent_node_id'] as String?;
      await w.put('nodes', {
        ...n,
        'id': nodeIds[n['id']],
        'map_id': targetMapId,
        'card_id': cardIds[n['card_id']],
        'parent_node_id': !nodeIds.containsKey(originalParent)
            ? parentNodeId
            : nodeIds[originalParent],
        'x': (n['x'] as num).toDouble() + offsetX,
        'y': (n['y'] as num).toDouble() + offsetY,
        'deleted_at': null,
        if (!nodeIds.containsKey(originalParent))
          'branch_layout': sourceLayouts[n['id']]!.name,
        'topic_style_json': sourceSummaryTopics.contains(n['id'])
            ? null
            : encodeJson(sourceStyles[n['id']]!.toJson()),
        'sort_index': targetMap['layout_kind'] == 'free'
            ? null
            : !nodeIds.containsKey(originalParent)
            ? await _nextTopicIndex(targetMapId, parentNodeId)
            : n['sort_index'],
      });
    }
    for (final edge in await _rows('SELECT * FROM edges WHERE map_id=?', [
      sourceMap['id'],
    ])) {
      final from = nodeIds[edge['from_node_id']];
      final to = nodeIds[edge['to_node_id']];
      if (from == null || to == null) continue;
      final pair = [from, to]..sort();
      final style = _edge(edge).style;
      await w.put('edges', {
        ...edge,
        'id': _id(),
        'map_id': targetMapId,
        'from_node_id': pair[0],
        'to_node_id': pair[1],
        'style_json': encodeJson(
          (from == pair[0] ? style : style.flipped()).toJson(),
        ),
      });
    }
    final sourceBoundaries = (await _rows(
      'SELECT * FROM boundaries WHERE map_id=?',
      [sourceMap['id']],
    )).map(_boundary);
    final sourceAuxiliary = await _boundaryAuxiliaryRoots(
      sourceMap['id'] as String,
    );
    await _copyBoundaries(
      w,
      [
        for (final boundary in sourceBoundaries)
          MapBoundary(
            id: boundary.id,
            mapId: boundary.mapId,
            parentNodeId: boundary.parentNodeId,
            nodeIds: boundaryRoots(
              boundary,
              sourceNodes.map(_node),
              auxiliaryRoots: sourceAuxiliary,
            ).map((n) => n.id).toList(),
            label: boundary.label,
            style: boundary.style,
          ),
      ],
      nodeIds,
      targetMapId,
      parentNodeId,
      {nodeId},
    );
    final sourceSummaries = (await _rows(
      'SELECT * FROM summaries WHERE map_id=?',
      [sourceMap['id']],
    )).map(_summary).toList();
    await _copySummaries(
      w,
      [
        for (final s in sourceSummaries)
          MapSummary(
            id: s.id,
            mapId: s.mapId,
            parentNodeId: s.parentNodeId,
            summaryNodeId: s.summaryNodeId,
            style: s.style,
            nodeIds: summaryRoots(
              s,
              sourceNodes.map(_node),
              sourceSummaries,
            ).map((n) => n.id).toList(),
          ),
      ],
      nodeIds,
      targetMapId,
    );
    await _expandTopicAncestors(w, parentNodeId);
    await _relayoutMap(w, targetMapId);
    return BranchCopyResult(
      rootNodeId: nodeIds[nodeId]!,
      cardIds: cardIds,
      nodeIds: nodeIds,
    );
  });

  Future<void> _copyDocument(
    _Writer w,
    String documentId,
    String targetProject,
    Map<String, String> documentIds,
    Map<String, String> revisionIds,
    Map<String, String> layerIds,
    Map<String, String> cardIds,
  ) async {
    final document = await _require('documents', documentId);
    final revisions = await _rows(
      'SELECT * FROM revisions WHERE document_id=?',
      [documentId],
    );
    final copyDocumentId = _id();
    documentIds[documentId] = copyDocumentId;
    for (final revision in revisions) {
      revisionIds[revision['id'] as String] = _id();
    }
    await w.put('documents', {
      ...document,
      'id': copyDocumentId,
      'project_id': targetProject,
      'active_revision_id': revisionIds[document['active_revision_id']],
      'deleted_at': null,
    });
    for (final revision in revisions) {
      final originalId = revision['id'] as String;
      final copyRevisionId = revisionIds[originalId]!;
      await w.put('revisions', {
        ...revision,
        'id': copyRevisionId,
        'document_id': copyDocumentId,
      });
      for (final layer in await _rows(
        'SELECT * FROM text_layers WHERE revision_id=?',
        [originalId],
      )) {
        final copyLayerId = _id();
        layerIds[layer['id'] as String] = copyLayerId;
        await w.put('text_layers', {
          ...layer,
          'id': copyLayerId,
          'revision_id': copyRevisionId,
        });
      }
      for (final table in ['epub_sections','epub_image_ocr']) {
        for (final row in await _rows('SELECT * FROM $table WHERE revision_id=?',[originalId])) {
          await w.put(table,{...row,'id':_id(),'revision_id':copyRevisionId});
        }
      }
      for (final annotation in await _rows(
        'SELECT * FROM annotations WHERE revision_id=?',
        [originalId],
      )) {
        await w.put('annotations', {
          ...annotation,
          'id': _id(),
          'revision_id': copyRevisionId,
          'card_id': cardIds[annotation['card_id']],
        });
      }
    }
  }

  Future<void> reparentNode(
    String nodeId,
    String? parentNodeId, {
    double? x,
    double? y,
  }) => _mutate('调整分支层级', (w) async {
    final node = await _require('nodes', nodeId, active: true);
    await _validateParent(node['map_id'] as String, parentNodeId);
    final all = await _rows(
      'SELECT * FROM nodes WHERE map_id=? AND deleted_at IS NULL',
      [node['map_id']],
    );
    if (parentNodeId != null) {
      if (_branchRows(all, nodeId).any((r) => r['id'] == parentNodeId)) {
        throw const RepositoryException(
          RepositoryError.cycle,
          '不能把分支挂到自身或其子节点。',
        );
      }
    }
    if (x != null || y != null) {
      await _translateBranch(
        w,
        node,
        x ?? (node['x'] as num).toDouble(),
        y ?? (node['y'] as num).toDouble(),
      );
    }
    final current = await _require('nodes', nodeId, active: true);
    final mapId = current['map_id'] as String;
    final map = await _require('maps', mapId, active: true);
    final parent = parentNodeId == null
        ? null
        : await _require('nodes', parentNodeId, active: true);
    await w.put('nodes', {
      ...current,
      'parent_node_id': parentNodeId,
      if (current['parent_node_id'] != parentNodeId)
        'sort_index': await _parentIsStructured(map, parentNodeId)
            ? await _nextTopicIndex(mapId, parentNodeId)
            : null,
      if (current['parent_node_id'] != parentNodeId) 'branch_side': null,
      if ((await _effectiveTopicLayouts(map, all))[parentNodeId] ==
              MapLayoutKind.mindMap &&
          parent != null &&
          x != null)
        'branch_side':
            x + (current['width'] as num) / 2 <
                (parent['x'] as num) + (parent['width'] as num) / 2
            ? -1
            : 1,
    });
    await _expandTopicAncestors(w, parentNodeId);
    await _relayoutMap(w, mapId);
  });

  Future<void> moveNode(String nodeId, double x, double y) =>
      _mutate('移动分支', (w) async {
        final node = await _require('nodes', nodeId, active: true);
        await _translateBranch(w, node, x, y);
      });

  /// 同项目移动保留身份；图外关联无法跨脑图存在，随这次命令移除。
  Future<void> moveBranchToMap(
    String nodeId,
    String targetMapId, {
    String? parentNodeId,
  }) => _mutate('移动分支到脑图', (w) async {
    final root = await _require('nodes', nodeId, active: true);
    final sourceMap = await _require(
      'maps',
      root['map_id'] as String,
      active: true,
    );
    final targetMap = await _require('maps', targetMapId, active: true);
    _sameProject(sourceMap['project_id'], targetMap['project_id'] as String);
    await _validateParent(targetMapId, parentNodeId);
    final all = await _rows(
      'SELECT * FROM nodes WHERE map_id=? AND deleted_at IS NULL',
      [sourceMap['id']],
    );
    final branch = await _summaryBranchRows(all, nodeId);
    final sourceStyles = sourceMap['id'] == targetMapId
        ? null
        : await _effectiveTopicStyles(sourceMap, all);
    final sourceSummaryTopics = sourceStyles == null
        ? const <String>{}
        : await _boundaryAuxiliaryRoots(sourceMap['id'] as String);
    final ids = branch.map((n) => n['id']).toSet();
    if (parentNodeId != null && ids.contains(parentNodeId)) {
      throw const RepositoryException(RepositoryError.cycle, '不能把分支挂到自身或其子节点。');
    }
    if (sourceMap['id'] != targetMapId) {
      for (final edge in await _rows('SELECT * FROM edges WHERE map_id=?', [
        sourceMap['id'],
      ])) {
        final fromInside = ids.contains(edge['from_node_id']);
        final toInside = ids.contains(edge['to_node_id']);
        if (fromInside && toInside) {
          await w.put('edges', {...edge, 'map_id': targetMapId});
        } else if (fromInside || toInside) {
          await w.remove('edges', edge['id'] as String);
        }
      }
      // 回收站中的节点仍持有父引用，不能随父分支迁移留下跨图引用。
      for (final node in await _rows('SELECT * FROM nodes WHERE map_id=?', [
        sourceMap['id'],
      ])) {
        if (!ids.contains(node['id']) && ids.contains(node['parent_node_id'])) {
          await w.put('nodes', {...node, 'parent_node_id': null});
        }
      }
    }
    final sourceLayouts = await _effectiveTopicLayouts(sourceMap, all);
    for (final node in branch) {
      await w.put('nodes', {
        ...node,
        'map_id': targetMapId,
        if (sourceStyles != null && !sourceSummaryTopics.contains(node['id']))
          'topic_style_json': encodeJson(sourceStyles[node['id']]!.toJson()),
        if (sourceMap['id'] != targetMapId &&
            !ids.contains(node['parent_node_id']))
          'branch_layout': sourceLayouts[node['id']]!.name,
        if (!ids.contains(node['parent_node_id']))
          'parent_node_id': parentNodeId,
        if (!ids.contains(node['parent_node_id']))
          'sort_index': targetMap['layout_kind'] == 'free'
              ? null
              : await _nextTopicIndex(targetMapId, parentNodeId),
        if (targetMap['layout_kind'] == 'free') 'sort_index': null,
      });
    }
    await _expandTopicAncestors(w, parentNodeId);
    await _relayoutMap(w, sourceMap['id'] as String);
    if (sourceMap['id'] != targetMapId) await _relayoutMap(w, targetMapId);
  });

  Future<void> layoutNodes(String mapId, Map<String, PdfPoint> positions) {
    final captured = Map<String, PdfPoint>.of(positions);
    return _mutate('整理脑图布局', (w) async {
      final selection = await _validatedBatchNodes(
        mapId,
        captured.keys.toSet(),
      );
      for (final position in captured.values) {
        if (!position.x.isFinite || !position.y.isFinite) {
          _invalid('脑图布局坐标不合法。');
        }
      }
      for (final node in selection.nodes) {
        final position = captured[node['id']]!;
        await w.put('nodes', {...node, 'x': position.x, 'y': position.y});
      }
    });
  }

  Future<void> _translateBranch(
    _Writer w,
    _Row root,
    double x,
    double y,
  ) async {
    if (!x.isFinite || !y.isFinite) _invalid('脑图位置必须是有限坐标。');
    final deltaX = x - (root['x'] as num).toDouble();
    final deltaY = y - (root['y'] as num).toDouble();
    final all = await _rows(
      'SELECT * FROM nodes WHERE map_id=? AND deleted_at IS NULL',
      [root['map_id']],
    );
    for (final node in await _summaryBranchRows(all, root['id'] as String)) {
      await w.put('nodes', {
        ...node,
        'x': (node['x'] as num).toDouble() + deltaX,
        'y': (node['y'] as num).toDouble() + deltaY,
      });
    }
  }

  Future<void> setNodeCollapsed(String nodeId, bool collapsed) =>
      _mutate('折叠分支', (w) async {
        final node = await _require('nodes', nodeId, active: true);
        if (node['collapsed'] == (collapsed ? 1 : 0)) return;
        await w.put('nodes', {...node, 'collapsed': collapsed ? 1 : 0});
        await _relayoutMap(w, node['map_id'] as String);
      });

  /// 按最新根节点状态切换整棵分支；隐藏后代也参与，一次布局和一次撤销。
  Future<void> toggleNodeBranchCollapsed(String nodeId) =>
      _mutate('切换所有次级分支', (w) async {
        final root = await _require('nodes', nodeId, active: true);
        final mapId = root['map_id'] as String;
        final all = await _rows(
          'SELECT * FROM nodes WHERE map_id=? AND deleted_at IS NULL',
          [mapId],
        );
        final parents = all.map((row) => row['parent_node_id']).toSet();
        if (!parents.contains(nodeId)) return;
        final collapsed = root['collapsed'] == 0;
        for (final node in _branchRows(all, nodeId)) {
          // 叶节点没有可收起的内容，保持其状态为展开。
          final next = collapsed && parents.contains(node['id']) ? 1 : 0;
          if (node['collapsed'] != next) {
            await w.put('nodes', {...node, 'collapsed': next});
          }
        }
        await _relayoutMap(w, mapId);
      });

  /// 精确处理所选节点，父节点被选中不抹去子节点自己的折叠状态。
  Future<void> setNodesCollapsed(
    String mapId,
    Iterable<String> nodeIds,
    bool collapsed,
  ) {
    final ids = nodeIds.toSet();
    return _mutate('批量折叠分支', (w) async {
      final selection = await _validatedBatchNodes(mapId, ids);
      var changed = false;
      for (final node in selection.nodes) {
        if (node['collapsed'] == (collapsed ? 1 : 0)) continue;
        changed = true;
        await w.put('nodes', {...node, 'collapsed': collapsed ? 1 : 0});
      }
      if (changed) await _relayoutMap(w, mapId);
    });
  }

  /// 只改变精确选中卡片的颜色，不按父子关系隐式扩展选择。
  Future<void> setCardsColor(
    String mapId,
    Iterable<String> nodeIds,
    String color,
  ) {
    final ids = nodeIds.toSet();
    return _mutate('批量修改卡片颜色', (w) async {
      final selection = await _validatedBatchNodes(mapId, ids);
      for (final card in selection.cards.values) {
        await _updateCardRow(w, card, color: color);
      }
    });
  }

  Future<({List<_Row> nodes, Map<String, _Row> cards})> _validatedBatchNodes(
    String mapId,
    Set<String> nodeIds,
  ) async {
    final map = await _require('maps', mapId, active: true);
    final projectId = map['project_id'] as String;
    await _require('projects', projectId, active: true);
    final nodes = <_Row>[];
    final cards = <String, _Row>{};
    for (final id in nodeIds) {
      final node = await _require('nodes', id, active: true);
      if (node['map_id'] != mapId) _invalid('批量操作包含其他脑图的节点。');
      final cardId = node['card_id'] as String;
      final card =
          cards[cardId] ?? await _require('cards', cardId, active: true);
      _sameProject(card['project_id'], projectId);
      nodes.add(node);
      cards[cardId] = card;
    }
    return (nodes: nodes, cards: cards);
  }

  Future<MapEdge> addAssociation(
    String firstNodeId,
    String secondNodeId,
  ) => _mutate('添加关联', (w) async {
    if (firstNodeId == secondNodeId) _invalid('关联不能指向同一节点。');
    final first = await _require('nodes', firstNodeId, active: true);
    final second = await _require('nodes', secondNodeId, active: true);
    if (first['map_id'] != second['map_id']) _invalid('关联的两端必须在同一脑图。');
    final map = await _require('maps', first['map_id'] as String, active: true);
    await _require('projects', map['project_id'] as String, active: true);
    await _require('cards', first['card_id'] as String, active: true);
    await _require('cards', second['card_id'] as String, active: true);
    final pair = [firstNodeId, secondNodeId]..sort();
    final existing = await _rows(
      'SELECT * FROM edges WHERE map_id=? AND from_node_id=? AND to_node_id=?',
      [first['map_id'], pair[0], pair[1]],
    );
    if (existing.isNotEmpty) return _edge(existing.single);
    final row = <String, Object?>{
      'id': _id(),
      'map_id': first['map_id'],
      'from_node_id': pair[0],
      'to_node_id': pair[1],
    };
    await w.put('edges', row);
    return _edge(row);
  });

  Future<void> removeAssociation(String edgeId) => _mutate('删除关联', (w) async {
    await _activeAssociation(edgeId, null, null);
    await w.remove('edges', edgeId);
  });

  /// 移除显示位置，不删除卡片。完整分支作为一次可撤销命令处理。
  Future<void> removeBranch(String nodeId) => _mutate('从脑图移除分支', (w) async {
    final root = await _require('nodes', nodeId, active: true);
    final all = await _rows(
      'SELECT * FROM nodes WHERE map_id=? AND deleted_at IS NULL',
      [root['map_id']],
    );
    final branch = await _summaryBranchRows(all, nodeId);
    await _removeBranchRows(w, root['map_id'] as String, branch);
  });

  /// 先验证完整选择，再排除已选祖先覆盖的根，隐藏后代仍属于分支。
  Future<void> removeBranches(String mapId, Iterable<String> nodeIds) {
    final ids = nodeIds.toSet();
    return _mutate('从脑图批量移除分支', (w) async {
      final selection = await _validatedBatchNodes(mapId, ids);
      if (selection.nodes.isEmpty) return;
      final all = await _rows(
        'SELECT * FROM nodes WHERE map_id=? AND deleted_at IS NULL',
        [mapId],
      );
      final byId = {for (final node in all) node['id'] as String: node};
      final roots = <String>[];
      for (final node in selection.nodes) {
        final id = node['id'] as String;
        final visited = <String>{id};
        var parentId = node['parent_node_id'] as String?;
        var covered = false;
        while (parentId != null) {
          if (!visited.add(parentId)) {
            throw const RepositoryException(
              RepositoryError.cycle,
              '脑图中存在循环，操作已取消。',
            );
          }
          if (ids.contains(parentId)) covered = true;
          parentId = byId[parentId]?['parent_node_id'] as String?;
        }
        if (!covered) roots.add(id);
      }
      final branch = <_Row>[];
      final included = <String>{};
      for (final rootId in roots) {
        for (final node in await _summaryBranchRows(all, rootId)) {
          if (included.add(node['id'] as String)) branch.add(node);
        }
      }
      await _removeBranchRows(w, mapId, branch);
    });
  }

  Future<void> _removeBranchRows(
    _Writer w,
    String mapId,
    List<_Row> branch,
  ) async {
    final ids = branch.map((n) => n['id']).toSet();
    for (final edge in await _rows('SELECT * FROM edges WHERE map_id=?', [
      mapId,
    ])) {
      if (ids.contains(edge['from_node_id']) ||
          ids.contains(edge['to_node_id'])) {
        await w.remove('edges', edge['id'] as String);
      }
    }
    for (final node in await _rows('SELECT * FROM nodes WHERE map_id=?', [
      mapId,
    ])) {
      if (!ids.contains(node['id']) && ids.contains(node['parent_node_id'])) {
        await w.put('nodes', {...node, 'parent_node_id': null});
      }
    }
    for (final node in branch.reversed) {
      await w.remove('nodes', node['id'] as String);
    }
    await _relayoutMap(w, mapId);
  }

  Future<MapNode> placeCard(
    String cardId,
    String mapId, {
    String? parentNodeId,
    double x = 0,
    double y = 0,
  }) => _mutate('放回脑图', (w) async {
    final card = await _require('cards', cardId, active: true);
    final map = await _require('maps', mapId, active: true);
    _sameProject(card['project_id'], map['project_id'] as String);
    await _validateParent(mapId, parentNodeId);
    final placed = await _rows(
      'SELECT n.id FROM nodes n JOIN maps m ON m.id=n.map_id WHERE n.card_id=? AND n.deleted_at IS NULL AND m.deleted_at IS NULL',
      [cardId],
    );
    if (placed.isNotEmpty) {
      throw const RepositoryException(
        RepositoryError.conflict,
        '卡片已在脑图中。要在另一位置放置独立副本，请使用复制。',
      );
    }
    final row = <String, Object?>{
      'id': _id(),
      'map_id': mapId,
      'card_id': cardId,
      'parent_node_id': parentNodeId,
      'x': x,
      'y': y,
      'width': 220.0,
      'height': 116.0,
      'collapsed': 0,
      'deleted_at': null,
      'sort_index': map['layout_kind'] == 'free'
          ? null
          : await _nextTopicIndex(mapId, parentNodeId),
      'branch_side': null,
    };
    await w.put('nodes', row);
    await _expandTopicAncestors(w, parentNodeId);
    await _relayoutMap(w, mapId);
    return _node(await _require('nodes', row['id'] as String, active: true));
  });

  Future<void> undo() => _exclusive(() async {
    if (_undo.isEmpty) return;
    final entry = _undo.last;
    await _applyHistory(entry, false);
    _undo.removeLast();
    _redo.add(entry);
    _notify();
  });

  Future<void> redo() => _exclusive(() async {
    if (_redo.isEmpty) return;
    final entry = _redo.last;
    await _applyHistory(entry, true);
    _redo.removeLast();
    _undo.add(entry);
    _notify();
  });

  Future<void> _applyHistory(_HistoryEntry entry, bool forward) async {
    await _database.transaction(() async {
      await _database.customStatement('PRAGMA defer_foreign_keys = ON');
      final changes = forward ? entry.changes : entry.changes.reversed;
      for (final change in changes) {
        final row = forward ? change.after : change.before;
        if (row == null) {
          await _database.customStatement(
            'DELETE FROM ${change.table} WHERE id=?',
            [change.id],
          );
        } else {
          // 引擎句柄不属于可撤销状态。恢复原来的运行中任务时重新排队。
          final restored =
              change.table == 'ocr_tasks' && row['status'] == 'running'
              ? <String, Object?>{
                  ...row,
                  'status': 'queued',
                  'session_id': null,
                }
              : row;
          await _putRow(_database, change.table, restored);
        }
      }
    });
  }
}

List<_Row> _branchRows(List<_Row> nodes, String rootId) {
  final byId = {for (final row in nodes) row['id'] as String: row};
  final children = <String, List<String>>{};
  for (final row in nodes) {
    final parent = row['parent_node_id'] as String?;
    if (parent != null) (children[parent] ??= []).add(row['id'] as String);
  }
  final result = <_Row>[];
  final queue = <String>[rootId];
  final visited = <String>{};
  for (var cursor = 0; cursor < queue.length; cursor++) {
    final id = queue[cursor];
    if (!visited.add(id)) {
      throw const RepositoryException(RepositoryError.cycle, '脑图中存在循环，操作已取消。');
    }
    final row = byId[id];
    if (row == null) _invalid('分支节点不存在。');
    result.add(row);
    queue.addAll(children[id] ?? const []);
  }
  return result;
}
