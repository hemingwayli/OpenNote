import 'package:flutter/widgets.dart';
import 'package:pdfrx/pdfrx.dart';

enum _FitMode { width, page, manual }

/// 目录、分栏和窗口改变尺寸时继续适配，并保留当前阅读位置。
class ReaderViewportSizing extends PdfViewerSizeDelegateProvider {
  _ReaderViewportDelegate? _active;

  void fitWidth() => _active?.fit(_FitMode.width);
  void fitPage() => _active?.fit(_FitMode.page);

  @override
  PdfViewerSizeDelegate create() => _active = _ReaderViewportDelegate(this);

  @override
  bool operator ==(Object other) => identical(this, other);

  @override
  int get hashCode => identityHashCode(this);
}

class _ReaderViewportDelegate extends PdfViewerSizeDelegateLegacy {
  _ReaderViewportDelegate(this.provider)
    : super(
        minScale: .1,
        maxScale: 8,
        useAlternativeFitScaleAsMinScale: false,
        onePassRenderingScaleThreshold: 200 / 72,
        calculateInitialZoom: null,
      );

  final ReaderViewportSizing provider;
  PdfViewerController? _viewer;
  _FitMode _mode = _FitMode.width;
  double? _lastZoom;
  bool _applying = false;

  @override
  void init(PdfViewerController controller) {
    super.init(controller);
    _viewer = controller..addListener(_viewChanged);
  }

  void _viewChanged() {
    final zoom = _viewer!.currentZoom;
    if (!_applying &&
        _lastZoom != null &&
        (zoom - _lastZoom!).abs() > .000001) {
      // 按钮、Ctrl+滚轮、触控板和指定比例回源都代表用户选择了手动缩放。
      _mode = _FitMode.manual;
    }
    _lastZoom = zoom;
  }

  void _apply(VoidCallback action) {
    _applying = true;
    try {
      action();
      _lastZoom = _viewer?.currentZoom;
    } finally {
      _applying = false;
    }
  }

  Matrix4? _fitMatrix(_FitMode mode, int page) => mode == _FitMode.width
      ? _viewer!.calcMatrixFitWidthForPage(pageNumber: page)
      : _viewer!.calcMatrixForFit(pageNumber: page);

  void fit(_FitMode mode) {
    final viewer = _viewer;
    if (viewer == null || !viewer.isReady) return;
    final matrix = _fitMatrix(mode, viewer.pageNumber ?? 1);
    if (matrix == null) return;
    _mode = mode;
    viewer.stopInteractiveViewerAnimation();
    _apply(() => viewer.value = matrix);
  }

  @override
  void onLayoutInitialized({
    required PdfViewerLayoutSnapshot state,
    required int initialPageNumber,
    required double coverScale,
    required double? alternativeFitScale,
    required PdfPageLayout layout,
    required PdfDocument document,
  }) {
    // 保留原有首次打开和初始页恢复行为；只改变后续视口变化的策略。
    _apply(
      () => super.onLayoutInitialized(
        state: state,
        initialPageNumber: initialPageNumber,
        coverScale: coverScale,
        alternativeFitScale: alternativeFitScale,
        layout: layout,
        document: document,
      ),
    );
  }

  @override
  void onLayoutUpdate({
    required PdfViewerLayoutSnapshot oldState,
    required PdfViewerLayoutSnapshot newState,
    required double currentZoom,
    required Rect oldVisibleRect,
    required int? anchorPageNumber,
    required bool isLayoutChanged,
    required bool isViewSizeChanged,
  }) {
    final viewer = _viewer;
    if (viewer == null) return;
    if (isLayoutChanged ||
        oldState.viewSize.isEmpty ||
        newState.layout == null) {
      _apply(
        () => super.onLayoutUpdate(
          oldState: oldState,
          newState: newState,
          currentZoom: currentZoom,
          oldVisibleRect: oldVisibleRect,
          anchorPageNumber: anchorPageNumber,
          isLayoutChanged: isLayoutChanged,
          isViewSizeChanged: isViewSizeChanged,
        ),
      );
      return;
    }
    final page = (anchorPageNumber ?? viewer.pageNumber ?? 1).clamp(
      1,
      newState.layout!.pageLayouts.length,
    );
    final pageRect = newState.layout!.pageLayouts[page - 1];
    final fit = _mode == _FitMode.manual ? null : _fitMatrix(_mode, page);
    final zoom = (fit?.storage[0] ?? currentZoom).clamp(.1, 8.0);
    // 手动缩放保留视口中心的横向内容；适配模式将页面居中到剩余阅读区。
    // 纵向锚点使用原视口顶部，避免开关目录或拖分栏时跳回页首。
    final center = Offset(
      _mode == _FitMode.manual ? oldVisibleRect.center.dx : pageRect.center.dx,
      oldVisibleRect.top + newState.viewSize.height / zoom / 2,
    );
    final matrix = viewer.calcMatrixFor(
      center,
      zoom: zoom,
      viewSize: newState.viewSize,
    );
    viewer.stopInteractiveViewerAnimation();
    _apply(
      () => viewer.value = viewer.calcMatrixForClampedToNearestBoundary(
        matrix,
        viewSize: newState.viewSize,
      ),
    );
  }

  @override
  void dispose() {
    _viewer?.removeListener(_viewChanged);
    _viewer = null;
    if (identical(provider._active, this)) provider._active = null;
    super.dispose();
  }
}
