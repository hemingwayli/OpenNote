import '../theme/open_note_icon.dart';
import '../theme/open_note_context_menu.dart';

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/open_note_theme.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

import '../../domain/models.dart';
import '../../domain/topic_style_resolver.dart';
import 'map_title_draft.dart';

class MapOutlinePaneController {
  _MapOutlinePaneState? _state;
  String? _pendingTitleId;
  MapTitleDraft? get titleDraft => _state?._titleDraft;
  void acceptTitle(MapTitleDraft draft) => _state?._acceptTitle(draft);
  void editTitle(String nodeId) {
    _pendingTitleId = nodeId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _state?._consumePendingTitle();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }
}

/// 大纲从现有单父树派生；浏览顺序不写回模型，正文显示与分支折叠独立。
class MapOutlinePane extends StatefulWidget {
  const MapOutlinePane({
    super.key,
    required this.snapshot,
    this.selectedNodeId,
    this.selectedNodeIds,
    required this.onSelect,
    this.onToggleSelection,
    this.onActivate,
    required this.onAction,
    required this.onToggleCollapsed,
    this.canCreate = true,
    this.imagePathResolver,
    this.controller,
    this.onCommitTitle,
    this.onSelectionChanged,
    this.onClipboardAction,
  });

  final MapSnapshot snapshot;
  final String? selectedNodeId;
  final Set<String>? selectedNodeIds;
  final void Function(MapNode) onSelect;
  final void Function(MapNode)? onToggleSelection;
  final void Function(MapNode)? onActivate;
  final void Function(MapNode, String action) onAction;
  final void Function(String nodeId) onToggleCollapsed;
  final bool canCreate;
  final Future<String> Function(String resourceId)? imagePathResolver;
  final MapOutlinePaneController? controller;
  final Future<void> Function()? onCommitTitle;
  final void Function(Set<String> ids, String? primary)? onSelectionChanged;
  final void Function(String action)? onClipboardAction;

  @override
  State<MapOutlinePane> createState() => _MapOutlinePaneState();
}

class _MapOutlinePaneState extends State<MapOutlinePane> {
  static const _blue = OpenNoteTokens.accent;
  static const _bodyStyle = TextStyle(
    fontSize: 16,
    height: 1.6,
    color: OpenNoteTokens.secondary,
  );
  static const _noteStyle = TextStyle(
    fontSize: 16,
    height: 1.6,
    color: OpenNoteTokens.secondary,
  );
  final _scroll = ScrollController();
  final _focus = FocusNode(debugLabel: 'OpenNote 脑图大纲');
  final _titleFocus = FocusNode(debugLabel: 'OpenNote 大纲标题');
  final _titleText = TextEditingController();
  String? _titleNodeId;
  String? _titleCardId;
  int _titleGeneration = 0;
  bool _titleSaving = false;
  String? _rangeAnchor;
  PointerDownEvent? _titlePointerDown;
  ({String nodeId, String cardId, int device, Offset position, Duration time})?
  _lastTitleClick;
  final _selectedRowKey = GlobalKey();
  final _contextMenuController = OpenNoteContextMenuController();
  bool Function()? _menuValid;
  final _rowExtents = <int, double>{};
  final _imagePaths = <String, Future<String>>{};
  Map<String, MapNode> _nodes = {};
  Map<String, TopicStyle> _styles = {};
  List<_OutlineEntry> _rows = [];
  Set<String> _selectedIds = {};
  String? _selectedId;
  String? _pressedNodeId;
  bool _pressedCtrl = false;
  bool _pressedInvalidated = false;
  String? _pendingRevealId;
  bool _revealScheduled = false;
  bool _showBody = false;
  double _layoutWidth = 0;
  TextScaler _textScaler = TextScaler.noScaling;
  TextStyle _baseTextStyle = const TextStyle();
  TextDirection _textDirection = TextDirection.ltr;

  @override
  void initState() {
    super.initState();
    widget.controller?._state = this;
    _syncSelection();
    _pendingRevealId = _selectedId;
    _deriveRows();
    WidgetsBinding.instance.addPostFrameCallback((_) => _consumePendingTitle());
  }

  @override
  void didUpdateWidget(covariant MapOutlinePane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_menuValid?.call() == false) _contextMenuController.cancel();
    if (oldWidget.controller != widget.controller) {
      if (oldWidget.controller?._state == this) {
        oldWidget.controller?._state = null;
      }
      widget.controller?._state = this;
    }
    if (oldWidget.snapshot.map.id != widget.snapshot.map.id ||
        oldWidget.imagePathResolver != widget.imagePathResolver) {
      _imagePaths.clear();
    }
    if (oldWidget.selectedNodeId != widget.selectedNodeId ||
        !setEquals(oldWidget.selectedNodeIds, widget.selectedNodeIds)) {
      final previous = _selectedId;
      _syncSelection();
      if (previous != _selectedId) _pendingRevealId = _selectedId;
    }
    if (oldWidget.snapshot != widget.snapshot) {
      if (oldWidget.snapshot.map.id != widget.snapshot.map.id) _finishTitle();
      if (oldWidget.snapshot.map.id != widget.snapshot.map.id ||
          (_pressedNodeId != null &&
              !widget.snapshot.nodes.any(
                (node) => node.id == _pressedNodeId,
              ))) {
        _pressedInvalidated = _pressedNodeId != null;
        _clearPressed();
      }
      _deriveRows();
      if (_titleNodeId != null &&
          (!_rows.any((row) => row.node.id == _titleNodeId) ||
              _nodes[_titleNodeId]?.cardId != _titleCardId)) {
        _finishTitle();
      }
    }
    if (widget.controller?._pendingTitleId != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _consumePendingTitle(),
      );
    }
  }

  @override
  void deactivate() {
    _contextMenuController.cancel();
    _lastTitleClick = null;
    _titlePointerDown = null;
    _pressedInvalidated = _pressedNodeId != null;
    _clearPressed();
    super.deactivate();
  }

  @override
  void dispose() {
    _contextMenuController.cancel();
    if (widget.controller?._state == this) widget.controller?._state = null;
    _scroll.dispose();
    _focus.dispose();
    _titleFocus.dispose();
    _titleText.dispose();
    super.dispose();
  }

  void _deriveRows() {
    final wasVisible = _rows.any((entry) => entry.node.id == _selectedId);
    _nodes = {for (final node in widget.snapshot.nodes) node.id: node};
    _styles = topicStylesFor(widget.snapshot);
    final children = <String, List<MapNode>>{};
    final ordered = _nodes.values.toList()..sort(_compareNodes);
    final roots = <MapNode>[];
    for (final node in ordered) {
      final parent = node.parentNodeId;
      if (parent == null || !_nodes.containsKey(parent)) {
        roots.add(node);
      } else {
        (children[parent] ??= []).add(node);
      }
    }
    // ordered 已排序，按顺序分配的各同层列表也保持 y/x/id 顺序。
    final rows = <_OutlineEntry>[];
    final visited = <String>{};
    final stack = <({MapNode node, int depth, bool visible})>[];
    void visit(MapNode root) {
      stack.add((node: root, depth: 0, visible: true));
      while (stack.isNotEmpty) {
        final current = stack.removeLast();
        if (!visited.add(current.node.id)) continue;
        final descendants = children[current.node.id] ?? const <MapNode>[];
        if (current.visible) {
          rows.add(
            _OutlineEntry(current.node, current.depth, descendants.length),
          );
        }
        for (var index = descendants.length - 1; index >= 0; index--) {
          stack.add((
            node: descendants[index],
            depth: current.depth + 1,
            visible: current.visible && !current.node.collapsed,
          ));
        }
      }
    }

    for (final root in roots) {
      visit(root);
    }
    // 即便输入快照出现孤立环也能有限显示；隐藏后代已访问，不会冒充根节点。
    for (final node in ordered) {
      if (!visited.contains(node.id)) visit(node);
    }
    _rows = rows;
    _rowExtents.clear();
    _selectedIds.removeWhere((id) => !_nodes.containsKey(id));
    if (!_selectedIds.contains(_selectedId)) {
      _selectedId = _selectedIds.lastOrNull;
    }
    if (!wasVisible && _rows.any((entry) => entry.node.id == _selectedId)) {
      _pendingRevealId = _selectedId;
    }
  }

  double _indent(_OutlineEntry entry, double width) =>
      math.min(entry.depth * 14.0, math.min(112.0, math.max(0.0, width - 220)));

  void _configureLayout(BuildContext context, double width) {
    final scaler = MediaQuery.textScalerOf(context);
    final style = DefaultTextStyle.of(context).style;
    final direction = Directionality.of(context);
    if (_layoutWidth != width ||
        _textScaler != scaler ||
        _baseTextStyle != style ||
        _textDirection != direction) {
      _layoutWidth = width;
      _textScaler = scaler;
      _baseTextStyle = style;
      _textDirection = direction;
      _rowExtents.clear();
    }
  }

  double _measureText(String text, TextStyle style, double width) {
    if (text.isEmpty) return 0;
    final painter = TextPainter(
      text: TextSpan(text: text, style: _baseTextStyle.merge(style)),
      textDirection: _textDirection,
      textScaler: _textScaler,
    );
    try {
      painter.layout(maxWidth: width);
      return painter.height;
    } finally {
      painter.dispose();
    }
  }

  double _rowExtent(int index) {
    final header = _headerExtent(_rows[index].node);
    if (!_showBody) return header;
    return _rowExtents.putIfAbsent(index, () {
      final entry = _rows[index];
      final card = widget.snapshot.cards[entry.node.cardId];
      if (card == null) return header;
      final width = math.max(
        1.0,
        _layoutWidth - _indent(entry, _layoutWidth) - 6 - 30 - 28,
      );
      return header +
          12 +
          (card.imageResourceId == null ? 0 : 144) +
          _measureText(
            card.body.isEmpty ? card.excerptSnapshot : card.body,
            _bodyStyle,
            width,
          ) +
          (card.note.isEmpty
              ? 0
              : 6 + _measureText(card.note, _noteStyle, width));
    });
  }

  double _headerExtent(MapNode node) => math.max(
    48.0,
    _textScaler.scale(_styles[node.id]!.surface.textSize) * 1.4 + 16,
  );

  void _scheduleReveal() {
    if (_pendingRevealId == null ||
        _revealScheduled ||
        !_rows.any((entry) => entry.node.id == _pendingRevealId)) {
      return;
    }
    _revealScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _revealScheduled = false;
      if (!mounted || !_scroll.hasClients) return;
      final id = _pendingRevealId;
      final index = _rows.indexWhere((entry) => entry.node.id == id);
      if (id == null || index < 0) return;
      var offset = 0.0;
      for (var row = 0; row < index; row++) {
        offset += _rowExtent(row);
      }
      // 不等整本正文预先布局；先按同一行高规则到达目标，再用实际控件校正。
      _scroll.jumpTo(offset);
      _pendingRevealId = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _selectedId != id) return;
        final rowContext = _selectedRowKey.currentContext;
        if (rowContext != null) {
          Scrollable.ensureVisible(
            rowContext,
            alignment: 0,
            duration: Duration.zero,
          );
        }
      });
    });
  }

  void _setBodyVisible(bool value) => setState(() {
    _showBody = value;
    _rowExtents.clear();
  });

  static int _compareNodes(MapNode left, MapNode right) =>
      compareMapNodes(left, right);

  bool _hasSource(MapNode node) =>
      (widget.snapshot.anchors[node.cardId] ?? const []).isNotEmpty;

  Future<String>? _imagePath(String resourceId) {
    final resolver = widget.imagePathResolver;
    if (resolver == null) return null;
    // 虚拟行或选中边框重建不影响不可变资源；仅显示到该图片时才查询。
    return _imagePaths.putIfAbsent(resourceId, () => resolver(resourceId));
  }

  void _syncSelection() {
    _selectedIds = Set.of(
      widget.selectedNodeIds ??
          {if (widget.selectedNodeId != null) widget.selectedNodeId!},
    );
    _selectedId = _selectedIds.contains(widget.selectedNodeId)
        ? widget.selectedNodeId
        : _selectedIds.lastOrNull;
  }

  void _requestFocus() {
    if (_titleNodeId != null) return;
    // 等编辑器的 TapRegion 处理失焦后，再让大纲承接工作台快捷键作用域。
    Future.microtask(() {
      if (mounted && _titleNodeId == null && _focus.canRequestFocus) {
        _focus.requestFocus();
      }
    });
  }

  void _clearPressed([String? nodeId]) {
    if (nodeId != null && _pressedNodeId != nodeId) return;
    _pressedNodeId = null;
    _pressedCtrl = false;
  }

  void _tapRow(MapNode node) {
    if (_pressedInvalidated) return;
    if (_titleNodeId == node.id) return;
    final current = _nodes[node.id];
    if (current == null) return;
    final toggle = _pressedNodeId == node.id && _pressedCtrl;
    _clearPressed();
    if (toggle && widget.onToggleSelection != null) {
      _rangeAnchor = null;
      _requestFocus();
      setState(() {
        if (_selectedIds.remove(node.id)) {
          if (_selectedId == node.id) _selectedId = _selectedIds.lastOrNull;
        } else {
          _selectedIds.add(node.id);
          _selectedId = node.id;
        }
      });
      widget.onToggleSelection!(current);
    } else {
      _select(current, activate: true);
    }
  }

  void _select(MapNode node, {bool activate = false}) {
    _rangeAnchor = null;
    _requestFocus();
    setState(() {
      _selectedIds = {node.id};
      _selectedId = node.id;
    });
    widget.onSelect(node);
    if (activate) widget.onActivate?.call(node);
  }

  MapTitleDraft? get _titleDraft {
    final node = _nodes[_titleNodeId];
    return node == null
        ? null
        : MapTitleDraft(
            widget.snapshot.map.id,
            node.id,
            _titleCardId!,
            _titleText.text,
            _titleGeneration,
          );
  }

  void _consumePendingTitle() {
    if (!mounted ||
        !widget.canCreate ||
        widget.onCommitTitle == null ||
        _titleSaving) {
      return;
    }
    final id = widget.controller?._pendingTitleId;
    if (id == null || !_rows.any((row) => row.node.id == id)) return;
    widget.controller?._pendingTitleId = null;
    _beginTitle(id);
  }

  void _beginTitle(String id, {String? replaceWith}) {
    if (!widget.canCreate || widget.onCommitTitle == null || _titleSaving) {
      return;
    }
    if (_titleNodeId != null && _titleNodeId != id) {
      unawaited(
        _commitTitle().then((_) {
          if (mounted && _titleNodeId == null && _selectedId == id) {
            _beginTitle(id, replaceWith: replaceWith);
          }
        }),
      );
      return;
    }
    final node = _nodes[id];
    final card = widget.snapshot.cards[node?.cardId];
    if (node == null ||
        card == null ||
        !_rows.any((row) => row.node.id == id)) {
      return;
    }
    _lastTitleClick = null;
    _titlePointerDown = null;
    // 键盘与标题双击已有选择，创建命令也先交接身份；不再排入一次会提交新草稿的选择。
    _rangeAnchor = null;
    final title = replaceWith ?? card.title;
    _titleText.value = TextEditingValue(
      text: title,
      selection: replaceWith == null
          ? TextSelection(baseOffset: 0, extentOffset: title.length)
          : TextSelection.collapsed(offset: title.length),
    );
    setState(() {
      if (!_selectedIds.contains(id)) _selectedIds = {id};
      _selectedId = id;
      _titleNodeId = id;
      _titleCardId = node.cardId;
      _titleGeneration++;
      _pendingRevealId = id;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _titleNodeId == id) _titleFocus.requestFocus();
    });
  }

  void _finishTitle() {
    if (_titleNodeId == null) return;
    final hadFocus = _titleFocus.hasFocus;
    _titleNodeId = null;
    _titleCardId = null;
    _titleGeneration++;
    if (mounted && hadFocus) _focus.requestFocus();
  }

  void _acceptTitle(MapTitleDraft draft) {
    if (!mounted ||
        draft.generation != _titleGeneration ||
        draft.nodeId != _titleNodeId ||
        draft.cardId != _titleCardId ||
        draft.title != _titleText.text) {
      return;
    }
    setState(_finishTitle);
  }

  Future<void> _commitTitle({String? nextAction}) async {
    if (_titleSaving || _titleNodeId == null) return;
    final node = _nodes[_titleNodeId];
    final mapId = widget.snapshot.map.id;
    setState(() => _titleSaving = true);
    try {
      await widget.onCommitTitle?.call();
      if (mounted &&
          widget.snapshot.map.id == mapId &&
          _titleNodeId == null &&
          node != null &&
          nextAction != null) {
        widget.onAction(node, nextAction);
      }
    } catch (_) {
      // 工作台负责显示失败；大纲保持目标与草稿，允许修正后重试。
      if (mounted && widget.snapshot.map.id == mapId) {
        _titleFocus.requestFocus();
      }
    } finally {
      if (mounted) {
        setState(() => _titleSaving = false);
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _consumePendingTitle(),
        );
      }
    }
  }

  void _titleClick(MapNode node, PointerUpEvent event) {
    final down = _titlePointerDown;
    _titlePointerDown = null;
    if (down == null ||
        down.pointer != event.pointer ||
        (down.position - event.position).distance > kTouchSlop ||
        event.timeStamp - down.timeStamp > kLongPressTimeout ||
        event.kind != PointerDeviceKind.mouse ||
        HardwareKeyboard.instance.isControlPressed) {
      _lastTitleClick = null;
      return;
    }
    final previous = _lastTitleClick;
    _lastTitleClick = (
      nodeId: node.id,
      cardId: node.cardId,
      device: event.device,
      position: event.position,
      time: event.timeStamp,
    );
    if (previous != null &&
        previous.nodeId == node.id &&
        previous.cardId == node.cardId &&
        previous.device == event.device &&
        event.timeStamp - previous.time <= kDoubleTapTimeout &&
        event.timeStamp - previous.time >= kDoubleTapMinTime &&
        (previous.position - event.position).distance <= kDoubleTapSlop) {
      _beginTitle(node.id);
    }
  }

  void _replaceSelection(Set<String> ids, String? primary) {
    setState(() {
      _selectedIds = ids;
      _selectedId = ids.contains(primary) ? primary : ids.lastOrNull;
      _pendingRevealId = _selectedId;
    });
    widget.onSelectionChanged?.call(Set.unmodifiable(ids), _selectedId);
  }

  void _navigate(LogicalKeyboardKey key, {required bool extend}) {
    if (_rows.isEmpty) return;
    final index = _rows.indexWhere((row) => row.node.id == _selectedId);
    final current = index < 0 ? null : _rows[index];
    int? targetIndex;
    if (current == null || key == LogicalKeyboardKey.home) {
      targetIndex = 0;
    } else if (key == LogicalKeyboardKey.end) {
      targetIndex = _rows.length - 1;
    } else if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown) {
      targetIndex = (index + (key == LogicalKeyboardKey.arrowUp ? -1 : 1))
          .clamp(0, _rows.length - 1);
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      if (current.childCount > 0 && !current.node.collapsed) {
        widget.onToggleCollapsed(current.node.id);
        return;
      }
      final parentIndex = _rows.indexWhere(
        (row) => row.node.id == current.node.parentNodeId,
      );
      if (parentIndex >= 0) targetIndex = parentIndex;
    } else if (key == LogicalKeyboardKey.arrowRight && current.childCount > 0) {
      if (current.node.collapsed) {
        widget.onToggleCollapsed(current.node.id);
        return;
      }
      targetIndex = index + 1;
    }
    if (targetIndex == null || targetIndex >= _rows.length) return;
    final target = _rows[targetIndex].node;
    if (extend && widget.onSelectionChanged != null) {
      _rangeAnchor ??= current?.node.id ?? target.id;
      final anchorIndex = _rows.indexWhere(
        (row) => row.node.id == _rangeAnchor,
      );
      final first = math.min(
        anchorIndex < 0 ? targetIndex : anchorIndex,
        targetIndex,
      );
      final last = math.max(
        anchorIndex < 0 ? targetIndex : anchorIndex,
        targetIndex,
      );
      _replaceSelection({
        for (var row = first; row <= last; row++) _rows[row].node.id,
      }, target.id);
    } else {
      _select(target);
      setState(() => _pendingRevealId = target.id);
    }
  }

  KeyEventResult _key(FocusNode focus, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final textFocus =
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<EditableText>() !=
        null;
    if (textFocus) return KeyEventResult.ignored;
    _lastTitleClick = null;
    final keyboard = HardwareKeyboard.instance;
    final key = event.logicalKey;
    if (keyboard.isControlPressed && widget.onClipboardAction != null) {
      final action = switch (key) {
        LogicalKeyboardKey.keyC => 'copy',
        LogicalKeyboardKey.keyX => 'cut',
        LogicalKeyboardKey.keyV => 'paste',
        _ => null,
      };
      if (action != null) {
        if (action == 'copy' || widget.canCreate) {
          widget.onClipboardAction!(action);
        }
        return KeyEventResult.handled;
      }
    }
    if (keyboard.isControlPressed &&
        key == LogicalKeyboardKey.keyA &&
        widget.onSelectionChanged != null) {
      _rangeAnchor = null;
      _replaceSelection({
        for (final row in _rows) row.node.id,
      }, _selectedId ?? _rows.firstOrNull?.node.id);
      return KeyEventResult.handled;
    }
    final node = _nodes[_selectedId];
    if (keyboard.isAltPressed && node != null && widget.canCreate) {
      final action = switch (key) {
        LogicalKeyboardKey.arrowUp => 'moveBefore',
        LogicalKeyboardKey.arrowDown => 'moveAfter',
        LogicalKeyboardKey.arrowLeft => 'promote',
        LogicalKeyboardKey.arrowRight => 'demote',
        _ => null,
      };
      if (action != null) {
        widget.onAction(node, action);
        return KeyEventResult.handled;
      }
    }
    if (!keyboard.isControlPressed &&
        !keyboard.isAltPressed &&
        !keyboard.isMetaPressed &&
        const [
          LogicalKeyboardKey.arrowUp,
          LogicalKeyboardKey.arrowDown,
          LogicalKeyboardKey.arrowLeft,
          LogicalKeyboardKey.arrowRight,
          LogicalKeyboardKey.home,
          LogicalKeyboardKey.end,
        ].contains(key)) {
      _navigate(key, extend: keyboard.isShiftPressed);
      return KeyEventResult.handled;
    }
    if (node == null) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.f2) {
      widget.onAction(node, 'editSelected');
      return KeyEventResult.handled;
    }
    if (!keyboard.isAltPressed && !keyboard.isMetaPressed && widget.canCreate) {
      if (key == LogicalKeyboardKey.enter) {
        widget.onAction(
          node,
          keyboard.isControlPressed
              ? 'newParent'
              : keyboard.isShiftPressed
              ? 'newSiblingBefore'
              : 'newSibling',
        );
        return KeyEventResult.handled;
      }
      if (!keyboard.isControlPressed &&
          !keyboard.isShiftPressed &&
          (key == LogicalKeyboardKey.tab || key == LogicalKeyboardKey.insert)) {
        widget.onAction(node, 'newChild');
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.delete) {
        widget.onAction(
          node,
          keyboard.isControlPressed
              ? 'removeTopicOnly'
              : 'removeSelectedBranches',
        );
        return KeyEventResult.handled;
      }
    }
    if (widget.onCommitTitle != null &&
        !keyboard.isControlPressed &&
        !keyboard.isAltPressed &&
        !keyboard.isMetaPressed) {
      if (key == LogicalKeyboardKey.space) {
        _beginTitle(node.id);
        return KeyEventResult.handled;
      }
      final character = event.character;
      if (character != null &&
          character.isNotEmpty &&
          character.runes.every((r) => r >= 32 && r != 127)) {
        _beginTitle(node.id, replaceWith: character);
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  Widget _titleField() => Focus(
    onKeyEvent: (_, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        if (!_titleSaving) setState(_finishTitle);
        return KeyEventResult.handled;
      }
      // 中文候选词确认属于输入法；只有组合态结束后才提交主题。
      if (_titleText.value.composing.isValid &&
          !_titleText.value.composing.isCollapsed) {
        return KeyEventResult.ignored;
      }
      if (event.logicalKey == LogicalKeyboardKey.enter) {
        unawaited(_commitTitle());
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.tab &&
          !HardwareKeyboard.instance.isShiftPressed) {
        unawaited(_commitTitle(nextAction: 'newChild'));
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: TextField(
      key: const ValueKey('outline-title-input'),
      controller: _titleText,
      focusNode: _titleFocus,
      readOnly: _titleSaving,
      textInputAction: TextInputAction.done,
      onSubmitted: (_) => unawaited(_commitTitle()),
      onTapOutside: (_) => unawaited(_commitTitle()),
      style: const TextStyle(fontSize: 16, color: OpenNoteTokens.text),
      decoration: const InputDecoration(
        isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        hintText: '主题标题',
      ),
    ),
  );

  void _action(String nodeId, String action) {
    _lastTitleClick = null;
    _titlePointerDown = null;
    final node = _nodes[nodeId];
    if (node == null) return;
    if (const [
          'newChild',
          'newSibling',
          'newSiblingBefore',
          'newParent',
        ].contains(action) &&
        !widget.canCreate) {
      return;
    }
    if (action == 'editTitle' && widget.onCommitTitle != null) {
      _beginTitle(nodeId);
      return;
    }
    if (const ['copy', 'cut', 'paste'].contains(action)) {
      widget.onClipboardAction?.call(action);
      return;
    }
    if (action == 'source' && !_hasSource(node)) return;
    if (!_selectedIds.contains(node.id) ||
        (_selectedIds.length != 1 &&
            !const ['topicStyle', 'branchStructure'].contains(action))) {
      _select(node);
    }
    widget.onAction(node, action);
  }

  List<OpenNoteMenuEntry<String>> _menuItems(MapNode node) => [
    if (widget.onCommitTitle != null)
      const OpenNoteMenuEntry('editTitle', '修改标题', icon: Icons.title),
    const OpenNoteMenuEntry('edit', '编辑卡片', icon: Icons.edit_outlined),
    const OpenNoteMenuEntry('topicStyle', '主题格式…', icon: Icons.format_shapes),
    const OpenNoteMenuEntry(
      'branchStructure',
      '分支结构…',
      icon: Icons.account_tree_outlined,
    ),
    OpenNoteMenuEntry(
      'source',
      '回到原文',
      icon: Icons.menu_book_outlined,
      enabled: _hasSource(node),
    ),
    const OpenNoteMenuEntry.divider(),
    OpenNoteMenuEntry(
      'newChild',
      '新建子主题',
      icon: Icons.subdirectory_arrow_right,
      enabled: widget.canCreate,
    ),
    OpenNoteMenuEntry(
      'newSibling',
      '新建同级主题',
      icon: Icons.add,
      enabled: widget.canCreate,
    ),
    if (widget.onCommitTitle != null) ...[
      OpenNoteMenuEntry(
        'newSiblingBefore',
        '在上方新建同级主题',
        icon: Icons.add,
        enabled: widget.canCreate,
      ),
      OpenNoteMenuEntry(
        'newParent',
        '插入上层主题',
        icon: Icons.account_tree_outlined,
        enabled: widget.canCreate,
      ),
    ],
    if (widget.onClipboardAction != null) ...[
      const OpenNoteMenuEntry.divider(),
      const OpenNoteMenuEntry('copy', '复制', icon: Icons.content_copy),
      OpenNoteMenuEntry(
        'cut',
        '剪切',
        icon: Icons.content_cut,
        enabled: widget.canCreate,
      ),
      OpenNoteMenuEntry(
        'paste',
        '粘贴',
        icon: Icons.content_paste,
        enabled: widget.canCreate,
      ),
    ],
    const OpenNoteMenuEntry('color', '卡片颜色…', icon: Icons.palette_outlined),
    if (widget.snapshot.map.layout == MapLayoutKind.mindMap &&
        node.parentNodeId != null) ...[
      const OpenNoteMenuEntry('branchLeft', '分支移到左侧', icon: Icons.arrow_back),
      const OpenNoteMenuEntry(
        'branchRight',
        '分支移到右侧',
        icon: Icons.arrow_forward,
      ),
    ],
    const OpenNoteMenuEntry('copyBranch', '复制独立分支…', icon: Icons.copy_outlined),
    const OpenNoteMenuEntry.divider(),
    const OpenNoteMenuEntry(
      'removeBranch',
      '分支卡片移入回收站',
      icon: Icons.delete_outline,
      danger: true,
    ),
  ];

  Future<void> _contextMenu(MapNode node, Offset globalPosition) async {
    final mapId = widget.snapshot.map.id;
    _select(node);
    bool valid() =>
        mounted &&
        widget.snapshot.map.id == mapId &&
        widget.snapshot.nodes.any(
          (current) => current.id == node.id && current.cardId == node.cardId,
        );
    _menuValid = valid;
    final action = await showOpenNoteContextMenu<String>(
      context: context,
      position: globalPosition,
      entries: _menuItems(node),
      controller: _contextMenuController,
      isValid: valid,
    );
    if (identical(_menuValid, valid)) _menuValid = null;
    if (!valid() || action == null) return;
    _action(node.id, action);
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _focus,
    onKeyEvent: _key,
    child: ColoredBox(
      color: Colors.white,
      child: Column(
        children: [
          Container(
            height: 42,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: OpenNoteTokens.border)),
            ),
            child: Row(
              children: [
                const Spacer(),
                IconButton(
                  key: const ValueKey('outline-single-line'),
                  tooltip: '单行显示',
                  color: !_showBody ? _blue : OpenNoteTokens.secondary,
                  onPressed: () => _setBodyVisible(false),
                  icon: const OpenNoteIcon(Icons.short_text, size: 20),
                ),
                IconButton(
                  key: const ValueKey('outline-show-body'),
                  tooltip: '显示正文',
                  color: _showBody ? _blue : OpenNoteTokens.secondary,
                  onPressed: () => _setBodyVisible(true),
                  icon: const OpenNoteIcon(Icons.notes_outlined, size: 18),
                ),
              ],
            ),
          ),
          Expanded(
            child: _rows.isEmpty
                ? const Center(
                    child: Text(
                      '脑图还没有主题',
                      style: TextStyle(color: OpenNoteTokens.secondary),
                    ),
                  )
                : LayoutBuilder(
                    builder: (context, constraints) {
                      _configureLayout(context, constraints.maxWidth);
                      _scheduleReveal();
                      return ListView.builder(
                        key: const ValueKey('outline-list'),
                        controller: _scroll,
                        padding: EdgeInsets.zero,
                        itemExtentBuilder: (index, _) =>
                            index < _rows.length ? _rowExtent(index) : null,
                        itemCount: _rows.length,
                        itemBuilder: (context, index) => _row(_rows[index]),
                      );
                    },
                  ),
          ),
        ],
      ),
    ),
  );

  Widget _row(_OutlineEntry entry) {
    final node = entry.node;
    final menuMapId = widget.snapshot.map.id;
    final card = widget.snapshot.cards[node.cardId];
    final title = card == null || card.title.trim().isEmpty
        ? '无标题卡片'
        : card.title;
    final selected = _selectedIds.contains(node.id);
    final primary = node.id == _selectedId;
    final parsed = int.tryParse(
      (card?.color ?? '').replaceFirst('#', ''),
      radix: 16,
    );
    final accent = Color(0xFF000000 | (parsed ?? 0xF7D976));
    return Semantics(
      key: ValueKey('outline-node-${node.id}'),
      selected: selected,
      value: primary
          ? '主选'
          : selected
          ? '已选'
          : null,
      label: '大纲第 ${entry.depth + 1} 级 $title',
      child: Listener(
        onPointerDown: (event) {
          if (event.buttons != kPrimaryMouseButton) return;
          _pressedInvalidated = false;
          _pressedNodeId = node.id;
          _pressedCtrl =
              widget.onToggleSelection != null &&
              HardwareKeyboard.instance.isControlPressed;
        },
        onPointerCancel: (_) => _clearPressed(node.id),
        child: Material(
          key: ValueKey('outline-row-surface-${node.id}'),
          color: selected ? OpenNoteTokens.background : Colors.white,
          shape: selected
              ? RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6),
                  side: BorderSide(
                    color: primary ? OpenNoteTokens.border : Colors.transparent,
                  ),
                )
              : null,
          child: InkWell(
            onTap: () => _tapRow(node),
            onTapCancel: () => _clearPressed(node.id),
            onSecondaryTapUp: (details) =>
                _contextMenu(node, details.globalPosition),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final indent = _indent(entry, constraints.maxWidth);
                return Padding(
                  padding: EdgeInsets.only(left: indent, right: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        height: _headerExtent(node),
                        child: Row(
                          children: [
                            Container(width: 4, height: 24, color: accent),
                            SizedBox(
                              width: 26,
                              child: entry.childCount == 0
                                  ? const SizedBox.shrink()
                                  : IconButton(
                                      key: ValueKey(
                                        'outline-collapse-${node.id}',
                                      ),
                                      tooltip: node.collapsed ? '展开分支' : '折叠分支',
                                      padding: EdgeInsets.zero,
                                      constraints:
                                          const BoxConstraints.tightFor(
                                            width: 26,
                                            height: 26,
                                          ),
                                      iconSize: 17,
                                      onPressed: () =>
                                          widget.onToggleCollapsed(node.id),
                                      icon: OpenNoteIcon(
                                        node.collapsed
                                            ? Icons.chevron_right
                                            : Icons.expand_more,
                                      ),
                                    ),
                            ),
                            if (indent < entry.depth * 14.0)
                              Padding(
                                padding: const EdgeInsets.only(right: 5),
                                child: Text(
                                  'L${entry.depth + 1}',
                                  key: ValueKey('outline-depth-${node.id}'),
                                  style: const TextStyle(
                                    fontSize: 10,
                                    color: OpenNoteTokens.secondary,
                                  ),
                                ),
                              ),
                            Expanded(
                              child: SizedBox(
                                // 定位只标记标题，切换主选不能销毁正在打开菜单的按钮。
                                key: primary ? _selectedRowKey : null,
                                child: _titleNodeId == node.id
                                    ? _titleField()
                                    : Listener(
                                        onPointerDown: (event) {
                                          _titlePointerDown =
                                              event.buttons ==
                                                  kPrimaryMouseButton
                                              ? event
                                              : null;
                                          if (_titlePointerDown == null) {
                                            _lastTitleClick = null;
                                          }
                                        },
                                        onPointerUp: (event) =>
                                            _titleClick(node, event),
                                        onPointerCancel: (_) {
                                          _titlePointerDown = null;
                                          _lastTitleClick = null;
                                        },
                                        onPointerSignal: (_) {
                                          _titlePointerDown = null;
                                          _lastTitleClick = null;
                                        },
                                        child: Text(
                                          title,
                                          key: ValueKey(
                                            'outline-title-${node.id}',
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: _styles[node.id]!
                                                .surface
                                                .textSize,
                                            fontFamily: _styles[node.id]!
                                                .surface
                                                .fontFamily,
                                            fontStyle:
                                                _styles[node.id]!.surface.italic
                                                ? FontStyle.italic
                                                : FontStyle.normal,
                                            color:
                                                selected &&
                                                    _styles[node.id]!
                                                            .surface
                                                            .textColor ==
                                                        const TopicStyle()
                                                            .surface
                                                            .textColor
                                                ? _blue
                                                : Color(
                                                    int.parse(
                                                          _styles[node.id]!
                                                              .surface
                                                              .textColor
                                                              .substring(1),
                                                          radix: 16,
                                                        ) |
                                                        0xff000000,
                                                  ),
                                            fontWeight:
                                                primary ||
                                                    _styles[node.id]!
                                                        .surface
                                                        .bold
                                                ? FontWeight.w600
                                                : FontWeight.normal,
                                          ),
                                        ),
                                      ),
                              ),
                            ),
                            if (_hasSource(node))
                              SizedBox(
                                width: 28,
                                child: IconButton(
                                  key: ValueKey('outline-source-${node.id}'),
                                  tooltip: '回到原文',
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints.tightFor(
                                    width: 28,
                                    height: 28,
                                  ),
                                  iconSize: 16,
                                  onPressed: () => _action(node.id, 'source'),
                                  icon: const OpenNoteIcon(
                                    Icons.menu_book_outlined,
                                    color: OpenNoteTokens.secondary,
                                  ),
                                ),
                              ),
                            SizedBox(
                              width: 28,
                              child: OpenNoteContextMenuButton<String>(
                                key: ValueKey('outline-menu-${node.id}'),
                                tooltip: '卡片操作',
                                icon: const OpenNoteIcon(
                                  Icons.more_horiz,
                                  size: 18,
                                ),
                                onOpened: () {
                                  if (!_selectedIds.contains(node.id)) {
                                    _select(node);
                                  }
                                },
                                onSelected: (action) =>
                                    _action(node.id, action),
                                entries: () => _menuItems(node),
                                isValid: () =>
                                    mounted &&
                                    widget.snapshot.map.id == menuMapId &&
                                    widget.snapshot.nodes.any(
                                      (current) =>
                                          current.id == node.id &&
                                          current.cardId == node.cardId,
                                    ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (_showBody && card != null) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(30, 0, 28, 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (card.imageResourceId != null)
                                _OutlineImage(
                                  key: ValueKey('outline-image-${node.id}'),
                                  path: _imagePath(card.imageResourceId!),
                                ),
                              if ((card.body.isEmpty
                                      ? card.excerptSnapshot
                                      : card.body)
                                  .isNotEmpty)
                                Text(
                                  card.body.isEmpty
                                      ? card.excerptSnapshot
                                      : card.body,
                                  key: ValueKey('outline-body-${node.id}'),
                                  style: _bodyStyle,
                                ),
                              if (card.note.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 6),
                                  child: Text(
                                    card.note,
                                    key: ValueKey('outline-note-${node.id}'),
                                    style: _noteStyle,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _OutlineEntry {
  const _OutlineEntry(this.node, this.depth, this.childCount);
  final MapNode node;
  final int depth;
  final int childCount;
}

class _OutlineImage extends StatelessWidget {
  const _OutlineImage({super.key, required this.path});
  final Future<String>? path;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 144,
    width: double.infinity,
    child: FutureBuilder<String>(
      key: ValueKey(path),
      future: path,
      builder: (context, snapshot) {
        if (snapshot.hasError || path == null) {
          return const Center(child: Text('截图暂不可用'));
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator(strokeWidth: 2));
        }
        return Image.file(
          File(snapshot.data!),
          fit: BoxFit.contain,
          cacheWidth: 720,
          errorBuilder: (_, _, _) => const Center(child: Text('截图暂不可用')),
        );
      },
    ),
  );
}
