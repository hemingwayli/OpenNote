import 'package:flutter/material.dart';

import 'open_note_theme.dart';

/// 轻浮层只组织现有工具，不持有选择、命令或编辑状态。
class OpenNoteToolGroup extends StatelessWidget {
  const OpenNoteToolGroup({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(2),
    decoration: BoxDecoration(
      color: OpenNoteTokens.surface,
      borderRadius: BorderRadius.circular(7),
      border: Border.all(color: OpenNoteTokens.border.withValues(alpha: .7)),
      boxShadow: OpenNoteTokens.floatingShadows,
    ),
    child: child,
  );
}
