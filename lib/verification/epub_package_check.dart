import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart' show PdfDocument;

import '../data/open_note_repository.dart';
import '../domain/models.dart';
import '../engines/epub/epub_publication.dart';
import '../ui/reader/epub_reader_pane.dart';
import '../ui/reader/reader_contract.dart';

/// 候选分发程序使用正式 EPUB 阅读器验证；只接受显式的空资料目录。
class EpubPackageCheck extends StatefulWidget {
  const EpubPackageCheck({
    super.key,
    required this.startup,
    required this.sourcePath,
    required this.fixtureDirectory,
    required this.reportPath,
  });
  final Future<OpenNoteRepository> startup;
  final String sourcePath;
  final String fixtureDirectory;
  final String reportPath;
  @override
  State<EpubPackageCheck> createState() => _EpubPackageCheckState();
}

class _EpubPackageCheckState extends State<EpubPackageCheck> {
  final reader = ReaderPaneController();
  final report = <String, Object?>{
    'success': false,
    'databaseVersion': 11,
    'candidateBuild': OpenNoteRepository.candidateBuild,
    'defaultDataDirectoryName': OpenNoteRepository.defaultDataDirectoryName,
    'runtimeExecutable': Platform.resolvedExecutable,
  };
  OpenNoteRepository? repository;
  ManagedDocument? document;
  StudyProject? project;
  MindMap? map;
  ReadingPosition? position;
  String? cardId;
  String? path;
  bool closing = false, finished = false;
  int phase = 0;
  Timer? deadline;

  @override
  void initState() {
    super.initState();
    deadline = Timer(
      const Duration(seconds: 150),
      () => unawaited(finish(StateError('候选 EPUB 原生验收超时'))),
    );
    unawaited(prepare());
  }

  Future<void> prepare() async {
    try {
      final repo = repository = await widget.startup;
      if ((await repo.listProjects()).isNotEmpty) {
        throw StateError('候选验证资料目录必须为空');
      }
      project = await repo.createProject('候选 EPUB／PDF 原生验收');
      map = (await repo.listMaps(project!.id)).first;
      final pdf = await repo.importPdf(
        projectId: project!.id,
        filePath: p.join(
          widget.fixtureDirectory,
          'tools/fixtures/pdf/native.pdf',
        ),
      );
      final native = await PdfDocument.openFile(
        await repo.resourcePath(
          (await repo.getRevision(pdf.activeRevisionId)).resourceId,
        ),
      );
      try {
        if (native.pages.length != 2) throw StateError('候选 PDF 引擎未正确加载');
      } finally {
        await native.dispose();
      }
      document = await repo.importEpub(
        projectId: project!.id,
        filePath: widget.sourcePath,
      );
      path = await repo.resourcePath(
        (await repo.getRevision(document!.activeRevisionId)).resourceId,
      );
      report['sourceHash'] = (await repo.getRevision(
        document!.activeRevisionId,
      )).contentHash;
      if (mounted) setState(() {});
    } catch (error, stack) {
      await finish(error, stack);
    }
  }

  Future<dynamic> js(
    InAppWebViewController web,
    String body,
    Map<String, dynamic> arguments,
  ) async {
    final result = await web.callAsyncJavaScript(
      functionBody:
          '''try {
        const value=await (async()=>{ $body })();
        return {ok:true,value:value ?? null};
      } catch(error) {return {ok:false,error:String(error),stack:String(error.stack)};}''',
      arguments: arguments,
    );
    if (result?.error != null) throw StateError('${result!.error}');
    final envelope = result?.value;
    if (envelope is! Map || envelope['ok'] != true) {
      throw StateError('候选原生 JS 失败：$envelope');
    }
    return envelope['value'];
  }

  Future<void> ready(
    InAppWebViewController web,
    EpubPublication publication,
  ) async {
    try {
      final repo = repository!;
      if (phase == 0) {
        final data = Map<String, dynamic>.from(
          await js(web, 'return await window.openNote.probe(sectionIndex);', {
            'sectionIndex': publication.sections.length ~/ 2,
          }) as Map,
        );
        final locator = EpubLocator.fromJson(
          Map<String, dynamic>.from(data['anchor'] as Map),
        );
        await repo.saveEpubSection(
          document!.activeRevisionId,
          Map<String, dynamic>.from(data['index'] as Map),
          sessionId: repo.sessionId,
        );
        final excerpt = await repo.createExcerpt(
          ExcerptDraft(
            projectId: project!.id,
            mapId: map!.id,
            title: '真实 EPUB 来源',
            text: locator.quote,
            anchors: [
              AnchorDraft(
                revisionId: document!.activeRevisionId,
                epubLocator: locator,
              ),
            ],
          ),
        );
        cardId = excerpt.card.id;
        final hits = await repo.search(
          project!.id,
          locator.quote,
          documentId: document!.id,
        );
        final hit = hits.firstWhere((h) => h.epubLocator != null);
        await js(web, 'return await window.openNote.jump(anchor,70);', {
          'anchor': hit.epubLocator!.toJson(),
        });
        final copyProject = await repo.createProject('独立副本');
        final copyMap = (await repo.listMaps(copyProject.id)).first;
        final copy = await repo.copyBranch(excerpt.node.id, copyMap.id);
        await repo.updateCard(copy.cardIds[cardId]!, body: '独立修改');
        if ((await repo.getCard(cardId!)).body != excerpt.card.body) {
          throw StateError('副本影响原卡片');
        }
        position = ReadingPosition(
          revisionId: document!.activeRevisionId,
          epubLocator: locator,
          settings: const EpubReadingSettings(
            fontSize: 26,
            lineHeight: 2,
            paginated: true,
          ),
        );
        await repo.saveEpubPosition(position!, sessionId: repo.sessionId);
        report.addAll({
          'nativePdf': true,
          'nativeEpub': true,
          'reflowCfi': true,
          'searchCfi': true,
          'independentCopy': true,
          'spineSections': publication.sections.length,
          'sampledSection': data['sampledSection'],
          'visibleImages': data['imageCount'],
        });
        await closeReader();
        final backup = await repo.backupTo(
          p.join(p.dirname(widget.reportPath), 'mixed.opennote'),
        );
        await repo.restoreFrom(backup);
        position = await repo.loadReadingPosition(document!.activeRevisionId);
        path = await repo.resourcePath(
          (await repo.getRevision(document!.activeRevisionId)).resourceId,
        );
        if (mounted) {
          setState(() {
            phase = 1;
            closing = false;
          });
        }
      } else {
        final anchors = await repo.getAnchors(cardId!);
        for (final anchor in anchors) {
          await js(web, 'return await window.openNote.jump(anchor,80);', {
            'anchor': anchor.epubLocator!.toJson(),
          });
        }
        final pixels = await web.takeScreenshot();
        if (pixels == null || pixels.length < 100) {
          throw StateError('恢复后原生截图为空');
        }
        await File(p.join(p.dirname(widget.reportPath), 'restored-epub.png'))
            .writeAsBytes(pixels);
        final formats = (await repo.listDocuments(project!.id))
            .map((d) => d.format)
            .toSet();
        if (!formats.containsAll(DocumentFormat.values) ||
            position!.settings.fontSize != 26) {
          throw StateError('混合文档或排版设置恢复失败');
        }
        report.addAll({
          'mixedBackupRestore': true,
          'restoredOfflineCfi': true,
          'nativeCloseAcknowledged': true,
          'screenshotBytes': pixels.length,
          'success': true,
        });
        await finish();
      }
    } catch (error, stack) {
      await finish(error, stack);
    }
  }

  Future<void> closeReader() async {
    if (mounted) setState(() => closing = true);
    await WidgetsBinding.instance.endOfFrame;
    await reader.drainClosedDocuments();
  }

  Future<void> finish([Object? error, StackTrace? stack]) async {
    if (finished) return;
    finished = true;
    deadline?.cancel();
    if (error != null) {
      report.addAll({'success': false, 'error': '$error', 'stack': '$stack'});
    }
    try {
      await closeReader();
      await repository?.close();
    } catch (closeError) {
      report.addAll({'success': false, 'closeError': '$closeError'});
    }
    report['finishedAt'] = DateTime.now().toUtc().toIso8601String();
    await File(widget.reportPath).parent.create(recursive: true);
    await File(widget.reportPath).writeAsString(
      const JsonEncoder.withIndent('  ').convert(report),
      encoding: utf8,
    );
    await ServicesBinding.instance.exitApplication(
      ui.AppExitType.required,
      report['success'] == true ? 0 : 1,
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('EPUB／PDF 候选包隔离验收')),
    body: path == null
        ? const Center(child: CircularProgressIndicator())
        : EpubReaderPane(
            key: ValueKey(phase),
            revisionId: document!.activeRevisionId,
            filePath: path!,
            sessionId: repository!.sessionId,
            controller: reader,
            closing: closing,
            initialPosition: position,
            onExcerpt: (_) {},
            onProbeReady: ready,
          ),
  );
}
