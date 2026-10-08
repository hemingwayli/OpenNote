import 'package:flutter_test/flutter_test.dart';
import 'package:opennote/domain/models.dart';
import 'package:opennote/domain/branch_structure.dart';
import 'package:opennote/domain/map_layout.dart';
import 'package:opennote/domain/topic_drop.dart';
import 'package:opennote/domain/summary_geometry.dart';

MapNode node(
  String id, {
  String? parent,
  MapLayoutKind? layout,
  int? side,
  bool collapsed = false,
  double x = 100,
  double y = 100,
  int? order,
}) => MapNode(
  id: id,
  mapId: 'm',
  cardId: id,
  parentNodeId: parent,
  x: x,
  y: y,
  branchLayout: layout,
  branchSide: side,
  collapsed: collapsed,
  sortIndex: order,
);

void main() {
  test('概要跟随局部分支方向；自由图的混合分支折叠时概要保持旧坐标', () {
    const summary = MapSummary(
      id: 's',
      mapId: 'm',
      summaryNodeId: 'summary',
      parentNodeId: 'a',
      nodeIds: ['a1', 'a2'],
    );
    List<MapNode> nodes(bool folded) => [
      node('r'),
      node('a', parent: 'r', layout: MapLayoutKind.down, collapsed: folded),
      node('a1', parent: 'a', order: 0),
      node('a2', parent: 'a', order: 1),
      node('summary', parent: 'a', x: 900, y: 900),
    ];
    expect(
      summaryDirection(summary, nodes(false), MapLayoutKind.right),
      MapLayoutKind.down,
    );
    final plan = calculateMapLayout(
      nodes(false),
      MapLayoutKind.free,
      summaries: [summary],
    );
    expect(
      plan.positions['summary']!.y,
      greaterThan(plan.positions['a1']!.y + 116),
    );
    final folded = calculateMapLayout(
      nodes(true),
      MapLayoutKind.free,
      summaries: [summary],
    );
    expect(folded.positions.containsKey('summary'), isFalse);
    expect(folded.positions.containsKey('a1'), isFalse);
  });
  test('混合向右、向下和向左按完整子树避让，保留中心主题锚点', () {
    final nodes = [
      node('r'),
      node('a', parent: 'r', layout: MapLayoutKind.down, order: 0),
      node('b', parent: 'r', layout: MapLayoutKind.left, order: 1),
      node('a1', parent: 'a'),
      node('a2', parent: 'a'),
      node('b1', parent: 'b'),
      node('b2', parent: 'b'),
    ];
    final plan = calculateMapLayout(nodes, MapLayoutKind.right);
    expect(plan.positions['r']!.x, 100);
    expect(plan.positions['r']!.y, 100);
    expect(plan.positions['a1']!.y, greaterThan(plan.positions['a']!.y + 116));
    expect(plan.positions['b1']!.x, lessThan(plan.positions['b']!.x - 220));
    for (var i = 0; i < nodes.length; i++) {
      for (var j = i + 1; j < nodes.length; j++) {
        final a = plan.positions[nodes[i].id]!,
            b = plan.positions[nodes[j].id]!;
        expect(
          a.x + 220 <= b.x ||
              b.x + 220 <= a.x ||
              a.y + 116 <= b.y ||
              b.y + 116 <= a.y,
          isTrue,
          reason: '${nodes[i].id} 与 ${nodes[j].id} 不能重叠',
        );
      }
    }
  });
  test('局部双侧分流只作用于直接子主题，最近内层结构覆盖继承', () {
    final nodes = [
      node('r'),
      node('a', parent: 'r', layout: MapLayoutKind.mindMap),
      node('l', parent: 'a', side: -1),
      node('ll', parent: 'l'),
      node('rr', parent: 'a', side: 1, layout: MapLayoutKind.up),
      node('u', parent: 'rr'),
    ];
    final layouts = branchLayoutsFor(nodes, MapLayoutKind.right);
    expect(layouts['a'], MapLayoutKind.mindMap);
    expect(layouts['l'], MapLayoutKind.left);
    expect(layouts['ll'], MapLayoutKind.left);
    expect(layouts['u'], MapLayoutKind.up);
    final plan = calculateMapLayout(nodes, MapLayoutKind.right);
    expect(plan.branchSides, {'l': -1, 'rr': 1});
    expect(plan.positions['ll']!.x, lessThan(plan.positions['l']!.x));
    expect(plan.positions['u']!.y, lessThan(plan.positions['rr']!.y));
  });
  test('自由分支保留手工相对位置，其他分支继续自动整理', () {
    final nodes = [
      node('r'),
      node('a', parent: 'r', layout: MapLayoutKind.free, x: 450, y: 200),
      node('a1', parent: 'a', x: 760, y: 380),
      node('b', parent: 'r'),
    ];
    final p = calculateMapLayout(nodes, MapLayoutKind.right).positions;
    expect(p['a1']!.x - p['a']!.x, 310);
    expect(p['a1']!.y - p['a']!.y, 180);
    expect(p['b']!.x, greaterThan(p['r']!.x));
  });
  test('折叠后代不写新坐标，展开恢复混合结构，隐藏环也必须拒绝', () {
    final nodes = [
      node('r', layout: MapLayoutKind.down, collapsed: true),
      node('a', parent: 'r'),
    ];
    expect(calculateMapLayout(nodes, MapLayoutKind.right).positions.keys, [
      'r',
    ]);
    expect(
      calculateMapLayout([
        node('r', layout: MapLayoutKind.down),
        nodes.last,
      ], MapLayoutKind.right).positions,
      hasLength(2),
    );
    expect(
      () => calculateMapLayout([
        node('r', layout: MapLayoutKind.down),
        node('a', parent: 'b', collapsed: true),
        node('b', parent: 'a'),
      ], MapLayoutKind.free),
      throwsStateError,
    );
  });
  test('5000 层混合知识树使用迭代遍历且坐标有效', () {
    final nodes = List.generate(
      5000,
      (i) => node(
        '$i',
        parent: i == 0 ? null : '${i - 1}',
        layout: i % 100 == 0 ? MapLayoutKind.down : null,
      ),
    );
    final plan = calculateMapLayout(nodes, MapLayoutKind.right);
    expect(plan.positions, hasLength(5000));
    expect(
      plan.positions.values.every((p) => p.x.isFinite && p.y.isFinite),
      isTrue,
    );
  });
  test('水平和垂直插入区域、自由布局及排除后代具有不同拖放语义', () {
    final n = node('a', parent: 'r');
    TopicDropTarget? hit(
      PdfPoint p,
      MapLayoutKind kind, {
      Set<String> excluded = const {},
    }) => topicDropTargetAt([n], {'a'}, excluded, p, kind, {'r': kind});
    expect(
      hit(const PdfPoint(200, 105), MapLayoutKind.right)!.placement,
      TopicDropPlacement.before,
    );
    expect(
      hit(const PdfPoint(200, 210), MapLayoutKind.right)!.placement,
      TopicDropPlacement.after,
    );
    expect(
      hit(const PdfPoint(200, 160), MapLayoutKind.right)!.placement,
      TopicDropPlacement.child,
    );
    expect(
      hit(const PdfPoint(105, 160), MapLayoutKind.down)!.placement,
      TopicDropPlacement.before,
    );
    expect(
      hit(const PdfPoint(315, 160), MapLayoutKind.up)!.placement,
      TopicDropPlacement.after,
    );
    expect(
      hit(const PdfPoint(200, 105), MapLayoutKind.free)!.placement,
      TopicDropPlacement.child,
    );
    expect(
      hit(const PdfPoint(200, 105), MapLayoutKind.right, excluded: {'a'}),
      isNull,
    );
    expect(hit(const PdfPoint(900, 160), MapLayoutKind.right), isNull);
  });
}
