import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opennote/platform/epub_webview_lifecycle.dart';
import 'package:flutter_inappwebview_windows/flutter_inappwebview_windows.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('关闭须等待原生视图回执，再释放对应环境，失败继续传播', () async {
    const view = MethodChannel(
      'com.pichillilorenzo/flutter_inappwebview_manager',
    );
    const environment = MethodChannel(
      'com.pichillilorenzo/flutter_webview_environment_created-id',
    );
    final released = Completer<void>();
    final calls = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const events = MethodChannel(
      'com.pichillilorenzo/custom_platform_view_42_events',
    );
    final creating = Completer<int>();
    messenger.setMockMethodCallHandler(events, (_) async => null);
    messenger.setMockMethodCallHandler(view, (call) async {
      if (call.method == 'createInAppWebView') return await creating.future;
      expect(call.arguments, {'id': 42});
      calls.add('view');
      await released.future;
      return null;
    });
    messenger.setMockMethodCallHandler(environment, (call) async {
      calls.add('environment');
      return null;
    });
    try {
      final native = CustomPlatformViewController();
      final created = native.initialize(
        arguments: {'webViewEnvironmentId': 'created-id'},
      );
      var completed = false;
      final close = closeEpubWindowsView(
        environmentId: 'created-id',
        disposeEnvironment: () => environment.invokeMethod<void>('dispose'),
      ).then((_) => completed = true);
      final widgetDisposal = native.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(calls, isEmpty);
      creating.complete(42);
      await created;
      await Future<void>.delayed(Duration.zero);
      expect(calls, ['view']);
      expect(completed, isFalse);
      released.complete();
      await close;
      await widgetDisposal;
      expect(calls, ['view', 'environment']);
      await expectLater(closeEpubWindowsView(environmentId:'created-id',disposeEnvironment:() async {
        throw PlatformException(code:'native-environment-close-failed');
      }),throwsA(isA<PlatformException>()));
    } finally {
      messenger.setMockMethodCallHandler(view, null);
      messenger.setMockMethodCallHandler(environment, null);
      messenger.setMockMethodCallHandler(events, null);
    }
  });
}
