import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart' show PdfDocument;

import '../application/ocr_queue.dart';
import '../data/open_note_repository.dart';
import '../domain/models.dart';

/// 安装包自检复用正式业务模块；必须显式指定一个空的验证资料目录。
Future<void> runOfflineCheck({
  required Future<OpenNoteRepository> startup,
  required String fixtureDirectory,
  required String reportPath,
  bool auditExisting = false,
}) async {
  final report = <String, Object?>{
    'version': '0.1.0',
    'success': false,
    'runtimeExecutable': Platform.resolvedExecutable,
    'startedAt': DateTime.now().toUtc().toIso8601String(),
  };
  final stopwatch = Stopwatch()..start();
  OpenNoteRepository? repository;
  OcrQueueController? queue;
  try {
    repository = await startup;
    final repo = repository;
    if (auditExisting) {
      report.addAll(await _auditExisting(repo));
      return;
    }
    _check((await repo.listProjects()).isEmpty, '验证资料目录必须为空');
    final project = await repo.createProject('离线交付验证');
    final map = (await repo.listMaps(project.id)).first;
    final native = await repo.importPdf(
      projectId: project.id,
      filePath: p.join(
        fixtureDirectory,
        'tools',
        'fixtures',
        'pdf',
        'native.pdf',
      ),
    );
    final scanned = await repo.importPdf(
      projectId: project.id,
      filePath: p.join(
        fixtureDirectory,
        'test',
        'ocr',
        'fixtures',
        'scanned_rotated.pdf',
      ),
    );
    queue = OcrQueueController(repo);
    final ocrWatch = Stopwatch()..start();
    await queue.enqueueRevision(native.activeRevisionId);
    await queue.enqueueRevision(scanned.activeRevisionId, priorityPage: 2);
    await queue.drain();
    ocrWatch.stop();
    _check(queue.lastError == null, '文字处理失败：${queue.lastError}');
    final nativeLayers = await repo.loadTextLayers(native.activeRevisionId);
    final scannedLayers = await repo.loadTextLayers(scanned.activeRevisionId);
    _check(
      nativeLayers.length == 2 &&
          nativeLayers.every((l) => l.source == TextLayerSource.nativePdf),
      '原生文字提取未完成',
    );
    _check(
      scannedLayers.length == 4 &&
          scannedLayers.every((l) => l.source == TextLayerSource.ocr),
      '扫描页识别未完成',
    );
    final singleCharacter = await repo.search(project.id, '知');
    final shortQuery = await repo.search(project.id, '知识');
    _check(singleCharacter.isNotEmpty && shortQuery.length == 4, '短中文搜索失败');
    final hit = shortQuery.first;
    final excerpt = await repo.createExcerpt(
      ExcerptDraft(
        projectId: project.id,
        mapId: map.id,
        title: '扫描书摘录',
        text: hit.text.substring(hit.start, hit.end),
        anchors: [
          AnchorDraft(
            revisionId: hit.revisionId!,
            pageIndex: hit.pageIndex!,
            quads: hit.quads,
            textLayerId: hit.textLayerId,
            textStart: hit.start,
            textEnd: hit.end,
          ),
        ],
        x: 80,
        y: 80,
      ),
    );
    final child = await repo.createExcerpt(
      ExcerptDraft(
        projectId: project.id,
        mapId: map.id,
        title: '独立编辑测试',
        text: '子卡片内容',
        parentNodeId: excerpt.node.id,
        x: 380,
        y: 80,
      ),
    );
    await repo.addAssociation(excerpt.node.id, child.node.id);
    final copyMap = await repo.createMap(project.id, '分支副本');
    final copy = await repo.copyBranch(excerpt.node.id, copyMap.id);
    await repo.updateCard(
      copy.cardIds[excerpt.card.id]!,
      body: '副本独立修改',
      note: '副本备注',
    );
    _check(
      (await repo.getCard(excerpt.card.id)).body == excerpt.card.body,
      '副本影响了原卡片',
    );
    await repo.trashDocument(scanned.id);
    final sourceRevision = await repo.getRevision(
      (await repo.getAnchors(excerpt.card.id)).first.revisionId,
    );
    final pdf = await PdfDocument.openFile(
      await repo.resourcePath(sourceRevision.resourceId),
    );
    try {
      _check(pdf.pages.length == 4, 'PDF 移入回收站后无法回源');
    } finally {
      await pdf.dispose();
    }
    final backup = p.join(p.dirname(reportPath), 'offline-check.onbackup');
    await queue.pauseAndDrain();
    await repo.backupTo(backup);
    final oldSession = repo.sessionId;
    await repo.updateCard(excerpt.card.id, body: '备份之后的修改');
    await repo.restoreFrom(backup);
    _check(repo.sessionId != oldSession && !repo.canUndo, '恢复后会话未隔离');
    _check(
      (await repo.getCard(excerpt.card.id)).body == excerpt.card.body,
      '恢复数据不一致',
    );
    var staleRejected = false;
    try {
      await repo.saveTextLayer(
        TextLayerDraft(
          revisionId: native.activeRevisionId,
          pageIndex: 0,
          source: TextLayerSource.nativePdf,
          text: '过期结果',
          fragments: const [],
          engineVersion: 'verification',
        ),
        sessionId: oldSession,
      );
    } on RepositoryException catch (error) {
      staleRejected = error.code == RepositoryError.staleSession;
    }
    _check(staleRejected, '旧会话结果未拒绝');
    report.addAll({
      'success': true,
      'nativePages': nativeLayers.length,
      'ocrPages': scannedLayers.length,
      'shortChineseHits': shortQuery.length,
      'processingElapsedMs': ocrWatch.elapsedMilliseconds,
      'independentCopy': true,
      'sourceAfterPdfTrash': true,
      'backupRestore': true,
      'staleSessionRejected': true,
      'libraryPath': repo.libraryPath,
    });
  } catch (error, trace) {
    report['error'] = '$error';
    report['stackTrace'] = '$trace';
  } finally {
    try {
      await queue?.disposeAsync();
    } catch (error) {
      report['disposeError'] = '$error';
    }
    try {
      await repository?.close();
    } catch (error) {
      report['closeError'] = '$error';
    }
    report['elapsedMs'] = stopwatch.elapsedMilliseconds;
    await File(reportPath).parent.create(recursive: true);
    await File(reportPath).writeAsString(
      const JsonEncoder.withIndent('  ').convert(report),
      encoding: utf8,
      flush: true,
    );
    await ServicesBinding.instance.exitApplication(
      ui.AppExitType.required,
      report['success'] == true ? 0 : 1,
    );
  }
}

Future<Map<String, Object?>> _auditExisting(OpenNoteRepository repo) async {
  final projects = await repo.listProjects();
  final project = projects.firstWhere((p) => p.title == '离线交付验证');
  final cards = await repo.listCards(project.id);
  final maps = await repo.listMaps(project.id);
  _check(cards.length == 4 && maps.length == 2, '重装后项目、卡片或脑图记录丢失');
  final excerpt = cards.firstWhere((c) => c.title == '扫描书摘录' && c.body == '知识');
  final anchors = await repo.getAnchors(excerpt.id);
  final revision = await repo.getRevision(anchors.first.revisionId);
  final document = await repo.getDocument(revision.documentId);
  _check(document.deletedAt != null, '重装后回收站状态改变');
  final layers = await repo.loadTextLayers(revision.id);
  _check(
    layers.length == 4 && layers.any((l) => l.id == anchors.first.textLayerId),
    '重装后 OCR 或来源锚点丢失',
  );
  final pdf = await PdfDocument.openFile(
    await repo.resourcePath(revision.resourceId),
  );
  try {
    _check(pdf.pages.length == 4, '重装后原文资源不可用');
  } finally {
    await pdf.dispose();
  }
  return {
    'success': true,
    'existingLibraryAudit': true,
    'projects': projects.length,
    'cards': cards.length,
    'maps': maps.length,
    'sourceAfterPdfTrash': true,
    'ocrLayers': layers.length,
    'libraryPath': repo.libraryPath,
  };
}

void _check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

class OfflineCheckScreen extends StatelessWidget {
  const OfflineCheckScreen({super.key});
  @override
  Widget build(BuildContext context) => const MaterialApp(
    home: Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 20),
            Text('OpenNote 正在验证离线交付模块…'),
          ],
        ),
      ),
    ),
  );
}
