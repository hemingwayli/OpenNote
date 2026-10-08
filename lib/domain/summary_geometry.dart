import 'models.dart';
import 'boundary_geometry.dart';
import 'branch_structure.dart';

List<MapNode> summaryRoots(
  MapSummary summary,
  Iterable<MapNode> nodes,
  Iterable<MapSummary> summaries,
) {
  final auxiliary = summaries.map((s) => s.summaryNodeId).toSet();
  if (summary.parentNodeId == null) {
    return nodes
        .where(
          (n) =>
              n.mapId == summary.mapId &&
              n.parentNodeId == null &&
              summary.nodeIds.contains(n.id) &&
              !auxiliary.contains(n.id),
        )
        .toList()
      ..sort(compareMapNodes);
  }
  return boundaryRoots(
    MapBoundary(
      id: summary.id,
      mapId: summary.mapId,
      parentNodeId: summary.parentNodeId,
      nodeIds: summary.nodeIds,
    ),
    nodes.where((n) => !auxiliary.contains(n.id)),
  );
}

Set<String> summaryMembers(
  MapSummary summary,
  Iterable<MapNode> nodes,
  Iterable<MapSummary> summaries,
  Set<String> shown,
) {
  final all = nodes.toList();
  final children = <String, List<MapNode>>{};
  for (final n in all) {
    if (n.parentNodeId != null) (children[n.parentNodeId!] ??= []).add(n);
  }
  final pending = summaryRoots(summary, all, summaries).toList();
  final result = <String>{};
  while (pending.isNotEmpty) {
    final node = pending.removeLast();
    if (!shown.contains(node.id) || !result.add(node.id)) continue;
    if (!node.collapsed) pending.addAll(children[node.id] ?? []);
  }
  return result;
}

MapLayoutKind summaryDirection(
  MapSummary summary,
  List<MapNode> nodes,
  MapLayoutKind kind, {
  List<MapSummary> summaries = const [],
  Map<String, MapLayoutKind>? layouts,
}) {
  return _summaryDirection(
    summary,
    nodes,
    kind,
    layouts ?? effectiveBranchLayouts(nodes, kind, summaries: summaries),
  );
}

/// 概要位于范围外侧，其子主题沿概要方向展开，而不继承主轴的交替分流。
Map<String, MapLayoutKind> effectiveBranchLayouts(
  List<MapNode> nodes,
  MapLayoutKind kind, {
  List<MapSummary> summaries = const [],
}) {
  var layouts = branchLayoutsFor(nodes, kind);
  if (summaries.isEmpty) return layouts;
  final byId = {for (final node in nodes) node.id: node};
  final children = <String, List<MapNode>>{};
  for (final node in nodes) {
    (children[node.parentNodeId ?? ''] ??= []).add(node);
  }
  final depths = <String, int>{};
  final pending = <(MapNode, int)>[
    for (final node in nodes)
      if (!byId.containsKey(node.parentNodeId)) (node, 0),
  ];
  while (pending.isNotEmpty) {
    final (node, depth) = pending.removeLast();
    if (depths.containsKey(node.id)) continue;
    depths[node.id] = depth;
    for (final child in children[node.id] ?? const <MapNode>[]) {
      pending.add((child, depth + 1));
    }
  }
  final ordered = summaries.toList()
    ..sort(
      (a, b) => (depths[a.summaryNodeId] ?? 0).compareTo(
        depths[b.summaryNodeId] ?? 0,
      ),
    );
  final roots = <String, MapLayoutKind>{};
  for (final summary in ordered) {
    if (byId[summary.summaryNodeId]?.branchLayout != null) continue;
    roots[summary.summaryNodeId] = _summaryDirection(
      summary,
      nodes,
      kind,
      layouts,
    );
    layouts = branchLayoutsFor(nodes, kind, rootLayouts: roots);
  }
  return layouts;
}

MapLayoutKind _summaryDirection(
  MapSummary summary,
  List<MapNode> nodes,
  MapLayoutKind kind,
  Map<String, MapLayoutKind> layouts,
) {
  final root = nodes.where((n) => summary.nodeIds.contains(n.id)).firstOrNull;
  if (root == null) return MapLayoutKind.right;
  final incoming = incomingBranchLayout(root, kind, layouts);
  if (incoming != MapLayoutKind.mindMap) {
    return incoming == MapLayoutKind.free
        ? MapLayoutKind.right
        : incoming.primaryDirection;
  }
  var branch = root;
  final byId = {for (final n in nodes) n.id: n};
  final seen = <String>{};
  while (byId[branch.parentNodeId] != null &&
      layouts[branch.parentNodeId] != MapLayoutKind.mindMap) {
    if (!seen.add(branch.id)) throw StateError('脑图层级存在循环');
    branch = byId[branch.parentNodeId]!;
  }
  final parent = byId[branch.parentNodeId];
  return branch.branchSide == -1 ||
          branch.branchSide == null && parent != null && branch.x < parent.x
      ? MapLayoutKind.left
      : MapLayoutKind.right;
}
