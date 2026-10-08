import 'open_note_icon.dart';

import 'package:flutter/material.dart';

/// 搜索入口收起时仍保留焦点节点；快捷键聚焦与鼠标展开走相同路径。
class OpenNoteSearch extends StatefulWidget {
  const OpenNoteSearch({
    super.key,
    required this.controller,
    required this.onChanged,
    required this.label,
    required this.inputKey,
    this.focusNode,
    this.collapsedAlignment = Alignment.centerLeft,
  });
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final String label;
  final Key inputKey;
  final FocusNode? focusNode;
  final AlignmentGeometry collapsedAlignment;

  @override
  State<OpenNoteSearch> createState() => _OpenNoteSearchState();
}

class _OpenNoteSearchState extends State<OpenNoteSearch> {
  late final _ownedFocus = FocusNode();
  FocusNode get _focus => widget.focusNode ?? _ownedFocus;
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_update);
    widget.controller.addListener(_update);
  }

  @override
  void didUpdateWidget(OpenNoteSearch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      (oldWidget.focusNode ?? _ownedFocus).removeListener(_update);
      _focus.addListener(_update);
    }
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_update);
      widget.controller.addListener(_update);
    }
  }

  void _update() {
    if (mounted) setState(() => _expanded = _focus.hasFocus);
  }

  @override
  void dispose() {
    _focus.removeListener(_update);
    widget.controller.removeListener(_update);
    _ownedFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final expanded = _expanded || widget.controller.text.isNotEmpty;
    return SizedBox(
      height: 44,
      child: Stack(
        children: [
          Offstage(
            offstage: !expanded,
            child: TextField(
              key: widget.inputKey,
              controller: widget.controller,
              focusNode: _focus,
              onChanged: widget.onChanged,
              decoration: InputDecoration(
                hintText: '搜索',
                prefixIcon: const OpenNoteIcon(Icons.search, size: 20),
                suffixIcon: IconButton(
                  tooltip: '清除搜索',
                  onPressed: () {
                    widget.controller.clear();
                    widget.onChanged('');
                  },
                  icon: const OpenNoteIcon(Icons.close, size: 18),
                ),
              ),
            ),
          ),
          if (!expanded)
            Align(
              alignment: widget.collapsedAlignment,
              child: IconButton(
                tooltip: widget.label,
                onPressed: _focus.requestFocus,
                icon: const OpenNoteIcon(Icons.search, size: 20),
              ),
            ),
        ],
      ),
    );
  }
}
