part of 'models.dart';

enum BranchPath { curve, straight, elbow }

enum BranchEnd { none, arrow }

/// 分支线属于主题的显示格式，不改变父子关系或关联线。
class BranchStyle {
  const BranchStyle({
    this.path = BranchPath.curve,
    this.color = '#B8C5D2',
    this.width = 1.4,
    this.dashed = false,
    this.followCardColor = false,
    this.start = BranchEnd.none,
    this.end = BranchEnd.none,
  });
  final BranchPath path;
  final String color;
  final double width;
  final bool dashed, followCardColor;
  final BranchEnd start, end;
  BranchStyle copyWith({
    BranchPath? path,
    String? color,
    double? width,
    bool? dashed,
    bool? followCardColor,
    BranchEnd? start,
    BranchEnd? end,
  }) => BranchStyle(
    path: path ?? this.path,
    color: color ?? this.color,
    width: width ?? this.width,
    dashed: dashed ?? this.dashed,
    followCardColor: followCardColor ?? this.followCardColor,
    start: start ?? this.start,
    end: end ?? this.end,
  );
  void validate() {
    if (!RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(color) ||
        !width.isFinite ||
        width < .5 ||
        width > 8) {
      throw const FormatException('分支样式无效');
    }
  }

  Map<String, Object> toJson() => {
    'path': path.name,
    'color': color,
    'width': width,
    'dashed': dashed,
    'followCardColor': followCardColor,
    'start': start.name,
    'end': end.name,
  };
  factory BranchStyle.fromJson(Map<String, dynamic> json) {
    const defaults = BranchStyle();
    if (json.keys.any((key) => !defaults.toJson().containsKey(key))) {
      throw const FormatException('未知分支样式字段');
    }
    final result = BranchStyle(
      path: BranchPath.values.byName(
        json['path'] as String? ?? defaults.path.name,
      ),
      color: json['color'] as String? ?? defaults.color,
      width: (json['width'] as num?)?.toDouble() ?? defaults.width,
      dashed: json['dashed'] as bool? ?? defaults.dashed,
      followCardColor:
          json['followCardColor'] as bool? ?? defaults.followCardColor,
      start: BranchEnd.values.byName(
        json['start'] as String? ?? defaults.start.name,
      ),
      end: BranchEnd.values.byName(json['end'] as String? ?? defaults.end.name),
    );
    result.validate();
    return result;
  }
  @override
  bool operator ==(Object other) =>
      other is BranchStyle &&
      path == other.path &&
      color == other.color &&
      width == other.width &&
      dashed == other.dashed &&
      followCardColor == other.followCardColor &&
      start == other.start &&
      end == other.end;
  @override
  int get hashCode =>
      Object.hash(path, color, width, dashed, followCardColor, start, end);
}

/// 普通主题格式与卡片颜色分开；未覆盖的主题使用脑图默认格式。
class TopicStyle {
  const TopicStyle({
    this.surface = const BoundaryStyle(
      fill: '#FFFFFF',
      fillOpacity: 1,
      color: '#E1E5EA',
      width: 1,
      textColor: '#262B33',
      textSize: 15,
      bold: true,
    ),
    this.branch = const BranchStyle(),
  });
  final BoundaryStyle surface;
  final BranchStyle branch;
  TopicStyle copyWith({BoundaryStyle? surface, BranchStyle? branch}) =>
      TopicStyle(
        surface: surface ?? this.surface,
        branch: branch ?? this.branch,
      );
  void validate() {
    surface.validate();
    branch.validate();
  }

  Map<String, Object> toJson() => {
    'surface': surface.toJson(),
    'branch': branch.toJson(),
  };
  factory TopicStyle.fromJson(Map<String, dynamic> json) {
    const defaults = TopicStyle();
    if (json.keys.any((key) => !defaults.toJson().containsKey(key))) {
      throw const FormatException('未知主题样式字段');
    }
    final result = TopicStyle(
      surface: json['surface'] == null
          ? defaults.surface
          : BoundaryStyle.fromJson(
              Map<String, dynamic>.from(json['surface'] as Map),
            ),
      branch: json['branch'] == null
          ? defaults.branch
          : BranchStyle.fromJson(
              Map<String, dynamic>.from(json['branch'] as Map),
            ),
    );
    result.validate();
    return result;
  }
  @override
  bool operator ==(Object other) =>
      other is TopicStyle && surface == other.surface && branch == other.branch;
  @override
  int get hashCode => Object.hash(surface, branch);
}
