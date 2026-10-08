part of 'open_note_repository.dart';

extension TopicStyleCommands on OpenNoteRepository {
  Future<void> _releaseSummaryStyle(_Writer w, _Row row) async {
    final summary = _summary(row);
    final nodes = await _rows('SELECT * FROM nodes WHERE id=?', [
      summary.summaryNodeId,
    ]);
    if (nodes.isEmpty) return;
    await w.put('nodes', {
      ...nodes.single,
      'topic_style_json': encodeJson(
        TopicStyle(
          surface: summary.style.topic,
          branch: summary.style.effectiveBranch,
        ).toJson(),
      ),
    });
  }

  /// 调用时捕获精确选集；应用后代、概要与主题一起保存为一次撤销。
  Future<void> setTopicStyle(
    String mapId,
    Set<String> nodeIds,
    TopicStyle? style, {
    bool includeDescendants = false,
    bool makeDefault = false,
    Map<String, String>? expectedCardIds,
  }) {
    final captured = Set<String>.unmodifiable(nodeIds);
    final expected = expectedCardIds == null
        ? null
        : Map<String, String>.unmodifiable(expectedCardIds);
    return _mutate('修改主题格式', (w) async {
      style?.validate();
      final selection = await _validatedBatchNodes(mapId, captured);
      final map = await _require('maps', mapId, active: true);
      final ids = Set<String>.of(captured);
      if (includeDescendants) {
        final all = await _rows(
          'SELECT * FROM nodes WHERE map_id=? AND deleted_at IS NULL',
          [mapId],
        );
        for (final id in captured) {
          ids.addAll(
            (await _summaryBranchRows(all, id)).map((r) => r['id'] as String),
          );
        }
      }
      final targets = includeDescendants
          ? await _validatedBatchNodes(mapId, ids)
          : selection;
      if (expected != null &&
          selection.nodes.any(
            (node) => expected[node['id']] != node['card_id'],
          )) {
        _invalid('所选主题内容已变更，请重新选择。');
      }
      final summaryRows = await _rows(
        'SELECT * FROM summaries WHERE map_id=?',
        [mapId],
      );
      final byTopic = {
        for (final row in summaryRows) row['summary_node_id']: row,
      };
      for (final node in targets.nodes) {
        final summaryRow = byTopic[node['id']];
        if (summaryRow != null) {
          final current = _summary(summaryRow).style;
          final next = style == null
              ? current.copyWith(
                  topic: _map(map).defaultStyle.surface,
                  branch: _map(map).defaultStyle.branch,
                )
              : current.copyWith(topic: style.surface, branch: style.branch);
          if (current != next) {
            await w.put('summaries', {
              ...summaryRow,
              'style_json': encodeJson(next.toJson()),
            });
          }
        } else {
          final current = _node(node).style;
          if (current == style) continue;
          await w.put('nodes', {
            ...node,
            'topic_style_json': style == null
                ? null
                : encodeJson(style.toJson()),
          });
        }
      }
      if (makeDefault) {
        final next = style ?? _map(map).defaultStyle;
        if (_map(map).defaultStyle != next) {
          await w.put('maps', {
            ...map,
            'default_style_json': encodeJson(next.toJson()),
          });
        }
      }
    });
  }

  Future<Map<String, TopicStyle>> _effectiveTopicStyles(
    _Row map,
    List<_Row> nodes,
  ) async {
    final summaries = (await _rows('SELECT * FROM summaries WHERE map_id=?', [
      map['id'],
    ])).map(_summary).toList();
    final snapshot = MapSnapshot(
      map: _map(map),
      nodes: nodes.map(_node).toList(),
      cards: const {},
      anchors: const {},
      edges: const [],
      summaries: summaries,
    );
    return topicStylesFor(snapshot);
  }
}
