import '../theme/open_note_icon.dart';
import '../theme/open_note_context_menu.dart';

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/open_note_theme.dart';
import '../theme/open_note_drag_cursor.dart';

import 'package:flutter/scheduler.dart';

import '../theme/open_note_view_switch.dart';

import 'package:flutter/gestures.dart'
    show
        DragStartBehavior,
        PointerDeviceKind,
        PointerPanZoomStartEvent,
        PointerPanZoomUpdateEvent,
        kDoubleTapSlop,
        kDoubleTapTimeout,
        kPrimaryMouseButton;
import 'package:pdfrx/pdfrx.dart';

import '../../domain/models.dart' as model;
import '../../engines/pdf/pdf_read_engine.dart';
import '../../engines/pdf/pdf_text_selection.dart';
import '../../engines/pdf/pdf_excerpt_text.dart';
import 'reader_contract.dart';
import '../theme/open_note_feedback.dart';
import 'reader_scroll_behavior.dart';
import 'reader_viewport_sizing.dart';
import 'reader_page_navigation.dart';
import 'reader_scroll_thumb.dart';
import 'reader_sidebar_divider.dart';
import 'source_highlight.dart';

export 'reader_contract.dart';

enum _ReaderTool { hand, text, rectangle }

enum _ReaderFeedbackKind { processing, success, error }

class ReaderPane extends StatefulWidget {
  const ReaderPane({
    super.key,
    required this.revisionId,
    required this.filePath,
    required this.onExcerpt,
    this.controller,
    this.closing = false,
    this.pageGeometry = const [],
    this.textLayers = const [],
    this.annotations = const [],
    this.initialPosition,
    this.initialPdfSettings = const model.PdfReadingSettings(),
    this.onPdfSettingsChanged,
    this.onNativeTextLayer,
    this.onTextLayerRequested,
    this.onIndexingRequested,
    this.onReadingPageChanged,
    this.onAnnotationCreated,
    this.onAnnotationActivated,
    this.onReadingPositionChanged,
    this.onGeometryLoaded,
    this.onInitialPageReady,
    this.title = 'PDF',
    this.documentActions,
    this.excerptTargetLabel = '顶层',
    this.enableTextDrag = false,
    this.textDragContext,
  });

  final String revisionId;
  final String filePath;
  final String title;
  final Widget? documentActions;
  final String excerptTargetLabel;
  final bool enableTextDrag;
  final Object? textDragContext;
  final void Function(SelectedExcerpt) onExcerpt;
  final ReaderPaneController? controller;
  final bool closing;
  final List<model.PdfPageGeometry> pageGeometry;
  final List<model.PageTextLayer> textLayers;
  final List<model.AppAnnotation> annotations;
  final model.ReadingPosition? initialPosition;
  final model.PdfReadingSettings initialPdfSettings;
  final void Function(model.PdfReadingSettings)? onPdfSettingsChanged;
  final Future<void> Function(model.TextLayerDraft)? onNativeTextLayer;
  final Future<List<model.PageTextLayer>> Function(int pageIndex)?
  onTextLayerRequested;

  /// 打开文档时补齐持久索引；外层须保留已失败或被用户取消的任务。
  final void Function(int pageIndex)? onIndexingRequested;

  /// 恢复阅读位置后及翻页时更新 OCR 优先级，不重复创建全书任务。
  final void Function(int pageIndex)? onReadingPageChanged;

  final void Function(ReaderAnnotationDraft)? onAnnotationCreated;
  final void Function(model.AppAnnotation)? onAnnotationActivated;
  final void Function(model.ReadingPosition)? onReadingPositionChanged;
  final void Function(List<model.PdfPageGeometry>)? onGeometryLoaded;
  final VoidCallback? onInitialPageReady;

  @override
  State<ReaderPane> createState() => _ReaderPaneState();
}

class _ReaderPaneState extends State<ReaderPane>
    with SingleTickerProviderStateMixin {
  final _viewer = PdfViewerController();
  final _scrollBehavior = ReaderScrollBehavior();
  final _viewportSizing = ReaderViewportSizing();
  late PdfDocumentRef _documentRef;
  Future<PdfDocument>? _openingDocument;
  final _closingDocuments = <Future<void>>{};
  final _pageInput = TextEditingController(text: '1');
  final _nativeLayers = <int, _LayerView>{};
  final _persistedLayers =
      <(int, model.TextLayerSource), model.PageTextLayer>{};
  final _layerRequests = <int, Future<void>>{};
  final _cacheAge = <int, int>{};
  int _cacheClock = 0;
  final _loadingLayers = <int, Future<void>>{};
  final _emptyNativePages = <int>{};
  List<model.PdfPageGeometry> _geometry = [];
  List<PdfOutlineNode> _outline = [];
  List<model.AnchorDraft> _sourceHighlights = [];
  late final AnimationController _sourceFade;
  Timer? _sourceHold;
  ReaderSourceRequest? _highlightRequest;
  List<model.AnchorDraft> _selection = [];
  List<int> _pendingSelectionPages = [];
  final _selectionTapGroup = Object();
  ReaderExcerptDrag? _textDrag;
  int _selectionEpoch = 0;
  bool _draggingText = false;
  final _highlightRanges =
      <
        int,
        ({
          List<model.TextFragment> fragments,
          Rect pageRect,
          Map<Rect, HighlightTextRange> ranges,
        })
      >{};
  PdfDocument? _document;
  _ReaderTool _tool = _ReaderTool.text;
  _TextPoint? _textStart;
  _TextPoint? _textEnd;
  Offset? _rectangleStart;
  Rect? _rectangle;
  int? _rectanglePage;
  int _pageIndex = 0;
  int _prefetchedPage = -1;
  int _generation = 0;
  final _contextMenuController = OpenNoteContextMenuController();
  int _sidebarTab = 0;
  bool _sidebarVisible = false;
  bool _sidebarAsDrawer = false;
  final _sidebarFocus = FocusScopeNode(debugLabel: 'PDF 目录抽屉');
  bool _sidebarFocusScheduled = false;
  double _sidebarWidth = 220;
  final _collapsedOutline = <PdfOutlineNode>{};
  bool _draggingStartHandle = false;
  double _trackpadScale = 1;
  Offset? _doubleTapPosition;
  Timer? _doubleTapTimer;
  bool _busy = false;
  bool _initialPageReadySent = false;
  bool _navigationReady = false;
  int _outlineNavigationRequest = 0;
  ({int pageNumber, Matrix4 matrix})? _outlineViewport;
  bool _indexingRequested = false;
  int? _prioritizedPage;
  String? _error;
  String? _status = '正在打开文档…';
  _ReaderFeedbackKind _feedbackKind = _ReaderFeedbackKind.processing;
  Timer? _feedbackTimer;
  Timer? _positionTimer;
  Timer? _edgeScrollTimer;
  Offset? _dragPoint;
  final _dragCursor = OpenNoteDragCursor();
  final _hoverCursor = ValueNotifier<MouseCursor>(SystemMouseCursors.basic);
  Offset? _hoverPosition;
  bool _primaryDown = false;
  bool _hoverRefreshScheduled = false;
  final _hoverLinks = <int, List<PdfLink>>{};
  final _hoverLinkRequests = <int>{};
  final _hoverAreas = <int, ({Object layer, Rect page, List<Rect> areas})>{};

  @override
  void initState() {
    super.initState();
    _restoreSidebarSettings();
    _sourceFade =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 300),
        )..addListener(() {
          if (_viewer.isReady) _viewer.invalidate();
        });
    if (!widget.closing) _openDocument();
    _rememberTextLayers();
    _attachController();
    _viewer.addListener(_positionChanged);
  }

  @override
  void didUpdateWidget(ReaderPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enableTextDrag != widget.enableTextDrag ||
        oldWidget.textDragContext != widget.textDragContext) {
      _cancelTextDrag();
    }
    if (oldWidget.controller != widget.controller) {
      _detachController(oldWidget.controller);
      _attachController();
    }
    if (oldWidget.revisionId != widget.revisionId ||
        oldWidget.filePath != widget.filePath ||
        oldWidget.closing != widget.closing) {
      if (oldWidget.revisionId != widget.revisionId ||
          oldWidget.filePath != widget.filePath) {
        _restoreSidebarSettings();
      }
      _contextMenuController.cancel();
      _releaseDocument(oldWidget.controller);
      _resetDocumentState();
      _attachController();
      if (!widget.closing) _openDocument();
    }
    if (oldWidget.textLayers != widget.textLayers ||
        oldWidget.annotations != widget.annotations) {
      _rememberTextLayers();
      if (_textStart != null && _textEnd != null) {
        _updateTextSelection(userChange: false);
      }
      if (!widget.closing && _viewer.isReady) _viewer.invalidate();
      _refreshHoverCursor();
    }
  }

  void _resetDocumentState() {
    _cancelTextDrag();
    _dragCursor.hide();
    _primaryDown = false;
    _hoverPosition = null;
    _hoverCursor.value = SystemMouseCursors.basic;
    _hoverLinks.clear();
    _hoverLinkRequests.clear();
    _hoverAreas.clear();
    _highlightRanges.clear();
    _scrollBehavior.stop();
    _generation++;
    _doubleTapTimer?.cancel();
    _positionTimer?.cancel();
    _edgeScrollTimer?.cancel();
    _dragPoint = null;
    _document = null;
    _nativeLayers.clear();
    _persistedLayers.clear();
    _layerRequests.clear();
    _cacheAge.clear();
    _loadingLayers.clear();
    _emptyNativePages.clear();
    _geometry = [];
    _outline = [];
    _outlineViewport = null;
    _collapsedOutline.clear();
    _selection = [];
    _pendingSelectionPages = [];
    _sourceHighlights = [];
    _sourceHold?.cancel();
    _sourceFade.stop();
    _highlightRequest = null;
    _textStart = null;
    _textEnd = null;
    _rectangleStart = null;
    _rectangle = null;
    _rectanglePage = null;
    _busy = false;
    _initialPageReadySent = false;
    _navigationReady = false;
    _indexingRequested = false;
    _prioritizedPage = null;
    _error = null;
    _feedback('正在打开文档…', _ReaderFeedbackKind.processing);
    _pageIndex = 0;
    _pageInput.text = '1';
    _prefetchedPage = -1;
  }

  void _attachController() {
    widget.controller?.activateRevision(widget.revisionId);
    widget.controller?.jumpToAnchorsDelegate = _jumpToAnchors;
    widget.controller?.currentZoomDelegate = _currentZoom;
    widget.controller?.goToPageDelegate = _goToPage;
    widget.controller?.clearHighlightsDelegate = _clearHighlights;
    widget.controller?.clearSelectionDelegate = _clearSelection;
    for (final closing in _closingDocuments) {
      widget.controller?.trackClosedDocument(closing);
    }
  }

  double? _currentZoom() =>
      !widget.closing && _viewer.isReady && _navigationReady
      ? _viewer.currentZoom
      : null;

  void _openDocument() {
    final filePath = widget.filePath;
    final opening = _openFile(filePath);
    _openingDocument = opening;
    // 文件路径/修订相同也不能共享另一个 Reader 的关闭所有权。
    _documentRef = PdfDocumentRefByLoader(
      (_) => opening,
      key: PdfDocumentRefKey(filePath, [Object()]),
      autoDispose: false,
    );
    // Viewer 会显示打开错误；若尚未装载 Viewer 就卸载，也要观察这个 Future。
    unawaited(opening.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
  }

  Future<PdfDocument> _openFile(String filePath) async {
    await pdfrxFlutterInitialize();
    return PdfDocument.openFile(filePath, useProgressiveLoading: true);
  }

  void _releaseDocument(ReaderPaneController? controller) {
    final opening = _openingDocument;
    if (opening == null) return;
    _openingDocument = null;
    final closing = _closeOpeningDocument(opening);
    _closingDocuments.add(closing);
    controller?.trackClosedDocument(closing);
    if (widget.controller != controller) {
      widget.controller?.trackClosedDocument(closing);
    }
    unawaited(
      closing.then<void>(
        (_) {
          _closingDocuments.remove(closing);
        },
        onError: (Object _, StackTrace _) {
          // 控制器保留并传播真实错误；State 不累计已完成的文档 Future。
          _closingDocuments.remove(closing);
        },
      ),
    );
  }

  Future<void> _closeOpeningDocument(Future<PdfDocument> opening) async {
    final PdfDocument document;
    try {
      document = await opening;
    } catch (_) {
      // 打开失败没有取得原生文档，不能让关闭/恢复一直等待不存在的资源。
      return;
    }
    await document.dispose();
  }

  void _detachController(ReaderPaneController? controller) {
    // key 切换时，新 State 可能已绑定同一个控制器；旧 State 只解除自己的回调。
    if (controller?.jumpToAnchorsDelegate == _jumpToAnchors) {
      controller?.jumpToAnchorsDelegate = null;
    }
    if (controller?.goToPageDelegate == _goToPage) {
      controller?.goToPageDelegate = null;
    }
    if (controller?.clearHighlightsDelegate == _clearHighlights) {
      controller?.clearHighlightsDelegate = null;
    }
    if (controller?.currentZoomDelegate == _currentZoom) {
      controller?.currentZoomDelegate = null;
    }
    if (controller?.clearSelectionDelegate == _clearSelection) {
      controller?.clearSelectionDelegate = null;
    }
  }

  @override
  void deactivate() {
    _cancelTextDrag();
    super.deactivate();
  }

  @override
  void dispose() {
    _contextMenuController.cancel();
    _cancelTextDrag();
    _dragCursor.hide();
    _hoverCursor.dispose();
    _generation++;
    _feedbackTimer?.cancel();
    _doubleTapTimer?.cancel();
    _sourceHold?.cancel();
    _sourceFade.dispose();
    _releaseDocument(widget.controller);
    _document = null;
    _positionTimer?.cancel();
    _edgeScrollTimer?.cancel();
    _viewer.removeListener(_positionChanged);
    _detachController(widget.controller);
    _pageInput.dispose();
    _sidebarFocus.dispose();
    super.dispose();
  }

  Future<void> _ready(
    PdfDocument document,
    PdfViewerController controller,
  ) async {
    final generation = ++_generation;
    _document = document;
    try {
      final geometry = widget.pageGeometry.length == document.pages.length
          ? widget.pageGeometry
          : await PdfReadEngine.loadGeometry(
              document,
              filePath: widget.filePath,
            );
      if (!mounted || generation != _generation) return;
      _geometry = geometry;
      widget.onGeometryLoaded?.call(geometry);
      final outline = await PdfReadEngine.loadOutline(
        document,
        filePath: widget.filePath,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _outline = outline;
        _feedback(null);
        _error = null;
      });
      final position = widget.initialPosition;
      if (position != null && position.revisionId == widget.revisionId) {
        await _goToPage(position.pageIndex, consumePending: false);
        if (!mounted || generation != _generation) return;
        final pageRect =
            _viewer.layout.pageLayouts[position.pageIndex.clamp(
              0,
              document.pages.length - 1,
            )];
        await _viewer.goToPosition(
          documentOffset: Offset(
            _viewer.visibleRect.left,
            pageRect.top + position.offset * pageRect.height,
          ),
        );
      }
      if (!mounted || generation != _generation) return;
      // 先完成旧阅读位置恢复，再取最新回源意图，避免较晚恢复覆盖用户的新跳转。
      _navigationReady = true;
      final pendingSource = widget.controller?.pendingSourceRequest;
      final pendingPage = widget.controller?.pendingPageIndex;
      if (pendingSource != null) {
        await _jumpToAnchors(pendingSource);
      } else if (pendingPage != null) {
        await _goToPage(pendingPage);
      }
      if (!mounted || generation != _generation) return;
      if (!_indexingRequested) {
        _indexingRequested = true;
        _prioritizeReadingPage();
        widget.onIndexingRequested?.call((_viewer.pageNumber ?? 1) - 1);
      }
      // 阅读器只准备当前页附近；完整索引由持久队列负责，包括历史原生文档。
      await _prepareVisibleLayers(generation);
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = '无法建立文档文字/坐标层：$error';
        _feedback('请检查文档，来源坐标未就绪', _ReaderFeedbackKind.error);
      });
    }
  }

  Future<void> _notifyInitialPageReady(
    String revisionId,
    String filePath,
    PdfDocumentRef documentRef,
  ) async {
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted ||
        widget.closing ||
        !identical(_documentRef, documentRef) ||
        widget.revisionId != revisionId ||
        widget.filePath != filePath ||
        _initialPageReadySent) {
      return;
    }
    _initialPageReadySent = true;
    widget.onInitialPageReady?.call();
  }

  void _rememberTextLayers() {
    // 外层只读取可见页附近的层；保留本次阅读已经到达的页，支持连续跨页选文。
    for (final layer in widget.textLayers) {
      if (layer.revisionId == widget.revisionId && layer.isCurrent) {
        _persistedLayers[(layer.pageIndex, layer.source)] = layer;
        _cacheAge[layer.pageIndex] = ++_cacheClock;
      }
    }
    _pruneTextLayers();
  }

  void _pruneTextLayers() {
    final current =
        (_viewer.isReady ? _viewer.pageNumber ?? 1 : _pageIndex + 1) - 1;
    final pinned = <int>{
      current - 1,
      current,
      current + 1,
      ..._selection.map((anchor) => anchor.pageIndex),
      if (_sourceHighlights.isNotEmpty) _sourceHighlights.first.pageIndex,
      if (widget.controller?.pendingAnchors?.isNotEmpty == true)
        widget.controller!.pendingAnchors!.first.pageIndex,
    };
    final start = _textStart;
    final end = _textEnd;
    if (start != null && end != null) {
      for (
        var index = math.min(start.pageIndex, end.pageIndex);
        index <= math.max(start.pageIndex, end.pageIndex);
        index++
      ) {
        pinned.add(index);
      }
    }
    final recent =
        _cacheAge.keys.where((page) => !pinned.contains(page)).toList()
          ..sort((a, b) => _cacheAge[b]!.compareTo(_cacheAge[a]!));
    final retained = {
      ...pinned,
      ...recent.take(math.max(0, 24 - pinned.length)),
    };
    _persistedLayers.removeWhere((key, _) => !retained.contains(key.$1));
    _nativeLayers.removeWhere((key, _) => !retained.contains(key));
    _cacheAge.removeWhere((key, _) => !retained.contains(key));
    _hoverAreas.removeWhere((key, _) => !retained.contains(key));
    _hoverLinks.removeWhere((key, _) => !retained.contains(key));
  }

  Future<void> _requestSavedLayer(int pageIndex) {
    final callback = widget.onTextLayerRequested;
    if (callback == null) return Future.value();
    return _layerRequests.putIfAbsent(pageIndex, () async {
      final generation = _generation;
      try {
        final layers = await callback(pageIndex);
        if (!mounted || generation != _generation) return;
        for (final layer in layers) {
          if (layer.revisionId == widget.revisionId && layer.isCurrent) {
            _persistedLayers[(layer.pageIndex, layer.source)] = layer;
            _cacheAge[layer.pageIndex] = ++_cacheClock;
          }
        }
        _pruneTextLayers();
        if (layers.isNotEmpty) {
          if (_textStart != null && _textEnd != null) {
            _updateTextSelection(userChange: false);
          }
          setState(() {});
        }
      } catch (error) {
        if (mounted && generation == _generation) {
          setState(
            () => _feedback('读取已保存文字层失败：$error', _ReaderFeedbackKind.error),
          );
        }
      } finally {
        if (generation == _generation) _layerRequests.remove(pageIndex);
        if (mounted && generation == _generation) _refreshHoverCursor();
      }
    });
  }

  _LayerView? _layer(int pageIndex) {
    final layers = _persistedLayers.values.where(
      (layer) =>
          layer.pageIndex == pageIndex &&
          layer.isCurrent &&
          layer.revisionId == widget.revisionId,
    );
    final native = layers
        .where(
          (layer) =>
              layer.source == model.TextLayerSource.nativePdf &&
              layer.text.trim().isNotEmpty,
        )
        .firstOrNull;
    if (native != null) return _LayerView.fromPersisted(native);
    final ocr = layers
        .where((layer) => layer.source == model.TextLayerSource.ocr)
        .firstOrNull;
    if (ocr != null) return _LayerView.fromPersisted(ocr);
    return _nativeLayers[pageIndex];
  }

  Future<void> _ensureLayer(int index, int generation) {
    if (_layer(index)?.text.trim().isNotEmpty == true ||
        _persistedLayers.containsKey((index, model.TextLayerSource.ocr))) {
      return Future.value();
    }
    return _loadingLayers.putIfAbsent(index, () async {
      try {
        await _requestSavedLayer(index);
        if (!mounted ||
            generation != _generation ||
            _layer(index)?.id != null ||
            _emptyNativePages.contains(index)) {
          return;
        }
        final document = _document;
        if (document == null || index >= _geometry.length) return;
        final draft = await PdfReadEngine.extractNativeText(
          revisionId: widget.revisionId,
          page: document.pages[index],
          geometry: _geometry[index],
        );
        if (!mounted || generation != _generation) return;
        _nativeLayers[index] = _LayerView.fromDraft(draft);
        _cacheAge[index] = ++_cacheClock;
        _pruneTextLayers();
        if (draft.text.trim().isEmpty) {
          _emptyNativePages.add(index);
        } else {
          await widget.onNativeTextLayer?.call(draft);
        }
        if (mounted && generation == _generation) {
          setState(() {
            if (_feedbackKind == _ReaderFeedbackKind.processing &&
                _pendingSelectionPages.isEmpty &&
                _layer(_pageIndex) != null) {
              _feedback(null);
            }
          });
        }
      } finally {
        // 只保留在途请求；页缓存淘汰后再次打开可重新取得已保存的文字层。
        if (generation == _generation) _loadingLayers.remove(index);
        if (mounted && generation == _generation) _refreshHoverCursor();
      }
    });
  }

  Future<void> _prepareVisibleLayers(int generation) async {
    if (!_viewer.isReady || _geometry.isEmpty) return;
    final index = (_viewer.pageNumber ?? 1) - 1;
    try {
      // 先准备正在阅读的页面，再预读前后页，避免当前页等待邻页取层。
      for (final page in [index, index + 1, index - 1]) {
        if (page < 0 || page >= _geometry.length) continue;
        if (!mounted || generation != _generation) return;
        if ((_viewer.pageNumber ?? 1) - 1 != index) return;
        await _ensureLayer(page, generation);
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(
          () => _feedback('准备本页文字层失败：$error', _ReaderFeedbackKind.error),
        );
      }
    }
  }

  Future<void> _goToPage(int pageIndex, {bool consumePending = true}) async {
    if (widget.closing ||
        !_viewer.isReady ||
        (consumePending && !_navigationReady)) {
      return;
    }
    if (consumePending) widget.controller?.pendingPageIndex = null;
    _outlineViewport = null;
    await _viewer.goToPage(
      pageNumber: pageIndex.clamp(0, _viewer.pageCount - 1) + 1,
      duration: Duration.zero,
    );
  }

  Future<void> _jumpToAnchors(ReaderSourceRequest request) async {
    final controller = widget.controller;
    final generation = _generation;
    if (controller?.isCurrentSource(request) == false) return;
    final valid = request.anchors
        .where(
          (anchor) =>
              anchor.revisionId == widget.revisionId &&
              anchor.pageIndex >= 0 &&
              anchor.pageIndex < _geometry.length,
        )
        .toList();
    if (widget.closing ||
        valid.isEmpty ||
        !_viewer.isReady ||
        !_navigationReady) {
      return;
    }
    controller?.acceptSource(request);
    _outlineViewport = null;
    _sourceHold?.cancel();
    _sourceFade.stop();
    _sourceFade.value = 0;
    final first = valid.first;
    final zoom = request.zoom ?? _viewer.currentZoom;
    final pageRect = _viewer.layout.pageLayouts[first.pageIndex];
    final visible = _viewer.visibleRect;
    var top = pageRect.top;
    var left = visible.left;
    if (first.quads.isEmpty) {
      left = pageRect.left;
    } else {
      final adapter = PdfCoordinateAdapter(_geometry[first.pageIndex]);
      var rect = adapter.quadToEngineRect(first.quads.first);
      for (final quad in first.quads.skip(1)) {
        rect = rect.merge(adapter.quadToEngineRect(quad));
      }
      final target = _viewer.calcRectForRectInsidePage(
        pageNumber: first.pageIndex + 1,
        rect: rect,
      );
      final viewportHeight = _viewer.viewSize.height / zoom;
      final viewportWidth = _viewer.viewSize.width / zoom;
      top =
          target.top -
          (target.height < viewportHeight * .65
              ? viewportHeight / 3
              : 16 / zoom);
      if (target.left < left || target.right > left + viewportWidth) {
        left = target.width <= viewportWidth
            ? target.center.dx - viewportWidth / 2
            : target.left - 16 / zoom;
      }
    }
    // 只平移；适配目标矩形会将短摘录放大，破坏用户阅读比例。
    await _viewer.goToPosition(
      documentOffset: Offset(left, top),
      zoom: zoom,
      duration: Duration.zero,
    );
    if (!mounted ||
        widget.closing ||
        generation != _generation ||
        controller?.isCurrentSource(request) == false) {
      return;
    }
    setState(() {
      _sourceHighlights = valid;
      _highlightRequest = request;
    });
    _sourceHold = Timer(const Duration(milliseconds: 200), () {
      if (!mounted || !identical(_highlightRequest, request)) return;
      _sourceFade.forward(from: 0).whenComplete(() {
        if (mounted && identical(_highlightRequest, request)) {
          _clearHighlights();
        }
      });
    });
    _viewer.invalidate();
  }

  void _clearHighlights() {
    if (!mounted) return;
    _sourceHold?.cancel();
    _sourceFade.stop();
    setState(() {
      _sourceHighlights = [];
      _highlightRequest = null;
    });
    if (_viewer.isReady) _viewer.invalidate();
  }

  void _positionChanged() {
    if (!mounted || widget.closing) return;
    if (_outlineViewport != null && _viewer.value != _outlineViewport!.matrix) {
      if (_viewportSizing.isApplying) {
        // 自动适配仍属于同一次阅读定位，避免整页模式同时显示多页时页码抖动。
        _outlineViewport = (
          pageNumber: _outlineViewport!.pageNumber,
          matrix: _viewer.value.clone(),
        );
      } else {
        _outlineViewport = null;
        // 用户滚动、缩放或其他导航后恢复阅读器原有的自动页码判断。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !widget.closing) setState(() {});
        });
      }
    }
    _refreshHoverCursor();
    _prioritizeReadingPage();
    if (_viewer.isReady && _geometry.isNotEmpty) {
      final index = (_viewer.pageNumber ?? 1) - 1;
      if (_prefetchedPage != index) {
        _prefetchedPage = index;
        _pruneTextLayers();
        unawaited(_prepareVisibleLayers(_generation));
      }
    }
    _positionTimer?.cancel();
    final generation = _generation;
    _positionTimer = Timer(const Duration(milliseconds: 350), () {
      if (!_viewer.isReady ||
          !mounted ||
          widget.closing ||
          generation != _generation) {
        return;
      }
      final index = (_viewer.pageNumber ?? 1) - 1;
      final pageRect = _viewer.layout.pageLayouts[index];
      final offset =
          ((_viewer.visibleRect.top - pageRect.top) / pageRect.height).clamp(
            0.0,
            1.0,
          );
      widget.onReadingPositionChanged?.call(
        model.ReadingPosition(
          revisionId: widget.revisionId,
          pageIndex: index,
          offset: offset,
        ),
      );
    });
  }

  void _prioritizeReadingPage() {
    if (!_indexingRequested || !_viewer.isReady || widget.closing) return;
    final page = (_viewer.pageNumber ?? 1) - 1;
    if (_prioritizedPage == page) return;
    _prioritizedPage = page;
    widget.onReadingPageChanged?.call(page);
  }

  _TextPoint? _textPoint(Offset localOffset, {bool nearest = true}) {
    if (!_viewer.isReady || _geometry.isEmpty) return null;
    final hit = _viewer.getPdfPageHitTestResult(
      localOffset,
      useDocumentLayoutCoordinates: false,
    );
    if (hit == null) return null;
    final index = hit.page.pageNumber - 1;
    final layer = _layer(index);
    if (layer == null || layer.fragments.isEmpty) {
      unawaited(_requestSavedLayer(index));
      return null;
    }
    final box = PdfCoordinateAdapter(_geometry[index]).effectiveBox;
    final point = Offset(hit.offset.x + box.left, hit.offset.y + box.top);
    model.TextFragment? closest;
    var distance = double.infinity;
    for (final fragment in layer.fragments) {
      final rect = PdfCoordinateAdapter.quadBounds(fragment.quad);
      final dx = math.max(
        0.0,
        math.max(rect.left - point.dx, point.dx - rect.right),
      );
      final dy = math.max(
        0.0,
        math.max(rect.top - point.dy, point.dy - rect.bottom),
      );
      final candidate = dx * dx + dy * dy;
      if (candidate < distance) {
        distance = candidate;
        closest = fragment;
      }
    }
    if (closest == null || (!nearest && distance > 0)) return null;
    return _TextPoint(index, closest.start, closest.start + closest.length);
  }

  void _trackpadStart(PointerPanZoomStartEvent event) {
    _scrollBehavior.stop();
    _doubleTapTimer?.cancel();
    _trackpadScale = 1;
  }

  void _trackpadUpdate(PointerPanZoomUpdateEvent event) {
    if (!_viewer.isReady || widget.closing) return;
    final scale = event.scale / _trackpadScale;
    _trackpadScale = event.scale;
    if (scale != 1) {
      _viewer.zoomOnLocalPosition(
        localPosition: event.localPosition,
        newZoom: (_viewer.currentZoom * scale).clamp(.1, 8),
        duration: Duration.zero,
      );
    }
    // 精确触控板已提供逐帧位移及惯性，不再套鼠标滚轮的平滑动画。
    final matrix = _viewer.value.clone();
    matrix.setEntry(0, 3, matrix.storage[12] + event.panDelta.dx);
    matrix.setEntry(1, 3, matrix.storage[13] + event.panDelta.dy);
    _viewer.value = _viewer.makeMatrixInSafeRange(matrix, forceClamp: true);
  }

  void _panStart(DragStartDetails details) {
    if (!_viewer.isReady || _geometry.isEmpty) return;
    _cancelTextDrag();
    _dragCursor.show(
      context,
      _tool == _ReaderTool.text
          ? SystemMouseCursors.text
          : SystemMouseCursors.precise,
    );
    _selectionEpoch++;
    _viewer.requestFocus();
    _doubleTapTimer?.cancel();
    _draggingStartHandle = false;
    _selection = [];
    _pendingSelectionPages = [];
    _dragPoint = details.localPosition;
    if (_tool == _ReaderTool.text) {
      _textStart = _textPoint(details.localPosition);
      _textEnd = _textStart;
      _edgeScrollTimer?.cancel();
      _edgeScrollTimer = Timer.periodic(
        const Duration(milliseconds: 50),
        (_) => _edgeScroll(),
      );
      _updateTextSelection();
      if (_textStart == null) {
        setState(() {
          _feedback('本页文字正在准备，请稍候', _ReaderFeedbackKind.processing);
        });
      }
    } else {
      final hit = _viewer.getPdfPageHitTestResult(
        details.localPosition,
        useDocumentLayoutCoordinates: false,
      );
      if (hit == null) return;
      _rectanglePage = hit.page.pageNumber - 1;
      _rectangleStart = _viewer.localToDocument(details.localPosition);
      _rectangle = Rect.fromPoints(_rectangleStart!, _rectangleStart!);
      setState(() {});
    }
  }

  void _panUpdate(DragUpdateDetails details) {
    _dragPoint = details.localPosition;
    if (_tool == _ReaderTool.text) {
      _textEnd = _textPoint(details.localPosition) ?? _textEnd;
      _updateTextSelection();
    } else if (_rectangleStart != null && _rectanglePage != null) {
      final pageRect = _viewer.layout.pageLayouts[_rectanglePage!];
      _rectangle = Rect.fromPoints(
        _rectangleStart!,
        _viewer.localToDocument(details.localPosition),
      ).intersect(pageRect);
      setState(() {});
      _viewer.invalidate();
    }
  }

  void _panEnd(DragEndDetails details) {
    _dragCursor.hide();
    _edgeScrollTimer?.cancel();
    _dragPoint = null;
    if (_tool == _ReaderTool.text) setState(() {});
    if (_tool == _ReaderTool.rectangle &&
        _rectangle != null &&
        !_rectangle!.isEmpty &&
        _rectanglePage != null) {
      final index = _rectanglePage!;
      final pageRect = _viewer.layout.pageLayouts[index];
      final localRect = _rectangle!.shift(-pageRect.topLeft);
      final quad = PdfCoordinateAdapter(_geometry[index])
          .displayRectToQuad(localRect, _document!.pages[index], pageRect.size);
      setState(() {
        _selection = [
          model.AnchorDraft(
            revisionId: widget.revisionId,
            pageIndex: index,
            quads: [quad],
          ),
        ];
        _feedback(null, _ReaderFeedbackKind.success);
      });
    }
  }

  void _edgeScroll() {
    final point = _dragPoint;
    if (!mounted ||
        point == null ||
        !_viewer.isReady ||
        _tool != _ReaderTool.text) {
      return;
    }
    final height = _viewer.viewSize.height;
    final direction = point.dy < 35 ? -1 : (point.dy > height - 35 ? 1 : 0);
    if (direction == 0 || height <= 0) return;
    final visible = _viewer.visibleRect;
    final maxTop = math.max(0.0, _viewer.documentSize.height - visible.height);
    final top = (visible.top + direction * 16 * visible.height / height).clamp(
      0.0,
      maxTop,
    );
    if ((top - visible.top).abs() < .01) return;
    unawaited(
      _viewer.goToPosition(documentOffset: Offset(visible.left, top)).then((_) {
        if (!mounted || _dragPoint == null) return;
        final point = _textPoint(_dragPoint!);
        if (_draggingStartHandle) {
          _textStart = point ?? _textStart;
        } else {
          _textEnd = point ?? _textEnd;
        }
        _updateTextSelection();
      }),
    );
  }

  void _updateTextSelection({bool userChange = true}) {
    final a = _textStart;
    final b = _textEnd;
    if (a == null || b == null) return;
    if (userChange) {
      _cancelTextDrag();
      _selectionEpoch++;
    }
    final anchors = selectTextAcrossPages(
      revisionId: widget.revisionId,
      a: a,
      b: b,
      layerForPage: _layer,
    );
    if (!userChange &&
        _textDrag != null &&
        anchors.map((a) => a.context).join('\n') != _textDrag!.text) {
      _cancelTextDrag();
      _selectionEpoch++;
    }
    final pending = <int>[];
    for (
      var index = math.min(a.pageIndex, b.pageIndex);
      index <= math.max(a.pageIndex, b.pageIndex);
      index++
    ) {
      final layer = _layer(index);
      final ocrComplete = _persistedLayers.values.any(
        (item) =>
            item.revisionId == widget.revisionId &&
            item.pageIndex == index &&
            item.isCurrent &&
            item.source == model.TextLayerSource.ocr,
      );
      if (layer == null || (layer.text.trim().isEmpty && !ocrComplete)) {
        pending.add(index);
        unawaited(_requestSavedLayer(index));
      }
    }
    setState(() {
      _selection = anchors;
      _pendingSelectionPages = pending;
      _rectangle = null;
      // 被动刷新文字层不清除真实保存错误；用户重新选择或文字未就绪时再更新反馈。
      if (userChange ||
          pending.isNotEmpty ||
          _feedbackKind == _ReaderFeedbackKind.processing) {
        _feedback(
          pending.isEmpty
              ? null
              : '第 ${pending.map((index) => index + 1).join("、")} 页文字尚未就绪',
          _ReaderFeedbackKind.processing,
        );
      }
    });
    _viewer.invalidate();
  }

  bool get _canCopy =>
      !widget.closing &&
      _tool == _ReaderTool.text &&
      _pendingSelectionPages.isEmpty &&
      _selection.any((anchor) => anchor.context.isNotEmpty);

  Future<void> _copySelection() async {
    if (!_canCopy) return;
    final generation = _generation;
    final text = _selection.map((anchor) => anchor.context).join('\n');
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted && generation == _generation) {
        setState(() => _feedback('已复制', _ReaderFeedbackKind.success));
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _feedback('复制失败：$error', _ReaderFeedbackKind.error));
      }
    }
  }

  Future<void> _selectionMenu(Offset globalPosition) async {
    if (!_viewer.isReady || widget.closing) return;
    _viewer.requestFocus();
    final generation = _generation;
    final action = await showOpenNoteContextMenu<String>(
      context: context,
      position: globalPosition,
      controller: _contextMenuController,
      isValid: () => mounted && !widget.closing && generation == _generation,
      entries: [
        OpenNoteMenuEntry(
          'excerpt',
          '摘录',
          icon: Icons.add,
          enabled:
              _selection.isNotEmpty && !_busy && _pendingSelectionPages.isEmpty,
        ),
        OpenNoteMenuEntry(
          'copy',
          '复制选中文字',
          icon: Icons.content_copy,
          shortcut: 'Ctrl+C',
          enabled: _canCopy,
        ),
      ],
    );
    if (!mounted || widget.closing || generation != _generation) return;
    if (action == null) _dismissSelection();
    if (action == 'copy') await _copySelection();
    if (action == 'excerpt') await _excerpt();
  }

  void _selectWord() {
    final position = _doubleTapPosition;
    if (position == null || _tool != _ReaderTool.text) return;
    final point = _textPoint(position, nearest: false);
    if (point == null) return;
    final layer = _layer(point.pageIndex)!;
    // 使用 Flutter 的 Unicode 词边界，不按空格切分中文，也不拆开代理对。
    final painter = TextPainter(
      text: TextSpan(text: layer.text, style: const TextStyle(fontSize: 14)),
      textDirection: TextDirection.ltr,
    )..layout();
    final range = painter.getWordBoundary(TextPosition(offset: point.start));
    painter.dispose();
    _viewer.requestFocus();
    _textStart = _TextPoint(point.pageIndex, range.start, range.start);
    _textEnd = _TextPoint(point.pageIndex, range.end, range.end);
    _updateTextSelection();
  }

  void _tapReader(TapUpDetails details, void Function(Offset) handleLinkTap) {
    _viewer.requestFocus();
    final point = details.localPosition;
    if (_tool == _ReaderTool.text &&
        _doubleTapTimer?.isActive == true &&
        _doubleTapPosition != null &&
        (point - _doubleTapPosition!).distance < kDoubleTapSlop) {
      _doubleTapTimer?.cancel();
      _doubleTapPosition = point;
      _selectWord();
      return;
    }
    _doubleTapPosition = point;
    _doubleTapTimer?.cancel();
    _doubleTapTimer = Timer(kDoubleTapTimeout, () {});
    _clearSelection();
    // 单击批注与链接即时响应；第二次完整点击才升级为选词，拖动不计入双击。
    if (!_activateAnnotation(point)) handleLinkTap(point);
  }

  bool _extendingSelection = false;

  bool get _hasSelection =>
      _selection.isNotEmpty || _textStart != null || _rectangle != null;

  void _dismissSelection() {
    if (!_hasSelection) return;
    _doubleTapTimer?.cancel();
    _doubleTapPosition = null;
    _clearSelection();
  }

  // 选区操作与 PDF 共用点击区域；外部点击继续交给原控件处理。
  Widget _selectionAction(Widget child) =>
      TapRegion(groupId: _selectionTapGroup, child: child);

  void _clearSelection() {
    _cancelTextDrag();
    _selectionEpoch++;
    _edgeScrollTimer?.cancel();
    _dragPoint = null;
    setState(() {
      _textStart = null;
      _textEnd = null;
      _selection = [];
      _pendingSelectionPages = [];
      _rectangleStart = null;
      _rectangle = null;
      _rectanglePage = null;
      _draggingStartHandle = false;
      if (!_busy && _feedbackKind != _ReaderFeedbackKind.error) _feedback(null);
    });
    if (_viewer.isReady) _viewer.invalidate();
  }

  bool? _readerKey(
    PdfViewerKeyHandlerParams params,
    LogicalKeyboardKey key,
    bool isRealKeyPress,
  ) {
    if (key == LogicalKeyboardKey.escape && _textDrag?.started == true) {
      if (isRealKeyPress) setState(_cancelTextDrag);
      return true;
    }
    if (key == LogicalKeyboardKey.escape && _hasSelection) {
      if (isRealKeyPress) _dismissSelection();
      return true;
    }
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed && key == LogicalKeyboardKey.keyC) {
      if (isRealKeyPress && _canCopy) unawaited(_copySelection());
      // 自定义选区清空后不交给底层复制空字符串，保留系统剪贴板。
      return true;
    }
    if (_tool == _ReaderTool.text &&
        _textStart != null &&
        _textEnd != null &&
        keyboard.isShiftPressed &&
        [
          LogicalKeyboardKey.arrowLeft,
          LogicalKeyboardKey.arrowRight,
          LogicalKeyboardKey.arrowUp,
          LogicalKeyboardKey.arrowDown,
          LogicalKeyboardKey.home,
          LogicalKeyboardKey.end,
        ].contains(key)) {
      unawaited(_extendSelection(key));
      return true;
    }
    return null;
  }

  Future<void> _extendSelection(LogicalKeyboardKey key) async {
    if (_extendingSelection || widget.closing) return;
    final end = _textEnd;
    if (end == null) return;
    final generation = _generation;
    _extendingSelection = true;
    try {
      var page = end.pageIndex;
      var layer = _layer(page);
      if (layer == null || layer.fragments.isEmpty) return;
      var offset = end.end.clamp(0, layer.text.length);
      if (key == LogicalKeyboardKey.arrowLeft ||
          key == LogicalKeyboardKey.arrowRight) {
        final forward = key == LogicalKeyboardKey.arrowRight;
        final fragments = layer.fragments;
        final candidates = forward
            ? fragments.where((f) => f.start + f.length > offset)
            : fragments.reversed.where((f) => f.start < offset);
        if (candidates.isNotEmpty) {
          final fragment = candidates.first;
          offset = forward ? fragment.start + fragment.length : fragment.start;
        } else {
          page += forward ? 1 : -1;
          if (page < 0 || page >= _geometry.length) return;
          await _requestSavedLayer(page);
          if (!mounted ||
              generation != _generation ||
              _textEnd != end ||
              widget.closing) {
            return;
          }
          layer = _layer(page);
          if (layer == null || layer.fragments.isEmpty) {
            setState(
              () => _feedback('相邻页文字尚未就绪，请稍后重试', _ReaderFeedbackKind.error),
            );
            return;
          }
          final fragment = forward
              ? layer.fragments.first
              : layer.fragments.last;
          offset = forward ? fragment.start + fragment.length : fragment.start;
        }
      } else {
        final text = layer.text;
        final lineStart = offset == 0
            ? 0
            : text.lastIndexOf('\n', offset - 1) + 1;
        final newline = text.indexOf('\n', offset);
        final lineEnd = newline < 0 ? text.length : newline;
        if (key == LogicalKeyboardKey.home) {
          offset = lineStart;
        } else if (key == LogicalKeyboardKey.end) {
          offset = lineEnd;
        } else if (key == LogicalKeyboardKey.arrowUp) {
          final previousEnd = math.max(0, lineStart - 1);
          final previousStart = previousEnd == 0
              ? 0
              : text.lastIndexOf('\n', previousEnd - 1) + 1;
          offset = math.min(previousStart + offset - lineStart, previousEnd);
        } else {
          final nextStart = math.min(text.length, lineEnd + 1);
          final nextNewline = text.indexOf('\n', nextStart);
          offset = math.min(
            nextStart + offset - lineStart,
            nextNewline < 0 ? text.length : nextNewline,
          );
        }
        // 行移动对齐实际字符范围，避免落在 UTF-16 代理对中间。
        for (final fragment in layer.fragments) {
          if (fragment.start < offset &&
              fragment.start + fragment.length > offset) {
            offset = fragment.start;
            break;
          }
        }
      }
      _textEnd = _TextPoint(page, offset, offset);
      _updateTextSelection();
      if (_selection.isNotEmpty) {
        final anchor = _selection.last;
        final rect = PdfCoordinateAdapter(_geometry[anchor.pageIndex])
            .quadInDocument(
              anchor.quads.last,
              _viewer.pages[anchor.pageIndex],
              _viewer.layout.pageLayouts[anchor.pageIndex],
            )
            .getBounds();
        if (!_viewer.visibleRect.overlaps(rect)) {
          await _viewer.goToPosition(
            documentOffset: Offset(_viewer.visibleRect.left, rect.top),
          );
        }
      }
    } finally {
      _extendingSelection = false;
    }
  }

  List<Widget> _selectionHandles(Size size) {
    if (_tool != _ReaderTool.text ||
        _selection.isEmpty ||
        !_viewer.isReady ||
        _draggingText) {
      return [];
    }
    return [
      for (final start in [true, false])
        Positioned.fill(
          child: AnimatedBuilder(
            animation: _viewer,
            builder: (context, _) {
              if (!_viewer.isReady || _selection.isEmpty) {
                return const SizedBox.shrink();
              }
              final anchor = start ? _selection.first : _selection.last;
              final quad = start ? anchor.quads.first : anchor.quads.last;
              final bounds = PdfCoordinateAdapter(_geometry[anchor.pageIndex])
                  .quadInDocument(
                    quad,
                    _viewer.pages[anchor.pageIndex],
                    _viewer.layout.pageLayouts[anchor.pageIndex],
                  )
                  .getBounds();
              final point = _viewer.documentToLocal(
                start ? bounds.bottomLeft : bounds.bottomRight,
              );
              if (!(Offset.zero & size).contains(point)) {
                return const SizedBox.shrink();
              }
              return Stack(
                children: [
                  Positioned(
                    left: (point.dx - 12).clamp(
                      0.0,
                      math.max(0.0, size.width - 24),
                    ),
                    top: point.dy.clamp(0.0, math.max(0.0, size.height - 24)),
                    child: Semantics(
                      label: start ? '调整选区起点' : '调整选区终点',
                      child: MouseRegion(
                        cursor: SystemMouseCursors.move,
                        child: GestureDetector(
                          key: Key(
                            start
                                ? 'reader-selection-start'
                                : 'reader-selection-end',
                          ),
                          behavior: HitTestBehavior.opaque,
                          onPanStart: (_) {
                            _dragCursor.show(context, SystemMouseCursors.move);
                            _viewer.requestFocus();
                            final first = _selection.first;
                            final last = _selection.last;
                            _textStart = _TextPoint(
                              first.pageIndex,
                              first.textStart!,
                              first.textStart!,
                            );
                            _textEnd = _TextPoint(
                              last.pageIndex,
                              last.textEnd!,
                              last.textEnd!,
                            );
                            _draggingStartHandle = start;
                            _edgeScrollTimer?.cancel();
                            _edgeScrollTimer = Timer.periodic(
                              const Duration(milliseconds: 50),
                              (_) => _edgeScroll(),
                            );
                          },
                          onPanUpdate: (details) {
                            final local = _viewer.globalToLocal(
                              details.globalPosition,
                            );
                            if (local == null) return;
                            _dragPoint = local;
                            final point = _textPoint(local);
                            if (point == null) return;
                            if (start) {
                              _textStart = point;
                            } else {
                              _textEnd = point;
                            }
                            _updateTextSelection();
                          },
                          onPanEnd: (_) {
                            _dragCursor.hide();
                            _edgeScrollTimer?.cancel();
                            setState(() {
                              _dragPoint = null;
                              _draggingStartHandle = false;
                            });
                          },
                          onPanCancel: () {
                            _dragCursor.hide();
                            _edgeScrollTimer?.cancel();
                            setState(() {
                              _dragPoint = null;
                              _draggingStartHandle = false;
                            });
                          },
                          child: SizedBox(
                            width: 24,
                            height: 24,
                            child: Align(
                              alignment: Alignment.topCenter,
                              child: Container(
                                width: 12,
                                height: 16,
                                decoration: const BoxDecoration(
                                  color: OpenNoteTokens.accent,
                                  borderRadius: BorderRadius.all(
                                    Radius.circular(6),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
    ];
  }

  Future<SelectedExcerpt> _prepareTextExcerpt(
    List<model.AnchorDraft> selected,
    int generation,
  ) async {
    // 文本层保存完成后绑定版本 ID；跨页仍保留每页独立的 UTF-16 范围。
    await Future.wait(_loadingLayers.values);
    if (!mounted || widget.closing || generation != _generation) {
      throw const ReaderExcerptDragCancelled();
    }
    await Future.wait(
      selected
          .where((a) => a.textLayerId == null)
          .map((a) => a.pageIndex)
          .toSet()
          .map(_requestSavedLayer),
    );
    if (!mounted || widget.closing || generation != _generation) {
      throw const ReaderExcerptDragCancelled();
    }
    final anchors = selected
        .map(
          (a) => model.AnchorDraft(
            revisionId: a.revisionId,
            pageIndex: a.pageIndex,
            quads: a.quads,
            textLayerId: a.textLayerId ?? _layer(a.pageIndex)?.id,
            textStart: a.textStart,
            textEnd: a.textEnd,
            context: a.context,
          ),
        )
        .toList();
    return SelectedExcerpt(
      text: formatPdfExcerptText(
        anchors: anchors,
        layerForPage: _layer,
        geometryForPage: (index) =>
            index >= 0 && index < _geometry.length ? _geometry[index] : null,
      ),
      anchors: List.unmodifiable(anchors),
    );
  }

  void _cancelTextDrag() {
    _textDrag?.removeListener(_textDragCursorChanged);
    _dragCursor.hide();
    if (_textDrag?.isClaimed == true) _busy = false;
    _textDrag?.cancel();
    _textDrag = null;
    _draggingText = false;
  }

  void _textDragCursorChanged() {
    final drag = _textDrag;
    if (!_draggingText || drag == null || !drag.canAccept) {
      _dragCursor.hide();
      return;
    }
    _dragCursor.update(
      drag.hasDropTarget
          ? SystemMouseCursors.copy
          : SystemMouseCursors.grabbing,
    );
  }

  ReaderExcerptDrag _selectionDrag() {
    if (_textDrag != null) return _textDrag!;
    final generation = _generation;
    final epoch = _selectionEpoch;
    final context = widget.textDragContext;
    final selected = List<model.AnchorDraft>.of(_selection);
    late ReaderExcerptDrag drag;
    bool current() =>
        mounted &&
        !widget.closing &&
        widget.enableTextDrag &&
        generation == _generation &&
        epoch == _selectionEpoch &&
        context == widget.textDragContext;
    drag = ReaderExcerptDrag(
      revisionId: widget.revisionId,
      text: selected.map((a) => a.context).join('\n'),
      anchors: selected,
      sourceIsCurrent: current,
      prepareExcerpt: () async {
        if (!current()) throw const ReaderExcerptDragCancelled();
        setState(() => _busy = true);
        return _prepareTextExcerpt(drag.anchors, generation);
      },
      onCommitted: () {
        if (!current()) return;
        _busy = false;
        _clearSelection();
      },
      onFinished: (error) {
        if (!mounted ||
            generation != _generation ||
            !identical(_textDrag, drag)) {
          return;
        }
        drag.removeListener(_textDragCursorChanged);
        _dragCursor.hide();
        setState(() {
          _busy = false;
          _draggingText = false;
          _textDrag = null;
          if (error != null) {
            _feedback('摘录失败：$error', _ReaderFeedbackKind.error);
          }
        });
      },
    );
    return _textDrag = drag;
  }

  List<Rect> _textHighlightAreas(
    int index,
    Iterable<model.PdfQuad> quads,
    PdfPage page,
    Rect pageRect,
  ) {
    final adapter = PdfCoordinateAdapter(_geometry[index]);
    Rect rect(model.PdfQuad q) =>
        adapter.quadInDocument(q, page, pageRect).getBounds();
    final layer = _layer(index);
    var cached = _highlightRanges[index];
    if (layer != null &&
        (cached == null ||
            !identical(cached.fragments, layer.fragments) ||
            cached.pageRect != pageRect)) {
      cached = (
        fragments: layer.fragments,
        pageRect: pageRect,
        ranges: {
          for (final fragment in layer.fragments)
            rect(fragment.quad): (
              start: fragment.start,
              end: fragment.start + fragment.length,
            ),
        },
      );
      _highlightRanges[index] = cached;
    }
    return mergeTextHighlightRects(
      quads.map(rect),
      vertical: page.rotation.index.isOdd,
      text: layer?.text,
      textRanges: layer == null ? const {} : cached!.ranges,
    );
  }

  List<Widget> _selectionDragRegions(Size size) {
    if (!widget.enableTextDrag ||
        widget.closing ||
        _busy ||
        _tool != _ReaderTool.text ||
        !_canCopy ||
        !_viewer.isReady ||
        _dragPoint != null) {
      return [];
    }
    final drag = _selectionDrag();
    return [
      Positioned.fill(
        child: AnimatedBuilder(
          animation: _viewer,
          builder: (context, _) => Stack(
            children: [
              for (final anchor in _selection)
                for (final rect in _textHighlightAreas(
                  anchor.pageIndex,
                  anchor.quads,
                  _viewer.pages[anchor.pageIndex],
                  _viewer.layout.pageLayouts[anchor.pageIndex],
                ))
                  if (Rect.fromPoints(
                    _viewer.documentToLocal(rect.topLeft),
                    _viewer.documentToLocal(rect.bottomRight),
                  ).overlaps(Offset.zero & size))
                    Positioned.fromRect(
                      rect: Rect.fromPoints(
                        _viewer.documentToLocal(rect.topLeft),
                        _viewer.documentToLocal(rect.bottomRight),
                      ).intersect(Offset.zero & size),
                      child: Listener(
                        onPointerSignal: (event) {
                          _doubleTapTimer?.cancel();
                          _viewer.handlePointerSignalEvent(event);
                        },
                        onPointerPanZoomStart: _trackpadStart,
                        onPointerPanZoomUpdate: _trackpadUpdate,
                        child: MouseRegion(
                          cursor: SystemMouseCursors.grab,
                          child: GestureDetector(
                            onSecondaryTapUp: (details) =>
                                _selectionMenu(details.globalPosition),
                            onTapUp: (_) => _viewer.requestFocus(),
                            child: Draggable<ReaderExcerptDrag>(
                              data: drag,
                              hitTestBehavior: HitTestBehavior.opaque,
                              maxSimultaneousDrags: _draggingText ? 0 : 1,
                              allowedButtonsFilter: (buttons) =>
                                  buttons == kPrimaryMouseButton,
                              dragAnchorStrategy: pointerDragAnchorStrategy,
                              rootOverlay: true,
                              feedback: AnimatedBuilder(
                                animation: drag,
                                builder: (context, _) => drag.canAccept
                                    ? Material(
                                        key: const Key(
                                          'reader-text-drag-preview',
                                        ),
                                        elevation: 2,
                                        shadowColor: const Color(0x241B2C42),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                          side: const BorderSide(
                                            color: OpenNoteTokens.border,
                                          ),
                                        ),
                                        surfaceTintColor: Colors.transparent,
                                        color: Colors.white,
                                        child: ConstrainedBox(
                                          constraints: const BoxConstraints(
                                            maxWidth: 280,
                                          ),
                                          child: Padding(
                                            padding: const EdgeInsets.all(12),
                                            child: Text(
                                              drag.text,
                                              maxLines: 3,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontSize: 14,
                                                color: OpenNoteTokens.text,
                                              ),
                                            ),
                                          ),
                                        ),
                                      )
                                    : const SizedBox.shrink(),
                              ),
                              onDragStarted: () {
                                drag.start();
                                drag.addListener(_textDragCursorChanged);
                                _dragCursor.show(
                                  context,
                                  SystemMouseCursors.grabbing,
                                );
                                _doubleTapTimer?.cancel();
                                _viewer.requestFocus();
                                setState(() => _draggingText = true);
                              },
                              onDragUpdate: (_) => _textDragCursorChanged(),
                              onDragEnd: (details) {
                                drag.removeListener(_textDragCursorChanged);
                                _dragCursor.hide();
                                if (!details.wasAccepted) drag.cancel();
                                if (mounted && identical(_textDrag, drag)) {
                                  setState(() {
                                    _draggingText = false;
                                    if (!details.wasAccepted) _textDrag = null;
                                  });
                                }
                              },
                              child: const SizedBox.expand(),
                            ),
                          ),
                        ),
                      ),
                    ),
            ],
          ),
        ),
      ),
    ];
  }

  Future<void> _excerpt() async {
    if (_selection.isEmpty || _busy || _pendingSelectionPages.isNotEmpty) {
      return;
    }
    final generation = _generation;
    final selected = List<model.AnchorDraft>.of(_selection);
    final callback = widget.onExcerpt;
    setState(() {
      _busy = true;
    });
    try {
      if (_tool == _ReaderTool.rectangle &&
          _rectanglePage != null &&
          _rectangle != null) {
        final index = _rectanglePage!;
        final pageRect = _viewer.layout.pageLayouts[index];
        final rect = _rectangle!;
        final normalized = Rect.fromLTRB(
          (rect.left - pageRect.left) / pageRect.width,
          (rect.top - pageRect.top) / pageRect.height,
          (rect.right - pageRect.left) / pageRect.width,
          (rect.bottom - pageRect.top) / pageRect.height,
        );
        final bytes = await PdfReadEngine.captureRect(
          _document!.pages[index],
          normalized,
        );
        if (!mounted || generation != _generation) return;
        callback(
          SelectedExcerpt(text: '', imageBytes: bytes, anchors: selected),
        );
      } else {
        callback(await _prepareTextExcerpt(selected, generation));
      }
      if (mounted && generation == _generation) {
        setState(() {
          _feedback(null, _ReaderFeedbackKind.success);
        });
      }
    } catch (error) {
      if (mounted &&
          generation == _generation &&
          error is! ReaderExcerptDragCancelled) {
        setState(() {
          _feedback('摘录失败：$error', _ReaderFeedbackKind.error);
        });
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Future<void> _annotate({bool note = false}) async {
    if (_selection.isEmpty ||
        _pendingSelectionPages.isNotEmpty ||
        widget.onAnnotationCreated == null) {
      return;
    }
    final generation = _generation;
    final selected = List<model.AnchorDraft>.of(_selection);
    final callback = widget.onAnnotationCreated!;
    var text = '';
    if (note) {
      final input = TextEditingController();
      final route = DialogRoute<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('添加文字批注'),
          content: TextField(controller: input, autofocus: true, maxLines: 4),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, input.text),
              child: const Text('保存'),
            ),
          ],
        ),
      );
      final result = await Navigator.of(context).push(route);
      // 路由结果先于退出动画返回，等覆盖层真正移除后才释放输入控制器。
      await route.completed;
      input.dispose();
      if (result == null || !mounted || generation != _generation) return;
      text = result;
    }
    for (final anchor in selected) {
      callback(
        ReaderAnnotationDraft(
          revisionId: anchor.revisionId,
          pageIndex: anchor.pageIndex,
          quads: anchor.quads,
          kind: note ? 'note' : 'highlight',
          text: text,
        ),
      );
    }
  }

  bool _activateAnnotation(Offset localPosition) {
    final annotation = _annotationAt(localPosition);
    if (annotation == null) return false;
    widget.onAnnotationActivated!(annotation);
    return true;
  }

  model.AppAnnotation? _annotationAt(Offset localPosition) {
    if (!_viewer.isReady || widget.onAnnotationActivated == null) return null;
    final hit = _viewer.getPdfPageHitTestResult(
      localPosition,
      useDocumentLayoutCoordinates: false,
    );
    if (hit == null) return null;
    final index = hit.page.pageNumber - 1;
    if (index >= _geometry.length) return null;
    final point = _viewer.localToDocument(localPosition);
    final pageRect = _viewer.layout.pageLayouts[index];
    final adapter = PdfCoordinateAdapter(_geometry[index]);
    for (final annotation in widget.annotations.reversed) {
      if (annotation.revisionId != widget.revisionId ||
          annotation.pageIndex != index) {
        continue;
      }
      final contains = annotation.kind == 'region'
          ? annotation.quads.any(
              (q) =>
                  adapter.quadInDocument(q, hit.page, pageRect).contains(point),
            )
          : _textHighlightAreas(
              index,
              annotation.quads,
              hit.page,
              pageRect,
            ).any((rect) => rect.contains(point));
      if (contains) {
        return annotation;
      }
    }
    return null;
  }

  void _refreshHoverCursor() {
    final position = _hoverPosition;
    if (position == null || !mounted) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (!_hoverRefreshScheduled) {
        _hoverRefreshScheduled = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _hoverRefreshScheduled = false;
          if (mounted) _refreshHoverCursor();
        });
      }
      return;
    }
    _hoverCursor.value = _cursorAt(position);
  }

  MouseCursor _cursorAt(Offset local) {
    if (widget.closing ||
        !_viewer.isReady ||
        _document == null ||
        _geometry.isEmpty) {
      return SystemMouseCursors.basic;
    }
    if (_tool == _ReaderTool.rectangle) return SystemMouseCursors.precise;
    if (_dragPoint != null) return SystemMouseCursors.text;
    if (_annotationAt(local) != null) return SystemMouseCursors.click;
    final hit = _viewer.getPdfPageHitTestResult(
      local,
      useDocumentLayoutCoordinates: false,
    );
    if (hit != null) {
      final index = hit.page.pageNumber - 1;
      _loadHoverLinks(index);
      if ((_hoverLinks[index] ?? const []).any(
        (link) =>
            link.dest != null &&
            link.dest!.pageNumber >= 1 &&
            link.dest!.pageNumber <= _viewer.pages.length &&
            link.rects.any((rect) => rect.containsPoint(hit.offset)),
      )) {
        return SystemMouseCursors.click;
      }
      final layer = _layer(index);
      if (_tool == _ReaderTool.text &&
          layer != null &&
          layer.fragments.isNotEmpty) {
        final pageRect = _viewer.layout.pageLayouts[index];
        final layerKey = (layer.id, layer.text, layer.fragments);
        var cached = _hoverAreas[index];
        if (cached == null ||
            cached.layer != layerKey ||
            cached.page != pageRect) {
          cached = (
            layer: layerKey,
            page: pageRect,
            areas: _textHighlightAreas(
              index,
              layer.fragments.map((f) => f.quad).toList(),
              hit.page,
              pageRect,
            ),
          );
          _hoverAreas[index] = cached;
        }
        final point = _viewer.localToDocument(local);
        if (cached.areas.any((area) => area.contains(point))) {
          return SystemMouseCursors.text;
        }
      }
    }
    return _tool == _ReaderTool.hand
        ? SystemMouseCursors.grab
        : SystemMouseCursors.basic;
  }

  void _loadHoverLinks(int index) {
    final document = _document;
    if (document == null || index >= document.pages.length) return;
    if (_hoverLinks.containsKey(index) || !_hoverLinkRequests.add(index)) {
      return;
    }
    final generation = _generation;
    unawaited(() async {
      try {
        final links = await document.pages[index].loadLinks(
          enableAutoLinkDetection: false,
        );
        if (!mounted ||
            generation != _generation ||
            !identical(_document, document) ||
            widget.closing) {
          return;
        }
        _hoverLinks[index] = links;
      } catch (_) {
        // 悬停不执行跳转，也不覆盖阅读区的实际错误反馈。
        if (!mounted ||
            generation != _generation ||
            !identical(_document, document)) {
          return;
        }
        _hoverLinks[index] = const [];
      }
      if (mounted &&
          generation == _generation &&
          identical(_document, document)) {
        _hoverLinkRequests.remove(index);
        _refreshHoverCursor();
      }
    }());
  }

  Widget _readerCursorRegion(Widget child, {bool transparent = false}) =>
      ValueListenableBuilder<MouseCursor>(
        valueListenable: _hoverCursor,
        builder: (_, cursor, child) => MouseRegion(
          cursor: cursor,
          opaque: !transparent,
          hitTestBehavior: transparent
              ? HitTestBehavior.translucent
              : HitTestBehavior.opaque,
          onEnter: (event) {
            _hoverPosition = event.localPosition;
            _refreshHoverCursor();
          },
          onHover: (event) {
            _hoverPosition = event.localPosition;
            _refreshHoverCursor();
          },
          onExit: (_) => _hoverPosition = null,
          child: child,
        ),
        child: child,
      );

  void _endPointer(PointerEvent event) {
    if (!_primaryDown) return;
    _primaryDown = false;
    if (!_draggingText) _dragCursor.hide();
  }

  Future<void> _handlePdfLink(PdfLink link) async {
    if (!_viewer.isReady) return;
    _outlineViewport = null;
    final generation = _generation;
    final destination = link.dest;
    if (destination == null) {
      if (mounted) {
        setState(() {
          _feedback(
            link.url == null ? '此链接没有可用的文内目标' : '暂不支持打开外部链接：${link.url}',
            _ReaderFeedbackKind.error,
          );
        });
      }
      return;
    }
    try {
      // 即时跳转避免后续导航取消动画时留下未完成的 TickerFuture。
      final moved = await _viewer.goToDest(
        destination,
        duration: Duration.zero,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _feedback(moved ? null : '无法跳转到该文内链接', _ReaderFeedbackKind.error);
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() => _feedback('文内链接跳转失败：$error', _ReaderFeedbackKind.error));
    }
  }

  void _paint(Canvas canvas, Rect pageRect, PdfPage page) {
    final index = page.pageNumber - 1;
    if (index >= _geometry.length) return;
    final adapter = PdfCoordinateAdapter(_geometry[index]);
    void paintQuads(
      Iterable<model.PdfQuad> quads,
      Color color, {
      bool stroke = false,
    }) {
      final paint = Paint()
        ..color = color
        ..style = stroke ? PaintingStyle.stroke : PaintingStyle.fill
        ..strokeWidth = 1.8;
      for (final quad in quads) {
        canvas.drawPath(adapter.quadInDocument(quad, page, pageRect), paint);
      }
    }

    for (final annotation in widget.annotations.where(
      (a) => a.revisionId == widget.revisionId && a.pageIndex == index,
    )) {
      final color = _parseColor(annotation.color).withValues(alpha: .30);
      if (annotation.kind == 'region') {
        paintQuads(annotation.quads, color);
      } else {
        for (final rect in _textHighlightAreas(
          index,
          annotation.quads,
          page,
          pageRect,
        )) {
          canvas.drawRect(rect, Paint()..color = color);
        }
      }
      if (annotation.kind == 'note' && annotation.quads.isNotEmpty) {
        final point = adapter
            .quadInDocument(annotation.quads.first, page, pageRect)
            .getBounds()
            .topRight;
        canvas.drawCircle(point, 4, Paint()..color = Colors.orange);
      }
    }
    final sourceRects = mergeSourceHighlightRects([
      for (final anchor in _sourceHighlights.where((a) => a.pageIndex == index))
        for (final quad in anchor.quads)
          adapter.quadInDocument(quad, page, pageRect).getBounds(),
    ], vertical: page.rotation.index.isOdd);
    final sourcePaint = Paint()
      ..color = OpenNoteTokens.accent.withValues(
        alpha: .10 * (1 - _sourceFade.value),
      );
    for (final rect in sourceRects) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(1.5)),
        sourcePaint,
      );
    }
    for (final anchor in _selection.where((a) => a.pageIndex == index)) {
      if (_tool == _ReaderTool.text) {
        for (final rect in _textHighlightAreas(
          index,
          anchor.quads,
          page,
          pageRect,
        )) {
          canvas.drawRect(
            rect,
            Paint()..color = Colors.blue.withValues(alpha: .26),
          );
        }
      } else {
        paintQuads(anchor.quads, Colors.blue.withValues(alpha: .26));
      }
    }
    if (_rectangle != null && _rectanglePage == index) {
      canvas.drawRect(
        _rectangle!,
        Paint()..color = Colors.blue.withValues(alpha: .15),
      );
      canvas.drawRect(
        _rectangle!,
        Paint()
          ..color = Colors.blue
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
  }

  Color _parseColor(String value) => Color(
    int.tryParse(value.replaceFirst('#', 'FF'), radix: 16) ?? 0xFFF7D976,
  );

  Future<void> _rotate() async {
    if (_document == null || !_viewer.isReady) return;
    final pages = List<PdfPage>.of(_document!.pages);
    final page = pages[_pageIndex];
    pages[_pageIndex] = page.rotatedTo(
      PdfPageRotation.values[(page.rotation.index + 1) % 4],
    );
    _document!.pages = pages;
    setState(() {
      _selection = [];
      _rectangle = null;
    });
    _viewer.forceRepaintAllPageImages();
    // 仅改变展示用代理页面；不 assemble/encode/save 原始 PDF。
  }

  Widget _toolbar(bool ready) => Container(
    key: const Key('reader-toolbar'),
    height: 44,
    padding: const EdgeInsets.symmetric(horizontal: 8),
    decoration: const BoxDecoration(
      color: OpenNoteTokens.surface,
      border: Border(bottom: BorderSide(color: OpenNoteTokens.border)),
    ),
    child: LayoutBuilder(
      builder: (context, box) {
        // 断点使用整个阅读面板的宽度，内边距不改变档位。
        final width = box.maxWidth + 16;
        final wide = width >= 720;
        final navigation = width >= 520;
        final compact = width < 360;
        final toolIcon = switch (_tool) {
          _ReaderTool.hand => Icons.pan_tool_outlined,
          _ReaderTool.text => Icons.text_fields,
          _ReaderTool.rectangle => Icons.crop,
        };
        final canExcerpt =
            _selection.isNotEmpty && !_busy && _pendingSelectionPages.isEmpty;
        final canAnnotate =
            _selection.isNotEmpty && widget.onAnnotationCreated != null;
        return IconButtonTheme(
          data: IconButtonThemeData(
            style: (IconButtonTheme.of(context).style ?? const ButtonStyle())
                .merge(
                  IconButton.styleFrom(
                    fixedSize: const Size(36, 36),
                    minimumSize: const Size(36, 36),
                    maximumSize: const Size(36, 36),
                    padding: const EdgeInsets.all(8),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    IconButton(
                      tooltip: '目录与缩略图',
                      onPressed: widget.closing ? null : _toggleSidebar,
                      icon: const OpenNoteIcon(Icons.view_sidebar_outlined),
                    ),
                    Flexible(
                      flex: 1,
                      child: ReaderPageNavigation(
                        controller: _pageInput,
                        ready: ready,
                        pageCount: _document?.pages.length,
                        showArrows: navigation,
                        onPrevious: () => _goToPage(_pageIndex - 1),
                        onNext: () => _goToPage(_pageIndex + 1),
                        onSubmitted: (value) {
                          final page = int.tryParse(value);
                          if (ready && page != null) _goToPage(page - 1);
                        },
                      ),
                    ),
                    if (!compact) const SizedBox(width: 8),
                    if (wide) ...[
                      _toolButton(
                        _ReaderTool.hand,
                        Icons.pan_tool_outlined,
                        '移动',
                      ),
                      _toolButton(_ReaderTool.text, Icons.text_fields, '选文'),
                      _toolButton(_ReaderTool.rectangle, Icons.crop, '矩形'),
                    ] else if (!compact)
                      SizedBox(
                        width: 36,
                        height: 36,
                        child: PopupMenuButton<_ReaderTool>(
                          tooltip: '切换阅读工具',
                          enabled: !widget.closing,
                          onSelected: _chooseTool,
                          icon: OpenNoteIcon(
                            toolIcon,
                            size: 18,
                            color: OpenNoteTokens.accent,
                          ),
                          itemBuilder: (_) => [
                            for (final tool in _ReaderTool.values)
                              CheckedPopupMenuItem(
                                value: tool,
                                checked: _tool == tool,
                                child: Text(switch (tool) {
                                  _ReaderTool.hand => '移动',
                                  _ReaderTool.text => '选文',
                                  _ReaderTool.rectangle => '矩形',
                                }),
                              ),
                          ],
                        ),
                      ),
                    if (!compact)
                      _selectionAction(
                        IconButton.filledTonal(
                          tooltip: '摘录到${widget.excerptTargetLabel}',
                          onPressed: canExcerpt ? _excerpt : null,
                          icon: const OpenNoteIcon(Icons.add, size: 18),
                        ),
                      ),
                    if (wide) ...[
                      _selectionAction(
                        IconButton(
                          tooltip: '添加独立高亮批注',
                          onPressed: canAnnotate ? _annotate : null,
                          icon: const OpenNoteIcon(
                            Icons.border_color_outlined,
                            size: 18,
                          ),
                        ),
                      ),
                      _selectionAction(
                        IconButton(
                          tooltip: '添加文字批注',
                          onPressed: canAnnotate
                              ? () => _annotate(note: true)
                              : null,
                          icon: const OpenNoteIcon(
                            Icons.sticky_note_2_outlined,
                            size: 18,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (navigation)
                IconButton(
                  tooltip: '缩小',
                  onPressed: ready ? () => _viewer.zoomDown() : null,
                  icon: const OpenNoteIcon(Icons.remove),
                ),
              if (!compact)
                IconButton(
                  tooltip: '适合页面宽度',
                  onPressed: ready ? _fitPageWidth : null,
                  icon: const OpenNoteIcon(Icons.fit_screen),
                ),
              if (navigation)
                IconButton(
                  tooltip: '放大',
                  onPressed: ready ? () => _viewer.zoomUp() : null,
                  icon: const OpenNoteIcon(Icons.add),
                ),
              _selectionAction(
                SizedBox(
                  width: 36,
                  height: 36,
                  child: PopupMenuButton<String>(
                    key: const Key('reader-more-tools'),
                    tooltip: '更多阅读工具',
                    icon: OpenNoteIcon(
                      compact ? toolIcon : Icons.more_horiz,
                      color: compact ? OpenNoteTokens.accent : null,
                    ),
                    onCanceled: _dismissSelection,
                    onSelected: (value) {
                      if (value == 'copy') {
                        _copySelection();
                      } else if (value == 'excerpt') {
                        _excerpt();
                      } else if (value == 'highlight') {
                        _annotate();
                      } else if (value == 'note') {
                        _annotate(note: true);
                      } else {
                        // 选区命令保留选区，视图命令沿用原清除行为。
                        _dismissSelection();
                        if (value == 'rotate') _rotate();
                        if (value == 'in') _viewer.zoomUp();
                        if (value == 'out') _viewer.zoomDown();
                        if (value == 'fit') _fitPage();
                        if (value == 'width') _fitPageWidth();
                        if (value == 'previous') _goToPage(_pageIndex - 1);
                        if (value == 'next') _goToPage(_pageIndex + 1);
                        for (final tool in _ReaderTool.values) {
                          if (value == 'tool:${tool.name}') _chooseTool(tool);
                        }
                      }
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'copy',
                        enabled: _canCopy,
                        child: const Text('复制选中文字  Ctrl+C'),
                      ),
                      if (compact)
                        PopupMenuItem(
                          value: 'excerpt',
                          enabled: canExcerpt,
                          child: Text('摘录到${widget.excerptTargetLabel}'),
                        ),
                      if (!wide) ...[
                        PopupMenuItem(
                          value: 'highlight',
                          enabled: canAnnotate,
                          child: const Text('添加独立高亮批注'),
                        ),
                        PopupMenuItem(
                          value: 'note',
                          enabled: canAnnotate,
                          child: const Text('添加文字批注'),
                        ),
                      ],
                      const PopupMenuDivider(),
                      if (compact) ...[
                        for (final tool in _ReaderTool.values)
                          CheckedPopupMenuItem(
                            value: 'tool:${tool.name}',
                            checked: _tool == tool,
                            enabled: !widget.closing,
                            child: Text(switch (tool) {
                              _ReaderTool.hand => '移动',
                              _ReaderTool.text => '选文',
                              _ReaderTool.rectangle => '矩形',
                            }),
                          ),
                        const PopupMenuDivider(),
                        PopupMenuItem(
                          value: 'width',
                          enabled: ready,
                          child: const Text('适合页面宽度'),
                        ),
                      ],
                      PopupMenuItem(
                        value: 'fit',
                        enabled: ready,
                        child: const Text('适合整页'),
                      ),
                      if (!navigation) ...[
                        PopupMenuItem(
                          value: 'previous',
                          enabled: ready,
                          child: const Text('上一页'),
                        ),
                        PopupMenuItem(
                          value: 'next',
                          enabled: ready,
                          child: const Text('下一页'),
                        ),
                        PopupMenuItem(
                          value: 'in',
                          enabled: ready,
                          child: const Text('放大'),
                        ),
                        PopupMenuItem(
                          value: 'out',
                          enabled: ready,
                          child: const Text('缩小'),
                        ),
                      ],
                      PopupMenuItem(
                        value: 'rotate',
                        enabled: ready,
                        child: const Text('旋转当前页'),
                      ),
                    ],
                  ),
                ),
              ),
              if (widget.documentActions != null)
                SizedBox(width: 36, height: 36, child: widget.documentActions!),
            ],
          ),
        );
      },
    ),
  );

  @override
  Widget build(BuildContext context) {
    _scrollBehavior.disableAnimations = MediaQuery.disableAnimationsOf(context);
    final revisionId = widget.revisionId;
    final filePath = widget.filePath;
    final documentRef = widget.closing ? null : _documentRef;
    final ready = !widget.closing && _viewer.isReady;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape &&
            _sidebarVisible &&
            _sidebarAsDrawer) {
          _closeSidebarDrawer();
          return KeyEventResult.handled;
        }
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape &&
            _hasSelection) {
          _dismissSelection();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Listener(
        onPointerDown: (event) {
          _scrollBehavior.stop();
          _primaryDown =
              event.kind == PointerDeviceKind.mouse &&
              event.buttons == kPrimaryMouseButton;
        },
        onPointerUp: _endPointer,
        onPointerCancel: _endPointer,
        child: Stack(
          children: [
            Column(
              children: [
                _toolbar(ready),
                Expanded(
                  child: widget.closing
                      ? const Center(
                          key: ValueKey('reader-closing-document'),
                          child: Text('正在关闭文档…'),
                        )
                      : LayoutBuilder(
                          builder: (context, constraints) {
                            _sidebarAsDrawer = constraints.maxWidth < 700;
                            if (_sidebarVisible && _sidebarAsDrawer) {
                              _focusSidebarDrawer();
                            }
                            final maxSidebar = math.max(
                              120.0,
                              math.min(440.0, constraints.maxWidth - 486),
                            );
                            final sidebarWidth = _sidebarWidth.clamp(
                              120.0,
                              maxSidebar,
                            );
                            final reader = Row(
                              children: [
                                if (_sidebarVisible && !_sidebarAsDrawer) ...[
                                  SizedBox(
                                    key: const Key('reader-sidebar'),
                                    width: sidebarWidth,
                                    child: _sidebar(),
                                  ),
                                  ReaderSidebarDivider(
                                    key: const Key('reader-sidebar-divider'),
                                    onDragUpdate: (delta) => setState(
                                      () =>
                                          _sidebarWidth = (sidebarWidth + delta)
                                              .clamp(120.0, maxSidebar),
                                    ),
                                    onDragEnd: _saveSidebarSettings,
                                  ),
                                ],
                                Expanded(
                                  child: ColoredBox(
                                    color: const Color(0xfff4f5f6),
                                    child: Stack(
                                      children: [
                                        Positioned.fill(
                                          child: TapRegion(
                                            groupId: _selectionTapGroup,
                                            // 区域始终注册，回调自行判断选区，避免重排后漏掉外部点击。
                                            onTapOutside: (_) =>
                                                _dismissSelection(),
                                            child: PdfViewer(
                                              documentRef!,
                                              key: ValueKey(widget.revisionId),
                                              controller: _viewer,
                                              initialPageNumber:
                                                  (widget
                                                          .initialPosition
                                                          ?.pageIndex ??
                                                      0) +
                                                  1,
                                              params: PdfViewerParams(
                                                // Windows 已按系统滚动行数换算；不再应用 pdfrx 的 0.2 倍减速。
                                                scrollByMouseWheel: 1,
                                                interactionDelegateProvider:
                                                    _scrollBehavior,
                                                onKey: _readerKey,
                                                sizeDelegateProvider:
                                                    _viewportSizing,
                                                calculateCurrentPageNumber:
                                                    _outlineViewport == null
                                                    ? null
                                                    : (_, _, viewer) =>
                                                          viewer.value ==
                                                              _outlineViewport
                                                                  ?.matrix
                                                          ? _outlineViewport
                                                                ?.pageNumber
                                                          : null,
                                                onSecondaryTapUp: (details) =>
                                                    _selectionMenu(
                                                      details.globalPosition,
                                                    ),
                                                backgroundColor: const Color(
                                                  0xFFEEF0F3,
                                                ),
                                                pageDropShadow: const BoxShadow(
                                                  color: Color(0x147b8798),
                                                  blurRadius: 8,
                                                  offset: Offset(0, 2),
                                                ),
                                                errorBannerBuilder:
                                                    (
                                                      context,
                                                      error,
                                                      _,
                                                      _,
                                                    ) => SingleChildScrollView(
                                                      key: const ValueKey(
                                                        'reader-load-error-scroll',
                                                      ),
                                                      primary: false,
                                                      padding:
                                                          const EdgeInsets.all(
                                                            20,
                                                          ),
                                                      child: Column(
                                                        mainAxisSize:
                                                            MainAxisSize.min,
                                                        crossAxisAlignment:
                                                            CrossAxisAlignment
                                                                .stretch,
                                                        children: [
                                                          Text(
                                                            '无法打开 PDF',
                                                            style:
                                                                Theme.of(
                                                                      context,
                                                                    )
                                                                    .textTheme
                                                                    .titleMedium,
                                                          ),
                                                          const SizedBox(
                                                            height: 12,
                                                          ),
                                                          Text(
                                                            error.toString(),
                                                          ),
                                                        ],
                                                      ),
                                                    ),
                                                panEnabled:
                                                    _tool == _ReaderTool.hand,
                                                onInteractionStart: (_) {
                                                  if (_primaryDown &&
                                                      _tool ==
                                                          _ReaderTool.hand) {
                                                    _dragCursor.show(
                                                      context,
                                                      SystemMouseCursors
                                                          .grabbing,
                                                    );
                                                  }
                                                },
                                                onInteractionEnd: (_) {
                                                  if (_tool ==
                                                      _ReaderTool.hand) {
                                                    _dragCursor.hide();
                                                  }
                                                },
                                                linkHandlerParams:
                                                    PdfLinkHandlerParams(
                                                      onLinkTap: (link) =>
                                                          unawaited(
                                                            _handlePdfLink(
                                                              link,
                                                            ),
                                                          ),
                                                      enableAutoLinkDetection:
                                                          false,
                                                    ),
                                                textSelectionParams:
                                                    const PdfTextSelectionParams(
                                                      enabled: false,
                                                    ),
                                                onViewerReady:
                                                    (document, controller) {
                                                      if (!widget.closing &&
                                                          identical(
                                                            _documentRef,
                                                            documentRef,
                                                          )) {
                                                        unawaited(
                                                          _ready(
                                                            document,
                                                            controller,
                                                          ),
                                                        );
                                                      }
                                                    },
                                                onDocumentLoadFinished:
                                                    (_, success) {
                                                      if (success &&
                                                          !widget.closing &&
                                                          identical(
                                                            _documentRef,
                                                            documentRef,
                                                          )) {
                                                        unawaited(
                                                          _notifyInitialPageReady(
                                                            revisionId,
                                                            filePath,
                                                            _documentRef,
                                                          ),
                                                        );
                                                      }
                                                    },
                                                onPageChanged: (page) {
                                                  if (!mounted ||
                                                      widget.closing ||
                                                      page == null ||
                                                      !identical(
                                                        _documentRef,
                                                        documentRef,
                                                      )) {
                                                    return;
                                                  }
                                                  _doubleTapTimer?.cancel();
                                                  setState(() {
                                                    _pageIndex = page - 1;
                                                    _pageInput.text = '$page';
                                                  });
                                                  // 页码晚于视图矩阵更新；用公开回调准备实际到达页的文字层。
                                                  _positionChanged();
                                                },
                                                pagePaintCallbacks: [_paint],
                                                viewerOverlayBuilder: (context, size, handleLinkTap) => [
                                                  if (_tool == _ReaderTool.hand)
                                                    Positioned.fill(
                                                      child: _readerCursorRegion(
                                                        PdfOverlayInteractionRegion(
                                                          onTap: (details) =>
                                                              _activateAnnotation(
                                                                details
                                                                    .localPosition,
                                                              ),
                                                          child:
                                                              const SizedBox.expand(),
                                                        ),
                                                        transparent: true,
                                                      ),
                                                    ),
                                                  if (_tool != _ReaderTool.hand)
                                                    Positioned.fill(
                                                      child: Listener(
                                                        onPointerSignal: (event) {
                                                          _doubleTapTimer
                                                              ?.cancel();
                                                          _viewer
                                                              .handlePointerSignalEvent(
                                                                event,
                                                              );
                                                        },
                                                        onPointerPanZoomStart:
                                                            _trackpadStart,
                                                        onPointerPanZoomUpdate:
                                                            _trackpadUpdate,
                                                        child: _readerCursorRegion(
                                                          GestureDetector(
                                                            supportedDevices: const {
                                                              PointerDeviceKind
                                                                  .mouse,
                                                              PointerDeviceKind
                                                                  .touch,
                                                              PointerDeviceKind
                                                                  .stylus,
                                                              PointerDeviceKind
                                                                  .invertedStylus,
                                                            },
                                                            dragStartBehavior:
                                                                DragStartBehavior
                                                                    .down,
                                                            behavior:
                                                                HitTestBehavior
                                                                    .translucent,
                                                            onPanStart:
                                                                _panStart,
                                                            onPanUpdate:
                                                                _panUpdate,
                                                            onPanEnd: _panEnd,
                                                            onPanCancel: () {
                                                              _dragCursor
                                                                  .hide();
                                                              _edgeScrollTimer
                                                                  ?.cancel();
                                                              _dragPoint = null;
                                                            },
                                                            onSecondaryTapUp:
                                                                (
                                                                  details,
                                                                ) => _selectionMenu(
                                                                  details
                                                                      .globalPosition,
                                                                ),
                                                            onTapUp:
                                                                (
                                                                  details,
                                                                ) => _tapReader(
                                                                  details,
                                                                  handleLinkTap,
                                                                ),
                                                            child:
                                                                const SizedBox.expand(),
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                  ..._selectionDragRegions(
                                                    size,
                                                  ),
                                                  ..._selectionHandles(size),
                                                  ReaderScrollThumb(
                                                    controller: _viewer,
                                                    onInteraction:
                                                        _dismissSelection,
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            );
                            return Stack(
                              fit: StackFit.expand,
                              children: [
                                reader,
                                if (_sidebarVisible && _sidebarAsDrawer) ...[
                                  Positioned.fill(
                                    child: GestureDetector(
                                      key: const Key('reader-sidebar-scrim'),
                                      behavior: HitTestBehavior.opaque,
                                      onTap: _closeSidebarDrawer,
                                      child: const ColoredBox(
                                        color: Color(0x26000000),
                                      ),
                                    ),
                                  ),
                                  Positioned(
                                    left: 0,
                                    top: 0,
                                    bottom: 0,
                                    width: math.min(
                                      _sidebarWidth.clamp(220.0, 320.0),
                                      constraints.maxWidth * .85,
                                    ),
                                    child: Material(
                                      elevation: 12,
                                      child: FocusScope(
                                        node: _sidebarFocus,
                                        child: SizedBox(
                                          key: const Key('reader-sidebar'),
                                          child: _sidebar(),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            );
                          },
                        ),
                ),
              ],
            ),
            if (widget.closing || _error != null || _status != null)
              Positioned(
                left: 12,
                right: 12,
                bottom: 16,
                child: IgnorePointer(
                  child: Align(
                    alignment: Alignment.bottomLeft,
                    child: OpenNoteFeedback(
                      key: const Key('reader-feedback'),
                      message: widget.closing ? '正在关闭文档…' : _error ?? _status!,
                      error:
                          _error != null ||
                          _feedbackKind == _ReaderFeedbackKind.error,
                      processing:
                          widget.closing ||
                          _feedbackKind == _ReaderFeedbackKind.processing,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _feedback(
    String? message, [
    _ReaderFeedbackKind kind = _ReaderFeedbackKind.success,
  ]) {
    _feedbackTimer?.cancel();
    _status = message;
    _feedbackKind = kind;
    if (message != null && kind == _ReaderFeedbackKind.success) {
      final generation = _generation;
      _feedbackTimer = Timer(const Duration(seconds: 2), () {
        if (mounted && generation == _generation) {
          setState(() => _status = null);
        }
      });
    }
  }

  void _fitPageWidth() => _viewportSizing.fitWidth();

  void _fitPage() => _viewportSizing.fitPage();

  void _focusSidebarDrawer() {
    if (_sidebarFocusScheduled || _sidebarFocus.hasFocus) return;
    _sidebarFocusScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _sidebarFocusScheduled = false;
      if (mounted && _sidebarVisible && _sidebarAsDrawer) {
        _sidebarFocus.requestFocus();
      }
    });
  }

  void _restoreSidebarSettings() {
    _sidebarVisible = widget.initialPdfSettings.sidebarVisible;
    _sidebarWidth = widget.initialPdfSettings.sidebarWidth;
  }

  void _saveSidebarSettings() {
    widget.onPdfSettingsChanged?.call(
      model.PdfReadingSettings(
        sidebarVisible: _sidebarVisible,
        sidebarWidth: _sidebarWidth,
      ),
    );
  }

  void _toggleSidebar() {
    setState(() => _sidebarVisible = !_sidebarVisible);
    _saveSidebarSettings();
  }

  void _closeSidebarDrawer() {
    if (_sidebarAsDrawer && _sidebarVisible) {
      setState(() => _sidebarVisible = false);
      _saveSidebarSettings();
      if (_viewer.isReady) _viewer.requestFocus();
    }
  }

  Future<void> _navigateOutline(PdfDest? destination) async {
    final request = ++_outlineNavigationRequest;
    final generation = _generation;
    if (widget.closing || !_viewer.isReady || !_navigationReady) return;
    final target = _resolveOutlineTarget(destination);
    if (target == null) {
      setState(() => _feedback('此章节没有有效的跳转目标', _ReaderFeedbackKind.error));
      return;
    }
    bool current() =>
        mounted &&
        !widget.closing &&
        _viewer.isReady &&
        _navigationReady &&
        generation == _generation &&
        request == _outlineNavigationRequest;
    try {
      if (_sidebarAsDrawer && _sidebarVisible) {
        _closeSidebarDrawer();
        // 抽屉关闭后的布局决定最终视口，旧请求不能覆盖后一次点击。
        await WidgetsBinding.instance.endOfFrame;
      }
      if (!current()) return;
      final moved = _viewportSizing.goToOutline(
        pageNumber: target.pageNumber,
        documentX: target.documentX,
        documentY: target.documentY,
      );
      if (moved) {
        // 页尾标题可能使相邻页占比更大；视口未移动时仍显示书签目标页。
        _outlineViewport = (
          pageNumber: target.pageNumber,
          matrix: _viewer.value.clone(),
        );
        _viewer.setCurrentPageNumber(target.pageNumber);
        _positionChanged();
      }
      setState(
        () => _feedback(moved ? null : '无法跳转到该章节', _ReaderFeedbackKind.error),
      );
    } catch (error) {
      if (current()) {
        setState(() => _feedback('章节跳转失败：$error', _ReaderFeedbackKind.error));
      }
    }
  }

  ({int pageNumber, double? documentX, double? documentY})?
  _resolveOutlineTarget(PdfDest? destination) {
    if (destination == null ||
        destination.pageNumber < 1 ||
        destination.pageNumber > _geometry.length ||
        destination.pageNumber > _viewer.pageCount) {
      return null;
    }
    final index = destination.pageNumber - 1;
    final page = _viewer.pages[index];
    final pageRect = _viewer.layout.pageLayouts[index];
    final adapter = PdfCoordinateAdapter(_geometry[index]);
    final box = adapter.effectiveBox;
    final params = destination.params;
    double? parameter(int index) =>
        params != null &&
            index < params.length &&
            params[index]?.isFinite == true
        ? params[index]
        : null;
    double? x;
    double? y;
    switch (destination.command) {
      case PdfDestCommand.xyz:
        if (params != null && params.length >= 2) {
          x = parameter(0);
          y = parameter(1);
        }
      case PdfDestCommand.fitH:
      case PdfDestCommand.fitBH:
        y = parameter(0);
      case PdfDestCommand.fitV:
      case PdfDestCommand.fitBV:
        x = parameter(0);
      case PdfDestCommand.fitR:
        final left = parameter(0);
        final bottom = parameter(1);
        final right = parameter(2);
        final top = parameter(3);
        if (left != null &&
            bottom != null &&
            right != null &&
            top != null &&
            left <= right &&
            bottom <= top) {
          final region = adapter
              .quadInDocument(
                model.PdfQuad.rect(
                  left.clamp(box.left, box.right),
                  bottom.clamp(box.top, box.bottom),
                  right.clamp(box.left, box.right),
                  top.clamp(box.top, box.bottom),
                ),
                page,
                pageRect,
              )
              .getBounds();
          return (
            pageNumber: destination.pageNumber,
            documentX: region.left,
            documentY: region.top,
          );
        }
      default:
        break;
    }
    if (x == null && y == null) {
      return (
        pageNumber: destination.pageNumber,
        documentX: null,
        documentY: null,
      );
    }
    final point = PdfPoint(
      (x ?? box.left).clamp(box.left, box.right) - box.left,
      (y ?? box.bottom).clamp(box.top, box.bottom) - box.top,
    ).toOffsetInDocument(page: page, pageRect: pageRect);
    final rotated =
        _geometry[index].rotation == 90 || _geometry[index].rotation == 270;
    return (
      pageNumber: destination.pageNumber,
      documentX: (rotated ? y : x) == null ? null : point.dx,
      documentY: (rotated ? x : y) == null ? null : point.dy,
    );
  }

  Widget _toolButton(_ReaderTool tool, IconData icon, String label) {
    return Semantics(
      selected: _tool == tool,
      child: IconButton(
        tooltip: label,
        onPressed: widget.closing ? null : () => _chooseTool(tool),
        style: IconButton.styleFrom(
          minimumSize: const Size(36, 36),
          foregroundColor: _tool == tool
              ? OpenNoteTokens.accent
              : OpenNoteTokens.secondary,
          backgroundColor: _tool == tool ? OpenNoteTokens.selected : null,
        ),
        icon: OpenNoteIcon(icon, size: 18),
      ),
    );
  }

  void _chooseTool(_ReaderTool tool) => setState(() {
    _cancelTextDrag();
    _doubleTapTimer?.cancel();
    _tool = tool;
    _selection = [];
    _pendingSelectionPages = [];
    _rectangle = null;
    _textStart = null;
    _textEnd = null;
    _refreshHoverCursor();
    if (_viewer.isReady) _viewer.invalidate();
  });

  Widget _sidebar() {
    final collapsible = _collapsibleOutlineNodes(_outline).toList();
    return Material(
      color: Colors.white,
      shape: const Border(right: BorderSide(color: OpenNoteTokens.border)),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(
                  child: OpenNoteViewSwitch(
                    value: _sidebarTab == 1,
                    labels: const ['目录', '缩略图'],
                    expand: true,
                    horizontalPadding: 4,
                    onChanged: (value) =>
                        setState(() => _sidebarTab = value ? 1 : 0),
                  ),
                ),
                if (_sidebarAsDrawer)
                  IconButton(
                    tooltip: '关闭目录',
                    onPressed: _closeSidebarDrawer,
                    icon: const OpenNoteIcon(Icons.close, size: 16),
                    constraints: const BoxConstraints.tightFor(
                      width: 36,
                      height: 36,
                    ),
                    padding: EdgeInsets.zero,
                    style: IconButton.styleFrom(
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: _sidebarTab == 0
                ? (_outline.isEmpty
                      ? const Center(
                          child: Text(
                            '暂无目录',
                            style: TextStyle(color: Colors.grey),
                          ),
                        )
                      : ListView(children: _outlineWidgets(_outline, 0)))
                : ListView.builder(
                    itemCount: _document?.pages.length ?? 0,
                    itemBuilder: (context, index) => InkWell(
                      onTap: () {
                        _closeSidebarDrawer();
                        unawaited(_goToPage(index));
                      },
                      child: Container(
                        margin: const EdgeInsets.fromLTRB(15, 6, 15, 6),
                        padding: const EdgeInsets.all(5),
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: index == _pageIndex
                                ? OpenNoteTokens.accent
                                : OpenNoteTokens.border,
                          ),
                        ),
                        child: Column(
                          children: [
                            SizedBox(
                              height: 148,
                              child: PdfPageView(
                                document: _document,
                                pageNumber: index + 1,
                                maximumDpi: 60,
                              ),
                            ),
                            Text(
                              '${index + 1}',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
          ),
          // 批量操作固定在面板底部，目录列表单独滚动。
          if (_sidebarTab == 0 && collapsible.isNotEmpty)
            Padding(
              key: const Key('reader-outline-actions'),
              padding: const EdgeInsets.all(8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.start,
                children: [
                  _outlineActionButton(
                    key: const Key('reader-outline-expand-all'),
                    tooltip: '展开全部',
                    icon: Icons.unfold_more,
                    onPressed: collapsible.any(_collapsedOutline.contains)
                        ? () => setState(_collapsedOutline.clear)
                        : null,
                  ),
                  const SizedBox(width: 4),
                  _outlineActionButton(
                    key: const Key('reader-outline-collapse-all'),
                    tooltip: '折叠全部',
                    icon: Icons.unfold_less,
                    onPressed:
                        collapsible.any(
                          (node) => !_collapsedOutline.contains(node),
                        )
                        ? () => setState(
                            () => _collapsedOutline.addAll(collapsible),
                          )
                        : null,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _outlineActionButton({
    required Key key,
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
  }) => IconButton(
    key: key,
    tooltip: tooltip,
    onPressed: onPressed,
    constraints: const BoxConstraints.tightFor(width: 36, height: 36),
    padding: EdgeInsets.zero,
    style:
        IconButton.styleFrom(
          foregroundColor: OpenNoteTokens.secondary,
          disabledForegroundColor: OpenNoteTokens.muted,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ).copyWith(
          overlayColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.focused)
                ? OpenNoteTokens.selected
                : OpenNoteTokens.hover,
          ),
        ),
    icon: OpenNoteIcon(icon, size: 18),
  );

  Iterable<PdfOutlineNode> _collapsibleOutlineNodes(
    List<PdfOutlineNode> nodes,
  ) sync* {
    for (final node in nodes) {
      if (node.children.isEmpty) continue;
      yield node;
      yield* _collapsibleOutlineNodes(node.children);
    }
  }

  List<Widget> _outlineWidgets(List<PdfOutlineNode> nodes, int depth) => [
    for (final node in nodes) ...[
      ListTile(
        dense: true,
        minTileHeight: 40,
        minVerticalPadding: 0,
        contentPadding: EdgeInsets.only(left: 10.0 + depth * 20, right: 8),
        // 叶项也预留箭头位置，避免同级标题错位或子项反向缩进。
        leading: node.children.isEmpty
            ? const SizedBox(width: 36, height: 36)
            : IconButton(
                tooltip: _collapsedOutline.contains(node) ? '展开章节' : '折叠章节',
                constraints: const BoxConstraints.tightFor(
                  width: 36,
                  height: 36,
                ),
                padding: EdgeInsets.zero,
                // 保留点击区域，让箭头在区域内靠近标题。
                alignment: Alignment.centerRight,
                icon: OpenNoteIcon(
                  _collapsedOutline.contains(node)
                      ? Icons.chevron_right
                      : Icons.expand_more,
                  size: 18,
                ),
                onPressed: () => setState(() {
                  if (!_collapsedOutline.remove(node)) {
                    _collapsedOutline.add(node);
                  }
                }),
              ),
        minLeadingWidth: 0,
        horizontalTitleGap: 0,
        title: Tooltip(
          message: node.title,
          child: Text(
            node.title,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 14,
              height: 1.4,
              fontWeight: depth == 0 ? FontWeight.w500 : FontWeight.w400,
            ),
          ),
        ),
        onTap: () => unawaited(_navigateOutline(node.dest)),
      ),
      if (!_collapsedOutline.contains(node))
        ..._outlineWidgets(node.children, depth + 1),
    ],
  ];
}

typedef _TextPoint = PdfSelectionPoint;
typedef _LayerView = PdfSelectableText;
