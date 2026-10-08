import 'package:flutter_test/flutter_test.dart';
import 'package:opennote/domain/models.dart';
import 'package:opennote/domain/boundary_geometry.dart';

void main() {
  test('外框样式完整往返、默认兼容及非法值拒绝', () {
    const style = BoundaryStyle(
      shape: BoundaryShape.ellipse,
      fillOpacity: .2,
      color: '#3574CB',
      width: 3,
      dashed: true,
      bold: true,
      italic: true,
      textSize: 18,
    );
    expect(BoundaryStyle.fromJson(style.toJson()), style);
    expect(BoundaryStyle.fromJson({}), const BoundaryStyle());
    for (final json in [
      {'fillOpacity': 2},
      {'textSize': double.nan},
      {'color': 'red'},
      {'width': 0},
      {'bold': 1},
      {'shape': 'unknown'},
      {'extra': false},
    ]) {
      expect(() => BoundaryStyle.fromJson(json), throwsA(anything));
    }
  });
  test('范围覆盖首尾间新插入主题及可见后代，折叠父隐藏整个外框', () {
    const boundary = MapBoundary(
      id: 'box',
      mapId: 'map',
      parentNodeId: 'root',
      nodeIds: ['a', 'c'],
    );
    final nodes = [
      _node('root', null, 0),
      _node('a', 'root', 0),
      _node('b', 'root', 1),
      _node('c', 'root', 2),
      _node('child', 'a', 0),
    ];
    expect(boundaryRoots(boundary, nodes).map((n) => n.id), ['a', 'b', 'c']);
    expect(boundaryMembers(boundary, nodes, nodes.map((n) => n.id).toSet()), {
      'a',
      'b',
      'c',
      'child',
    });
    expect(boundaryMembers(boundary, nodes, {'root'}), isEmpty);
    expect(boundaryMembers(boundary, nodes, {'root', 'a', 'b', 'c'}), {
      'a',
      'b',
      'c',
    });
  });
}

MapNode _node(String id, String? parent, int index) => MapNode(
  id: id,
  mapId: 'map',
  cardId: id,
  parentNodeId: parent,
  sortIndex: index,
  x: index * 240,
  y: 0,
);
