import 'package:flutter_inappwebview_windows/flutter_inappwebview_windows.dart';

/// 固定 Windows 插件 0.6.0 的原生关闭协议。
/// 控制器 dispose 只清除 Dart 句柄；这里等待真实视图销毁的原生回执。
/// 此版本环境的 Dart channel 使用静态实例 ID，须按创建的环境 ID 调用。
Future<void> closeEpubWindowsView({
  required String environmentId,
  required Future<void> Function() disposeEnvironment,
}) async {
  await disposeWindowsWebViewEnvironmentViews(environmentId);
  await disposeEnvironment();
}
