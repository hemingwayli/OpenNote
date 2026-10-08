part of 'open_note_repository.dart';

extension SummaryCommands on OpenNoteRepository {
  Future<List<_Row>> _summaryBranchRows(List<_Row> nodes, String rootId) async {
    final result = _branchRows(nodes, rootId);
    final included = result.map((n) => n['id'] as String).toSet();
    final mapId = result.first['map_id'];
    final summaries = (await _rows('SELECT * FROM summaries WHERE map_id=?', [
      mapId,
    ])).map(_summary).toList();
    final byId = {for (final n in nodes) n['id']: n};
    var added = true;
    while (added) {
      added = false;
      for (final s in summaries) {
        final roots = summaryRoots(s, nodes.map(_node), summaries);
        if (included.contains(s.summaryNodeId) ||
            !byId.containsKey(s.summaryNodeId) ||
            roots.isEmpty ||
            !roots.every((n) => included.contains(n.id))) {
          continue;
        }
        for (final n in _branchRows(nodes, s.summaryNodeId)) {
          if (included.add(n['id'] as String)) result.add(n);
        }
        added = true;
      }
    }
    return result;
  }

  Future<List<String>> createSummaries(String mapId, Set<String> nodeIds) {
    final captured = Set<String>.unmodifiable(nodeIds);
    return _mutate('添加概要', (w) async {
      await _activeBoundaryMap(mapId);
      final nodes = await _boundaryNodes(mapId);
      final summaries = (await _rows('SELECT * FROM summaries WHERE map_id=?', [
        mapId,
      ])).map(_summary).toList();
      final auxiliary = summaries.map((s) => s.summaryNodeId).toSet();
      final byId = {for (final n in nodes) n.id: n};
      if (captured.isEmpty ||
          captured.any(
            (id) => !byId.containsKey(id) || auxiliary.contains(id),
          )) {
        _invalid('请选择普通主题添加概要。');
      }
      final groups = <String?, List<String>>{};
      for (final id in captured) {
        var parent = byId[id]!.parentNodeId;
        final seen = <String>{id};
        var covered = false;
        while (parent != null) {
          if (!seen.add(parent)) _invalid('脑图层级存在循环。');
          if (captured.contains(parent)) {
            covered = true;
            break;
          }
          parent = byId[parent]?.parentNodeId;
        }
        if (!covered) (groups[byId[id]!.parentNodeId] ??= []).add(id);
      }
      if ((groups[null]?.length ?? 0) > 1) _invalid('多个自由主题请分别添加概要。');
      final map = await _require('maps', mapId, active: true);
      final result = <String>[];
      for (final group in groups.entries) {
        final id = _id();
        final draft = MapSummary(
          id: id,
          mapId: mapId,
          summaryNodeId: '',
          parentNodeId: group.key,
          nodeIds: group.value,
        );
        final roots = summaryRoots(draft, nodes, summaries);
        final topic = await _createExcerptRows(
          w,
          ExcerptDraft(
            projectId: map['project_id'] as String,
            mapId: mapId,
            title: '概要',
            text: '',
            parentNodeId: group.key,
            x: roots.first.x + roots.first.width + 72,
            y: roots.first.y,
          ),
        );
        await w.put('summaries', {
          'id': id,
          'map_id': mapId,
          'parent_node_id': group.key,
          'summary_node_id': topic.node.id,
          'node_ids': encodeJson(roots.map((n) => n.id).toList()),
          'style_json': '{}',
        });
        await _expandTopicAncestors(w, group.key);
        result.add(topic.node.id);
      }
      await _positionSummaries(w, mapId);
      return result;
    });
  }

  Future<void> updateSummary(
    String id, {
    SummaryStyle? style,
    List<String>? nodeIds,
    String? expectedMapId,
    List<String>? expectedNodeIds,
  }) {
    final captured = nodeIds == null
        ? null
        : List<String>.unmodifiable(nodeIds);
    final expected = expectedNodeIds == null
        ? null
        : List<String>.unmodifiable(expectedNodeIds);
    return _mutate('编辑概要范围和样式', (w) async {
      final row = await _require('summaries', id), current = _summary(row);
      if (expectedMapId != null && expectedMapId != current.mapId ||
          expected != null &&
              encodeJson(expected) != encodeJson(current.nodeIds)) {
        _invalid('概要范围已变更，请重新选择。');
      }
      await _activeBoundaryMap(current.mapId);
      await _require('nodes', current.summaryNodeId, active: true);
      final nextStyle = style ?? current.style;
      nextStyle.validate();
      var roots = current.nodeIds;
      if (captured != null) {
        final nodes = await _boundaryNodes(current.mapId);
        final all = (await _rows('SELECT * FROM summaries WHERE map_id=?', [
          current.mapId,
        ])).map(_summary).toList();
        final auxiliary = all.map((s) => s.summaryNodeId).toSet();
        final byId = {for (final n in nodes) n.id: n};
        if (captured.isEmpty ||
            captured.toSet().length != captured.length ||
            captured.any(
              (id) =>
                  byId[id]?.parentNodeId != current.parentNodeId ||
                  !byId.containsKey(id) ||
                  auxiliary.contains(id),
            )) {
          _invalid('概要范围必须是同一分支的普通主题。');
        }
        roots = summaryRoots(
          MapSummary(
            id: id,
            mapId: current.mapId,
            summaryNodeId: current.summaryNodeId,
            parentNodeId: current.parentNodeId,
            nodeIds: captured,
          ),
          nodes,
          all,
        ).map((n) => n.id).toList();
      }
      if (nextStyle == current.style &&
          encodeJson(roots) == encodeJson(current.nodeIds)) {
        return;
      }
      await w.put('summaries', {
        ...row,
        'node_ids': encodeJson(roots),
        'style_json': encodeJson(nextStyle.toJson()),
      });
      if (captured != null) await _positionSummaries(w, current.mapId);
    });
  }

  /// 去除括号后保留概要主题及子主题，作为普通主题继续编辑。
  Future<void> removeSummary(String id, {String? expectedMapId}) =>
      _mutate('移除概要范围', (w) async {
        final row = await _require('summaries', id);
        if (expectedMapId != null && row['map_id'] != expectedMapId) {
          _invalid('概要已移动。');
        }
        await _activeBoundaryMap(row['map_id'] as String);
        await _releaseSummaryStyle(w, row);
        await w.remove('summaries', id);
        await _relayoutMap(w, row['map_id'] as String);
      });

  Future<void> _positionSummaries(_Writer w, String mapId) async {
    final map = await _require('maps', mapId, active: true);
    if (map['layout_kind'] != 'free') {
      await _relayoutMap(w, mapId);
      return;
    }
    final nodes = await _boundaryNodes(mapId);
    final plan = calculateMapLayout(
      nodes,
      MapLayoutKind.free,
      summaries: (await _rows('SELECT * FROM summaries WHERE map_id=?', [
        mapId,
      ])).map(_summary).toList(),
    );
    for (final entry in plan.positions.entries) {
      final row = await _require('nodes', entry.key, active: true);
      await w.put('nodes', {...row, 'x': entry.value.x, 'y': entry.value.y});
    }
  }

  /// 节点移图／重挂或永久移除时同步范围，保持同一事务及一次撤销。
  Future<bool> _normalizeChangedSummaries(
    _Writer w,
    List<_RowChange> changes,
  ) async {
    final maps = <String>{};
    for (final c in changes) {
      if (c.table != 'nodes' || c.before == null) continue;
      if (c.after != null &&
          c.after!['map_id'] == c.before!['map_id'] &&
          c.after!['parent_node_id'] == c.before!['parent_node_id']) {
        continue;
      }
      maps.add(c.before!['map_id'] as String);
    }
    var changed = false;
    for (final mapId in maps) {
      final rows = await _rows('SELECT * FROM summaries WHERE map_id=?', [
        mapId,
      ]);
      if (rows.isEmpty) continue;
      final summaries = rows.map(_summary).toList();
      final before = {
        for (final n in await _rows('SELECT * FROM nodes WHERE map_id=?', [
          mapId,
        ]))
          n['id'] as String: n,
      };
      for (final c in changes.where((c) => c.table == 'nodes')) {
        if (c.before?['map_id'] == mapId) {
          before[c.id] = c.before!;
        } else if (c.after?['map_id'] == mapId) {
          before.remove(c.id);
        }
      }
      for (final row in rows) {
        final s = _summary(row);
        final topicRows = await _rows('SELECT * FROM nodes WHERE id=?', [
          s.summaryNodeId,
        ]);
        if (topicRows.isEmpty) {
          await w.remove('summaries', s.id);
          changed = true;
          continue;
        }
        final topic = topicRows.single;
        final scope = summaryRoots(
          s,
          before.values.map(_node),
          summaries,
        ).map((n) => n.id).toList();
        final retained = <String>[];
        for (final id in scope.isEmpty ? s.nodeIds : scope) {
          final members = await _rows('SELECT * FROM nodes WHERE id=?', [id]);
          if (members.isNotEmpty &&
              members.single['map_id'] == topic['map_id'] &&
              members.single['parent_node_id'] == topic['parent_node_id']) {
            retained.add(id);
          }
        }
        if (retained.isEmpty) {
          await _releaseSummaryStyle(w, row);
          await w.remove('summaries', s.id);
        } else {
          await w.put('summaries', {
            ...row,
            'map_id': topic['map_id'],
            'parent_node_id': topic['parent_node_id'],
            'node_ids': encodeJson(retained),
          });
        }
        changed = true;
      }
    }
    if (changed) {
      final currentMaps = {
        for (final c in changes.where((c) => c.table == 'nodes'))
          if (c.after != null) c.after!['map_id'] as String,
        ...maps,
      };
      await _relayoutActiveMaps(w, currentMaps);
    }
    return changed;
  }

  Future<void> _copySummaries(
    _Writer w,
    Iterable<MapSummary> summaries,
    Map<String, String> nodeIds,
    String targetMapId,
  ) async {
    for (final s in summaries) {
      if (!nodeIds.containsKey(s.summaryNodeId) ||
          !s.nodeIds.every(nodeIds.containsKey)) {
        continue;
      }
      final topic = await _require('nodes', nodeIds[s.summaryNodeId]!);
      final roots = s.nodeIds.map((id) => nodeIds[id]!).toList();
      await w.put('summaries', {
        'id': _id(),
        'map_id': targetMapId,
        'parent_node_id': topic['parent_node_id'],
        'summary_node_id': nodeIds[s.summaryNodeId],
        'node_ids': encodeJson(roots),
        'style_json': encodeJson(s.style.toJson()),
      });
    }
  }
}

MapSummary _summary(_Row row) => MapSummary(
  id: row['id'] as String,
  mapId: row['map_id'] as String,
  summaryNodeId: row['summary_node_id'] as String,
  parentNodeId: row['parent_node_id'] as String?,
  nodeIds: List.unmodifiable(
    (jsonDecode(row['node_ids'] as String) as List).cast<String>(),
  ),
  style: SummaryStyle.fromJson(
    Map<String, dynamic>.from(jsonDecode(row['style_json'] as String) as Map),
  ),
);
