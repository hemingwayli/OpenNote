import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';

/// 实际工作台的诊断挂点，仅在显式的独立目录计时模式下使用。
class StartupCheck {
  StartupCheck(this.reportPath) {
    _timeout = Timer(const Duration(seconds: 40), () {
      unawaited(_finish(error: '工作台或初始 PDF 预览未在40秒内就绪'));
    });
  }
  final String reportPath;
  final DateTime startedAt = DateTime.now().toUtc();
  late final Timer _timeout;
  DateTime? _workspaceReady;
  DateTime? _pdfReady;
  bool _finished = false;

  void workspaceReady() {
    _workspaceReady ??= DateTime.now().toUtc();
    _tryFinish();
  }

  void initialPdfReady() {
    _pdfReady ??= DateTime.now().toUtc();
    _tryFinish();
  }

  void _tryFinish() {
    if (_workspaceReady != null && _pdfReady != null) unawaited(_finish());
  }

  Future<void> _finish({String? error}) async {
    if (_finished) return;
    _finished = true;
    _timeout.cancel();
    final report = {
      'success': error == null,
      'runtimeExecutable': Platform.resolvedExecutable,
      'dartStartupAtUtc': startedAt.toIso8601String(),
      'workspaceReadyAtUtc': _workspaceReady?.toIso8601String(),
      'initialPdfReadyAtUtc': _pdfReady?.toIso8601String(),
      'workspaceReadyFromDartMs': _workspaceReady
          ?.difference(startedAt)
          .inMilliseconds,
      'initialPdfReadyFromDartMs': _pdfReady
          ?.difference(startedAt)
          .inMilliseconds,
      'pdfReadiness': '公开 onDocumentLoadFinished 成功后完成一帧；包括全部页尺寸和初始预览缓存，是首可见页的保守上界，不代表高分辨率细化或物理屏幕扫描时间',
      'error': ?error,
    };
    try {
      await File(reportPath).parent.create(recursive: true);
      await File(reportPath).writeAsString(
        const JsonEncoder.withIndent('  ').convert(report),
        encoding: utf8,
        flush: true,
      );
    } finally {
      // 使用真实工作台的退出流程提交编辑、排空队列并关闭资料库。
      await ServicesBinding.instance.exitApplication(
        ui.AppExitType.cancelable,
        error == null ? 0 : 1,
      );
    }
  }
}
