import '../domain/map_clipboard.dart';

/// 一次应用会话内共享；系统剪贴板文本或资料库会话改变后不再使用内部来源记录。
class MapClipboardController {
  MapClipboardContent? content;
  String? sessionId;
  bool cut = false;
  void store(MapClipboardContent value, String session, {required bool isCut}) {
    content = value;
    sessionId = session;
    cut = isCut;
  }

  MapClipboardContent? matching(String text, String session) =>
      sessionId == session && content?.text == text ? content : null;
  void clear() {
    content = null;
    sessionId = null;
    cut = false;
  }
}
