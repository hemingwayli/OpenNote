part of 'open_note_repository.dart';

extension BoundaryCommands on OpenNoteRepository {
  /// 不同分支分别创建外框，同一分支的首尾主题界定连续范围；整批只有一次撤销。
  Future<List<String>> createBoundaries(String mapId, Set<String> nodeIds) {
    final captured = Set<String>.unmodifiable(nodeIds);
    return _mutate('添加外框', (w) async {
      await _activeBoundaryMap(mapId);
      final nodes = await _boundaryNodes(mapId);
      final auxiliary = await _boundaryAuxiliaryRoots(mapId);
      final byId = {for (final node in nodes) node.id: node};
      if (captured.isEmpty || captured.any((id) => !byId.containsKey(id))) {
        _invalid('请先选择有效的主题。');
      }
      final groups = <String?, List<String>>{};
      for (final id in captured) {
        // 选中父主题时，包含的后代无需另建一层外框。
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
      if ((groups[null]?.length ?? 0) > 1) _invalid('多个自由主题不能放入同一个外框，请分别添加。');
      final result = <String>[];
      for (final group in groups.entries) {
        final id = _id();
        final boundary = MapBoundary(
          id: id,
          mapId: mapId,
          parentNodeId: group.key,
          nodeIds: group.value,
        );
        final range = boundaryRoots(
          boundary,
          nodes,
          auxiliaryRoots: auxiliary,
        ).map((n) => n.id).toList();
        await w.put('boundaries', {
          'id': id,
          'map_id': mapId,
          'parent_node_id': group.key,
          'node_ids': encodeJson(range),
          'label': '',
          'style_json': '{}',
        });
        result.add(id);
      }
      return result;
    });
  }

  Future<void> updateBoundary(
    String id, {
    String? label,
    BoundaryStyle? style,
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
    return _mutate('编辑外框', (w) async {
      final row = await _require('boundaries', id);
      final mapId = row['map_id'] as String;
      if (expectedMapId != null && mapId != expectedMapId) {
        _invalid('外框已移动，请重新选择。');
      }
      await _activeBoundaryMap(mapId);
      final current = _boundary(row);
      if (expected != null &&
          encodeJson(expected) != encodeJson(current.nodeIds)) {
        _invalid('外框范围已变更，请重新选择。');
      }
      final text = label ?? current.label;
      if (text.length > 1000) _invalid('外框说明最多 1000 字。');
      final nextStyle = style ?? current.style;
      nextStyle.validate();
      var roots = current.nodeIds;
      if (captured != null) {
        final nodes = await _boundaryNodes(mapId);
        final byId = {for (final n in nodes) n.id: n};
        if (captured.isEmpty ||
            captured.toSet().length != captured.length ||
            captured.any(
              (id) =>
                  byId[id] == null ||
                  byId[id]!.parentNodeId != current.parentNodeId,
            ) ||
            current.parentNodeId == null && captured.length > 1) {
          _invalid('外框范围必须是同一分支的主题。');
        }
        roots = boundaryRoots(
          MapBoundary(
            id: id,
            mapId: mapId,
            parentNodeId: current.parentNodeId,
            nodeIds: captured,
          ),
          nodes,
          auxiliaryRoots: await _boundaryAuxiliaryRoots(mapId),
        ).map((n) => n.id).toList();
      }
      if (text == current.label &&
          nextStyle == current.style &&
          encodeJson(roots) == encodeJson(current.nodeIds)) {
        return;
      }
      await w.put('boundaries', {
        ...row,
        'label': text,
        'style_json': encodeJson(nextStyle.toJson()),
        'node_ids': encodeJson(roots),
      });
    });
  }

  Future<void> removeBoundary(String id, {String? expectedMapId}) =>
      _mutate('删除外框', (w) async {
        final row = await _require('boundaries', id);
        if (expectedMapId != null && row['map_id'] != expectedMapId) {
          _invalid('外框已移动。');
        }
        await _activeBoundaryMap(row['map_id'] as String);
        await w.remove('boundaries', id);
      });

  Future<void> _activeBoundaryMap(String mapId) async {
    final map = await _require('maps', mapId, active: true);
    await _require('projects', map['project_id'] as String, active: true);
  }

  Future<List<MapNode>> _boundaryNodes(String mapId) async => (await _rows(
    'SELECT n.* FROM nodes n JOIN cards c ON c.id=n.card_id '
    'WHERE n.map_id=? AND n.deleted_at IS NULL AND c.deleted_at IS NULL',
    [mapId],
  )).map(_node).toList();

  Future<Set<String>> _boundaryAuxiliaryRoots(String mapId) async =>
      (await _rows('SELECT summary_node_id FROM summaries WHERE map_id=?', [
        mapId,
      ])).map((r) => r['summary_node_id'] as String).toSet();

  /// 仅层级／身份变化才维护范围，普通拖动不查询全库。维护和原命令共用 Writer。
  Future<bool> _normalizeChangedBoundaries(
    _Writer w,
    List<_RowChange> changes,
  ) async {
    final maps = <String>{};
    for (final entry in changes) {
      if (entry.table != 'nodes' || entry.before == null) continue;
      final after = entry.after;
      if (after != null &&
          after['map_id'] == entry.before!['map_id'] &&
          after['parent_node_id'] == entry.before!['parent_node_id']) {
        continue;
      }
      maps.add(entry.before!['map_id'] as String);
    }
    var changed = false;
    for (final mapId in maps) {
      final boundaries = await _rows(
        'SELECT * FROM boundaries WHERE map_id=?',
        [mapId],
      );
      if (boundaries.isEmpty) continue;
      final auxiliary = await _boundaryAuxiliaryRoots(mapId);
      final previous = {
        for (final row in await _rows('SELECT * FROM nodes WHERE map_id=?', [
          mapId,
        ]))
          row['id'] as String: row,
      };
      for (final entry in changes.where((c) => c.table == 'nodes')) {
        if (entry.before?['map_id'] == mapId) {
          previous[entry.id] = entry.before!;
        } else if (entry.after?['map_id'] == mapId) {
          previous.remove(entry.id);
        }
      }
      for (final row in boundaries) {
        final boundary = _boundary(row);
        final members = <_Row>[];
        final roots = boundaryRoots(
          boundary,
          previous.values.map(_node),
          auxiliaryRoots: auxiliary,
        );
        for (final id
            in roots.isEmpty ? boundary.nodeIds : roots.map((n) => n.id)) {
          members.addAll(await _rows('SELECT * FROM nodes WHERE id=?', [id]));
        }
        if (members.isEmpty) {
          await w.remove('boundaries', boundary.id);
          changed = true;
          continue;
        }
        final retained = members
            .where(
              (n) =>
                  n['map_id'] == boundary.mapId &&
                  n['parent_node_id'] == boundary.parentNodeId,
            )
            .toList();
        final chosen = retained.isNotEmpty ? retained : members;
        final targetMap = chosen.first['map_id'];
        final targetParent = chosen.first['parent_node_id'];
        var ids = chosen
            .where(
              (n) =>
                  n['map_id'] == targetMap &&
                  n['parent_node_id'] == targetParent,
            )
            .map((n) => n['id'] as String)
            .toList();
        if (targetParent == null && ids.length > 1) {
          for (final id in ids.skip(1)) {
            await w.put('boundaries', {
              ...row,
              'id': _id(),
              'map_id': targetMap,
              'parent_node_id': null,
              'node_ids': encodeJson([id]),
            });
          }
          ids = [ids.first];
        }
        await w.put('boundaries', {
          ...row,
          'map_id': targetMap,
          'parent_node_id': targetParent,
          'node_ids': encodeJson(ids),
        });
        changed = true;
      }
    }
    return changed;
  }

  Future<void> _copyBoundaries(
    _Writer w,
    Iterable<MapBoundary> boundaries,
    Map<String, String> nodeIds,
    String targetMapId,
    String? targetParent,
    Set<String> copiedRoots,
  ) async {
    for (final boundary in boundaries) {
      if (boundary.nodeIds.isEmpty ||
          !boundary.nodeIds.every(nodeIds.containsKey)) {
        continue;
      }
      final roots = boundary.nodeIds.map((id) => nodeIds[id]!).toList();
      final parent =
          nodeIds[boundary.parentNodeId] ??
          (boundary.nodeIds.every(copiedRoots.contains) ? targetParent : null);
      final ranges = parent == null
          ? [
              for (final id in roots) [id],
            ]
          : [roots];
      for (final range in ranges) {
        await w.put('boundaries', {
          'id': _id(),
          'map_id': targetMapId,
          'parent_node_id': parent,
          'node_ids': encodeJson(range),
          'label': boundary.label,
          'style_json': encodeJson(boundary.style.toJson()),
        });
      }
    }
  }
}

MapBoundary _boundary(_Row row) => MapBoundary(
  id: row['id'] as String,
  mapId: row['map_id'] as String,
  parentNodeId: row['parent_node_id'] as String?,
  nodeIds: List.unmodifiable(
    (jsonDecode(row['node_ids'] as String) as List).cast<String>(),
  ),
  label: row['label'] as String,
  style: BoundaryStyle.fromJson(
    Map<String, dynamic>.from(jsonDecode(row['style_json'] as String) as Map),
  ),
);
