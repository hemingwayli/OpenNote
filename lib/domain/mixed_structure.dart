part of 'map_layout.dart';

class _BranchBounds {
  const _BranchBounds(this.left, this.top, this.right, this.bottom);
  final double left, top, right, bottom;
  double get width => right - left;
  double get height => bottom - top;
  _BranchBounds include(_BranchBounds other, PdfPoint offset) => _BranchBounds(
    math.min(left, other.left + offset.x),
    math.min(top, other.top + offset.y),
    math.max(right, other.right + offset.x),
    math.max(bottom, other.bottom + offset.y),
  );
}

/// 混合结构使用子树边界排布，避免转向的分支压住邻居；两趟迭代不复制整棵子树。
MapLayoutPlan _calculateMixedLayout(List<MapNode> nodes, MapLayoutKind kind) {
  final byId = {for (final node in nodes) node.id: node};
  final children = <String, List<MapNode>>{}, roots = <MapNode>[];
  for (final node in nodes) {
    if (!byId.containsKey(node.parentNodeId)) {
      roots.add(node);
    } else {
      (children[node.parentNodeId!] ??= []).add(node);
    }
  }
  roots.sort(compareMapNodes);
  for (final group in children.values) {
    group.sort(compareMapNodes);
  }
  final ordered = <MapNode>[], seen = <String>{};
  final stack = roots.reversed.toList();
  while (stack.isNotEmpty) {
    final node = stack.removeLast();
    if (!seen.add(node.id)) throw StateError('脑图层级存在循环');
    ordered.add(node);
    stack.addAll((children[node.id] ?? const <MapNode>[]).reversed);
  }
  if (seen.length != nodes.length) throw StateError('脑图层级存在循环');
  final weights = <String, double>{}, sides = <String, int>{};
  for (final node in ordered.reversed) {
    weights[node.id] =
        1 +
        (node.collapsed
            ? 0
            : (children[node.id] ?? const <MapNode>[]).fold(
                0.0,
                (v, n) => v + weights[n.id]!,
              ));
  }
  // 指定的左右方向优先，其余按可见分支体量分配，随后保存以保持编辑顺序稳定。
  for (final node in ordered) {
    final group = children[node.id] ?? const <MapNode>[];
    var left = 0.0, right = 0.0;
    for (final child in group) {
      if (child.branchSide == -1) left += weights[child.id]!;
      if (child.branchSide == 1) right += weights[child.id]!;
    }
    for (final child in group) {
      final side = child.branchSide ?? (right <= left ? 1 : -1);
      sides[child.id] = side;
      if (child.branchSide == null) {
        if (side == -1) {
          left += weights[child.id]!;
        } else {
          right += weights[child.id]!;
        }
      }
    }
  }
  final initialLayouts = branchLayoutsFor(nodes, kind, branchSides: sides);
  for (final node in ordered) {
    final layout = initialLayouts[node.id]!;
    if (!layout.spine) continue;
    final group = children[node.id] ?? const <MapNode>[];
    for (var i = 0; i < group.length; i++) {
      sides[group[i].id] = group[i].branchSide ?? (i.isEven ? 1 : -1);
    }
  }
  final layouts = branchLayoutsFor(nodes, kind, branchSides: sides);
  final offsets = <String, PdfPoint>{}, bounds = <String, _BranchBounds>{};
  final persistedSides = <String, int>{};
  for (final node in ordered.reversed) {
    var box = _BranchBounds(0, 0, node.width, node.height);
    final group = node.collapsed
        ? const <MapNode>[]
        : children[node.id] ?? const <MapNode>[];
    final layout = layouts[node.id]!;
    if (layout == MapLayoutKind.free) {
      for (final child in group) {
        final delta = PdfPoint(child.x - node.x, child.y - node.y);
        offsets[child.id] = delta;
        box = box.include(bounds[child.id]!, delta);
      }
    } else if (layout.tree) {
      var cursor = node.height + 36;
      for (final child in group) {
        final b = bounds[child.id]!;
        final delta = PdfPoint(
          layout == MapLayoutKind.treeRight
              ? 48 - b.left
              : node.width - 48 - b.right,
          cursor - b.top,
        );
        offsets[child.id] = delta;
        box = box.include(b, delta);
        cursor += b.height + 36;
      }
    } else if (layout.spine) {
      var cursor = layout == MapLayoutKind.timelineVertical
          ? node.height + 96
          : layout == MapLayoutKind.fishboneRight
          ? 96.0
          : node.width + 96;
      for (final child in group) {
        final b = bounds[child.id]!, side = sides[child.id]!;
        late PdfPoint delta;
        if (layout == MapLayoutKind.timelineVertical) {
          delta = PdfPoint(
            side == -1 ? -72 - b.right : node.width + 72 - b.left,
            cursor - b.top,
          );
          cursor += b.height + 96;
        } else {
          final y = side == -1 ? -72 - b.bottom : node.height + 72 - b.top;
          final diagonal = layout.fishbone
              ? (y + child.height / 2 - node.height / 2).abs()
              : 0.0;
          delta = PdfPoint(
            layout == MapLayoutKind.fishboneRight
                ? -cursor - diagonal - b.right
                : cursor + diagonal - b.left,
            y,
          );
          cursor += b.width + diagonal + 96;
        }
        offsets[child.id] = delta;
        box = box.include(b, delta);
        persistedSides[child.id] = side;
      }
    } else {
      final groups = layout == MapLayoutKind.mindMap
          ? [
              group.where((n) => sides[n.id] == 1).toList(),
              group.where((n) => sides[n.id] == -1).toList(),
            ]
          : [group];
      for (final members in groups) {
        if (members.isEmpty) continue;
        final direction = layout == MapLayoutKind.mindMap
            ? sides[members.first.id] == -1
                  ? MapLayoutKind.left
                  : MapLayoutKind.right
            : layout.primaryDirection;
        final total =
            members.fold(
              0.0,
              (v, n) =>
                  v +
                  (direction.vertical
                      ? bounds[n.id]!.width
                      : bounds[n.id]!.height),
            ) +
            (members.length - 1) * 36;
        var cursor =
            (direction.vertical ? node.width : node.height) / 2 - total / 2;
        for (final child in members) {
          final b = bounds[child.id]!;
          final delta = switch (direction) {
            MapLayoutKind.left => PdfPoint(-72 - b.right, cursor - b.top),
            MapLayoutKind.down => PdfPoint(
              cursor - b.left,
              node.height + 72 - b.top,
            ),
            MapLayoutKind.up => PdfPoint(cursor - b.left, -72 - b.bottom),
            _ => PdfPoint(node.width + 72 - b.left, cursor - b.top),
          };
          offsets[child.id] = delta;
          box = box.include(b, delta);
          cursor += (direction.vertical ? b.width : b.height) + 36;
          if (layout == MapLayoutKind.mindMap) {
            persistedSides[child.id] = sides[child.id]!;
          }
        }
      }
    }
    bounds[node.id] = box;
  }
  final positions = <String, PdfPoint>{};
  double? forestBottom;
  for (final root in roots) {
    final box = bounds[root.id]!;
    final anchor = kind == MapLayoutKind.free || forestBottom == null
        ? PdfPoint(root.x, root.y)
        : PdfPoint(roots.first.x, forestBottom + 100 - box.top);
    final pending = <(MapNode, PdfPoint)>[(root, anchor)];
    while (pending.isNotEmpty) {
      final (node, point) = pending.removeLast();
      positions[node.id] = point;
      if (node.collapsed) continue;
      for (final child in children[node.id] ?? const <MapNode>[]) {
        final delta = offsets[child.id]!;
        pending.add((child, PdfPoint(point.x + delta.x, point.y + delta.y)));
      }
    }
    forestBottom = anchor.y + box.bottom;
  }
  return MapLayoutPlan(positions, persistedSides);
}
