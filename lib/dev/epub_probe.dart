import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../engines/epub/epub_publication.dart';
import '../ui/reader/epub_reader_pane.dart';

/// 独立原生验证入口；完全不打开生产资料库。
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: _Probe()));
}

class _Probe extends StatefulWidget {
  const _Probe();
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  final samples = [
    'epub3-reflow',
    'epub2-reflow',
    'epub3-vertical',
    'epub3-fixed',
    'epub3-mixed',
    if (Platform.environment['OPENNOTE_EPUB_REAL_BOOK'] != null) 'real-book',
  ];
  final results = <Map<String, dynamic>>[];
  int current = 0;
  Future<void> ready(
    InAppWebViewController controller,
    EpubPublication publication,
  ) async {
    final directory = Directory('.local/verification/epub-pdf/native-probe');
    await directory.create(recursive: true);
    try {
      if (current == 0) {
        final version = await WebViewEnvironment.getAvailableVersion();
        final empty = Directory('${directory.path}/empty-runtime');
        await empty.create(recursive: true);
        final unavailable = await WebViewEnvironment.getAvailableVersion(
          browserExecutableFolder: empty.absolute.path,
        );
        if (version == null || unavailable != null) {
          throw StateError('运行时可用／缺失原生探测不符合约定');
        }
        results.add({
          'sample': 'runtime-detection',
          'status': 'passed',
          'systemVersion': version,
          'missingCase':
              'empty executable directory; installed runtime unchanged',
        });
      }
      final result = await controller.callAsyncJavaScript(
        functionBody: 'try {return {ok:true,data:await window.openNote.probe()};} catch(error) {return {ok:false,error:String(error.stack || error)};}',
      );
      if (result?.error != null) throw StateError(result!.error.toString());
      final envelope=Map<String,dynamic>.from(result!.value as Map);
      if(envelope['ok']!=true) throw StateError('${envelope['error']}');
      final json = Map<String, dynamic>.from(envelope['data'] as Map);
      if (json['text'] != (json['anchor'] as Map)['quote']) {
        throw StateError('CFI 回源内容不一致');
      }
      if ((json['index'] as Map)['text'].toString().isEmpty) {
        throw StateError('正文索引为空');
      }
      final screenshot = await controller.takeScreenshot();
      if (screenshot == null || screenshot.length < 100) {
        throw StateError('原生截图为空');
      }
      await File('${directory.path}/${samples[current]}.png')
          .writeAsBytes(screenshot);
      if (samples[current] == 'real-book') {
        json['index'] = {
          'href': (json['index'] as Map)['href'],
          'textLength': (json['index'] as Map)['text'].toString().length,
          'fragmentCount': ((json['index'] as Map)['fragments'] as List).length,
        };
      }
      results.add({
        'sample': samples[current],
        'status': 'passed',
        'data': json,
        'screenshotBytes': screenshot.length,
      });
      await File('${directory.path}/report.json')
          .writeAsString(jsonEncode(results));
      if (!mounted) return;
      if (current + 1 < samples.length) {
        setState(() {
          current++;
        });
      } else {
        debugPrint('EPUB_NATIVE_PROBE_PASSED');
        await Future<void>.delayed(const Duration(seconds: 1));
        exit(0);
      }
    } catch (error, stack) {
      results.add({
        'sample': samples[current],
        'status': 'failed',
        'error': error.toString(),
        'stack': stack.toString(),
      });
      await File('${directory.path}/report.json')
          .writeAsString(jsonEncode(results));
      debugPrint('EPUB 原生探针失败：$error');
      exit(1);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('EPUB 原生隔离验证 · ${samples[current]}')),
    body: EpubReaderPane(
      key: ValueKey(current),
      revisionId: samples[current],
      sessionId: 'isolated-probe',
      filePath: samples[current] == 'real-book'
          ? Platform.environment['OPENNOTE_EPUB_REAL_BOOK']!
          : '${Directory.current.path}/tools/fixtures/epub/${samples[current]}.epub',
      onExcerpt: (_) {},
      onProbeReady: ready,
    ),
  );
}
