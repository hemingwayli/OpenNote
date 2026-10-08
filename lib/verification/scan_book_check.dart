import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';

import '../application/ocr_queue.dart';
import '../data/open_note_repository.dart';
import '../domain/models.dart' as model;
import '../engines/pdf/pdf_read_engine.dart';
import '../engines/pdf/pdf_text_selection.dart';

/// 本机扫描书诊断入口。正文仅保存在专用资料库，报告只保存指标。
Future<void> runScanBookCheck({
  required Future<OpenNoteRepository> startup,
  required String sourcePath,
  required String reportPath,
  bool resumeExisting = false,
}) async {
  final report = <String, Object?>{
    'formatVersion': 1,
    'success': false,
    'processingVersion': OcrQueueController.modelVersion,
    'runtimeExecutable': Platform.resolvedExecutable,
    'startedAt': DateTime.now().toUtc().toIso8601String(),
    'resumeExisting': resumeExisting,
    'scope':
        'Local user-authorized scan; formal PDF/OCR/repository pipeline. '
        'Metrics only, no book text or images in report; no UI gesture claim.',
  };
  final total = Stopwatch()..start();
  OpenNoteRepository? repository;
  OcrQueueController? queue;
  PdfDocument? document;
  Future<void> progressWrite = Future<void>.value();
  Object? progressError;
  final progressPath = p.join(p.dirname(reportPath), 'progress.json');
  String stage = 'startup';
  List<int> selected = [];
  Map<String, Object?>? marker;
  void Function()? listener;
  try {
    repository = await startup;
    var repo = repository;
    final source = File(p.absolute(sourcePath));
    _require(await source.exists(), '指定的扫描 PDF 不存在');
    final sourceHash = await _fileHash(source.path);
    report['sourceSha256'] = sourceHash;
    report['sourceBytes'] = await source.length();
    final markerPath = p.join(repo.rootPath, '.scan-book-verification.json');
    if (resumeExisting) {
      _require(await File(markerPath).exists(), '该资料目录没有扫描书验证标识，拒绝操作普通资料库');
      marker = Map<String, Object?>.from(
        jsonDecode(await File(markerPath).readAsString(encoding: utf8)) as Map,
      );
      _require(
        marker['formatVersion'] == 1 &&
            marker['kind'] == 'opennote-local-scan-book-verification' &&
            marker['sourceSha256'] == sourceHash &&
            marker['processingVersion'] == OcrQueueController.modelVersion,
        '专用验证标识、源文件哈希或 OCR 处理版本不匹配',
      );
      final projects = await repo.listProjects(includeDeleted: true);
      _require(
        projects.length == 1 &&
            projects.single.id == marker['projectId'] &&
            projects.single.title == '扫描书专用验证',
        '资料目录包含普通项目或验证项目不一致',
      );
    } else {
      _require(
        (await repo.listProjects(includeDeleted: true)).isEmpty,
        '首次扫描书验证必须使用空的专用资料目录',
      );
      _require(!await File(markerPath).exists(), '已有扫描验证标识，请显式使用续跑参数');
      document = await PdfDocument.openFile(source.path);
      final count = document.pages.length;
      _require(count >= 5, '扫描书少于五页，无法进行前中后五页验证');
      selected = _initialPages(count);
      final project = await repo.createProject('扫描书专用验证');
      final maps = await repo.listMaps(project.id);
      final imported = await repo.importPdf(
        projectId: project.id,
        filePath: source.path,
        title: '本机扫描书样本',
        pageCount: count,
      );
      marker = {
        'formatVersion': 1,
        'kind': 'opennote-local-scan-book-verification',
        'sourceSha256': sourceHash,
        'processingVersion': OcrQueueController.modelVersion,
        'projectId': project.id,
        'mapId': maps.first.id,
        'revisionId': imported.activeRevisionId,
        'pageCount': count,
        'selectedPageIndices': selected,
        'cardsByPage': <String, String>{},
        'runCount': 0,
      };
      await _writeJson(markerPath, marker);
      await document.dispose();
      document = null;
    }
    final state = marker;
    final projectId = state['projectId'] as String;
    final revisionId = state['revisionId'] as String;
    final pageCount = state['pageCount'] as int;
    selected = (state['selectedPageIndices'] as List).cast<int>();
    _require(
      selected.length >= 5 &&
          selected.length <= 8 &&
          selected.toSet().length == selected.length &&
          selected.every((page) => page >= 0 && page < pageCount),
      '验证采样页不合法',
    );
    final revision = await repo.getRevision(revisionId);
    final managed = await repo.getDocument(revision.documentId);
    _require(
      revision.contentHash == sourceHash && managed.projectId == projectId,
      '托管文档与验证标识不一致',
    );
    final beforeLayers = await repo.loadTextLayers(
      revisionId,
      pageIndices: selected,
    );
    final beforeTasks = await repo.listOcrTasks(revisionId: revisionId);
    report['reusedCompletedPagesAtStartup'] = beforeLayers.length;
    report['taskStatusAtStartup'] = {
      for (final status in model.OcrTaskStatus.values)
        status.name: beforeTasks.where((task) => task.status == status).length,
    };
    state['runCount'] = (state['runCount'] as int) + 1;
    await _writeJson(markerPath, state);
    report['runCount'] = state['runCount'];
    report['pageCount'] = pageCount;
    report['initialSamplePagesOneBased'] = selected
        .map((page) => page + 1)
        .toList();
    queue = OcrQueueController(repo);
    final work = queue;
    void writeProgress() {
      final snapshot = <String, Object?>{
        'formatVersion': 1,
        'stage': stage,
        'runCount': state['runCount'],
        'samplePagesOneBased': selected.map((page) => page + 1).toList(),
        'completedPages': work.completedCount,
        'reusedCompletedPagesAtStartup': beforeLayers.length,
        'currentPageOneBased': work.currentPageIndex == null
            ? null
            : work.currentPageIndex! + 1,
        'queuedPages': work.pendingCount,
        'failedPages': work.failedCount,
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
      };
      progressWrite = progressWrite
          .then((_) => _writeJson(progressPath, snapshot))
          .catchError((Object error) {
            progressError = error;
          });
    }

    listener = writeProgress;
    work.addListener(listener);
    stage = 'ocr';
    writeProgress();
    final processing = Stopwatch()..start();
    // 先落盘全部有限任务，再启动同一个正式持久队列，便于进程中断后恢复。
    final completed = beforeLayers.map((layer) => layer.pageIndex).toSet();
    await repo.enqueueOcr(
      revisionId,
      selected.where((page) => !completed.contains(page)),
      modelVersion: OcrQueueController.modelVersion,
      force: true,
    );
    await work.resumePending();
    await work.drain();
    _require(work.lastError == null, '扫描页处理失败：${work.lastError}');
    var layers = await repo.loadTextLayers(revisionId, pageIndices: selected);
    var textPages = layers.where(_isTextPage).toList();
    // 封面/空白采样至多增加三页，整次诊断最多排八页，不处理整本书。
    for (final base in List<int>.from(selected)) {
      if (textPages.length >= 5 || selected.length >= 8) break;
      final candidate = math.min(pageCount - 1, base + 1);
      if (selected.contains(candidate)) continue;
      selected.add(candidate);
      selected.sort();
      state['selectedPageIndices'] = selected;
      await _writeJson(markerPath, state);
      await work.enqueuePage(revisionId, candidate);
      await work.drain();
      _require(work.lastError == null, '补充文本页处理失败：${work.lastError}');
      layers = await repo.loadTextLayers(revisionId, pageIndices: selected);
      textPages = layers.where(_isTextPage).toList();
    }
    processing.stop();
    report['processingWallMs'] = processing.elapsedMilliseconds;
    report['samplePagesOneBased'] = selected.map((page) => page + 1).toList();
    report['textPageCount'] = textPages.length;
    _require(textPages.length >= 5, '八页有限采样中不足五个有效文本页');
    _require(
      textPages
              .where((layer) => layer.source == model.TextLayerSource.ocr)
              .length >=
          5,
      '采样中不足五个实际 OCR 文本页',
    );
    stage = 'search-excerpt-source';
    writeProgress();
    final actualRevision = await repo.getRevision(revisionId);
    document = await PdfDocument.openFile(
      await repo.resourcePath(actualRevision.resourceId),
    );
    final geometry = await PdfReadEngine.loadGeometry(
      document,
      filePath: await repo.resourcePath(actualRevision.resourceId),
    );
    final cards = Map<String, String>.from(state['cardsByPage'] as Map);
    final checks = <Map<String, Object?>>[];
    final saved = <_SavedExcerpt>[];
    for (final layer in textPages.take(5)) {
      final match = RegExp(r'[\u3400-\u9fff]{2,}')
          .allMatches(layer.text)
          .firstWhere(
            (match) => match.start >= 20,
            orElse: () =>
                RegExp(r'[\u3400-\u9fff]{2,}').firstMatch(layer.text) ??
                (throw StateError('采样页没有可用于短中文搜索的连续文字')),
          );
      final query = layer.text.substring(match.start, match.start + 2);
      final hits = await repo.search(projectId, query);
      _require(
        hits.any(
          (hit) =>
              hit.revisionId == revisionId &&
              hit.pageIndex == layer.pageIndex &&
              hit.textLayerId == layer.id &&
              hit.quads.isNotEmpty,
        ),
        '采样页短中文搜索未返回同一文字层与字框',
      );
      final anchors = selectTextAcrossPages(
        revisionId: revisionId,
        a: PdfSelectionPoint(layer.pageIndex, match.start, match.start + 2),
        b: PdfSelectionPoint(layer.pageIndex, match.start, match.start + 2),
        layerForPage: (page) => page == layer.pageIndex
            ? PdfSelectableText.fromPersisted(layer)
            : null,
      );
      _require(
        anchors.length == 1 && anchors.single.quads.isNotEmpty,
        '共同选文函数没有生成文字锚点',
      );
      final key = '${layer.pageIndex}';
      String cardId;
      if (cards[key] case final String existing) {
        cardId = existing;
        _require(
          (await repo.getCard(cardId)).excerptSnapshot == query,
          '已保存诊断卡片不一致',
        );
      } else {
        final excerpt = await repo.createExcerpt(
          model.ExcerptDraft(
            projectId: projectId,
            mapId: state['mapId'] as String,
            title: '采样第${layer.pageIndex + 1}页',
            text: query,
            anchors: anchors,
            x: 80,
            y: 80 + checks.length * 100,
          ),
        );
        cardId = excerpt.card.id;
        cards[key] = cardId;
        state['cardsByPage'] = cards;
        await _writeJson(markerPath, state);
      }
      final sourceAnchors = await repo.getAnchors(cardId);
      _require(
        sourceAnchors.length == 1 &&
            sourceAnchors.single.textLayerId == layer.id &&
            sourceAnchors.single.revisionId == revisionId &&
            sourceAnchors.single.pageIndex == layer.pageIndex,
        '保存后的来源页或文字层版本不一致',
      );
      final page = document.pages[layer.pageIndex];
      await page.ensureLoaded();
      final coordinates = PdfCoordinateAdapter(geometry[layer.pageIndex]);
      final size = Size(page.width, page.height);
      final pageRect = Offset.zero & size;
      var maxError = 0.0;
      var outside = 0;
      for (final quad in sourceAnchors.single.quads) {
        final offsets = quad.points
            .map(
              (point) => PdfPoint(
                point.x - coordinates.effectiveBox.left,
                point.y - coordinates.effectiveBox.top,
              ).toOffsetInDocument(page: page, pageRect: pageRect),
            )
            .toList();
        final back = coordinates.displayQuadToQuad(offsets, page, size);
        for (var i = 0; i < 4; i++) {
          maxError = math.max(
            maxError,
            math.sqrt(
              math.pow(back.points[i].x - quad.points[i].x, 2) +
                  math.pow(back.points[i].y - quad.points[i].y, 2),
            ),
          );
        }
        if (quad.points.any(
          (point) =>
              point.x < coordinates.effectiveBox.left - 2 ||
              point.x > coordinates.effectiveBox.right + 2 ||
              point.y < coordinates.effectiveBox.top - 2 ||
              point.y > coordinates.effectiveBox.bottom + 2,
        )) {
          outside++;
        }
      }
      _require(maxError < 0.0001 && outside == 0, '回源四边形超出页框或坐标往返不一致');
      saved.add(_SavedExcerpt(layer.pageIndex, cardId, query, layer.id));
      checks.add({
        'pageOneBased': layer.pageIndex + 1,
        'source': layer.source.name,
        'textUtf16Length': layer.text.length,
        'cjkCodepoints': _cjkCount(layer.text),
        'fragmentCount': layer.fragments.length,
        'elapsedNativeMs': layer.parameters['elapsedMs'],
        'renderWidth': layer.parameters['renderWidth'],
        'renderHeight': layer.parameters['renderHeight'],
        'readingOrder': layer.parameters['readingOrder'],
        'writingDirection': layer.parameters['writingDirection'],
        'shortChineseSearchMatched': true,
        'excerptSaved': true,
        'sourceAnchorMatched': true,
        'selectedQuadCount': sourceAnchors.single.quads.length,
        'coordinateRoundtripMaxErrorPdfUnits': maxError,
        'outOfEffectiveBoxQuads': outside,
        'geometryPrecision': 'approximateCharacter',
        'scope': 'Coordinate roundtrip and bounds; no manual glyph-edge precision claim.',
      });
    }
    report['pages'] = checks;
    await document.dispose();
    document = null;
    stage = 'backup-reopen';
    writeProgress();
    await work.pauseAndDrain();
    final backupPath = p.join(
      p.dirname(reportPath),
      'scan-book-${DateTime.now().microsecondsSinceEpoch}.opennote',
    );
    final backupWatch = Stopwatch()..start();
    await repo.backupTo(backupPath);
    await repo.restoreFrom(backupPath);
    backupWatch.stop();
    await work.disposeAsync();
    queue = null;
    final libraryRoot = repo.rootPath;
    await repo.close();
    repository = null;
    repo = await OpenNoteRepository.open(rootPath: libraryRoot);
    repository = repo;
    for (final item in saved) {
      final card = await repo.getCard(item.cardId);
      final anchors = await repo.getAnchors(item.cardId);
      final current = await repo.loadTextLayers(
        revisionId,
        pageIndex: item.pageIndex,
      );
      _require(
        card.excerptSnapshot == item.query &&
            anchors.single.textLayerId == item.layerId &&
            current.single.id == item.layerId,
        '备份恢复并重开后摘录或来源版本改变',
      );
      _require(
        (await repo.search(projectId, item.query)).any(
          (hit) =>
              hit.revisionId == revisionId &&
              hit.pageIndex == item.pageIndex &&
              hit.textLayerId == item.layerId,
        ),
        '重开后扫描文字搜索失败',
      );
    }
    final reopenedRevision = await repo.getRevision(revisionId);
    _require(
      await _fileHash(await repo.resourcePath(reopenedRevision.resourceId)) ==
          sourceHash,
      '备份重开后的托管 PDF 字节不一致',
    );
    _require(await _fileHash(source.path) == sourceHash, '原始 PDF 字节发生改变');
    report.addAll({
      'success': true,
      'backupRestoreAndReopen': true,
      'backupRestoreMs': backupWatch.elapsedMilliseconds,
      'sourceBytesUnchanged': true,
      'managedResourceHashMatched': true,
      'excerptCount': saved.length,
      'reportContainsBookText': false,
      'manualRecognitionQualityMeasured': false,
    });
    stage = 'complete';
    writeProgress();
  } catch (error, trace) {
    report['error'] = '$error';
    report['stackTrace'] = '$trace';
    stage = 'failed';
  } finally {
    if (listener != null && queue != null) queue.removeListener(listener);
    try {
      await document?.dispose();
      await queue?.disposeAsync();
    } catch (error) {
      report['disposeError'] = '$error';
    }
    try {
      await repository?.close();
    } catch (error) {
      report['closeError'] = '$error';
    }
    await progressWrite;
    if (progressError != null) report['progressWriteError'] = '$progressError';
    report['elapsedMs'] = total.elapsedMilliseconds;
    await _writeJson(reportPath, report);
    await ServicesBinding.instance.exitApplication(
      ui.AppExitType.required,
      report['success'] == true ? 0 : 1,
    );
  }
}

List<int> _initialPages(int count) => [
  .05,
  .25,
  .5,
  .75,
  .95,
].map((fraction) => ((count - 1) * fraction).round()).toSet().toList()..sort();

int _cjkCount(String text) => text.runes
    .where(
      (code) =>
          (code >= 0x3400 && code <= 0x9fff) ||
          (code >= 0x20000 && code <= 0x3134f),
    )
    .length;

bool _isTextPage(model.PageTextLayer layer) =>
    _cjkCount(layer.text) >= 40 && layer.fragments.length >= 40;

Future<String> _fileHash(String path) => Isolate.run(
  () async => (await sha256.bind(File(path).openRead()).first).toString(),
);

Future<void> _writeJson(String path, Map<String, Object?> value) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  final pending = File('$path.pending');
  await pending.writeAsString(
    const JsonEncoder.withIndent('  ').convert(value),
    encoding: utf8,
    flush: true,
  );
  await pending.rename(path);
}

void _require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

class _SavedExcerpt {
  const _SavedExcerpt(this.pageIndex, this.cardId, this.query, this.layerId);
  final int pageIndex;
  final String cardId;
  final String query;
  final String layerId;
}
