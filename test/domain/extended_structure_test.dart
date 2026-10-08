import 'package:flutter_test/flutter_test.dart';
import 'package:opennote/domain/models.dart';
import 'package:opennote/domain/map_layout.dart';
import 'package:opennote/domain/branch_structure.dart';
import 'package:opennote/domain/structure_geometry.dart';
import 'package:opennote/domain/topic_drop.dart';

void main() {
  test('大括号中间主题的连线接到括号中腰，左右镜像无断口', () {
    final root = node('r');
    final children = [
      node('a', parent: 'r'),
      node('b', parent: 'r'),
      node('c', parent: 'r'),
    ];
    for (final kind in [MapLayoutKind.braceRight, MapLayoutKind.braceLeft]) {
      final positions = calculateMapLayout([root, ...children], kind).positions;
      final spine = structureSpineGeometry(
        root,
        [for (final c in children) (c, positions[c.id]!)],
        kind,
        positions[root.id]!,
      )!;
      final link = structureLinkGeometry(
        root,
        children[1],
        kind,
        positions[root.id]!,
        positions['b']!,
        spine: spine,
      )!;
      expect(link.first.x, spine.points.last.x);
      expect(link.first.y, spine.points.last.y);
    }
  });
  for (final kind in MapLayoutKind.values.where((k) => k.extended)) {
    test('${kind.label}：固定主题、可变尺寸、子树不重叠且主轴确实不同', () {
      final nodes = [
        node('r', x: 110, y: 160),
        node('a', parent: 'r', order: 0, width: 320, height: 170),
        node('b', parent: 'r', order: 1, width: 190, height: 90),
        node('a1', parent: 'a', order: 0, width: 320, height: 210),
        node('a2', parent: 'a', order: 1),
        node('b1', parent: 'b', order: 0),
      ];
      final plan = calculateMapLayout(nodes.reversed.toList(), kind);
      expect(plan.positions['r']!.x, 110);
      expect(plan.positions['r']!.y, 160);
      noOverlap(nodes, plan);
      final r = plan.positions['r']!,
          a = plan.positions['a']!,
          b = plan.positions['b']!;
      if (kind.tree) {
        expect(a.y, greaterThan(r.y + nodes[0].height));
        expect(b.y, greaterThan(plan.positions['a2']!.y + 116));
        expect((a.x - r.x).abs(), lessThan(nodes[1].width));
      } else if (kind == MapLayoutKind.timelineVertical) {
        expect(a.y, lessThan(b.y));
        expect(a.x > r.x && b.x < r.x, isTrue);
      } else if (kind.spine) {
        expect(a.y > r.y && b.y < r.y, isTrue);
        expect(
          kind == MapLayoutKind.fishboneRight ? a.x > b.x : a.x < b.x,
          isTrue,
        );
      } else {
        expect(
          kind.primaryDirection == MapLayoutKind.left ? a.x < r.x : a.x > r.x,
          isTrue,
        );
      }
      final link = structureLinkGeometry(nodes[0], nodes[1], kind, r, a)!;
      expect(link.every((p) => p.x.isFinite && p.y.isFinite), isTrue);
      if (kind.fishbone) {
        expect(
          (link.last.x - link.first.x).abs(),
          closeTo((link.last.y - link.first.y).abs(), .001),
        );
      }
      final spine = structureSpineGeometry(
        nodes[0],
        [(nodes[1], a), (nodes[2], b)],
        kind,
        r,
      );
      expect(spine != null, kind.spine || kind.brace);
      if (kind.brace) {
        expect(spine!.braceBottom!.y, greaterThan(spine.braceTop!.y));
      }
    });
  }
  test('交替主轴保持已指定侧，子分支向外；局部转向不覆盖其他树', () {
    final nodes = [
      node('r'),
      node('a', parent: 'r', side: -1),
      node('b', parent: 'r', side: 1),
      node('x', parent: 'a', structure: MapLayoutKind.treeLeft),
      node('y', parent: 'x'),
    ];
    final plan = calculateMapLayout(nodes, MapLayoutKind.timeline);
    noOverlap(nodes, plan);
    expect(plan.branchSides['a'], -1);
    final layouts = branchLayoutsFor(
      nodes,
      MapLayoutKind.timeline,
      branchSides: plan.branchSides,
    );
    expect(layouts['a'], MapLayoutKind.up);
    expect(layouts['b'], MapLayoutKind.down);
    expect(layouts['x'], MapLayoutKind.treeLeft);
    expect(layouts['y'], MapLayoutKind.treeLeft);
  });
  test('主轴拖放按事件方向使用前后边缘；右鱼头方向反转', () {
    for (final kind in [
      MapLayoutKind.timeline,
      MapLayoutKind.timelineVertical,
      MapLayoutKind.fishboneRight,
    ]) {
      final target = node('t', parent: 'r', x: 400, y: 400);
      final nodes = [node('r'), target];
      final horizontal = kind.siblingsHorizontal;
      final before = kind.reverseSiblingOrder ? 215.0 : 5.0;
      final point = horizontal
          ? PdfPoint(target.x + before, target.y + 58)
          : PdfPoint(target.x + 110, target.y + 5);
      expect(
        topicDropTargetAt(
          nodes,
          {'r', 't'},
          {'r'},
          point,
          kind,
          branchLayoutsFor(nodes, kind),
        )!.placement,
        TopicDropPlacement.before,
      );
    }
  });
  test('深树缩进迭代与折叠：不递归溢出，隐藏后代保留坐标', () {
    final deep = [
      for (var i = 0; i < 5000; i++)
        node('$i', parent: i == 0 ? null : '${i - 1}'),
    ];
    expect(
      calculateMapLayout(deep, MapLayoutKind.treeRight).positions.length,
      5000,
    );
    final folded = [
      node('r', folded: true),
      node('a', parent: 'r', x: 901, y: 702),
    ];
    final plan = calculateMapLayout(folded, MapLayoutKind.fishboneLeft);
    expect(plan.positions.keys, ['r']);
    expect(folded[1].x, 901);
  });
}

MapNode node(
  String id, {
  String? parent,
  double x = 80,
  double y = 80,
  double width = 220,
  double height = 116,
  int? order,
  int? side,
  MapLayoutKind? structure,
  bool folded = false,
}) => MapNode(
  id: id,
  mapId: 'm',
  cardId: id,
  parentNodeId: parent,
  x: x,
  y: y,
  width: width,
  height: height,
  sortIndex: order,
  branchSide: side,
  branchLayout: structure,
  collapsed: folded,
);

void noOverlap(List<MapNode> nodes, MapLayoutPlan plan) {
  expect(plan.positions.length, nodes.length);
  for (var i = 0; i < nodes.length; i++) {
    final a = nodes[i], p = plan.positions[a.id]!;
    for (var j = i + 1; j < nodes.length; j++) {
      final b = nodes[j], q = plan.positions[b.id]!;
      expect(
        p.x < q.x + b.width &&
            p.x + a.width > q.x &&
            p.y < q.y + b.height &&
            p.y + a.height > q.y,
        isFalse,
        reason: '${a.id}/${b.id} 重叠',
      );
    }
  }
}
