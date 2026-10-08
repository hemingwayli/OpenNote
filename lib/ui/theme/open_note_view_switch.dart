import 'open_note_icon.dart';

import 'package:flutter/material.dart';

import 'open_note_theme.dart';

/// 同一内容区的视图切换：灰色底座与独立选中面，保留键盘焦点反馈。
class OpenNoteViewSwitch extends StatelessWidget {
  const OpenNoteViewSwitch({
    super.key,
    required this.value,
    required this.labels,
    required this.onChanged,
    this.icons,
    this.expand = false,
    this.iconOnly = false,
  });
  final bool value;
  final List<String> labels;
  final List<IconData>? icons;
  final ValueChanged<bool> onChanged;
  final bool expand;
  final bool iconOnly;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: OpenNoteTokens.background,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Padding(
      padding: const EdgeInsets.all(2),
      child: Row(
        mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
        children: [
          for (var index = 0; index < 2; index++)
            if (expand) Expanded(child: _item(index)) else _item(index),
        ],
      ),
    ),
  );

  Widget _item(int index) {
    final selected = value == (index == 1);
    return Semantics(
      selected: selected,
      label: iconOnly ? labels[index] : null,
      child: Tooltip(
        message: labels[index],
        child: TextButton(
          style: TextButton.styleFrom(
            minimumSize: Size(iconOnly ? 36 : 52, 36),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            foregroundColor: selected
                ? OpenNoteTokens.text
                : OpenNoteTokens.secondary,
            backgroundColor: selected ? Colors.white : Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6),
            ),
          ),
          onPressed: () => onChanged(index == 1),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icons != null) ...[
                OpenNoteIcon(icons![index], size: 18),
                if (!iconOnly) const SizedBox(width: 7),
              ],
              if (!iconOnly || icons == null) Text(labels[index]),
            ],
          ),
        ),
      ),
    );
  }
}
