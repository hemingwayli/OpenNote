part of 'open_note_repository.dart';

extension TopicCommands on OpenNoteRepository {
  Future<List<MapNode>> pasteTopicOutline(
    String mapId,
    List<TopicTextLine> lines, {
    String? parentNodeId,
  }) => _mutate('粘贴主题大纲', (w) async {
    final map = await _require('maps', mapId, active: true);
    await _validateParent(mapId, parentNodeId);
    if (lines.isEmpty || lines.length > 2000) _invalid('粘贴的主题数量无效。');
    final placement = await _pastePosition(mapId, parentNodeId);
    final parents = <int, String>{};
    final roots = <MapNode>[];
    var previousDepth = 0;
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.depth < 0 || line.depth > (i == 0 ? 0 : previousDepth + 1)) {
        _invalid('大纲缩进不连续。');
      }
      final parent = line.depth == 0 ? parentNodeId : parents[line.depth - 1];
      if (line.depth > 0 && parent == null) _invalid('大纲缺少父主题。');
      final created = await _createExcerptRows(
        w,
        ExcerptDraft(
          projectId: map['project_id'] as String,
          mapId: mapId,
          title: line.title,
          text: '',
          parentNodeId: parent,
          x: placement.x + line.depth * 290,
          y: placement.y + i * 140,
          createHighlight: false,
        ),
      );
      parents[line.depth] = created.node.id;
      previousDepth = line.depth;
      if (line.depth == 0) roots.add(created.node);
    }
    await _relayoutMap(w, mapId);
    return [
      for (final root in roots)
        _node(await _require('nodes', root.id, active: true)),
    ];
  });

  Future<List<MapNode>> pasteTopicCopy(
    MapClipboardContent content,
    String mapId, {
    String? parentNodeId,
  }) => _mutate('粘贴独立主题分支', (w) async {
    final source = content.snapshot;
    final map = await _require('maps', mapId, active: true);
    final projectId = map['project_id'] as String;
    await _require('projects', projectId, active: true);
    await _validateParent(mapId, parentNodeId);
    final placement = await _pastePosition(mapId, parentNodeId);
    final minX = source.nodes.map((n) => n.x).reduce((a, b) => a < b ? a : b);
    final minY = source.nodes.map((n) => n.y).reduce((a, b) => a < b ? a : b);
    final cardIds = {for (final card in source.cards.values) card.id: _id()};
    final nodeIds = {for (final node in source.nodes) node.id: _id()};
    for (final card in source.cards.values) {
      if (card.imageResourceId != null) {
        await _require('resources', card.imageResourceId!);
      }
      await w.put('cards', {
        'id': cardIds[card.id],
        'project_id': projectId,
        'title': _title(card.title),
        'excerpt_snapshot': card.excerptSnapshot,
        'body': card.body,
        'note': card.note,
        'thoughts_json': encodePersonalThoughts([
          for (final thought in card.thoughts)
            PersonalThought(id: _id(), text: thought.text),
        ]),
        'color': card.color,
        'image_resource_id': card.imageResourceId,
        'updated_at': _now(),
        'deleted_at': null,
      });
    }
    final crossProject = source.map.projectId != projectId;
    final documents = <String, String>{};
    final revisions = <String, String>{};
    final layers = <String, String>{};
    for (final anchors in source.anchors.values) {
      for (final anchor in anchors) {
        if (crossProject && !revisions.containsKey(anchor.revisionId)) {
          final revision = await _require('revisions', anchor.revisionId);
          await _copyDocument(
            w,
            revision['document_id'] as String,
            projectId,
            documents,
            revisions,
            layers,
            cardIds,
          );
        }
        final draft = AnchorDraft(
          revisionId: crossProject
              ? revisions[anchor.revisionId]!
              : anchor.revisionId,
          pageIndex: anchor.pageIndex,
          quads: anchor.quads,
          textLayerId: crossProject
              ? layers[anchor.textLayerId]
              : anchor.textLayerId,
          textStart: anchor.textStart,
          textEnd: anchor.textEnd,
          context: anchor.context,
          epubLocator: anchor.epubLocator,
        );
        await _validateAnchor(draft, projectId);
        await w.put('anchors', _anchorRow(draft, cardIds[anchor.cardId]!));
      }
    }
    final roots = <MapNode>[];
    for (final node in source.nodes) {
      final isRoot = content.rootIds.contains(node.id);
      final row = <String, Object?>{
        'id': nodeIds[node.id],
        'map_id': mapId,
        'card_id': cardIds[node.cardId],
        'parent_node_id': isRoot ? parentNodeId : nodeIds[node.parentNodeId],
        'x': node.x + placement.x - minX,
        'y': node.y + placement.y - minY,
        'width': node.width,
        'height': node.height,
        'collapsed': node.collapsed ? 1 : 0,
        'deleted_at': null,
        'sort_index': map['layout_kind'] == 'free'
            ? null
            : isRoot
            ? await _nextTopicIndex(mapId, parentNodeId)
            : node.sortIndex,
        'branch_side': node.branchSide,
        'topic_style_json': node.style == null
            ? null
            : encodeJson(node.style!.toJson()),
        'branch_layout': node.branchLayout?.name,
      };
      await w.put('nodes', row);
      if (isRoot) roots.add(_node(row));
    }
    for (final edge in source.edges) {
      final pair = [nodeIds[edge.fromNodeId]!, nodeIds[edge.toNodeId]!]..sort();
      await w.put('edges', {
        'id': _id(),
        'map_id': mapId,
        'from_node_id': pair[0],
        'to_node_id': pair[1],
        'label': edge.label,
        'style_json': encodeJson(
          (nodeIds[edge.fromNodeId] == pair[0]
                  ? edge.style
                  : edge.style.flipped())
              .toJson(),
        ),
      });
    }
    await _copyBoundaries(
      w,
      source.boundaries,
      nodeIds,
      mapId,
      parentNodeId,
      content.rootIds.toSet(),
    );
    await _copySummaries(w, source.summaries, nodeIds, mapId);
    await _expandTopicAncestors(w, parentNodeId);
    await _relayoutMap(w, mapId);
    return [
      for (final root in roots)
        _node(await _require('nodes', root.id, active: true)),
    ];
  });

  /// 剪切先保留原分支，粘贴成功才移动；失败不会删除原数据或留下半份副本。
  Future<List<MapNode>> pasteTopicMove(
    MapClipboardContent content,
    String mapId, {
    String? parentNodeId,
  }) => _mutate('剪切并移动主题分支', (w) async {
    final source = content.snapshot;
    final sourceMap = await _require('maps', source.map.id, active: true);
    final targetMap = await _require('maps', mapId, active: true);
    _sameProject(sourceMap['project_id'], targetMap['project_id'] as String);
    await _validateParent(mapId, parentNodeId);
    final ids = source.nodes.map((n) => n.id).toSet();
    if (ids.contains(parentNodeId)) {
      throw const RepositoryException(
        RepositoryError.cycle,
        '不能把剪切分支粘贴到自身或其后代。',
      );
    }
    final all = await _rows(
      'SELECT * FROM nodes WHERE map_id=? AND deleted_at IS NULL',
      [source.map.id],
    );
    final actual = <String>{};
    final sourceStyles = source.map.id == mapId
        ? null
        : await _effectiveTopicStyles(sourceMap, all);
    final summaryTopics = sourceStyles == null
        ? const <String>{}
        : await _boundaryAuxiliaryRoots(source.map.id);
    for (final root in content.rootIds) {
      actual.addAll(
        (await _summaryBranchRows(all, root)).map((r) => r['id'] as String),
      );
    }
    if (actual.length != ids.length || !actual.containsAll(ids)) {
      _invalid('剪切分支的结构已变更，请重新剪切。');
    }
    final byId = {for (final row in all) row['id'] as String: row};
    for (final node in source.nodes) {
      if (byId[node.id]?['card_id'] != node.cardId ||
          byId[node.id]?['parent_node_id'] != node.parentNodeId) {
        _invalid('剪切分支的结构已变更，请重新剪切。');
      }
    }
    final placement = await _pastePosition(
      mapId,
      parentNodeId,
      excludeIds: ids,
    );
    final minX = source.nodes
        .map((n) => (byId[n.id]!['x'] as num).toDouble())
        .reduce((a, b) => a < b ? a : b);
    final minY = source.nodes
        .map((n) => (byId[n.id]!['y'] as num).toDouble())
        .reduce((a, b) => a < b ? a : b);
    if (source.map.id != mapId) {
      for (final edge in await _rows('SELECT * FROM edges WHERE map_id=?', [
        source.map.id,
      ])) {
        final from = ids.contains(edge['from_node_id']);
        final to = ids.contains(edge['to_node_id']);
        if (from && to) {
          await w.put('edges', {...edge, 'map_id': mapId});
        } else if (from || to) {
          await w.remove('edges', edge['id'] as String);
        }
      }
      for (final row in await _rows('SELECT * FROM nodes WHERE map_id=?', [
        source.map.id,
      ])) {
        if (!ids.contains(row['id']) && ids.contains(row['parent_node_id'])) {
          await w.put('nodes', {...row, 'parent_node_id': null});
        }
      }
    }
    final roots = <MapNode>[];
    final sourceLayouts = await _effectiveTopicLayouts(sourceMap, all);
    for (final id in ids) {
      final node = byId[id]!;
      final isRoot = content.rootIds.contains(id);
      final row = <String, Object?>{
        ...node,
        'map_id': mapId,
        if (sourceStyles != null && !summaryTopics.contains(id))
          'topic_style_json': encodeJson(sourceStyles[id]!.toJson()),
        if (isRoot) 'parent_node_id': parentNodeId,
        if (isRoot && source.map.id != mapId)
          'branch_layout': sourceLayouts[id]!.name,
        if (isRoot &&
            (source.map.id != mapId || node['parent_node_id'] != parentNodeId))
          'sort_index': targetMap['layout_kind'] == 'free'
              ? null
              : await _nextTopicIndex(mapId, parentNodeId),
        if (targetMap['layout_kind'] == 'free') 'sort_index': null,
        'x': (node['x'] as num).toDouble() + placement.x - minX,
        'y': (node['y'] as num).toDouble() + placement.y - minY,
      };
      await w.put('nodes', row);
      if (isRoot) roots.add(_node(row));
    }
    await _expandTopicAncestors(w, parentNodeId);
    await _relayoutMap(w, source.map.id);
    if (source.map.id != mapId) await _relayoutMap(w, mapId);
    return [
      for (final root in roots)
        _node(await _require('nodes', root.id, active: true)),
    ];
  });

  Future<PdfPoint> _pastePosition(
    String mapId,
    String? parentId, {
    Set<String> excludeIds = const {},
  }) async {
    final all = await _rows(
      'SELECT * FROM nodes WHERE map_id=? AND deleted_at IS NULL',
      [mapId],
    );
    final parent = parentId == null
        ? null
        : await _require('nodes', parentId, active: true);
    final branches = <_Row>[];
    for (final node in all.where(
      (r) => r['parent_node_id'] == parentId && !excludeIds.contains(r['id']),
    )) {
      branches.addAll(
        _branchRows(
          all,
          node['id'] as String,
        ).where((r) => !excludeIds.contains(r['id'])),
      );
    }
    return PdfPoint(
      parent == null
          ? 80
          : (parent['x'] as num).toDouble() +
                (parent['width'] as num).toDouble() +
                70,
      branches.isEmpty
          ? parent == null
                ? 80
                : (parent['y'] as num).toDouble()
          : _branchBottom(branches) + 24,
    );
  }

  Future<void> _expandTopicAncestors(_Writer w, String? parentId) async {
    while (parentId != null) {
      final node = await _require('nodes', parentId, active: true);
      if (node['collapsed'] == 1) {
        await w.put('nodes', {...node, 'collapsed': 0});
      }
      parentId = node['parent_node_id'] as String?;
    }
  }

  /// 插入和为新主题让出空间共用一个事务；折叠的后代仍跟随分支移动。
  Future<ExcerptResult> insertTopic(
    String nodeId,
    TopicInsertKind kind, {
    String title = '新主题',
  }) => _mutate('插入脑图主题', (w) async {
    final target = await _require('nodes', nodeId, active: true);
    final mapId = target['map_id'] as String;
    final map = await _require('maps', mapId, active: true);
    final structured = await _parentIsStructured(
      map,
      kind == TopicInsertKind.child
          ? nodeId
          : target['parent_node_id'] as String?,
    );
    final all = await _rows(
      'SELECT * FROM nodes WHERE map_id=? AND deleted_at IS NULL',
      [mapId],
    );
    final parentId = target['parent_node_id'] as String?;
    var x = (target['x'] as num).toDouble();
    var y = (target['y'] as num).toDouble();
    String? newParentId;
    int? insertIndex;
    if (kind == TopicInsertKind.child) {
      newParentId = nodeId;
      x += (target['width'] as num).toDouble() + 70;
      final descendants = _branchRows(all, nodeId).skip(1).toList();
      if (descendants.isNotEmpty) y = _branchBottom(descendants) + 24;
    } else if (kind == TopicInsertKind.parent) {
      newParentId = parentId;
      insertIndex = target['sort_index'] as int?;
      if (!structured) {
        await _offsetTopicRows(w, _branchRows(all, nodeId), 290, 0);
      }
    } else {
      newParentId = parentId;
      final siblings =
          all.where((row) => row['parent_node_id'] == parentId).toList()
            ..sort(_compareTopicRows);
      final index = siblings.indexWhere((row) => row['id'] == nodeId);
      final before = kind == TopicInsertKind.siblingBefore;
      insertIndex = index + (before ? 0 : 1);
      if (!before) y = _branchBottom(_branchRows(all, nodeId)) + 24;
      final following = siblings.skip(index + (before ? 0 : 1)).toList();
      if (structured) {
        for (final sibling in following) {
          await w.put('nodes', {
            ...sibling,
            'sort_index':
                (sibling['sort_index'] as int? ?? siblings.indexOf(sibling)) +
                1,
          });
        }
      } else if (following.isNotEmpty) {
        final firstY = (following.first['y'] as num).toDouble();
        final shift = y + 140 - firstY;
        if (shift > 0) {
          for (final sibling in following) {
            await _offsetTopicRows(
              w,
              _branchRows(all, sibling['id'] as String),
              0,
              shift,
            );
          }
        }
      }
    }
    final result = await _createExcerptRows(
      w,
      ExcerptDraft(
        projectId: map['project_id'] as String,
        mapId: mapId,
        title: title,
        text: '',
        parentNodeId: newParentId,
        x: x,
        y: y,
        createHighlight: false,
      ),
    );
    if (structured && insertIndex != null) {
      final inserted = await _require('nodes', result.node.id, active: true);
      await w.put('nodes', {
        ...inserted,
        'sort_index': insertIndex,
        if (kind != TopicInsertKind.child) 'branch_side': target['branch_side'],
      });
    }
    if (kind == TopicInsertKind.parent) {
      final current = await _require('nodes', nodeId, active: true);
      await w.put('nodes', {
        ...current,
        'parent_node_id': result.node.id,
        if (structured) 'sort_index': 0,
        if (structured) 'branch_side': null,
      });
    }
    await _relayoutMap(w, mapId);
    return ExcerptResult(
      card: result.card,
      node: _node(await _require('nodes', result.node.id, active: true)),
    );
  });

  /// 删除一个放置点，子分支提升一层；卡片、后代身份和它们的关联继续保留。
  Future<void> removeTopicOnly(String nodeId) => _mutate('仅移除当前主题', (w) async {
    final node = await _require('nodes', nodeId, active: true);
    final mapId = node['map_id'] as String;
    final map = await _require('maps', mapId, active: true);
    final activeRows = await _rows(
      'SELECT * FROM nodes WHERE map_id=? AND deleted_at IS NULL',
      [mapId],
    );
    final children =
        activeRows.where((row) => row['parent_node_id'] == nodeId).toList()
          ..sort(_compareTopicRows);
    final siblings =
        activeRows
            .where((row) => row['parent_node_id'] == node['parent_node_id'])
            .toList()
          ..sort(_compareTopicRows);
    for (final child in await _rows(
      'SELECT * FROM nodes WHERE parent_node_id=?',
      [nodeId],
    )) {
      await w.put('nodes', {
        ...child,
        'parent_node_id': node['parent_node_id'],
        if (node['branch_side'] != null) 'branch_side': node['branch_side'],
      });
    }
    for (final edge in await _rows('SELECT * FROM edges WHERE map_id=?', [
      mapId,
    ])) {
      if (edge['from_node_id'] == nodeId || edge['to_node_id'] == nodeId) {
        await w.remove('edges', edge['id'] as String);
      }
    }
    await w.remove('nodes', nodeId);
    if (await _parentIsStructured(map, node['parent_node_id'] as String?)) {
      final expanded = [
        for (final sibling in siblings)
          if (sibling['id'] == nodeId) ...children else sibling,
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
    await _relayoutMap(w, mapId);
  });

  /// 调整同级阅读顺序，按整条分支让位，不重建任何卡片或关系。
  Future<void> reorderTopic(String nodeId, {required bool before}) =>
      _mutate('调整同级主题顺序', (w) async {
        final node = await _require('nodes', nodeId, active: true);
        final all = await _rows(
          'SELECT * FROM nodes WHERE map_id=? AND deleted_at IS NULL',
          [node['map_id']],
        );
        final siblings =
            all
                .where((row) => row['parent_node_id'] == node['parent_node_id'])
                .toList()
              ..sort(_compareTopicRows);
        final index = siblings.indexWhere((row) => row['id'] == nodeId);
        final otherIndex = index + (before ? -1 : 1);
        if (otherIndex < 0 || otherIndex >= siblings.length) return;
        final map = await _require(
          'maps',
          node['map_id'] as String,
          active: true,
        );
        if (await _parentIsStructured(map, node['parent_node_id'] as String?)) {
          final other = siblings[otherIndex];
          await w.put('nodes', {...node, 'sort_index': other['sort_index']});
          await w.put('nodes', {...other, 'sort_index': node['sort_index']});
          await _relayoutMap(w, node['map_id'] as String);
          return;
        }
        final first = _branchRows(
          all,
          siblings[before ? otherIndex : index]['id'] as String,
        );
        final second = _branchRows(
          all,
          siblings[before ? index : otherIndex]['id'] as String,
        );
        final top = _branchTop(first);
        final gap = (_branchTop(second) - _branchBottom(first)).clamp(
          24.0,
          double.infinity,
        );
        await _offsetTopicRows(w, second, 0, top - _branchTop(second));
        await _offsetTopicRows(
          w,
          first,
          0,
          top +
              _branchBottom(second) -
              _branchTop(second) +
              gap -
              _branchTop(first),
        );
      });

  Future<void> _offsetTopicRows(
    _Writer w,
    List<_Row> rows,
    double dx,
    double dy,
  ) async {
    for (final row in rows) {
      await w.put('nodes', {
        ...row,
        'x': (row['x'] as num).toDouble() + dx,
        'y': (row['y'] as num).toDouble() + dy,
      });
    }
  }
}

int _compareTopicRows(_Row a, _Row b) {
  if ((a['sort_index'] == null) != (b['sort_index'] == null)) {
    return a['sort_index'] == null ? 1 : -1;
  }
  if (a['sort_index'] != null && b['sort_index'] != null) {
    final order = (a['sort_index'] as int).compareTo(b['sort_index'] as int);
    if (order != 0) return order;
  }
  final y = (a['y'] as num).compareTo(b['y'] as num);
  if (y != 0) return y;
  final x = (a['x'] as num).compareTo(b['x'] as num);
  return x != 0 ? x : (a['id'] as String).compareTo(b['id'] as String);
}

double _branchTop(List<_Row> rows) =>
    rows.map((r) => (r['y'] as num).toDouble()).reduce((a, b) => a < b ? a : b);

double _branchBottom(List<_Row> rows) => rows
    .map((r) => (r['y'] as num).toDouble() + (r['height'] as num).toDouble())
    .reduce((a, b) => a > b ? a : b);
