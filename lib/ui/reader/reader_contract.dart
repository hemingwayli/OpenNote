import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import '../../domain/models.dart';

class SelectedExcerpt {
  const SelectedExcerpt({
    required this.text,
    required this.anchors,
    this.imageBytes,
  });
  final String text;
  final Uint8List? imageBytes;
  final List<AnchorDraft> anchors;
}

/// 一次文字拖动的只读快照；领取、准备与确认各自隔离，鼠标松手不等同于保存成功。
class ReaderExcerptDrag extends ChangeNotifier {
  ReaderExcerptDrag({
    required this.revisionId,
    required this.text,
    required List<AnchorDraft> anchors,
    required this.sourceIsCurrent,
    required this.prepareExcerpt,
    required this.onCommitted,
    required this.onFinished,
  }) : anchors = List.unmodifiable(
         anchors.map(
           (a) => AnchorDraft(
             revisionId: a.revisionId,
             pageIndex: a.pageIndex,
             quads: List.unmodifiable(
               a.quads.map((q) => PdfQuad(List.unmodifiable(q.points))),
             ),
             textLayerId: a.textLayerId,
             textStart: a.textStart,
             textEnd: a.textEnd,
             context: a.context,
             epubLocator: a.epubLocator == null ? null : EpubLocator.fromJson(Map<String,dynamic>.from(a.epubLocator!.toJson())),
           ),
         ),
       );

  final String revisionId;
  final String text;
  final List<AnchorDraft> anchors;
  final bool Function() sourceIsCurrent;
  final Future<SelectedExcerpt> Function() prepareExcerpt;
  final VoidCallback onCommitted;
  final void Function(Object?) onFinished;
  bool _cancelled = false;
  bool _claimed = false;
  bool _finished = false;
  bool _started = false;
  Object? _dropTarget;
  Future<SelectedExcerpt>? _preparing;

  bool get isCurrent => !_cancelled && !_finished && sourceIsCurrent();
  bool get canAccept => isCurrent && !_claimed;
  bool get isClaimed => _claimed;
  bool get started => _started;
  bool get hasDropTarget => canAccept && _dropTarget != null;

  /// 接收区域只登记当前可用落点；离开旧区域不能撤掉另一接收区的反馈。
  void setDropTarget(Object target, {required bool accepted}) {
    if (!canAccept) return;
    if (accepted) {
      if (identical(_dropTarget, target)) return;
      _dropTarget = target;
    } else {
      if (!identical(_dropTarget, target)) return;
      _dropTarget = null;
    }
    _notify();
  }

  void clearDropTarget(Object target) => setDropTarget(target, accepted: false);

  void _notify() {
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => notifyListeners());
    } else {
      notifyListeners();
    }
  }

  void start() {
    _started = true;
    _notify();
  }

  bool claim() {
    if (!canAccept) return false;
    _claimed = true;
    _notify();
    return true;
  }

  Future<SelectedExcerpt> prepare() => _preparing ??= () async {
    if (!isCurrent) throw const ReaderExcerptDragCancelled();
    final excerpt = await prepareExcerpt();
    if (!isCurrent) throw const ReaderExcerptDragCancelled();
    return excerpt;
  }();

  void cancel() {
    if (_finished || _cancelled) return;
    _cancelled = true;
    _notify();
  }

  void commit() {
    if (_finished) return;
    final current = isCurrent;
    _finished = true;
    _notify();
    if (current) onCommitted();
    onFinished(null);
  }

  void fail(Object error) {
    if (_finished) return;
    final current = isCurrent;
    _finished = true;
    _notify();
    onFinished(current && error is! ReaderExcerptDragCancelled ? error : null);
  }
}

/// 来源或目标已失效时安静取消，不把旧会话的取消显示为新会话错误。
class ReaderExcerptDragCancelled implements Exception {
  const ReaderExcerptDragCancelled();
}

class ReaderAnnotationDraft {
  const ReaderAnnotationDraft({
    required this.revisionId,
    required this.pageIndex,
    required this.quads,
    this.kind = 'highlight',
    this.text = '',
    this.color = '#F7D976',
    this.epubLocator,
  });
  final String revisionId;
  final int pageIndex;
  final List<PdfQuad> quads;
  final String kind;
  final String text;
  final String color;
  final EpubLocator? epubLocator;
}

/// 回源意图跨文档加载保留缩放，并用序号隔离旧异步结果。
class ReaderSourceRequest {
  ReaderSourceRequest({
    required this.sequence,
    required List<AnchorDraft> anchors,
    this.zoom,
    this.cardId,
  }) : anchors = List.unmodifiable(anchors);
  final int sequence;
  final List<AnchorDraft> anchors;
  final double? zoom;
  final String? cardId;
  String? get revisionId => anchors.firstOrNull?.revisionId;
}

/// 外层通过这个控制器回源，控制器不持有或写入数据库。
class ReaderPaneController {
  ReaderSourceRequest? pendingSourceRequest;
  List<AnchorDraft>? get pendingAnchors => pendingSourceRequest?.anchors;
  int _sourceSequence = 0;
  String? _activeRevision;
  String? _highlightCardId;
  int? pendingPageIndex;
  Future<void> Function(ReaderSourceRequest)? jumpToAnchorsDelegate;
  double? Function()? currentZoomDelegate;
  double? get currentZoom => currentZoomDelegate?.call();
  Future<void> Function(int)? goToPageDelegate;
  VoidCallback? clearHighlightsDelegate;
  VoidCallback? clearSelectionDelegate;
  final _closingDocuments = <Future<void>>{};
  Object? _documentCloseError;
  StackTrace? _documentCloseStack;

  /// Reader 只登记已经卸载或切换的文档；成功关闭后不保留原生文档 Future。
  void trackClosedDocument(Future<void> closing) {
    if (!_closingDocuments.add(closing)) return;
    unawaited(
      closing.then<void>(
        (_) {
          _closingDocuments.remove(closing);
        },
        onError: (Object error, StackTrace stack) {
          _documentCloseError ??= error;
          _documentCloseStack ??= stack;
          _closingDocuments.remove(closing);
        },
      ),
    );
  }

  /// 资料库恢复/退出须先停止对应 PDF 视图，再等待迟到或已有文档实际关闭。
  /// 只等待已登记的关闭；真实失败会继续传播，不能伪装排空完成。
  Future<void> drainClosedDocuments() async {
    while (_closingDocuments.isNotEmpty) {
      await Future.wait([
        for (final closing in _closingDocuments.toList())
          closing.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      ]);
    }
    final error = _documentCloseError;
    if (error != null) {
      Error.throwWithStackTrace(error, _documentCloseStack!);
    }
  }

  bool isCurrentSource(ReaderSourceRequest request) =>
      request.sequence == _sourceSequence;

  void activateRevision(String revisionId) {
    if (_activeRevision != revisionId &&
        pendingSourceRequest?.revisionId != revisionId) {
      _sourceSequence++;
      pendingSourceRequest = null;
      _highlightCardId = null;
    }
    _activeRevision = revisionId;
  }

  void acceptSource(ReaderSourceRequest request) {
    if (!isCurrentSource(request)) return;
    if (identical(pendingSourceRequest, request)) pendingSourceRequest = null;
    _highlightCardId = request.cardId;
  }

  Future<void> jumpToAnchors(
    List<AnchorDraft> anchors, {
    double? zoom,
    String? cardId,
  }) async {
    final request = ReaderSourceRequest(
      sequence: ++_sourceSequence,
      anchors: anchors,
      zoom: zoom ?? currentZoom,
      cardId: cardId,
    );
    pendingSourceRequest = request;
    pendingPageIndex = null;
    await jumpToAnchorsDelegate?.call(request);
  }

  Future<void> showSearchHit(SearchHit hit, {double? zoom}) async {
    if (hit.revisionId == null || (hit.pageIndex == null && hit.epubLocator == null)) return;
    await jumpToAnchors([
      AnchorDraft(
        revisionId: hit.revisionId!,
        pageIndex: hit.pageIndex ?? 0,
        quads: hit.quads,
        textLayerId: hit.textLayerId,
        textStart: hit.start,
        textEnd: hit.end,
        context: hit.text,
        epubLocator: hit.epubLocator,
      ),
    ], zoom: zoom);
  }

  Future<void> goToPage(int pageIndex) async {
    pendingPageIndex = pageIndex;
    clearHighlights();
    await goToPageDelegate?.call(pageIndex);
  }

  void clearHighlights() {
    _sourceSequence++;
    pendingSourceRequest = null;
    _highlightCardId = null;
    clearHighlightsDelegate?.call();
  }

  void clearAfterCardDeletion(Set<String> cardIds) {
    if (cardIds.contains(_highlightCardId) ||
        cardIds.contains(pendingSourceRequest?.cardId)) {
      clearHighlights();
    }
    clearSelectionDelegate?.call();
  }
}
