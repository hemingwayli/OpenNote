import 'package:flutter_driver/driver_extension.dart';
import 'package:opennote/main.dart' as app;

/// 仅用于官方 Dart MCP 的真实窗口交互验收，强制使用独立资料库。
Future<void> main(List<String> arguments) async {
  if (!arguments.any((value) => value.startsWith('--data-dir='))) {
    throw ArgumentError('项目首页运行验收必须提供独立 --data-dir');
  }
  enableFlutterDriverExtension();
  await app.main(arguments);
}
