import '../theme/open_note_icon.dart';
import '../theme/open_note_context_menu.dart';

import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../theme/open_note_theme.dart';
import '../theme/open_note_window_bar.dart';
import '../theme/open_note_tool_group.dart';
import '../theme/open_note_view_switch.dart';
import 'workbench_layout.dart';
import '../theme/open_note_feedback.dart';
import 'workspace_library.dart';

import 'package:flutter/services.dart';

import '../../application/ocr_queue.dart';
import '../../platform/window_fullscreen.dart';
import '../../application/workspace_controller.dart';
import '../../application/map_clipboard_controller.dart';
import '../../domain/map_clipboard.dart';
import '../../data/open_note_repository.dart';
import '../../domain/models.dart';
import '../map/map_outline_pane.dart';
import '../map/mind_map_pane.dart';
import '../map/relationship_style_dialog.dart';
import '../map/boundary_style_dialog.dart';
import '../map/summary_style_dialog.dart';
import '../map/topic_style_dialog.dart';
import '../../domain/topic_style_resolver.dart';
import '../reader/reader_pane.dart';
import '../reader/epub_reader_pane.dart';
import 'card_editor.dart';
import 'card_color_palette.dart';
import 'search_dialog.dart';
import 'text_input_dialog.dart';
import '../home/library_actions.dart';
import '../map/branch_structure_dialog.dart';
import '../map/map_structure_dialog.dart';
import '../theme/open_note_drag_cursor.dart';

enum _ViewLinkMode {
  both,
  documentToMap,
  mapToDocument,
  off;

  bool get locateMap => this == both || this == documentToMap;
  bool get locateDocument => this == both || this == mapToDocument;
  String get label => switch (this) {
    both => '双向联动',
    documentToMap => '文档定位脑图',
    mapToDocument => '脑图定位文档',
    off => '关闭联动',
  };
  IconData get icon => switch (this) {
    both => Icons.sync_alt,
    documentToMap => Icons.arrow_forward,
    mapToDocument => Icons.arrow_back,
    off => Icons.link_off,
  };
}

class WorkbenchController {
  Future<void> Function()? _prepare;
  VoidCallback? _cancel;
  Future<void> prepareToLeave() async => await _prepare?.call();
  void cancelLeave() => _cancel?.call();
}

class Workbench extends StatefulWidget {
  const Workbench({
    super.key,
    required this.repository,
    required this.projectId,
    required this.ocr,
    required this.controller,
    required this.onReturnHome,
    this.onWorkspaceReady,
    this.onInitialPdfReady,
    this.onEpubReady,
    this.mapClipboard,
  });
  final OpenNoteRepository repository;
  final String projectId;
  final OcrQueueController ocr;
  final WorkbenchController controller;
  final Future<void> Function() onReturnHome;
  final VoidCallback? onWorkspaceReady;
  final VoidCallback? onInitialPdfReady;
  final EpubReaderReady? onEpubReady;
  final MapClipboardController? mapClipboard;
  @override
  State<Workbench> createState() => _WorkbenchState();
}

class _WorkbenchState extends State<Workbench> {
  late final WorkspaceController _workspace;
  late final OcrQueueController _ocr;
  final _reader = ReaderPaneController();
  final _graph = MindMapPaneController();
  final _outline = MapOutlinePaneController();
  final _editor = CardEditorController();
  late final _mapClipboard = widget.mapClipboard ?? MapClipboardController();
  final _libraryFilter = TextEditingController();
  final _scaffold = GlobalKey<ScaffoldState>();
  final _contentFocus = FocusScopeNode(debugLabel: 'OpenNote 工作台内容');
  FocusNode? _lastContentFocus;
  final _imagePaths = <String, Future<String>>{};
  ({String key, MapSnapshot? map, Future<bool> available})? _editorSource;
  bool _working = false;
  int _queuedCommands = 0;
  Future<void> _commandTail = Future.value();
  Future<void>? _leaveRequest;
  int _commandFailures = 0;
  late final Future<void> _initialization;
  bool _closing = false;
  bool _readerClosing = false;
  bool _libraryVisible = true;
  final _window = const WindowFullscreen();
  Future<void> _fullscreenTail = Future.value();
  bool _immersive = false;
  bool _fullscreenRequested = false;
  int _fullscreenRequests = 0;
  Timer? _immersiveHintTimer;
  bool _immersiveHint = false;
  bool _mapVisible = true;
  bool _pdfVisible = true;
  bool _editorVisible = false;
  String? _editorCardId;
  String? _editorSession;
  String? _editorProjectId;
  String? _editorMapId;
  bool _outlineVisible = false;
  String? _newThemeCardId;
  int _editorFocusIntent = 0;
  bool _cardsTab = false;
  _ViewLinkMode _viewLinkMode = _ViewLinkMode.both;
  double _split = .58;
  final _tabDragCursor = OpenNoteDragCursor();
  String? _saveStatus;
  Timer? _saveFeedbackTimer;
  String? _feedbackCardId;
  String? _feedbackSession;
  bool _initialPdfReported = false;
  ({String session, String revision})? _ocrObservedDocument;
  bool _ocrPreviouslyReady = false;
  bool _ocrCompletionVisible = false;
  Timer? _ocrCompletionTimer;
  Timer? _clipboardFeedbackTimer;
  ({String session, String mapId, String message})? _clipboardFeedback;

  OpenNoteRepository get _repo => widget.repository;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_rememberContentFocus);
    _workspace = WorkspaceController(_repo)..addListener(_changed);
    _ocr = widget.ocr..addListener(_changed);
    widget.controller._prepare = _prepareToLeave;
    widget.controller._cancel = _cancelLeave;
    _initialization = _initialize();
    unawaited(_initialization.catchError(_workspace.reportError));
  }

  void _cancelLeave() {
    _leaveRequest = null;
    if (mounted) {
      setState(() {
        _closing = false;
        _readerClosing = false;
      });
    }
  }

  Future<void> _prepareToLeave() => _leaveRequest ??= _leave();

  Future<void> _leave() async {
    assert(() {
      debugPrint('EPUB 生命周期：等待工作台命令');
      return true;
    }());
    setState(() => _closing = true);
    final failures = _commandFailures;
    try {
      // 初始化失败也允许返回首页；错误已经显示，不在此重试打开失效项目。
      await _initialization.catchError((Object _) {});
      await _commandTail;
      assert(() {
        debugPrint('EPUB 生命周期：提交草稿与导航');
        return true;
      }());
      await _setImmersive(false);
      if (_commandFailures != failures) throw StateError('待完成操作失败，请确认后重试返回');
      await _flushDrafts();
      await _workspace.persistResume();
      _reader.clearHighlights();
      if (mounted) setState(() => _readerClosing = true);
      assert(() {
        debugPrint('EPUB 生命周期：等待关闭帧');
        return true;
      }());
      await WidgetsBinding.instance.endOfFrame;
      await _reader.drainClosedDocuments();
      assert(() {
        debugPrint('EPUB 生命周期：原生阅读器已关闭');
        return true;
      }());
      await _workspace.persistResume();
    } catch (error) {
      _cancelLeave();
      _workspace.reportError(error);
      rethrow;
    }
  }

  Future<void> _initialize() async {
    await _workspace.initialize(projectId: widget.projectId);
    if (!mounted || widget.onWorkspaceReady == null) return;
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) widget.onWorkspaceReady?.call();
  }

  void _changed() {
    _updateOcrCompletion();
    if (_repo.sessionId != _immersiveSession && _fullscreenRequested) {
      _background(_setImmersive(false));
    }
    if (_editorVisible) {
      if (_editorSession != _repo.sessionId ||
          _editorProjectId != _workspace.project?.id) {
        _editorVisible = false;
        _editorCardId = null;
        _editorFocusIntent++;
      } else {
        if (_editorMapId != _workspace.map?.map.id) {
          _editorMapId = _workspace.map?.map.id;
          _editorCardId = null;
          _editorFocusIntent++;
        }
        final selected = _workspace.selectedCard;
        if (selected != null) _editorCardId = selected.id;
        if (_editorCardId != null && _editorCard == null) {
          _editorCardId = null;
          _editorFocusIntent++;
        }
      }
    }
    if (_feedbackCardId != _feedbackTargetCardId ||
        _feedbackSession != _repo.sessionId) {
      _saveFeedbackTimer?.cancel();
      _saveStatus = null;
    }
    if (mounted) setState(() {});
  }

  NoteCard? get _editorCard =>
      _workspace.cards.where((card) => card.id == _editorCardId).firstOrNull;

  String? get _feedbackTargetCardId =>
      _editorVisible ? _editorCardId : _workspace.selectedCardId;

  void _openEditor(NoteCard card) {
    final opening = !_editorVisible;
    _editorVisible = true;
    _editorCardId = card.id;
    _editorSession = _repo.sessionId;
    _editorProjectId = _workspace.project?.id;
    _editorMapId = _workspace.map?.map.id;
    if (opening) {
      final session = _editorSession;
      final mapId = _editorMapId;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            !_editorVisible ||
            _outlineVisible ||
            !_mapVisible ||
            _editorSession != session ||
            _editorMapId != mapId ||
            _editorCardId != card.id ||
            (context.size?.width ?? 0) < 1600) {
          return;
        }
        final nodeId = _workspace.selectedNodeId;
        if (nodeId != null) _graph.keepNodeVisible(nodeId);
      });
    }
  }

  void _requireEditorContext(String session, String cardId) {
    if (!mounted ||
        _repo.sessionId != session ||
        _editorSession != session ||
        _editorProjectId != _workspace.project?.id ||
        !_editorVisible ||
        _editorCardId != cardId) {
      throw StateError('编辑目标已切换，请重新选择卡片');
    }
  }

  void _closeEditor() {
    // 关闭意图立即取消旧焦点请求，保存成功后才真正卸载编辑器。
    _editorFocusIntent++;
    final session = _repo.sessionId;
    final projectId = _workspace.project?.id;
    _background(
      _perform(() async {
        if (_repo.sessionId != session || _workspace.project?.id != projectId) {
          return;
        }
        if (mounted) {
          setState(() {
            _editorVisible = false;
            _editorCardId = null;
          });
        }
      }, showGlobalProgress: false),
    );
  }

  Future<void> _perform(
    Future<void> Function() action, {
    bool flush = true,
    bool selectionOnly = false,
    bool showGlobalProgress = true,
    bool reportFailure = true,
  }) async {
    if (!mounted || _closing) return;
    // 选择仍串行等待草稿提交，但不把本地视图状态当成全局写入命令。
    // 拖动写入由脑图区显示忙碌状态，避免每次松手都闪烁全局按钮。
    final globalProgress = !selectionOnly && showGlobalProgress;
    if (globalProgress) {
      _queuedCommands++;
      setState(() => _working = true);
    }
    final operation = _commandTail.then((_) async {
      // 恢复脑图／标签完成后再执行已接受输入，避免较晚的恢复清掉用户刚选中的节点。
      await _initialization;
      if (!mounted) return;
      try {
        if (flush) await _flushDrafts();
        await action();
        if (!selectionOnly) await _workspace.refresh();
      } catch (error, trace) {
        _commandFailures++;
        if (reportFailure) _workspace.reportError(error, trace);
        rethrow;
      }
    });
    // 队列继续接受后续命令；当前调用仍必须收到失败，才能回滚临时画布位置。
    _commandTail = operation.catchError((Object _) {});
    try {
      await operation;
    } finally {
      if (globalProgress) {
        _queuedCommands--;
        if (mounted) setState(() => _working = _queuedCommands > 0);
      }
    }
  }

  void _background(Future<void> future) {
    unawaited(future.catchError(_workspace.reportError));
  }

  Future<void> _flushDrafts() async {
    await _editor.flush();
    await _flushMapTitles();
    await _flushRelationshipLabel();
    await _flushBoundaryLabel();
  }

  Future<void> _flushBoundaryLabel() async {
    final draft = _graph.boundaryDraft;
    if (draft == null) return;
    final session = _repo.sessionId;
    _requireMapContext(session, draft.mapId);
    await _repo.updateBoundary(
      draft.boundaryId,
      label: draft.label,
      expectedMapId: draft.mapId,
      expectedNodeIds: draft.nodeIds,
    );
    _requireMapContext(session, draft.mapId);
    _graph.acceptBoundaryLabel(draft);
    await _workspace.refresh();
  }

  Future<void> _editBoundary(String session, MapBoundary boundary) async {
    await _perform(() async {}, selectionOnly: true);
    _requireMapContext(session, boundary.mapId);
    final snapshot = await _repo.loadMap(boundary.mapId);
    final latest = snapshot.boundaries
        .where((b) => b.id == boundary.id)
        .firstOrNull;
    if (!mounted || latest == null) return;
    final result = await showDialog<BoundaryEditResult>(
      context: context,
      builder: (_) => BoundaryStyleDialog(boundary: latest, snapshot: snapshot),
    );
    if (result == null) return;
    await _perform(() async {
      _requireMapContext(session, boundary.mapId);
      await _repo.updateBoundary(
        boundary.id,
        label: result.label,
        style: result.style,
        nodeIds: result.nodeIds,
        expectedMapId: boundary.mapId,
        expectedNodeIds: latest.nodeIds,
      );
    }, showGlobalProgress: false);
  }

  Future<void> _editSummary(String session, MapSummary summary) async {
    await _perform(() async {}, selectionOnly: true);
    _requireMapContext(session, summary.mapId);
    final snapshot = await _repo.loadMap(summary.mapId);
    final latest = snapshot.summaries
        .where((s) => s.id == summary.id)
        .firstOrNull;
    if (!mounted || latest == null) return;
    final result = await showDialog<SummaryEditResult>(
      context: context,
      builder: (_) => SummaryStyleDialog(summary: latest, snapshot: snapshot),
    );
    if (result == null) return;
    await _perform(() async {
      _requireMapContext(session, summary.mapId);
      await _repo.updateSummary(
        summary.id,
        style: result.style,
        nodeIds: result.nodeIds,
        expectedMapId: summary.mapId,
        expectedNodeIds: latest.nodeIds,
      );
    }, showGlobalProgress: false);
  }

  Future<void> _editTopicStyle(
    String session,
    String mapId, {
    String? nodeId,
  }) async {
    late Set<String> ids;
    await _perform(() async {
      _requireMapContext(session, mapId);
      ids = nodeId == null
          ? <String>{}
          : _workspace.selectedNodeIds.contains(nodeId)
          ? Set<String>.of(_workspace.selectedNodeIds)
          : {nodeId};
    }, selectionOnly: true);
    _requireMapContext(session, mapId);
    final snapshot = await _repo.loadMap(mapId);
    final nodes = {for (final n in snapshot.nodes) n.id: n};
    if (!mounted || ids.any((id) => !nodes.containsKey(id))) return;
    final expected = {for (final id in ids) id: nodes[id]!.cardId};
    final result = await showDialog<TopicStyleEditResult>(
      context: context,
      builder: (_) => TopicStyleDialog(
        style: nodeId == null
            ? snapshot.map.defaultStyle
            : topicStyleFor(snapshot, nodes[nodeId]!),
        defaultStyle: nodeId == null
            ? const TopicStyle()
            : snapshot.map.defaultStyle,
        selectionCount: ids.length,
        editingDefault: nodeId == null,
      ),
    );
    if (result == null) return;
    await _perform(() async {
      _requireMapContext(session, mapId);
      await _repo.setTopicStyle(
        mapId,
        ids,
        result.style,
        includeDescendants: result.includeDescendants,
        makeDefault: result.makeDefault,
        expectedCardIds: expected,
      );
    }, showGlobalProgress: false);
  }

  Future<void> _editBranchStructure(MapNode node) async {
    final session = _repo.sessionId, mapId = node.mapId;
    late Set<String> ids;
    await _perform(() async {
      _requireMapContext(session, mapId);
      ids = _workspace.selectedNodeIds.contains(node.id)
          ? Set.of(_workspace.selectedNodeIds)
          : {node.id};
    }, selectionOnly: true);
    _requireMapContext(session, mapId);
    final snapshot = await _repo.loadMap(mapId);
    final nodes = {for (final n in snapshot.nodes) n.id: n};
    if (!mounted || ids.any((id) => !nodes.containsKey(id))) return;
    final expected = {for (final id in ids) id: nodes[id]!.cardId};
    final result = await showDialog<BranchStructureResult>(
      context: context,
      builder: (_) => BranchStructureDialog(
        kind: nodes[node.id]!.branchLayout,
        selectionCount: ids.length,
      ),
    );
    if (result == null) return;
    await _perform(() async {
      _requireMapContext(session, mapId);
      await _repo.setBranchLayout(
        mapId,
        ids,
        result.kind,
        resetDescendantOverrides: result.resetDescendants,
        expectedCardIds: expected,
      );
    }, showGlobalProgress: false);
  }

  Future<void> _flushRelationshipLabel() async {
    final draft = _graph.relationshipDraft;
    if (draft == null) return;
    final session = _repo.sessionId;
    _requireMapContext(session, draft.mapId);
    await _repo.updateAssociation(
      draft.edgeId,
      label: draft.label,
      expectedFromNodeId: draft.fromNodeId,
      expectedToNodeId: draft.toNodeId,
    );
    _requireMapContext(session, draft.mapId);
    _graph.acceptRelationshipLabel(draft);
    await _workspace.refresh();
  }

  Future<void> _editAssociation(String session, MapEdge edge) async {
    await _perform(() async {}, selectionOnly: true);
    _requireMapContext(session, edge.mapId);
    final latest = (await _repo.loadMap(edge.mapId)).edges
        .where((e) => e.id == edge.id)
        .firstOrNull;
    if (!mounted ||
        latest == null ||
        latest.fromNodeId != edge.fromNodeId ||
        latest.toNodeId != edge.toNodeId) {
      return;
    }
    final result = await showDialog<RelationshipEditResult>(
      context: context,
      builder: (_) => RelationshipStyleDialog(edge: latest),
    );
    if (result == null) return;
    await _perform(() async {
      _requireMapContext(session, edge.mapId);
      await _repo.updateAssociation(
        edge.id,
        label: result.label,
        style: result.style,
        expectedFromNodeId: latest.fromNodeId,
        expectedToNodeId: latest.toNodeId,
      );
    }, showGlobalProgress: false);
  }

  Future<void> _flushMapTitles() async {
    // 两个视图保留各自滚动状态；切换前提交当前草稿，隐藏视图不留下未保存输入。
    final draft = _outline.titleDraft ?? _graph.titleDraft;
    if (draft == null) return;
    final session = _repo.sessionId;
    _requireMapContext(session, draft.mapId);
    final latest = await _repo.loadMap(draft.mapId);
    final node = latest.nodes.where((n) => n.id == draft.nodeId).firstOrNull;
    if (node == null || node.cardId != draft.cardId) {
      throw StateError('正在编辑的主题已变更，请重新选择');
    }
    await _repo.updateCard(draft.cardId, title: draft.title);
    _requireMapContext(session, draft.mapId);
    _graph.acceptTitle(draft);
    _outline.acceptTitle(draft);
    await _workspace.refresh();
  }

  Future<String> _imagePath(String resourceId) => _imagePaths.putIfAbsent(
    '${_repo.sessionId}:$resourceId',
    () => _repo.resourcePath(resourceId),
  );

  @override
  void dispose() {
    FocusManager.instance.removeListener(_rememberContentFocus);
    _immersiveHintTimer?.cancel();
    if (_fullscreenRequested || _immersive) {
      unawaited(
        _setImmersive(false).catchError((Object error) {
          // 销毁后仍恢复原生窗口；错误留在诊断日志，不访问已销毁工作台。
          debugPrint('恢复普通窗口失败：$error');
        }),
      );
    }
    _tabDragCursor.hide();
    _contentFocus.dispose();
    _clipboardFeedbackTimer?.cancel();
    widget.controller._prepare = null;
    widget.controller._cancel = null;
    _workspace.removeListener(_changed);
    _ocr.removeListener(_changed);
    _saveFeedbackTimer?.cancel();
    _ocrCompletionTimer?.cancel();
    _workspace.dispose();
    _libraryFilter.dispose();
    super.dispose();
  }

  Future<String?> _nameDialog(
    String title,
    String hint, {
    String initialText = '',
    String confirmLabel = '创建',
  }) async {
    final result = await showDialog<TextInputResult>(
      context: context,
      builder: (context) => TextInputDialog(
        title: title,
        hint: hint,
        initialText: initialText,
        confirmLabel: confirmLabel,
        requireText: true,
      ),
    );
    return result?.text.trim();
  }

  Future<void> _rename(
    String kind,
    String currentTitle,
    Future<void> Function(String) save,
  ) async {
    final title = await _nameDialog(
      '重命名$kind',
      '$kind名称',
      initialText: currentTitle,
      confirmLabel: '保存',
    );
    if (title != null) await _perform(() => save(title));
  }

  Future<void> _newMap() async {
    final project = _workspace.project;
    if (project == null) return;
    final name = await _nameDialog('新建脑图', '脑图名称');
    if (name != null) {
      await _perform(() async {
        final map = await _repo.createMap(project.id, name);
        await _workspace.selectMap(map.id);
      });
    }
  }

  Future<void> _newTheme({
    MapNode? relativeTo,
    bool sibling = false,
    Offset? canvasPosition,
    bool quickTitle = false,
  }) async {
    final map = _workspace.map;
    if (_working || _closing || map == null) return;
    final session = _repo.sessionId;
    final target = canvasPosition != null
        ? null
        : relativeTo ??
              map.nodes
                  .where((node) => node.id == _workspace.selectedNodeId)
                  .firstOrNull;
    final parentId = canvasPosition != null
        ? null
        : sibling
        ? target?.parentNodeId
        : target?.id;
    await _perform(() async {
      if (_repo.sessionId != session || _workspace.map?.map.id != map.map.id) {
        throw StateError('目标脑图已切换，请重新创建主题');
      }
      final result = await _workspace.addTheme(
        '新主题',
        parentNodeId: parentId,
        x: canvasPosition?.dx ?? (sibling ? target?.x : null),
        y: canvasPosition?.dy,
      );
      if (!mounted ||
          _repo.sessionId != session ||
          _workspace.map?.map.id != map.map.id) {
        return;
      }
      setState(() {
        _newThemeCardId = quickTitle ? null : result.card.id;
        if (!quickTitle) _openEditor(result.card);
      });
      _graph.centerOnNode(result.node.id);
    });
    if (quickTitle && mounted && _workspace.selectedNodeId != null) {
      _graph.editTitle(_workspace.selectedNodeId!);
    }
  }

  Future<void> _insertMapTopic(MapNode node, TopicInsertKind kind) async {
    final session = _repo.sessionId;
    final mapId = node.mapId;
    String? createdId;
    await _perform(() async {
      _requireMapContext(session, mapId);
      final result = await _repo.insertTopic(node.id, kind);
      _requireMapContext(session, mapId);
      await _workspace.refresh();
      _workspace.selectInsertedNodes([result.node]);
      createdId = result.node.id;
      _graph.centerOnNode(result.node.id);
    });
    if (createdId != null && mounted) {
      if (_outlineVisible) {
        _outline.editTitle(createdId!);
      } else {
        _graph.editTitle(createdId!);
      }
    }
  }

  Future<void> _import() async {
    if (_workspace.project == null) return;
    final files = await openFiles(
      acceptedTypeGroups: const [
        XTypeGroup(label: '阅读文档（PDF／EPUB）', extensions: ['pdf', 'epub']),
      ],
    );
    if (files.isEmpty) return;
    await _perform(() async {
      for (final file in files) {
        final document = await _workspace.importDocument(file.path);
        final revision = await _repo.getRevision(document.activeRevisionId);
        if (revision.format == DocumentFormat.pdf) {
          await _ocr.enqueueRevision(
            document.activeRevisionId,
            priorityPage: 0,
          );
        }
      }
    });
  }

  Future<void> _source(NoteCard card, {VoidCallback? requireContext}) async {
    final zoom = _reader.currentZoom;
    requireContext?.call();
    await _editor.flush();
    requireContext?.call();
    final anchors = await _repo.getAnchors(card.id);
    requireContext?.call();
    if (anchors.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('主题卡片没有原文来源')));
      }
      return;
    }
    final revision = await _repo.getRevision(anchors.first.revisionId);
    requireContext?.call();
    final document = await _repo.getDocument(revision.documentId);
    requireContext?.call();
    await _workspace.openDocument(document);
    requireContext?.call();
    if (mounted) setState(() => _pdfVisible = true);
    await _reader.jumpToAnchors(anchors, zoom: zoom, cardId: card.id);
    requireContext?.call();
  }

  Future<void> _selectCard(NoteCard card, {bool editor = true}) async {
    await _editor.flush();
    _newThemeCardId = null;
    for (final map in _workspace.maps) {
      final snapshot = map.id == _workspace.map?.map.id
          ? _workspace.map!
          : await _repo.loadMap(map.id);
      final node = snapshot.nodes.where((n) => n.cardId == card.id).firstOrNull;
      if (node != null) {
        if (map.id != _workspace.map?.map.id) {
          await _workspace.selectMap(map.id);
        }
        var parentId = node.parentNodeId;
        while (parentId != null) {
          final parent = snapshot.nodes.firstWhere((n) => n.id == parentId);
          if (parent.collapsed) await _repo.setNodeCollapsed(parent.id, false);
          parentId = parent.parentNodeId;
        }
        await _workspace.refresh();
        _workspace.selectNode(node);
        _graph.centerOnNode(node.id);
        break;
      }
    }
    _workspace.selectCard(card);
    if (mounted) {
      setState(() {
        if (editor) _openEditor(card);
        _mapVisible = true;
      });
    }
  }

  Future<void> _annotation(AppAnnotation annotation) async {
    if (annotation.cardId != null) {
      if (_viewLinkMode.locateMap) {
        await _selectCard(
          await _repo.getCard(annotation.cardId!),
          editor: false,
        );
      }
      return;
    }
    if (!mounted) return;
    final result = await showDialog<TextInputResult>(
      context: context,
      builder: (context) => TextInputDialog(
        title: '文字批注',
        initialText: annotation.text,
        multiline: true,
        allowDelete: true,
      ),
    );
    if (result == null) return;
    if (result.delete) {
      await _repo.deleteAnnotation(annotation.id);
    } else {
      await _repo.updateAnnotation(annotation.id, text: result.text);
    }
  }

  Future<void> _branchAction(MapNode node, String action) async {
    final card = _workspace.map?.cards[node.cardId];
    switch (action) {
      case 'source':
        if (card != null) await _source(card);
      case 'copyBranch':
      case 'moveBranch':
        await _copyOrMove(node, move: action == 'moveBranch');
      case 'detach':
        await _repo.reparentNode(node.id, null);
      case 'removeBranch':
        await _trashMapTopics(node.mapId, {node.id});
      case 'trashCard':
        await _repo.trashCard(node.cardId);
        _reader.clearAfterCardDeletion({node.cardId});
      case 'color':
        if (card != null) await _chooseCardColor(card);
      case 'removeTopicOnly':
        await _trashMapTopics(node.mapId, {node.id}, includeDescendants: false);
      case 'moveBefore':
      case 'moveAfter':
        await _repo.reorderTopic(node.id, before: action == 'moveBefore');
      case 'branchLeft':
      case 'branchRight':
        await _repo.setBranchSide(node.id, action == 'branchLeft' ? -1 : 1);
      case 'promote':
      case 'demote':
        final latest = await _repo.loadMap(node.mapId);
        final current = latest.nodes.where((n) => n.id == node.id).firstOrNull;
        if (current == null) throw StateError('主题已变更，请重新选择');
        if (action == 'promote') {
          if (current.parentNodeId == null) return;
          final parent = latest.nodes.firstWhere(
            (n) => n.id == current.parentNodeId,
          );
          await _repo.reparentNode(
            node.id,
            parent.parentNodeId,
            x: parent.x,
            y: parent.y + parent.height + 24,
          );
        } else {
          final siblings =
              latest.nodes
                  .where((n) => n.parentNodeId == current.parentNodeId)
                  .toList()
                ..sort(compareMapNodes);
          final index = siblings.indexWhere((n) => n.id == node.id);
          if (index == 0) return;
          final parent = siblings[index - 1];
          await _repo.reparentNode(
            node.id,
            parent.id,
            x: parent.x + parent.width + 70,
            y: current.y,
          );
        }
    }
  }

  void _mapAction(MapNode node, String action) {
    if (action == 'collapseBranch') {
      final session = _repo.sessionId;
      _background(
        _perform(() async {
          _requireMapContext(session, node.mapId);
          await _repo.toggleNodeBranchCollapsed(node.id);
        }, showGlobalProgress: false),
      );
    } else if (action == 'branchStructure') {
      _background(_editBranchStructure(node));
    } else if (action == 'topicStyle') {
      _background(
        _editTopicStyle(_repo.sessionId, node.mapId, nodeId: node.id),
      );
    } else if (const [
      'newChild',
      'newSibling',
      'newSiblingBefore',
      'newParent',
    ].contains(action)) {
      _background(
        _insertMapTopic(node, switch (action) {
          'newChild' => TopicInsertKind.child,
          'newSiblingBefore' => TopicInsertKind.siblingBefore,
          'newParent' => TopicInsertKind.parent,
          _ => TopicInsertKind.siblingAfter,
        }),
      );
    } else if (action == 'editTitle') {
      if (_outlineVisible) {
        _outline.editTitle(node.id);
      } else {
        _graph.editTitle(node.id);
      }
    } else if (action == 'removeSelectedBranches') {
      _selectedAction(action, selectionAtExecution: true);
    } else if (action == 'editSelected') {
      _selectedAction('edit', selectionAtExecution: true);
    } else if (action == 'edit') {
      _editMapNode(node);
    } else {
      _background(_perform(() => _branchAction(node, action)));
    }
  }

  void _mapSelect(MapNode node) => _selectMapNode(node, additive: false);

  void _showClipboardFeedback(String session, String mapId, String message) {
    if (!mounted || _closing) return;
    _clipboardFeedbackTimer?.cancel();
    setState(
      () => _clipboardFeedback = (
        session: session,
        mapId: mapId,
        message: message,
      ),
    );
    _clipboardFeedbackTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _clipboardFeedback = null);
    });
  }

  void _clipboardAction(String action) {
    final mapId = _workspace.map?.map.id;
    if (mapId == null || _closing) return;
    final session = _repo.sessionId;
    _background(
      _perform(() async {
        _requireMapContext(session, mapId);
        if (action != 'paste') {
          final ids = Set<String>.of(_workspace.selectedNodeIds);
          if (ids.isEmpty) return;
          final latest = await _repo.loadMap(mapId);
          final content = MapClipboardContent.capture(latest, ids);
          await Clipboard.setData(ClipboardData(text: content.text));
          _requireMapContext(session, mapId);
          _mapClipboard.store(content, session, isCut: action == 'cut');
          _showClipboardFeedback(
            session,
            mapId,
            action == 'cut'
                ? '分支已准备剪切，粘贴成功后移动'
                : '已复制 ${content.snapshot.nodes.length} 个主题及其内容',
          );
          return;
        }
        final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
        _requireMapContext(session, mapId);
        if (text == null || text.trim().isEmpty) {
          throw StateError('剪贴板中没有可粘贴的主题');
        }
        final content = _mapClipboard.matching(text, session);
        final parent = _workspace.selectedNodeId;
        final roots = content == null
            ? await _repo.pasteTopicOutline(
                mapId,
                parseTopicOutline(text),
                parentNodeId: parent,
              )
            : _mapClipboard.cut
            ? await _repo.pasteTopicMove(content, mapId, parentNodeId: parent)
            : await _repo.pasteTopicCopy(content, mapId, parentNodeId: parent);
        _requireMapContext(session, mapId);
        _mapClipboard.cut = false;
        await _workspace.refresh();
        _workspace.selectInsertedNodes(roots);
        if (roots.isNotEmpty) _graph.centerOnNode(roots.first.id);
      }, selectionOnly: action != 'paste'),
    );
  }

  void _mapToggleSelection(MapNode node) =>
      _selectMapNode(node, additive: true);

  void _selectMapNode(MapNode node, {required bool additive}) {
    // 较晚的选择输入取消旧编辑请求，即使主选卡片没有改变。
    _editorFocusIntent++;
    final session = _repo.sessionId;
    final mapId = _workspace.map?.map.id;
    final locateCanvas = _outlineVisible;
    _background(
      _perform(() async {
        if (_repo.sessionId != session ||
            _workspace.map?.map.id != mapId ||
            mapId != node.mapId ||
            !_workspace.map!.nodes.any((value) => value.id == node.id)) {
          return;
        }
        _newThemeCardId = null;
        _workspace.selectNode(node, additive: additive);
        if (locateCanvas) _graph.centerOnNode(node.id);
      }, selectionOnly: true),
    );
  }

  void _requireMapContext(String session, String mapId) {
    if (_repo.sessionId != session || _workspace.map?.map.id != mapId) {
      throw StateError('目标脑图已切换，请重新选择卡片');
    }
  }

  Future<void> _dropTextExcerpt(
    String session,
    String mapId,
    ReaderExcerptDrag drag,
    Offset position,
    MapNode? parent,
  ) async {
    bool current() =>
        mounted &&
        !_closing &&
        !_readerClosing &&
        _mapVisible &&
        _pdfVisible &&
        !_outlineVisible &&
        _repo.sessionId == session &&
        _workspace.map?.map.id == mapId &&
        _workspace.revision?.id == drag.revisionId &&
        drag.isCurrent;
    if (!current()) throw const ReaderExcerptDragCancelled();
    final excerpt = await drag.prepare();
    if (!current()) throw const ReaderExcerptDragCancelled();
    ExcerptResult? inserted;
    await _perform(
      () async {
        // 在队列真正执行时检查来源，再提交旧草稿；失效拖动不触碰新会话的编辑器。
        if (!current()) return;
        await _flushDrafts();
        if (!current()) return;
        if (parent != null &&
            !_workspace.map!.nodes.any(
              (n) => n.id == parent.id && n.cardId == parent.cardId,
            )) {
          return;
        }
        inserted = await _workspace.addExcerptAt(
          excerpt,
          mapId: mapId,
          position: PdfPoint(position.dx, position.dy),
          parentNodeId: parent?.id,
          selectionIsCurrent: current,
        );
      },
      flush: false,
      showGlobalProgress: false,
      reportFailure: false,
    );
    if (inserted == null) throw const ReaderExcerptDragCancelled();
  }

  void _editMapNode(MapNode node) {
    final mapId = _workspace.map?.map.id;
    if (mapId == null || node.mapId != mapId) return;
    final session = _repo.sessionId;
    final nodeId = node.id;
    final cardId = node.cardId;
    final focusIntent = ++_editorFocusIntent;
    _background(
      _perform(() async {
        _requireMapContext(session, mapId);
        final latest = await _repo.loadMap(mapId);
        _requireMapContext(session, mapId);
        final current = latest.nodes
            .where((value) => value.id == nodeId && value.cardId == cardId)
            .firstOrNull;
        final card = latest.cards[cardId];
        if (current == null || card == null) {
          throw StateError('目标卡片已变更，请重新选择');
        }
        if (_editorFocusIntent != focusIntent) return;
        _newThemeCardId = null;
        _workspace.selectNode(current);
        _workspace.selectCard(card);
        if (mounted) {
          setState(() {
            _openEditor(card);
            _mapVisible = true;
          });
        }
        await _focusEditorBody(
          session,
          mapId,
          cardId,
          nodeId: nodeId,
          selectedIds: Set<String>.unmodifiable(_workspace.selectedNodeIds),
          focusIntent: focusIntent,
        );
      }),
    );
  }

  Future<void> _focusEditorBody(
    String session,
    String mapId,
    String cardId, {
    required String nodeId,
    required Set<String> selectedIds,
    required int focusIntent,
  }) async {
    bool isCurrent() =>
        mounted &&
        !_closing &&
        _editorFocusIntent == focusIntent &&
        _editorVisible &&
        _editorCardId == cardId &&
        _repo.sessionId == session &&
        _workspace.map?.map.id == mapId &&
        _workspace.selectedNodeId == nodeId &&
        _workspace.selectedNodeIds.length == selectedIds.length &&
        _workspace.selectedNodeIds.containsAll(selectedIds) &&
        _workspace.selectedCard?.id == cardId;
    await WidgetsBinding.instance.endOfFrame;
    if (isCurrent()) _editor.focusBody(cardId, isCurrent: isCurrent);
  }

  Future<void> _moveMapGroup(
    String session,
    String mapId,
    Map<String, PdfPoint> positions,
  ) {
    final frozen = Map<String, PdfPoint>.unmodifiable(positions);
    return _perform(() async {
      _requireMapContext(session, mapId);
      await _repo.layoutNodes(mapId, frozen);
    }, showGlobalProgress: false);
  }

  Future<void> _trashMapTopics(
    String mapId,
    Set<String> nodeIds, {
    bool includeDescendants = true,
  }) async {
    final cards = await _repo.trashMapTopics(
      mapId,
      nodeIds,
      includeDescendants: includeDescendants,
    );
    _reader.clearAfterCardDeletion(cards);
  }

  void _selectedAction(String action, {bool selectionAtExecution = false}) {
    final map = _workspace.map;
    if (map == null) return;
    final session = _repo.sessionId;
    final mapId = map.map.id;
    final acceptedPrimary = _workspace.selectedNodeId;
    final acceptedSelection = Set<String>.unmodifiable(
      _workspace.selectedNodeIds,
    );
    if (!selectionAtExecution && acceptedSelection.isEmpty) return;
    final focusIntent = action == 'edit' ? ++_editorFocusIntent : null;
    _background(
      _perform(() async {
        _requireMapContext(session, mapId);
        // 键盘意图按队列顺序取目标，前置Ctrl选择必须先完成；菜单保留接受时的明确目标。
        final primaryId = selectionAtExecution
            ? _workspace.selectedNodeId
            : acceptedPrimary;
        final selected = selectionAtExecution
            ? Set<String>.unmodifiable(_workspace.selectedNodeIds)
            : acceptedSelection;
        if (primaryId == null || selected.isEmpty) return;
        final latest = await _repo.loadMap(mapId);
        _requireMapContext(session, mapId);
        final nodes = {for (final node in latest.nodes) node.id: node};
        if (selected.any((id) => !nodes.containsKey(id)) ||
            !selected.contains(primaryId)) {
          throw StateError('所选卡片已变更，请重新选择');
        }
        final card = latest.cards[nodes[primaryId]!.cardId]!;
        switch (action) {
          case 'edit':
            // 打开当前主选卡的共用编辑器，不把多选改为单选。
            if (_workspace.selectedNodeId != primaryId ||
                _editorFocusIntent != focusIntent) {
              return;
            }
            if (mounted) setState(() => _openEditor(card));
            await _focusEditorBody(
              session,
              mapId,
              card.id,
              nodeId: primaryId,
              selectedIds: selected,
              focusIntent: focusIntent!,
            );
          case 'source':
            await _source(card);
          case 'collapseSelected':
            await _repo.setNodesCollapsed(mapId, selected, true);
          case 'expandSelected':
            await _repo.setNodesCollapsed(mapId, selected, false);
          case 'colorSelected':
            final colors = selected
                .map((id) => latest.cards[nodes[id]!.cardId]!.color)
                .toSet();
            final color = await _pickCardColor(
              title: '所选 ${selected.length} 张卡片的颜色',
              currentColor: colors.length == 1 ? colors.single : null,
            );
            if (color == null) return;
            _requireMapContext(session, mapId);
            await _repo.setCardsColor(mapId, selected, color);
          case 'removeSelectedBranches':
            await _trashMapTopics(mapId, selected);
        }
      }),
    );
  }

  Widget _selectedMenu(MapSnapshot map, {required bool compact}) {
    final count = _workspace.selectedNodeIds.length;
    final selectionLabel = '已选 $count 项';
    final primary = map.nodes
        .where((node) => node.id == _workspace.selectedNodeId)
        .firstOrNull;
    return PopupMenuButton<String>(
      key: const Key('workspace-selected-menu'),
      tooltip: selectionLabel,
      enabled: !_working && !_closing,
      onSelected: _selectedAction,
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'edit', child: Text('编辑主选卡片')),
        PopupMenuItem(
          value: 'source',
          enabled:
              primary != null &&
              (map.anchors[primary.cardId] ?? const []).isNotEmpty,
          child: const Text('主选卡片回到原文'),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'collapseSelected', child: Text('折叠所选节点')),
        const PopupMenuItem(value: 'expandSelected', child: Text('展开所选节点')),
        const PopupMenuItem(value: 'colorSelected', child: Text('所选卡片颜色…')),
        const PopupMenuItem(
          value: 'removeSelectedBranches',
          child: Text('所选分支及后代卡片移入回收站'),
        ),
      ],
      child: Semantics(
        label: selectionLabel,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: compact
                ? [
                    const OpenNoteIcon(Icons.check_box_outlined, size: 18),
                    const SizedBox(width: 4),
                    Text('$count'),
                  ]
                : [
                    Text(selectionLabel),
                    const OpenNoteIcon(Icons.arrow_drop_down, size: 18),
                  ],
          ),
        ),
      ),
    );
  }

  void _mapActivate(MapNode node) {
    final map = _workspace.map;
    if (map == null ||
        map.map.id != node.mapId ||
        !_viewLinkMode.locateDocument ||
        (map.anchors[node.cardId] ?? const []).isEmpty) {
      return;
    }
    final session = _repo.sessionId;
    final mapId = map.map.id;
    final nodeId = node.id;
    final cardId = node.cardId;
    _background(
      _perform(() async {
        _requireMapContext(session, mapId);
        final latest = await _repo.loadMap(mapId);
        _requireMapContext(session, mapId);
        if (!latest.nodes.any(
          (value) => value.id == nodeId && value.cardId == cardId,
        )) {
          throw StateError('目标卡片已变更，请重新选择');
        }
        final card = latest.cards[cardId];
        if (card == null) throw StateError('目标卡片已变更，请重新选择');
        await _source(
          card,
          requireContext: () => _requireMapContext(session, mapId),
        );
      }),
    );
  }

  void _toggleMapCollapsed(String id) {
    final mapId = _workspace.map?.map.id;
    if (mapId == null) return;
    final session = _repo.sessionId;
    _background(
      _perform(() async {
        _requireMapContext(session, mapId);
        final latest = await _repo.loadMap(mapId);
        _requireMapContext(session, mapId);
        final node = latest.nodes.firstWhere((value) => value.id == id);
        await _repo.setNodeCollapsed(id, !node.collapsed);
      }, showGlobalProgress: false),
    );
  }

  Widget _mapViewSwitcher({required bool compact}) {
    if (compact) {
      return PopupMenuButton<bool>(
        key: const Key('map-view-switch'),
        tooltip: _outlineVisible ? '脑图视图：大纲' : '脑图视图：画布',
        initialValue: _outlineVisible,
        icon: OpenNoteIcon(
          _outlineVisible
              ? Icons.view_list_outlined
              : Icons.account_tree_outlined,
          size: 20,
        ),
        onSelected: _switchMapView,
        itemBuilder: (context) => const [
          PopupMenuItem(value: false, child: Text('画布')),
          PopupMenuItem(value: true, child: Text('大纲')),
        ],
      );
    }
    return OpenNoteViewSwitch(
      key: const Key('map-view-switch'),
      value: _outlineVisible,
      labels: const ['画布', '大纲'],
      icons: const [Icons.account_tree_outlined, Icons.view_list_outlined],
      iconOnly: true,
      onChanged: _switchMapView,
    );
  }

  void _switchMapView(bool outline) {
    if (outline == _outlineVisible) return;
    _background(
      _perform(
        () async {
          await _flushMapTitles();
          await _flushRelationshipLabel();
          await _flushBoundaryLabel();
          if (mounted) setState(() => _outlineVisible = outline);
        },
        flush: false,
        selectionOnly: true,
      ),
    );
  }

  Future<void> _chooseCardColor(NoteCard card) async {
    final session = _repo.sessionId;
    final projectId = _workspace.project?.id;
    final color = await _pickCardColor(title: '卡片颜色', currentColor: card.color);
    if (color == null) return;
    if (_repo.sessionId != session || _workspace.project?.id != projectId) {
      throw StateError('目标资料库已切换，请重新选择卡片');
    }
    await _repo.updateCard(card.id, color: color);
  }

  Future<void> _changeEditorColor(
    String session,
    String cardId,
    String color,
  ) async {
    _requireEditorContext(session, cardId);
    await _perform(
      () async {
        _requireEditorContext(session, cardId);
        await _flushDrafts();
        _requireEditorContext(session, cardId);
        await _repo.updateCard(cardId, color: color);
      },
      flush: false,
      showGlobalProgress: false,
    );
  }

  Future<String?> _pickCardColor({
    required String title,
    String? currentColor,
  }) async {
    return showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(title),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
            child: CardColorPalette(
              currentColor: currentColor,
              onSelected: (color) => Navigator.pop(context, color),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _copyOrMove(MapNode node, {required bool move}) async {
    final projects = move ? [_workspace.project!] : _workspace.projects;
    final targets = <({StudyProject project, MindMap map})>[];
    for (final project in projects) {
      for (final map in await _repo.listMaps(project.id)) {
        if (!move || map.id != node.mapId) {
          targets.add((project: project, map: map));
        }
      }
    }
    if (!mounted) return;
    final target = await showDialog<MindMap>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(move ? '移动完整分支' : '复制为独立分支'),
        children: targets.isEmpty
            ? [
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('请先新建另一个脑图'),
                ),
              ]
            : [
                for (final target in targets)
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(context, target.map),
                    child: Text(
                      '${target.project.title} / ${target.map.title}',
                    ),
                  ),
              ],
      ),
    );
    if (target == null) return;
    if (move) {
      await _repo.moveBranchToMap(node.id, target.id);
    } else {
      await _repo.copyBranch(node.id, target.id);
    }
  }

  Future<void> _search() async {
    final project = _workspace.project;
    if (project == null) return;
    await _editor.flush();
    if (!mounted) return;
    final hit = await showDialog<SearchHit>(
      context: context,
      builder: (context) =>
          SearchDialog(repository: _repo, projectId: project.id),
    );
    if (hit == null) return;
    await _perform(() async {
      if (hit.cardId != null) {
        await _selectCard(await _repo.getCard(hit.cardId!));
      } else if (hit.documentId != null) {
        final zoom = _reader.currentZoom;
        await _workspace.openDocument(await _repo.getDocument(hit.documentId!));
        if (mounted) setState(() => _pdfVisible = true);
        await _reader.showSearchHit(hit, zoom: zoom);
      }
    });
  }

  Future<void> _trash() async {
    await _editor.flush();
    if (!mounted) return;
    await LibraryActions(context, _repo).trash(projectId: widget.projectId);
    await _workspace.refresh();
  }

  KeyEventResult _key(FocusNode focus, KeyEvent event) {
    if (_closing || event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape &&
        (_immersive || _fullscreenRequested)) {
      _background(_setImmersive(false));
      return KeyEventResult.handled;
    }
    final textFocus =
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<EditableText>() !=
        null;
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed &&
        event.logicalKey == LogicalKeyboardKey.keyF) {
      _background(_search());
      return KeyEventResult.handled;
    }
    if (textFocus || _working) return KeyEventResult.ignored;
    if (keyboard.isControlPressed &&
        event.logicalKey == LogicalKeyboardKey.keyZ) {
      _background(_perform(keyboard.isShiftPressed ? _repo.redo : _repo.undo));
      return KeyEventResult.handled;
    }
    if (keyboard.isControlPressed &&
        event.logicalKey == LogicalKeyboardKey.keyY) {
      _background(_perform(_repo.redo));
      return KeyEventResult.handled;
    }
    if (keyboard.isControlPressed &&
        event.logicalKey == LogicalKeyboardKey.keyN) {
      _background(_newTheme());
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.f2 &&
        _workspace.selectedNodeId != null) {
      // 切换视图后焦点可能在工具栏；沿用当前选择的正文编辑入口。
      _selectedAction('edit', selectionAtExecution: true);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.delete &&
        _workspace.selectedNodeId != null) {
      if (keyboard.isControlPressed) {
        final node = _workspace.map?.nodes
            .where((n) => n.id == _workspace.selectedNodeId)
            .firstOrNull;
        if (node != null) {
          _background(_perform(() => _branchAction(node, 'removeTopicOnly')));
        }
      } else {
        _selectedAction('removeSelectedBranches', selectionAtExecution: true);
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _button(IconData icon, String tooltip, VoidCallback? action) =>
      IconButton(
        tooltip: tooltip,
        onPressed: _working || _closing ? null : action,
        icon: OpenNoteIcon(icon, size: 20),
      );

  String? _immersiveSession;

  void _rememberContentFocus() {
    final focus = FocusManager.instance.primaryFocus;
    if (focus != null && focus.ancestors.contains(_contentFocus)) {
      _lastContentFocus = focus;
    }
  }

  void _restoreContentFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_immersive || _closing) return;
      final current = FocusManager.instance.primaryFocus;
      if (current?.ancestors.contains(_contentFocus) == true) return;
      final previous = _lastContentFocus;
      if (previous?.context?.mounted == true &&
          previous!.canRequestFocus &&
          previous.ancestors.contains(_contentFocus)) {
        previous.requestFocus();
      } else {
        _contentFocus.requestFocus();
      }
    });
  }

  Future<void> _setImmersive(bool enabled) {
    _fullscreenRequested = enabled;
    if (enabled) _immersiveSession = _repo.sessionId;
    _fullscreenRequests++;
    if (mounted) setState(() {});
    final operation = _fullscreenTail.then((_) async {
      if (enabled && (!mounted || _closing)) return;
      if (_immersive == enabled) return;
      final actual = await _window.setFullscreen(enabled);
      _immersive = actual;
      _immersiveHintTimer?.cancel();
      _immersiveHint = actual;
      if (mounted) {
        setState(() {});
        // 隐藏入口后焦点回到内容，不留在离屏的顶栏按钮上。
        if (actual) _restoreContentFocus();
        if (actual) {
          _immersiveHintTimer = Timer(const Duration(milliseconds: 1500), () {
            if (mounted) setState(() => _immersiveHint = false);
          });
        }
      }
    });
    _fullscreenTail = operation.catchError((Object _) {});
    return operation.whenComplete(() {
      _fullscreenRequests--;
      if (_fullscreenRequests == 0) _fullscreenRequested = _immersive;
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) => FocusScope(
    autofocus: true,
    onKeyEvent: _key,
    child: Scaffold(
      key: _scaffold,
      drawer: Drawer(width: 260, child: SafeArea(child: _library())),
      body: Stack(
        children: [
          Column(
            children: [
              Offstage(
                offstage: _immersive,
                child: ExcludeFocus(excluding: _immersive, child: _toolbar()),
              ),
              Expanded(
                child: FocusScope(
                  node: _contentFocus,
                  child: WorkbenchLayout(
                    immersive: _immersive,
                    libraryVisible: _libraryVisible,
                    library: _library(),
                    panesBuilder: _panes,
                    editor: _editorVisible ? _cardEditor() : null,
                  ),
                ),
              ),
            ],
          ),
          if (_workspace.error != null)
            Positioned(
              left: 16,
              right: 16,
              top: _immersive ? 16 : 64,
              child: Semantics(
                liveRegion: true,
                child: Material(
                  key: const ValueKey('workspace-error'),
                  color: const Color(0xffffeded),
                  child: Row(
                    children: [
                      const SizedBox(width: 12),
                      const OpenNoteIcon(
                        Icons.error_outline,
                        size: 18,
                        color: Colors.red,
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: Text(_workspace.error!, maxLines: 3)),
                      IconButton(
                        tooltip: '关闭错误提示',
                        onPressed: _workspace.clearError,
                        icon: const OpenNoteIcon(Icons.close, size: 16),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (_immersiveHint)
            const Positioned(
              left: 16,
              right: 16,
              bottom: 16,
              child: IgnorePointer(
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: OpenNoteFeedback(message: '按 Esc 退出沉浸式阅读'),
                ),
              ),
            ),
          if (_ocrCompletionVisible)
            Positioned(
              left: 16,
              right: 16,
              bottom: _saveStatus == null ? 16 : 64,
              child: const IgnorePointer(
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: OpenNoteFeedback(
                    key: Key('workspace-ocr-complete-feedback'),
                    message: '文字识别完成',
                  ),
                ),
              ),
            ),
          if (_saveStatus != null &&
              _feedbackCardId == _feedbackTargetCardId &&
              _feedbackSession == _repo.sessionId)
            Positioned(
              left: 16,
              bottom: 16,
              child: IgnorePointer(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: (MediaQuery.sizeOf(context).width - 32).clamp(
                      0,
                      360,
                    ),
                  ),
                  child: OpenNoteFeedback(
                    key: const Key('workspace-save-feedback'),
                    message: _saveStatus!,
                    error: _saveStatus!.startsWith('保存失败'),
                    processing: _saveStatus == '正在保存…',
                    pending: _saveStatus == '待保存…',
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );

  Widget _toolbar() => WorkbenchBar(
    active: !_immersive,
    child: LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 1000;
        final narrow = constraints.maxWidth < 760;
        final veryNarrow = constraints.maxWidth < 480;
        final projectTitle = OpenNoteWindowDrag(
          child: SizedBox(
            width: compact ? 100 : 220,
            child: Tooltip(
              message: _workspace.project?.title ?? '正在打开项目…',
              child: Text(
                _workspace.project?.title ?? '正在打开项目…',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall
                    ?.copyWith(fontSize: 16),
              ),
            ),
          ),
        );
        final leading = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!veryNarrow) _button(Icons.menu, '资料面板', _toggleLibrary),
            const SizedBox(width: 8),
            OpenNoteToolGroup(
              child: IconButton(
                tooltip: '返回项目主页',
                key: const Key('return-project-home'),
                onPressed: _closing
                    ? null
                    : () => _background(widget.onReturnHome()),
                icon: const OpenNoteIcon(Icons.home_outlined, size: 20),
              ),
            ),
            const SizedBox(width: 16),
            projectTitle,
          ],
        );
        final commands = OpenNoteToolGroup(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!narrow)
                _button(
                  Icons.undo,
                  '撤销 Ctrl+Z',
                  _repo.canUndo
                      ? () => _background(_perform(_repo.undo))
                      : null,
                ),
              if (!narrow)
                _button(
                  Icons.redo,
                  '重做 Ctrl+Y',
                  _repo.canRedo
                      ? () => _background(_perform(_repo.redo))
                      : null,
                ),

              _button(
                Icons.search,
                '搜索 Ctrl+F',
                _workspace.project == null
                    ? null
                    : () => _background(_search()),
              ),
              const SizedBox(width: 4),
              IconButton(
                key: const Key('workspace-immersive-reading'),
                tooltip: '沉浸式阅读',
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                icon: const OpenNoteIcon(Icons.fullscreen_rounded, size: 20),
                onPressed:
                    _working ||
                        _closing ||
                        _fullscreenRequests > 0 ||
                        _workspace.project == null
                    ? null
                    : () => _background(_setImmersive(true)),
              ),
              const SizedBox(width: 4),
            ],
          ),
        );
        final views = OpenNoteToolGroup(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!_pdfVisible && _hasOcrActivity) _ocrMenu(),
              if (!narrow)
                PopupMenuButton<_ViewLinkMode>(
                  key: const Key('workspace-view-link-mode'),
                  tooltip: '图文联动：${_viewLinkMode.label}',
                  icon: OpenNoteIcon(_viewLinkMode.icon, size: 20),
                  onSelected: (mode) => setState(() => _viewLinkMode = mode),
                  itemBuilder: (_) => [
                    for (final mode in _ViewLinkMode.values)
                      CheckedPopupMenuItem(
                        value: mode,
                        checked: mode == _viewLinkMode,
                        child: Text(mode.label),
                      ),
                  ],
                ),
              if (!narrow)
                _button(
                  _workspace.revision?.format == DocumentFormat.epub
                      ? Icons.menu_book_outlined
                      : _workspace.revision == null
                      ? Icons.description_outlined
                      : Icons.picture_as_pdf_outlined,
                  '显示 / 收起文档',
                  _togglePdf,
                ),
              if (!narrow)
                _button(Icons.account_tree_outlined, '显示 / 收起脑图', _toggleMap),
              PopupMenuButton<String>(
                key: const Key('workspace-more-actions'),
                tooltip: '资料库操作',
                icon: const OpenNoteIcon(Icons.more_horiz),
                onSelected: (action) {
                  if (action == 'pdf') {
                    _togglePdf();
                    return;
                  }
                  if (action == 'map') {
                    _toggleMap();
                    return;
                  }
                  if (action == 'library') {
                    _toggleLibrary();
                    return;
                  }
                  if (action.startsWith('view-link:')) {
                    setState(
                      () => _viewLinkMode = _ViewLinkMode.values.firstWhere(
                        (mode) => action == 'view-link:${mode.name}',
                      ),
                    );
                    return;
                  }
                  _background(switch (action) {
                    'undo' => _perform(_repo.undo),
                    'redo' => _perform(_repo.redo),
                    'trash' => _trash(),
                    'about' => _about(),
                    'ocr-details' => _ocrDetails(),
                    _ => Future.value(),
                  });
                },
                itemBuilder: (_) => [
                  if (veryNarrow)
                    const PopupMenuItem(value: 'library', child: Text('资料面板')),
                  if (narrow) ...[
                    PopupMenuItem(
                      value: 'undo',
                      enabled: !_working && !_closing && _repo.canUndo,
                      child: const Text('撤销 · Ctrl+Z'),
                    ),
                    PopupMenuItem(
                      value: 'redo',
                      enabled: !_working && !_closing && _repo.canRedo,
                      child: const Text('重做 · Ctrl+Y'),
                    ),
                    const PopupMenuDivider(),
                    CheckedPopupMenuItem(
                      value: 'pdf',
                      checked: _pdfVisible,
                      child: const Text('文档阅读'),
                    ),
                    CheckedPopupMenuItem(
                      value: 'map',
                      checked: _mapVisible,
                      child: const Text('脑图'),
                    ),
                    for (final mode in _ViewLinkMode.values)
                      CheckedPopupMenuItem(
                        value: 'view-link:${mode.name}',
                        checked: mode == _viewLinkMode,
                        child: Text(mode.label),
                      ),
                    const PopupMenuDivider(),
                  ],
                  const PopupMenuItem(value: 'trash', child: Text('当前项目回收站')),
                  if (_currentOcrStatus != null)
                    const PopupMenuItem(
                      value: 'ocr-details',
                      child: Text('文字识别状态'),
                    ),
                  const PopupMenuItem(
                    value: 'about',
                    child: Text('关于 OpenNote'),
                  ),
                ],
              ),
            ],
          ),
        );
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: narrow
              ? Row(
                  children: [
                    leading,
                    const Expanded(
                      child: OpenNoteWindowDrag(child: SizedBox.expand()),
                    ),
                    commands,
                    const SizedBox(width: 12),
                    views,
                  ],
                )
              : Stack(
                  children: [
                    const Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      height: 4,
                      child: OpenNoteWindowDrag(child: SizedBox.expand()),
                    ),
                    const Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      height: 4,
                      child: OpenNoteWindowDrag(child: SizedBox.expand()),
                    ),
                    Positioned.fill(
                      child: Row(children: [leading, const Spacer(), views]),
                    ),
                    // 补偿右侧原生窗口按钮的宽度，让工具组对齐整窗中心。
                    Align(
                      alignment: Alignment.center,
                      child: Padding(
                        padding: const EdgeInsets.only(left: 136),
                        child: commands,
                      ),
                    ),
                  ],
                ),
        );
      },
    ),
  );

  void _toggleLibrary() {
    if (MediaQuery.sizeOf(context).width < 1280) {
      _scaffold.currentState?.openDrawer();
    } else {
      setState(() => _libraryVisible = !_libraryVisible);
    }
  }

  void _togglePdf() => setState(() {
    _pdfVisible = !_pdfVisible;
    if (!_pdfVisible) _mapVisible = true;
  });

  void _toggleMap() => setState(() {
    _mapVisible = !_mapVisible;
    if (!_mapVisible) _pdfVisible = true;
  });

  Widget _library() => WorkspaceLibrary(
    allDocuments: _workspace.documents,
    allMaps: _workspace.maps,
    allCards: _workspace.cards,
    filter: _libraryFilter,
    cardsTab: _cardsTab,
    selectedDocumentId: _workspace.document?.id,
    selectedMapId: _workspace.map?.map.id,
    selectedCardId: _workspace.selectedCardId,
    onImportPdf: _workspace.project == null || _working || _closing
        ? null
        : () => _background(_import()),
    onTabChanged: (value) => setState(() => _cardsTab = value),
    onFilterChanged: (_) => setState(() {}),
    onDocumentSelected: (document) =>
        _background(_perform(() => _workspace.openDocument(document))),
    onMapSelected: (map) =>
        _background(_perform(() => _workspace.selectMap(map.id))),
    onCardSelected: (card) => _background(_perform(() => _selectCard(card))),
    onDocumentAction: (document, action) => _background(
      action == 'rename'
          ? _rename(
              '文档',
              document.title,
              (title) => _repo.renameDocument(document.id, title),
            )
          : _perform(() => _repo.trashDocument(document.id)),
    ),
    onMapAction: (map, action) => _background(
      action == 'rename'
          ? _rename('脑图', map.title, (title) => _repo.renameMap(map.id, title))
          : _perform(() => _repo.trashMap(map.id)),
    ),
    onCardAction: (card, action) => _background(
      _perform(() async {
        if (action == 'place' && _workspace.map != null) {
          await _repo.placeCard(card.id, _workspace.map!.map.id, x: 80, y: 80);
        } else if (action == 'trash') {
          await _repo.trashCard(card.id);
          _reader.clearAfterCardDeletion({card.id});
        }
      }),
    ),
    onNewMap: _workspace.project == null || _working || _closing
        ? null
        : () => _background(_newMap()),
  );

  Widget _panes(double editorInset) => WorkbenchSplit(
    pdfVisible: _pdfVisible,
    mapVisible: _mapVisible,
    fraction: _split,
    // 宽屏编辑只占右侧空间，PDF 不缩窄，脑图仍可点击切换卡片。
    mapTrailingInset: editorInset,
    onChanged: (value) => setState(() => _split = value),
    pdf: _pdfPane(),
    map: _mapPane(),
  );

  Future<void> _changeMapStructure(
    MapSnapshot map,
    String session,
    String value,
  ) async {
    MapSnapshot? committed;
    await _perform(() async {
      _requireMapContext(session, map.map.id);
      if (value == 'organize') {
        await _workspace.autoLayout();
      } else if (value == 'expandAll') {
        await _repo.setMapVisibleDepth(map.map.id, null);
      } else if (value.startsWith('depth:')) {
        await _repo.setMapVisibleDepth(
          map.map.id,
          int.parse(value.substring(6)),
        );
      } else {
        await _repo.setMapLayout(
          map.map.id,
          MapLayoutKind.values.byName(value),
        );
      }
      committed = await _repo.loadMap(map.map.id);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 仓储通知刷新可能晚于命令完成，直接用这次提交的位置计算视口。
      if (mounted &&
          !_outlineVisible &&
          _repo.sessionId == session &&
          _workspace.map?.map.id == map.map.id) {
        _graph.fitAll(snapshot: committed!);
      }
    });
  }

  Future<void> _chooseMapStructure(MapSnapshot map, String session) async {
    await _perform(() async {
      _requireMapContext(session, map.map.id);
    }, selectionOnly: true);
    _requireMapContext(session, map.map.id);
    if (!mounted || _closing) return;
    final kind = await showDialog<MapLayoutKind>(
      context: context,
      builder: (_) => MapStructureDialog(current: map.map.layout),
    );
    if (kind == null || !mounted || _closing) return;
    _requireMapContext(session, map.map.id);
    await _changeMapStructure(map, session, kind.name);
  }

  void _mapStructureAction(String value, MapSnapshot map, String session) =>
      _background(
        value == 'defaultStyle'
            ? _editTopicStyle(session, map.map.id)
            : value == 'moreStructures'
            ? _chooseMapStructure(map, session)
            : value == 'branchStructure'
            ? _editBranchStructure(
                map.nodes.singleWhere((n) => n.id == _workspace.selectedNodeId),
              )
            : _changeMapStructure(map, session, value),
      );

  List<OpenNoteMenuEntry<String>> _mapStructureEntries(MapSnapshot map) => [
    const OpenNoteMenuEntry('organize', '自动整理'),
    const OpenNoteMenuEntry('defaultStyle', '脑图默认格式…'),
    if (_workspace.selectedNodeId != null)
      const OpenNoteMenuEntry('branchStructure', '所选主题分支结构…'),
    const OpenNoteMenuEntry.divider(),
    for (final kind in MapLayoutKind.values.where((k) => !k.extended))
      OpenNoteMenuEntry(
        kind.name,
        kind.label,
        icon: kind == map.map.layout ? Icons.check_rounded : null,
      ),
    const OpenNoteMenuEntry('moreStructures', '更多结构…'),
    const OpenNoteMenuEntry.divider(),
    const OpenNoteMenuEntry('depth:0', '收起全部分支'),
    for (var depth = 1; depth <= 3; depth++)
      OpenNoteMenuEntry('depth:$depth', '展开到第 $depth 层'),
    const OpenNoteMenuEntry('expandAll', '展开全部'),
  ];

  // 大纲页头沿用原入口，画布通过右下角“更多”的侧向子菜单打开同一组命令。
  Widget _mapStructureMenu(
    MapSnapshot map,
    String session,
  ) => PopupMenuButton<String>(
    key: const ValueKey('map-structure-menu'),
    tooltip: '脑图结构与整理',
    enabled: !_working && !_closing,
    icon: const OpenNoteIcon(Icons.auto_awesome_motion_outlined, size: 20),
    onSelected: (value) => _mapStructureAction(value, map, session),
    itemBuilder: (_) => [
      for (final entry in _mapStructureEntries(map))
        if (entry.divider)
          const PopupMenuDivider()
        else
          PopupMenuItem(
            value: entry.value,
            height: MapLayoutKind.values.any((kind) => kind.name == entry.value)
                ? 36
                : kMinInteractiveDimension,
            child: MapLayoutKind.values.any((kind) => kind.name == entry.value)
                ? Row(
                    children: [
                      OpenNoteIcon(
                        entry.icon,
                        size: 18,
                        color: OpenNoteTokens.accent,
                      ),
                      const SizedBox(width: 10),
                      Text(entry.label),
                    ],
                  )
                : Text(entry.label),
          ),
    ],
  );

  Widget _mapPane() {
    final map = _workspace.map;
    if (map == null) {
      return _empty(
        '暂无脑图',
        Icons.account_tree_outlined,
        '新建脑图',
        () => _background(_newMap()),
      );
    }
    final session = _repo.sessionId;
    final content = Column(
      children: [
        Material(
          color: OpenNoteTokens.surface,
          child: SizedBox(
            key: const Key('workspace-map-header'),
            height: 40,
            child: LayoutBuilder(
              builder: (context, constraints) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    if (_workspace.maps.length > 1)
                      Expanded(
                        child: Text(
                          map.map.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      )
                    else
                      const Spacer(),
                    if (_outlineVisible)
                      _button(
                        Icons.add_rounded,
                        '新建主题 Ctrl+N',
                        () => _background(_newTheme()),
                      ),
                    if (_outlineVisible) _mapStructureMenu(map, session),
                    if (_workspace.selectedNodeIds.length > 1)
                      _selectedMenu(map, compact: true)
                    else if (_outlineVisible && _workspace.selectedCard != null)
                      _button(
                        Icons.edit_note,
                        '编辑卡片',
                        () => _background(
                          _perform(() => _selectCard(_workspace.selectedCard!)),
                        ),
                      ),
                    _mapViewSwitcher(compact: constraints.maxWidth < 360),
                  ],
                ),
              ),
            ),
          ),
        ),
        Expanded(
          child: IndexedStack(
            index: _outlineVisible ? 1 : 0,
            children: [
              ExcludeFocus(
                excluding: _outlineVisible,
                child: MindMapPane(
                  key: ValueKey('${_repo.sessionId}:${map.map.id}'),
                  snapshot: map,
                  creationTools: SizedBox(
                    width: 36,
                    height: 36,
                    child: IconButton(
                      key: const ValueKey('map-new-topic'),
                      tooltip: '新建主题 Ctrl+N',
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                      onPressed: _working || _closing
                          ? null
                          : () => _background(_newTheme()),
                      color: OpenNoteTokens.secondary,
                      icon: const OpenNoteIcon(Icons.add, size: 18),
                    ),
                  ),
                  structureMenuEntries: () => _mapStructureEntries(map),
                  onStructureMenuAction: (value) =>
                      _mapStructureAction(value, map, session),
                  imagePathResolver: _imagePath,
                  controller: _graph,
                  canCreate: !_working && !_closing,
                  onTextExcerptDrop:
                      _mapVisible && !_outlineVisible && _pdfVisible
                      ? (drag, position, parent) => _dropTextExcerpt(
                          session,
                          map.map.id,
                          drag,
                          position,
                          parent,
                        )
                      : null,
                  canAcceptTextDrag: (drag) =>
                      !_readerClosing &&
                      !_closing &&
                      _workspace.revision?.id == drag.revisionId,
                  selectedNodeId: _workspace.selectedNodeId,
                  selectedNodeIds: _workspace.selectedNodeIds,
                  onCreateAt: (position) => _background(
                    _newTheme(canvasPosition: position, quickTitle: true),
                  ),
                  onCreateRelatedAt: (position, from) async {
                    late ExcerptResult result;
                    await _perform(() async {
                      _requireMapContext(session, map.map.id);
                      result = await _repo.createAssociatedTopic(
                        map.map.id,
                        PdfPoint(position.dx, position.dy),
                        fromNodeId: from,
                      );
                      _workspace.replaceNodeSelection({
                        result.node.id,
                      }, result.node.id);
                    }, showGlobalProgress: false);
                    return result.node.id;
                  },
                  onCommitTitle: () => _perform(() async {}),
                  onCommitRelationshipLabel: () =>
                      _perform(() async {}, showGlobalProgress: false),
                  onPrepareRelationshipEdit: () => _perform(() async {
                    _requireMapContext(session, map.map.id);
                    _editorFocusIntent++;
                    _workspace.replaceNodeSelection(const {}, null);
                  }, selectionOnly: true),
                  onEditAssociation: (edge) => _editAssociation(session, edge),
                  onCreateBoundaries: (ids) async {
                    late List<String> result;
                    await _perform(() async {
                      _requireMapContext(session, map.map.id);
                      result = await _repo.createBoundaries(map.map.id, ids);
                    }, showGlobalProgress: false);
                    return result;
                  },
                  onCommitBoundaryLabel: () =>
                      _perform(() async {}, showGlobalProgress: false),
                  onEditBoundary: (boundary) =>
                      _editBoundary(session, boundary),
                  onChangeBoundaryRange: (boundary, ids) => _perform(() async {
                    _requireMapContext(session, boundary.mapId);
                    await _repo.updateBoundary(
                      boundary.id,
                      nodeIds: ids,
                      expectedMapId: boundary.mapId,
                      expectedNodeIds: boundary.nodeIds,
                    );
                  }, showGlobalProgress: false),
                  onRemoveBoundary: (boundary) => _perform(() async {
                    _requireMapContext(session, boundary.mapId);
                    await _repo.removeBoundary(
                      boundary.id,
                      expectedMapId: boundary.mapId,
                    );
                  }, showGlobalProgress: false),
                  onCreateSummaries: (ids) async {
                    late List<String> result;
                    await _perform(() async {
                      _requireMapContext(session, map.map.id);
                      result = await _repo.createSummaries(map.map.id, ids);
                      final inserted = await _repo.loadMap(map.map.id);
                      _requireMapContext(session, map.map.id);
                      _workspace.selectInsertedNodes([
                        for (final id in result)
                          inserted.nodes.singleWhere((n) => n.id == id),
                      ]);
                    }, showGlobalProgress: false);
                    return result;
                  },
                  onEditSummary: (summary) => _editSummary(session, summary),
                  onChangeSummaryRange: (summary, ids) => _perform(() async {
                    _requireMapContext(session, summary.mapId);
                    await _repo.updateSummary(
                      summary.id,
                      nodeIds: ids,
                      expectedMapId: summary.mapId,
                      expectedNodeIds: summary.nodeIds,
                    );
                  }, showGlobalProgress: false),
                  onRemoveSummary: (summary) => _perform(() async {
                    _requireMapContext(session, summary.mapId);
                    await _repo.removeSummary(
                      summary.id,
                      expectedMapId: summary.mapId,
                    );
                  }, showGlobalProgress: false),
                  onChangeAssociationStyle: (edge, style) => _perform(() async {
                    _requireMapContext(session, edge.mapId);
                    await _repo.updateAssociation(
                      edge.id,
                      style: style,
                      expectedFromNodeId: edge.fromNodeId,
                      expectedToNodeId: edge.toNodeId,
                    );
                  }, showGlobalProgress: false),
                  onReconnectAssociation: (edge, endpoint, target, anchor) =>
                      _perform(() async {
                        _requireMapContext(session, edge.mapId);
                        await _repo.reconnectAssociation(
                          edge.id,
                          endpoint,
                          target,
                          anchor: anchor,
                          expectedFromNodeId: edge.fromNodeId,
                          expectedToNodeId: edge.toNodeId,
                        );
                      }, showGlobalProgress: false),
                  onClipboardAction: _clipboardAction,
                  onSelectionChanged: (ids, primary) => _background(
                    _perform(() async {
                      _requireMapContext(session, map.map.id);
                      _workspace.replaceNodeSelection(ids, primary);
                    }, selectionOnly: true),
                  ),
                  onSelect: _mapSelect,
                  onToggleSelection: _mapToggleSelection,
                  onActivate: _mapActivate,
                  onClearSelection: () {
                    _editorFocusIntent++;
                    _background(
                      _perform(() async {
                        _requireMapContext(session, map.map.id);
                        _workspace.replaceNodeSelection(const {}, null);
                      }, selectionOnly: true),
                    );
                  },
                  onMove: (id, x, y) => _perform(() async {
                    _requireMapContext(session, map.map.id);
                    await _repo.moveNode(id, x, y);
                  }, showGlobalProgress: false),
                  onMoveGroup: (positions) =>
                      _moveMapGroup(session, map.map.id, positions),
                  onReparent: (id, parent) => _perform(() async {
                    _requireMapContext(session, map.map.id);
                    await _repo.reparentNode(id, parent);
                  }, showGlobalProgress: false),
                  onReparentAt: (id, parent, x, y) => _perform(() async {
                    _requireMapContext(session, map.map.id);
                    await _repo.reparentNode(id, parent, x: x, y: y);
                  }, showGlobalProgress: false),
                  onDropTopic: (source, target, x, y) => _perform(() async {
                    _requireMapContext(session, map.map.id);
                    await _repo.dropTopic(source, target, x: x, y: y);
                  }, showGlobalProgress: false),
                  onAssociate: (a, b) => _perform(() async {
                    await _repo.addAssociation(a, b);
                  }),
                  onRemoveAssociation: (id) =>
                      _background(_perform(() => _repo.removeAssociation(id))),
                  onAction: _mapAction,
                  onToggleCollapsed: _toggleMapCollapsed,
                ),
              ),
              ExcludeFocus(
                excluding: !_outlineVisible,
                child: MapOutlinePane(
                  key: ValueKey('outline:${_repo.sessionId}:${map.map.id}'),
                  snapshot: map,
                  controller: _outline,
                  onCommitTitle: () => _perform(() async {}),
                  onClipboardAction: _clipboardAction,
                  onSelectionChanged: (ids, primary) => _background(
                    _perform(() async {
                      _requireMapContext(session, map.map.id);
                      _workspace.replaceNodeSelection(ids, primary);
                    }, selectionOnly: true),
                  ),
                  selectedNodeId: _workspace.selectedNodeId,
                  selectedNodeIds: _workspace.selectedNodeIds,
                  imagePathResolver: _imagePath,
                  canCreate: !_working && !_closing,
                  onSelect: _mapSelect,
                  onToggleSelection: _mapToggleSelection,
                  onActivate: _mapActivate,
                  onAction: _mapAction,
                  onToggleCollapsed: _toggleMapCollapsed,
                ),
              ),
            ],
          ),
        ),
      ],
    );
    final feedback = _clipboardFeedback;
    // 提示覆盖在脑图区内，不挤压内容、不拦截拖动，也不延续到另一脑图。
    return Stack(
      children: [
        Positioned.fill(child: content),
        if (!_closing &&
            feedback != null &&
            feedback.session == session &&
            feedback.mapId == map.map.id)
          Positioned(
            // 标题行与创作工具组之下，短暂反馈不盖住工具按钮。
            top: 96,
            left: 16,
            right: 16,
            child: IgnorePointer(
              child: Align(
                alignment: Alignment.topRight,
                child: Semantics(
                  liveRegion: true,
                  child: Container(
                    key: const Key('map-clipboard-feedback'),
                    constraints: const BoxConstraints(maxWidth: 320),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: OpenNoteTokens.surface,
                      border: Border.all(color: OpenNoteTokens.border),
                      borderRadius: BorderRadius.circular(8),
                      boxShadow: OpenNoteTokens.floatingShadows,
                    ),
                    child: Text(
                      feedback.message,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _pdfPane() {
    if (!_pdfVisible ||
        _closing ||
        _readerClosing ||
        _workspace.documents.length < 2) {
      _tabDragCursor.hide();
    }
    final revision = _workspace.revision;
    final filePath = _workspace.documentPath;
    final session = _repo.sessionId;
    return Column(
      children: [
        if (_workspace.documents.length > 1)
          SizedBox(
            height: 40,
            child: Row(
              children: [
                Expanded(
                  child: ReorderableListView.builder(
                    key: const Key('workspace-document-tabs'),
                    scrollDirection: Axis.horizontal,
                    buildDefaultDragHandles: false,
                    onReorderStart: (_) => _tabDragCursor.show(
                      context,
                      SystemMouseCursors.grabbing,
                    ),
                    onReorderEnd: (_) => _tabDragCursor.hide(),
                    itemCount: _workspace.openedDocuments.length,
                    onReorderItem: _workspace.reorderDocumentTabs,
                    itemBuilder: (context, index) {
                      final document = _workspace.openedDocuments[index];
                      final selected = document.id == _workspace.document?.id;
                      return Container(
                        key: ValueKey('document-tab-${document.id}'),
                        width: 220,
                        margin: const EdgeInsets.fromLTRB(4, 2, 0, 2),
                        decoration: BoxDecoration(
                          color: selected
                              ? OpenNoteTokens.background
                              : Colors.transparent,
                          border: Border.all(
                            color: selected
                                ? OpenNoteTokens.border
                                : Colors.transparent,
                          ),
                          borderRadius: BorderRadius.circular(7),
                        ),
                        child: Row(
                          children: [
                            ReorderableDragStartListener(
                              key: ValueKey('document-tab-drag-${document.id}'),
                              index: index,
                              child: MouseRegion(
                                cursor: SystemMouseCursors.grab,
                                child: Tooltip(
                                  message: '拖动调整文档标签顺序',
                                  child: Padding(
                                    padding: EdgeInsets.symmetric(
                                      horizontal: 10,
                                    ),
                                    child: OpenNoteIcon(
                                      document.format == DocumentFormat.epub
                                          ? Icons.menu_book_outlined
                                          : Icons.description_outlined,
                                      size: 18,
                                      color: OpenNoteTokens.secondary,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            Expanded(
                              child: InkWell(
                                onTap: () => _background(
                                  _perform(
                                    () => _workspace.openDocument(document),
                                  ),
                                ),
                                child: Tooltip(
                                  message: document.title,
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: Text(
                                      document.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: selected
                                            ? FontWeight.w500
                                            : FontWeight.w400,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            IconButton(
                              key: ValueKey(
                                'document-tab-close-${document.id}',
                              ),
                              tooltip: '关闭文档标签',
                              constraints: const BoxConstraints.tightFor(
                                width: 28,
                                height: 28,
                              ),
                              padding: EdgeInsets.zero,
                              icon: const OpenNoteIcon(Icons.close, size: 14),
                              onPressed: _closing
                                  ? null
                                  : () => _background(
                                      _perform(
                                        () => _workspace.closeDocumentTab(
                                          document.id,
                                        ),
                                      ),
                                    ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        if (_workspace.documents.length <= 1 &&
            _workspace.document?.format == DocumentFormat.epub)
          SizedBox(
            height: 40,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  OpenNoteIcon(
                    revision?.format == DocumentFormat.epub
                        ? Icons.menu_book_outlined
                        : Icons.description_outlined,
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Tooltip(
                      message: _workspace.document!.title,
                      child: Text(
                        _workspace.document!.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          color: OpenNoteTokens.secondary,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        Expanded(
          key: const Key('workspace-pdf-content'),
          child: revision == null || filePath == null
              ? _empty(
                  '暂无资料',
                  Icons.description_outlined,
                  '添加文档',
                  _workspace.project == null
                      ? null
                      : () => _background(_import()),
                )
              : revision.format == DocumentFormat.epub
              ? EpubReaderPane(
                  key: ValueKey('$session:${revision.id}'),
                  revisionId: revision.id,
                  filePath: filePath,
                  sessionId: session,
                  title: _workspace.document?.title ?? 'EPUB',
                  controller: _reader,
                  onProbeReady: widget.onEpubReady,
                  closing: _readerClosing,
                  initialPosition: _workspace.readingPosition,
                  annotations: _workspace.annotations,
                  completedSections: _workspace.epubIndexedSections,
                  enableTextDrag:
                      !_working &&
                      !_closing &&
                      !_readerClosing &&
                      _mapVisible &&
                      !_outlineVisible,
                  textDragContext: (
                    session,
                    _workspace.project?.id,
                    _workspace.map?.map.id,
                    revision.id,
                    _mapVisible,
                    _outlineVisible,
                    _pdfVisible,
                  ),
                  onExcerpt: (value) =>
                      _background(_perform(() => _workspace.addExcerpt(value))),
                  onIndexSection: (data) => _repo.saveEpubSection(
                    revision.id,
                    data,
                    sessionId: session,
                  ),
                  onReadingPositionChanged: (value) =>
                      _background(_workspace.updateReadingPosition(value)),
                  onAnnotationCreated: (value) => _background(
                    _perform(() async {
                      if (_repo.sessionId != session) return;
                      await _repo.createAnnotation(
                        anchor: AnchorDraft(
                          revisionId: value.revisionId,
                          epubLocator: value.epubLocator,
                        ),
                        kind: value.kind,
                        text: value.text,
                        color: value.color,
                      );
                    }),
                  ),
                  onAnnotationActivated: (value) =>
                      _background(_perform(() => _annotation(value))),
                  onImageOcr: (value) async => (await _ocr.enqueueEpubImage(
                    revisionId: revision.id,
                    locator: value.anchors.first.epubLocator!,
                    image: value.imageBytes!,
                  )).text,
                  onImageOcrCancel: () => _ocr.cancelEpubImages(revision.id),
                  onSearch: () => _background(_search()),
                  onEscape: () {
                    if (_immersive) _background(_setImmersive(false));
                  },
                  onInitialPageReady: () {
                    if (_repo.sessionId == session &&
                        _workspace.document?.activeRevisionId == revision.id) {
                      _background(
                        _workspace.persistResume(
                          successfullyReadDocumentId: _workspace.document!.id,
                        ),
                      );
                    }
                  },
                )
              : ReaderPane(
                  key: ValueKey('$session:${revision.id}'),
                  revisionId: revision.id,
                  filePath: filePath,
                  title: _workspace.document?.title ?? 'PDF',
                  controller: _reader,
                  closing: _readerClosing,
                  documentActions: _showOcrEntry ? _ocrMenu() : null,
                  initialPdfSettings: _workspace.pdfReadingSettings,
                  onPdfSettingsChanged: (value) => _background(
                    _workspace.updatePdfReadingSettings(
                      revision.id,
                      value,
                      sessionId: session,
                    ),
                  ),
                  excerptTargetLabel: _excerptTargetLabel,
                  enableTextDrag:
                      !_working &&
                      !_closing &&
                      !_readerClosing &&
                      _mapVisible &&
                      !_outlineVisible,
                  textDragContext: (
                    session,
                    _workspace.project?.id,
                    _workspace.map?.map.id,
                    revision.id,
                    _mapVisible,
                    _outlineVisible,
                    _pdfVisible,
                  ),
                  pageGeometry: revision.pageGeometry,
                  textLayers: _workspace.textLayers,
                  annotations: _workspace.annotations,
                  initialPosition: _workspace.readingPosition,
                  onInitialPageReady: () {
                    if (_repo.sessionId == session &&
                        _workspace.document?.activeRevisionId == revision.id) {
                      _background(
                        _workspace.persistResume(
                          successfullyReadDocumentId: _workspace.document!.id,
                        ),
                      );
                    }
                    if (_initialPdfReported) return;
                    _initialPdfReported = true;
                    widget.onInitialPdfReady?.call();
                  },
                  onExcerpt: (value) =>
                      _background(_perform(() => _workspace.addExcerpt(value))),
                  onNativeTextLayer: (value) =>
                      _workspace.saveNativeLayer(value, session),
                  onTextLayerRequested: (page) async {
                    if (_repo.sessionId != session) return [];
                    final layers = await _repo.loadTextLayers(
                      revision.id,
                      pageIndices: [page],
                    );
                    return _repo.sessionId == session ? layers : [];
                  },
                  onIndexingRequested: (page) => _background(
                    _ocr.enqueueRevision(
                      revision.id,
                      priorityPage: page,
                      retryIncomplete: false,
                    ),
                  ),
                  onReadingPageChanged: (page) {
                    if (_repo.sessionId == session) {
                      _ocr.prioritizeReadingPage(revision.id, page);
                    }
                  },
                  onAnnotationCreated: (value) => _background(
                    _perform(() async {
                      if (_repo.sessionId != session) return;
                      await _repo.createAnnotation(
                        anchor: AnchorDraft(
                          revisionId: value.revisionId,
                          pageIndex: value.pageIndex,
                          quads: value.quads,
                        ),
                        kind: value.kind,
                        text: value.text,
                        color: value.color,
                      );
                    }),
                  ),
                  onAnnotationActivated: (value) =>
                      _background(_perform(() => _annotation(value))),
                  onReadingPositionChanged: (value) =>
                      _background(_workspace.updateReadingPosition(value)),
                  onGeometryLoaded: (geometry) {
                    if (_repo.sessionId == session) {
                      _background(
                        _repo.setRevisionMetadata(
                          revision.id,
                          pageCount: geometry.length,
                          pageGeometry: geometry,
                        ),
                      );
                    }
                  },
                ),
        ),
      ],
    );
  }

  Widget _cardEditor() {
    final card = _editorCard;
    if (card == null) return CardEditorPlaceholder(onClose: _closeEditor);
    final session = _repo.sessionId;
    final sourceKey = '$session:${card.id}';
    final map = _workspace.map;
    if (_editorSource?.key != sourceKey ||
        !identical(_editorSource?.map, map)) {
      // 当前脑图已有完整来源快照；未放入脑图的卡片按真实锚点查询。
      _editorSource = (
        key: sourceKey,
        map: map,
        available: map?.cards.containsKey(card.id) == true
            ? Future.value((map!.anchors[card.id] ?? const []).isNotEmpty)
            : _repo.getAnchors(card.id).then((anchors) => anchors.isNotEmpty),
      );
    }
    return CardEditor(
      key: ValueKey('${_repo.sessionId}:${card.id}'),
      card: card,
      controller: _editor,
      sourceAvailable: _editorSource!.available,
      autofocusBody: card.id == _newThemeCardId,
      imagePath: card.imageResourceId == null
          ? null
          : _imagePath(card.imageResourceId!),
      onSave: (title, body, thoughts) async {
        if (_repo.sessionId != session ||
            _workspace.project?.id != card.projectId) {
          throw StateError('目标资料库已切换，请重新选择卡片');
        }
        await _repo.updateCard(
          card.id,
          title: title,
          body: body,
          thoughts: thoughts,
        );
      },
      onColorChanged: (color) => _changeEditorColor(session, card.id, color),
      onBackToSource: () => _background(
        _perform(() async {
          _requireEditorContext(session, card.id);
          await _source(
            card,
            requireContext: () => _requireEditorContext(session, card.id),
          );
        }),
      ),
      onSaveState: (status) => _showSaveFeedback(card.id, session, status),
      onClose: _closeEditor,
    );
  }

  Widget _empty(
    String title,
    IconData icon,
    String button,
    VoidCallback? action,
  ) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: OpenNoteTokens.surface,
            border: Border.all(color: OpenNoteTokens.border),
            borderRadius: BorderRadius.circular(12),
          ),
          child: OpenNoteIcon(icon, size: 28, color: OpenNoteTokens.accent),
        ),
        const SizedBox(height: 16),
        Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w500,
            color: OpenNoteTokens.secondary,
          ),
        ),
        const SizedBox(height: 18),
        FilledButton.tonal(onPressed: action, child: Text(button)),
      ],
    ),
  );

  void _showSaveFeedback(String cardId, String session, String status) {
    if (!mounted ||
        cardId != _feedbackTargetCardId ||
        session != _repo.sessionId) {
      return;
    }
    _saveFeedbackTimer?.cancel();
    setState(() {
      _feedbackCardId = cardId;
      _feedbackSession = session;
      _saveStatus = status;
    });
    if (status == '资料已保存') {
      _saveFeedbackTimer = Timer(const Duration(milliseconds: 1500), () {
        if (mounted &&
            _feedbackCardId == cardId &&
            _feedbackSession == session) {
          setState(() => _saveStatus = null);
        }
      });
    }
  }

  String get _excerptTargetLabel {
    final map = _workspace.map;
    final parent = map?.nodes
        .where((n) => n.id == _workspace.selectedNodeId)
        .firstOrNull;
    return parent == null ? '顶层' : map!.cards[parent.cardId]?.title ?? '主题';
  }

  Future<void> _about() async => showAboutDialog(
    context: context,
    applicationName: 'OpenNote',
    applicationVersion: '0.1.0',
    children: [const Text('离线文档阅读与知识整理')],
  );

  OcrDocumentStatus? get _currentOcrStatus {
    final revision = _workspace.revision;
    if (revision == null || revision.format != DocumentFormat.pdf) return null;
    return _ocr.statusForRevision(revision.id, pageCount: revision.pageCount);
  }

  bool _ocrReady(OcrDocumentStatus status) =>
      status.isReady && !status.hasActivity && status.error == null;

  bool get _hasOcrActivity => _currentOcrStatus?.hasActivity ?? false;

  bool get _showOcrEntry {
    final status = _currentOcrStatus;
    return status != null && !_ocrReady(status);
  }

  void _updateOcrCompletion() {
    final status = _currentOcrStatus;
    final revision = _workspace.revision;
    final document = status == null || revision == null
        ? null
        : (session: _repo.sessionId, revision: revision.id);
    final ready = status != null && _ocrReady(status);
    if (document != _ocrObservedDocument) {
      _ocrCompletionTimer?.cancel();
      _ocrCompletionVisible = false;
      _ocrObservedDocument = document;
    } else if (ready && !_ocrPreviouslyReady) {
      _ocrCompletionTimer?.cancel();
      _ocrCompletionVisible = true;
      _ocrCompletionTimer = Timer(const Duration(milliseconds: 1800), () {
        if (mounted) setState(() => _ocrCompletionVisible = false);
      });
    } else if (!ready) {
      _ocrCompletionTimer?.cancel();
      _ocrCompletionVisible = false;
    }
    _ocrPreviouslyReady = ready;
  }

  Future<void> _ocrDetails() async {
    final status = _currentOcrStatus;
    if (status == null) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('文字识别状态'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_workspace.document?.title ?? '当前 PDF'),
            const SizedBox(height: 12),
            Text(status.label),
            if (status.error != null) ...[
              const SizedBox(height: 8),
              Text(status.error!),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Widget _ocrMenu() {
    final revision = _workspace.revision;
    if (revision == null || revision.format != DocumentFormat.pdf) {
      return const SizedBox.shrink();
    }
    final session = _repo.sessionId;
    final status = _ocr.statusForRevision(
      revision.id,
      pageCount: revision.pageCount,
    );
    final enabled = !_working && !_closing && !status.isCancelling;
    return PopupMenuButton<String>(
      key: const Key('workspace-ocr-menu'),
      tooltip: status.label,
      icon: status.pendingPages > 0
          ? SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                value: status.progress,
                strokeWidth: 2,
              ),
            )
          : OpenNoteIcon(
              status.failedPages > 0
                  ? Icons.warning_amber
                  : status.cancelledPages > 0
                  ? Icons.pause_circle_outline
                  : status.isReady
                  ? Icons.check_circle_outline
                  : Icons.document_scanner_outlined,
              size: 20,
              color: status.failedPages > 0
                  ? Colors.orange
                  : OpenNoteTokens.secondary,
            ),
      onSelected: (value) {
        if (session != _repo.sessionId ||
            revision.id != _workspace.revision?.id) {
          return;
        }
        _background(switch (value) {
          'retry' => _ocr.retryRevision(
            revision.id,
            status: OcrTaskStatus.failed,
          ),
          'continue' => _ocr.retryRevision(
            revision.id,
            status: OcrTaskStatus.cancelled,
          ),
          'cancel' => _ocr.cancel(revisionId: revision.id),
          _ => Future.value(),
        });
      },
      itemBuilder: (_) => [
        PopupMenuItem<String>(
          enabled: false,
          child: Text(_workspace.document?.title ?? '当前 PDF'),
        ),
        PopupMenuItem<String>(enabled: false, child: Text(status.label)),
        if (status.failedPages > 0)
          PopupMenuItem(
            value: 'retry',
            enabled: enabled,
            child: Text('重试失败页面（${status.failedPages} 页）'),
          ),
        if (status.cancelledPages > 0)
          PopupMenuItem(
            value: 'continue',
            enabled: enabled,
            child: Text('继续处理（${status.cancelledPages} 页）'),
          ),
        if (status.pendingPages > 0)
          PopupMenuItem(
            value: 'cancel',
            enabled: enabled,
            child: const Text('取消处理'),
          ),
        if (status.error != null)
          PopupMenuItem(
            enabled: false,
            child: Text(
              status.error!,
              style: const TextStyle(color: Colors.red),
            ),
          ),
      ],
    );
  }
}
