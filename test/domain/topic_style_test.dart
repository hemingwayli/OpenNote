import 'package:flutter_test/flutter_test.dart';
import 'package:opennote/domain/models.dart';
import 'package:opennote/domain/topic_style_resolver.dart';

void main() {
  test('主题与分支格式严格序列化；错误类型、未知字段、非有限尺寸拒绝', () {
    final style = TopicStyle(
      surface: const TopicStyle().surface.copyWith(
        textSize: 24,
        italic: true,
        shape: BoundaryShape.ellipse,
      ),
      branch: const BranchStyle(
        path: BranchPath.elbow,
        end: BranchEnd.arrow,
        followCardColor: true,
      ),
    );
    expect(TopicStyle.fromJson(style.toJson()), style);
    for (final invalid in [
      <String, dynamic>{'unknown': 1},
      {
        'branch': {'width': double.nan},
      },
      {
        'branch': {'dashed': 'true'},
      },
      {
        'surface': {'textSize': 100},
      },
      {
        'surface': {'fill': '#xyzxyz'},
      },
    ]) {
      expect(() => TopicStyle.fromJson(invalid), throwsA(anything));
    }
  });
  test('默认、精确覆盖与概要分支继承使用唯一解析；折叠不改格式归属', () {
    const custom = TopicStyle(branch: BranchStyle(color: '#3574CB'));
    final nodes = [
      const MapNode(id: 'root', mapId: 'm', cardId: 'r', x: 0, y: 0),
      const MapNode(
        id: 'a',
        mapId: 'm',
        cardId: 'a',
        parentNodeId: 'root',
        x: 0,
        y: 0,
      ),
      const MapNode(
        id: 's',
        mapId: 'm',
        cardId: 's',
        parentNodeId: 'root',
        x: 0,
        y: 0,
        collapsed: true,
      ),
      const MapNode(
        id: 'child',
        mapId: 'm',
        cardId: 'c',
        parentNodeId: 's',
        x: 0,
        y: 0,
      ),
      const MapNode(
        id: 'explicit',
        mapId: 'm',
        cardId: 'e',
        parentNodeId: 'child',
        x: 0,
        y: 0,
        style: custom,
      ),
    ];
    final defaultStyle = const TopicStyle().copyWith(
      surface: const TopicStyle().surface.copyWith(textSize: 18),
    );
    final snapshot = MapSnapshot(
      map: MindMap(
        id: 'm',
        projectId: 'p',
        title: '图',
        defaultStyle: defaultStyle,
      ),
      nodes: nodes,
      cards: const {},
      anchors: const {},
      edges: const [],
      summaries: const [
        MapSummary(
          id: 'sum',
          mapId: 'm',
          summaryNodeId: 's',
          parentNodeId: 'root',
          nodeIds: ['a'],
          style: SummaryStyle(
            branch: BranchStyle(path: BranchPath.straight, color: '#262B33'),
          ),
        ),
      ],
    );
    final styles = topicStylesFor(snapshot);
    expect(styles['root'], defaultStyle);
    expect(styles['child']!.surface, defaultStyle.surface);
    expect(styles['child']!.branch.color, '#262B33');
    expect(styles['s']!.surface.fill, '#F3F6FC');
    expect(styles['explicit'], custom);
    expect(topicStyleFor(snapshot, nodes.last), custom);
  });
}
