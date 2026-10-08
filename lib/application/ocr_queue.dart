import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:pdfrx/pdfrx.dart' as pdf;
import 'package:uuid/uuid.dart';

import '../data/open_note_repository.dart';
import '../domain/models.dart';
import '../engines/ocr/ocr_service.dart';
import '../engines/pdf/pdf_read_engine.dart';

/// 持久队列按页运行。数据库任务、PDF 图像和原生推理共享一条提交路径。
class _EpubImageRequest {
  _EpubImageRequest(this.revisionId,this.locator,this.image,this.session,this.generation);
  final String revisionId;
  final EpubLocator locator;
  final Uint8List image;
  final String session;
  final int generation;
  bool cancelled=false;
  final Completer<OcrResult> done=Completer<OcrResult>();
}

/// 当前文档的文字就绪状态；队列空闲不代表所有页面已完成。
class OcrDocumentStatus {
  const OcrDocumentStatus({
    required this.totalPages,
    required this.completedPages,
    this.pendingPages = 0,
    this.failedPages = 0,
    this.cancelledPages = 0,
    this.isCancelling = false,
    this.error,
  });

  final int totalPages;
  final int completedPages;
  final int pendingPages;
  final int failedPages;
  final int cancelledPages;
  final bool isCancelling;
  final String? error;
  bool get isReady => totalPages > 0 && completedPages == totalPages &&
      pendingPages == 0 && failedPages == 0 && cancelledPages == 0;
  bool get hasActivity => isCancelling || pendingPages > 0 || failedPages > 0 || cancelledPages > 0;
  double? get progress => totalPages == 0 ? null : completedPages / totalPages;
  String get label {
    if (isCancelling) return '正在取消文字处理';
    if (pendingPages > 0) return '文字处理中 $completedPages/$totalPages 页';
    if (failedPages > 0) return '文字处理失败 $failedPages 页';
    if (cancelledPages > 0) return '处理已取消，剩余 $cancelledPages 页';
    if (isReady) return '文字已就绪';
    return '正在准备文字处理';
  }
}

class OcrQueueController extends ChangeNotifier {
  OcrQueueController(
    this.repository, {
    NativeOcrService? service,
    Future<NativeOcrService> Function()? serviceFactory,
    // 注入参数保持公开名称 service，内部句柄不暴露为可写字段。
    // ignore: prefer_initializing_formals
  }) : _service = service,
       _factory = serviceFactory ?? NativeOcrService.create;

  static const modelVersion = ocrProcessingVersion;
  final OpenNoteRepository repository;
  final Future<NativeOcrService> Function() _factory;
  NativeOcrService? _service;
  Future<void>? _loop;
  Future<void>? _disposing;
  bool _disposed = false;
  bool _notifierDisposed = false;
  bool _paused = false;
  bool _cancelling = false;
  bool _wakeRequested = false;
  final Set<Future<void>> _admissions = {};
  int _generation = 0;
  final List<String> _priority = [];
  final List<_EpubImageRequest> _imageRequests = [];
  String? _activeImageRevision;
  _EpubImageRequest? _activeImageRequest;
  ({String session, String revision, int page})? _readingPriority;
  pdf.PdfDocument? _document;
  String? _documentRevisionId;
  String? _documentSessionId;
  pdf.PdfPageRenderCancellationToken? _renderCancellation;
  List<OcrTask> _tasks = const [];
  OcrTask? currentTask;
  String? lastError;
  String? _displayRevisionId;
  String? _statusSessionId;
  final _pageCounts = <String, int>{};
  final _reusablePages = <String, Set<int>>{};
  final _cancelledRevisions = <String>{};
  String? _currentPageRevision;
  Completer<void>? _currentPageDone;

  OcrDocumentStatus statusForRevision(String revisionId, {int pageCount = 0}) {
    final sameSession = _statusSessionId == repository.sessionId;
    final total = sameSession ? (_pageCounts[revisionId] ?? pageCount) : pageCount;
    final tasks = sameSession ? _tasks.where((task) =>
        task.revisionId == revisionId && task.modelVersion == modelVersion) : <OcrTask>[];
    // 复用的文字层可能没有队列任务，必须一并计算；失败和取消页不能算作就绪。
    final completed = <int>{
      if (sameSession) ...?_reusablePages[revisionId],
      ...tasks.where((task) => task.status == OcrTaskStatus.completed)
          .map((task) => task.pageIndex),
    };
    completed.removeAll(tasks.where((task) => task.status != OcrTaskStatus.completed)
        .map((task) => task.pageIndex));
    final failed = tasks.where((task) => task.status == OcrTaskStatus.failed).toList();
    return OcrDocumentStatus(
      totalPages: total,
      completedPages: completed.where((page) => page >= 0 && page < total).length,
      pendingPages: tasks.where((task) => task.status == OcrTaskStatus.queued ||
          task.status == OcrTaskStatus.running).length,
      failedPages: failed.length,
      cancelledPages: tasks.where((task) => task.status == OcrTaskStatus.cancelled).length,
      isCancelling: sameSession && _cancelledRevisions.contains(revisionId),
      error: failed.where((task) => task.error.isNotEmpty).lastOrNull?.error,
    );
  }

  void _resetStatusSession(String session) {
    if (_statusSessionId == session) return;
    _statusSessionId = session;
    _pageCounts.clear();
    _reusablePages.clear();
  }

  bool get isRunning => currentTask != null || _activeImageRevision != null;
  bool get isBusy => _loop != null;
  bool get isPaused => _paused;
  int? get currentPageIndex => currentTask?.pageIndex;
  String? get activeRevisionId => _activeImageRevision ?? currentTask?.revisionId ?? _displayRevisionId;
  Iterable<OcrTask> get _displayTasks => _displayRevisionId == null
      ? _tasks
      : _tasks.where((t) => t.revisionId == _displayRevisionId);
  int get totalCount => _displayTasks.length;
  int get completedCount =>
      _displayTasks.where((t) => t.status == OcrTaskStatus.completed).length;
  int get pendingCount => _displayTasks
      .where(
        (t) =>
            t.status == OcrTaskStatus.queued ||
            t.status == OcrTaskStatus.running,
      )
      .length;
  int get failedCount =>
      _displayTasks.where((t) => t.status == OcrTaskStatus.failed).length;
  int get cancelledCount =>
      _displayTasks.where((t) => t.status == OcrTaskStatus.cancelled).length;
  int retryableCountForRevision(String revisionId) => _tasks
      .where(
        (task) =>
            task.revisionId == revisionId &&
            task.modelVersion == modelVersion &&
            (task.status == OcrTaskStatus.failed ||
                task.status == OcrTaskStatus.cancelled),
      )
      .length;
  double get progress => totalCount == 0
      ? 0
      : (completedCount + failedCount + cancelledCount) / totalCount;

  /// 只调整内存中的领取顺序；已完成/失败/取消页不会因翻页重新入队。
  void prioritizeReadingPage(String revisionId, int pageIndex) {
    if (_disposed || _cancelling || pageIndex < 0) return;
    _readingPriority = (
      session: repository.sessionId,
      revision: revisionId,
      page: pageIndex,
    );
  }

  Future<void> enqueueRevision(
    String revisionId, {
    int? priorityPage,
    bool retryIncomplete = true,
  }) => _admit(() async {
    _ensureAccepting();
    // 在异步元数据读取前记录意图，防止较早的入队结果覆盖后来的翻页。
    if (priorityPage != null) prioritizeReadingPage(revisionId, priorityPage);
    final session = repository.sessionId;
    final revision = await _ensureMetadata(revisionId, session);
    final complete = await repository.reusableTextPages(
      revisionId,
      ocrEngineVersion: modelVersion,
    );
    if (priorityPage != null &&
        (priorityPage < 0 || priorityPage >= revision.pageCount)) {
      throw ArgumentError.value(priorityPage, 'priorityPage');
    }
    _ensureSession(session);
    _ensureAccepting();
    _resetStatusSession(session);
    _pageCounts[revisionId] = revision.pageCount;
    _reusablePages[revisionId] = complete;
    await repository.enqueueOcr(
      revisionId,
      [
        for (var page = 0; page < revision.pageCount; page++)
          if (!complete.contains(page)) page,
      ],
      modelVersion: modelVersion,
      retryIncomplete: retryIncomplete,
    );
    _displayRevisionId = revisionId;
    lastError = null;
    await _refresh();
    _kick();
  });

  Future<void> enqueuePage(String revisionId, int pageIndex) => _admit(
    () async {
      _ensureAccepting();
      final session = repository.sessionId;
      final revision = await _ensureMetadata(revisionId, session);
      if (pageIndex < 0 || pageIndex >= revision.pageCount) {
        throw ArgumentError.value(pageIndex, 'pageIndex');
      }
      _ensureSession(session);
      _ensureAccepting();
      final tasks = await repository.enqueueOcr(
        revisionId,
        [pageIndex],
        modelVersion: modelVersion,
        force: true,
      );
      for (final task in tasks.where((t) => t.status == OcrTaskStatus.queued)) {
        _priority.remove(task.id);
        _priority.insert(0, task.id);
      }
      _displayRevisionId = revisionId;
      lastError = null;
      await _refresh();
      _kick();
    },
  );

  Future<void> resumePending() async {
    if (_disposed || _paused || _cancelling) return;
    await _refresh();
    _kick();
  }

  /// 按需图片识别与 PDF 页共享一个原生服务，排空前完成已接受的图片及保存。
  Future<OcrResult> enqueueEpubImage({required String revisionId,required EpubLocator locator,
    required Uint8List image}) async {
      late OcrResult result;
      await _admit(() async {
      final request=_EpubImageRequest(revisionId,locator,Uint8List.fromList(image),repository.sessionId,_generation);
      _imageRequests.add(request);
      _kick();
      result=await request.done.future;
    });
      return result;
    }

  void cancelEpubImages(String revisionId) {
    for(final request in _imageRequests.where((r)=>r.revisionId==revisionId).toList()) {
      _imageRequests.remove(request);request.cancelled=true;
      request.done.completeError(const OcrCancelledException());
    }
    if(_activeImageRequest?.revisionId==revisionId) {
      _activeImageRequest!.cancelled=true;_service?.cancel();
    }
  }

  /// 用户显式重试当前文档的失败/取消页；启动恢复仍只接续 queued。
  Future<void> retryRevision(String revisionId, {OcrTaskStatus? status}) => _admit(() async {
    _ensureAccepting();
    if (_cancelledRevisions.contains(revisionId)) {
      throw StateError('文字处理正在取消，请稍后继续。');
    }
    if (status != null && status != OcrTaskStatus.failed && status != OcrTaskStatus.cancelled) {
      throw ArgumentError.value(status, 'status');
    }
    final session = repository.sessionId;
    final tasks = await repository.listOcrTasks(revisionId: revisionId);
    final pages = tasks
        .where(
          (task) =>
              task.modelVersion == modelVersion &&
              (task.status == OcrTaskStatus.failed ||
                  task.status == OcrTaskStatus.cancelled) &&
              (status == null || task.status == status),
        )
        .map((task) => task.pageIndex)
        .toSet();
    _ensureSession(session);
    _ensureAccepting();
    if (pages.isEmpty) {
      await _refresh();
      return;
    }
    // force=false 也能恢复 failed/cancelled；并发已完成的页不能被强制重排。
    final queued = await repository.enqueueOcr(
      revisionId,
      pages,
      modelVersion: modelVersion,
    );
    _ensureSession(session);
    _ensureAccepting();
    _displayRevisionId = revisionId;
    for (final task in queued.where(
      (task) => task.status == OcrTaskStatus.queued,
    )) {
      _priority.remove(task.id);
      _priority.add(task.id);
    }
    lastError = null;
    await _refresh();
    _kick();
  });

  /// 恢复/切换资料库前停止接收新任务，等待当前页完整提交并释放 PDF 文件句柄。
  Future<void> pauseAndDrain() async {
    if (_disposed) return;
    _paused = true;
    _emit();
    await Future.wait(_admissions.toList());
    await _loop;
    await _closeDocument();
  }

  Future<void> resume() async {
    if (_disposed) return;
    _paused = false;
    _priority.clear();
    _readingPriority = null;
    await resumePending();
  }

  Future<void> cancel({String? revisionId}) async {
    if (_disposed || _cancelling) return;
    if (revisionId != null) {
      if (!_cancelledRevisions.add(revisionId)) return;
      _emit();
      try {
        // 只中止目标文档；等当前页释放后再允许继续处理，避免旧结果覆盖新任务。
        cancelEpubImages(revisionId);
        await repository.cancelOcr(revisionId: revisionId);
        if (_currentPageRevision == revisionId) {
          _renderCancellation?.cancel();
          _service?.cancel();
          await _currentPageDone?.future;
        }
        await _refresh();
      } finally {
        _cancelledRevisions.remove(revisionId);
        _emit();
      }
      return;
    }
    _cancelling = true;
    _generation++;
    _renderCancellation?.cancel();
    _service?.cancel();
    for(final request in _imageRequests) {
      request.done.completeError(const OcrCancelledException());
    }
    _imageRequests.clear();
    try {
      await Future.wait(_admissions.toList());
      await repository.cancelOcr();
      await _loop;
      await _closeDocument();
      _priority.clear();
      _readingPriority = null;
      await _refresh();
    } finally {
      _cancelling = false;
      _emit();
    }
  }

  /// 测试、备份等需要等待队列的入口；正常 UI 使用 ChangeNotifier 监听进度。
  Future<void> drain() async {
    while (_loop != null) {
      await _loop;
    }
  }

  void _kick() {
    if (_disposed || (_paused && _imageRequests.isEmpty) || _cancelling) return;
    if (_loop != null) {
      _wakeRequested = true;
      return;
    }
    _wakeRequested = false;
    _loop = _run().whenComplete(() {
      _loop = null;
      _emit();
      if (_wakeRequested) _kick();
    });
    _emit();
  }

  Future<void> _run() async {
    Object? initializationError;
    try {
      while (!_disposed && (!_paused || _imageRequests.isNotEmpty) && !_cancelling) {
        if(_imageRequests.isNotEmpty) {
          final request=_imageRequests.removeAt(0);
          _activeImageRevision=request.revisionId;
          _activeImageRequest=request;
          _emit();
          try {
            _ensureSession(request.session);
            if(request.generation != _generation || request.cancelled) throw const OcrCancelledException();
            if(initializationError != null) throw initializationError;
            try {_service ??= await _factory();} catch(error) {initializationError=error;rethrow;}
            final codec=await instantiateImageCodec(request.image,targetWidth:1800,allowUpscaling:false);
            try {
              final frame=await codec.getNextFrame();
              try {
                final pixels=await frame.image.toByteData(format:ImageByteFormat.rawRgba);
                final png=await frame.image.toByteData(format:ImageByteFormat.png);
                if(pixels==null || png==null) throw StateError('无法解码 EPUB 图片');
                if(request.generation != _generation || request.cancelled || _cancelling) throw const OcrCancelledException();
                final result=await _service!.recognize(pixels.buffer.asUint8List(pixels.offsetInBytes,pixels.lengthInBytes),
                  width:frame.image.width,height:frame.image.height,stride:frame.image.width*4);
                if(request.generation != _generation || request.cancelled || _cancelling) throw const OcrCancelledException();
                _ensureSession(request.session);
                await repository.saveEpubImageOcr(revisionId:request.revisionId,locator:request.locator,
                  image:png.buffer.asUint8List(png.offsetInBytes,png.lengthInBytes),text:result.text,
                  result:Map<String,dynamic>.from(result.toJson()),engineVersion:modelVersion,sessionId:request.session);
                request.done.complete(result);
              } finally {frame.image.dispose();}
            } finally {codec.dispose();}
          } catch(error,stack) {request.done.completeError(error,stack);}
          finally {_activeImageRevision=null;_activeImageRequest=null;_emit();}
          continue;
        }
        final session = repository.sessionId;
        final tasks = await repository.listOcrTasks();
        if (_disposed || _cancelling) break;
        if(_paused) {if(_imageRequests.isNotEmpty) continue;break;}
        final waiting = tasks
            .where((t) => t.status == OcrTaskStatus.queued)
            .toList();
        if (waiting.isEmpty) break;
        waiting.sort((a, b) {
          final reading = _readingPriority;
          if (reading != null && reading.session == session) {
            final ar = a.revisionId == reading.revision;
            final br = b.revisionId == reading.revision;
            if (ar != br) return ar ? -1 : 1;
            if (ar) {
              final distance = (a.pageIndex - reading.page).abs().compareTo(
                (b.pageIndex - reading.page).abs(),
              );
              if (distance != 0) return distance;
              // 等距时先准备下一页，再准备上一页。
              return b.pageIndex.compareTo(a.pageIndex);
            }
          }
          final ai = _priority.indexOf(a.id), bi = _priority.indexOf(b.id);
          if (ai >= 0 && bi >= 0) return ai.compareTo(bi);
          if (ai >= 0) return -1;
          if (bi >= 0) return 1;
          return 0;
        });
        final task = waiting.first;
        final generation = _generation;
        final pageDone = Completer<void>();
        _currentPageRevision = task.revisionId;
        _currentPageDone = pageDone;
        try {
          currentTask = await repository.claimOcrTask(
            task.id,
            sessionId: session,
          );
          _displayRevisionId = task.revisionId;
          await _refresh();
          if (task.modelVersion != modelVersion) {
            throw StateError('队列使用 ${task.modelVersion}，当前安装的是 $modelVersion。');
          }
          _ensureSession(session);
          // 持久任务可先于页框建立；跨启动恢复必须走同一元数据权威入口。
          final revision = await _ensureMetadata(
            task.revisionId,
            session,
            forRunningTask: true,
          );
          final documentRecord = await repository.getDocument(
            revision.documentId,
          );
          if (documentRecord.deletedAt != null) {
            throw StateError('文档已移入回收站，未执行 OCR。');
          }
          final document = await _openDocument(revision, session);
          _ensureSession(session);
          if (generation != _generation || _cancelling || _cancelledRevisions.contains(task.revisionId)) {
            throw const OcrCancelledException();
          }
          // 以 PDF 实际可见方向识别；/Rotate 可能用于把侧向扫描纠正为可读方向。
          final page = document.pages[task.pageIndex];
          await page.ensureLoaded();
          final geometry = revision.pageGeometry.firstWhere(
            (g) => g.pageIndex == task.pageIndex,
          );
          final native = await PdfReadEngine.extractNativeText(
            revisionId: revision.id,
            page: page,
            geometry: geometry,
          );
          if (generation != _generation || _cancelling || _cancelledRevisions.contains(task.revisionId)) {
            throw const OcrCancelledException();
          }
          _ensureSession(session);
          if (native.text.trim().isNotEmpty && native.fragments.isNotEmpty) {
            await repository.saveTextLayer(
              TextLayerDraft(
                revisionId: native.revisionId,
                pageIndex: native.pageIndex,
                source: native.source,
                text: native.text,
                fragments: native.fragments,
                engineVersion: native.engineVersion,
                parameters: {
                  ...native.parameters,
                  'pageGeometry': geometry.toJson(),
                  'recognitionRunId': const Uuid().v4(),
                },
              ),
              sessionId: session,
              ocrTaskId: task.id,
            );
            _priority.remove(task.id);
            continue;
          }
          // 原生文字为空才加载 OCR；安装故障在本轮只初始化一次，原生页仍可正常入库。
          if (_service == null) {
            if (initializationError != null) throw initializationError;
            try {
              _service = await _factory();
            } catch (error) {
              initializationError = error;
              rethrow;
            }
          }
          if (generation != _generation || _cancelling || _cancelledRevisions.contains(task.revisionId)) {
            throw const OcrCancelledException();
          }
          final scale = math.min(
            300 / 72 * geometry.userUnit,
            3600 / math.max(page.width, page.height),
          );
          final width = math.max(1, (page.width * scale).round());
          final height = math.max(1, (page.height * scale).round());
          _renderCancellation = page.createCancellationToken();
          final bitmap = await page.render(
            width: width,
            height: height,
            fullWidth: width.toDouble(),
            fullHeight: height.toDouble(),
            backgroundColor: 0xFFFFFFFF,
            annotationRenderingMode: pdf.PdfAnnotationRenderingMode.none,
            cancellationToken: _renderCancellation,
          );
          _renderCancellation = null;
          if (bitmap == null || generation != _generation || _cancelling || _cancelledRevisions.contains(task.revisionId)) {
            bitmap?.dispose();
            throw const OcrCancelledException();
          }
          late OcrResult result;
          try {
            if (generation != _generation || _cancelling || _cancelledRevisions.contains(task.revisionId)) {
              throw const OcrCancelledException();
            }
            result = await _service!.recognize(
              bitmap.pixels,
              width: bitmap.width,
              height: bitmap.height,
              stride: bitmap.width * 4,
              pixelFormat: OcrPixelFormat.bgra,
            );
          } finally {
            bitmap.dispose();
          }
          if (generation != _generation || _cancelling || _cancelledRevisions.contains(task.revisionId)) {
            throw const OcrCancelledException();
          }
          _ensureSession(session);
          final draft = ocrResultToTextLayer(
            result: result,
            revisionId: revision.id,
            page: page,
            geometry: geometry,
            runId: const Uuid().v4(),
          );
          await repository.saveTextLayer(
            draft,
            sessionId: session,
            ocrTaskId: task.id,
          );
          _priority.remove(task.id);
        } catch (error) {
          if (!_cancelling &&
              !_cancelledRevisions.contains(task.revisionId) &&
              generation == _generation &&
              repository.sessionId == session) {
            lastError = '$error';
            try {
              await repository.failOcrTask(
                task.id,
                '$error',
                sessionId: session,
              );
            } on RepositoryException catch (stale) {
              if (stale.code != RepositoryError.staleSession &&
                  stale.code != RepositoryError.notFound &&
                  stale.code != RepositoryError.conflict) {
                rethrow;
              }
            }
          }
        } finally {
          _renderCancellation = null;
          currentTask = null;
          _currentPageRevision = null;
          _currentPageDone = null;
          pageDone.complete();
          if (!_disposed) await _refresh();
        }
      }
    } catch (error) {
      lastError = '$error';
      _emit();
    } finally {
      await _closeDocument();
    }
  }

  Future<DocumentRevision> _ensureMetadata(
    String revisionId,
    String session, {
    bool forRunningTask = false,
  }) async {
    final revision = await repository.getRevision(revisionId);
    if (revision.pageCount > 0 &&
        revision.pageGeometry.length == revision.pageCount &&
        revision.pageGeometry.map((page) => page.pageIndex).toSet().length ==
            revision.pageCount &&
        revision.pageGeometry.every(
          (page) => page.pageIndex >= 0 && page.pageIndex < revision.pageCount,
        )) {
      return revision;
    }
    final path = await repository.resourcePath(revision.resourceId);
    final geometry = await PdfReadEngine.loadSourceGeometry(path);
    _ensureSession(session);
    // 已 claim 页在 pauseAndDrain 时继续排空；新入队调用仍须接受状态有效。
    if (!forRunningTask) _ensureAccepting();
    await repository.setRevisionMetadata(
      revisionId,
      pageCount: geometry.length,
      pageGeometry: geometry,
    );
    return repository.getRevision(revisionId);
  }

  Future<pdf.PdfDocument> _openDocument(
    DocumentRevision revision,
    String session,
  ) async {
    if (_document != null &&
        _documentRevisionId == revision.id &&
        _documentSessionId == session) {
      return _document!;
    }
    await _closeDocument();
    final path = await repository.resourcePath(revision.resourceId);
    _ensureSession(session);
    _document = await pdf.PdfDocument.openFile(path);
    _documentRevisionId = revision.id;
    _documentSessionId = session;
    if (_document!.pages.length != revision.pageCount) {
      throw StateError('PDF 页数与资料库记录不一致。');
    }
    return _document!;
  }

  Future<void> _closeDocument() async {
    final previous = _document;
    _document = null;
    _documentRevisionId = null;
    _documentSessionId = null;
    await previous?.dispose();
  }

  Future<void> _refresh() async {
    final session = repository.sessionId;
    final tasks = await repository.listOcrTasks();
    _ensureSession(session);
    _resetStatusSession(session);
    _tasks = tasks;
    _emit();
  }

  void _ensureAccepting() {
    if (_disposed || _paused || _cancelling) {
      throw StateError('OCR 队列已暂停或正在关闭。');
    }
  }

  Future<void> _admit(Future<void> Function() action) async {
    _ensureAccepting();
    final done = Completer<void>();
    _admissions.add(done.future);
    try {
      await action();
    } finally {
      _admissions.remove(done.future);
      done.complete();
    }
  }

  void _ensureSession(String session) {
    if (repository.sessionId != session) {
      throw const RepositoryException(
        RepositoryError.staleSession,
        'OCR 所属资料库会话已切换。',
      );
    }
  }

  void _emit() {
    if (!_disposed && !_notifierDisposed) notifyListeners();
  }

  Future<void> disposeAsync() => _disposing ??= _disposeAsync();
  Future<void> _disposeAsync() async {
    // 正常释放完成当前页并保留待处理页，下次启动继续；显式取消才改变任务状态。
    await pauseAndDrain();
    _disposed = true;
    await _service?.dispose();
    if (!_notifierDisposed) {
      _notifierDisposed = true;
      super.dispose();
    }
  }

  @override
  void dispose() {
    if (_notifierDisposed) return;
    _notifierDisposed = true;
    super.dispose();
    unawaited(disposeAsync());
  }
}

/// 字符串索引使用 UTF-16。每个 CTC token 的几何可对应多个 UTF-16 单元。
TextLayerDraft ocrResultToTextLayer({
  required OcrResult result,
  required String revisionId,
  required pdf.PdfPage page,
  required PdfPageGeometry geometry,
  String? runId,
}) {
  final adapter = PdfCoordinateAdapter(geometry);
  final size = Size(result.width.toDouble(), result.height.toDouble());
  final text = StringBuffer();
  final fragments = <TextFragment>[];
  var index = 0;
  for (final line in result.lines) {
    if (index > 0) {
      text.write('\n');
      index++;
    }
    if (line.characters.isEmpty) {
      fragments.add(
        TextFragment(
          start: index,
          length: line.text.length,
          quad: adapter.displayQuadToQuad(
            line.quad.map((p) => Offset(p.x, p.y)).toList(),
            page,
            size,
          ),
          order: fragments.length,
          confidence: line.confidence,
          precision: GeometryPrecision.line,
        ),
      );
    } else {
      var offset = index;
      for (final character in line.characters) {
        fragments.add(
          TextFragment(
            start: offset,
            length: character.text.length,
            quad: adapter.displayQuadToQuad(
              character.quad.map((p) => Offset(p.x, p.y)).toList(),
              page,
              size,
            ),
            order: fragments.length,
            confidence: character.confidence,
            precision: GeometryPrecision.approximateCharacter,
          ),
        );
        offset += character.text.length;
      }
      if (offset != index + line.text.length) {
        throw const FormatException('OCR 字符范围与行文本不一致。');
      }
    }
    text.write(line.text);
    index += line.text.length;
  }
  return TextLayerDraft(
    revisionId: revisionId,
    pageIndex: page.pageNumber - 1,
    source: TextLayerSource.ocr,
    text: text.toString(),
    fragments: fragments,
    engineVersion: OcrQueueController.modelVersion,
    parameters: {
      'formatVersion': 1,
      'recognitionRunId': ?runId,
      'coordinates': 'originalPdfUserSpace',
      'textIndex': 'utf16',
      'model': result.model,
      'backend': result.engine,
      'characterGeometry': 'approximateCtcAlignment',
      'readingOrder': result.readingOrder,
      'writingDirection': result.writingDirection,
      'directionDetection': result.directionDetection,
      'renderWidth': result.width,
      'renderHeight': result.height,
      'elapsedMs': result.elapsedMs,
      'pageGeometry': geometry.toJson(),
      'renderRotation': page.rotation.index * 90,
      'detectionMaxSide': 1536,
      'recognitionMaxWidth': 3200,
      'onnxruntime': '1.21.0',
    },
  );
}
