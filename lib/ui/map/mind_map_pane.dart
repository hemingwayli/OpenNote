import '../theme/open_note_icon.dart';
import '../theme/open_note_context_menu.dart';

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme/open_note_theme.dart';
import '../theme/open_note_tool_group.dart';
import '../theme/open_note_drag_cursor.dart';
import '../reader/reader_contract.dart';

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../../domain/models.dart';
import '../../domain/relationship_geometry.dart';
import '../../domain/boundary_geometry.dart';
import 'boundary_painter.dart';
import '../../domain/summary_geometry.dart';
import '../../domain/topic_style_resolver.dart';
import '../../domain/branch_structure.dart';
import '../../domain/topic_drop.dart';
import '../../domain/structure_geometry.dart';
import 'topic_style_painter.dart';
import 'summary_painter.dart';
import 'boundary_label_draft.dart';
export 'boundary_label_draft.dart';
import 'relationship_painter.dart';
import 'relationship_label_draft.dart';
export 'relationship_label_draft.dart';
import 'map_title_draft.dart';
export 'map_title_draft.dart';
part 'boundary_interactions.dart';
part 'summary_interactions.dart';

class MindMapPaneController {
  _MindMapPaneState? _state;
  String? _pendingCenterId;
  String? _pendingTitleId;
  MapTitleDraft? get titleDraft => _state?._titleDraft;
  RelationshipLabelDraft? get relationshipDraft => _state?._relationshipDraft;
  BoundaryLabelDraft? get boundaryDraft => _state?._boundaryDraft;
  void acceptBoundaryLabel(BoundaryLabelDraft draft) =>
      _state?._acceptBoundaryLabel(draft);
  void acceptRelationshipLabel(RelationshipLabelDraft draft) =>
      _state?._acceptRelationshipLabel(draft);
  void acceptTitle(MapTitleDraft draft) => _state?._acceptTitle(draft);
  void editTitle(String nodeId) {
    _pendingTitleId = nodeId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _state?._consumePendingTitle();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  int get renderedNodeCount => _state?._renderedCount ?? 0;
  double get scale => _state?._transform.value.getMaxScaleOnAxis() ?? 1;
  void fitAll({MapSnapshot? snapshot}) => _state?._fitAll(snapshot: snapshot);
  void zoomIn() => _state?._zoom(1.25);
  void zoomOut() => _state?._zoom(.8);
  void centerOnNode(String nodeId) {
    _pendingCenterId = nodeId;
    // 切换脑图的通知可能早于新 Pane 布局，交由当前绑定的 State 兑现。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _state?._consumePendingCenter();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void setView({
    required double scale,
    Offset worldTopLeft = const Offset(-80, -80),
  }) => _state?._setView(scale, worldTopLeft);
  void keepNodeVisible(String nodeId) => _state?._keepNodeVisible(nodeId);
  void beginAssociation(String nodeId) => _state?._beginAssociation(nodeId);
}

/// 只在空白处的框选模式或 Shift 手势参与竞争，其余鼠标拖动交给画布平移。
class _MapMarqueeRecognizer extends PanGestureRecognizer {
  _MapMarqueeRecognizer() : super(supportedDevices: {PointerDeviceKind.mouse});
  bool Function()? canStart;

  @override
  bool isPointerAllowed(PointerEvent event) =>
      event.buttons == kPrimaryMouseButton &&
      (canStart?.call() ?? false) &&
      super.isPointerAllowed(event);
}

/// 保留尾部物理像素原有的透明度，每个纹理像素按实际采样比例映射到画布。
class _ScreenSnapshotPainter implements SnapshotPainter {
  const _ScreenSnapshotPainter();

  @override
  void paintSnapshot(
    PaintingContext context,
    Offset offset,
    Size size,
    ui.Image image,
    Size sourceSize,
    double pixelRatio,
  ) {
    final source = Rect.fromLTWH(
      0,
      0,
      image.width.toDouble(),
      image.height.toDouble(),
    );
    final destination = Rect.fromLTWH(
      offset.dx,
      offset.dy,
      image.width / pixelRatio,
      image.height / pixelRatio,
    );
    context.canvas.drawImageRect(
      image,
      source,
      destination,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  void paint(
    PaintingContext context,
    Offset offset,
    Size size,
    PaintingContextCallback painter,
  ) => painter(context, offset);

  @override
  bool shouldRepaint(covariant _ScreenSnapshotPainter oldPainter) => false;

  // 共享绘制器没有可变状态，不保留每个节点的监听或图像引用。
  @override
  bool get hasListeners => false;
  @override
  void addListener(VoidCallback listener) {}
  @override
  void removeListener(VoidCallback listener) {}
  @override
  void notifyListeners() {}
  @override
  void dispose() {}
}

/// 脑图只处理输入与显示。父关系和关联始终来自持久模型，拖放只提交一次命令。
class MindMapPane extends StatefulWidget {
  const MindMapPane({
    super.key,
    required this.snapshot,
    this.creationTools,
    this.structureMenuEntries,
    this.onStructureMenuAction,
    this.selectedNodeId,
    this.selectedNodeIds,
    required this.onSelect,
    this.onToggleSelection,
    this.onActivate,
    this.onCreateAt,
    this.onCreateRelatedAt,
    this.canCreate = true,
    required this.onMove,
    this.onMoveGroup,
    required this.onReparent,
    required this.onAssociate,
    required this.onRemoveAssociation,
    required this.onAction,
    required this.onToggleCollapsed,
    this.onClearSelection,
    this.onReparentAt,
    this.onDropTopic,
    this.onCommitTitle,
    this.onCommitRelationshipLabel,
    this.onPrepareRelationshipEdit,
    this.onEditAssociation,
    this.onChangeAssociationStyle,
    this.onReconnectAssociation,
    this.onCreateBoundaries,
    this.onCommitBoundaryLabel,
    this.onEditBoundary,
    this.onChangeBoundaryRange,
    this.onRemoveBoundary,
    this.onCreateSummaries,
    this.onEditSummary,
    this.onChangeSummaryRange,
    this.onRemoveSummary,
    this.onSelectionChanged,
    this.onClipboardAction,
    this.controller,
    this.imagePathResolver,
    this.onTextExcerptDrop,
    this.canAcceptTextDrag,
  });
  final MapSnapshot snapshot;
  final Widget? creationTools;
  final List<OpenNoteMenuEntry<String>> Function()? structureMenuEntries;
  final ValueChanged<String>? onStructureMenuAction;
  final String? selectedNodeId;
  final Set<String>? selectedNodeIds;
  final void Function(MapNode) onSelect;
  final void Function(MapNode)? onToggleSelection;
  final void Function(MapNode)? onActivate;
  final void Function(Offset)? onCreateAt;
  final Future<String> Function(Offset, String? fromNodeId)? onCreateRelatedAt;
  final bool canCreate;
  final Future<void> Function(String nodeId, double x, double y) onMove;
  final Future<void> Function(Map<String, PdfPoint> positions)? onMoveGroup;
  final Future<void> Function(String nodeId, String? parentNodeId) onReparent;
  final Future<void> Function(
    String nodeId,
    String? parentNodeId,
    double x,
    double y,
  )?
  onReparentAt;
  final Future<void> Function(
    MapNode source,
    TopicDropTarget target,
    double x,
    double y,
  )?
  onDropTopic;
  final Future<void> Function(String, String) onAssociate;
  final void Function(String edgeId) onRemoveAssociation;
  final void Function(MapNode, String action) onAction;
  final void Function(String nodeId) onToggleCollapsed;
  final VoidCallback? onClearSelection;
  final MindMapPaneController? controller;
  final Future<void> Function()? onCommitTitle;
  final Future<void> Function()? onCommitRelationshipLabel;
  final Future<void> Function()? onPrepareRelationshipEdit;
  final Future<void> Function(MapEdge)? onEditAssociation;
  final Future<void> Function(MapEdge, RelationshipStyle)?
  onChangeAssociationStyle;
  final Future<void> Function(
    MapEdge,
    String endpoint,
    String target,
    PdfPoint anchor,
  )?
  onReconnectAssociation;
  final Future<List<String>> Function(Set<String>)? onCreateBoundaries;
  final Future<void> Function()? onCommitBoundaryLabel;
  final Future<void> Function(MapBoundary)? onEditBoundary;
  final Future<void> Function(MapBoundary, List<String>)? onChangeBoundaryRange;
  final Future<void> Function(MapBoundary)? onRemoveBoundary;
  final Future<List<String>> Function(Set<String>)? onCreateSummaries;
  final Future<void> Function(MapSummary)? onEditSummary;
  final Future<void> Function(MapSummary, List<String>)? onChangeSummaryRange;
  final Future<void> Function(MapSummary)? onRemoveSummary;
  final void Function(Set<String> ids, String? primary)? onSelectionChanged;
  final void Function(String action)? onClipboardAction;
  final Future<String> Function(String resourceId)? imagePathResolver;
  final Future<void> Function(
    ReaderExcerptDrag,
    Offset position,
    MapNode? parent,
  )?
  onTextExcerptDrop;
  final bool Function(ReaderExcerptDrag)? canAcceptTextDrag;
  @override
  State<MindMapPane> createState() => _MindMapPaneState();
}

class _MindMapPaneState extends State<MindMapPane> {
  static const _blue = OpenNoteTokens.accent;
  static const _green = Color(0xFF27945D);
  final _transform = TransformationController();
  final _viewport = GlobalKey();
  ReaderExcerptDrag? _incomingText;
  MapNode? _incomingParent;
  Offset? _incomingPosition, _incomingGlobal;
  bool _incomingInvalid = false;
  final _focus = FocusNode(debugLabel: 'OpenNote 脑图');
  final _contextMenuController = OpenNoteContextMenuController();
  bool Function()? _menuValid;
  final _titleFocus = FocusNode(debugLabel: 'OpenNote 脑图标题');
  final _titleText = TextEditingController();
  final _relationshipFocus = FocusNode(debugLabel: 'OpenNote 关联说明');
  final _relationshipText = TextEditingController();
  String? _relationshipId, _relationshipFrom, _relationshipTo;
  int _relationshipGeneration = 0;
  bool _relationshipSaving = false;
  final _boundaryFocus = FocusNode(debugLabel: 'OpenNote 外框说明');
  final _boundaryText = TextEditingController();
  String? _selectedBoundary, _editingBoundary;
  List<String> _boundaryDraftNodes = const [];
  int _boundaryGeneration = 0;
  bool _boundarySaving = false;
  MapBoundary? _previewBoundary;
  ({MapBoundary boundary, String end, Map<String, MapNode> nodes})?
  _boundaryDrag;
  String? _doubleTapBoundary;
  MapEdge? _previewEdge;
  ({MapEdge edge, String part, MapNode from, MapNode to})? _edgeDrag;
  String? _edgeDropNode;
  Offset _edgeLabelGrab = Offset.zero;
  String? _titleNodeId;
  String? _titleCardId;
  int _titleGeneration = 0;
  bool _titleSaving = false;
  Map<String, MapNode> _nodes = {};
  Map<String, TopicStyle> _topicStyles = {};
  Map<String, MapLayoutKind> _branchLayouts = {};
  Map<String, List<String>> _children = {};
  Map<String, int> _descendantCounts = {};
  String? _hoveredCollapseId;
  final Map<String, _NodeTile> _nodeTiles = {};
  final Map<String, SnapshotController> _nodeSnapshots = {};
  Set<String> _shownIds = {};
  Set<String> _selectedIds = {};
  Set<String> _dragIds = {};
  Set<String> _dragRoots = {};
  Map<String, MapNode> _dragStartNodes = {};
  final Map<String, Offset> _pendingPositions = {};
  String? _selectedId;
  String? _pressedNodeId;
  bool _pressedCtrl = false;
  bool _pressedInvalidated = false;
  PointerDownEvent? _mouseClickDown;
  PointerUpEvent? _mouseClickUp;
  bool _secondMouseClick = false;
  ({
    String nodeId,
    String cardId,
    int device,
    Offset position,
    Duration upTime,
  })?
  _lastMouseClick;
  bool _dragGroup = false;
  String? _dragging;
  String? _dropTarget;
  TopicDropTarget? _dropIntent;
  String? _associationFrom;
  bool _associationMode = false;
  String? _selectedEdge;
  Offset? _cursor;
  Offset? _doubleTapWorld;
  String? _doubleTapEdge;
  Offset _dragGrab = Offset.zero;
  Offset _dragDelta = Offset.zero;
  Offset _origin = const Offset(320, 320);
  Size _canvasSize = const Size(2400, 2400);
  Size _size = Size.zero;
  int _renderedCount = 0;
  bool _busy = false;
  bool _showLocalProgress = true;
  bool _active = true;
  bool _snapshotDependenciesChangedInDrag = false;
  bool _marqueeMode = false;
  final _dragCursor = OpenNoteDragCursor();
  final _shiftPressed = ValueNotifier<bool>(false);
  bool _primaryDown = false;
  Rect? _marquee;
  Set<String> _marqueeBase = {};
  String? _marqueePrimary;
  bool _marqueeAdditive = false;
  void _boundaryUpdate(VoidCallback change) => setState(change);
  MapSummary? _previewSummary;
  ({MapSummary summary, String end, MapSnapshot snapshot})? _summaryDrag;

  @override
  void initState() {
    super.initState();
    _syncSelection();
    widget.controller?._state = this;
    _rebuildGraph();
    _transform.addListener(_viewChanged);
    HardwareKeyboard.instance.addHandler(_cursorModifiersChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _active) {
        _fitAll();
        _consumePendingCenter();
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 同尺寸下字体缩放、主题与文字方向也会改变像素，不能继续使用旧快照。
    Theme.of(context);
    _nodeTiles.clear();
    MediaQuery.textScalerOf(context);
    Directionality.of(context);
    DefaultTextStyle.of(context);
    IconTheme.of(context);
    if (_dragging != null) _snapshotDependenciesChangedInDrag = true;
    for (final controller in _nodeSnapshots.values) {
      if (_dragging != null) {
        // 子按钮主题仍可能逐帧动画，本次手势保持实时绘制直至结束。
        controller.allowSnapshotting = false;
      } else if (controller.allowSnapshotting) {
        controller.clear();
      }
    }
  }

  @override
  void didUpdateWidget(covariant MindMapPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_menuValid?.call() == false) _contextMenuController.cancel();
    if (_incomingText != null) {
      if (oldWidget.snapshot.map.id != widget.snapshot.map.id ||
          oldWidget.snapshot.map.projectId != widget.snapshot.map.projectId ||
          widget.onTextExcerptDrop == null ||
          !widget.canCreate) {
        _clearIncomingText();
      } else if (_incomingParent != null &&
          !widget.snapshot.nodes.any(
            (n) =>
                n.id == _incomingParent!.id &&
                n.cardId == _incomingParent!.cardId,
          )) {
        _incomingInvalid = true;
        _incomingText?.clearDropTarget(this);
      }
    }
    if (oldWidget.controller != widget.controller) {
      _clearMouseClicks();
      if (identical(oldWidget.controller?._state, this)) {
        oldWidget.controller?._state = null;
      }
      widget.controller?._state = this;
    }
    if (oldWidget.selectedNodeId != widget.selectedNodeId ||
        !setEquals(oldWidget.selectedNodeIds, widget.selectedNodeIds)) {
      _cancelMarquee(restore: false);
      _syncSelection();
      if (_menuValid?.call() == false) _contextMenuController.cancel();
    }
    if (oldWidget.snapshot != widget.snapshot) {
      final previousClick = _lastMouseClick;
      if (oldWidget.snapshot.map.id != widget.snapshot.map.id ||
          oldWidget.snapshot.map.projectId != widget.snapshot.map.projectId ||
          (previousClick != null &&
              !widget.snapshot.nodes.any(
                (node) =>
                    node.id == previousClick.nodeId &&
                    node.cardId == previousClick.cardId,
              ))) {
        _clearMouseClicks();
      }
      if (oldWidget.snapshot.map.id != widget.snapshot.map.id ||
          oldWidget.snapshot.map.projectId != widget.snapshot.map.projectId ||
          (_pressedNodeId != null &&
              !widget.snapshot.nodes.any(
                (node) =>
                    node.id == _pressedNodeId &&
                    node.cardId ==
                        oldWidget.snapshot.nodes
                            .where((oldNode) => oldNode.id == _pressedNodeId)
                            .firstOrNull
                            ?.cardId,
              ))) {
        _pressedInvalidated = _pressedNodeId != null;
        _clearMouseClicks();
        _clearPressed();
      }
      if (!_busy && _dragging == null) {
        // 已提交的预览交还给新的持久快照；撤销不必先经过移动坐标的确认帧。
        _pendingPositions.clear();
      } else {
        final previousNodes = {
          for (final n in oldWidget.snapshot.nodes) n.id: n,
        };
        final latestNodes = {for (final n in widget.snapshot.nodes) n.id: n};
        _pendingPositions.removeWhere((id, position) {
          final match = latestNodes[id], previous = previousNodes[id];
          return match == null ||
              (match.x - position.dx).abs() < .01 &&
                  (match.y - position.dy).abs() < .01 ||
              // 自动排布可提交不同于鼠标落点的坐标；撤销也必须立即接管。
              // 正文／格式刷新没有改变位置或层级，仍保留未完成的拖动预览。
              previous != null &&
                  (match.x != previous.x ||
                      match.y != previous.y ||
                      match.parentNodeId != previous.parentNodeId ||
                      match.sortIndex != previous.sortIndex ||
                      match.branchLayout != previous.branchLayout);
        });
      }
      _rebuildGraph();
      _syncBoundaryState(oldWidget.snapshot);
      if (_summaryDrag != null && !_summaryDragValid()) _cancelSummaryDrag();
      if (_associationFrom != null && !_shownIds.contains(_associationFrom)) {
        _associationFrom = null;
        _associationMode = false;
      }
      final editingEdge = widget.snapshot.edges
          .where((e) => e.id == _relationshipId)
          .firstOrNull;
      if (_relationshipId != null &&
          (oldWidget.snapshot.map.id != widget.snapshot.map.id ||
              editingEdge == null ||
              editingEdge.fromNodeId != _relationshipFrom ||
              editingEdge.toNodeId != _relationshipTo ||
              !_shownIds.contains(editingEdge.fromNodeId) ||
              !_shownIds.contains(editingEdge.toNodeId))) {
        _finishRelationshipLabel();
      }
      if (_edgeDrag != null && !_validEdgeDrag()) _cancelEdgeDrag();
      if (_previewEdge != null && _edgeDrag == null) {
        final committed = widget.snapshot.edges
            .where((e) => e.id == _previewEdge!.id)
            .firstOrNull;
        if (!_busy ||
            committed == null ||
            (committed.fromNodeId == _previewEdge!.fromNodeId &&
                committed.toNodeId == _previewEdge!.toNodeId &&
                committed.style == _previewEdge!.style)) {
          _previewEdge = null;
        }
      }
      if (_titleNodeId != null &&
          (oldWidget.snapshot.map.id != widget.snapshot.map.id ||
              !_nodes.containsKey(_titleNodeId) ||
              _nodes[_titleNodeId]?.cardId != _titleCardId ||
              !_shownIds.contains(_titleNodeId))) {
        _finishTitle();
      }
      if (_lastMouseClick != null &&
          !_shownIds.contains(_lastMouseClick!.nodeId)) {
        _clearMouseClicks();
      }
      if (_dragging != null &&
          (oldWidget.snapshot.map.id != widget.snapshot.map.id ||
              !_dragIsValid())) {
        // 快照改变分支时取消整个手势，不把剩余旧成员继续当作有效拖动。
        _resetDrag();
      }
      if (oldWidget.snapshot.map.id != widget.snapshot.map.id) {
        _cancelMarquee(restore: false);
        _pendingPositions.clear();
        _associationFrom = null;
        _associationMode = false;
        _selectedEdge = null;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _active) {
            _fitAll();
            _consumePendingCenter();
          }
        });
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _consumePendingCenter();
      });
    }
    if (widget.controller?._pendingTitleId != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _consumePendingTitle(),
      );
    }
  }

  void _viewChanged() {
    if (mounted && _active) setState(() {});
  }

  @override
  void deactivate() {
    _contextMenuController.cancel();
    _dragCursor.hide();
    _primaryDown = false;
    _clearIncomingText();
    _cancelEdgeDrag();
    _cancelSummaryDrag();
    _cancelMarquee();
    _active = false;
    _pressedInvalidated = _pressedNodeId != null;
    _resetDrag();
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _active = true;
  }

  @override
  void dispose() {
    _contextMenuController.cancel();
    HardwareKeyboard.instance.removeHandler(_cursorModifiersChanged);
    _shiftPressed.dispose();
    _dragCursor.hide();
    _clearIncomingText();
    _relationshipFocus.dispose();
    _relationshipText.dispose();
    _boundaryFocus.dispose();
    _boundaryText.dispose();
    if (identical(widget.controller?._state, this)) {
      widget.controller?._state = null;
    }
    _transform.removeListener(_viewChanged);
    _transform.dispose();
    _focus.dispose();
    _titleFocus.dispose();
    _titleText.dispose();
    for (final controller in _nodeSnapshots.values) {
      controller.allowSnapshotting = false;
      controller.dispose();
    }
    _nodeSnapshots.clear();
    super.dispose();
  }

  void _rebuildGraph() {
    _nodes = {for (final n in widget.snapshot.nodes) n.id: n};
    _topicStyles = topicStylesFor(widget.snapshot);
    _branchLayouts = effectiveBranchLayouts(
      widget.snapshot.nodes,
      widget.snapshot.map.layout,
      summaries: widget.snapshot.summaries,
    );
    _nodeTiles.removeWhere((id, _) => !_nodes.containsKey(id));
    for (final id in _nodeSnapshots.keys.toList()) {
      if (_nodes.containsKey(id)) continue;
      final controller = _nodeSnapshots.remove(id)!;
      controller.allowSnapshotting = false;
      controller.dispose();
    }
    _children = {};
    for (final n in _nodes.values) {
      if (n.parentNodeId != null) (_children[n.parentNodeId!] ??= []).add(n.id);
    }
    // 全部后代计数与折叠可见性无关；迭代两趟计算，避免深树递归和逐节点遍历。
    final ordered = _nodes.values
        .where((n) => !_nodes.containsKey(n.parentNodeId))
        .map((n) => n.id)
        .toList();
    for (var i = 0; i < ordered.length; i++) {
      ordered.addAll(_children[ordered[i]] ?? const []);
    }
    _descendantCounts = {};
    for (final id in ordered.reversed) {
      _descendantCounts[id] = (_children[id] ?? const <String>[]).fold(
        0,
        (count, child) => count + 1 + (_descendantCounts[child] ?? 0),
      );
    }
    _shownIds = {};
    final pending = _nodes.values
        .where(
          (n) => n.parentNodeId == null || !_nodes.containsKey(n.parentNodeId),
        )
        .map((n) => n.id)
        .toList();
    for (var index = 0; index < pending.length; index++) {
      final id = pending[index];
      if (!_shownIds.add(id)) continue;
      if (!_nodes[id]!.collapsed) pending.addAll(_children[id] ?? const []);
    }
    _selectedIds.removeWhere((id) => !_nodes.containsKey(id));
    if (!_selectedIds.contains(_selectedId)) {
      _selectedId = _selectedIds.lastOrNull;
    }
    final oldOrigin = _origin;
    final bounds = _contentBounds(_nodes.values, widget.snapshot.edges);
    _origin = Offset(
      320 - math.min(0, bounds.left),
      320 - math.min(0, bounds.top),
    );
    _canvasSize = Size(
      math.max(2400, bounds.right + _origin.dx + 320),
      math.max(2400, bounds.bottom + _origin.dy + 320),
    );
    if (oldOrigin != _origin) {
      _transform.value = _transform.value.clone()
        ..translateByDouble(
          oldOrigin.dx - _origin.dx,
          oldOrigin.dy - _origin.dy,
          0,
          1,
        );
    }
  }

  Rect _bounds(Iterable<MapNode> nodes) {
    Rect? result;
    for (final n in nodes) {
      final rect = Rect.fromLTWH(n.x, n.y, n.width, n.height);
      result = result?.expandToInclude(rect) ?? rect;
    }
    return result ?? const Rect.fromLTWH(0, 0, 220, 116);
  }

  /// 曲线和说明也属于图的内容；负坐标和适合全部不能只计算主题矩形。
  Rect _contentBounds(Iterable<MapNode> nodes, Iterable<MapEdge> edges) {
    final byId = {for (final node in nodes) node.id: node};
    var bounds = _bounds(byId.values);
    for (final edge in edges) {
      final from = byId[edge.fromNodeId], to = byId[edge.toNodeId];
      if (from == null || to == null) continue;
      final geometry = relationshipGeometry(from, to, edge.style);
      if (edge.style.shape == RelationshipShape.curve) {
        for (final point in [
          ...geometry.samples,
          geometry.controlFrom,
          geometry.controlTo,
        ]) {
          bounds = bounds.expandToInclude(
            Rect.fromCircle(center: relationOffset(point), radius: 14),
          );
        }
      }
      if (edge.label.isNotEmpty) {
        bounds = bounds.expandToInclude(
          Rect.fromLTWH(
            geometry.label.x - 110,
            geometry.label.y - 14,
            220,
            edge.style.labelSize * 1.4 * 5 + 12,
          ),
        );
      }
    }
    for (final boundary in widget.snapshot.boundaries) {
      final visual = boundaryVisual(
        boundary,
        byId.values,
        byId.keys.toSet(),
        (n) => Offset(n.x, n.y),
        auxiliaryRoots: widget.snapshot.summaries
            .map((s) => s.summaryNodeId)
            .toSet(),
      );
      if (visual != null) {
        bounds = bounds.expandToInclude(visual.rect.inflate(32));
      }
    }
    for (final summary in widget.snapshot.summaries) {
      final visual = summaryVisual(
        summary,
        byId.values.toList(),
        widget.snapshot.summaries,
        byId.keys.toSet(),
        (n) => Offset(n.x, n.y),
        widget.snapshot.map.layout,
        branchLayouts: _branchLayouts,
      );
      if (visual != null) {
        bounds = bounds.expandToInclude(visual.bounds.inflate(24));
      }
    }
    return bounds;
  }

  Offset _position(MapNode n) =>
      (_pendingPositions[n.id] ?? Offset(n.x, n.y)) +
      (_dragIds.contains(n.id) ? _dragDelta : Offset.zero);

  bool _pansCanvas(MapNode node) =>
      !_busy &&
      _active &&
      !_associationMode &&
      _edgeDrag == null &&
      !_nodes.containsKey(node.parentNodeId) &&
      incomingBranchLayout(node, widget.snapshot.map.layout, _branchLayouts) !=
          MapLayoutKind.free;

  Widget _nodeTile(MapNode node) {
    final pansCanvas = _pansCanvas(node);
    final cursor = _busy || !_active
        ? SystemMouseCursors.basic
        : _associationMode
        ? SystemMouseCursors.click
        : _dragIds.contains(node.id)
        ? SystemMouseCursors.grabbing
        : !pansCanvas &&
              _selectedIds.length > 1 &&
              _selectedIds.contains(node.id) &&
              widget.onMoveGroup == null
        ? SystemMouseCursors.click
        : SystemMouseCursors.grab;
    final card = widget.snapshot.cards[node.cardId]!;
    final topicStyle = _topicStyles[node.id]!.surface;
    final selected = _selectedIds.contains(node.id);
    final primary = _selectedId == node.id;
    final showDetails = selected || _transform.value.getMaxScaleOnAxis() >= .55;
    final dropTarget =
        (_dropTarget == node.id &&
            _dropIntent?.placement == TopicDropPlacement.child) ||
        (!_incomingInvalid && _incomingParent?.id == node.id);
    final previous = _nodeTiles[node.id];
    if (previous != null &&
        (previous.topicStyle != topicStyle ||
            previous.card.title != card.title ||
            previous.card.body != card.body ||
            previous.card.excerptSnapshot != card.excerptSnapshot ||
            previous.card.note != card.note ||
            previous.card.color != card.color ||
            previous.card.imageResourceId != card.imageResourceId ||
            previous.node.cardId != node.cardId ||
            previous.node.collapsed != node.collapsed ||
            previous.selected != selected ||
            previous.primary != primary ||
            previous.showDetails != showDetails ||
            previous.dropTarget != dropTarget ||
            previous.imagePathResolver != widget.imagePathResolver)) {
      _nodeSnapshots[node.id]?.clear();
    }
    // 视口矩阵只改变位置。保留卡片子树与布局，数据/交互状态变化时才更新。
    if (previous != null &&
        identical(previous.node, node) &&
        identical(previous.card, card) &&
        previous.topicStyle == topicStyle &&
        previous.selected == selected &&
        previous.primary == primary &&
        previous.showDetails == showDetails &&
        previous.dropTarget == dropTarget &&
        previous.cursor == cursor &&
        (previous.onPanStart == null) == pansCanvas &&
        previous.imagePathResolver == widget.imagePathResolver) {
      return previous;
    }
    return _nodeTiles[node.id] = _NodeTile(
      key: ValueKey('map-node-${node.id}'),
      node: node,
      card: card,
      topicStyle: topicStyle,
      imagePathResolver: widget.imagePathResolver,
      selected: selected,
      primary: primary,
      showDetails: showDetails,
      dropTarget: dropTarget,
      cursor: cursor,
      onPointerDown: (event) => _nodePointerDown(node, event),
      onPointerUp: (event) => _nodePointerUp(node, event),
      onTap: () => _activateNode(node),
      onTapCancel: () => _cancelNodeClick(node.id),
      onMenu: (point) => _nodeMenu(node, point),
      // 自动布局根节点把平移交给祖先 InteractiveViewer，沿用缩放、边界和手势阈值。
      // 不进入节点移动／挂接流程，因此只改变视图，不提交保存或撤销命令。
      onPanStart: pansCanvas ? null : (details) => _startDrag(node, details),
      onPanUpdate: pansCanvas ? null : _updateDrag,
      onPanEnd: pansCanvas ? null : (_) => _finishDrag(),
      onPanCancel: pansCanvas
          ? null
          : () {
              // 普通点击胜出时也会取消尚未开始的 pan，不能因此清掉按下时的 Ctrl。
              if (_dragging != null) _cancelDrag();
            },
    );
  }

  Widget _nodeSnapshot(
    MapNode node,
    MediaQueryData originalMediaQuery,
    MediaQueryData snapshotMediaQuery,
    double scale,
  ) {
    final controller = _nodeSnapshots.putIfAbsent(
      node.id,
      () => SnapshotController(),
    );
    final tile = _nodeTile(node);
    // 按当前屏幕比例采样文字；图片继续实时加载，放大不插值上采样。
    controller.allowSnapshotting =
        _active &&
        _dragging != null &&
        !_snapshotDependenciesChangedInDrag &&
        widget.snapshot.cards[node.cardId]!.imageResourceId == null &&
        scale <= 1;
    // 常驻两层代理保持鼠标识别器；只调整 DPR，其余布局、字体与输入数据沿用原值。
    return MediaQuery(
      data: controller.allowSnapshotting
          ? snapshotMediaQuery
          : originalMediaQuery,
      child: SnapshotWidget(
        controller: controller,
        painter: const _ScreenSnapshotPainter(),
        mode: SnapshotMode.normal,
        autoresize: true,
        child: tile,
      ),
    );
  }

  Rect _rect(MapNode n) => _position(n) & Size(n.width, n.height);

  void _toggleTopicCollapsed(MapNode node) {
    if (_busy || !_active || !_nodes.containsKey(node.id)) return;
    _clearMouseClicks();
    // 点击外侧控件只选择主题，不触发卡片激活、PDF 回源或双击编辑。
    if (_selectedId != node.id || _selectedIds.length != 1) _select(node);
    _focus.requestFocus();
    widget.onToggleCollapsed(node.id);
  }

  Widget _collapseControl(MapNode node) {
    final count = _descendantCounts[node.id] ?? 0;
    final direction = (_branchLayouts[node.id] ?? widget.snapshot.map.layout)
        .primaryDirection;
    final badgeWidth = node.collapsed
        ? math.max(16.0, count.toString().length * 7.0 + 6)
        : 12.0;
    final distance =
        direction == MapLayoutKind.up || direction == MapLayoutKind.down
        ? 12.0
        : math.max(12.0, badgeWidth / 2 + 4);
    final rect = _rect(node);
    final center = switch (direction) {
      MapLayoutKind.left => rect.centerLeft - Offset(distance, 0),
      MapLayoutKind.up => rect.topCenter - Offset(0, distance),
      MapLayoutKind.down => rect.bottomCenter + Offset(0, distance),
      _ => rect.centerRight + Offset(distance, 0),
    };
    final branch = _topicStyles[node.id]!.branch;
    final colorText = branch.followCardColor
        ? widget.snapshot.cards[node.cardId]!.color
        : branch.color;
    final color = Color(
      0xFF000000 | int.parse(colorText.substring(1), radix: 16),
    );
    final hitWidth = math.max(24.0, badgeWidth + 8);
    return Positioned(
      key: ValueKey('map-collapse-position-${node.id}'),
      left: center.dx + _origin.dx - hitWidth / 2,
      top: center.dy + _origin.dy - 12,
      width: hitWidth,
      height: 24,
      child: IgnorePointer(
        ignoring: _dragging != null,
        child: Semantics(
          button: true,
          label: node.collapsed ? '展开细分主题' : '折叠细分主题',
          value: '$count 个后代主题',
          child: Tooltip(
            message: node.collapsed
                ? '展开 $count 个后代主题 Ctrl+/'
                : '折叠细分主题 Ctrl+/',
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              onEnter: (_) => setState(() => _hoveredCollapseId = node.id),
              onExit: (_) {
                if (_hoveredCollapseId == node.id) {
                  setState(() => _hoveredCollapseId = null);
                }
              },
              child: GestureDetector(
                key: ValueKey('map-collapse-${node.id}'),
                behavior: HitTestBehavior.opaque,
                onTapDown: (_) => _clearMouseClicks(),
                onTap: () => _toggleTopicCollapsed(node),
                child: CustomPaint(
                  painter: _CollapseConnectorPainter(
                    color,
                    direction,
                    distance,
                  ),
                  child: Center(
                    child: Container(
                      key: ValueKey('map-collapse-badge-${node.id}'),
                      width: badgeWidth,
                      height: node.collapsed ? 16 : 12,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: _hoveredCollapseId == node.id
                            ? Color.alphaBlend(
                                color.withValues(alpha: .12),
                                OpenNoteTokens.surface,
                              )
                            : OpenNoteTokens.surface,
                        border: Border.all(color: color),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: node.collapsed
                          ? Text(
                              '$count',
                              textScaler: TextScaler.noScaling,
                              style: TextStyle(
                                fontSize: 10,
                                height: 1,
                                color: color,
                              ),
                            )
                          : null,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Offset _worldFromGlobal(Offset global) {
    if (!mounted || !_active) return Offset.zero;
    final box = _viewport.currentContext!.findRenderObject()! as RenderBox;
    return _transform.toScene(box.globalToLocal(global)) - _origin;
  }

  Offset _screenFromWorld(Offset world) =>
      MatrixUtils.transformPoint(_transform.value, world + _origin);

  void _setView(double scale, Offset topLeft) {
    if (!mounted) return;
    final value = scale.clamp(.08, 2.5).toDouble();
    _transform.value = Matrix4.identity()
      ..translateByDouble(
        -(topLeft.dx + _origin.dx) * value,
        -(topLeft.dy + _origin.dy) * value,
        0,
        1,
      )
      ..scaleByDouble(value, value, value, 1);
  }

  void _fitAll({MapSnapshot? snapshot}) {
    if (_size.isEmpty) return;
    var visibleNodes = _nodes.values.where((n) => _shownIds.contains(n.id));
    if (snapshot != null) {
      if (snapshot.map.id != widget.snapshot.map.id) return;
      final byId = {for (final node in snapshot.nodes) node.id: node};
      final children = <String, List<MapNode>>{};
      for (final node in snapshot.nodes) {
        if (node.parentNodeId != null) {
          (children[node.parentNodeId!] ??= []).add(node);
        }
      }
      final pending = snapshot.nodes
          .where((node) => !byId.containsKey(node.parentNodeId))
          .toList();
      final visible = <MapNode>[];
      final seen = <String>{};
      while (pending.isNotEmpty) {
        final node = pending.removeLast();
        if (!seen.add(node.id)) continue;
        visible.add(node);
        if (!node.collapsed) {
          pending.addAll(children[node.id] ?? const []);
        }
      }
      visibleNodes = visible;
    }
    final bounds = _contentBounds(
      visibleNodes,
      (snapshot ?? widget.snapshot).edges,
    ).inflate(60);
    final scale = math
        .min(
          1.0,
          math.min(
            (_size.width - 80) / bounds.width,
            (_size.height - 60) / bounds.height,
          ),
        )
        .clamp(.08, 2.5)
        .toDouble();
    _setView(
      scale,
      bounds.center - Offset(_size.width, _size.height) / (2 * scale),
    );
  }

  void _centerNode(String id) {
    final node = _nodes[id];
    if (node == null || _size.isEmpty) return;
    final scale = _transform.value
        .getMaxScaleOnAxis()
        .clamp(.5, 1.4)
        .toDouble();
    _setView(
      scale,
      _rect(node).center - Offset(_size.width, _size.height) / (2 * scale),
    );
  }

  /// 编辑区收窄视口后仅平移必要距离，不缩放、不改变焦点或选择。
  void _keepNodeVisible(String id) {
    final node = _nodes[id];
    if (!mounted || !_active || node == null || _size.isEmpty) return;
    final screen = MatrixUtils.transformRect(
      _transform.value,
      _rect(node).shift(_origin),
    );
    final safe = Rect.fromLTRB(12, 60, _size.width - 12, _size.height - 12);
    double shift(double start, double end, double low, double high) {
      if (end - start > high - low) return (low + high - start - end) / 2;
      if (start < low) return low - start;
      if (end > high) return high - end;
      return 0;
    }

    final delta = Offset(
      shift(screen.left, screen.right, safe.left, safe.right),
      shift(screen.top, screen.bottom, safe.top, safe.bottom),
    );
    if (delta == Offset.zero) return;
    final value = _transform.value.clone();
    value.setEntry(0, 3, value.entry(0, 3) + delta.dx);
    value.setEntry(1, 3, value.entry(1, 3) + delta.dy);
    _transform.value = value;
  }

  void _consumePendingCenter() {
    if (!mounted || !_active || _size.isEmpty) return;
    final controller = widget.controller;
    if (controller == null || !identical(controller._state, this)) return;
    final id = controller._pendingCenterId;
    if (id == null || !_nodes.containsKey(id) || !_shownIds.contains(id)) {
      return;
    }
    controller._pendingCenterId = null;
    _centerNode(id);
  }

  void _zoom(double factor) {
    if (_size.isEmpty) return;
    final old = _transform.value.getMaxScaleOnAxis();
    final center =
        _transform.toScene(Offset(_size.width / 2, _size.height / 2)) - _origin;
    final scale = (old * factor).clamp(.08, 2.5).toDouble();
    _setView(scale, center - Offset(_size.width, _size.height) / (2 * scale));
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
    // 等本次 down 的 TextField TapRegion 失焦完成，再把焦点交给脑图。
    Future.microtask(() {
      if (mounted && _active && _titleNodeId == null) _focus.requestFocus();
    });
  }

  void _clearPressed([String? nodeId]) {
    if (nodeId != null && _pressedNodeId != nodeId) return;
    _pressedNodeId = null;
    _pressedCtrl = false;
    _mouseClickDown = null;
    _mouseClickUp = null;
    _secondMouseClick = false;
  }

  void _clearMouseClicks() {
    _lastMouseClick = null;
    _mouseClickDown = null;
    _mouseClickUp = null;
    _secondMouseClick = false;
  }

  void _cancelNodeClick(String nodeId) {
    if (_pressedNodeId != nodeId) return;
    _clearMouseClicks();
    _clearPressed(nodeId);
  }

  void _nodePointerDown(MapNode node, PointerDownEvent event) {
    final previous = _lastMouseClick;
    _clearMouseClicks();
    if (event.buttons != kPrimaryMouseButton) return;
    if (_busy || !_active || _associationMode) return;
    final current = _nodes[node.id];
    if (current == null) return;
    _pressedInvalidated = false;
    _pressedNodeId = node.id;
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    _pressedCtrl = widget.onToggleSelection != null && ctrl;
    if (event.kind == PointerDeviceKind.mouse && !ctrl) {
      _mouseClickDown = event;
      final gap = previous == null ? null : event.timeStamp - previous.upTime;
      // 单击仍由原 tap 立即完成；只用真实事件记录识别下一次完整鼠标点击。
      _secondMouseClick =
          previous != null &&
          previous.nodeId == current.id &&
          previous.cardId == current.cardId &&
          previous.device == event.device &&
          gap != null &&
          gap >= kDoubleTapMinTime &&
          gap <= kDoubleTapTimeout &&
          (event.position - previous.position).distance <= kDoubleTapSlop;
    }
    if (_pressedCtrl ||
        (_selectedIds.length > 1 && _selectedIds.contains(node.id))) {
      // 保留组直到完整点击/拖动分类完成；不能在down时丢掉group drag的成员。
      _requestFocus();
    } else {
      _select(current);
    }
  }

  void _nodePointerUp(MapNode node, PointerUpEvent event) {
    final down = _mouseClickDown;
    if (_pressedNodeId == node.id &&
        down != null &&
        event.pointer == down.pointer &&
        event.device == down.device &&
        event.kind == PointerDeviceKind.mouse &&
        event.timeStamp >= down.timeStamp) {
      _mouseClickUp = event;
    }
  }

  void _select(MapNode node) {
    _requestFocus();
    setState(() {
      _selectedIds = {node.id};
      _selectedId = node.id;
      _selectedEdge = null;
      _selectedBoundary = null;
    });
    widget.onSelect(node);
  }

  void _toggleSelection(MapNode node) {
    _requestFocus();
    setState(() {
      if (_selectedIds.remove(node.id)) {
        if (_selectedId == node.id) _selectedId = _selectedIds.lastOrNull;
      } else {
        _selectedIds.add(node.id);
        _selectedId = node.id;
      }
      _selectedEdge = null;
      _selectedBoundary = null;
    });
    // 只发送toggle意图；工作台必须在执行时对控制器最新集合操作。
    widget.onToggleSelection?.call(node);
  }

  Future<void> _run(
    Future<void> Function() action, {
    bool showProgress = true,
  }) async {
    if (_busy || !mounted || !_active) return;
    setState(() {
      _busy = true;
      _showLocalProgress = showProgress;
    });
    try {
      await action();
    } catch (error) {
      _pendingPositions.clear();
      _previewEdge = null;
      if (mounted && _active) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(SnackBar(content: Text('$error')));
      }
    } finally {
      if (mounted && _active) setState(() => _busy = false);
    }
  }

  void _beginAssociation(String id) {
    _clearMouseClicks();
    if (!_nodes.containsKey(id) || _busy) return;
    _select(_nodes[id]!);
    setState(() {
      _associationFrom = id;
      _associationMode = true;
      _selectedId = id;
      _selectedEdge = null;
    });
    _focus.requestFocus();
  }

  void _createChosenAssociation() {
    if (_busy ||
        !mounted ||
        !_active ||
        !widget.canCreate ||
        _edgeDrag != null) {
      return;
    }
    if (_selectedIds.length == 2) {
      final ids = _selectedIds.toList();
      _run(() => widget.onAssociate(ids[0], ids[1]));
    } else if (_selectedId != null) {
      _beginAssociation(_selectedId!);
    } else {
      _clearMouseClicks();
      setState(() {
        _associationMode = true;
        _associationFrom = null;
        _selectedEdge = null;
        _marqueeMode = false;
      });
      _focus.requestFocus();
    }
  }

  void _createRelatedAt(Offset position) {
    final create = widget.onCreateRelatedAt;
    if (create == null) return;
    final from = _associationFrom, mapId = widget.snapshot.map.id;
    _run(() async {
      final nodeId = await create(position, from);
      if (!mounted ||
          !_active ||
          widget.snapshot.map.id != mapId ||
          !_associationMode ||
          _associationFrom != from) {
        return;
      }
      setState(() {
        _associationFrom = from == null ? nodeId : null;
        _associationMode = from == null;
        _cursor = null;
      });
      _focus.requestFocus();
    });
  }

  void _activateNode(MapNode node) {
    if (_busy || !mounted || !_active) return;
    if (_pressedInvalidated) return;
    final current = _nodes[node.id];
    if (current == null) return;
    final toggle = _pressedNodeId == node.id && _pressedCtrl;
    final down = _mouseClickDown;
    final up = _mouseClickUp;
    final edit = _secondMouseClick;
    _clearPressed();
    final from = _associationFrom;
    if (_associationMode) {
      _clearMouseClicks();
      if (from == null) {
        _beginAssociation(current.id);
      } else if (from != node.id) {
        setState(() {
          _associationFrom = null;
          _associationMode = false;
        });
        _run(() => widget.onAssociate(from, node.id));
      }
      return;
    }
    if (toggle && widget.onToggleSelection != null) {
      _toggleSelection(current);
      return;
    }
    if (_selectedId != node.id || _selectedIds.length != 1) _select(current);
    if (edit &&
        down != null &&
        up != null &&
        !HardwareKeyboard.instance.isControlPressed) {
      // 第二次成功抬起只编辑最新节点，不再次请求原文定位。
      final local = _worldFromGlobal(up.position) - _position(current);
      if (widget.onCommitTitle != null &&
          local.dy <= 36 &&
          local.dx < current.width - 32) {
        _beginTitle(current.id);
      } else {
        widget.onAction(current, 'edit');
      }
      return;
    }
    if (down != null &&
        up != null &&
        !HardwareKeyboard.instance.isControlPressed) {
      _lastMouseClick = (
        nodeId: current.id,
        cardId: current.cardId,
        device: down.device,
        position: up.position,
        upTime: up.timeStamp,
      );
    }
    // 第一次完整点击立即激活，按下选中或拖动不会跳转原文。
    widget.onActivate?.call(current);
  }

  Set<String> _branchIds(String rootId) {
    final result = <String>{};
    final pending = [rootId];
    for (var i = 0; i < pending.length; i++) {
      if (result.add(pending[i])) {
        pending.addAll(_children[pending[i]] ?? const []);
      }
    }
    return result;
  }

  Set<String> _dragMemberIds(Set<String> roots) {
    final result = <String>{};
    for (final root in roots) {
      result.addAll(_branchIds(root));
    }
    // 完整范围随分支一起移动；与仓储保存时的概要归属保持一致。
    // 迭代补齐嵌套概要，使预览与松开后的保存位置一致。
    var changed = true;
    while (changed) {
      changed = false;
      for (final summary in widget.snapshot.summaries) {
        if (result.contains(summary.summaryNodeId) ||
            !_nodes.containsKey(summary.summaryNodeId)) {
          continue;
        }
        final scope = summaryRoots(
          summary,
          _nodes.values,
          widget.snapshot.summaries,
        );
        if (scope.isNotEmpty &&
            scope.every((node) => result.contains(node.id))) {
          result.addAll(_branchIds(summary.summaryNodeId));
          changed = true;
        }
      }
    }
    return result;
  }

  bool _dragIsValid() {
    final id = _dragging;
    if (id == null || !_nodes.containsKey(id) || !_shownIds.contains(id)) {
      return false;
    }
    for (final root in _dragRoots) {
      if (!_nodes.containsKey(root)) return false;
    }
    final branch = _dragMemberIds(_dragRoots);
    if (branch.length != _dragIds.length || !branch.containsAll(_dragIds)) {
      return false;
    }
    for (final memberId in _dragIds) {
      final current = _nodes[memberId];
      final start = _dragStartNodes[memberId];
      if (current == null ||
          start == null ||
          current.branchLayout != start.branchLayout ||
          current.parentNodeId != start.parentNodeId ||
          current.x != start.x ||
          current.y != start.y) {
        return false;
      }
    }
    final target = _dropTarget;
    return target == null ||
        (_nodes.containsKey(target) &&
            _shownIds.contains(target) &&
            !_dragIds.contains(target) &&
            _nodes[target]!.cardId == _dropIntent?.anchor.cardId &&
            _nodes[target]!.parentNodeId == _dropIntent?.anchor.parentNodeId &&
            _nodes[target]!.branchLayout == _dropIntent?.anchor.branchLayout);
  }

  void _resetDrag() {
    if (_dragging != null) _dragCursor.hide();
    _clearMouseClicks();
    for (final controller in _nodeSnapshots.values) {
      controller.allowSnapshotting = false;
    }
    _snapshotDependenciesChangedInDrag = false;
    _dragging = null;
    _dragIds = {};
    _dragRoots = {};
    _dragStartNodes = {};
    _dropTarget = null;
    _dropIntent = null;
    _dragGrab = Offset.zero;
    _dragDelta = Offset.zero;
    _dragGroup = false;
    _clearPressed();
  }

  void _startDrag(MapNode node, DragStartDetails details) {
    _clearMouseClicks();
    if (_busy ||
        _associationMode ||
        _edgeDrag != null ||
        !mounted ||
        !_active) {
      return;
    }
    final current = _nodes[node.id];
    if (current == null || !_shownIds.contains(current.id)) return;
    final group = _selectedIds.length > 1 && _selectedIds.contains(current.id);
    _clearPressed();
    if (group && widget.onMoveGroup == null) return;
    _dragCursor.show(context, SystemMouseCursors.grabbing);
    // 按下时已完成本地选中；开始拖动不再重复向工作台提交同一个选择。
    if (!group && (_selectedId != current.id || _selectedIds.length != 1)) {
      _select(current);
    }
    setState(() {
      _dragging = current.id;
      _dragGroup = group;
      _dragRoots = group ? Set.of(_selectedIds) : {current.id};
      _dragIds = _dragMemberIds(_dragRoots);
      _dragStartNodes = {for (final id in _dragIds) id: _nodes[id]!};
      _dragDelta = Offset.zero;
      _dragGrab = _worldFromGlobal(details.globalPosition) - _position(current);
      _dropTarget = null;
      _dropIntent = null;
    });
  }

  void _updateDrag(DragUpdateDetails details) {
    if (!mounted || !_active) return;
    final id = _dragging;
    if (id == null) return;
    if (!_dragIsValid()) {
      _cancelDrag();
      _cancelSummaryDrag();
      return;
    }
    final cursor = _worldFromGlobal(details.globalPosition);
    final node = _nodes[id]!;
    final target = _dragGroup
        ? null
        : topicDropTargetAt(
            _nodes.values,
            _shownIds,
            _dragIds,
            PdfPoint(cursor.dx, cursor.dy),
            widget.snapshot.map.layout,
            _branchLayouts,
            allowSiblings: widget.onDropTopic != null,
          );
    setState(() {
      _dragDelta =
          cursor -
          _dragGrab -
          (_pendingPositions[id] ?? Offset(node.x, node.y));
      _dropIntent = target;
      _dropTarget = target?.anchor.id;
    });
  }

  void _finishDrag() {
    if (!mounted || !_active) return;
    final id = _dragging;
    if (id == null) return;
    if (!_dragIsValid()) {
      _cancelDrag();
      return;
    }
    final root = _nodes[id]!;
    final source = _dragStartNodes[id]!;
    final dropIntent = _dropIntent;
    final position = _position(root);
    final target = _dropTarget;
    final group = _dragGroup;
    final moveGroup = widget.onMoveGroup;
    final moved = _dragDelta.distance > .5;
    // 自动结构只接受层级或顺序调整，空白落点不改变布局锚点。
    // 组内已包含的后代随顶层分支移动，不单独判断它的入枝布局。
    final freelyMovable = _dragRoots
        .map((rootId) => _nodes[rootId]!)
        .where((node) => !_dragIds.contains(node.parentNodeId))
        .every(
          (node) =>
              incomingBranchLayout(
                node,
                widget.snapshot.map.layout,
                _branchLayouts,
              ) ==
              MapLayoutKind.free,
        );
    if (target == null && !freelyMovable) {
      setState(_resetDrag);
      return;
    }
    final positions = <String, Offset>{};
    if (moved &&
        (group ||
            target == null ||
            widget.onReparentAt != null ||
            widget.onDropTopic != null)) {
      for (final childId in _dragIds) {
        positions[childId] = _position(_nodes[childId]!);
      }
      _pendingPositions.addAll(positions);
    }
    setState(_resetDrag);
    if (!moved) return;
    if (group) {
      if (moveGroup == null) return;
      final submitted = Map<String, PdfPoint>.unmodifiable({
        for (final entry in positions.entries)
          entry.key: PdfPoint(entry.value.dx, entry.value.dy),
      });
      _run(() => moveGroup(submitted));
      return;
    }
    _run(
      () => target == null
          ? widget.onMove(id, position.dx, position.dy)
          : widget.onDropTopic != null && dropIntent != null
          ? widget.onDropTopic!(source, dropIntent, position.dx, position.dy)
          : widget.onReparentAt != null
          ? widget.onReparentAt!(id, target, position.dx, position.dy)
          : widget.onReparent(id, target),
    );
  }

  void _cancelDrag() {
    if (!mounted || !_active) {
      _resetDrag();
      return;
    }
    setState(_resetDrag);
  }

  bool get _creationAllowed =>
      mounted &&
      _active &&
      widget.canCreate &&
      !_busy &&
      _incomingText == null &&
      _dragging == null &&
      _edgeDrag == null &&
      !_associationMode;

  void _createRelative(MapNode node, String action) {
    _clearMouseClicks();
    if (_creationAllowed) widget.onAction(node, action);
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
    if (!_creationAllowed || widget.onCommitTitle == null || _titleSaving) {
      return;
    }
    final id = widget.controller?._pendingTitleId;
    if (id == null || !_nodes.containsKey(id) || !_shownIds.contains(id)) {
      return;
    }
    widget.controller?._pendingTitleId = null;
    _beginTitle(id);
  }

  void _beginTitle(String nodeId, {String? replaceWith}) {
    if (!_creationAllowed || widget.onCommitTitle == null || _titleSaving) {
      return;
    }
    if (_titleNodeId != null && _titleNodeId != nodeId) {
      unawaited(
        _commitTitle().then((_) {
          if (mounted &&
              _active &&
              _titleNodeId == null &&
              _selectedId == nodeId) {
            _beginTitle(nodeId, replaceWith: replaceWith);
          }
        }),
      );
      return;
    }
    final node = _nodes[nodeId];
    if (node == null || !_shownIds.contains(nodeId)) return;
    _clearMouseClicks();
    final title = replaceWith ?? widget.snapshot.cards[node.cardId]!.title;
    _titleText.value = TextEditingValue(
      text: title,
      selection: replaceWith != null
          ? TextSelection.collapsed(offset: title.length)
          : TextSelection(baseOffset: 0, extentOffset: title.length),
    );
    setState(() {
      _titleNodeId = nodeId;
      _titleCardId = node.cardId;
      _titleGeneration++;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _active && _titleNodeId == nodeId) {
        _titleFocus.requestFocus();
      }
    });
  }

  void _finishTitle() {
    if (_titleNodeId == null) return;
    final hadFocus = _titleFocus.hasFocus;
    _titleNodeId = null;
    _titleCardId = null;
    _titleGeneration++;
    if (hadFocus && mounted && _active) _focus.requestFocus();
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
    setState(() => _titleSaving = true);
    try {
      await widget.onCommitTitle?.call();
      if (mounted &&
          _active &&
          _titleNodeId == null &&
          node != null &&
          nextAction != null) {
        widget.onAction(node, nextAction);
      }
    } catch (_) {
      // 工作台已经展示保存错误，保留输入和目标供用户修正、重试。
      if (mounted && _active) _titleFocus.requestFocus();
    } finally {
      if (mounted) {
        setState(() => _titleSaving = false);
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _consumePendingTitle(),
        );
      }
    }
  }

  void _replaceSelection(Set<String> ids, String? primary) {
    _clearMouseClicks();
    setState(() {
      _selectedIds = ids;
      _selectedId = ids.contains(primary) ? primary : ids.lastOrNull;
      _selectedEdge = null;
    });
    widget.onSelectionChanged?.call(Set.unmodifiable(ids), _selectedId);
  }

  bool get _canMarquee =>
      widget.onSelectionChanged != null &&
      _creationAllowed &&
      _titleNodeId == null &&
      (_marqueeMode || HardwareKeyboard.instance.isShiftPressed);

  void _beginMarquee(DragStartDetails details) {
    if (!_creationAllowed ||
        widget.onSelectionChanged == null ||
        _titleNodeId != null) {
      return;
    }
    _clearMouseClicks();
    _doubleTapWorld = null;
    _requestFocus();
    final point = _worldFromGlobal(details.globalPosition);
    setState(() {
      _marqueeBase = Set.of(_selectedIds);
      _marqueePrimary = _selectedId;
      _marquee = Rect.fromPoints(point, point);
      _selectedEdge = null;
    });
  }

  void _updateMarquee(DragUpdateDetails details) {
    final box = _marquee;
    if (box == null || !mounted || !_active) return;
    setState(() {
      // 拖动方向可能反转，起点单独保存，不能使用已归一化矩形的左上角。
      _marquee = Rect.fromPoints(
        _marqueeStart!,
        _worldFromGlobal(details.globalPosition),
      );
      final hits = _nodes.values
          .where(
            (node) =>
                _shownIds.contains(node.id) && _rect(node).overlaps(_marquee!),
          )
          .map((node) => node.id);
      _selectedIds = {if (_marqueeAdditive) ..._marqueeBase, ...hits};
      _selectedId = _selectedIds.contains(_marqueePrimary)
          ? _marqueePrimary
          : _selectedIds.lastOrNull;
    });
  }

  Offset? _marqueeStart;

  void _finishMarquee(DragEndDetails details) {
    if (_marquee == null || !mounted || !_active) return;
    final ids = {
      if (_marqueeAdditive) ..._marqueeBase.where(_nodes.containsKey),
      ..._selectedIds.where(_shownIds.contains),
    };
    final primary = _selectedId;
    _marquee = null;
    _marqueeStart = null;
    _marqueeBase = {};
    _marqueePrimary = null;
    // 逐帧只绘制选择预览；抬起时统一交给工作台，不逐帧提交业务命令。
    _replaceSelection(ids, primary);
  }

  void _cancelMarquee({bool restore = true}) {
    if (_marquee == null) return;
    if (restore) {
      _selectedIds = _marqueeBase.where(_nodes.containsKey).toSet();
      _selectedId = _selectedIds.contains(_marqueePrimary)
          ? _marqueePrimary
          : _selectedIds.lastOrNull;
    }
    _marquee = null;
    _marqueeStart = null;
    _marqueeBase = {};
    _marqueePrimary = null;
  }

  void _navigateMixedTopic(LogicalKeyboardKey key, {required bool additive}) {
    final shown = _nodes.values.where((n) => _shownIds.contains(n.id)).toList()
      ..sort(compareMapNodes);
    if (shown.isEmpty) return;
    final current = _nodes[_selectedId];
    MapNode? target;
    if (current == null ||
        key == LogicalKeyboardKey.home ||
        key == LogicalKeyboardKey.end) {
      final children = <String, List<MapNode>>{};
      for (final n in shown) {
        (children[n.parentNodeId ?? ''] ??= []).add(n);
      }
      final stack = shown
          .where((n) => !_nodes.containsKey(n.parentNodeId))
          .toList()
          .reversed
          .toList();
      final ordered = <MapNode>[], seen = <String>{};
      while (stack.isNotEmpty) {
        final n = stack.removeLast();
        if (!seen.add(n.id)) continue;
        ordered.add(n);
        stack.addAll((children[n.id] ?? const <MapNode>[]).reversed);
      }
      if (ordered.isEmpty) return;
      target = key == LogicalKeyboardKey.end ? ordered.last : ordered.first;
    } else {
      final direction = _branchLayouts[current.id]!;
      final forward = switch (direction.primaryDirection) {
        MapLayoutKind.left => LogicalKeyboardKey.arrowLeft,
        MapLayoutKind.down => LogicalKeyboardKey.arrowDown,
        MapLayoutKind.up => LogicalKeyboardKey.arrowUp,
        _ => LogicalKeyboardKey.arrowRight,
      };
      if (current.collapsed &&
          (_children[current.id] ?? const []).isNotEmpty &&
          (key == forward ||
              direction == MapLayoutKind.mindMap &&
                  key == LogicalKeyboardKey.arrowLeft)) {
        widget.onToggleCollapsed(current.id);
        return;
      }
      final auxiliary = widget.snapshot.summaries
          .map((s) => s.summaryNodeId)
          .toSet();
      final ordinaryChildren = shown
          .where(
            (n) => n.parentNodeId == current.id && !auxiliary.contains(n.id),
          )
          .toList();
      final incoming = incomingBranchLayout(
        current,
        widget.snapshot.map.layout,
        _branchLayouts,
      );
      final backward = switch (forward) {
        LogicalKeyboardKey.arrowLeft => LogicalKeyboardKey.arrowRight,
        LogicalKeyboardKey.arrowDown => LogicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.arrowUp => LogicalKeyboardKey.arrowDown,
        _ => LogicalKeyboardKey.arrowLeft,
      };
      var semantic = false;
      if (direction.tree && key == forward ||
          direction.spine && key == forward) {
        semantic = true;
        target = ordinaryChildren.firstOrNull;
      } else if (direction.tree && key == backward) {
        semantic = true;
        target = _nodes[current.parentNodeId];
      } else if (incoming.spine && !auxiliary.contains(current.id)) {
        final nextKey = incoming == MapLayoutKind.timelineVertical
            ? LogicalKeyboardKey.arrowDown
            : incoming.reverseSiblingOrder
            ? LogicalKeyboardKey.arrowLeft
            : LogicalKeyboardKey.arrowRight;
        final previousKey = incoming == MapLayoutKind.timelineVertical
            ? LogicalKeyboardKey.arrowUp
            : incoming.reverseSiblingOrder
            ? LogicalKeyboardKey.arrowRight
            : LogicalKeyboardKey.arrowLeft;
        if (key == nextKey || key == previousKey) {
          semantic = true;
          final siblings = shown
              .where(
                (n) =>
                    n.parentNodeId == current.parentNodeId &&
                    !auxiliary.contains(n.id),
              )
              .toList();
          final index = siblings.indexWhere((n) => n.id == current.id);
          final next = index + (key == nextKey ? 1 : -1);
          target = next < 0
              ? _nodes[current.parentNodeId]
              : next < siblings.length
              ? siblings[next]
              : null;
        }
      }
      final axis = switch (key) {
        LogicalKeyboardKey.arrowLeft => const Offset(-1, 0),
        LogicalKeyboardKey.arrowUp => const Offset(0, -1),
        LogicalKeyboardKey.arrowDown => const Offset(0, 1),
        _ => const Offset(1, 0),
      };
      final center = _rect(current).center;
      var best = double.infinity;
      for (final candidate in semantic ? const <MapNode>[] : shown) {
        if (candidate.id == current.id) continue;
        final delta = _rect(candidate).center - center;
        final along = delta.dx * axis.dx + delta.dy * axis.dy;
        final across = (delta.dx * axis.dy - delta.dy * axis.dx).abs();
        if (along <= 1 || across > along * 1.5) continue;
        final related =
            candidate.parentNodeId == current.id ||
            current.parentNodeId == candidate.id ||
            candidate.parentNodeId == current.parentNodeId;
        final score = along + across * 2 + (related ? 0 : 180);
        if (score < best) {
          target = candidate;
          best = score;
        }
      }
    }
    if (target == null) return;
    if (additive && widget.onSelectionChanged != null) {
      _replaceSelection({..._selectedIds, target.id}, target.id);
    } else {
      _select(target);
    }
    if (!(Offset.zero & _size)
        .deflate(28)
        .contains(_screenFromWorld(_rect(target).center))) {
      _centerNode(target.id);
    }
  }

  Widget _dropInsertionMarker(MapNode node) {
    final rect = _rect(node).shift(_origin);
    final incoming = incomingBranchLayout(
      node,
      widget.snapshot.map.layout,
      _branchLayouts,
    );
    final vertical = incoming.siblingsHorizontal;
    final before =
        (_dropIntent!.placement == TopicDropPlacement.before) !=
        incoming.reverseSiblingOrder;
    return Positioned(
      left: vertical
          ? (before ? rect.left - 8 : rect.right + 2)
          : rect.left - 10,
      top: vertical ? rect.top - 10 : (before ? rect.top - 8 : rect.bottom + 2),
      width: vertical ? 12 : rect.width + 20,
      height: vertical ? rect.height + 20 : 12,
      child: IgnorePointer(
        child: CustomPaint(
          key: const ValueKey('map-drop-insertion'),
          painter: _TopicInsertionPainter(vertical),
        ),
      ),
    );
  }

  void _navigateTopic(LogicalKeyboardKey key, {required bool additive}) {
    if (widget.snapshot.map.layout.extended ||
        _nodes.values.any((n) => n.branchLayout != null)) {
      _navigateMixedTopic(key, additive: additive);
      return;
    }
    final current = _nodes[_selectedId];
    final layout = widget.snapshot.map.layout;
    var ordered =
        _nodes.values.where((node) => _shownIds.contains(node.id)).toList()
          ..sort(compareMapNodes);
    if (ordered.isEmpty) return;
    if (layout != MapLayoutKind.free) {
      final roots = ordered
          .where((node) => !_nodes.containsKey(node.parentNodeId))
          .toList();
      final pending = roots.reversed.toList();
      ordered = [];
      final seen = <String>{};
      while (pending.isNotEmpty) {
        final node = pending.removeLast();
        if (!seen.add(node.id)) continue;
        ordered.add(node);
        final children =
            (_children[node.id] ?? const <String>[])
                .where(_shownIds.contains)
                .map((id) => _nodes[id]!)
                .toList()
              ..sort(compareMapNodes);
        pending.addAll(children.reversed);
      }
    }
    var childKey = layout.vertical
        ? (layout == MapLayoutKind.up
              ? LogicalKeyboardKey.arrowUp
              : LogicalKeyboardKey.arrowDown)
        : (layout == MapLayoutKind.left
              ? LogicalKeyboardKey.arrowLeft
              : LogicalKeyboardKey.arrowRight);
    var parentKey = layout.vertical
        ? (layout == MapLayoutKind.up
              ? LogicalKeyboardKey.arrowDown
              : LogicalKeyboardKey.arrowUp)
        : (layout == MapLayoutKind.left
              ? LogicalKeyboardKey.arrowRight
              : LogicalKeyboardKey.arrowLeft);
    if (layout == MapLayoutKind.mindMap && current?.parentNodeId != null) {
      var branch = current!;
      final seen = <String>{};
      while (_nodes[branch.parentNodeId]?.parentNodeId != null &&
          seen.add(branch.id)) {
        branch = _nodes[branch.parentNodeId]!;
      }
      final root = _nodes[branch.parentNodeId];
      if (root != null && branch.x < root.x) {
        childKey = LogicalKeyboardKey.arrowLeft;
        parentKey = LogicalKeyboardKey.arrowRight;
      }
    }
    MapNode? target;
    if (current == null || key == LogicalKeyboardKey.home) {
      target = ordered.first;
    } else if (key == LogicalKeyboardKey.end) {
      target = ordered.last;
    } else if (layout == MapLayoutKind.mindMap &&
        current.parentNodeId == null &&
        (key == LogicalKeyboardKey.arrowLeft ||
            key == LogicalKeyboardKey.arrowRight)) {
      if (current.collapsed && (_children[current.id] ?? const []).isNotEmpty) {
        widget.onToggleCollapsed(current.id);
        return;
      }
      final left = key == LogicalKeyboardKey.arrowLeft;
      target = ordered
          .where(
            (n) => n.parentNodeId == current.id && (n.x < current.x) == left,
          )
          .firstOrNull;
    } else if (key == parentKey) {
      target = _nodes[current.parentNodeId];
    } else if (key == childKey) {
      if (current.collapsed && (_children[current.id] ?? const []).isNotEmpty) {
        widget.onToggleCollapsed(current.id);
        return;
      }
      target = ordered.where((n) => n.parentNodeId == current.id).firstOrNull;
    } else {
      final siblings = ordered
          .where((n) => n.parentNodeId == current.parentNodeId)
          .where(
            (n) =>
                layout != MapLayoutKind.mindMap ||
                _nodes[current.parentNodeId]?.parentNodeId != null ||
                current.parentNodeId == null ||
                (n.x < _nodes[current.parentNodeId]!.x) ==
                    (current.x < _nodes[current.parentNodeId]!.x),
          )
          .toList();
      final index = siblings.indexWhere((n) => n.id == current.id);
      final next =
          index +
          (key ==
                  (layout.vertical
                      ? LogicalKeyboardKey.arrowLeft
                      : LogicalKeyboardKey.arrowUp)
              ? -1
              : 1);
      if (next >= 0 && next < siblings.length) target = siblings[next];
    }
    if (target == null) return;
    if (additive && widget.onSelectionChanged != null) {
      _replaceSelection({..._selectedIds, target.id}, target.id);
    } else {
      _select(target);
    }
    final screen = _screenFromWorld(_rect(target).center);
    if (!(Offset.zero & _size).deflate(28).contains(screen)) {
      _centerNode(target.id);
    }
  }

  KeyEventResult _key(FocusNode focus, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed) _clearMouseClicks();
    final textFocus =
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<EditableText>() !=
        null;
    if (textFocus) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      final hasAction =
          _dragging != null ||
          _edgeDrag != null ||
          _boundaryDrag != null ||
          _summaryDrag != null ||
          _marquee != null ||
          _marqueeMode ||
          _associationMode ||
          _associationFrom != null ||
          _selectedEdge != null ||
          _selectedBoundary != null;
      if (!hasAction) return KeyEventResult.ignored;
      _dragCursor.hide();
      _cancelBoundaryDrag();
      _cancelSummaryDrag();
      if (_edgeDrag != null) setState(_cancelEdgeDrag);
      setState(() {
        _cancelMarquee();
        _marqueeMode = false;
      });
      _cancelDrag();
      setState(() {
        _associationFrom = null;
        _associationMode = false;
        _selectedEdge = null;
        _selectedBoundary = null;
      });
      return KeyEventResult.handled;
    }
    if (_busy || !_active || _dragging != null || _edgeDrag != null) {
      return KeyEventResult.ignored;
    }
    if (keyboard.isControlPressed &&
        !keyboard.isShiftPressed &&
        event.logicalKey == LogicalKeyboardKey.slash &&
        _selectedId != null) {
      final node = _nodes[_selectedId]!;
      if ((_children[node.id] ?? const []).isNotEmpty) {
        if (keyboard.isAltPressed) {
          widget.onAction(node, 'collapseBranch');
        } else {
          widget.onToggleCollapsed(node.id);
        }
      }
      return KeyEventResult.handled;
    }
    if (keyboard.isControlPressed &&
        keyboard.isShiftPressed &&
        event.logicalKey == LogicalKeyboardKey.keyS &&
        widget.onCreateSummaries != null) {
      _createSummary();
      return KeyEventResult.handled;
    }
    if (keyboard.isControlPressed &&
        !keyboard.isShiftPressed &&
        event.logicalKey == LogicalKeyboardKey.keyB &&
        widget.onCreateBoundaries != null) {
      _createBoundary();
      return KeyEventResult.handled;
    }
    if (_selectedBoundary != null &&
        !keyboard.isControlPressed &&
        event.logicalKey == LogicalKeyboardKey.space &&
        widget.onCommitBoundaryLabel != null) {
      unawaited(_beginBoundaryLabel(_selectedBoundary!));
      return KeyEventResult.handled;
    }
    if (_selectedEdge != null &&
        event.logicalKey == LogicalKeyboardKey.space &&
        !keyboard.isControlPressed &&
        widget.onCommitRelationshipLabel != null) {
      unawaited(_beginRelationshipLabel(_selectedEdge!));
      return KeyEventResult.handled;
    }
    if (keyboard.isControlPressed &&
        keyboard.isShiftPressed &&
        event.logicalKey == LogicalKeyboardKey.keyR) {
      _createChosenAssociation();
      return KeyEventResult.handled;
    }
    if (keyboard.isControlPressed && widget.onClipboardAction != null) {
      final action = switch (event.logicalKey) {
        LogicalKeyboardKey.keyC => 'copy',
        LogicalKeyboardKey.keyX => 'cut',
        LogicalKeyboardKey.keyV => 'paste',
        _ => null,
      };
      if (action != null) {
        widget.onClipboardAction!(action);
        return KeyEventResult.handled;
      }
    }
    if (keyboard.isControlPressed &&
        event.logicalKey == LogicalKeyboardKey.keyA &&
        widget.onSelectionChanged != null) {
      _replaceSelection(
        Set.of(_shownIds),
        _selectedId ?? _shownIds.firstOrNull,
      );
      return KeyEventResult.handled;
    }
    if (keyboard.isAltPressed && _selectedId != null) {
      final action = switch (event.logicalKey) {
        LogicalKeyboardKey.arrowUp => 'moveBefore',
        LogicalKeyboardKey.arrowDown => 'moveAfter',
        LogicalKeyboardKey.arrowLeft => 'promote',
        LogicalKeyboardKey.arrowRight => 'demote',
        _ => null,
      };
      if (action != null && _creationAllowed) {
        widget.onAction(_nodes[_selectedId]!, action);
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
        ].contains(event.logicalKey)) {
      _navigateTopic(event.logicalKey, additive: keyboard.isShiftPressed);
      return KeyEventResult.handled;
    }
    if (_selectedId != null &&
        _creationAllowed &&
        !keyboard.isAltPressed &&
        !keyboard.isMetaPressed &&
        event.logicalKey == LogicalKeyboardKey.enter) {
      _createRelative(
        _nodes[_selectedId]!,
        keyboard.isControlPressed
            ? 'newParent'
            : keyboard.isShiftPressed
            ? 'newSiblingBefore'
            : 'newSibling',
      );
      return KeyEventResult.handled;
    }
    if (!textFocus &&
        !keyboard.isControlPressed &&
        !keyboard.isAltPressed &&
        !keyboard.isMetaPressed &&
        !keyboard.isShiftPressed &&
        _selectedId != null &&
        _creationAllowed &&
        (event.logicalKey == LogicalKeyboardKey.tab ||
            event.logicalKey == LogicalKeyboardKey.insert ||
            event.logicalKey == LogicalKeyboardKey.enter)) {
      _createRelative(
        _nodes[_selectedId]!,
        event.logicalKey == LogicalKeyboardKey.insert ||
                event.logicalKey == LogicalKeyboardKey.tab
            ? 'newChild'
            : 'newSibling',
      );
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.delete && !_busy) {
      if (_selectedBoundary != null && widget.onRemoveBoundary != null) {
        final boundary = _boundaryById(_selectedBoundary!);
        if (boundary != null) {
          _run(() => widget.onRemoveBoundary!(boundary), showProgress: false);
        }
      } else if (_selectedEdge != null) {
        widget.onRemoveAssociation(_selectedEdge!);
      } else if (_selectedId != null) {
        widget.onAction(
          _nodes[_selectedId]!,
          keyboard.isControlPressed
              ? 'removeTopicOnly'
              : 'removeSelectedBranches',
        );
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.f2 && _selectedId != null) {
      widget.onAction(_nodes[_selectedId]!, 'editSelected');
      return KeyEventResult.handled;
    }
    if (_selectedId != null &&
        widget.onCommitTitle != null &&
        !keyboard.isControlPressed &&
        !keyboard.isAltPressed &&
        !keyboard.isMetaPressed) {
      if (event.logicalKey == LogicalKeyboardKey.space) {
        _beginTitle(_selectedId!);
        return KeyEventResult.handled;
      }
      final character = event.character;
      if (character != null &&
          character.isNotEmpty &&
          character.runes.every((r) => r >= 32 && r != 127)) {
        _beginTitle(_selectedId!, replaceWith: character);
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  Future<String?> _showContextMenu(
    Offset global,
    List<OpenNoteMenuEntry<String>> entries,
    bool Function() valid, {
    bool openAbove = false,
  }) async {
    _menuValid = valid;
    try {
      return await showOpenNoteContextMenu<String>(
        context: context,
        position: global,
        entries: entries,
        controller: _contextMenuController,
        isValid: valid,
        openAbove: openAbove,
      );
    } finally {
      if (identical(_menuValid, valid)) _menuValid = null;
    }
  }

  void _toggleMarqueeMode() {
    setState(() {
      _clearMouseClicks();
      _cancelMarquee();
      _marqueeMode = !_marqueeMode;
      _associationFrom = null;
      _associationMode = false;
    });
    _focus.requestFocus();
  }

  Future<void> _showToolsMenu(Offset position) async {
    final mapId = widget.snapshot.map.id;
    final selected = Set<String>.of(_selectedIds);
    bool valid() =>
        mounted &&
        _active &&
        widget.snapshot.map.id == mapId &&
        setEquals(selected, _selectedIds) &&
        selected.every(
          (id) => widget.snapshot.nodes.any((node) => node.id == id),
        );
    final structure =
        widget.structureMenuEntries?.call() ??
        const <OpenNoteMenuEntry<String>>[];
    final action = await _showContextMenu(
      position,
      [
        if (structure.isNotEmpty) ...[
          OpenNoteMenuEntry(
            'tool:structure',
            '脑图结构与整理',
            key: const ValueKey('map-structure-menu'),
            icon: Icons.auto_awesome_motion_outlined,
            enabled: widget.canCreate && !_busy,
            children: structure,
          ),
          const OpenNoteMenuEntry.divider(),
        ],
        if (widget.onSelectionChanged != null)
          OpenNoteMenuEntry(
            'tool:marquee',
            '框选卡片',
            key: const ValueKey('map-tool-marquee'),
            icon: _marqueeMode ? Icons.check_rounded : Icons.select_all,
            shortcut: 'Shift+拖动',
            enabled: !_busy,
          ),
        OpenNoteMenuEntry(
          'tool:association',
          '关联卡片',
          key: const ValueKey('map-tool-association'),
          icon: _associationMode ? Icons.check_rounded : Icons.link,
          shortcut: 'Ctrl+Shift+R',
          enabled: widget.canCreate && !_busy,
        ),
        if (widget.onCreateBoundaries != null ||
            widget.onCreateSummaries != null)
          const OpenNoteMenuEntry.divider(),
        if (widget.onCreateBoundaries != null)
          OpenNoteMenuEntry(
            'tool:boundary',
            '添加外框',
            key: const ValueKey('map-tool-boundary'),
            icon: Icons.crop_square,
            shortcut: 'Ctrl+B',
            enabled: !_busy && widget.canCreate && _selectedIds.isNotEmpty,
          ),
        if (widget.onCreateSummaries != null)
          OpenNoteMenuEntry(
            'tool:summary',
            '添加概要',
            key: const ValueKey('map-tool-summary'),
            icon: Icons.data_array,
            shortcut: 'Ctrl+Shift+S',
            enabled: !_busy && widget.canCreate && _selectedIds.isNotEmpty,
          ),
      ],
      valid,
      openAbove: true,
    );
    if (action == null || !valid()) return;
    switch (action) {
      case 'tool:marquee':
        _toggleMarqueeMode();
      case 'tool:association':
        _createChosenAssociation();
      case 'tool:boundary':
        _createBoundary();
      case 'tool:summary':
        _createSummary();
      default:
        widget.onStructureMenuAction?.call(action);
    }
  }

  Widget _canvasTools() => ConstrainedBox(
    constraints: BoxConstraints(maxWidth: math.max(0, _size.width - 24)),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (_associationMode || _marqueeMode)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: IgnorePointer(
              child: Container(
                key: ValueKey(
                  _associationMode
                      ? 'map-association-mode'
                      : 'map-marquee-mode',
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: OpenNoteTokens.accent.withValues(alpha: .06),
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Text(
                  _associationMode
                      ? _associationFrom == null
                            ? '关联中：选择起点或在空白新建 · Esc 退出'
                            : '关联中：选择终点或在空白新建 · Esc 退出'
                      : '框选中 · Esc 退出',
                  style: const TextStyle(
                    color: OpenNoteTokens.accent,
                    fontSize: 12,
                  ),
                ),
              ),
            ),
          ),
        Builder(
          builder: (toolbarContext) => OpenNoteToolGroup(
            key: const ValueKey('map-viewport-controls'),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.creationTools != null) widget.creationTools!,
                _tool('更多脑图工具', Icons.more_horiz, () {
                  final box = toolbarContext.findRenderObject()! as RenderBox;
                  unawaited(
                    _showToolsMenu(box.localToGlobal(const Offset(0, -6))),
                  );
                }, selected: _associationMode || _marqueeMode),
                const SizedBox(
                  height: 18,
                  child: VerticalDivider(width: 12, thickness: 1),
                ),
                _tool('适合全部卡片', Icons.fit_screen, _fitAll),
              ],
            ),
          ),
        ),
      ],
    ),
  );

  Future<void> _nodeMenu(MapNode node, Offset global) async {
    _clearMouseClicks();
    if (!_selectedIds.contains(node.id)) _select(node);
    final mapId = widget.snapshot.map.id;
    final projectId = widget.snapshot.map.projectId;
    bool valid() =>
        mounted &&
        _active &&
        widget.snapshot.map.id == mapId &&
        widget.snapshot.map.projectId == projectId &&
        widget.snapshot.nodes.any(
          (current) => current.id == node.id && current.cardId == node.cardId,
        );
    final action = await _showContextMenu(global, _nodeMenuItems(node), valid);
    if (action == null || !valid()) return;
    // 格式操作保留精确多选，普通右键命令仍作用于当前卡片。
    if (action != 'topicStyle') _select(node);
    if (const ['newChild', 'newSibling'].contains(action)) {
      _createRelative(node, action);
    } else if (action.startsWith('clipboard')) {
      widget.onClipboardAction?.call(switch (action) {
        'clipboardCopy' => 'copy',
        'clipboardCut' => 'cut',
        _ => 'paste',
      });
    } else if (action == 'collapse') {
      _toggleTopicCollapsed(node);
    } else {
      widget.onAction(node, action);
    }
  }

  List<OpenNoteMenuEntry<String>> _nodeMenuItems(MapNode node) {
    final hasChildren = (_children[node.id] ?? const []).isNotEmpty;
    return [
      _item(
        'newChild',
        Icons.subdirectory_arrow_right,
        '新建子主题 Tab',
        enabled: _creationAllowed,
      ),
      _item('newSibling', Icons.add, '新建同级主题 Enter', enabled: _creationAllowed),
      const OpenNoteMenuEntry.divider(),
      _item('edit', Icons.edit_outlined, '编辑卡片 F2'),
      if ((widget.snapshot.anchors[node.cardId] ?? const []).isNotEmpty)
        _item('source', Icons.menu_book_outlined, '回到原文'),
      _item(
        'clipboardMenu',
        Icons.content_copy,
        '复制与移动',
        children: [
          if (widget.onClipboardAction != null) ...[
            _item('clipboardCopy', Icons.content_copy, '复制 Ctrl+C'),
            _item('clipboardCut', Icons.content_cut, '剪切 Ctrl+X'),
            _item('clipboardPaste', Icons.content_paste, '粘贴为子主题 Ctrl+V'),
            const OpenNoteMenuEntry.divider(),
          ],
          _item('copyBranch', Icons.copy_outlined, '复制到其他脑图…'),
          _item('moveBranch', Icons.drive_file_move_outline, '移动到其他脑图…'),
        ],
      ),
      _item(
        'styleMenu',
        Icons.palette_outlined,
        '样式',
        children: [
          _item('topicStyle', Icons.format_shapes, '主题格式…'),
          _item('color', Icons.palette_outlined, '卡片颜色…'),
        ],
      ),
      if (hasChildren)
        _item(
          'collapseMenu',
          Icons.unfold_more,
          '折叠与展开',
          children: [
            _item(
              'collapse',
              node.collapsed ? Icons.unfold_more : Icons.unfold_less,
              node.collapsed ? '展开细分主题 Ctrl+/' : '折叠细分主题 Ctrl+/',
              enabled: hasChildren,
            ),
            _item(
              'collapseBranch',
              node.collapsed ? Icons.unfold_more : Icons.unfold_less,
              node.collapsed ? '展开所有次级分支 Ctrl+Alt+/' : '折叠所有次级分支 Ctrl+Alt+/',
              enabled: hasChildren,
            ),
          ],
        ),
      const OpenNoteMenuEntry.divider(),
      _item(
        'removeBranch',
        Icons.delete_outline,
        hasChildren ? '删除分支 Delete' : '删除卡片 Delete',
      ),
    ];
  }

  Widget _titleEditor() => Material(
    key: const ValueKey('map-title-editor'),
    color: Colors.white,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(8),
      side: const BorderSide(color: _blue, width: 1.5),
    ),
    elevation: 3,
    shadowColor: Colors.black.withValues(alpha: .12),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Focus(
            onKeyEvent: (_, event) {
              if (event is! KeyDownEvent || _titleSaving) {
                return KeyEventResult.ignored;
              }
              if (event.logicalKey == LogicalKeyboardKey.escape) {
                setState(_finishTitle);
                return KeyEventResult.handled;
              }
              final composing = _titleText.value.composing;
              if (composing.isValid && !composing.isCollapsed) {
                return KeyEventResult.ignored;
              }
              if (event.logicalKey == LogicalKeyboardKey.enter &&
                  !HardwareKeyboard.instance.isShiftPressed) {
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
              key: const ValueKey('map-title-input'),
              focusNode: _titleFocus,
              controller: _titleText,
              readOnly: _titleSaving,
              minLines: 1,
              maxLines: 4,
              style: const TextStyle(
                fontSize: 16,
                height: 1.5,
                fontWeight: FontWeight.w600,
              ),
              decoration: const InputDecoration(
                isDense: true,
                hintText: '主题标题',
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: EdgeInsets.zero,
              ),
              onTapOutside: (_) => unawaited(_commitTitle()),
            ),
          ),
          Row(
            children: [
              const Spacer(),
              IconButton(
                tooltip: '取消标题编辑',
                iconSize: 16,
                onPressed: _titleSaving ? null : () => setState(_finishTitle),
                icon: const OpenNoteIcon(Icons.close),
              ),
              IconButton(
                tooltip: '保存标题',
                iconSize: 18,
                color: _blue,
                onPressed: _titleSaving
                    ? null
                    : () => unawaited(_commitTitle()),
                icon: const OpenNoteIcon(Icons.check),
              ),
            ],
          ),
        ],
      ),
    ),
  );

  OpenNoteMenuEntry<String> _item(
    String action,
    IconData icon,
    String text, {
    bool enabled = true,
    List<OpenNoteMenuEntry<String>> children = const [],
  }) {
    final shortcut = RegExp(r'^(.*) (Ctrl\+[^ ]+|Tab|Enter|F2|Space|Delete)$')
        .firstMatch(text);
    return OpenNoteMenuEntry(
      action,
      shortcut?.group(1) ?? text,
      key: ValueKey('map-menu-$action'),
      icon: icon,
      shortcut: shortcut?.group(2),
      enabled: enabled,
      danger: const ['removeBranch', 'remove', 'delete'].contains(action),
      children: children,
    );
  }

  MapNode _relationshipNode(MapNode node) {
    final position = _position(node);
    return MapNode(
      id: node.id,
      mapId: node.mapId,
      cardId: node.cardId,
      x: position.dx,
      y: position.dy,
      width: node.width,
      height: node.height,
      parentNodeId: node.parentNodeId,
    );
  }

  MapEdge _displayEdge(MapEdge edge) {
    final displayed = _previewEdge?.id == edge.id ? _previewEdge! : edge;
    final source = displayed.style.colorSource;
    if (source == RelationshipColorSource.custom) return displayed;
    final nodeId = source == RelationshipColorSource.from
        ? displayed.fromNodeId
        : displayed.toNodeId;
    final color = widget.snapshot.cards[_nodes[nodeId]?.cardId]?.color;
    if (color == null) return displayed;
    return MapEdge(
      id: displayed.id,
      mapId: displayed.mapId,
      fromNodeId: displayed.fromNodeId,
      toNodeId: displayed.toNodeId,
      label: displayed.label,
      style: displayed.style.copyWith(color: color),
    );
  }

  MapEdge? get _chosenEdge =>
      widget.snapshot.edges.where((e) => e.id == _selectedEdge).firstOrNull;
  RelationshipGeometry _relationshipGeometry(MapEdge edge) =>
      relationshipGeometry(
        _relationshipNode(_nodes[edge.fromNodeId]!),
        _relationshipNode(_nodes[edge.toNodeId]!),
        edge.style,
      );

  RelationshipLabelDraft? get _relationshipDraft => _relationshipId == null
      ? null
      : RelationshipLabelDraft(
          widget.snapshot.map.id,
          _relationshipId!,
          _relationshipFrom!,
          _relationshipTo!,
          _relationshipText.text,
          _relationshipGeneration,
        );
  void _finishRelationshipLabel() {
    final focus = _relationshipFocus.hasFocus;
    _relationshipId = null;
    _relationshipFrom = null;
    _relationshipTo = null;
    _relationshipGeneration++;
    if (focus && mounted && _active) _focus.requestFocus();
  }

  void _acceptRelationshipLabel(RelationshipLabelDraft draft) {
    if (!mounted ||
        draft.mapId != widget.snapshot.map.id ||
        draft.edgeId != _relationshipId ||
        draft.fromNodeId != _relationshipFrom ||
        draft.toNodeId != _relationshipTo ||
        draft.generation != _relationshipGeneration ||
        draft.label != _relationshipText.text) {
      return;
    }
    setState(_finishRelationshipLabel);
  }

  Future<void> _beginRelationshipLabel(String id) async {
    if (widget.onCommitRelationshipLabel == null ||
        _busy ||
        _relationshipSaving ||
        !_active) {
      return;
    }
    final mapId = widget.snapshot.map.id;
    final original = widget.snapshot.edges.where((e) => e.id == id).firstOrNull;
    if (original == null) return;
    try {
      await widget.onPrepareRelationshipEdit?.call();
    } catch (_) {
      return;
    }
    final edge = widget.snapshot.edges.where((e) => e.id == id).firstOrNull;
    if (!mounted ||
        !_active ||
        widget.snapshot.map.id != mapId ||
        edge == null ||
        edge.fromNodeId != original.fromNodeId ||
        edge.toNodeId != original.toNodeId ||
        !_shownIds.contains(edge.fromNodeId) ||
        !_shownIds.contains(edge.toNodeId)) {
      return;
    }
    setState(() {
      _selectedId = null;
      _selectedIds = {};
      _selectedEdge = id;
      _associationFrom = null;
      _associationMode = false;
      _relationshipId = id;
      _relationshipFrom = edge.fromNodeId;
      _relationshipTo = edge.toNodeId;
      _relationshipGeneration++;
      _relationshipText.value = TextEditingValue(
        text: edge.label,
        selection: TextSelection(
          baseOffset: 0,
          extentOffset: edge.label.length,
        ),
      );
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _active && _relationshipId == id) {
        _relationshipFocus.requestFocus();
      }
    });
  }

  Future<void> _commitRelationshipLabel() async {
    if (_relationshipId == null || _relationshipSaving) return;
    setState(() => _relationshipSaving = true);
    try {
      await widget.onCommitRelationshipLabel?.call();
    } catch (_) {
      if (mounted && _active) _relationshipFocus.requestFocus();
    } finally {
      if (mounted) setState(() => _relationshipSaving = false);
    }
  }

  bool _validEdgeDrag() {
    final drag = _edgeDrag;
    if (drag == null) return false;
    final current = widget.snapshot.edges
        .where((e) => e.id == drag.edge.id)
        .firstOrNull;
    if (current == null ||
        current.fromNodeId != drag.edge.fromNodeId ||
        current.toNodeId != drag.edge.toNodeId ||
        current.style != drag.edge.style ||
        current.label != drag.edge.label) {
      return false;
    }
    for (final original in [drag.from, drag.to]) {
      final node = _nodes[original.id];
      if (node == null ||
          !_shownIds.contains(node.id) ||
          node.cardId != original.cardId ||
          node.x != original.x ||
          node.y != original.y ||
          node.width != original.width ||
          node.height != original.height) {
        return false;
      }
    }
    return true;
  }

  void _startEdgeDrag(MapEdge edge, String part, {Offset? globalPosition}) {
    if (_busy || !_active || _relationshipId != null || _dragging != null) {
      return;
    }
    final original = widget.snapshot.edges
        .where((e) => e.id == edge.id)
        .firstOrNull;
    if (original == null) return;
    _dragCursor.show(
      context,
      part == 'label' ? SystemMouseCursors.grabbing : SystemMouseCursors.move,
    );
    setState(() {
      _edgeDrag = (
        edge: original,
        part: part,
        from: _nodes[original.fromNodeId]!,
        to: _nodes[original.toNodeId]!,
      );
      _previewEdge = original;
      _edgeDropNode = null;
      _edgeLabelGrab = part == 'label' && globalPosition != null
          ? _worldFromGlobal(globalPosition) -
                relationOffset(_relationshipGeometry(original).label)
          : Offset.zero;
    });
  }

  void _cancelEdgeDrag() {
    if (_edgeDrag != null) _dragCursor.hide();
    _edgeDrag = null;
    _previewEdge = null;
    _edgeDropNode = null;
  }

  void _updateEdgeDrag(DragUpdateDetails details) {
    final drag = _edgeDrag;
    if (drag == null || !mounted || !_active) return;
    if (!_validEdgeDrag()) {
      setState(_cancelEdgeDrag);
      return;
    }
    final point = _worldFromGlobal(details.globalPosition);
    final edge = drag.edge;
    var style = edge.style;
    var from = edge.fromNodeId, to = edge.toNodeId;
    String? target;
    if (drag.part == 'controlFrom' || drag.part == 'controlTo') {
      final node = drag.part == 'controlFrom' ? drag.from : drag.to;
      final center = _rect(node).center;
      final offset = PdfPoint(point.dx - center.dx, point.dy - center.dy);
      style = drag.part == 'controlFrom'
          ? style.copyWith(controlFrom: offset)
          : style.copyWith(controlTo: offset);
    } else if (drag.part == 'label') {
      final middle = _relationshipGeometry(edge).point(.5);
      style = style.copyWith(
        labelOffset: PdfPoint(
          point.dx - middle.x - _edgeLabelGrab.dx,
          point.dy - middle.y - _edgeLabelGrab.dy,
        ),
      );
    } else {
      final opposite = drag.part == 'from' ? edge.toNodeId : edge.fromNodeId;
      for (final node in _nodes.values) {
        if (node.id != opposite &&
            _shownIds.contains(node.id) &&
            _rect(node).inflate(12).contains(point)) {
          target = node.id;
        }
      }
      if (target != null) {
        final anchor = relationshipAnchorAt(
          _relationshipNode(_nodes[target]!),
          PdfPoint(point.dx, point.dy),
        );
        if (drag.part == 'from') {
          from = target;
          style = style.copyWith(anchorFrom: anchor);
        } else {
          to = target;
          style = style.copyWith(anchorTo: anchor);
        }
      }
    }
    setState(() {
      _edgeDropNode = target;
      _previewEdge = MapEdge(
        id: edge.id,
        mapId: edge.mapId,
        fromNodeId: from,
        toNodeId: to,
        label: edge.label,
        style: style,
      );
    });
  }

  void _finishEdgeDrag() {
    _dragCursor.hide();
    final drag = _edgeDrag, preview = _previewEdge, target = _edgeDropNode;
    if (drag == null || preview == null) return;
    if (!_validEdgeDrag()) {
      setState(_cancelEdgeDrag);
      return;
    }
    setState(() {
      _edgeDrag = null;
      _edgeDropNode = null;
    });
    if (drag.part == 'from' || drag.part == 'to') {
      if (target == null) {
        setState(() => _previewEdge = null);
        return;
      }
      final endpoint = drag.part == 'from'
          ? drag.edge.fromNodeId
          : drag.edge.toNodeId;
      final anchor = drag.part == 'from'
          ? preview.style.anchorFrom!
          : preview.style.anchorTo!;
      _run(
        () =>
            widget.onReconnectAssociation!(drag.edge, endpoint, target, anchor),
      );
    } else {
      _run(() => widget.onChangeAssociationStyle!(drag.edge, preview.style));
    }
  }

  String? _hitAssociation(Offset point) {
    final threshold = 8 / _transform.value.getMaxScaleOnAxis();
    for (final original in widget.snapshot.edges.reversed) {
      final edge = _displayEdge(original);
      final from = _nodes[edge.fromNodeId];
      final to = _nodes[edge.toNodeId];
      if (from == null ||
          to == null ||
          !_shownIds.contains(from.id) ||
          !_shownIds.contains(to.id)) {
        continue;
      }
      if (_relationshipGeometry(edge).distanceTo(PdfPoint(point.dx, point.dy)) <
          threshold) {
        return edge.id;
      }
    }
    return null;
  }

  void _backgroundTap(Offset global) {
    _clearMouseClicks();
    if (_busy || !mounted || !_active) return;
    if (_associationMode) {
      _createRelatedAt(_worldFromGlobal(global));
      return;
    }
    final edge = _hitAssociation(_worldFromGlobal(global));
    final summary = edge == null
        ? _summaryVisuals.reversed
              .where(
                (v) => v.hit(
                  _worldFromGlobal(global),
                  8 / _transform.value.getMaxScaleOnAxis(),
                ),
              )
              .firstOrNull
        : null;
    if (summary != null && _nodes[summary.summary.summaryNodeId] != null) {
      _select(_nodes[summary.summary.summaryNodeId]!);
      return;
    }
    final boundary = edge == null
        ? _hitBoundary(_worldFromGlobal(global))
        : null;
    setState(() {
      _selectedIds = {};
      _selectedId = null;
      _selectedEdge = edge;
      _selectedBoundary = boundary;
      _associationFrom = null;
      _associationMode = false;
    });
    _focus.requestFocus();
    widget.onClearSelection?.call();
  }

  void _backgroundDoubleTapDown(TapDownDetails details) {
    _clearMouseClicks();
    final point = _worldFromGlobal(details.globalPosition);
    _doubleTapEdge = _hitAssociation(point);
    _doubleTapBoundary = _doubleTapEdge == null ? _hitBoundary(point) : null;
    _doubleTapWorld =
        _creationAllowed && _doubleTapEdge == null && _doubleTapBoundary == null
        ? point
        : null;
  }

  void _backgroundDoubleTap() {
    final boundary = _doubleTapBoundary;
    _doubleTapBoundary = null;
    if (boundary != null) {
      unawaited(_beginBoundaryLabel(boundary));
      return;
    }
    final point = _doubleTapWorld;
    final edge = _doubleTapEdge;
    _doubleTapEdge = null;
    _doubleTapWorld = null;
    if (edge != null) {
      unawaited(_beginRelationshipLabel(edge));
      return;
    }
    if (point != null && _creationAllowed) widget.onCreateAt?.call(point);
  }

  Future<void> _edgeMenu(Offset global) async {
    _clearMouseClicks();
    final id = _hitAssociation(_worldFromGlobal(global));
    if (id == null) {
      await _boundaryMenu(global);
      return;
    }
    setState(() => _selectedEdge = id);
    final mapId = widget.snapshot.map.id;
    bool valid() =>
        mounted &&
        _active &&
        widget.snapshot.map.id == mapId &&
        widget.snapshot.edges.any((edge) => edge.id == id);
    final action = await _showContextMenu(global, [
      if (widget.onCommitRelationshipLabel != null)
        _item('label', Icons.edit_outlined, '编辑关系说明'),
      if (widget.onEditAssociation != null)
        _item('style', Icons.tune, '关联线样式…'),
      if (widget.onChangeAssociationStyle != null)
        _item('reset', Icons.restart_alt, '重置关联线样式'),
      _item('remove', Icons.link_off, '删除关联'),
    ], valid);
    if (!valid()) return;
    if (action == 'remove' && mounted) widget.onRemoveAssociation(id);
    final edge = widget.snapshot.edges.where((e) => e.id == id).firstOrNull;
    if (!mounted || edge == null) return;
    if (action == 'label') unawaited(_beginRelationshipLabel(id));
    if (action == 'style') {
      _run(() => widget.onEditAssociation!(edge), showProgress: false);
    }
    if (action == 'reset') {
      _run(
        () => widget.onChangeAssociationStyle!(edge, const RelationshipStyle()),
      );
    }
  }

  bool _canReceiveText(ReaderExcerptDrag drag) =>
      mounted &&
      _active &&
      widget.canCreate &&
      !_busy &&
      _dragging == null &&
      _edgeDrag == null &&
      !_associationMode &&
      widget.onTextExcerptDrop != null &&
      drag.canAccept &&
      (widget.canAcceptTextDrag?.call(drag) ?? true);

  void _clearIncomingText() {
    _incomingText?.clearDropTarget(this);
    _incomingText?.removeListener(_incomingTextChanged);
    _incomingText = null;
    _incomingParent = null;
    _incomingPosition = null;
    _incomingGlobal = null;
    _incomingInvalid = false;
  }

  void _incomingTextChanged() {
    final drag = _incomingText;
    if (drag?.canAccept != true) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _active && identical(_incomingText, drag)) {
          setState(_clearIncomingText);
        }
      });
    }
  }

  void _previewTextDrop(DragTargetDetails<ReaderExcerptDrag> details) {
    if (!_canReceiveText(details.data)) {
      if (_incomingText != null) setState(_clearIncomingText);
      return;
    }
    final world = _worldFromGlobal(details.offset);
    MapNode? parent;
    for (final n in _nodes.values.toList().reversed) {
      if (_shownIds.contains(n.id) &&
          (_position(n) & Size(n.width, n.height)).contains(world)) {
        parent = n;
        break;
      }
    }
    setState(() {
      if (!identical(_incomingText, details.data)) {
        _clearIncomingText();
        _incomingText = details.data..addListener(_incomingTextChanged);
      }
      if (_incomingGlobal != null &&
          (details.offset - _incomingGlobal!).distance > 1) {
        _incomingInvalid = false;
      }
      _incomingGlobal = details.offset;
      _incomingPosition = world;
      _incomingParent = parent;
    });
    details.data.setDropTarget(this, accepted: !_incomingInvalid);
  }

  bool _cursorModifiersChanged(KeyEvent event) {
    _shiftPressed.value = HardwareKeyboard.instance.isShiftPressed;
    return false;
  }

  MouseCursor get _backgroundCursor => _busy || !_active
      ? SystemMouseCursors.basic
      : _associationMode || _canMarquee
      ? SystemMouseCursors.precise
      : SystemMouseCursors.grab;

  void _endCanvasPointer(PointerEvent event) {
    _primaryDown = false;
    if (_dragging == null &&
        _edgeDrag == null &&
        _summaryDrag == null &&
        _boundaryDrag == null) {
      _dragCursor.hide();
    }
  }

  Future<void> _acceptTextDrop(
    DragTargetDetails<ReaderExcerptDrag> details,
  ) async {
    final drag = details.data;
    if (!drag.canAccept) return;
    if (!_canReceiveText(drag) || _incomingInvalid) {
      drag.fail(const ReaderExcerptDragCancelled());
      if (mounted) setState(_clearIncomingText);
      return;
    }
    _previewTextDrop(details);
    final parent = _incomingParent;
    final position = _incomingPosition!;
    final callback = widget.onTextExcerptDrop!;
    if (!drag.claim()) return;
    setState(() {
      _clearIncomingText();
      _busy = true;
      _showLocalProgress = false;
    });
    try {
      await callback(drag, position, parent);
      drag.commit();
    } catch (error) {
      // 来源阅读区负责显示失败；取消不产生提示或新的写入。
      drag.fail(error);
    } finally {
      if (mounted && _active) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      _size = constraints.biggest;
      final scale = _transform.value.getMaxScaleOnAxis();
      final originalMediaQuery = MediaQuery.of(context);
      // 所有文字节点共享一次数据复制；空闲缩放不复制，图片始终使用原数据。
      final snapshotMediaQuery =
          _active &&
              _dragging != null &&
              !_snapshotDependenciesChangedInDrag &&
              scale <= 1
          ? originalMediaQuery.copyWith(
              devicePixelRatio:
                  View.of(context).devicePixelRatio * math.min(1, scale),
            )
          : originalMediaQuery;
      final topLeft = _transform.toScene(Offset.zero) - _origin;
      final bottomRight =
          _transform.toScene(Offset(_size.width, _size.height)) - _origin;
      final visible = Rect.fromPoints(
        topLeft,
        bottomRight,
      ).inflate(80 / _transform.value.getMaxScaleOnAxis());
      final rendered = _nodes.values
          .where((n) => _shownIds.contains(n.id) && _rect(n).overlaps(visible))
          .toList();
      _renderedCount = rendered.length;
      final dropTargetNode = _nodes[_dropTarget];
      return Focus(
        focusNode: _focus,
        onFocusChange: (hasFocus) {
          if (!hasFocus) _clearMouseClicks();
        },
        onKeyEvent: _key,
        child: MouseRegion(
          onHover: (event) {
            if (_associationFrom != null && mounted && _active) {
              setState(() => _cursor = _worldFromGlobal(event.position));
            }
          },
          child: ColoredBox(
            color: OpenNoteTokens.background,
            child: Stack(
              key: _viewport,
              children: [
                const Positioned.fill(
                  child: IgnorePointer(
                    child: RepaintBoundary(
                      child: ColoredBox(color: OpenNoteTokens.surface),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: DragTarget<ReaderExcerptDrag>(
                    onWillAcceptWithDetails: (details) {
                      if (!_canReceiveText(details.data)) return false;
                      _previewTextDrop(details);
                      return true;
                    },
                    onMove: _previewTextDrop,
                    onLeave: (data) {
                      if (identical(_incomingText, data)) {
                        setState(_clearIncomingText);
                      }
                    },
                    onAcceptWithDetails: (details) =>
                        unawaited(_acceptTextDrop(details)),
                    builder: (context, candidates, rejected) => Listener(
                      onPointerDown: (event) => _primaryDown =
                          event.kind == PointerDeviceKind.mouse &&
                          event.buttons == kPrimaryMouseButton,
                      onPointerUp: _endCanvasPointer,
                      onPointerCancel: _endCanvasPointer,
                      child: InteractiveViewer(
                        transformationController: _transform,
                        scaleFactor: 800,
                        onInteractionStart: (_) {
                          _clearMouseClicks();
                          if (_primaryDown &&
                              _dragging == null &&
                              _marquee == null) {
                            _dragCursor.show(
                              context,
                              SystemMouseCursors.grabbing,
                            );
                          }
                        },
                        onInteractionEnd: (_) {
                          if (_dragging == null) _dragCursor.hide();
                        },
                        minScale: .08,
                        maxScale: 2.5,
                        constrained: false,
                        boundaryMargin: const EdgeInsets.all(4000),
                        trackpadScrollCausesScale: true,
                        child: RepaintBoundary(
                          child: SizedBox(
                            width: _canvasSize.width,
                            height: _canvasSize.height,
                            child: Stack(
                              children: [
                                Positioned.fill(
                                  child: Listener(
                                    onPointerDown: (_) {
                                      _clearMouseClicks();
                                      _marqueeAdditive =
                                          HardwareKeyboard
                                              .instance
                                              .isControlPressed ||
                                          HardwareKeyboard
                                              .instance
                                              .isShiftPressed;
                                    },
                                    onPointerCancel: (_) {
                                      // 已接受的 Pan 在取消指针时也可能发 onEnd，先撤掉预览防止误提交。
                                      if (_marquee != null) {
                                        setState(_cancelMarquee);
                                      }
                                    },
                                    child: RawGestureDetector(
                                      gestures: {
                                        _MapMarqueeRecognizer:
                                            GestureRecognizerFactoryWithHandlers<
                                              _MapMarqueeRecognizer
                                            >(() => _MapMarqueeRecognizer(), (
                                              recognizer,
                                            ) {
                                              recognizer.canStart = () =>
                                                  _canMarquee;
                                              recognizer.dragStartBehavior =
                                                  DragStartBehavior.down;
                                              recognizer.onStart = (details) {
                                                _marqueeStart =
                                                    _worldFromGlobal(
                                                      details.globalPosition,
                                                    );
                                                _beginMarquee(details);
                                              };
                                              recognizer.onUpdate =
                                                  _updateMarquee;
                                              recognizer.onEnd = _finishMarquee;
                                              recognizer.onCancel = () {
                                                if (mounted &&
                                                    _marquee != null) {
                                                  setState(_cancelMarquee);
                                                }
                                              };
                                            }),
                                      },
                                      child: ValueListenableBuilder<bool>(
                                        valueListenable: _shiftPressed,
                                        builder: (_, _, child) => MouseRegion(
                                          cursor: _backgroundCursor,
                                          child: child,
                                        ),
                                        child: GestureDetector(
                                          key: const ValueKey('map-background'),
                                          behavior: HitTestBehavior.opaque,
                                          onTapUp: (details) => _backgroundTap(
                                            details.globalPosition,
                                          ),
                                          onSecondaryTapDown: (details) =>
                                              _edgeMenu(details.globalPosition),
                                          onDoubleTapDown:
                                              _associationMode ||
                                                  widget.onCreateAt == null &&
                                                      widget.onCommitRelationshipLabel ==
                                                          null &&
                                                      widget.onCommitBoundaryLabel ==
                                                          null
                                              ? null
                                              : _backgroundDoubleTapDown,
                                          onDoubleTap:
                                              _associationMode ||
                                                  widget.onCreateAt == null &&
                                                      widget.onCommitRelationshipLabel ==
                                                          null &&
                                                      widget.onCommitBoundaryLabel ==
                                                          null
                                              ? null
                                              : _backgroundDoubleTap,
                                          onDoubleTapCancel:
                                              _associationMode ||
                                                  widget.onCreateAt == null &&
                                                      widget.onCommitRelationshipLabel ==
                                                          null &&
                                                      widget.onCommitBoundaryLabel ==
                                                          null
                                              ? null
                                              : () => _doubleTapWorld = null,
                                          child: CustomPaint(
                                            painter: BoundaryCanvasPainter(
                                              _boundaryVisuals,
                                              _origin,
                                              _selectedBoundary,
                                              visible,
                                            ),
                                            foregroundPainter: _MapPainter(
                                              layout:
                                                  widget.snapshot.map.layout,
                                              nodes: _nodes,
                                              children: _children,
                                              shownIds: _shownIds,
                                              origin: _origin,
                                              position: _position,
                                              edges: [
                                                for (final edge
                                                    in widget.snapshot.edges)
                                                  _displayEdge(edge),
                                              ],
                                              selectedEdge: _selectedEdge,
                                              visible: visible,
                                              associationFrom: _associationFrom,
                                              cursor: _cursor,
                                              summaries: _summaryVisuals,
                                              topicStyles: _topicStyles,
                                              branchLayouts: _branchLayouts,
                                              cards: widget.snapshot.cards,
                                              selectedNode: _selectedId,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                for (final node in rendered)
                                  Positioned(
                                    key: ValueKey('map-position-${node.id}'),
                                    left: _position(node).dx + _origin.dx,
                                    top: _position(node).dy + _origin.dy,
                                    width: node.width,
                                    height: node.height,
                                    // 常驻代理保留节点顺序、命中与手势；选中时不插拔节点边界。
                                    child: _nodeSnapshot(
                                      node,
                                      originalMediaQuery,
                                      snapshotMediaQuery,
                                      scale,
                                    ),
                                  ),
                                for (final node in rendered)
                                  if ((_descendantCounts[node.id] ?? 0) > 0 &&
                                      (node.collapsed ||
                                          _selectedIds.contains(node.id)))
                                    _collapseControl(node),
                                ..._relationshipLabels(visible),
                                ..._boundaryLabels(visible),
                                if (dropTargetNode != null)
                                  Positioned(
                                    left:
                                        _rect(dropTargetNode).left + _origin.dx,
                                    top:
                                        _rect(dropTargetNode).top +
                                        _origin.dy -
                                        26,
                                    child: IgnorePointer(
                                      child: Container(
                                        key: const ValueKey('map-drop-target'),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 9,
                                          vertical: 4,
                                        ),
                                        decoration: BoxDecoration(
                                          color: _green,
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
                                        ),
                                        child: Text(
                                          widget.onDropTopic == null
                                              ? '成为子卡片'
                                              : _dropIntent?.label ?? '加入子主题',
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                if (dropTargetNode != null &&
                                    _dropIntent?.placement !=
                                        TopicDropPlacement.child)
                                  _dropInsertionMarker(dropTargetNode),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (_incomingText?.canAccept == true &&
                    !_incomingInvalid &&
                    _incomingPosition != null)
                  Positioned(
                    left: (_screenFromWorld(_incomingPosition!).dx + 12).clamp(
                      8.0,
                      math.max(8, _size.width - 160),
                    ),
                    top: (_screenFromWorld(_incomingPosition!).dy - 32).clamp(
                      8.0,
                      math.max(8, _size.height - 40),
                    ),
                    child: IgnorePointer(
                      child: Material(
                        key: const Key('map-text-drop-preview'),
                        color: _green,
                        borderRadius: BorderRadius.circular(6),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          child: Text(
                            _incomingParent == null ? '创建顶层卡片' : '加入子主题',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                Positioned(right: 12, bottom: 12, child: _canvasTools()),
                ..._relationshipOverlays(),
                ..._boundaryOverlays(),
                ..._summaryOverlays(),
                if (_marquee != null)
                  Positioned.fromRect(
                    rect: Rect.fromPoints(
                      _screenFromWorld(_marquee!.topLeft),
                      _screenFromWorld(_marquee!.bottomRight),
                    ),
                    child: IgnorePointer(
                      child: Container(
                        key: const ValueKey('map-selection-box'),
                        decoration: BoxDecoration(
                          color: _blue.withValues(alpha: .08),
                          border: Border.all(color: _blue),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ),
                if (_titleNodeId != null && _nodes[_titleNodeId] != null)
                  Positioned(
                    left: _screenFromWorld(_rect(_nodes[_titleNodeId]!).topLeft)
                        .dx
                        .clamp(8.0, math.max(8, _size.width - 300))
                        .toDouble(),
                    top: _screenFromWorld(_rect(_nodes[_titleNodeId]!).topLeft)
                        .dy
                        .clamp(8.0, math.max(8, _size.height - 160))
                        .toDouble(),
                    width: math.min(292, math.max(140, _size.width - 16)),
                    child: _titleEditor(),
                  ),
                if (_nodes.isEmpty)
                  const IgnorePointer(
                    child: Center(
                      child: Text(
                        '暂无卡片',
                        style: TextStyle(
                          color: OpenNoteTokens.secondary,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ),
                if (_busy && _showLocalProgress)
                  const Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: LinearProgressIndicator(minHeight: 2),
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );

  List<Widget> _relationshipLabels(Rect visible) => [
    for (final original in widget.snapshot.edges)
      if (original.label.isNotEmpty &&
          original.id != _relationshipId &&
          _shownIds.contains(original.fromNodeId) &&
          _shownIds.contains(original.toNodeId))
        _relationshipLabel(_displayEdge(original), visible),
  ];
  Widget _relationshipLabel(MapEdge edge, Rect visible) {
    final location = relationOffset(_relationshipGeometry(edge).label);
    if (!visible.inflate(120).contains(location)) {
      return const SizedBox.shrink();
    }
    final selected = _selectedEdge == edge.id;
    return Positioned(
      left: location.dx + _origin.dx - 110,
      top: location.dy + _origin.dy - 14,
      width: 220,
      child: Center(
        child: MouseRegion(
          cursor: _busy
              ? SystemMouseCursors.basic
              : selected && widget.onChangeAssociationStyle != null
              ? SystemMouseCursors.grab
              : SystemMouseCursors.click,
          child: GestureDetector(
            key: ValueKey('relationship-label-${edge.id}'),
            dragStartBehavior: DragStartBehavior.down,
            onTap: () => _chooseEdge(edge.id),
            onDoubleTap: widget.onCommitRelationshipLabel == null
                ? null
                : () => unawaited(_beginRelationshipLabel(edge.id)),
            onSecondaryTapDown: (_) => _run(
              () => widget.onEditAssociation?.call(edge) ?? Future.value(),
              showProgress: false,
            ),
            onPanStart: selected && widget.onChangeAssociationStyle != null
                ? (details) => _startEdgeDrag(
                    edge,
                    'label',
                    globalPosition: details.globalPosition,
                  )
                : null,
            onPanUpdate: selected && widget.onChangeAssociationStyle != null
                ? _updateEdgeDrag
                : null,
            onPanEnd: selected && widget.onChangeAssociationStyle != null
                ? (_) => _finishEdgeDrag()
                : null,
            onPanCancel: selected ? () => setState(_cancelEdgeDrag) : null,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: .96),
                borderRadius: BorderRadius.circular(5),
                border: selected
                    ? Border.all(color: _blue.withValues(alpha: .5))
                    : null,
              ),
              child: Text(
                edge.label,
                style: relationshipLabelStyle(edge.style),
                maxLines: 5,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _chooseEdge(String? id) {
    setState(() {
      _selectedIds = {};
      _selectedId = null;
      _selectedEdge = id;
      _associationFrom = null;
      _associationMode = false;
    });
    _focus.requestFocus();
    widget.onClearSelection?.call();
  }

  List<Widget> _relationshipOverlays() {
    final original = _chosenEdge;
    if (original == null ||
        !_shownIds.contains(original.fromNodeId) ||
        !_shownIds.contains(original.toNodeId)) {
      return const [];
    }
    final edge = _displayEdge(original), geometry = _relationshipGeometry(edge);
    final location = _screenFromWorld(relationOffset(geometry.label));
    final result = <Widget>[];
    if (_relationshipId == edge.id) {
      final width = math.min(320.0, math.max(160.0, _size.width - 24));
      result.add(
        Positioned(
          left: (location.dx - width / 2).clamp(
            8.0,
            math.max(8.0, _size.width - width - 8),
          ),
          top: (location.dy - 22).clamp(8.0, math.max(8.0, _size.height - 180)),
          width: width,
          child: Material(
            color: Colors.white,
            elevation: 2,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Focus(
                onKeyEvent: (_, event) {
                  if (event is! KeyDownEvent) return KeyEventResult.ignored;
                  if (event.logicalKey == LogicalKeyboardKey.escape &&
                      !_relationshipSaving) {
                    setState(_finishRelationshipLabel);
                    return KeyEventResult.handled;
                  }
                  if (event.logicalKey == LogicalKeyboardKey.enter &&
                      !HardwareKeyboard.instance.isShiftPressed) {
                    final composing = _relationshipText.value.composing;
                    if (composing.isValid && !composing.isCollapsed) {
                      return KeyEventResult.ignored;
                    }
                    unawaited(_commitRelationshipLabel());
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      key: const Key('relationship-label-editor'),
                      controller: _relationshipText,
                      focusNode: _relationshipFocus,
                      readOnly: _relationshipSaving,
                      maxLength: 1000,
                      maxLines: 4,
                      minLines: 1,
                      style: relationshipLabelStyle(edge.style),
                      decoration: const InputDecoration(
                        hintText: '关系说明',
                        isDense: true,
                      ),
                      onTapOutside: (_) =>
                          unawaited(_commitRelationshipLabel()),
                    ),
                    Row(
                      children: [
                        const Spacer(),
                        IconButton(
                          tooltip: '保存关系说明',
                          onPressed: _relationshipSaving
                              ? null
                              : () => unawaited(_commitRelationshipLabel()),
                          icon: const OpenNoteIcon(Icons.check, size: 18),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      return result;
    }
    if (widget.onEditAssociation != null ||
        widget.onCommitRelationshipLabel != null) {
      result.add(
        Positioned(
          left: (location.dx - 72).clamp(8.0, math.max(8.0, _size.width - 152)),
          top: (location.dy - 54).clamp(8.0, math.max(8.0, _size.height - 40)),
          child: Container(
            key: const Key('relationship-actions'),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: OpenNoteTokens.border),
              borderRadius: BorderRadius.circular(8),
              boxShadow: OpenNoteTokens.floatingShadows,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.onCommitRelationshipLabel != null)
                  _tool(
                    '编辑关系说明',
                    Icons.edit_outlined,
                    () => unawaited(_beginRelationshipLabel(edge.id)),
                  ),
                if (widget.onEditAssociation != null)
                  _tool(
                    '关联线样式',
                    Icons.tune,
                    () => _run(
                      () => widget.onEditAssociation!(original),
                      showProgress: false,
                    ),
                  ),
                _tool(
                  '删除关联',
                  Icons.link_off,
                  () => widget.onRemoveAssociation(edge.id),
                ),
              ],
            ),
          ),
        ),
      );
    }
    void handle(String part, PdfPoint point, {bool control = false}) {
      final screen = _screenFromWorld(relationOffset(point));
      result.add(
        Positioned(
          left: screen.dx - 14,
          top: screen.dy - 14,
          width: 28,
          height: 28,
          child: Listener(
            onPointerCancel: (_) => setState(_cancelEdgeDrag),
            child: MouseRegion(
              cursor: _busy
                  ? SystemMouseCursors.basic
                  : SystemMouseCursors.move,
              child: GestureDetector(
                key: ValueKey('relationship-handle-${edge.id}-$part'),
                dragStartBehavior: DragStartBehavior.down,
                behavior: HitTestBehavior.opaque,
                onPanStart: (_) => _startEdgeDrag(original, part),
                onPanUpdate: _updateEdgeDrag,
                onPanEnd: (_) => _finishEdgeDrag(),
                onPanCancel: () => setState(_cancelEdgeDrag),
                child: Center(
                  child: Container(
                    width: control ? 10 : 14,
                    height: control ? 10 : 14,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      border: Border.all(
                        color: _edgeDropNode != null ? _green : _blue,
                        width: 2,
                      ),
                      shape: control ? BoxShape.rectangle : BoxShape.circle,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    if (widget.onChangeAssociationStyle != null &&
        edge.style.shape == RelationshipShape.curve) {
      result.add(
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: RelationshipGuidePainter([
                (
                  _screenFromWorld(relationOffset(geometry.start)),
                  _screenFromWorld(relationOffset(geometry.controlFrom)),
                ),
                (
                  _screenFromWorld(relationOffset(geometry.end)),
                  _screenFromWorld(relationOffset(geometry.controlTo)),
                ),
              ]),
            ),
          ),
        ),
      );
      handle('controlFrom', geometry.controlFrom, control: true);
      handle('controlTo', geometry.controlTo, control: true);
    }
    if (widget.onReconnectAssociation != null) {
      handle('from', geometry.start);
      handle('to', geometry.end);
    }
    return result;
  }

  Widget _tool(
    String label,
    IconData icon,
    VoidCallback? callback, {
    bool selected = false,
  }) => SizedBox(
    width: 36,
    height: 36,
    child: IconButton(
      tooltip: label,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      onPressed: _busy || callback == null
          ? null
          : () {
              _clearMouseClicks();
              callback();
            },
      iconSize: 18,
      color: selected ? _blue : OpenNoteTokens.secondary,
      icon: OpenNoteIcon(icon),
    ),
  );
}

/// 将外侧徽标与节点边缘连接；徽标表面覆盖线条中部。
class _CollapseConnectorPainter extends CustomPainter {
  const _CollapseConnectorPainter(this.color, this.direction, this.distance);
  final Color color;
  final MapLayoutKind direction;
  final double distance;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final towardNode = switch (direction) {
      MapLayoutKind.left => Offset(distance, 0),
      MapLayoutKind.up => Offset(0, distance),
      MapLayoutKind.down => Offset(0, -distance),
      _ => Offset(-distance, 0),
    };
    canvas.drawLine(center + towardNode, center, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _CollapseConnectorPainter oldDelegate) =>
      color != oldDelegate.color ||
      direction != oldDelegate.direction ||
      distance != oldDelegate.distance;
}

class _NodeTile extends StatelessWidget {
  const _NodeTile({
    super.key,
    required this.node,
    required this.card,
    required this.selected,
    required this.primary,
    required this.showDetails,
    required this.dropTarget,
    required this.cursor,
    required this.onTap,
    required this.onTapCancel,
    required this.onPointerDown,
    required this.onPointerUp,
    required this.onMenu,
    required this.onPanStart,
    required this.onPanUpdate,
    required this.onPanEnd,
    required this.onPanCancel,
    this.imagePathResolver,
    this.topicStyle,
  });
  final MapNode node;
  final BoundaryStyle? topicStyle;
  final NoteCard card;
  final bool selected;
  final bool primary;
  final bool showDetails;
  final bool dropTarget;
  final MouseCursor cursor;
  final VoidCallback onTap;
  final VoidCallback onTapCancel;
  final void Function(PointerDownEvent) onPointerDown;
  final void Function(PointerUpEvent) onPointerUp;
  final void Function(Offset) onMenu;
  final void Function(DragStartDetails)? onPanStart;
  final void Function(DragUpdateDetails)? onPanUpdate;
  final void Function(DragEndDetails)? onPanEnd;
  final VoidCallback? onPanCancel;
  final Future<String> Function(String resourceId)? imagePathResolver;

  @override
  Widget build(BuildContext context) {
    final parsed = int.tryParse(card.color.replaceFirst('#', ''), radix: 16);
    final accent = Color(0xFF000000 | (parsed ?? 0xF7D976));
    final border = dropTarget
        ? const Color(0xFF27945D)
        : selected
        ? OpenNoteTokens.accent
        : topicStyle == null
        ? OpenNoteTokens.border
        : Color(
            int.parse(topicStyle!.color.substring(1), radix: 16) | 0xFF000000,
          );
    return Semantics(
      label: '脑图卡片 ${card.title}',
      selected: selected,
      value: primary
          ? '主选'
          : selected
          ? '已选'
          : null,
      onTap: onTap,
      child: Listener(
        onPointerDown: onPointerDown,
        onPointerUp: onPointerUp,
        onPointerCancel: (_) {
          // 已接受的 pan 在 PointerCancel 后也会触发 onPanEnd，先取消临时拖动。
          onPanCancel?.call();
          onTapCancel();
        },
        child: MouseRegion(
          cursor: cursor,
          child: GestureDetector(
            dragStartBehavior: DragStartBehavior.down,
            behavior: HitTestBehavior.opaque,
            // 节点消费完整单击，避免抬起鼠标后祖先空白画布清空选中。
            onTap: onTap,
            onTapCancel: onTapCancel,
            onSecondaryTapDown: (details) => onMenu(details.globalPosition),
            onPanStart: onPanStart,
            onPanUpdate: onPanUpdate,
            onPanEnd: onPanEnd,
            onPanCancel: onPanCancel,
            child: DecoratedBox(
              key: ValueKey('map-node-border-${node.id}'),
              decoration: BoxDecoration(
                color: topicStyle == null
                    ? Colors.white
                    : Color(
                        int.parse(topicStyle!.fill.substring(1), radix: 16) |
                            0xFF000000,
                      ).withValues(alpha: topicStyle!.fillOpacity),
                border: Border.all(
                  color: topicStyle?.dashed == true && !selected && !dropTarget
                      ? Colors.transparent
                      : border,
                  width: primary || dropTarget
                      ? 2
                      : selected
                      ? 1.25
                      : topicStyle?.width ?? 1,
                ),
                borderRadius: BorderRadius.circular(
                  topicStyle?.shape == BoundaryShape.rectangle
                      ? 0
                      : topicStyle?.shape == BoundaryShape.ellipse
                      ? 58
                      : 8,
                ),
              ),
              child: CustomPaint(
                foregroundPainter:
                    topicStyle?.dashed == true && !selected && !dropTarget
                    ? TopicBorderPainter(topicStyle!)
                    : null,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(
                    topicStyle?.shape == BoundaryShape.rectangle
                        ? 0
                        : topicStyle?.shape == BoundaryShape.ellipse
                        ? node.height / 2
                        : 8,
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 3,
                        decoration: BoxDecoration(
                          color: accent,
                          borderRadius: const BorderRadius.only(
                            topLeft: Radius.circular(4),
                            bottomLeft: Radius.circular(4),
                          ),
                        ),
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 10, 10, 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      card.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: topicStyle?.textSize ?? 15,
                                        fontWeight:
                                            topicStyle == null ||
                                                topicStyle!.bold
                                            ? FontWeight.w600
                                            : FontWeight.w400,
                                        fontStyle: topicStyle?.italic == true
                                            ? FontStyle.italic
                                            : FontStyle.normal,
                                        fontFamily: topicStyle?.fontFamily,
                                        color: topicStyle == null
                                            ? OpenNoteTokens.text
                                            : Color(
                                                int.parse(
                                                      topicStyle!.textColor
                                                          .substring(1),
                                                      radix: 16,
                                                    ) |
                                                    0xFF000000,
                                              ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 5),
                              Expanded(
                                child: !showDetails
                                    ? const SizedBox.shrink()
                                    : card.imageResourceId != null
                                    ? _CardThumbnail(
                                        key: ValueKey(card.imageResourceId),
                                        resourceId: card.imageResourceId!,
                                        resolver: imagePathResolver,
                                      )
                                    : LayoutBuilder(
                                        builder: (context, constraints) => Text(
                                          card.body.isEmpty
                                              ? card.excerptSnapshot
                                              : card.body,
                                          maxLines:
                                              (constraints.maxHeight /
                                                      (MediaQuery.textScalerOf(
                                                            context,
                                                          ).scale(14) *
                                                          1.4))
                                                  .floor()
                                                  .clamp(1, 3),
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 14,
                                            height: 1.4,
                                            color: OpenNoteTokens.secondary,
                                          ),
                                        ),
                                      ),
                              ),
                              Row(
                                children: [
                                  if (card.imageResourceId != null &&
                                      !showDetails)
                                    const Padding(
                                      padding: EdgeInsets.only(left: 5),
                                      child: OpenNoteIcon(
                                        Icons.image_outlined,
                                        semanticLabel: '包含图片',
                                        size: 12,
                                        color: OpenNoteTokens.secondary,
                                      ),
                                    ),
                                  if (card.note.isNotEmpty && !showDetails)
                                    const Padding(
                                      padding: EdgeInsets.only(left: 5),
                                      child: OpenNoteIcon(
                                        Icons.comment_outlined,
                                        semanticLabel: '包含备注',
                                        size: 12,
                                        color: OpenNoteTokens.secondary,
                                      ),
                                    ),
                                  if (card.note.isNotEmpty && showDetails)
                                    Expanded(
                                      child: Text(
                                        card.note,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 10,
                                          color: OpenNoteTokens.secondary,
                                        ),
                                      ),
                                    )
                                  else
                                    const Spacer(),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CardThumbnail extends StatefulWidget {
  const _CardThumbnail({super.key, required this.resourceId, this.resolver});
  final String resourceId;
  final Future<String> Function(String resourceId)? resolver;
  @override
  State<_CardThumbnail> createState() => _CardThumbnailState();
}

class _CardThumbnailState extends State<_CardThumbnail> {
  Future<String>? _path;
  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant _CardThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.resourceId != widget.resourceId ||
        oldWidget.resolver != widget.resolver) {
      _resolve();
    }
  }

  void _resolve() {
    final resolver = widget.resolver;
    _path = resolver == null
        ? null
        : Future.sync(() => resolver(widget.resourceId));
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<String>(
    future: _path,
    builder: (context, snapshot) {
      if (snapshot.hasData) {
        return Align(
          alignment: Alignment.centerLeft,
          child: Image.file(
            File(snapshot.data!),
            key: ValueKey('map-image-${widget.resourceId}'),
            cacheWidth: 320,
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) =>
                const Text('图片无法读取', style: TextStyle(fontSize: 10)),
          ),
        );
      }
      return Align(
        alignment: Alignment.centerLeft,
        child: Text(
          snapshot.hasError || _path == null ? '图片无法读取' : '载入图片…',
          style: const TextStyle(fontSize: 10, color: OpenNoteTokens.secondary),
        ),
      );
    },
  );
}

class _TopicInsertionPainter extends CustomPainter {
  const _TopicInsertionPainter(this.vertical);
  final bool vertical;
  @override
  void paint(Canvas canvas, Size size) {
    final start = vertical
        ? Offset(size.width / 2, 3)
        : Offset(3, size.height / 2);
    final end = vertical
        ? Offset(size.width / 2, size.height - 3)
        : Offset(size.width - 3, size.height / 2);
    final paint = Paint()
      ..color = OpenNoteTokens.accent
      ..strokeWidth = 2;
    canvas.drawLine(start, end, paint);
    canvas.drawCircle(start, 3, paint);
    canvas.drawCircle(end, 3, paint);
  }

  @override
  bool shouldRepaint(_TopicInsertionPainter old) => old.vertical != vertical;
}

class _MapPainter extends CustomPainter {
  _MapPainter({
    required this.layout,
    required this.nodes,
    required this.children,
    required this.shownIds,
    required this.origin,
    required this.position,
    required this.edges,
    required this.selectedEdge,
    required this.visible,
    required this.associationFrom,
    required this.cursor,
    required this.summaries,
    required this.topicStyles,
    required this.branchLayouts,
    required this.cards,
    required this.selectedNode,
  });
  final MapLayoutKind layout;
  final Map<String, MapNode> nodes;
  final Map<String, List<String>> children;
  final Set<String> shownIds;
  final Offset origin;
  final Offset Function(MapNode) position;
  final List<MapEdge> edges;
  final String? selectedEdge;
  final Rect visible;
  final String? associationFrom;
  final Offset? cursor;
  final List<SummaryVisual> summaries;
  final Map<String, TopicStyle> topicStyles;
  final Map<String, MapLayoutKind> branchLayouts;
  final Map<String, NoteCard> cards;
  final String? selectedNode;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(visible.shift(origin));
    for (final visual in summaries) {
      if (visual.bounds.overlaps(visible)) {
        paintSummary(
          canvas,
          visual,
          origin,
          visual.summary.summaryNodeId == selectedNode,
        );
      }
    }
    final summaryTopics = summaries.map((s) => s.summary.summaryNodeId).toSet();
    final hierarchyPaths = <BranchStyle, Path>{};
    final spines = <String, StructureSpineGeometry>{};
    PdfPoint point(MapNode n) {
      final p = position(n) + origin;
      return PdfPoint(p.dx, p.dy);
    }

    for (final parent in nodes.values) {
      final kind = branchLayouts[parent.id] ?? layout;
      if (!shownIds.contains(parent.id) || !kind.spine && !kind.brace) continue;
      final geometry = structureSpineGeometry(
        parent,
        [
          for (final id in children[parent.id] ?? const <String>[])
            if (shownIds.contains(id) && !summaryTopics.contains(id))
              (nodes[id]!, point(nodes[id]!)),
        ],
        kind,
        point(parent),
      );
      if (geometry == null) continue;
      spines[parent.id] = geometry;
      var style = topicStyles[parent.id]!.branch;
      if (style.followCardColor) {
        style = style.copyWith(color: cards[parent.cardId]!.color);
      }
      style = style.copyWith(start: BranchEnd.none, end: BranchEnd.none);
      (hierarchyPaths[style] ??= Path()).addPath(
        structureSpinePath(geometry),
        Offset.zero,
      );
    }
    for (final node in nodes.values) {
      if (summaryTopics.contains(node.id)) continue;
      final parent = nodes[node.parentNodeId];
      if (parent == null ||
          !shownIds.contains(parent.id) ||
          !shownIds.contains(node.id)) {
        continue;
      }
      final parentPosition = position(parent) + origin;
      final nodePosition = position(node) + origin;
      final incoming = incomingBranchLayout(node, layout, branchLayouts);
      final direction = incoming.primaryDirection;
      final special = structureLinkGeometry(
        parent,
        node,
        incoming,
        point(parent),
        point(node),
        spine: spines[parent.id],
      );
      final reverse =
          direction == MapLayoutKind.left ||
          direction == MapLayoutKind.up ||
          (direction == MapLayoutKind.mindMap &&
              nodePosition.dx < parentPosition.dx);
      final start =
          parentPosition +
          (direction.vertical
              ? Offset(parent.width / 2, reverse ? 0 : parent.height)
              : Offset(reverse ? 0 : parent.width, parent.height / 2));
      final end =
          nodePosition +
          (direction.vertical
              ? Offset(node.width / 2, reverse ? node.height : 0)
              : Offset(reverse ? node.width : 0, node.height / 2));
      final bounds = special == null
          ? Rect.fromPoints(start, end)
          : special
                .skip(1)
                .fold(
                  Rect.fromPoints(
                    Offset(special.first.x, special.first.y),
                    Offset(special.first.x, special.first.y),
                  ),
                  (bounds, p) => bounds.expandToInclude(
                    Rect.fromPoints(Offset(p.x, p.y), Offset(p.x, p.y)),
                  ),
                );
      if (!bounds.inflate(16).overlaps(visible.shift(origin))) {
        continue;
      }
      var style = topicStyles[node.id]!.branch;
      if (style.followCardColor) {
        style = style.copyWith(color: cards[node.cardId]!.color);
      }
      final path = special == null
          ? branchPath(start, end, style.path, direction.vertical)
          : structureLinePath(special);
      (hierarchyPaths[style] ??= Path()).addPath(path, Offset.zero);
    }
    for (final entry in hierarchyPaths.entries) {
      paintBranch(canvas, entry.value, entry.key);
    }
    // 同样笔触的线段合并提交，避免总览中每条虚线产生数千次独立绘制。
    final associations = Path();
    final selectedAssociation = Path();
    for (final edge in edges) {
      final from = nodes[edge.fromNodeId];
      final to = nodes[edge.toNodeId];
      if (from == null ||
          to == null ||
          !shownIds.contains(from.id) ||
          !shownIds.contains(to.id)) {
        continue;
      }
      if (edge.style != const RelationshipStyle()) {
        MapNode placed(MapNode node) {
          final point = position(node);
          return MapNode(
            id: node.id,
            mapId: node.mapId,
            cardId: node.cardId,
            x: point.dx,
            y: point.dy,
            width: node.width,
            height: node.height,
          );
        }

        paintRelationship(
          canvas,
          relationshipGeometry(placed(from), placed(to), edge.style),
          edge.style,
          origin: origin,
          selected: edge.id == selectedEdge,
          clip: visible.shift(origin),
        );
        continue;
      }
      final start =
          position(from) + origin + Offset(from.width / 2, from.height / 2);
      final end = position(to) + origin + Offset(to.width / 2, to.height / 2);
      _appendDashedLine(
        edge.id == selectedEdge ? selectedAssociation : associations,
        start,
        end,
        clip: visible.shift(origin),
      );
    }
    canvas.drawPath(
      associations,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = const Color(0xFFC58035)
        ..strokeWidth = 1.4,
    );
    canvas.drawPath(
      selectedAssociation,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = OpenNoteTokens.accent
        ..strokeWidth = 2.2,
    );
    if (associationFrom != null &&
        cursor != null &&
        nodes.containsKey(associationFrom)) {
      final from = nodes[associationFrom]!;
      final start =
          position(from) + origin + Offset(from.width / 2, from.height / 2);
      final preview = Path();
      _appendDashedLine(
        preview,
        start,
        cursor! + origin,
        clip: visible.shift(origin),
      );
      canvas.drawPath(
        preview,
        Paint()
          ..style = PaintingStyle.stroke
          ..color = const Color(0xFFC58035)
          ..strokeWidth = 1.7,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _MapPainter oldDelegate) => true;
}

void _appendDashedLine(Path path, Offset from, Offset to, {Rect? clip}) {
  final delta = to - from;
  final distance = delta.distance;
  if (distance < .01) return;
  final unit = delta / distance;
  var low = 0.0;
  var high = 1.0;
  if (clip != null) {
    for (final axis in [
      (from.dx, delta.dx, clip.left, clip.right),
      (from.dy, delta.dy, clip.top, clip.bottom),
    ]) {
      if (axis.$2.abs() < .0001) {
        if (axis.$1 < axis.$3 || axis.$1 > axis.$4) return;
        continue;
      }
      final a = (axis.$3 - axis.$1) / axis.$2;
      final b = (axis.$4 - axis.$1) / axis.$2;
      low = math.max(low, math.min(a, b));
      high = math.min(high, math.max(a, b));
      if (low > high) return;
    }
  }
  final start = (low * distance / 14).floor() * 14.0;
  final end = high * distance;
  for (double value = start; value < end; value += 14) {
    final startPoint = from + unit * value;
    final endPoint = from + unit * math.min(value + 8, end);
    path
      ..moveTo(startPoint.dx, startPoint.dy)
      ..lineTo(endPoint.dx, endPoint.dy);
  }
}
