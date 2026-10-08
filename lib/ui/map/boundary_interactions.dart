part of 'mind_map_pane.dart';

extension _BoundaryInteractions on _MindMapPaneState {
  MapBoundary? _boundaryById(String id) =>
      widget.snapshot.boundaries.where((b) => b.id == id).firstOrNull;
  MapBoundary _displayBoundary(MapBoundary boundary) =>
      _previewBoundary?.id == boundary.id ? _previewBoundary! : boundary;
  List<BoundaryVisual> get _boundaryVisuals => [
    for (final boundary in widget.snapshot.boundaries)
      ?boundaryVisual(
        _displayBoundary(boundary),
        _nodes.values,
        _shownIds,
        _position,
        auxiliaryRoots: widget.snapshot.summaries
            .map((s) => s.summaryNodeId)
            .toSet(),
      ),
  ];
  String? _hitBoundary(Offset point) => _boundaryVisuals.reversed
      .where((v) => v.hit(point, 8 / _transform.value.getMaxScaleOnAxis()))
      .firstOrNull
      ?.boundary
      .id;
  void _selectBoundary(String id) {
    if (_busy || !_active) return;
    _boundaryUpdate(() {
      _selectedBoundary = id;
      _selectedEdge = null;
      _selectedId = null;
      _selectedIds = {};
      _associationMode = false;
      _associationFrom = null;
    });
    _focus.requestFocus();
    widget.onClearSelection?.call();
  }

  void _createBoundary() {
    if (_selectedIds.isEmpty || widget.onCreateBoundaries == null) return;
    final selected = Set<String>.of(_selectedIds), map = widget.snapshot.map.id;
    _run(() async {
      final ids = await widget.onCreateBoundaries!(selected);
      if (mounted &&
          _active &&
          widget.snapshot.map.id == map &&
          ids.isNotEmpty) {
        _boundaryUpdate(() {
          _selectedBoundary = ids.first;
          _selectedEdge = null;
          _selectedId = null;
          _selectedIds = {};
        });
        widget.onClearSelection?.call();
        _focus.requestFocus();
      }
    }, showProgress: false);
  }

  BoundaryLabelDraft? get _boundaryDraft => _editingBoundary == null
      ? null
      : BoundaryLabelDraft(
          widget.snapshot.map.id,
          _editingBoundary!,
          List.unmodifiable(_boundaryDraftNodes),
          _boundaryText.text,
          _boundaryGeneration,
        );
  void _finishBoundaryLabel() {
    _editingBoundary = null;
    _boundaryDraftNodes = [];
    _boundaryGeneration++;
  }

  void _acceptBoundaryLabel(BoundaryLabelDraft draft) {
    if (draft.mapId != widget.snapshot.map.id ||
        draft.boundaryId != _editingBoundary ||
        draft.generation != _boundaryGeneration ||
        draft.label != _boundaryText.text) {
      return;
    }
    _boundaryUpdate(_finishBoundaryLabel);
    _focus.requestFocus();
  }

  Future<void> _beginBoundaryLabel(String id) async {
    if (_busy ||
        _boundarySaving ||
        !_active ||
        widget.onCommitBoundaryLabel == null) {
      return;
    }
    final map = widget.snapshot.map.id;
    final original = _boundaryById(id);
    if (original == null) return;
    if (_editingBoundary != null && _editingBoundary != id) {
      await _saveBoundaryLabel();
      if (_editingBoundary != null) return;
    }
    try {
      await widget.onPrepareRelationshipEdit?.call();
    } catch (_) {
      // 工作台保留并报告之前未能保存的草稿，不切换焦点或启动另一个编辑器。
      return;
    }
    final boundary = _boundaryById(id);
    if (!mounted ||
        !_active ||
        widget.snapshot.map.id != map ||
        boundary == null ||
        boundary.parentNodeId != original.parentNodeId ||
        !listEquals(boundary.nodeIds, original.nodeIds) ||
        !_boundaryVisuals.any((visual) => visual.boundary.id == id)) {
      return;
    }
    _boundaryUpdate(() {
      _selectedBoundary = id;
      _selectedEdge = null;
      _selectedId = null;
      _selectedIds = {};
      _editingBoundary = id;
      _boundaryDraftNodes = List.of(boundary.nodeIds);
      _boundaryGeneration++;
      _boundaryText.value = TextEditingValue(
        text: boundary.label,
        selection: TextSelection(
          baseOffset: 0,
          extentOffset: boundary.label.length,
        ),
      );
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _editingBoundary == id) _boundaryFocus.requestFocus();
    });
  }

  Future<void> _saveBoundaryLabel() async {
    if (_editingBoundary == null || _boundarySaving) return;
    _boundaryUpdate(() => _boundarySaving = true);
    try {
      await widget.onCommitBoundaryLabel?.call();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
        _boundaryFocus.requestFocus();
      }
    } finally {
      if (mounted) _boundaryUpdate(() => _boundarySaving = false);
    }
  }

  void _syncBoundaryState(MapSnapshot previous) {
    final mapChanged = previous.map.id != widget.snapshot.map.id;
    final editing = _editingBoundary == null
        ? null
        : _boundaryById(_editingBoundary!);
    if (mapChanged ||
        editing == null ||
        !listEquals(editing.nodeIds, _boundaryDraftNodes) ||
        !_boundaryVisuals.any((v) => v.boundary.id == editing.id)) {
      _finishBoundaryLabel();
    }
    if (mapChanged ||
        _selectedBoundary != null &&
            !_boundaryVisuals.any((v) => v.boundary.id == _selectedBoundary)) {
      _selectedBoundary = null;
    }
    if (_boundaryDrag != null && !_boundaryDragValid()) _cancelBoundaryDrag();
    if (_boundaryDrag == null && !_busy) _previewBoundary = null;
  }

  bool _boundaryDragValid() {
    final drag = _boundaryDrag;
    if (drag == null) return false;
    final current = _boundaryById(drag.boundary.id);
    if (current == null ||
        current.mapId != drag.boundary.mapId ||
        current.parentNodeId != drag.boundary.parentNodeId ||
        !listEquals(current.nodeIds, drag.boundary.nodeIds) ||
        current.style != drag.boundary.style) {
      return false;
    }
    return drag.nodes.entries.every((entry) {
      final actual = _nodes[entry.key], old = entry.value;
      return actual != null &&
          actual.parentNodeId == old.parentNodeId &&
          actual.cardId == old.cardId &&
          actual.x == old.x &&
          actual.y == old.y &&
          actual.collapsed == old.collapsed;
    });
  }

  void _cancelBoundaryDrag() {
    if (_boundaryDrag != null) _dragCursor.hide();
    _boundaryDrag = null;
    _previewBoundary = null;
  }

  void _startBoundaryDrag(MapBoundary boundary, String end) {
    if (_busy || !_active || _editingBoundary != null) return;
    _dragCursor.show(context, SystemMouseCursors.move);
    _boundaryUpdate(() {
      _boundaryDrag = (boundary: boundary, end: end, nodes: Map.of(_nodes));
      _previewBoundary = boundary;
    });
  }

  void _updateBoundaryDrag(Offset global) {
    final drag = _boundaryDrag;
    if (drag == null || !_boundaryDragValid()) {
      _boundaryUpdate(_cancelBoundaryDrag);
      return;
    }
    final siblings =
        _nodes.values
            .where(
              (n) =>
                  (!widget.snapshot.summaries.any(
                        (s) => s.summaryNodeId == n.id,
                      ) ||
                      drag.boundary.nodeIds.contains(n.id)) &&
                  n.parentNodeId == drag.boundary.parentNodeId &&
                  _shownIds.contains(n.id),
            )
            .toList()
          ..sort(compareMapNodes);
    if (siblings.isEmpty || drag.boundary.parentNodeId == null) return;
    final point = _worldFromGlobal(global);
    final nearest = siblings.reduce(
      (a, b) =>
          (_rect(a).center - point).distanceSquared <
              (_rect(b).center - point).distanceSquared
          ? a
          : b,
    );
    final roots = boundaryRoots(drag.boundary, _nodes.values);
    if (roots.isEmpty) return;
    final opposite = drag.end == 'start' ? roots.last.id : roots.first.id;
    final lo = math.min(
      siblings.indexWhere((n) => n.id == opposite),
      siblings.indexOf(nearest),
    );
    final hi = math.max(
      siblings.indexWhere((n) => n.id == opposite),
      siblings.indexOf(nearest),
    );
    if (lo < 0) return;
    _boundaryUpdate(
      () => _previewBoundary = MapBoundary(
        id: drag.boundary.id,
        mapId: drag.boundary.mapId,
        parentNodeId: drag.boundary.parentNodeId,
        nodeIds: siblings.sublist(lo, hi + 1).map((n) => n.id).toList(),
        label: drag.boundary.label,
        style: drag.boundary.style,
      ),
    );
  }

  void _finishBoundaryDrag() {
    final drag = _boundaryDrag, preview = _previewBoundary;
    if (drag == null || preview == null || !_boundaryDragValid()) {
      _boundaryUpdate(_cancelBoundaryDrag);
      return;
    }
    _boundaryUpdate(() => _boundaryDrag = null);
    if (listEquals(preview.nodeIds, drag.boundary.nodeIds)) {
      _boundaryUpdate(() => _previewBoundary = null);
      return;
    }
    _run(() async {
      try {
        await widget.onChangeBoundaryRange!(drag.boundary, preview.nodeIds);
      } finally {
        if (mounted) _boundaryUpdate(() => _previewBoundary = null);
      }
    }, showProgress: false);
  }

  Future<void> _boundaryMenu(Offset global, {String? id}) async {
    id ??= _hitBoundary(_worldFromGlobal(global));
    if (id == null) return;
    _selectBoundary(id);
    final boundary = _boundaryById(id);
    if (boundary == null) return;
    final mapId = widget.snapshot.map.id;
    bool valid() =>
        mounted &&
        _active &&
        widget.snapshot.map.id == mapId &&
        widget.snapshot.boundaries.any((current) => current.id == boundary.id);
    final action = await _showContextMenu(global, [
      if (widget.onCommitBoundaryLabel != null)
        _item('label', Icons.title, '编辑外框说明 Space'),
      if (widget.onEditBoundary != null) _item('style', Icons.tune, '外框样式与范围…'),
      if (widget.onRemoveBoundary != null)
        _item('delete', Icons.delete_outline, '删除外框（保留主题）'),
    ], valid);
    if (!valid()) return;
    if (!mounted) return;
    if (action == 'label') unawaited(_beginBoundaryLabel(id));
    if (action == 'style') {
      _run(() => widget.onEditBoundary!(boundary), showProgress: false);
    }
    if (action == 'delete') {
      _run(() => widget.onRemoveBoundary!(boundary), showProgress: false);
    }
  }

  List<Widget> _boundaryLabels(Rect visible) => [
    for (final visual in _boundaryVisuals)
      if (visual.rect.overlaps(visible) &&
          visual.boundary.id != _editingBoundary &&
          (visual.boundary.label.isNotEmpty ||
              visual.boundary.id == _selectedBoundary))
        Positioned(
          left: visual.label.dx + _origin.dx,
          top: visual.label.dy + _origin.dy,
          child: MouseRegion(
            cursor: _busy ? SystemMouseCursors.basic : SystemMouseCursors.click,
            child: GestureDetector(
              key: ValueKey('boundary-label-${visual.boundary.id}'),
              onTap: () => _selectBoundary(visual.boundary.id),
              onDoubleTap: () =>
                  unawaited(_beginBoundaryLabel(visual.boundary.id)),
              onSecondaryTapDown: (d) =>
                  _boundaryMenu(d.globalPosition, id: visual.boundary.id),
              child: Container(
                constraints: const BoxConstraints(maxWidth: 280),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: OpenNoteTokens.background,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  visual.boundary.label.isEmpty
                      ? '+ 添加说明'
                      : visual.boundary.label,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: visual.boundary.style.fontFamily,
                    color: Color(
                      int.parse(
                            visual.boundary.style.textColor.substring(1),
                            radix: 16,
                          ) |
                          0xFF000000,
                    ),
                    fontSize: visual.boundary.style.textSize,
                    fontWeight: visual.boundary.style.bold
                        ? FontWeight.w600
                        : FontWeight.w400,
                    fontStyle: visual.boundary.style.italic
                        ? FontStyle.italic
                        : FontStyle.normal,
                  ),
                ),
              ),
            ),
          ),
        ),
  ];
  List<Widget> _boundaryOverlays() {
    final visual = _boundaryVisuals
        .where((v) => v.boundary.id == _selectedBoundary)
        .firstOrNull;
    if (visual == null) return [];
    if (_editingBoundary == visual.boundary.id) {
      final point = _screenFromWorld(visual.label);
      return [
        Positioned(
          left: point.dx.clamp(8, math.max(8, _size.width - 308)),
          top: point.dy.clamp(8, math.max(8, _size.height - 160)),
          width: math.min(300, _size.width - 16),
          child: Material(
            elevation: 3,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Focus(
                onKeyEvent: (_, event) {
                  if (event is! KeyDownEvent || _boundarySaving) {
                    return KeyEventResult.ignored;
                  }
                  if (event.logicalKey == LogicalKeyboardKey.escape) {
                    _boundaryUpdate(_finishBoundaryLabel);
                    _focus.requestFocus();
                    return KeyEventResult.handled;
                  }
                  if (event.logicalKey == LogicalKeyboardKey.enter &&
                      !HardwareKeyboard.instance.isShiftPressed) {
                    final composing = _boundaryText.value.composing;
                    if (!composing.isValid || composing.isCollapsed) {
                      unawaited(_saveBoundaryLabel());
                    }
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: TextField(
                  key: const Key('boundary-label-editor'),
                  controller: _boundaryText,
                  focusNode: _boundaryFocus,
                  maxLength: 1000,
                  minLines: 1,
                  maxLines: 4,
                  readOnly: _boundarySaving,
                  onTapOutside: (_) => unawaited(_saveBoundaryLabel()),
                  decoration: const InputDecoration(labelText: '外框说明'),
                ),
              ),
            ),
          ),
        ),
      ];
    }
    final boundary = visual.boundary;
    return [
      if (widget.onChangeBoundaryRange != null && boundary.parentNodeId != null)
        for (final end in ['start', 'end'])
          Positioned(
            left:
                _screenFromWorld(
                  Offset(
                    visual.rect.center.dx,
                    end == 'start' ? visual.rect.top : visual.rect.bottom,
                  ),
                ).dx -
                16,
            top:
                _screenFromWorld(
                  Offset(
                    visual.rect.center.dx,
                    end == 'start' ? visual.rect.top : visual.rect.bottom,
                  ),
                ).dy -
                12,
            width: 32,
            height: 24,
            child: MouseRegion(
              cursor: _busy
                  ? SystemMouseCursors.basic
                  : SystemMouseCursors.move,
              child: Listener(
                onPointerCancel: (_) => _boundaryUpdate(_cancelBoundaryDrag),
                child: GestureDetector(
                  key: ValueKey('boundary-handle-${boundary.id}-$end'),
                  dragStartBehavior: DragStartBehavior.down,
                  onPanStart: (_) => _startBoundaryDrag(boundary, end),
                  onPanUpdate: (d) => _updateBoundaryDrag(d.globalPosition),
                  onPanEnd: (_) => _finishBoundaryDrag(),
                  onPanCancel: () => _boundaryUpdate(_cancelBoundaryDrag),
                  child: Center(
                    child: Container(
                      width: 24,
                      height: 6,
                      decoration: BoxDecoration(
                        color: _MindMapPaneState._blue,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      Positioned(
        right: 16,
        top: 16,
        child: Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.only(left: 12),
                child: Text('外框'),
              ),
              if (widget.onCommitBoundaryLabel != null)
                IconButton(
                  tooltip: '编辑外框说明',
                  onPressed: () => unawaited(_beginBoundaryLabel(boundary.id)),
                  icon: const OpenNoteIcon(Icons.title),
                ),
              if (widget.onEditBoundary != null)
                IconButton(
                  tooltip: '外框样式与范围',
                  onPressed: () => _run(
                    () => widget.onEditBoundary!(boundary),
                    showProgress: false,
                  ),
                  icon: const OpenNoteIcon(Icons.tune),
                ),
              if (widget.onRemoveBoundary != null)
                IconButton(
                  tooltip: '删除外框（保留主题）',
                  onPressed: () => _run(
                    () => widget.onRemoveBoundary!(boundary),
                    showProgress: false,
                  ),
                  icon: const OpenNoteIcon(Icons.close),
                ),
            ],
          ),
        ),
      ),
    ];
  }
}
