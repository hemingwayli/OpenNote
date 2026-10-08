part of 'models.dart';

enum RelationshipShape { straight, curve, elbow }

enum RelationshipArrow { none, triangle, open, diamond, circle }

enum RelationshipColorSource { custom, from, to }

/// 控制点相对对应主题中心保存；锚点是主题矩形边界上的 0–1 坐标。
class RelationshipStyle {
  const RelationshipStyle({
    this.shape = RelationshipShape.straight,
    this.color = '#C58035',
    this.colorSource = RelationshipColorSource.custom,
    this.width = 1.4,
    this.dashed = true,
    this.startArrow = RelationshipArrow.none,
    this.endArrow = RelationshipArrow.none,
    this.labelColor = '#596579',
    this.labelSize = 14,
    this.labelBold = false,
    this.labelFont = 'Source Han Sans CN',
    this.labelItalic = false,
    this.controlFrom,
    this.controlTo,
    this.anchorFrom,
    this.anchorTo,
    this.labelOffset,
    this.curveBias = 1,
  });
  final RelationshipShape shape;
  final String color;
  final RelationshipColorSource colorSource;
  final double width;
  final bool dashed;
  final RelationshipArrow startArrow;
  final RelationshipArrow endArrow;
  final String labelColor;
  final double labelSize;
  final bool labelBold;
  final String labelFont;
  final bool labelItalic;
  final PdfPoint? controlFrom;
  final PdfPoint? controlTo;
  final PdfPoint? anchorFrom;
  final PdfPoint? anchorTo;
  final PdfPoint? labelOffset;
  final int curveBias;

  RelationshipStyle copyWith({
    RelationshipShape? shape,
    String? color,
    RelationshipColorSource? colorSource,
    double? width,
    bool? dashed,
    RelationshipArrow? startArrow,
    RelationshipArrow? endArrow,
    String? labelColor,
    double? labelSize,
    bool? labelBold,
    String? labelFont,
    bool? labelItalic,
    PdfPoint? controlFrom,
    PdfPoint? controlTo,
    PdfPoint? anchorFrom,
    PdfPoint? anchorTo,
    PdfPoint? labelOffset,
    bool resetControls = false,
    bool clearFromAnchor = false,
    bool clearToAnchor = false,
    bool resetLabelOffset = false,
  }) => RelationshipStyle(
    shape: shape ?? this.shape,
    color: color ?? this.color,
    colorSource: colorSource ?? this.colorSource,
    width: width ?? this.width,
    dashed: dashed ?? this.dashed,
    startArrow: startArrow ?? this.startArrow,
    endArrow: endArrow ?? this.endArrow,
    labelColor: labelColor ?? this.labelColor,
    labelSize: labelSize ?? this.labelSize,
    labelBold: labelBold ?? this.labelBold,
    labelFont: labelFont ?? this.labelFont,
    labelItalic: labelItalic ?? this.labelItalic,
    controlFrom: resetControls ? null : controlFrom ?? this.controlFrom,
    controlTo: resetControls ? null : controlTo ?? this.controlTo,
    anchorFrom: clearFromAnchor ? null : anchorFrom ?? this.anchorFrom,
    anchorTo: clearToAnchor ? null : anchorTo ?? this.anchorTo,
    labelOffset: resetLabelOffset ? null : labelOffset ?? this.labelOffset,
    curveBias: curveBias,
  );

  /// SQLite 仍以无向规范对保证唯一；更换规范顺序时同时交换所有端点语义。
  RelationshipStyle flipped() => RelationshipStyle(
    shape: shape,
    color: color,
    colorSource: switch (colorSource) {
      RelationshipColorSource.custom => RelationshipColorSource.custom,
      RelationshipColorSource.from => RelationshipColorSource.to,
      RelationshipColorSource.to => RelationshipColorSource.from,
    },
    width: width,
    dashed: dashed,
    startArrow: endArrow,
    endArrow: startArrow,
    labelColor: labelColor,
    labelSize: labelSize,
    labelBold: labelBold,
    labelFont: labelFont,
    labelItalic: labelItalic,
    controlFrom: controlTo,
    controlTo: controlFrom,
    anchorFrom: anchorTo,
    anchorTo: anchorFrom,
    labelOffset: labelOffset,
    curveBias: -curveBias,
  );

  Map<String, Object?> toJson() => {
    'shape': shape.name,
    'color': color,
    'colorSource': colorSource.name,
    'width': width,
    'dashed': dashed,
    'startArrow': startArrow.name,
    'endArrow': endArrow.name,
    'labelColor': labelColor,
    'labelSize': labelSize,
    'labelBold': labelBold,
    'labelFont': labelFont,
    'labelItalic': labelItalic,
    'controlFrom': ?controlFrom?.toJson(),
    'controlTo': ?controlTo?.toJson(),
    'anchorFrom': ?anchorFrom?.toJson(),
    'anchorTo': ?anchorTo?.toJson(),
    'labelOffset': ?labelOffset?.toJson(),
    'curveBias': curveBias,
  };

  factory RelationshipStyle.fromJson(Map<String, dynamic> json) {
    for (final key in json.keys) {
      if (!const {
        'shape',
        'color',
        'colorSource',
        'width',
        'dashed',
        'startArrow',
        'endArrow',
        'labelColor',
        'labelSize',
        'labelBold',
        'labelFont',
        'labelItalic',
        'controlFrom',
        'controlTo',
        'anchorFrom',
        'anchorTo',
        'labelOffset',
        'curveBias',
      }.contains(key)) {
        throw const FormatException('关联样式含未知字段');
      }
    }
    final value = RelationshipStyle(
      shape: RelationshipShape.values.byName(
        json['shape'] as String? ?? 'straight',
      ),
      color: json['color'] as String? ?? '#C58035',
      colorSource: RelationshipColorSource.values.byName(
        json['colorSource'] as String? ?? 'custom',
      ),
      width: (json['width'] as num? ?? 1.4).toDouble(),
      dashed: json['dashed'] as bool? ?? true,
      startArrow: RelationshipArrow.values.byName(
        json['startArrow'] as String? ?? 'none',
      ),
      endArrow: RelationshipArrow.values.byName(
        json['endArrow'] as String? ?? 'none',
      ),
      labelColor: json['labelColor'] as String? ?? '#596579',
      labelSize: (json['labelSize'] as num? ?? 14).toDouble(),
      labelBold: json['labelBold'] as bool? ?? false,
      labelFont: json['labelFont'] as String? ?? 'Source Han Sans CN',
      labelItalic: json['labelItalic'] as bool? ?? false,
      controlFrom: _stylePoint(json['controlFrom']),
      controlTo: _stylePoint(json['controlTo']),
      anchorFrom: _stylePoint(json['anchorFrom']),
      anchorTo: _stylePoint(json['anchorTo']),
      labelOffset: _stylePoint(json['labelOffset']),
      curveBias: json['curveBias'] as int? ?? 1,
    );
    value.validate();
    return value;
  }

  void validate() {
    final hex = RegExp(r'^#[0-9a-fA-F]{6}$');
    if (!hex.hasMatch(color) ||
        !hex.hasMatch(labelColor) ||
        !width.isFinite ||
        width < .5 ||
        width > 8 ||
        !labelSize.isFinite ||
        labelSize < 10 ||
        labelSize > 32 ||
        (curveBias != 1 && curveBias != -1) ||
        !const [
          'Source Han Sans CN',
          'Segoe UI',
          'Microsoft YaHei',
        ].contains(labelFont)) {
      throw const FormatException('关联线颜色、粗细或文字样式无效');
    }
    for (final point in [controlFrom, controlTo, labelOffset]) {
      if (point != null &&
          (!point.x.isFinite ||
              !point.y.isFinite ||
              point.x.abs() > 1000000 ||
              point.y.abs() > 1000000)) {
        throw const FormatException('关联线控制点无效');
      }
    }
    for (final point in [anchorFrom, anchorTo]) {
      if (point != null &&
          (!point.x.isFinite ||
              !point.y.isFinite ||
              point.x < 0 ||
              point.x > 1 ||
              point.y < 0 ||
              point.y > 1 ||
              !(point.x == 0 ||
                  point.x == 1 ||
                  point.y == 0 ||
                  point.y == 1))) {
        throw const FormatException('关联线端点必须位于主题边界');
      }
    }
  }

  @override
  bool operator ==(Object other) =>
      other is RelationshipStyle &&
      shape == other.shape &&
      color == other.color &&
      colorSource == other.colorSource &&
      width == other.width &&
      dashed == other.dashed &&
      startArrow == other.startArrow &&
      endArrow == other.endArrow &&
      labelColor == other.labelColor &&
      labelSize == other.labelSize &&
      labelBold == other.labelBold &&
      labelFont == other.labelFont &&
      labelItalic == other.labelItalic &&
      _sameStylePoint(controlFrom, other.controlFrom) &&
      _sameStylePoint(controlTo, other.controlTo) &&
      _sameStylePoint(anchorFrom, other.anchorFrom) &&
      _sameStylePoint(anchorTo, other.anchorTo) &&
      _sameStylePoint(labelOffset, other.labelOffset) &&
      curveBias == other.curveBias;
  @override
  int get hashCode => Object.hash(
    shape,
    color,
    colorSource,
    width,
    dashed,
    startArrow,
    endArrow,
    labelColor,
    labelSize,
    labelBold,
    labelFont,
    labelItalic,
    _stylePointHash(controlFrom),
    _stylePointHash(controlTo),
    _stylePointHash(anchorFrom),
    _stylePointHash(anchorTo),
    _stylePointHash(labelOffset),
    curveBias,
  );
}

bool _sameStylePoint(PdfPoint? a, PdfPoint? b) =>
    identical(a, b) || a != null && b != null && a.x == b.x && a.y == b.y;
int _stylePointHash(PdfPoint? point) =>
    point == null ? 0 : Object.hash(point.x, point.y);

PdfPoint? _stylePoint(Object? value) {
  if (value == null) return null;
  if (value is! Map ||
      value.length != 2 ||
      !value.containsKey('x') ||
      !value.containsKey('y')) {
    throw const FormatException('关联坐标格式无效');
  }
  return PdfPoint.fromJson(Map<String, dynamic>.from(value));
}
