import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opennote/ui/reader/epub_reader_pane.dart';

void main() {
  testWidgets('缺失系统 WebView2 时提供明确安装提示，尚未打开或解析书籍', (tester) async {
    var queried = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: EpubReaderPane(
          revisionId: 'r',
          filePath: 'does-not-exist.epub',
          sessionId: 's',
          onExcerpt: (_) {},
          runtimeVersion: () async {
            queried++;
            return null;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(queried, 1);
    expect(
      find.textContaining('本机缺少 Microsoft Edge WebView2 Runtime'),
      findsOneWidget,
    );
    expect(find.textContaining('PDF 可继续阅读'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, skip: !Platform.isWindows);
}
