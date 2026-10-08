import 'package:flutter_test/flutter_test.dart';
import 'package:opennote/domain/models.dart';
import 'package:opennote/domain/map_layout.dart';
import 'package:opennote/domain/summary_geometry.dart';
import 'package:opennote/domain/boundary_geometry.dart';

MapNode n(
  String id, {
  String? parent,
  double x = 0,
  double y = 0,
  int? side,
  int? order,
  bool collapsed = false,
}) => MapNode(
  id: id,
  mapId: 'map',
  cardId: 'card-$id',
  parentNodeId: parent,
  x: x,
  y: y,
  branchSide: side,
  sortIndex: order,
  collapsed: collapsed,
);
const s = MapSummary(
  id: 'summary',
  mapId: 'map',
  summaryNodeId: 's',
  parentNodeId: 'root',
  nodeIds: ['a', 'b'],
);
void main() {
  test('严格概要样式序列化和默认模板，非法字段与数值拒绝', () {
    const style = SummaryStyle(
      bracket: SummaryBracket.square,
      dashed: true,
      topic: BoundaryStyle(textSize: 18, bold: true),
    );
    expect(SummaryStyle.fromJson(style.toJson()), style);
    expect(SummaryStyle.fromJson({}), const SummaryStyle());
    expect(
      () => SummaryStyle.fromJson({'width': double.nan}),
      throwsFormatException,
    );
    expect(
      () => SummaryStyle.fromJson({'unknown': true}),
      throwsFormatException,
    );
    expect(
      () =>
          const SummaryStyle(topic: BoundaryStyle(fontFamily: 'invalid'))
              .validate(),
      throwsFormatException,
    );
  });
  test('动态同级范围排除概要自身，折叠子主题不纳入括号尺寸', () {
    final nodes = [
      n('root'),
      n('a', parent: 'root', order: 0, collapsed: true),
      n('s', parent: 'root', order: 1),
      n('mid', parent: 'root', order: 2),
      n('b', parent: 'root', order: 3),
      n('hidden', parent: 'a'),
    ];
    expect(summaryRoots(s, nodes, [s]).map((n) => n.id), ['a', 'mid', 'b']);
    expect(summaryMembers(s, nodes, [s], nodes.map((n) => n.id).toSet()), {
      'a',
      'mid',
      'b',
    });
  });
  test('左右上下布局概要在范围外，子主题沿概要方向，原根锚点不变', () {
    final nodes = [
      n('root', x: 80, y: 120),
      n('a', parent: 'root', order: 0),
      n('b', parent: 'root', order: 1),
      n('s', parent: 'root'),
      n('child', parent: 's'),
    ];
    for (final kind in [
      MapLayoutKind.right,
      MapLayoutKind.left,
      MapLayoutKind.down,
      MapLayoutKind.up,
    ]) {
      final plan = calculateMapLayout(nodes, kind, summaries: [s]);
      expect(plan.positions, hasLength(5));
      expect(plan.positions['root']!.x, 80);
      expect(plan.positions['root']!.y, 120);
      final summary = plan.positions['s']!,
          a = plan.positions['a']!,
          child = plan.positions['child']!;
      switch (kind) {
        case MapLayoutKind.left:
          expect(summary.x + 220, lessThan(a.x));
          expect(child.x, lessThan(summary.x));
        case MapLayoutKind.up:
          expect(summary.y + 116, lessThan(a.y));
          expect(child.y, lessThan(summary.y));
        case MapLayoutKind.down:
          expect(summary.y, greaterThan(a.y + 116));
          expect(child.y, greaterThan(summary.y));
        default:
          expect(summary.x, greaterThan(a.x + 220));
          expect(child.x, greaterThan(summary.x));
      }
    }
  });
  test('双侧概要沿左分支继续向左；概要内嵌套概要与折叠布局稳定', () {
    final left = n('a', parent: 'root', side: -1, order: 0),
        right = n('b', parent: 'root', side: 1, order: 1);
    final nodes = [
      n('root', x: 80),
      left,
      right,
      n('s', parent: 'root'),
      n('c', parent: 's'),
      n('d', parent: 's'),
      n('nested', parent: 's'),
    ];
    const leftSummary = MapSummary(
      id: 'left',
      mapId: 'map',
      summaryNodeId: 's',
      parentNodeId: 'root',
      nodeIds: ['a'],
    );
    const nested = MapSummary(
      id: 'nested',
      mapId: 'map',
      summaryNodeId: 'nested',
      parentNodeId: 's',
      nodeIds: ['c', 'd'],
    );
    final plan = calculateMapLayout(
      nodes,
      MapLayoutKind.mindMap,
      summaries: [nested, leftSummary],
    );
    expect(plan.positions, hasLength(7));
    expect(plan.positions['s']!.x, lessThan(plan.positions['a']!.x));
    expect(plan.positions['nested']!.x, lessThan(plan.positions['c']!.x));
  });
  test('双侧未指定方向时概要跟随本次自动排布方向，不使用旧坐标猜测', () {
    final nodes = [
      n('root', x: 80),
      n('a', parent: 'root', order: 0),
      n('b', parent: 'root', order: 1),
      n('s', parent: 'root'),
    ];
    const summary = MapSummary(
      id: 'summary',
      mapId: 'map',
      summaryNodeId: 's',
      parentNodeId: 'root',
      nodeIds: ['a'],
    );
    final plan = calculateMapLayout(
      nodes,
      MapLayoutKind.mindMap,
      summaries: [summary],
    );
    expect(plan.branchSides['a'], 1);
    expect(plan.positions['s']!.x, greaterThan(plan.positions['a']!.x));
  });
  test('外框与概要并存时不把新增概要主题当作范围中间的普通主题', () {
    final nodes = [
      n('root'),
      n('a', parent: 'root', order: 0),
      n('s', parent: 'root', order: 1),
      n('b', parent: 'root', order: 2),
    ];
    const boundary = MapBoundary(
      id: 'box',
      mapId: 'map',
      parentNodeId: 'root',
      nodeIds: ['a', 'b'],
    );
    expect(
      boundaryRoots(boundary, nodes, auxiliaryRoots: {'s'}).map((n) => n.id),
      ['a', 'b'],
    );
    const explicit = MapBoundary(
      id: 'box',
      mapId: 'map',
      parentNodeId: 'root',
      nodeIds: ['s'],
    );
    expect(
      boundaryRoots(explicit, nodes, auxiliaryRoots: {'s'}).single.id,
      's',
    );
  });
}
