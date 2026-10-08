part of 'open_note_repository.dart';

extension TopicDropCommands on OpenNoteRepository {
  /// 拖放的层级、同级顺序、展开与布局由同一 Writer 保存为一次撤销。
  Future<void> dropTopic(
    MapNode source,
    TopicDropTarget target, {
    double? x,
    double? y,
  }) => _mutate('拖放脑图主题', (w) async {
    final node = await _require('nodes', source.id, active: true);
    final anchor = await _require('nodes', target.anchor.id, active: true);
    final mapId = source.mapId;
    final map = await _require('maps', mapId, active: true);
    await _validatedBatchNodes(mapId, {source.id, target.anchor.id});
    if (node['card_id'] != source.cardId ||
        node['parent_node_id'] != source.parentNodeId ||
        node['x'] != source.x ||
        node['y'] != source.y ||
        anchor['map_id'] != mapId ||
        target.anchor.mapId != mapId ||
        anchor['card_id'] != target.anchor.cardId ||
        anchor['parent_node_id'] != target.anchor.parentNodeId ||
        node['branch_layout'] != source.branchLayout?.name ||
        anchor['branch_layout'] != target.anchor.branchLayout?.name) {
      _invalid('拖放目标已变更，请重试。');
    }
    final all = await _rows(
      'SELECT * FROM nodes WHERE map_id=? AND deleted_at IS NULL',
      [mapId],
    );
    final branch = await _summaryBranchRows(all, source.id);
    if (branch.any((r) => r['id'] == target.anchor.id)) {
      throw const RepositoryException(RepositoryError.cycle, '不能把分支放到自身或后代。');
    }
    final parentId = target.placement == TopicDropPlacement.child
        ? target.anchor.id
        : anchor['parent_node_id'] as String?;
    await _validateParent(mapId, parentId);
    var structured = await _parentIsStructured(map, parentId);
    if (!structured && target.placement != TopicDropPlacement.child) {
      _invalid('自由布局请直接移动主题。');
    }
    if (!structured) {
      // 自由布局挂接后只整理目标分支，鼠标落点不作为最终主题位置。
      await w.put('nodes', {
        ...anchor,
        'branch_layout': MapLayoutKind.right.name,
      });
      structured = true;
    }
    final siblings =
        all
            .where(
              (n) => n['parent_node_id'] == parentId && n['id'] != source.id,
            )
            .toList()
          ..sort(_compareTopicRows);
    var index = siblings.length;
    if (target.placement != TopicDropPlacement.child) {
      index = siblings.indexWhere((n) => n['id'] == target.anchor.id);
      if (index < 0) _invalid('同级插入目标已失效。');
      if (target.placement == TopicDropPlacement.after) index++;
    }
    final layouts = await _effectiveTopicLayouts(map, all);
    final side = target.placement == TopicDropPlacement.child
        ? (layouts[parentId] == MapLayoutKind.mindMap && x != null
              ? (x + source.width / 2 <
                        (anchor['x'] as num).toDouble() +
                            (anchor['width'] as num).toDouble() / 2
                    ? -1
                    : 1)
              : null)
        : anchor['branch_side'];
    final moved = {
      ...await _require('nodes', source.id, active: true),
      'parent_node_id': parentId,
      'branch_side': side,
    };
    siblings.insert(index, moved);
    for (var i = 0; i < siblings.length; i++) {
      await w.put('nodes', {
        ...siblings[i],
        'sort_index': structured ? i : null,
      });
    }
    await _expandTopicAncestors(w, parentId);
    await _relayoutMap(w, mapId);
  });
}
