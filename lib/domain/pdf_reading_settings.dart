/// 每份 PDF 的目录偏好；窗口临时变窄不改变保存的宽度。
class PdfReadingSettings {
  const PdfReadingSettings({
    this.sidebarVisible = false,
    this.sidebarWidth = 220,
  });

  final bool sidebarVisible;
  final double sidebarWidth;

  Map<String, Object> toJson() => {
    'sidebarVisible': sidebarVisible,
    'sidebarWidth': sidebarWidth,
  };

  factory PdfReadingSettings.fromJson(Map<String, dynamic> value) {
    final visible = value['sidebarVisible'] ?? false;
    final width = value['sidebarWidth'] ?? 220;
    if (visible is! bool ||
        width is! num ||
        !width.isFinite ||
        width < 120 ||
        width > 440) {
      throw const FormatException('PDF 目录设置不合法。');
    }
    return PdfReadingSettings(
      sidebarVisible: visible,
      sidebarWidth: width.toDouble(),
    );
  }
}
