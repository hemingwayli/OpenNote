import 'open_note_icon.dart';

import 'package:flutter/material.dart';

import 'open_note_theme.dart';

/// 局部反馈由调用方管理寿命；浮层不参与内容布局。
class OpenNoteFeedback extends StatelessWidget {
  const OpenNoteFeedback({
    super.key,
    required this.message,
    this.error = false,
    this.processing = false,
    this.pending = false,
  });
  final String message;
  final bool error;
  final bool processing;
  final bool pending;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Material(
      color: error ? const Color(0xfffff3f1) : OpenNoteTokens.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: error ? const Color(0xffdfb5af) : OpenNoteTokens.border,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (processing)
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 1.5),
              )
            else
              OpenNoteIcon(
                error
                    ? Icons.error_outline
                    : pending
                    ? Icons.schedule_outlined
                    : Icons.check_rounded,
                size: 16,
                color: error ? Colors.red : OpenNoteTokens.secondary,
              ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                message,
                style: const TextStyle(
                  fontSize: 12,
                  color: OpenNoteTokens.text,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
