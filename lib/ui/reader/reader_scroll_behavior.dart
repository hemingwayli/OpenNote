import 'package:flutter/widgets.dart';
import 'package:pdfrx/pdfrx.dart';

/// 保留平台滚轮距离，以屏幕坐标平滑滚动；缩放不改变每格滚轮的速度。
class ReaderScrollBehavior extends PdfViewerScrollInteractionDelegateProvider {
  _ReaderScrollDelegate? _active;
  bool disableAnimations = false;

  void stop() => _active?.stop();

  @override
  PdfViewerScrollInteractionDelegate create() =>
      _active = _ReaderScrollDelegate(this);

  @override
  bool operator ==(Object other) => identical(this, other);

  @override
  int get hashCode => identityHashCode(this);
}

class _ReaderScrollDelegate implements PdfViewerScrollInteractionDelegate {
  _ReaderScrollDelegate(this.behavior);

  final ReaderScrollBehavior behavior;
  PdfViewerController? _viewer;
  AnimationController? _animation;
  Offset _start = Offset.zero;
  Offset? _target;
  bool _applying = false;

  @override
  void init(PdfViewerController controller, TickerProvider vsync) {
    _viewer?.removeListener(_onViewChanged);
    _animation?.dispose();
    _target = null;
    _viewer = controller..addListener(_onViewChanged);
    _animation = AnimationController(
      vsync: vsync,
      duration: const Duration(milliseconds: 220),
    )..addListener(_tick);
  }

  // 页码跳转、回源、缩放和拖动优先，旧滚轮动画不能将新位置拉回。
  void _onViewChanged() {
    if (!_applying) stop();
  }

  Offset get _translation {
    final matrix = _viewer!.value;
    return Offset(matrix.storage[12], matrix.storage[13]);
  }

  Matrix4 _matrixAt(Offset position) => _viewer!.value.clone()
    ..setEntry(0, 3, position.dx)
    ..setEntry(1, 3, position.dy);

  @override
  void pan(Offset delta, PdfViewerLayoutMetrics layoutMetrics) {
    final viewer = _viewer;
    if (viewer == null || !viewer.isReady || delta == Offset.zero) return;
    final current = _translation;
    final pending = (_target ?? current) - current;
    // 同向连续滚动累加；反向时立即从当前位置起步，不先滑完旧方向。
    final proposed =
        current +
        Offset(
          delta.dx + (delta.dx * pending.dx < 0 ? 0 : pending.dx),
          delta.dy + (delta.dy * pending.dy < 0 ? 0 : pending.dy),
        );
    final safe = viewer.makeMatrixInSafeRange(
      _matrixAt(proposed),
      forceClamp: true,
    );
    _start = current;
    _target = Offset(safe.storage[12], safe.storage[13]);
    if (behavior.disableAnimations) {
      _apply(_target!);
      stop();
      return;
    }
    _animation!.forward(from: 0);
  }

  void _tick() {
    final target = _target;
    if (target == null) return;
    final progress = Curves.easeOutCubic.transform(_animation!.value);
    _apply(Offset.lerp(_start, target, progress)!);
    if (_animation!.value == 1) stop();
  }

  void _apply(Offset position) {
    final viewer = _viewer!;
    _applying = true;
    try {
      viewer.value = viewer.makeMatrixInSafeRange(
        _matrixAt(position),
        forceClamp: true,
      );
    } finally {
      _applying = false;
    }
  }

  @override
  void zoom(double scale, Offset focalPoint, PdfViewerLayoutMetrics metrics) {
    stop();
    final viewer = _viewer;
    if (viewer == null || !viewer.isReady) return;
    // Ctrl+滚轮沿用阅读器原有的鼠标锚点缩放，不叠加平移动画。
    viewer.zoomOnLocalPosition(
      localPosition: focalPoint,
      newZoom: (viewer.currentZoom * scale).clamp(
        metrics.minScale,
        metrics.maxScale,
      ),
      duration: Duration.zero,
    );
  }

  @override
  void stop() {
    _animation?.stop();
    _target = null;
  }

  @override
  void dispose() {
    stop();
    _viewer?.removeListener(_onViewChanged);
    _animation?.dispose();
    _animation = null;
    _viewer = null;
    if (identical(behavior._active, this)) behavior._active = null;
  }
}
