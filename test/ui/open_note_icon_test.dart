import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opennote/ui/theme/open_note_icon.dart';
import 'package:opennote/ui/theme/open_note_theme.dart';

void main() {
  testWidgets('输入框前缀保留点击槽位，线性图标不随槽位被放大', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: openNoteTheme(),
          home: const Scaffold(
            body: TextField(
              decoration: InputDecoration(
                prefixIcon: OpenNoteIcon(
                  Icons.search,
                  size: 20,
                  semanticLabel: '搜索',
                ),
              ),
            ),
          ),
        ),
      );
      final icon = find.byIcon(Icons.search);
      expect(icon, findsOneWidget);
      expect(tester.getSize(icon).width, greaterThanOrEqualTo(48));
      final paint = find.descendant(
        of: icon,
        matching: find.byType(CustomPaint),
      );
      expect(tester.getSize(paint), const Size(20, 20));
      expect(find.bySemanticsLabel('搜索'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });
}
