import '../theme/open_note_icon.dart';

import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';

import '../../application/ocr_queue.dart';
import '../../application/map_clipboard_controller.dart';
import '../../data/open_note_repository.dart';
import '../../engines/ocr/ocr_service.dart';
import '../workspace/workbench.dart';
import 'library_actions.dart';
import 'project_cover.dart';
import 'project_home.dart';

class OpenNoteShell extends StatefulWidget {
  const OpenNoteShell({
    super.key,
    required this.repository,
    this.initialProjectId,
    this.ocrServiceFactory,
    this.onWorkspaceReady,
    this.onInitialPdfReady,
  });
  final OpenNoteRepository repository;

  /// 仅供显式诊断／组件测试进入指定项目；普通应用启动不传此参数。
  final String? initialProjectId;
  final Future<NativeOcrService> Function()? ocrServiceFactory;
  final VoidCallback? onWorkspaceReady;
  final VoidCallback? onInitialPdfReady;
  @override
  State<OpenNoteShell> createState() => _OpenNoteShellState();
}

class _OpenNoteShellState extends State<OpenNoteShell> {
  late final OcrQueueController _ocr;
  late final AppLifecycleListener _lifecycle;
  late final StreamSubscription<int> _subscription;
  final _workbench = WorkbenchController();
  final _mapClipboard = MapClipboardController();
  late ProjectCoverCache _covers;
  late String _session;
  String? _projectId;
  bool _busy = false;
  bool _closed = false;
  Future<void>? _returnRequest;
  Future<AppExitResponse>? _exitRequest;
  Completer<void>? _pendingOperation;
  String? _error;

  @override
  void initState() {
    super.initState();
    _session = widget.repository.sessionId;
    _projectId = widget.initialProjectId;
    _covers = ProjectCoverCache(
      '${widget.repository.libraryPath}/cache/project-covers',
    );
    _ocr = OcrQueueController(
      widget.repository,
      serviceFactory: widget.ocrServiceFactory,
    );
    unawaited(
      _ocr.resumePending().catchError((Object error) {
        if (mounted) setState(() => _error = '$error');
      }),
    );
    _subscription = widget.repository.changes.listen((_) {
      if (!mounted) return;
      if (_session != widget.repository.sessionId) {
        _mapClipboard.clear();
        _covers.dispose();
        setState(() {
          _session = widget.repository.sessionId;
          _projectId = null;
          _covers = ProjectCoverCache(
            '${widget.repository.libraryPath}/cache/project-covers',
          );
        });
      }
    });
    _lifecycle = AppLifecycleListener(
      onExitRequested: () => _exitRequest ??= _exit(),
    );
  }

  Future<void> _openProject(String id) async {
    if (_busy || _projectId != null || _exitRequest != null) return;
    setState(() => _busy = true);
    final pending = _pendingOperation = Completer<void>();
    try {
      final project = (await widget.repository.listProjects())
          .where((p) => p.id == id)
          .firstOrNull;
      if (project == null) throw StateError('项目已不存在或已移入回收站');
      if (mounted) {
        setState(() {
          _projectId = id;
          _error = null;
        });
      }
    } finally {
      pending.complete();
      _pendingOperation = null;
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _returnHome() => _returnRequest ??= _leave();
  Future<void> _leave() async {
    setState(() => _busy = true);
    try {
      await _workbench.prepareToLeave();
      // 退出广播正在遍历生命周期观察者时，保留工作台子树直到退出决定完成。
      // 否则返回首页会先销毁仍在该次广播快照中的控件观察者。
      if (mounted && _exitRequest == null) {
        setState(() {
          _projectId = null;
          _error = null;
        });
      }
      await WidgetsBinding.instance.endOfFrame;
    } finally {
      _returnRequest = null;
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<AppExitResponse> _exit() async {
    setState(() => _busy = true);
    try {
      await _pendingOperation?.future;
      if (_returnRequest != null) await _returnRequest;
      await WidgetsBinding.instance.endOfFrame;
      await _workbench.prepareToLeave();
      await _ocr.pauseAndDrain();
      await _covers.disposeAndDrain();
      await widget.repository.close();
      _closed = true;
      await _ocr.disposeAsync();
      return AppExitResponse.exit;
    } catch (error) {
      _exitRequest = null;
      _workbench.cancelLeave();
      if (_covers.isDisposed) {
        _covers = ProjectCoverCache(
          '${widget.repository.libraryPath}/cache/project-covers',
        );
      }
      await _ocr.resume();
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$error';
        });
      }
      return AppExitResponse.cancel;
    }
  }

  Future<void> _libraryAction(String action) async {
    if (_busy || _projectId != null || _exitRequest != null) return;
    setState(() => _busy = true);
    final pending = _pendingOperation = Completer<void>();
    final actions = LibraryActions(
      context,
      widget.repository,
      beforeRestore: () async {
        await _ocr.pauseAndDrain();
        await _covers.disposeAndDrain();
      },
      afterRestore: () async {
        await _ocr.resume();
        if (mounted && _covers.isDisposed) {
          setState(() {
            _covers = ProjectCoverCache(
              '${widget.repository.libraryPath}/cache/project-covers',
            );
          });
        }
      },
    );
    try {
      await switch (action) {
        'backup' => actions.backup(),
        'restore' => actions.restore(),
        'trash' => actions.trash(),
        'licenses' => actions.licenses(),
        'undo' => widget.repository.undo(),
        'redo' => widget.repository.redo(),
        _ => Future<void>.value(),
      };
    } finally {
      pending.complete();
      _pendingOperation = null;
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _subscription.cancel();
    _covers.dispose();
    if (!_closed) unawaited(_ocr.disposeAsync());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      ProjectHome(
        key: ValueKey('project-home-$_session'),
        repository: widget.repository,
        covers: _covers,
        active: _projectId == null,
        busy: _busy || _exitRequest != null,
        onOpenProject: _openProject,
        onLibraryAction: _libraryAction,
      ),
      if (_projectId != null)
        Workbench(
          key: ValueKey('workbench-$_session-$_projectId'),
          repository: widget.repository,
          projectId: _projectId!,
          ocr: _ocr,
          controller: _workbench,
          mapClipboard: _mapClipboard,
          onReturnHome: _returnHome,
          onWorkspaceReady: widget.onWorkspaceReady,
          onInitialPdfReady: widget.onInitialPdfReady,
        ),
      if (_error != null)
        Positioned(
          left: 24,
          right: 24,
          bottom: 16,
          child: Material(
            color: Theme.of(context).colorScheme.errorContainer,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(child: Text(_error!)),
                  IconButton(
                    onPressed: () => setState(() => _error = null),
                    icon: const OpenNoteIcon(Icons.close),
                  ),
                ],
              ),
            ),
          ),
        ),
    ],
  );
}
