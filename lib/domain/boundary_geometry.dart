import 'models.dart';

/// 以范围首尾锚点覆盖连续同级主题，新插入的中间主题自动纳入范围。
List<MapNode> boundaryRoots(
  MapBoundary boundary,
  Iterable<MapNode> nodes, {
  Set<String> auxiliaryRoots = const {},
}) {
  final siblings =
      nodes
          .where(
            (n) =>
                n.mapId == boundary.mapId &&
                (!auxiliaryRoots.contains(n.id) ||
                    boundary.nodeIds.contains(n.id)) &&
                n.parentNodeId == boundary.parentNodeId,
          )
          .toList()
        ..sort(compareMapNodes);
  final selected = [
    for (var i = 0; i < siblings.length; i++)
      if (boundary.nodeIds.contains(siblings[i].id)) i,
  ];
  if (selected.isEmpty) return [];
  return siblings.sublist(selected.first, selected.last + 1);
}

/// 后代参与外框尺寸；折叠的内容与被父主题隐藏的范围不参与绘制。
Set<String> boundaryMembers(
  MapBoundary boundary,
  Iterable<MapNode> nodes,
  Set<String> shown, {
  Set<String> auxiliaryRoots = const {},
}) {
  final all = nodes.toList();
  final children = <String, List<MapNode>>{};
  for (final node in all) {
    if (node.parentNodeId != null) {
      (children[node.parentNodeId!] ??= []).add(node);
    }
  }
  final pending = boundaryRoots(
    boundary,
    all,
    auxiliaryRoots: auxiliaryRoots,
  ).where((n) => shown.contains(n.id)).toList();
  final result = <String>{};
  while (pending.isNotEmpty) {
    final node = pending.removeLast();
    if (!shown.contains(node.id) || !result.add(node.id)) continue;
    if (!node.collapsed) pending.addAll(children[node.id] ?? []);
  }
  return result;
}
