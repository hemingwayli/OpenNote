part of 'open_note_repository.dart';

extension MapLayoutCommands on OpenNoteRepository {
  Future<Map<String, MapLayoutKind>> _effectiveTopicLayouts(
    _Row map,
    List<_Row> nodes,
  ) async => effectiveBranchLayouts(
    nodes.map(_node).toList(),
    _map(map).layout,
    summaries: (await _rows('SELECT * FROM summaries WHERE map_id=?', [
      map['id'],
    ])).map(_summary).toList(),
  );
  Future<bool> _parentIsStructured(_Row map, String? parentId) async {
    if (parentId == null) return map['layout_kind'] != 'free';
    final ancestors = await _rows(
      '''WITH RECURSIVE chain(id,parent_node_id,branch_layout) AS (
        SELECT id,parent_node_id,branch_layout FROM nodes WHERE id=? AND map_id=?
        UNION SELECT n.id,n.parent_node_id,n.branch_layout FROM nodes n JOIN chain c
          ON n.id=c.parent_node_id)
        SELECT * FROM chain''',
      [parentId, map['id']],
    );
    final byId = {for (final row in ancestors) row['id']: row};
    final seen = <String>{};
    String? id = parentId;
    while (id != null && byId.containsKey(id)) {
      if (!seen.add(id)) {
        throw const RepositoryException(RepositoryError.cycle, '脑图层级存在循环。');
      }
      final row = byId[id]!;
      if (row['branch_layout'] != null) return row['branch_layout'] != 'free';
      id = row['parent_node_id'] as String?;
    }
    return map['layout_kind'] != 'free';
  }

  /// 只覆盖所选主题的结构；显式重置后代时才清除内层已指定的结构。
  Future<void> setBranchLayout(
    String mapId,
    Set<String> nodeIds,
    MapLayoutKind? kind, {
    bool resetDescendantOverrides = false,
    Map<String, String>? expectedCardIds,
  }) {
    final ids = Set<String>.unmodifiable(nodeIds);
    final expected = expectedCardIds == null
        ? null
        : Map<String, String>.unmodifiable(expectedCardIds);
    return _mutate('修改分支结构', (w) async {
      if (ids.isEmpty) _invalid('请先选择主题。');
      final batch = await _validatedBatchNodes(mapId, ids);
      if (expected != null &&
          batch.nodes.any((n) => expected[n['id']] != n['card_id'])) {
        _invalid('所选主题已变更，请重新选择。');
      }
      final all = await _rows(
        'SELECT * FROM nodes WHERE map_id=? AND deleted_at IS NULL',
        [mapId],
      );
      final descendants = <String>{};
      if (resetDescendantOverrides) {
        for (final id in ids) {
          descendants.addAll(
            (await _summaryBranchRows(all, id)).map((n) => n['id'] as String),
          );
        }
        await _validatedBatchNodes(mapId, descendants);
      }
      var changed = false;
      for (final row in all) {
        if (!ids.contains(row['id']) && !descendants.contains(row['id'])) {
          continue;
        }
        final value = ids.contains(row['id']) ? kind?.name : null;
        if (row['branch_layout'] != value) {
          await w.put('nodes', {...row, 'branch_layout': value});
          changed = true;
        }
      }
      if (changed) await _relayoutMap(w, mapId, normalizeFree: true);
    });
  }

  Future<int> _nextTopicIndex(String mapId, String? parentId) async =>
      (await _rows(
            'SELECT COALESCE(MAX(sort_index),-1)+1 AS next FROM nodes WHERE map_id=? AND parent_node_id IS ? AND deleted_at IS NULL',
            [mapId, parentId],
          )).single['next']
          as int;
  Future<void> setMapLayout(String mapId, MapLayoutKind kind) =>
      _mutate('更改脑图结构', (w) async {
        final map = await _require('maps', mapId, active: true);
        await _require('projects', map['project_id'] as String, active: true);
        await w.put('maps', {...map, 'layout_kind': kind.name});
        await _relayoutMap(w, mapId, normalizeFree: true);
      });

  Future<void> organizeMap(String mapId) => _mutate('整理脑图布局', (w) async {
    final map = await _require('maps', mapId, active: true);
    await _require('projects', map['project_id'] as String, active: true);
    if (map['layout_kind'] == 'free') {
      await w.put('maps', {...map, 'layout_kind': 'right'});
    }
    await _relayoutMap(w, mapId);
  });

  Future<void> setBranchSide(String nodeId, int side) =>
      _mutate('调整分支左右方向', (w) async {
        if (side != -1 && side != 1) _invalid('分支方向无效。');
        var node = await _require('nodes', nodeId, active: true);
        final mapId = node['map_id'] as String;
        final map = await _require('maps', mapId, active: true);
        final all = await _rows(
          'SELECT * FROM nodes WHERE map_id=? AND deleted_at IS NULL',
          [mapId],
        );
        final layouts = await _effectiveTopicLayouts(map, all);
        final byId = {for (final row in all) row['id'] as String: row};
        var parentId = node['parent_node_id'] as String?;
        if (parentId == null) _invalid('中心主题不能设置左右方向。');
        final seen = <String>{nodeId};
        while (parentId != null) {
          if (!seen.add(parentId)) {
            throw const RepositoryException(RepositoryError.cycle, '脑图层级存在循环。');
          }
          final parent = byId[parentId];
          if (parent == null) _invalid('上级主题已变更。');
          if (layouts[parentId] == MapLayoutKind.mindMap) break;
          node = parent;
          parentId = parent['parent_node_id'] as String?;
        }
        if (parentId == null) _invalid('左右分支仅用于双侧脑图。');
        await w.put('nodes', {...node, 'branch_side': side});
        await _relayoutMap(w, mapId);
      });

  /// 层级从中心主题的 0 层开始；隐藏后代也统一设置，重新展开时状态可预测。
  Future<void> setMapVisibleDepth(String mapId, int? depth) =>
      _mutate('调整脑图展开层级', (w) async {
        if (depth != null && depth < 0) {
          _invalid('展开层级无效。');
        }
        final map = await _require('maps', mapId, active: true);
        await _require('projects', map['project_id'] as String, active: true);
        final rows = await _rows(
          'SELECT * FROM nodes WHERE map_id=? AND deleted_at IS NULL',
          [mapId],
        );
        final byId = {for (final row in rows) row['id'] as String: row};
        final children = <String, List<_Row>>{};
        for (final row in rows) {
          final parent = row['parent_node_id'] as String?;
          if (parent != null && byId.containsKey(parent)) {
            (children[parent] ??= []).add(row);
          }
        }
        final pending = <(_Row, int)>[
          for (final row in rows)
            if (!byId.containsKey(row['parent_node_id'])) (row, 0),
        ];
        final seen = <String>{};
        while (pending.isNotEmpty) {
          final (node, level) = pending.removeLast();
          final id = node['id'] as String;
          if (!seen.add(id)) {
            throw const RepositoryException(RepositoryError.cycle, '脑图层级存在循环。');
          }
          final descendants = children[id] ?? const <_Row>[];
          final collapsed =
              descendants.isNotEmpty && depth != null && level >= depth;
          if (node['collapsed'] != (collapsed ? 1 : 0)) {
            await w.put('nodes', {...node, 'collapsed': collapsed ? 1 : 0});
          }
          for (final child in descendants) {
            pending.add((child, level + 1));
          }
        }
        if (seen.length != rows.length) {
          throw const RepositoryException(RepositoryError.cycle, '脑图层级存在循环。');
        }
        await _relayoutMap(w, mapId);
      });

  Future<void> _relayoutMap(
    _Writer w,
    String mapId, {
    bool normalizeFree = false,
  }) async {
    final map = await _require('maps', mapId, active: true);
    await _require('projects', map['project_id'] as String, active: true);
    final kind = MapLayoutKind.values.byName(
      map['layout_kind'] as String? ?? 'free',
    );
    var rows = await _rows(
      'SELECT * FROM nodes WHERE map_id=? AND deleted_at IS NULL',
      [mapId],
    );
    if (kind == MapLayoutKind.free &&
        !normalizeFree &&
        rows.every((r) => r['branch_layout'] == null)) {
      return;
    }
    final layouts = await _effectiveTopicLayouts(map, rows);
    final groups = <String?, List<_Row>>{};
    for (final row in rows) {
      (groups[row['parent_node_id'] as String?] ??= []).add(row);
    }
    for (final group in groups.entries) {
      final siblings = group.value;
      siblings.sort(_compareTopicRows);
      final structured = (layouts[group.key] ?? kind) != MapLayoutKind.free;
      for (var index = 0; index < siblings.length; index++) {
        final row = siblings[index];
        final next = structured ? index : null;
        if (row['sort_index'] != next) {
          await w.put('nodes', {...row, 'sort_index': next});
        }
      }
    }
    rows = await _rows(
      'SELECT * FROM nodes WHERE map_id=? AND deleted_at IS NULL',
      [mapId],
    );
    final plan = calculateMapLayout(
      rows.map(_node).toList(),
      kind,
      summaries: (await _rows('SELECT * FROM summaries WHERE map_id=?', [
        mapId,
      ])).map(_summary).toList(),
    );
    for (final row in rows) {
      final point = plan.positions[row['id']];
      final side = plan.branchSides[row['id']];
      if (point == null && side == null) continue;
      await w.put('nodes', {
        ...row,
        if (point != null) 'x': point.x,
        if (point != null) 'y': point.y,
        'branch_side': ?side,
      });
    }
  }

  Future<void> _relayoutActiveMaps(_Writer w, Iterable<String> mapIds) async {
    for (final id in mapIds.toSet()) {
      final rows = await _rows(
        'SELECT m.id FROM maps m JOIN projects p ON p.id=m.project_id WHERE m.id=? AND m.deleted_at IS NULL AND p.deleted_at IS NULL',
        [id],
      );
      if (rows.isNotEmpty) {
        await _relayoutMap(w, id);
      }
    }
  }
}
