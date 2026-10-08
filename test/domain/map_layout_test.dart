import 'package:flutter_test/flutter_test.dart';
import 'package:opennote/domain/map_layout.dart';
import 'package:opennote/domain/models.dart';

void main() {
  for (final kind in MapLayoutKind.values.where(
    (kind) => kind != MapLayoutKind.free && !kind.extended,
  )) {
    test('结构几何 ${kind.name}：固定中心、可变尺寸不重叠、同级顺序稳定', () {
      final nodes = [
        _node('root', x: 91, y: 143),
        _node('a', parent: 'root', order: 0, width: 340, height: 170),
        _node('b', parent: 'root', order: 1, width: 190, height: 90),
        _node('c', parent: 'a', order: 0, width: 300, height: 220),
        _node('d', parent: 'a', order: 1, width: 180, height: 75),
        _node('e', parent: 'b', order: 0),
      ];
      final plan = calculateMapLayout(nodes.reversed.toList(), kind);
      expect(plan.positions.length, nodes.length);
      expect(plan.positions['root']!.x, 91);
      expect(plan.positions['root']!.y, 143);
      for (final first in nodes) {
        final a = plan.positions[first.id]!;
        expect(a.x.isFinite && a.y.isFinite, isTrue);
        for (final second in nodes.where((n) => n.id != first.id)) {
          final b = plan.positions[second.id]!;
          final overlap =
              a.x < b.x + second.width &&
              a.x + first.width > b.x &&
              a.y < b.y + second.height &&
              a.y + first.height > b.y;
          expect(overlap, isFalse, reason: '${first.id} 与 ${second.id} 重叠');
        }
      }
      final root = plan.positions['root']!;
      final a = plan.positions['a']!;
      final b = plan.positions['b']!;
      switch (kind) {
        case MapLayoutKind.right:
          expect(a.x, greaterThan(root.x + nodes.first.width));
          expect(a.y, lessThan(b.y));
        case MapLayoutKind.left:
          expect(a.x + nodes[1].width, lessThan(root.x));
          expect(a.y, lessThan(b.y));
        case MapLayoutKind.down:
          expect(a.y, greaterThan(root.y + nodes.first.height));
          expect(a.x, lessThan(b.x));
        case MapLayoutKind.up:
          expect(a.y + nodes[1].height, lessThan(root.y));
          expect(a.x, lessThan(b.x));
        case MapLayoutKind.mindMap:
          expect(plan.branchSides.values.toSet(), {-1, 1});
          expect((a.x < root.x) != (b.x < root.x), isTrue);
        case MapLayoutKind.free:
          fail('结构用例不包含自由布局');
        default:
          fail('扩展结构由对应几何用例验证');
      }
    });
  }

  test('双侧布局固定已有方向，新分支不使原有分支跳到另一侧', () {
    final plan = calculateMapLayout([
      _node('root'),
      _node('left', parent: 'root', order: 0, side: -1),
      _node('right', parent: 'root', order: 1, side: 1),
      _node('new', parent: 'root', order: 2),
      _node('child', parent: 'left'),
    ], MapLayoutKind.mindMap);
    expect(plan.branchSides['left'], -1);
    expect(plan.branchSides['right'], 1);
    expect(plan.positions['child']!.x, lessThan(plan.positions['left']!.x));
  });

  test('折叠不改写隐藏坐标，多个中心主题的整棵树保持分离', () {
    final nodes = [
      _node('first', x: 33, y: 44, order: 0, collapsed: true),
      _node('hidden', parent: 'first', x: 789, y: 456),
      _node('second', order: 1),
      _node('visible', parent: 'second'),
    ];
    final plan = calculateMapLayout(nodes, MapLayoutKind.down);
    expect(plan.positions.containsKey('hidden'), isFalse);
    expect(nodes[1].x, 789);
    expect(plan.positions['second']!.y, greaterThan(44 + nodes.first.height));
    expect(
      plan.positions['visible']!.y,
      greaterThan(plan.positions['second']!.y),
    );
  });

  test('2500 层使用迭代遍历，隐藏循环仍拒绝，自由布局不改变坐标', () {
    final nodes = [
      for (var i = 0; i < 2500; i++)
        _node('$i', parent: i == 0 ? null : '${i - 1}'),
    ];
    expect(
      calculateMapLayout(nodes, MapLayoutKind.left).positions.length,
      2500,
    );
    expect(calculateMapLayout(nodes, MapLayoutKind.free).positions, isEmpty);
    expect(
      () => calculateMapLayout([
        _node('root', collapsed: true),
        _node('a', parent: 'b'),
        _node('b', parent: 'a'),
      ], MapLayoutKind.right),
      throwsStateError,
    );
  });
}

MapNode _node(
  String id, {
  String? parent,
  int? order,
  int? side,
  double x = 0,
  double y = 0,
  double width = 220,
  double height = 116,
  bool collapsed = false,
}) => MapNode(
  id: id,
  mapId: 'map',
  cardId: 'card-$id',
  parentNodeId: parent,
  x: x,
  y: y,
  width: width,
  height: height,
  collapsed: collapsed,
  sortIndex: order,
  branchSide: side,
);
