part of 'mind_map_pane.dart';

extension _SummaryInteractions on _MindMapPaneState {
  MapSummary? get _selectedSummary => widget.snapshot.summaries
      .where((s) => s.summaryNodeId == _selectedId)
      .firstOrNull;
  MapSummary _displaySummary(MapSummary s) =>
      _previewSummary?.id == s.id ? _previewSummary! : s;
  List<SummaryVisual> get _summaryVisuals => [
    for (final s in widget.snapshot.summaries)
      ?summaryVisual(
        _displaySummary(s),
        _nodes.values.toList(),
        widget.snapshot.summaries,
        _shownIds,
        _position,
        widget.snapshot.map.layout,
        branchLayouts: _branchLayouts,
      ),
  ];

  void _createSummary() {
    if (_selectedIds.isEmpty ||
        widget.onCreateSummaries == null ||
        _busy ||
        !widget.canCreate) {
      return;
    }
    final ids = Set<String>.of(_selectedIds), map = widget.snapshot.map.id;
    _run(() async {
      final created = await widget.onCreateSummaries!(ids);
      if (!mounted ||
          !_active ||
          widget.snapshot.map.id != map ||
          created.isEmpty) {
        return;
      }
      // 仓储完成可能早于下一帧节点树刷新，标题请求交由控制器在可编辑时兑现。
      _boundaryUpdate(() {
        _selectedId = created.first;
        _selectedIds = {created.first};
        _selectedEdge = null;
        _selectedBoundary = null;
      });
      // 创建回调已提交工作台选集，不再发出重复选择命令而提前提交新标题草稿。
      _focus.requestFocus();
      widget.controller?.centerOnNode(created.first);
      widget.controller?.editTitle(created.first);
    }, showProgress: false);
  }

  void _cancelSummaryDrag() {
    if (_summaryDrag != null) _dragCursor.hide();
    _summaryDrag = null;
    _previewSummary = null;
  }

  bool _summaryDragValid() {
    final drag = _summaryDrag;
    if (!mounted ||
        !_active ||
        drag == null ||
        drag.snapshot.map.id != widget.snapshot.map.id) {
      return false;
    }
    final current = widget.snapshot.summaries
        .where((s) => s.id == drag.summary.id)
        .firstOrNull;
    if (current == null ||
        current.style != drag.summary.style ||
        current.summaryNodeId != drag.summary.summaryNodeId ||
        current.parentNodeId != drag.summary.parentNodeId ||
        !listEquals(current.nodeIds, drag.summary.nodeIds)) {
      return false;
    }
    final byId = {for (final n in widget.snapshot.nodes) n.id: n};
    return drag.snapshot.nodes.length == byId.length &&
        drag.snapshot.nodes.every((n) {
          final next = byId[n.id];
          return next != null &&
              next.cardId == n.cardId &&
              next.parentNodeId == n.parentNodeId &&
              next.x == n.x &&
              next.y == n.y &&
              next.collapsed == n.collapsed;
        });
  }

  void _startSummaryRange(MapSummary s, String end) {
    if (_busy || !widget.canCreate) return;
    _dragCursor.show(context, _summaryRangeCursor(s));
    _boundaryUpdate(
      () => _summaryDrag = (summary: s, end: end, snapshot: widget.snapshot),
    );
    _focus.requestFocus();
  }

  void _updateSummaryRange(Offset global) {
    if (!_summaryDragValid()) {
      _boundaryUpdate(_cancelSummaryDrag);
      return;
    }
    final drag = _summaryDrag!, s = drag.summary;
    final auxiliaries = widget.snapshot.summaries
        .map((s) => s.summaryNodeId)
        .toSet();
    final siblings =
        _nodes.values
            .where(
              (n) =>
                  n.parentNodeId == s.parentNodeId &&
                  !auxiliaries.contains(n.id) &&
                  _shownIds.contains(n.id),
            )
            .toList()
          ..sort(compareMapNodes);
    if (siblings.isEmpty) return;
    final pointer = _worldFromGlobal(global);
    final vertical = summaryDirection(
      s,
      _nodes.values.toList(),
      widget.snapshot.map.layout,
      layouts: _branchLayouts,
    ).vertical;
    siblings.sort(
      (a, b) =>
          (vertical
                  ? (_rect(a).center.dx - pointer.dx).abs()
                  : (_rect(a).center.dy - pointer.dy).abs())
              .compareTo(
                vertical
                    ? (_rect(b).center.dx - pointer.dx).abs()
                    : (_rect(b).center.dy - pointer.dy).abs(),
              ),
    );
    final nearest = siblings.first;
    siblings.sort(compareMapNodes);
    final range = summaryRoots(s, _nodes.values, widget.snapshot.summaries);
    if (range.isEmpty) return;
    var start = siblings.indexWhere((n) => n.id == range.first.id);
    var end = siblings.indexWhere((n) => n.id == range.last.id);
    final index = siblings.indexWhere((n) => n.id == nearest.id);
    if (drag.end == 'start') {
      start = math.min(index, end);
    } else {
      end = math.max(start, index);
    }
    _boundaryUpdate(
      () => _previewSummary = MapSummary(
        id: s.id,
        mapId: s.mapId,
        summaryNodeId: s.summaryNodeId,
        parentNodeId: s.parentNodeId,
        style: s.style,
        nodeIds: siblings.sublist(start, end + 1).map((n) => n.id).toList(),
      ),
    );
  }

  void _finishSummaryRange() {
    final drag = _summaryDrag, preview = _previewSummary;
    final valid = _summaryDragValid();
    _boundaryUpdate(_cancelSummaryDrag);
    if (!valid ||
        drag == null ||
        preview == null ||
        listEquals(preview.nodeIds, drag.summary.nodeIds) ||
        widget.onChangeSummaryRange == null) {
      return;
    }
    _run(
      () => widget.onChangeSummaryRange!(drag.summary, preview.nodeIds),
      showProgress: false,
    );
  }

  MouseCursor _summaryRangeCursor(MapSummary summary) =>
      summaryDirection(
        summary,
        _nodes.values.toList(),
        widget.snapshot.map.layout,
        layouts: _branchLayouts,
      ).vertical
      ? SystemMouseCursors.resizeLeftRight
      : SystemMouseCursors.resizeUpDown;

  List<Widget> _summaryOverlays() {
    final selected = _selectedSummary;
    if (selected == null || _titleNodeId != null) return [];
    final visual = _summaryVisuals
        .where((v) => v.summary.id == selected.id)
        .firstOrNull;
    if (visual == null) return [];
    return [
      if (widget.onChangeSummaryRange != null && selected.parentNodeId != null)
        for (final end in ['start', 'end'])
          Positioned(
            left:
                _screenFromWorld(end == 'start' ? visual.start : visual.end)
                    .dx -
                12,
            top:
                _screenFromWorld(end == 'start' ? visual.start : visual.end)
                    .dy -
                12,
            width: 24,
            height: 24,
            child: MouseRegion(
              cursor: _busy
                  ? SystemMouseCursors.basic
                  : _summaryRangeCursor(selected),
              child: Listener(
                onPointerCancel: (_) => _boundaryUpdate(_cancelSummaryDrag),
                child: GestureDetector(
                  key: ValueKey('summary-handle-${selected.id}-$end'),
                  dragStartBehavior: DragStartBehavior.down,
                  onPanStart: (_) => _startSummaryRange(selected, end),
                  onPanUpdate: (d) => _updateSummaryRange(d.globalPosition),
                  onPanEnd: (_) => _finishSummaryRange(),
                  onPanCancel: () => _boundaryUpdate(_cancelSummaryDrag),
                  child: Center(
                    child: Container(
                      width: 10,
                      height: 10,
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
                child: Text('概要'),
              ),
              if (widget.onEditSummary != null)
                IconButton(
                  tooltip: '概要样式与范围',
                  onPressed: () => _run(
                    () => widget.onEditSummary!(selected),
                    showProgress: false,
                  ),
                  icon: const OpenNoteIcon(Icons.tune),
                ),
              if (widget.onRemoveSummary != null)
                IconButton(
                  tooltip: '移除概要括号（保留主题）',
                  onPressed: () => _run(
                    () => widget.onRemoveSummary!(selected),
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
