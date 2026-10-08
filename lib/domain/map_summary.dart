part of 'models.dart';

enum SummaryBracket { brace, square, curve }

/// 概要范围独立保存，文字和子主题仍使用正常卡片与节点。
class MapSummary {
  const MapSummary({
    required this.id,
    required this.mapId,
    required this.summaryNodeId,
    required this.nodeIds,
    this.parentNodeId,
    this.style = const SummaryStyle(),
  });
  final String id, mapId, summaryNodeId;
  final String? parentNodeId;
  final List<String> nodeIds;
  final SummaryStyle style;
}

class SummaryStyle {
  const SummaryStyle({
    this.bracket = SummaryBracket.brace,
    this.color = '#8BA7D0',
    this.width = 1.4,
    this.dashed = false,
    this.branch,
    this.topic = const BoundaryStyle(
      fill: '#F3F6FC',
      fillOpacity: 1,
      textColor: '#262B33',
      textSize: 15,
      bold: true,
    ),
  });
  final SummaryBracket bracket;
  final String color;
  final double width;
  final bool dashed;
  final BranchStyle? branch;
  BranchStyle get effectiveBranch =>
      branch ?? BranchStyle(color: color, width: width, dashed: dashed);
  // 共用已验证的表面／文字样式值，范围与概要主题身份保持独立。
  final BoundaryStyle topic;
  SummaryStyle copyWith({
    SummaryBracket? bracket,
    String? color,
    double? width,
    bool? dashed,
    BoundaryStyle? topic,
    BranchStyle? branch,
  }) => SummaryStyle(
    bracket: bracket ?? this.bracket,
    color: color ?? this.color,
    width: width ?? this.width,
    dashed: dashed ?? this.dashed,
    topic: topic ?? this.topic,
    branch: branch ?? this.branch,
  );
  void validate() {
    topic.validate();
    branch?.validate();
    if (!RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(color) ||
        !width.isFinite ||
        width < .5 ||
        width > 8) {
      throw const FormatException('概要样式无效');
    }
  }

  Map<String, Object> toJson() => {
    'bracket': bracket.name,
    'color': color,
    'width': width,
    'dashed': dashed,
    'topic': topic.toJson(),
    if (branch != null) 'branch': branch!.toJson(),
  };
  factory SummaryStyle.fromJson(Map<String, dynamic> json) {
    const defaults = SummaryStyle();
    if (json.keys.any(
      (key) => !defaults.toJson().containsKey(key) && key != 'branch',
    )) {
      throw const FormatException('未知概要样式字段');
    }
    final style = SummaryStyle(
      bracket: SummaryBracket.values.byName(
        json['bracket'] as String? ?? defaults.bracket.name,
      ),
      color: json['color'] as String? ?? defaults.color,
      width: (json['width'] as num?)?.toDouble() ?? defaults.width,
      dashed: json['dashed'] as bool? ?? defaults.dashed,
      topic: json['topic'] == null
          ? defaults.topic
          : BoundaryStyle.fromJson(
              Map<String, dynamic>.from(json['topic'] as Map),
            ),
      branch: json['branch'] == null
          ? null
          : BranchStyle.fromJson(
              Map<String, dynamic>.from(json['branch'] as Map),
            ),
    );
    style.validate();
    return style;
  }
  @override
  bool operator ==(Object other) =>
      other is SummaryStyle &&
      bracket == other.bracket &&
      color == other.color &&
      width == other.width &&
      dashed == other.dashed &&
      topic == other.topic &&
      branch == other.branch;
  @override
  int get hashCode => Object.hash(bracket, color, width, dashed, topic, branch);
}
