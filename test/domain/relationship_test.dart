import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:opennote/domain/models.dart';
import 'package:opennote/domain/relationship_geometry.dart';

void main() {
  test('关联样式旧默认及 JSON 往返保留所有端点与文字字段', () {
    expect(RelationshipStyle.fromJson({}), const RelationshipStyle());
    const style = RelationshipStyle(
      shape: RelationshipShape.curve,
      color: '#3574CB',
      colorSource: RelationshipColorSource.from,
      width: 3,
      dashed: false,
      startArrow: RelationshipArrow.circle,
      endArrow: RelationshipArrow.triangle,
      labelColor: '#262B33',
      labelSize: 18,
      labelBold: true,
      labelItalic: true,
      labelFont: 'Segoe UI',
      controlFrom: PdfPoint(90, -70),
      controlTo: PdfPoint(-60, 150),
      anchorFrom: PdfPoint(1, .3),
      anchorTo: PdfPoint(0, .7),
      labelOffset: PdfPoint(12, -24),
    );
    final restored = RelationshipStyle.fromJson(
      jsonDecode(jsonEncode(style.toJson())) as Map<String, dynamic>,
    );
    expect(restored, style);
    expect(restored.hashCode, style.hashCode);
    expect(style.flipped().flipped(), style);
    expect(style.flipped().colorSource, RelationshipColorSource.to);
  });

  test('关联样式拒绝非法颜色、数值、中心锚点与未知字段', () {
    for (final invalid in [
      {'unknown': true},
      {'color': '#XX1122'},
      {'width': 0},
      {'width': double.infinity},
      {'labelSize': 33},
      {'shape': 'bad'},
      {'labelFont': 'unavailable'},
      {'curveBias': 0},
      {
        'anchorFrom': {'x': .5, 'y': .5},
      },
      {
        'controlFrom': {'x': 1, 'y': double.nan},
      },
      {
        'controlTo': {'x': 1, 'y': 2, 'extra': 3},
      },
    ]) {
      expect(
        () => RelationshipStyle.fromJson(invalid),
        throwsA(anyOf(isA<FormatException>(), isA<ArgumentError>())),
        reason: '$invalid',
      );
    }
  });

  test('规范端点对调不反转可见曲线、说明位置或箭头语义', () {
    for (final shape in RelationshipShape.values) {
      for (final manual in [false, true]) {
        final style = RelationshipStyle(
          shape: shape,
          startArrow: RelationshipArrow.open,
          endArrow: RelationshipArrow.triangle,
          controlFrom: manual ? const PdfPoint(95, 110) : null,
          controlTo: manual ? const PdfPoint(-60, 50) : null,
          anchorFrom: manual ? const PdfPoint(1, .2) : null,
          anchorTo: manual ? const PdfPoint(0, .8) : null,
          labelOffset: const PdfPoint(20, -10),
        );
        final original = relationshipGeometry(
          _node('a', 0, 0),
          _node('b', 350, 160),
          style,
        );
        final flipped = relationshipGeometry(
          _node('b', 350, 160),
          _node('a', 0, 0),
          style.flipped(),
        );
        for (final t in [0.0, .2, .5, .8, 1.0]) {
          _near(original.point(t), flipped.point(1 - t));
        }
        _near(original.label, flipped.label);
        expect(style.flipped().endArrow, style.startArrow);
      }
    }
  });

  test('手动控制点跟随对应主题、端点按比例留在边界', () {
    const style = RelationshipStyle(
      shape: RelationshipShape.curve,
      controlFrom: PdfPoint(80, -50),
      anchorFrom: PdfPoint(1, .25),
    );
    final before = relationshipGeometry(
      _node('a', 0, 0),
      _node('b', 350, 160),
      style,
    );
    final after = relationshipGeometry(
      _node('a', 40, 70, width: 300),
      _node('b', 350, 160),
      style,
    );
    _near(after.start, const PdfPoint(340, 99));
    _near(
      after.controlFrom,
      PdfPoint(before.controlFrom.x + 80, before.controlFrom.y + 70),
    );
    expect(
      relationshipAnchorAt(
        _node('a', 10, 20),
        const PdfPoint(500, 60),
      ).toJson(),
      {'x': 1.0, 'y': 40 / 116},
    );
  });

  test('曲线命中使用曲线本身，折线中点按路径长度定位', () {
    final curve = relationshipGeometry(
      _node('a', 0, 0),
      _node('b', 500, 0),
      const RelationshipStyle(
        shape: RelationshipShape.curve,
        controlFrom: PdfPoint(180, 220),
        controlTo: PdfPoint(-180, 220),
      ),
    );
    expect(curve.distanceTo(curve.point(.5)), closeTo(0, .001));
    expect(curve.distanceTo(const PdfPoint(360, 58)), greaterThan(100));
    final elbow = relationshipGeometry(
      _node('a', 0, 0),
      _node('b', 500, 240),
      const RelationshipStyle(shape: RelationshipShape.elbow),
    );
    expect(elbow.distanceTo(elbow.point(.5)), closeTo(0, .001));
    expect(elbow.corners, hasLength(2));
  });

  test('重叠主题的曲线与端点仍为有限坐标', () {
    for (final shape in RelationshipShape.values) {
      final geometry = relationshipGeometry(
        _node('a', 0, 0),
        _node('b', 0, 0),
        RelationshipStyle(shape: shape),
      );
      expect(
        geometry.samples.every((p) => p.x.isFinite && p.y.isFinite),
        isTrue,
      );
      expect(geometry.distanceTo(geometry.start), closeTo(0, .001));
    }
  });
}

MapNode _node(String id, double x, double y, {double width = 220}) => MapNode(
  id: id,
  mapId: 'map',
  cardId: 'card-$id',
  x: x,
  y: y,
  width: width,
  height: 116,
);
void _near(PdfPoint actual, PdfPoint expected) {
  expect(actual.x, closeTo(expected.x, 1e-8));
  expect(actual.y, closeTo(expected.y, 1e-8));
}
