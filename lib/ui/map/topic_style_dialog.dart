import '../theme/open_note_icon.dart';

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../domain/models.dart';
import '../theme/open_note_theme.dart';
import 'topic_style_painter.dart';

class TopicStyleEditResult {
  const TopicStyleEditResult(
    this.style, {
    this.includeDescendants = false,
    this.makeDefault = false,
  });
  final TopicStyle? style;
  final bool includeDescendants, makeDefault;
}

class TopicStyleDialog extends StatefulWidget {
  const TopicStyleDialog({
    super.key,
    required this.style,
    required this.defaultStyle,
    required this.selectionCount,
    this.editingDefault = false,
  });
  final TopicStyle style, defaultStyle;
  final int selectionCount;
  final bool editingDefault;
  @override
  State<TopicStyleDialog> createState() => _TopicStyleDialogState();
}

class _TopicStyleDialogState extends State<TopicStyleDialog> {
  late TopicStyle _style = widget.style;
  final _colors = <String, TextEditingController>{};
  bool _descendants = false, _default = false, _reset = false;
  String? _error;
  void _surface(BoundaryStyle surface) => setState(() {
    _style = _style.copyWith(surface: surface);
    _reset = false;
  });
  void _branch(BranchStyle branch) => setState(() {
    _style = _style.copyWith(branch: branch);
    _reset = false;
  });
  @override
  void dispose() {
    for (final controller in _colors.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Widget _choice<T>(
    String label,
    T value,
    Map<T, String> options,
    ValueChanged<T> changed,
  ) => Padding(
    key: ValueKey('topic-style-$label'),
    padding: const EdgeInsets.only(bottom: 12),
    child: DropdownButtonFormField<T>(
      key: ValueKey('topic-style-$label-$value'),
      initialValue: value,
      decoration: InputDecoration(labelText: label),
      items: [
        for (final option in options.entries)
          DropdownMenuItem(value: option.key, child: Text(option.value)),
      ],
      onChanged: (next) {
        if (next != null) changed(next);
      },
    ),
  );
  Map<double, String> _numbers(List<double> values, double current) => {
    for (final value in ({...values, current}.toList()..sort()))
      value: value.toString().replaceFirst(RegExp(r'\.0$'), ''),
  };
  Widget _color(String label, String value, ValueChanged<String> changed) {
    final controller = _colors.putIfAbsent(
      label,
      () => TextEditingController(text: value),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              key: ValueKey('topic-style-$label'),
              controller: controller,
              decoration: InputDecoration(
                labelText: label,
                prefixIcon: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Container(
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      color: Color(
                        int.parse(value.substring(1), radix: 16) | 0xff000000,
                      ),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: OpenNoteTokens.border),
                    ),
                  ),
                ),
              ),
              onChanged: (text) {
                if (RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(text)) changed(text);
              },
            ),
          ),
          const SizedBox(width: 8),
          PopupMenuButton<String>(
            tooltip: '选择$label',
            icon: const OpenNoteIcon(Icons.palette_outlined, size: 20),
            onSelected: (color) {
              controller.text = color;
              changed(color);
            },
            itemBuilder: (_) => [
              for (final color in [
                '#FFFFFF',
                '#262B33',
                '#E1E5EA',
                '#3574CB',
                '#8BA7D0',
                '#EAF1FC',
                '#EAF4EE',
                '#F7D976',
              ])
                PopupMenuItem(
                  value: color,
                  child: Row(
                    children: [
                      Container(
                        width: 18,
                        height: 18,
                        color: Color(
                          int.parse(color.substring(1), radix: 16) | 0xff000000,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(color),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  void _restore() => setState(() {
    _style = widget.defaultStyle;
    _reset = true;
    _error = null;
    final values = {
      '填充颜色': _style.surface.fill,
      '边框颜色': _style.surface.color,
      '文字颜色': _style.surface.textColor,
      '连线颜色': _style.branch.color,
    };
    for (final entry in _colors.entries) {
      entry.value.text = values[entry.key]!;
    }
  });
  void _save() {
    if (_colors.values.any(
      (c) => !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(c.text),
    )) {
      setState(() => _error = '颜色请使用 #RRGGBB 格式。');
      return;
    }
    _style.validate();
    Navigator.pop(
      context,
      TopicStyleEditResult(
        _reset && !widget.editingDefault ? null : _style,
        includeDescendants: _descendants,
        makeDefault: widget.editingDefault || _default,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final surface = _style.surface, branch = _style.branch;
    return Dialog(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 520,
          maxHeight: math.max(240, MediaQuery.sizeOf(context).height - 80),
        ),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: DefaultTabController(
            length: 2,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.editingDefault ? '脑图默认格式' : '主题格式',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    if (!widget.editingDefault)
                      Text(
                        '${widget.selectionCount} 个主题',
                        style: const TextStyle(
                          color: OpenNoteTokens.secondary,
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                Container(
                  height: 72,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: OpenNoteTokens.background,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 64,
                        height: 48,
                        child: CustomPaint(painter: _BranchPreview(branch)),
                      ),
                      Flexible(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 22,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              color: Color(
                                int.parse(
                                      surface.fill.substring(1),
                                      radix: 16,
                                    ) |
                                    0xff000000,
                              ).withValues(alpha: surface.fillOpacity),
                              border: Border.all(
                                color: Color(
                                  int.parse(
                                        surface.color.substring(1),
                                        radix: 16,
                                      ) |
                                      0xff000000,
                                ),
                                width: surface.width,
                              ),
                              borderRadius: BorderRadius.circular(
                                surface.shape == BoundaryShape.rectangle
                                    ? 0
                                    : surface.shape == BoundaryShape.ellipse
                                    ? 40
                                    : 8,
                              ),
                            ),
                            child: Text(
                              '示例主题',
                              style: TextStyle(
                                fontFamily: surface.fontFamily,
                                fontSize: surface.textSize,
                                fontWeight: surface.bold
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                                fontStyle: surface.italic
                                    ? FontStyle.italic
                                    : FontStyle.normal,
                                color: Color(
                                  int.parse(
                                        surface.textColor.substring(1),
                                        radix: 16,
                                      ) |
                                      0xff000000,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                const TabBar(
                  tabs: [
                    Tab(text: '主题'),
                    Tab(text: '分支'),
                  ],
                ),
                Flexible(
                  child: SizedBox(
                    height: 320,
                    child: TabBarView(
                      children: [
                        SingleChildScrollView(
                          padding: const EdgeInsets.only(top: 16),
                          child: Column(
                            children: [
                              _choice('主题形状', surface.shape, {
                                BoundaryShape.rounded: '圆角矩形',
                                BoundaryShape.rectangle: '矩形',
                                BoundaryShape.ellipse: '胶囊',
                              }, (v) => _surface(surface.copyWith(shape: v))),
                              _color(
                                '填充颜色',
                                surface.fill,
                                (v) =>
                                    _surface(_style.surface.copyWith(fill: v)),
                              ),
                              _color(
                                '边框颜色',
                                surface.color,
                                (v) =>
                                    _surface(_style.surface.copyWith(color: v)),
                              ),
                              _choice(
                                '边框粗细',
                                surface.width,
                                _numbers([
                                  .5,
                                  1,
                                  1.4,
                                  2,
                                  3,
                                  4,
                                  6,
                                  8,
                                ], surface.width),
                                (v) => _surface(surface.copyWith(width: v)),
                              ),
                              SwitchListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('虚线边框'),
                                value: surface.dashed,
                                onChanged: (v) =>
                                    _surface(surface.copyWith(dashed: v)),
                              ),
                              _choice(
                                '字体',
                                surface.fontFamily,
                                {
                                  'Source Han Sans CN': '思源黑体',
                                  'Segoe UI': 'Segoe UI',
                                  'Microsoft YaHei': '微软雅黑',
                                },
                                (v) =>
                                    _surface(surface.copyWith(fontFamily: v)),
                              ),
                              _choice(
                                '字号',
                                surface.textSize,
                                _numbers([
                                  10,
                                  12,
                                  14,
                                  15,
                                  16,
                                  18,
                                  20,
                                  24,
                                  28,
                                  32,
                                ], surface.textSize),
                                (v) => _surface(surface.copyWith(textSize: v)),
                              ),
                              _color(
                                '文字颜色',
                                surface.textColor,
                                (v) => _surface(
                                  _style.surface.copyWith(textColor: v),
                                ),
                              ),
                              CheckboxListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('粗体'),
                                value: surface.bold,
                                onChanged: (v) =>
                                    _surface(surface.copyWith(bold: v)),
                              ),
                              CheckboxListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('斜体'),
                                value: surface.italic,
                                onChanged: (v) =>
                                    _surface(surface.copyWith(italic: v)),
                              ),
                            ],
                          ),
                        ),
                        SingleChildScrollView(
                          padding: const EdgeInsets.only(top: 16),
                          child: Column(
                            children: [
                              const Align(
                                alignment: Alignment.centerLeft,
                                child: Padding(
                                  padding: EdgeInsets.only(bottom: 12),
                                  child: Text(
                                    '设置连接该主题的分支线。概要主题设置其子分支线。',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: OpenNoteTokens.secondary,
                                    ),
                                  ),
                                ),
                              ),
                              _choice('连线形状', branch.path, {
                                BranchPath.curve: '曲线',
                                BranchPath.straight: '直线',
                                BranchPath.elbow: '折线',
                              }, (v) => _branch(branch.copyWith(path: v))),
                              _color(
                                '连线颜色',
                                branch.color,
                                (v) =>
                                    _branch(_style.branch.copyWith(color: v)),
                              ),
                              _choice(
                                '连线粗细',
                                branch.width,
                                _numbers([
                                  .5,
                                  1,
                                  1.4,
                                  2,
                                  3,
                                  4,
                                  6,
                                  8,
                                ], branch.width),
                                (v) => _branch(branch.copyWith(width: v)),
                              ),
                              SwitchListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('虚线'),
                                value: branch.dashed,
                                onChanged: (v) =>
                                    _branch(branch.copyWith(dashed: v)),
                              ),
                              SwitchListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('跟随卡片颜色'),
                                value: branch.followCardColor,
                                onChanged: (v) => _branch(
                                  branch.copyWith(followCardColor: v),
                                ),
                              ),
                              _choice('起点', branch.start, {
                                BranchEnd.none: '无箭头',
                                BranchEnd.arrow: '箭头',
                              }, (v) => _branch(branch.copyWith(start: v))),
                              _choice('终点', branch.end, {
                                BranchEnd.none: '无箭头',
                                BranchEnd.arrow: '箭头',
                              }, (v) => _branch(branch.copyWith(end: v))),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (!widget.editingDefault) ...[
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('同时应用到子主题'),
                    value: _descendants,
                    onChanged: (v) => setState(() => _descendants = v!),
                  ),
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('设为本图默认格式'),
                    value: _default,
                    onChanged: (v) => setState(() => _default = v!),
                  ),
                ],
                if (_error != null)
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    TextButton(onPressed: _restore, child: const Text('恢复默认')),
                    const Spacer(),
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(onPressed: _save, child: const Text('保存')),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BranchPreview extends CustomPainter {
  const _BranchPreview(this.style);
  final BranchStyle style;
  @override
  void paint(Canvas canvas, Size size) => paintBranch(
    canvas,
    branchPath(
      Offset(0, size.height * .75),
      Offset(size.width, size.height * .25),
      style.path,
      false,
    ),
    style,
  );
  @override
  bool shouldRepaint(_BranchPreview old) => old.style != style;
}
