import '../theme/open_note_icon.dart';

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../domain/models.dart';
import '../theme/open_note_theme.dart';
import 'card_color_palette.dart';

class CardEditorController {
  Future<void> Function()? flushDelegate;
  void Function(String, bool Function())? _focusBodyDelegate;
  Future<void> flush() async => await flushDelegate?.call();

  void focusBody(String cardId, {required bool Function() isCurrent}) =>
      _focusBodyDelegate?.call(cardId, isCurrent);
}

/// 文本撤销由各输入框处理；一次自动保存提交标题、正文和个人思考的完整快照。
class CardEditor extends StatefulWidget {
  const CardEditor({
    super.key,
    required this.card,
    required this.controller,
    required this.onSave,
    required this.onBackToSource,
    required this.imagePath,
    required this.onSaveState,
    required this.onClose,
    this.sourceAvailable,
    this.autofocusBody = false,
    this.onColorChanged,
  });
  final NoteCard card;
  final CardEditorController controller;
  final Future<void> Function(
    String title,
    String body,
    List<PersonalThought> thoughts,
  )
  onSave;
  final Future<String>? imagePath;
  final VoidCallback onBackToSource;
  final Future<bool>? sourceAvailable;
  final void Function(String) onSaveState;
  final VoidCallback onClose;
  final bool autofocusBody;
  final Future<void> Function(String color)? onColorChanged;
  @override
  State<CardEditor> createState() => _CardEditorState();
}

class _CardEditorState extends State<CardEditor> {
  late final TextEditingController _title;
  late final TextEditingController _body;
  final _thoughts = <_ThoughtDraft>[];
  final _bodyFocus = FocusNode(debugLabel: 'OpenNote 卡片正文');
  Timer? _timer;
  bool _dirty = false;
  int _pendingSaves = 0;
  Future<void> _saving = Future.value();
  bool _changingColor = false;
  FocusNode? _colorReturnFocus;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.card.title);
    _body = TextEditingController(text: widget.card.body);
    _syncThoughts(widget.card.thoughts);
    _bindController();
    if (widget.autofocusBody) _focusBodyAfterLayout();
  }

  @override
  void didUpdateWidget(CardEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _unbindController(oldWidget.controller);
      _bindController();
    }
    if (!oldWidget.autofocusBody && widget.autofocusBody) {
      _focusBodyAfterLayout();
    }
    if (!_dirty && _pendingSaves == 0 && oldWidget.card != widget.card) {
      // 撤销或外部命令更新后，输入框与已提交记录一致。
      _replace(_title, widget.card.title);
      _replace(_body, widget.card.body);
      _syncThoughts(widget.card.thoughts);
    }
  }

  void _focusBodyAfterLayout() {
    // 创建时主动交接焦点；普通 autofocus 不会替换脑图已有的焦点。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.autofocusBody) _bodyFocus.requestFocus();
    });
  }

  void _bindController() {
    widget.controller.flushDelegate = _flush;
    widget.controller._focusBodyDelegate = _requestBodyFocus;
  }

  void _unbindController(CardEditorController controller) {
    if (controller.flushDelegate == _flush) controller.flushDelegate = null;
    if (controller._focusBodyDelegate == _requestBodyFocus) {
      controller._focusBodyDelegate = null;
    }
  }

  void _requestBodyFocus(String cardId, bool Function() isCurrent) {
    final controller = widget.controller;
    if (!mounted ||
        widget.card.id != cardId ||
        controller._focusBodyDelegate != _requestBodyFocus ||
        !isCurrent()) {
      return;
    }
    // 工作台已等待布局完成，避免再次延迟后抢走用户选中的字段焦点。
    _bodyFocus.requestFocus();
  }

  void _replace(TextEditingController controller, String value) {
    if (controller.text != value) controller.text = value;
  }

  List<PersonalThought> _thoughtSnapshot() => List.unmodifiable([
    for (final draft in _thoughts)
      if (draft.controller.text.isNotEmpty)
        PersonalThought(id: draft.id, text: draft.controller.text),
  ]);

  void _syncThoughts(List<PersonalThought> thoughts) {
    // 自己的保存回读不重建输入框，保留空草稿、选区、焦点及输入法状态。
    if (_thoughts.isNotEmpty && listEquals(_thoughtSnapshot(), thoughts)) {
      return;
    }
    final existing = {for (final draft in _thoughts) draft.id: draft};
    _thoughts.clear();
    for (final thought in thoughts) {
      final draft = existing.remove(thought.id) ?? _ThoughtDraft(thought.id);
      _replace(draft.controller, thought.text);
      _thoughts.add(draft);
    }
    for (final draft in existing.values) {
      _retireThought(draft);
    }
    if (_thoughts.isEmpty) {
      _thoughts.add(_ThoughtDraft('${widget.card.id}:thought'));
    }
  }

  void _retireThought(_ThoughtDraft draft) {
    // 等旧输入框卸载后再释放控制器，避免删除或撤销期间访问已释放对象。
    WidgetsBinding.instance.addPostFrameCallback((_) => draft.dispose());
  }

  void _addThought() {
    final draft = _thoughts.last.controller.text.isEmpty
        ? _thoughts.last
        : _ThoughtDraft(const Uuid().v4());
    if (!_thoughts.contains(draft)) setState(() => _thoughts.add(draft));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _thoughts.contains(draft)) draft.focus.requestFocus();
    });
  }

  void _removeThought(_ThoughtDraft draft) {
    setState(() {
      _thoughts.remove(draft);
      if (_thoughts.isEmpty) {
        _thoughts.add(_ThoughtDraft(const Uuid().v4()));
      }
    });
    _retireThought(draft);
    _changed('');
  }

  void _changed(String _) {
    _dirty = true;
    widget.onSaveState('待保存…');
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 500), () {
      unawaited(
        _flush().catchError((Object error) {
          if (mounted) widget.onSaveState('保存失败：$error');
        }),
      );
    });
  }

  Future<void> _flush() async {
    _timer?.cancel();
    if (!_dirty) return _saving;
    final title = _title.text;
    final body = _body.text;
    final thoughts = _thoughtSnapshot();
    _dirty = false;
    _pendingSaves++;
    final callback = widget.onSave;
    _saving = _saving.catchError((Object _) {}).then((_) async {
      if (mounted) widget.onSaveState('正在保存…');
      try {
        await callback(title, body, thoughts);
        if (mounted) widget.onSaveState(_dirty ? '待保存…' : '资料已保存');
      } catch (_) {
        _dirty = true;
        rethrow;
      } finally {
        _pendingSaves--;
      }
    });
    return _saving;
  }

  Future<void> _changeColor(String color) async {
    final callback = widget.onColorChanged;
    if (!mounted || callback == null || _changingColor) return;
    _restoreColorFocus();
    setState(() => _changingColor = true);
    try {
      await callback(color);
    } catch (error) {
      if (mounted) widget.onSaveState('保存失败：$error');
    } finally {
      if (mounted) setState(() => _changingColor = false);
    }
  }

  void _restoreColorFocus() {
    final focus = _colorReturnFocus;
    _colorReturnFocus = null;
    // 只在菜单关闭当下交还焦点，不在异步保存结束后抢用户新选中的字段。
    if (mounted && focus?.context != null) focus!.requestFocus();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _unbindController(widget.controller);
    _title.dispose();
    _body.dispose();
    for (final draft in _thoughts) {
      draft.dispose();
    }
    _bodyFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    child: Column(
      children: [
        _CardEditorHeader(
          onClose: widget.onClose,
          sourceAvailable: widget.sourceAvailable,
          onBackToSource: widget.onBackToSource,
          colorAction: widget.onColorChanged == null
              ? null
              : Listener(
                  // 指针按下时记住输入焦点，避免按钮本身的焦点替换原字段。
                  onPointerDown: (_) =>
                      _colorReturnFocus = FocusManager.instance.primaryFocus,
                  child: PopupMenuButton<String>(
                    key: const Key('card-editor-color'),
                    tooltip: '卡片颜色',
                    enabled: !_changingColor,
                    constraints: const BoxConstraints(
                      minWidth: 292,
                      maxWidth: 292,
                    ),
                    position: PopupMenuPosition.under,
                    color: OpenNoteTokens.surface,
                    surfaceTintColor: Colors.transparent,
                    elevation: 3,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                      side: const BorderSide(color: OpenNoteTokens.border),
                    ),
                    onSelected: _changeColor,
                    onOpened: () => _colorReturnFocus ??=
                        FocusManager.instance.primaryFocus,
                    onCanceled: _restoreColorFocus,
                    itemBuilder: (context) => [
                      PopupMenuItem<String>(
                        enabled: false,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: CardColorPalette(
                          compact: true,
                          currentColor: widget.card.color,
                          onSelected: (color) => Navigator.pop(context, color),
                        ),
                      ),
                    ],
                    icon: Container(
                      width: 16,
                      height: 16,
                      decoration: BoxDecoration(
                        color: cardColor(widget.card.color),
                        shape: BoxShape.circle,
                        border: Border.all(color: const Color(0x18262B33)),
                      ),
                    ),
                  ),
                ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  key: const Key('card-title'),
                  controller: _title,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    height: 1.5,
                  ),
                  maxLines: 3,
                  minLines: 1,
                  decoration: const InputDecoration(
                    hintText: '卡片标题',
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: OpenNoteTokens.accent),
                    ),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 0,
                      vertical: 8,
                    ),
                  ),
                  onChanged: _changed,
                ),
                const SizedBox(height: 12),
                const Divider(height: 1),
                const SizedBox(height: 16),
                if (widget.imagePath != null) ...[
                  FutureBuilder<String>(
                    future: widget.imagePath,
                    builder: (context, snapshot) => snapshot.hasData
                        ? Image.file(
                            File(snapshot.data!),
                            cacheWidth: 1024,
                            errorBuilder: (_, error, trace) =>
                                Text('图片读取失败：$error'),
                          )
                        : const LinearProgressIndicator(),
                  ),
                  const SizedBox(height: 14),
                ],
                TextField(
                  key: const Key('card-body'),
                  controller: _body,
                  focusNode: _bodyFocus,
                  minLines: 3,
                  maxLines: 12,
                  style: const TextStyle(fontSize: 16, height: 1.6),
                  decoration: _blockDecoration('正文'),
                  onChanged: _changed,
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '个人思考',
                        style: TextStyle(
                          fontSize: 12,
                          color: OpenNoteTokens.secondary,
                        ),
                      ),
                    ),
                    IconButton(
                      key: const Key('card-add-thought'),
                      tooltip: '添加个人思考',
                      onPressed: _addThought,
                      icon: const OpenNoteIcon(Icons.add, size: 19),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                for (var i = 0; i < _thoughts.length; i++) ...[
                  _thoughtBlock(_thoughts[i], i),
                  if (i < _thoughts.length - 1) const SizedBox(height: 12),
                ],
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _body,
                  builder: (context, value, _) {
                    final original = widget.card.excerptSnapshot;
                    // 按当前草稿精确比较；显隐不等待自动保存，也不改变原始摘录。
                    if (original.isEmpty || value.text == original) {
                      return const SizedBox.shrink();
                    }
                    return Column(
                      key: const Key('card-original-section'),
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SizedBox(height: 24),
                        ExpansionTile(
                          key: ValueKey('card-original-${widget.card.id}'),
                          tilePadding: EdgeInsets.zero,
                          title: const Tooltip(
                            message: '只读来源',
                            child: Text(
                              '原文',
                              style: TextStyle(
                                fontSize: 12,
                                color: OpenNoteTokens.secondary,
                              ),
                            ),
                          ),
                          children: [
                            SelectableText(
                              original,
                              style: const TextStyle(
                                fontSize: 16,
                                height: 1.6,
                                color: OpenNoteTokens.secondary,
                              ),
                            ),
                          ],
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );

  Widget _thoughtBlock(_ThoughtDraft draft, int index) => Focus(
    focusNode: draft.rowFocus,
    canRequestFocus: false,
    onFocusChange: (_) {
      if (mounted) setState(() {});
    },
    child: GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: draft.focus.requestFocus,
      child: Container(
        key: ValueKey('card-thought-row-${draft.id}'),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: OpenNoteTokens.background,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: draft.rowFocus.hasFocus
                ? OpenNoteTokens.accent.withValues(alpha: .45)
                : Colors.transparent,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Semantics(
                label: '个人思考',
                child: TextField(
                  key: index == 0
                      ? const Key('card-note')
                      : ValueKey('card-thought-${draft.id}'),
                  controller: draft.controller,
                  focusNode: draft.focus,
                  minLines: 1,
                  maxLines: null,
                  style: const TextStyle(fontSize: 16, height: 1.6),
                  decoration: const InputDecoration(
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    contentPadding: EdgeInsets.zero,
                    isDense: true,
                  ),
                  onChanged: _changed,
                ),
              ),
            ),
            const SizedBox(width: 4),
            // 保留操作位置，选中或切换焦点时文字和卡片高度不跳动。
            SizedBox(
              width: 36,
              height: 36,
              child: draft.rowFocus.hasFocus
                  ? IconButton(
                      key: ValueKey('card-delete-thought-${draft.id}'),
                      tooltip: '删除这条思考',
                      onPressed: () => _removeThought(draft),
                      icon: const OpenNoteIcon(Icons.delete_outline, size: 17),
                    )
                  : null,
            ),
          ],
        ),
      ),
    ),
  );

  InputDecoration _blockDecoration(String label) => InputDecoration(
    labelText: label,
    floatingLabelBehavior: FloatingLabelBehavior.always,
    alignLabelWithHint: true,
    filled: false,
    contentPadding: const EdgeInsets.symmetric(vertical: 14),
    border: InputBorder.none,
    enabledBorder: InputBorder.none,
    focusedBorder: const UnderlineInputBorder(
      borderSide: BorderSide(color: OpenNoteTokens.accent),
    ),
  );
}

/// 同项目切换脑图或目标删除后保留面板，只提示重新选择。
class CardEditorPlaceholder extends StatelessWidget {
  const CardEditorPlaceholder({super.key, required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    child: Column(
      children: [
        _CardEditorHeader(onClose: onClose),
        const Expanded(
          child: Center(
            child: Text(
              '请选择卡片',
              style: TextStyle(color: OpenNoteTokens.secondary, fontSize: 14),
            ),
          ),
        ),
      ],
    ),
  );
}

class _CardEditorHeader extends StatelessWidget {
  const _CardEditorHeader({
    required this.onClose,
    this.sourceAvailable,
    this.onBackToSource,
    this.colorAction,
  });

  final VoidCallback onClose;
  final Future<bool>? sourceAvailable;
  final VoidCallback? onBackToSource;
  final Widget? colorAction;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 56,
    child: Row(
      children: [
        const SizedBox(width: 24),
        const Text(
          '卡片笔记',
          style: TextStyle(fontSize: 13, color: OpenNoteTokens.secondary),
        ),
        const Spacer(),
        ?colorAction,
        FutureBuilder<bool>(
          future: sourceAvailable,
          builder: (context, snapshot) => snapshot.data == true
              ? IconButton(
                  tooltip: '回到原文',
                  onPressed: onBackToSource,
                  icon: const OpenNoteIcon(Icons.menu_book_outlined, size: 19),
                )
              : const SizedBox.shrink(),
        ),
        IconButton(
          tooltip: '收起编辑',
          onPressed: onClose,
          icon: const OpenNoteIcon(Icons.close, size: 19),
        ),
      ],
    ),
  );
}

class _ThoughtDraft {
  _ThoughtDraft(this.id);

  final String id;
  final controller = TextEditingController();
  final focus = FocusNode(debugLabel: 'OpenNote 个人思考');
  final rowFocus = FocusNode(debugLabel: 'OpenNote 个人思考条目');

  void dispose() {
    controller.dispose();
    focus.dispose();
    rowFocus.dispose();
  }
}
