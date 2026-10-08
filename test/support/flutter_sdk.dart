import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

/// 与开发入口一致，个人 SDK 位置仅从环境或忽略的本地配置读取。
String flutterSdkPath() {
  var selected = Platform.environment['OPENNOTE_FLUTTER_ROOT'];
  final local = File('.local/toolchain.json');
  if ((selected == null || selected.isEmpty) && local.existsSync()) {
    selected =
        (jsonDecode(local.readAsStringSync(encoding: utf8))
                as Map<String, dynamic>)['sdkPath']
            as String?;
  }
  if (selected == null || selected.isEmpty) {
    selected =
        (jsonDecode(
              File('tools/toolchain-lock.json')
                  .readAsStringSync(encoding: utf8),
            ) as Map<String, dynamic>)['sdkPath']
            as String?;
  }
  if (selected == null || selected.isEmpty) {
    throw StateError('请按构建说明准备锁定的 Flutter SDK。');
  }
  return path.normalize(path.absolute(selected));
}
