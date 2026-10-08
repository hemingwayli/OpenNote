import 'models.dart';

/// 每个主题的子分支方向；双侧结构仅在指定主题处分流，后代继续沿所属方向。
Map<String, MapLayoutKind> branchLayoutsFor(
  List<MapNode> nodes,
  MapLayoutKind kind, {
  Map<String, int> branchSides = const {},
  Map<String, MapLayoutKind> rootLayouts = const {},
}) {
  final byId = {for (final n in nodes) n.id: n};
  final children = <String, List<MapNode>>{};
  for (final node in nodes) {
    (children[node.parentNodeId ?? ''] ??= []).add(node);
  }
  final result = <String, MapLayoutKind>{};
  final pending = <(MapNode, MapLayoutKind)>[
    for (final node in nodes)
      if (!byId.containsKey(node.parentNodeId)) (node, kind),
  ];
  while (pending.isNotEmpty) {
    final (node, inherited) = pending.removeLast();
    if (result.containsKey(node.id)) continue;
    final layout = node.branchLayout ?? rootLayouts[node.id] ?? inherited;
    result[node.id] = layout;
    for (final child in children[node.id] ?? const <MapNode>[]) {
      final side =
          branchSides[child.id] ??
          child.branchSide ??
          (child.x + child.width / 2 < node.x + node.width / 2 ? -1 : 1);
      pending.add((child, inheritedChildLayout(layout, side)));
    }
  }
  // 显示层有限处理孤立环；真正布局和持久化仍独立校验完整层级。
  for (final node in nodes) {
    result.putIfAbsent(
      node.id,
      () => node.branchLayout ?? rootLayouts[node.id] ?? kind,
    );
  }
  return result;
}

MapLayoutKind incomingBranchLayout(
  MapNode node,
  MapLayoutKind mapKind,
  Map<String, MapLayoutKind> layouts,
) => layouts[node.parentNodeId] ?? mapKind;

/// 主轴结构只在所属主题处分流，子树保持朝外；内层显式结构仍可覆盖。
MapLayoutKind inheritedChildLayout(MapLayoutKind layout, int side) =>
    switch (layout) {
      MapLayoutKind.mindMap || MapLayoutKind.timelineVertical =>
        side == -1 ? MapLayoutKind.left : MapLayoutKind.right,
      MapLayoutKind.timeline =>
        side == -1 ? MapLayoutKind.up : MapLayoutKind.down,
      MapLayoutKind.fishboneLeft => MapLayoutKind.right,
      MapLayoutKind.fishboneRight => MapLayoutKind.left,
      _ => layout,
    };
