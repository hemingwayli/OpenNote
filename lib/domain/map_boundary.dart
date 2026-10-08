part of 'models.dart';

enum BoundaryShape { rounded, rectangle, ellipse }

/// 外框是脑图的独立组织对象，不把分组说明写入卡片正文。
class MapBoundary {
  const MapBoundary({
    required this.id,
    required this.mapId,
    required this.nodeIds,
    this.parentNodeId,
    this.label = '',
    this.style = const BoundaryStyle(),
  });
  final String id, mapId, label;
  final String? parentNodeId;
  final List<String> nodeIds;
  final BoundaryStyle style;
}

class BoundaryStyle {
  const BoundaryStyle({
    this.shape = BoundaryShape.rounded,
    this.fill = '#EAF1FC',
    this.fillOpacity = .65,
    this.color = '#8BA7D0',
    this.width = 1.4,
    this.dashed = false,
    this.textColor = '#596579',
    this.textSize = 14,
    this.bold = false,
    this.italic = false,
    this.fontFamily = 'Source Han Sans CN',
  });
  final BoundaryShape shape;
  final String fill, color, textColor, fontFamily;
  final double fillOpacity, width, textSize;
  final bool dashed, bold, italic;
  BoundaryStyle copyWith({
    BoundaryShape? shape,
    String? fill,
    double? fillOpacity,
    String? color,
    double? width,
    bool? dashed,
    String? textColor,
    double? textSize,
    bool? bold,
    bool? italic,
    String? fontFamily,
  }) => BoundaryStyle(
    shape: shape ?? this.shape,
    fill: fill ?? this.fill,
    fillOpacity: fillOpacity ?? this.fillOpacity,
    color: color ?? this.color,
    width: width ?? this.width,
    dashed: dashed ?? this.dashed,
    textColor: textColor ?? this.textColor,
    textSize: textSize ?? this.textSize,
    bold: bold ?? this.bold,
    italic: italic ?? this.italic,
    fontFamily: fontFamily ?? this.fontFamily,
  );
  void validate() {
    final hex = RegExp(r'^#[0-9a-fA-F]{6}$');
    if (![fill, color, textColor].every(hex.hasMatch) ||
        !fillOpacity.isFinite ||
        fillOpacity < 0 ||
        fillOpacity > 1 ||
        !width.isFinite ||
        width < .5 ||
        width > 8 ||
        !textSize.isFinite ||
        textSize < 10 ||
        textSize > 32 ||
        ![
          'Source Han Sans CN',
          'Segoe UI',
          'Microsoft YaHei',
        ].contains(fontFamily)) {
      throw const FormatException('外框样式无效');
    }
  }

  Map<String, Object> toJson() => {
    'shape': shape.name,
    'fill': fill,
    'fillOpacity': fillOpacity,
    'color': color,
    'width': width,
    'dashed': dashed,
    'textColor': textColor,
    'textSize': textSize,
    'bold': bold,
    'italic': italic,
    'fontFamily': fontFamily,
  };
  factory BoundaryStyle.fromJson(Map<String, dynamic> json) {
    const defaults = BoundaryStyle();
    if (json.keys.any((key) => !defaults.toJson().containsKey(key))) {
      throw const FormatException('未知外框样式字段');
    }
    final result = BoundaryStyle(
      shape: BoundaryShape.values.byName(
        json['shape'] as String? ?? defaults.shape.name,
      ),
      fill: json['fill'] as String? ?? defaults.fill,
      fillOpacity:
          (json['fillOpacity'] as num?)?.toDouble() ?? defaults.fillOpacity,
      color: json['color'] as String? ?? defaults.color,
      width: (json['width'] as num?)?.toDouble() ?? defaults.width,
      dashed: json['dashed'] as bool? ?? defaults.dashed,
      textColor: json['textColor'] as String? ?? defaults.textColor,
      textSize: (json['textSize'] as num?)?.toDouble() ?? defaults.textSize,
      bold: json['bold'] as bool? ?? defaults.bold,
      italic: json['italic'] as bool? ?? defaults.italic,
      fontFamily: json['fontFamily'] as String? ?? defaults.fontFamily,
    );
    result.validate();
    return result;
  }
  @override
  bool operator ==(Object other) =>
      other is BoundaryStyle &&
      shape == other.shape &&
      fill == other.fill &&
      fillOpacity == other.fillOpacity &&
      color == other.color &&
      width == other.width &&
      dashed == other.dashed &&
      textColor == other.textColor &&
      textSize == other.textSize &&
      bold == other.bold &&
      italic == other.italic &&
      fontFamily == other.fontFamily;
  @override
  int get hashCode => Object.hash(
    shape,
    fill,
    fillOpacity,
    color,
    width,
    dashed,
    textColor,
    textSize,
    bold,
    italic,
    fontFamily,
  );
}
