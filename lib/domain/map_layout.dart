import 'dart:math' as math;

import 'models.dart';
import 'summary_geometry.dart';
import 'branch_structure.dart';

part 'mixed_structure.dart';

class MapLayoutPlan {
  const MapLayoutPlan(this.positions, this.branchSides);
  final Map<String, PdfPoint> positions;
  final Map<String, int> branchSides;
}

/// 从单父树计算结构位置，折叠后代保持原坐标；迭代遍历支持很深的知识树。
MapLayoutPlan calculateMapLayout(
  List<MapNode> nodes,
  MapLayoutKind kind, {
  List<MapSummary> summaries = const [],
}) {
  if (summaries.isEmpty) return _calculateTreeLayout(nodes, kind);
  final byId = {for (final n in nodes) n.id: n};
  final children = <String, List<MapNode>>{};
  for (final n in nodes) {
    if (n.parentNodeId != null) (children[n.parentNodeId!] ??= []).add(n);
  }
  Set<String> branch(String id) {
    final result = <String>{}, pending = <String>[id];
    while (pending.isNotEmpty) {
      final next = pending.removeLast();
      if (!result.add(next)) throw StateError('脑图层级存在循环');
      pending.addAll((children[next] ?? []).map((n) => n.id));
    }
    return result;
  }

  final auxiliaryRoots = summaries.map((s) => s.summaryNodeId).toSet();
  final summaryBranches = {for (final id in auxiliaryRoots) id: branch(id)};
  final auxiliary = <String>{};
  for (final id in auxiliaryRoots) {
    auxiliary.addAll(summaryBranches[id]!);
  }
  final main = nodes.where((n) => !auxiliary.contains(n.id)).toList();
  final mainPlan = _calculateTreeLayout(main, kind);
  final positions = <String, PdfPoint>{...mainPlan.positions};
  final sides = <String, int>{...mainPlan.branchSides};
  final ready =
      kind == MapLayoutKind.free && main.every((n) => n.branchLayout == null)
      ? main.map((n) => n.id).toSet()
      : positions.keys.toSet();
  PdfPoint point(MapNode n) => positions[n.id] ?? PdfPoint(n.x, n.y);
  final pending = summaries
      .where((s) => byId.containsKey(s.summaryNodeId))
      .toList();
  var progress = true;
  while (pending.isNotEmpty && progress) {
    progress = false;
    for (final summary in pending.toList()) {
      final members = summaryMembers(
        summary,
        nodes,
        summaries,
        nodes.map((n) => n.id).toSet(),
      );
      if (members.isEmpty || !members.every(ready.contains)) continue;
      final root = byId[summary.summaryNodeId]!;
      final direction = summaryDirection(
        summary,
        [
          for (final n in nodes)
            MapNode(
              id: n.id,
              mapId: n.mapId,
              cardId: n.cardId,
              parentNodeId: n.parentNodeId,
              x: point(n).x,
              y: point(n).y,
              width: n.width,
              height: n.height,
              branchSide: sides[n.id] ?? n.branchSide,
              sortIndex: n.sortIndex,
              collapsed: n.collapsed,
              style: n.style,
              branchLayout: n.branchLayout,
            ),
        ],
        kind,
        summaries: summaries,
      );
      var left = double.infinity, top = double.infinity;
      var right = double.negativeInfinity, bottom = double.negativeInfinity;
      for (final id in members) {
        final n = byId[id]!, p = point(n);
        left = math.min(left, p.x);
        top = math.min(top, p.y);
        right = math.max(right, p.x + n.width);
        bottom = math.max(bottom, p.y + n.height);
      }
      final rootPoint = switch (direction) {
        MapLayoutKind.left => PdfPoint(
          left - 72 - root.width,
          (top + bottom - root.height) / 2,
        ),
        MapLayoutKind.down => PdfPoint(
          (left + right - root.width) / 2,
          bottom + 72,
        ),
        MapLayoutKind.up => PdfPoint(
          (left + right - root.width) / 2,
          top - 72 - root.height,
        ),
        _ => PdfPoint(right + 72, (top + bottom - root.height) / 2),
      };
      final ids = summaryBranches[root.id]!;
      final nested = <String>{};
      for (final id in auxiliaryRoots) {
        if (id != root.id && ids.contains(id)) {
          nested.addAll(summaryBranches[id]!);
        }
      }
      final local = nodes
          .where((n) => ids.contains(n.id) && !nested.contains(n.id))
          .toList();
      final plan = _calculateTreeLayout(local, direction);
      final anchor = plan.positions[root.id]!;
      var dx = rootPoint.x - anchor.x, dy = rootPoint.y - anchor.y;
      // 概要子树比范围更高时向外避让，不能遮住未被概括的主题。
      bool overlaps() {
        for (final placed in plan.positions.entries) {
          final n = byId[placed.key]!;
          final x = placed.value.x + dx, y = placed.value.y + dy;
          for (final id in ready) {
            final other = byId[id]!, p = point(other);
            if (x < p.x + other.width + 20 &&
                x + n.width + 20 > p.x &&
                y < p.y + other.height + 20 &&
                y + n.height + 20 > p.y) {
              return true;
            }
          }
        }
        return false;
      }

      while (overlaps()) {
        switch (direction) {
          case MapLayoutKind.left:
            dx -= 292;
          case MapLayoutKind.up:
            dy -= 188;
          case MapLayoutKind.down:
            dy += 188;
          default:
            dx += 292;
        }
      }
      for (final entry in plan.positions.entries) {
        positions[entry.key] = PdfPoint(entry.value.x + dx, entry.value.y + dy);
        ready.add(entry.key);
      }
      sides.addAll(plan.branchSides);
      pending.remove(summary);
      progress = true;
    }
  }
  // 折叠范围保持旧坐标；重新展开时在同一事务内恢复布局。
  return MapLayoutPlan(positions, sides);
}

MapLayoutPlan _calculateTreeLayout(List<MapNode> nodes, MapLayoutKind kind) {
  if (kind.extended ||
      nodes.isNotEmpty && nodes.any((n) => n.branchLayout != null)) {
    return _calculateMixedLayout(nodes, kind);
  }
  if (nodes.isEmpty || kind == MapLayoutKind.free) {
    return const MapLayoutPlan({}, {});
  }
  final byId = {for (final node in nodes) node.id: node};
  final children = <String, List<MapNode>>{};
  final roots = <MapNode>[];
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
  // 先检查完整层级，不让折叠隐藏循环或把坏树排成一个看似合法的布局。
  final visited = <String>{};
  final depths = <String, int>{};
  final stack = <(MapNode, int)>[for (final root in roots.reversed) (root, 0)];
  final ordered = <MapNode>[];
  while (stack.isNotEmpty) {
    final (node, depth) = stack.removeLast();
    if (!visited.add(node.id)) throw StateError('脑图层级存在循环');
    depths[node.id] = depth;
    ordered.add(node);
    for (final child in (children[node.id] ?? const <MapNode>[]).reversed) {
      stack.add((child, depth + 1));
    }
  }
  if (visited.length != nodes.length) throw StateError('脑图层级存在循环');
  final spans = <String, double>{};
  final primaryDimensions = <int, double>{};
  final visible = <String>{};
  final pendingVisible = roots.reversed.toList();
  while (pendingVisible.isNotEmpty) {
    final node = pendingVisible.removeLast();
    visible.add(node.id);
    final primary = kind.vertical ? node.height : node.width;
    primaryDimensions[depths[node.id]!] = math.max(
      primaryDimensions[depths[node.id]!] ?? 0,
      primary,
    );
    if (!node.collapsed) {
      pendingVisible.addAll((children[node.id] ?? const <MapNode>[]).reversed);
    }
  }
  double sumSpan(List<MapNode> group) => group.isEmpty
      ? 0
      : group.fold(0.0, (sum, node) => sum + spans[node.id]!) +
            (group.length - 1) * 36;
  for (final node in ordered.reversed.where(
    (node) => visible.contains(node.id),
  )) {
    final descendants = node.collapsed
        ? const <MapNode>[]
        : children[node.id] ?? const <MapNode>[];
    spans[node.id] = math.max(
      kind.vertical ? node.width : node.height,
      sumSpan(descendants),
    );
  }
  final offsets = <int, double>{0: 0};
  for (var depth = 1; depth < primaryDimensions.length; depth++) {
    offsets[depth] = offsets[depth - 1]! + primaryDimensions[depth - 1]! + 72;
  }
  final positions = <String, PdfPoint>{};
  final sides = <String, int>{};
  double? forestBottom;
  final anchorX = roots.first.x;
  for (final root in roots) {
    final local = <String, PdfPoint>{};
    final assignments = <({MapNode node, double center, int side})>[
      (node: root, center: 0, side: 1),
    ];
    if (kind == MapLayoutKind.mindMap && !root.collapsed) {
      var leftWeight = 0.0;
      var rightWeight = 0.0;
      final branches = children[root.id] ?? const <MapNode>[];
      for (final child in branches) {
        if (child.branchSide == -1) leftWeight += spans[child.id]!;
        if (child.branchSide == 1) rightWeight += spans[child.id]!;
      }
      for (final child in branches) {
        var side = child.branchSide;
        if (side == null) {
          side = rightWeight <= leftWeight ? 1 : -1;
          if (side == 1) {
            rightWeight += spans[child.id]!;
          } else {
            leftWeight += spans[child.id]!;
          }
        }
        sides[child.id] = side;
      }
    }
    while (assignments.isNotEmpty) {
      final current = assignments.removeLast();
      final node = current.node;
      final depth = depths[node.id]!;
      final primary = offsets[depth]!;
      local[node.id] = switch (kind) {
        MapLayoutKind.down => PdfPoint(
          current.center - node.width / 2,
          primary,
        ),
        MapLayoutKind.up => PdfPoint(
          current.center - node.width / 2,
          root.height - primary - node.height,
        ),
        MapLayoutKind.left => PdfPoint(
          root.width - primary - node.width,
          current.center - node.height / 2,
        ),
        MapLayoutKind.mindMap when current.side == -1 => PdfPoint(
          root.width - primary - node.width,
          current.center - node.height / 2,
        ),
        _ => PdfPoint(primary, current.center - node.height / 2),
      };
      if (node.collapsed) continue;
      final descendants = children[node.id] ?? const <MapNode>[];
      final groups = kind == MapLayoutKind.mindMap && depth == 0
          ? [
              descendants.where((n) => sides[n.id] == 1).toList(),
              descendants.where((n) => sides[n.id] == -1).toList(),
            ]
          : [descendants];
      for (final group in groups) {
        var cursor = current.center - sumSpan(group) / 2;
        final next = <({MapNode node, double center, int side})>[];
        for (final child in group) {
          next.add((
            node: child,
            center: cursor + spans[child.id]! / 2,
            side: depth == 0 && kind == MapLayoutKind.mindMap
                ? sides[child.id]!
                : current.side,
          ));
          cursor += spans[child.id]! + 36;
        }
        assignments.addAll(next.reversed);
      }
    }
    final top = local.values.map((point) => point.y).reduce(math.min);
    final bottom = local.entries
        .map((entry) => entry.value.y + byId[entry.key]!.height)
        .reduce(math.max);
    final localRoot = local[root.id]!;
    final dx = anchorX - localRoot.x;
    final dy = forestBottom == null
        ? root.y - localRoot.y
        : forestBottom + 100 - top;
    for (final entry in local.entries) {
      positions[entry.key] = PdfPoint(entry.value.x + dx, entry.value.y + dy);
    }
    forestBottom = bottom + dy;
  }
  return MapLayoutPlan(positions, sides);
}
