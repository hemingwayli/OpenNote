import 'package:flutter/material.dart';

import '../../domain/models.dart';
import '../../domain/boundary_geometry.dart';

class BoundaryEditResult {
  const BoundaryEditResult(this.label, this.style, this.nodeIds);
  final String label;
  final BoundaryStyle style;
  final List<String> nodeIds;
}

class BoundaryStyleDialog extends StatefulWidget {
  const BoundaryStyleDialog({
    super.key,
    required this.boundary,
    required this.snapshot,
  });
  final MapBoundary boundary;
  final MapSnapshot snapshot;
  @override
  State<BoundaryStyleDialog> createState() => _BoundaryStyleDialogState();
}

class _BoundaryStyleDialogState extends State<BoundaryStyleDialog> {
  final _form = GlobalKey<FormState>();
  late final _label = TextEditingController(text: widget.boundary.label);
  late final _fill = TextEditingController(text: widget.boundary.style.fill);
  late final _color = TextEditingController(text: widget.boundary.style.color);
  late final _textColor = TextEditingController(
    text: widget.boundary.style.textColor,
  );
  late var _style = widget.boundary.style;
  late final _siblings =
      widget.snapshot.nodes
          .where(
            (n) =>
                n.parentNodeId == widget.boundary.parentNodeId &&
                (!widget.snapshot.summaries.any(
                      (s) => s.summaryNodeId == n.id,
                    ) ||
                    widget.boundary.nodeIds.contains(n.id)),
          )
          .toList()
        ..sort(compareMapNodes);
  late final _initial = boundaryRoots(
    widget.boundary,
    widget.snapshot.nodes,
    auxiliaryRoots: widget.snapshot.summaries
        .map((s) => s.summaryNodeId)
        .toSet(),
  );
  late String _start = _initial.first.id, _end = _initial.last.id;
  @override
  void dispose() {
    _label.dispose();
    _fill.dispose();
    _color.dispose();
    _textColor.dispose();
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
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('外框样式与范围'),
    content: SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                key: const Key('boundary-description'),
                controller: _label,
                maxLength: 1000,
                minLines: 1,
                maxLines: 3,
                decoration: const InputDecoration(labelText: '分组说明'),
              ),
              if (widget.boundary.parentNodeId != null) ...[
                const SizedBox(height: 12),
                _choice('范围起点', _start, {
                  for (final n in _siblings)
                    n.id: widget.snapshot.cards[n.cardId]!.title,
                }, (v) => _start = v),
                const SizedBox(height: 12),
                _choice('范围终点', _end, {
                  for (final n in _siblings)
                    n.id: widget.snapshot.cards[n.cardId]!.title,
                }, (v) => _end = v),
              ],
              const SizedBox(height: 16),
              _choice('外框形状', _style.shape, const {
                BoundaryShape.rounded: '圆角矩形',
                BoundaryShape.rectangle: '矩形',
                BoundaryShape.ellipse: '椭圆',
              }, (v) => _style = _style.copyWith(shape: v)),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _hex(
                      '填充颜色',
                      _fill,
                      (v) => _style = _style.copyWith(fill: v),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: _hex(
                      '边框颜色',
                      _color,
                      (v) => _style = _style.copyWith(color: v),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text('填充不透明度 ${(_style.fillOpacity * 100).round()}%'),
              Slider(
                value: _style.fillOpacity,
                divisions: 20,
                onChanged: (v) =>
                    setState(() => _style = _style.copyWith(fillOpacity: v)),
              ),
              Text('边框粗细 ${_style.width.toStringAsFixed(1)}'),
              Slider(
                value: _style.width,
                min: .5,
                max: 8,
                divisions: 15,
                onChanged: (v) =>
                    setState(() => _style = _style.copyWith(width: v)),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('虚线边框'),
                value: _style.dashed,
                onChanged: (v) =>
                    setState(() => _style = _style.copyWith(dashed: v)),
              ),
              _choice('字体', _style.fontFamily, const {
                'Source Han Sans CN': '思源黑体',
                'Segoe UI': 'Segoe UI',
                'Microsoft YaHei': '微软雅黑',
              }, (v) => _style = _style.copyWith(fontFamily: v)),
              const SizedBox(height: 12),
              _hex(
                '文字颜色',
                _textColor,
                (v) => _style = _style.copyWith(textColor: v),
              ),
              Text('字号 ${_style.textSize.round()}'),
              Slider(
                value: _style.textSize,
                min: 10,
                max: 32,
                divisions: 22,
                onChanged: (v) =>
                    setState(() => _style = _style.copyWith(textSize: v)),
              ),
              Row(
                children: [
                  FilterChip(
                    label: const Text('粗体'),
                    selected: _style.bold,
                    onSelected: (v) =>
                        setState(() => _style = _style.copyWith(bold: v)),
                  ),
                  const SizedBox(width: 12),
                  FilterChip(
                    label: const Text('斜体'),
                    selected: _style.italic,
                    onSelected: (v) =>
                        setState(() => _style = _style.copyWith(italic: v)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => setState(() {
          _style = const BoundaryStyle();
          _fill.text = _style.fill;
          _color.text = _style.color;
          _textColor.text = _style.textColor;
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
          final lo = _siblings.indexWhere((n) => n.id == _start),
              hi = _siblings.indexWhere((n) => n.id == _end);
          final nodes = _siblings
              .sublist(lo < hi ? lo : hi, (lo > hi ? lo : hi) + 1)
              .map((n) => n.id)
              .toList();
          Navigator.pop(
            context,
            BoundaryEditResult(_label.text, _style, nodes),
          );
        },
        child: const Text('保存'),
      ),
    ],
  );
}
