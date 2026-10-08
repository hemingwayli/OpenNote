import 'package:flutter/material.dart';

import '../../domain/models.dart';
import '../../domain/relationship_geometry.dart';
import 'relationship_painter.dart';

class RelationshipEditResult {
  const RelationshipEditResult(this.label, this.style);
  final String label;
  final RelationshipStyle style;
}

/// 关系文字与线条作为同一次编辑提交；取消不会制造撤销记录。
class RelationshipStyleDialog extends StatefulWidget {
  const RelationshipStyleDialog({super.key, required this.edge});
  final MapEdge edge;
  @override
  State<RelationshipStyleDialog> createState() =>
      _RelationshipStyleDialogState();
}

class _RelationshipStyleDialogState extends State<RelationshipStyleDialog> {
  final _form = GlobalKey<FormState>();
  late final _label = TextEditingController(text: widget.edge.label);
  late final _lineColor = TextEditingController(text: widget.edge.style.color);
  late final _textColor = TextEditingController(
    text: widget.edge.style.labelColor,
  );
  late RelationshipStyle _style = widget.edge.style;
  @override
  void dispose() {
    _label.dispose();
    _lineColor.dispose();
    _textColor.dispose();
    super.dispose();
  }

  void _change(RelationshipStyle style) => setState(() => _style = style);
  static const _arrows = {
    RelationshipArrow.none: '无箭头',
    RelationshipArrow.triangle: '实心箭头',
    RelationshipArrow.open: '开放箭头',
    RelationshipArrow.diamond: '菱形',
    RelationshipArrow.circle: '圆点',
  };
  Widget _dropdown<T>(
    String label,
    String key,
    T value,
    Map<T, String> options,
    void Function(T) change,
  ) => DropdownButtonFormField<T>(
    key: ValueKey('$key-$value'),
    initialValue: value,
    isExpanded: true,
    decoration: InputDecoration(labelText: label),
    items: [
      for (final option in options.entries)
        DropdownMenuItem(value: option.key, child: Text(option.value)),
    ],
    onChanged: (value) {
      if (value != null) change(value);
    },
  );
  Widget _color(
    String label,
    String key,
    TextEditingController controller,
    void Function(String) change,
  ) => TextFormField(
    key: ValueKey(key),
    controller: controller,
    decoration: InputDecoration(labelText: label, hintText: '#3574CB'),
    validator: (value) => RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(value ?? '')
        ? null
        : '输入六位十六进制颜色',
    onChanged: (value) {
      if (RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(value)) change(value);
    },
  );
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('关联线样式'),
    content: SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: 140,
                child: CustomPaint(painter: _RelationshipPreview(_style)),
              ),
              const SizedBox(height: 16),
              TextFormField(
                key: const Key('relationship-description'),
                controller: _label,
                maxLines: 3,
                minLines: 1,
                maxLength: 1000,
                decoration: const InputDecoration(labelText: '关系说明'),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _dropdown(
                      '线条形状',
                      'relationship-shape',
                      _style.shape,
                      const {
                        RelationshipShape.straight: '直线',
                        RelationshipShape.curve: '曲线',
                        RelationshipShape.elbow: '折线',
                      },
                      (value) => _change(_style.copyWith(shape: value)),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: _color(
                      '线条颜色',
                      'relationship-line-color',
                      _lineColor,
                      (value) => _change(
                        _style.copyWith(
                          color: value,
                          colorSource: RelationshipColorSource.custom,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _dropdown(
                '颜色来源',
                'relationship-color-source',
                _style.colorSource,
                const {
                  RelationshipColorSource.custom: '自定义颜色',
                  RelationshipColorSource.from: '跟随起点主题',
                  RelationshipColorSource.to: '跟随终点主题',
                },
                (value) => _change(_style.copyWith(colorSource: value)),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Text('线条粗细'),
                  Expanded(
                    child: Slider(
                      key: const Key('relationship-width'),
                      value: _style.width,
                      min: .5,
                      max: 8,
                      divisions: 15,
                      label: _style.width.toStringAsFixed(1),
                      onChanged: (value) =>
                          _change(_style.copyWith(width: value)),
                    ),
                  ),
                  Text(_style.width.toStringAsFixed(1)),
                ],
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('虚线'),
                value: _style.dashed,
                onChanged: (value) => _change(_style.copyWith(dashed: value)),
              ),
              Row(
                children: [
                  Expanded(
                    child: _dropdown(
                      '起点箭头',
                      'relationship-start-arrow',
                      _style.startArrow,
                      _arrows,
                      (value) => _change(_style.copyWith(startArrow: value)),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: _dropdown(
                      '终点箭头',
                      'relationship-end-arrow',
                      _style.endArrow,
                      _arrows,
                      (value) => _change(_style.copyWith(endArrow: value)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              const Text('说明文字'),
              const SizedBox(height: 12),
              _dropdown('字体', 'relationship-font', _style.labelFont, const {
                'Source Han Sans CN': '思源黑体',
                'Segoe UI': 'Segoe UI',
                'Microsoft YaHei': '微软雅黑',
              }, (value) => _change(_style.copyWith(labelFont: value))),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _color(
                      '文字颜色',
                      'relationship-text-color',
                      _textColor,
                      (value) => _change(_style.copyWith(labelColor: value)),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: _dropdown(
                      '字号',
                      'relationship-size',
                      _style.labelSize,
                      {
                        for (final size in [
                          10.0,
                          12.0,
                          14.0,
                          16.0,
                          18.0,
                          20.0,
                          24.0,
                          28.0,
                          32.0,
                          _style.labelSize,
                        ])
                          size: '${size.toInt()}',
                      },
                      (value) => _change(_style.copyWith(labelSize: value)),
                    ),
                  ),
                ],
              ),
              Row(
                children: [
                  Expanded(
                    child: CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('加粗'),
                      value: _style.labelBold,
                      onChanged: (value) =>
                          _change(_style.copyWith(labelBold: value)),
                    ),
                  ),
                  Expanded(
                    child: CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('斜体'),
                      value: _style.labelItalic,
                      onChanged: (value) =>
                          _change(_style.copyWith(labelItalic: value)),
                    ),
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
        onPressed: () {
          _lineColor.text = '#C58035';
          _textColor.text = '#596579';
          _change(const RelationshipStyle());
        },
        child: const Text('重置样式'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const Key('relationship-style-save'),
        onPressed: () {
          if (_form.currentState!.validate()) {
            Navigator.pop(context, RelationshipEditResult(_label.text, _style));
          }
        },
        child: const Text('保存'),
      ),
    ],
  );
}

class _RelationshipPreview extends CustomPainter {
  const _RelationshipPreview(this.style);
  final RelationshipStyle style;
  @override
  void paint(Canvas canvas, Size size) {
    final a = MapNode(
      id: 'a',
      mapId: 'preview',
      cardId: 'a',
      x: 8,
      y: 32,
      width: 56,
      height: 32,
    );
    final b = MapNode(
      id: 'b',
      mapId: 'preview',
      cardId: 'b',
      x: size.width - 64,
      y: 32,
      width: 56,
      height: 32,
    );
    final previewStyle = style.copyWith(
      resetControls: true,
      clearFromAnchor: true,
      clearToAnchor: true,
      resetLabelOffset: true,
    );
    paintRelationship(
      canvas,
      relationshipGeometry(a, b, previewStyle),
      previewStyle.copyWith(
        color: switch (style.colorSource) {
          RelationshipColorSource.custom => style.color,
          RelationshipColorSource.from => '#F7D976',
          RelationshipColorSource.to => '#BDD9FF',
        },
      ),
    );
    final paint = Paint()..color = const Color(0xffF5F6F8);
    for (final node in [a, b]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(node.x, node.y, node.width, node.height),
          const Radius.circular(6),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_RelationshipPreview old) => old.style != style;
}
