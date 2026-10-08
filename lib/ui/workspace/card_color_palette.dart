import '../theme/open_note_icon.dart';

import 'package:flutter/material.dart';

import '../theme/open_note_theme.dart';

const cardColorPalette = [
  ('黄色', '#F7D976'),
  ('橙色', '#F2B36D'),
  ('红色', '#EB8C91'),
  ('紫色', '#B7A0DD'),
  ('蓝色', '#80B9EB'),
  ('绿色', '#91C69A'),
  ('灰色', '#B8BEC7'),
];

Color cardColor(String value) =>
    Color(0xFF000000 | int.parse(value.substring(1), radix: 16));

/// 面板用紧凑圆点，原有改色窗口沿用方形色块；颜色值共用一份。
class CardColorPalette extends StatelessWidget {
  const CardColorPalette({
    super.key,
    required this.onSelected,
    this.currentColor,
    this.compact = false,
  });

  final String? currentColor;
  final ValueChanged<String> onSelected;
  final bool compact;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: compact ? 4 : 8,
    runSpacing: compact ? 4 : 8,
    children: [
      for (final value in cardColorPalette)
        Tooltip(
          message: value.$1,
          child: Semantics(
            button: true,
            selected: value.$2 == currentColor,
            label: value.$1,
            child: InkWell(
              key: ValueKey('card-color-${value.$2}'),
              onTap: () => onSelected(value.$2),
              borderRadius: BorderRadius.circular(6),
              child: Container(
                width: compact ? 36 : 40,
                height: compact ? 36 : 40,
                decoration: BoxDecoration(
                  color: compact ? null : cardColor(value.$2),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: value.$2 == currentColor
                        ? OpenNoteTokens.accent
                        : Colors.transparent,
                    width: compact ? 1 : 2,
                  ),
                ),
                child: Center(
                  child: Container(
                    width: compact ? 18 : null,
                    height: compact ? 18 : null,
                    decoration: compact
                        ? BoxDecoration(
                            color: cardColor(value.$2),
                            shape: BoxShape.circle,
                          )
                        : null,
                    child: value.$2 == currentColor
                        ? OpenNoteIcon(Icons.check, size: compact ? 12 : 20)
                        : null,
                  ),
                ),
              ),
            ),
          ),
        ),
    ],
  );
}
