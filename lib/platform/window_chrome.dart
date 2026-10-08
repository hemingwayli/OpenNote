import 'dart:ui' show AppExitType;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'window_fullscreen.dart';

/// 适配窗口外观；原生关闭请求统一交给 Flutter 可取消退出生命周期。
abstract final class WindowChrome {
  static final maximized = ValueNotifier(false);
  static final maximizeInteraction = ValueNotifier((
    hovered: false,
    pressed: false,
  ));
  static bool _listening = false;
  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  static Future<void> updateRegions(List<Map<String, double>> regions) async {
    if (!supported) return;
    if (!_listening) {
      _listening = true;
      WindowFullscreen.channel.setMethodCallHandler((call) async {
        if (call.method == 'windowState' && call.arguments is bool) {
          maximized.value = call.arguments as bool;
        } else if (call.method == 'maximizeInteraction' &&
            call.arguments is Map) {
          final state = call.arguments as Map;
          if (state['hovered'] is bool && state['pressed'] is bool) {
            maximizeInteraction.value = (
              hovered: state['hovered'] as bool,
              pressed: state['pressed'] as bool,
            );
          }
        } else if (call.method == 'requestAppExit') {
          await ServicesBinding.instance.exitApplication(
            AppExitType.cancelable,
          );
        }
      });
    }
    try {
      final value = await WindowFullscreen.channel.invokeMethod<bool>(
        'setChromeRegions',
        regions,
      );
      if (value != null) maximized.value = value;
    } on MissingPluginException {
      // 非 Windows 组件预览不创建原生窗口。
    }
  }

  static Future<void> action(String action) async {
    if (!supported) return;
    await WindowFullscreen.channel.invokeMethod<void>(action);
  }
}
