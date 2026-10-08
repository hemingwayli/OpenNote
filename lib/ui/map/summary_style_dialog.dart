import 'package:flutter/material.dart';

import '../../domain/models.dart';
import '../../domain/summary_geometry.dart';

class SummaryEditResult {
  const SummaryEditResult(this.style, this.nodeIds);
  final SummaryStyle style;
  final List<String> nodeIds;
}

class SummaryStyleDialog extends StatefulWidget {
  const SummaryStyleDialog({
    super.key,
    required this.summary,
    required this.snapshot,
  });
  final MapSummary summary;
  final MapSnapshot snapshot;
  @override
  State<SummaryStyleDialog> createState() => _SummaryStyleDialogState();
}

class _SummaryStyleDialogState extends State<SummaryStyleDialog> {
  final _form = GlobalKey<FormState>();
  late var _style = widget.summary.style;
  late final _color = TextEditingController(text: _style.color);
  late final _fill = TextEditingController(text: _style.topic.fill);
  late final _border = TextEditingController(text: _style.topic.color);
  late final _text = TextEditingController(text: _style.topic.textColor);
  late final _auxiliary = widget.snapshot.summaries
      .map((s) => s.summaryNodeId)
      .toSet();
  late final _siblings =
      widget.snapshot.nodes
          .where(
            (n) =>
                n.parentNodeId == widget.summary.parentNodeId &&
                !_auxiliary.contains(n.id),
          )
          .toList()
        ..sort(compareMapNodes);
  late final _range = summaryRoots(
    widget.summary,
    widget.snapshot.nodes,
    widget.snapshot.summaries,
  );
  late var _start = _range.first.id, _end = _range.last.id;
  @override
  void dispose() {
    _color.dispose();
    _fill.dispose();
    _border.dispose();
    _text.dispose();
    super.dispose();
  }

  Widget _choice<T>(
    String label,
    T value,
    Map<T, String> choices,
    void Function(T) change,
  ) => DropdownButtonFormField<T>(
    key: ValueKey('$label-$value'),
    initialValue: value,
    isExpanded: true,
    decoration: InputDecoration(labelText: label),
    items: [
      for (final e in choices.entries)
        DropdownMenuItem(
          value: e.key,
          child: Text(e.value, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
    ],
    onChanged: (v) {
      if (v != null) setState(() => change(v));
    },
  );
  Widget _hex(
    String label,
    TextEditingController controller,
    void Function(String) change,
  ) => TextFormField(
    controller: controller,
    decoration: InputDecoration(labelText: label),
    validator: (v) =>
        RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(v ?? '') ? null : '输入六位十六进制颜色',
    onChanged: (v) {
      if (RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(v)) setState(() => change(v));
    },
  );
  void _topic(BoundaryStyle s) {
    _style = _style.copyWith(topic: s);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('概要样式与范围'),
    content: SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.summary.parentNodeId != null) ...[
                _choice(
                  '范围起点',
                  _start,
                  {
                    for (final n in _siblings)
                      n.id: widget.snapshot.cards[n.cardId]!.title,
                  },
                  (v) {
                    _start = v;
                    if (_siblings.indexWhere((n) => n.id == _start) >
                        _siblings.indexWhere((n) => n.id == _end)) {
                      _end = v;
                    }
                  },
                ),
                const SizedBox(height: 12),
                _choice(
                  '范围终点',
                  _end,
                  {
                    for (final n in _siblings)
                      n.id: widget.snapshot.cards[n.cardId]!.title,
                  },
                  (v) {
                    _end = v;
                    if (_siblings.indexWhere((n) => n.id == _end) <
                        _siblings.indexWhere((n) => n.id == _start)) {
                      _start = v;
                    }
                  },
                ),
                const SizedBox(height: 16),
              ],
              _choice('概要括号', _style.bracket, const {
                SummaryBracket.brace: '花括号',
                SummaryBracket.square: '方括号',
                SummaryBracket.curve: '弧线',
              }, (v) => _style = _style.copyWith(bracket: v)),
              const SizedBox(height: 12),
              _hex(
                '括号与连接线颜色',
                _color,
                (v) => _style = _style.copyWith(color: v),
              ),
              _choice('连接线粗细', _style.width, {
                for (final v in {1.0, 1.4, 2.0, 3.0, 4.0, _style.width})
                  v: '$v',
              }, (v) => _style = _style.copyWith(width: v)),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('概要连接线使用虚线'),
                value: _style.dashed,
                onChanged: (v) =>
                    setState(() => _style = _style.copyWith(dashed: v)),
              ),
              const Divider(height: 24),
              const Text('概要主题'),
              const SizedBox(height: 12),
              _choice('主题形状', _style.topic.shape, const {
                BoundaryShape.rounded: '圆角矩形',
                BoundaryShape.rectangle: '矩形',
                BoundaryShape.ellipse: '胶囊',
              }, (v) => _topic(_style.topic.copyWith(shape: v))),
              const SizedBox(height: 12),
              _hex(
                '主题填充色',
                _fill,
                (v) => _topic(_style.topic.copyWith(fill: v)),
              ),
              const SizedBox(height: 12),
              _hex(
                '主题边框色',
                _border,
                (v) => _topic(_style.topic.copyWith(color: v)),
              ),
              _choice('主题边框粗细', _style.topic.width, {
                for (final v in {1.0, 1.4, 2.0, 3.0, 4.0, _style.topic.width})
                  v: '$v',
              }, (v) => _topic(_style.topic.copyWith(width: v))),
              const SizedBox(height: 12),
              _hex(
                '主题文字色',
                _text,
                (v) => _topic(_style.topic.copyWith(textColor: v)),
              ),
              const SizedBox(height: 12),
              _choice('字体', _style.topic.fontFamily, const {
                'Source Han Sans CN': '思源黑体',
                'Segoe UI': 'Segoe UI',
                'Microsoft YaHei': '微软雅黑',
              }, (v) => _topic(_style.topic.copyWith(fontFamily: v))),
              const SizedBox(height: 12),
              _choice('字号', _style.topic.textSize, {
                for (final v in {
                  12.0,
                  14.0,
                  15.0,
                  16.0,
                  18.0,
                  20.0,
                  24.0,
                  _style.topic.textSize,
                })
                  v: '${v.toInt()}',
              }, (v) => _topic(_style.topic.copyWith(textSize: v))),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('粗体'),
                value: _style.topic.bold,
                onChanged: (v) =>
                    setState(() => _topic(_style.topic.copyWith(bold: v))),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('斜体'),
                value: _style.topic.italic,
                onChanged: (v) =>
                    setState(() => _topic(_style.topic.copyWith(italic: v))),
              ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => setState(() {
          _style = const SummaryStyle();
          _color.text = _style.color;
          _fill.text = _style.topic.fill;
          _border.text = _style.topic.color;
          _text.text = _style.topic.textColor;
        }),
        child: const Text('重置样式'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () {
          if (!_form.currentState!.validate()) return;
          final a = _siblings.indexWhere((n) => n.id == _start),
              b = _siblings.indexWhere((n) => n.id == _end);
          Navigator.pop(
            context,
            SummaryEditResult(
              _style,
              widget.summary.parentNodeId == null
                  ? widget.summary.nodeIds
                  : _siblings.sublist(a, b + 1).map((n) => n.id).toList(),
            ),
          );
        },
        child: const Text('保存'),
      ),
    ],
  );
}
