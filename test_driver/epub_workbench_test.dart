import 'dart:convert';
import 'dart:io';

import 'package:flutter_driver/flutter_driver.dart';

Future<void> main() async {
  final driver = await FlutterDriver.connect();
  final results = <Map<String, dynamic>>[];
  Future<void> tap(
    SerializableFinder finder, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    stdout.writeln('原生工作台点击：${finder.serialize()}');
    await driver.tap(finder, timeout: timeout);
  }

  Future<dynamic> action(
    String name, [
    Map<String, dynamic> values = const {},
  ]) async => jsonDecode(
    await driver.requestData(
      jsonEncode({'action': name, ...values}),
      timeout: const Duration(minutes: 2),
    ),
  );
  Future<Map<String, dynamic>> state() async =>
      Map<String, dynamic>.from(await action('state') as Map);
  Future<Map<String, dynamic>> until(
    bool Function(Map<String, dynamic>) check,
  ) async {
    final deadline = DateTime.now().add(const Duration(minutes: 2));
    while (DateTime.now().isBefore(deadline)) {
      final data = await state();
      if (check(data)) return data;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    throw StateError('真实工作台状态等待超时');
  }

  Future<void> command(
    String name, [
    Map<String, dynamic> values = const {},
  ]) async {
    final value = await driver.requestData(
      jsonEncode({'action': name, ...values}),
      timeout: const Duration(minutes: 2),
    );
    if (value != 'passed') throw StateError('$name: $value');
  }

  final directory = Directory('.local/verification/epub-pdf/workbench');
  await directory.create(recursive: true);
  try {
    await until((s) => (s['ready'] as int) > 0);
    await driver.runUnsynchronized(() async {
      var current = await until(
        (s) => (s['ready'] as int) > 0 && (s['indexed'] as int) > 0,
      );
      final selection = await action('select') as Map;
      final source = await driver.getCenter(
        find.byValueKey('epub-excerpt-action'),
      );
      final target = await driver.getCenter(
        find.byType('MindMapPane'),
        timeout: const Duration(seconds: 20),
      );
      await driver.scroll(
        find.byValueKey('epub-excerpt-action'),
        target.dx - source.dx,
        target.dy - source.dy,
        const Duration(seconds: 1),
      );
      current = await until((s) => (s['cards'] as List).length == 1);
      results.add({'step': '真实选文经 Flutter 拖拽提交卡片与脑图', 'passed': true});
      await tap(find.byTooltip('更多阅读工具'));
      await tap(find.text('阅读设置'));
      await driver.scroll(
        find.byValueKey('epub-font-size-slider'),
        80,
        0,
        const Duration(milliseconds: 300),
      );
      await tap(find.text('应用'));
      current = await until(
        (s) =>
            s['settings'] != null && (s['settings'] as Map)['fontSize'] != 18,
      );
      await command('verifySources');
      results.add({'step': '改变字号后 CFI 与原选文仍一致', 'passed': true});
      await command('screenshot', {'name': 'epub-reflow'});
      await tap(find.byValueKey('document-tab-${current['pdf']}'));
      await until((s) => s['active'] == s['pdf']);
      final node = (current['nodes'] as List).first as Map;
      await tap(find.byValueKey('map-node-${node['id']}'));
      current = await until(
        (s) => s['active'] == s['epub'] && (s['ready'] as int) >= 2,
      );
      await command('verifySources');
      results.add({'step': 'PDF 标签切换后脑图回源打开 EPUB', 'passed': true});
      await tap(
        find.byTooltip('搜索 Ctrl+F'),
        timeout: const Duration(seconds: 20),
      );
      await tap(find.byValueKey('search-input'));
      await driver.enterText(selection['quote'] as String);
      await driver.waitFor(
        find.byValueKey('search-result-0'),
        timeout: const Duration(seconds: 20),
      );
      final searchTarget =
          await action('searchTarget', {'query': selection['quote']}) as Map;
      await driver.scrollIntoView(
        find.byValueKey('search-result-${searchTarget['index']}'),
      );
      await tap(find.byValueKey('search-result-${searchTarget['index']}'));
      await driver.waitForAbsent(find.byValueKey('search-input'));
      await command('verifySources');
      results.add({'step': '真实书籍正文建立索引、搜索并点击原文回源', 'passed': true});
      await tap(find.byValueKey('workspace-document-${current['media']}'));
      current = await until(
        (s) =>
            s['active'] == s['media'] && s['webRevision'] == s['mediaRevision'],
      );
      await action('selectImage');
      await tap(find.byValueKey('epub-excerpt-action'));
      current = await until((s) => (s['cards'] as List).length == 2);
      await action('selectImage');
      await tap(find.byTooltip('区域摘录'));
      await driver.scroll(
        find.byValueKey('epub-region-overlay'),
        120,
        60,
        const Duration(milliseconds: 700),
      );
      await driver.waitForAbsent(
        find.byValueKey('epub-region-overlay'),
        timeout: const Duration(seconds: 20),
      );
      await tap(find.byValueKey('epub-excerpt-action'));
      current = await until((s) => (s['cards'] as List).length == 3);
      await action('selectImage');
      await tap(find.byTooltip('更多阅读工具'));
      await tap(find.text('识别图片文字'));
      await driver.waitFor(
        find.text('图片识别结果'),
        timeout: const Duration(seconds: 40),
      );
      await tap(find.text('摘录识别文字'));
      current = await until((s) => (s['cards'] as List).length == 4);
      await command('verifyMedia');
      await command('verifySources');
      await driver.waitForAbsent(
        find.byValueKey('workspace-error'),
        timeout: const Duration(seconds: 5),
      );
      results.add({'step': '原图、区域截图及真实离线图片 OCR 可摘录并保存来源', 'passed': true});
      await File('${directory.path}/workbench.png')
          .writeAsBytes(await driver.screenshot());
      final ready = current['ready'] as int;
      await command('restore');
      current = await until(
        (s) => (s['ready'] as int) > ready && (s['cards'] as List).length == 4,
      );
      await command('verifySources');
      await command('verifyMedia');
      await driver.scrollIntoView(
        find.byValueKey('document-tab-${current['epub']}'),
      );
      await tap(find.byValueKey('document-tab-${current['epub']}'));
      await until(
        (s) => s['active'] == s['epub'] && s['webRevision'] == s['revision'],
      );
      await command('verifySources');
      await command('screenshot', {'name': 'restored-book'});
      results.add({'step': '关闭原生资源、混合备份恢复与离线回源', 'passed': true});
      await command('close');
    });
  } catch (error, stack) {
    results.add({
      'passed': false,
      'error': error.toString(),
      'stack': stack.toString(),
    });
    rethrow;
  } finally {
    await File('${directory.path}/report.json')
        .writeAsString(const JsonEncoder.withIndent('  ').convert(results));
    await driver.close();
  }
}
