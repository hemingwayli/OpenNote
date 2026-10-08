import 'models.dart';

/// 概要主题的格式仅存入概要对象，普通主题仅存入节点；避免两份持久格式竞争。
TopicStyle topicStyleFor(MapSnapshot snapshot, MapNode node) {
  return topicStylesFor(snapshot)[node.id]!;
}

Map<String, TopicStyle> topicStylesFor(MapSnapshot snapshot) {
  final byId = {for (final n in snapshot.nodes) n.id: n};
  final summaries = {for (final s in snapshot.summaries) s.summaryNodeId: s};
  final inherited = <String, BranchStyle?>{};
  BranchStyle? branchFor(String? id) {
    final pending = <String>[];
    final seen = <String>{};
    BranchStyle? result;
    while (id != null) {
      // 显示层对孤立环有限遍历，沿用本图默认；写入及备份仍校验无环层级。
      if (!seen.add(id)) break;
      if (inherited.containsKey(id)) {
        result = inherited[id];
        break;
      }
      final summary = summaries[id];
      if (summary != null) {
        result = summary.style.effectiveBranch;
        break;
      }
      pending.add(id);
      id = byId[id]?.parentNodeId;
    }
    for (final id in pending) {
      inherited[id] = result;
    }
    return result;
  }

  return {
    for (final node in snapshot.nodes)
      node.id: summaries.containsKey(node.id)
          ? TopicStyle(
              surface: summaries[node.id]!.style.topic,
              branch: summaries[node.id]!.style.effectiveBranch,
            )
          : node.style ??
                snapshot.map.defaultStyle.copyWith(
                  branch: branchFor(node.parentNodeId),
                ),
  };
}
