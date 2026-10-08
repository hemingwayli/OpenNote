import 'package:flutter/services.dart';

/// 窗口切换由 Windows runner 执行；返回实际状态，失败交给工作台反馈。
class WindowFullscreen {
  const WindowFullscreen();

  static const channel = MethodChannel('opennote/window');

  Future<bool> setFullscreen(bool enabled) async {
    final actual = await channel.invokeMethod<bool>('setFullscreen', enabled);
    if (actual == null) {
      throw PlatformException(code: 'invalid-fullscreen-result');
    }
    return actual;
  }
}
