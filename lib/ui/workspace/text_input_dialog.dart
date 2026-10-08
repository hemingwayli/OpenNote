import 'package:flutter/material.dart';

class TextInputResult {
  const TextInputResult(this.text, {this.delete = false});
  final String text;
  final bool delete;
}

/// 控制器随对话框路由卸载，结果返回时退出动画仍可安全读取输入内容。
class TextInputDialog extends StatefulWidget {
  const TextInputDialog({
    super.key,
    required this.title,
    this.initialText = '',
    this.hint = '',
    this.confirmLabel = '保存',
    this.multiline = false,
    this.requireText = false,
    this.allowDelete = false,
  });
  final String title;
  final String initialText;
  final String hint;
  final String confirmLabel;
  final bool multiline;
  final bool requireText;
  final bool allowDelete;

  @override
  State<TextInputDialog> createState() => _TextInputDialogState();
}

class _TextInputDialogState extends State<TextInputDialog> {
  late final _input = TextEditingController(text: widget.initialText);

  void _confirm() {
    if (!widget.requireText || _input.text.trim().isNotEmpty) {
      Navigator.pop(context, TextInputResult(_input.text));
    }
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: 360,
      child: TextField(
        autofocus: true,
        controller: _input,
        maxLines: widget.multiline ? 6 : 1,
        decoration: InputDecoration(hintText: widget.hint),
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => _confirm(),
      ),
    ),
    actions: [
      if (widget.allowDelete)
        TextButton(
          onPressed: () => Navigator.pop(
            context,
            TextInputResult(_input.text, delete: true),
          ),
          child: const Text('删除批注'),
        ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: widget.requireText && _input.text.trim().isEmpty
            ? null
            : _confirm,
        child: Text(widget.confirmLabel),
      ),
    ],
  );
}
