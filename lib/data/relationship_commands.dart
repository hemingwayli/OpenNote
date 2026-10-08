part of 'open_note_repository.dart';

extension RelationshipCommands on OpenNoteRepository {
  /// 空白处建立自由主题及其关联共用一次事务，失败不遗留孤立新主题。
  Future<ExcerptResult> createAssociatedTopic(
    String mapId,
    PdfPoint position, {
    String? fromNodeId,
  }) => _mutate('创建关联主题', (w) async {
    final map = await _require('maps', mapId, active: true);
    final projectId = map['project_id'] as String;
    await _require('projects', projectId, active: true);
    if (!position.x.isFinite ||
        !position.y.isFinite ||
        position.x.abs() > 1000000 ||
        position.y.abs() > 1000000) {
      _invalid('主题位置无效。');
    }
    if (fromNodeId != null) {
      final from = await _require('nodes', fromNodeId, active: true);
      await _require('cards', from['card_id'] as String, active: true);
      if (from['map_id'] != mapId) _invalid('关联的两端必须在同一脑图。');
    }
    final created = await _createExcerptRows(
      w,
      ExcerptDraft(
        projectId: projectId,
        mapId: mapId,
        title: '自由主题',
        text: '',
        x: position.x,
        y: position.y,
      ),
    );
    if (fromNodeId != null) {
      final pair = [fromNodeId, created.node.id]..sort();
      await w.put('edges', {
        'id': _id(),
        'map_id': mapId,
        'from_node_id': pair[0],
        'to_node_id': pair[1],
      });
    }
    await _relayoutMap(w, mapId);
    return ExcerptResult(
      card: created.card,
      node: _node(await _require('nodes', created.node.id, active: true)),
    );
  });

  Future<void> updateAssociation(
    String edgeId, {
    String? label,
    RelationshipStyle? style,
    String? expectedFromNodeId,
    String? expectedToNodeId,
  }) => _mutate('编辑关联线', (w) async {
    final row = await _activeAssociation(
      edgeId,
      expectedFromNodeId,
      expectedToNodeId,
    );
    final current = _edge(row);
    final nextLabel = label ?? current.label;
    if (nextLabel.length > 1000) _invalid('关联说明最多 1000 字。');
    final nextStyle = style ?? current.style;
    nextStyle.validate();
    if (nextLabel == current.label && nextStyle == current.style) return;
    await w.put('edges', {
      ...row,
      'label': nextLabel,
      'style_json': encodeJson(nextStyle.toJson()),
    });
  });

  /// 保留关联身份和说明；规范对调时交换端点、箭头与控制点。
  Future<void> reconnectAssociation(
    String edgeId,
    String endpointNodeId,
    String targetNodeId, {
    PdfPoint? anchor,
    String? expectedFromNodeId,
    String? expectedToNodeId,
  }) => _mutate('重连关联线', (w) async {
    final row = await _activeAssociation(
      edgeId,
      expectedFromNodeId,
      expectedToNodeId,
    );
    final edge = _edge(row);
    if (endpointNodeId != edge.fromNodeId && endpointNodeId != edge.toNodeId) {
      _invalid('关联端点已变更。');
    }
    final target = await _require('nodes', targetNodeId, active: true);
    await _require('cards', target['card_id'] as String, active: true);
    if (target['map_id'] != edge.mapId) _invalid('关联的两端必须在同一脑图。');
    final from = endpointNodeId == edge.fromNodeId
        ? targetNodeId
        : edge.fromNodeId;
    final to = endpointNodeId == edge.toNodeId ? targetNodeId : edge.toNodeId;
    if (from == to) _invalid('关联不能指向同一节点。');
    final pair = [from, to]..sort();
    final duplicates = await _rows(
      'SELECT id FROM edges WHERE map_id=? AND from_node_id=? AND to_node_id=? AND id<>?',
      [edge.mapId, pair[0], pair[1], edgeId],
    );
    if (duplicates.isNotEmpty) _invalid('这两个主题已经有关联线。');
    var style = endpointNodeId == edge.fromNodeId
        ? edge.style.copyWith(
            anchorFrom: anchor,
            clearFromAnchor: anchor == null,
          )
        : edge.style.copyWith(anchorTo: anchor, clearToAnchor: anchor == null);
    if (from != pair[0]) style = style.flipped();
    style.validate();
    if (pair[0] == edge.fromNodeId &&
        pair[1] == edge.toNodeId &&
        style == edge.style) {
      return;
    }
    await w.put('edges', {
      ...row,
      'from_node_id': pair[0],
      'to_node_id': pair[1],
      'style_json': encodeJson(style.toJson()),
    });
  });

  Future<_Row> _activeAssociation(
    String id,
    String? expectedFrom,
    String? expectedTo,
  ) async {
    final row = await _require('edges', id);
    if ((expectedFrom != null && row['from_node_id'] != expectedFrom) ||
        (expectedTo != null && row['to_node_id'] != expectedTo)) {
      _invalid('关联端点已变更，请重新选择。');
    }
    final map = await _require('maps', row['map_id'] as String, active: true);
    await _require('projects', map['project_id'] as String, active: true);
    for (final field in ['from_node_id', 'to_node_id']) {
      final node = await _require('nodes', row[field] as String, active: true);
      if (node['map_id'] != map['id']) _invalid('关联端点不属于当前脑图。');
      await _require('cards', node['card_id'] as String, active: true);
    }
    return row;
  }
}
