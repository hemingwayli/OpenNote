import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_driver/driver_extension.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:opennote/application/ocr_queue.dart';
import 'package:opennote/application/workspace_controller.dart';
import 'package:opennote/data/open_note_repository.dart';
import 'package:opennote/ui/theme/open_note_theme.dart';
import 'package:opennote/ui/workspace/workbench.dart';

/// 驱动真实工作台与原生 WebView2，只允许显式独立资料目录。
Future<void> main() async {
  late Future<String> Function(String?) requests;
  final initialized = Completer<void>();
  enableFlutterDriverExtension(
    handler: (request) async {
      await initialized.future;
      return requests(request);
    },
  );
  final root = Platform.environment['OPENNOTE_EPUB_PROBE_ROOT'];
  final book = Platform.environment['OPENNOTE_EPUB_REAL_BOOK'];
  if (root == null ||
      book == null ||
      !Directory(root).absolute.path.contains('.local')) {
    throw ArgumentError('真实书籍验收必须提供独立 .local 资料目录与 EPUB 路径');
  }
  await pdfrxFlutterInitialize();
  final repo = await OpenNoteRepository.open(rootPath: root);
  final project = await repo.createProject('EPUB 与 PDF 隔离验收');
  await repo.createMap(project.id, '学习脑图');
  final setup = WorkspaceController(repo);
  await setup.initialize(projectId: project.id);
  final pdf = await setup.importDocument('tools/fixtures/pdf/native.pdf');
  final media = await setup.importDocument(
    'tools/fixtures/epub/epub3-reflow.epub',
  );
  final epub = await setup.importDocument(book);
  final epubHash = (await repo.getRevision(epub.activeRevisionId)).contentHash;
  await setup.persistResume();
  setup.dispose();
  final ocr = OcrQueueController(repo);
  final lifecycle = WorkbenchController();
  InAppWebViewController? web;
  var ready = 0;
  String? webRevision;
  void mount() {
    runApp(
      MaterialApp(
        theme: openNoteTheme(),
        home: Workbench(
          repository: repo,
          projectId: project.id,
          ocr: ocr,
          controller: lifecycle,
          onReturnHome: () async {},
          onEpubReady: (controller, publication) async {
            web = controller;
            webRevision = publication.contentHash == epubHash
                ? epub.activeRevisionId
                : media.activeRevisionId;
            ready++;
          },
        ),
      ),
    );
  }

  final directory = Directory('.local/verification/epub-pdf/workbench');
  await directory.create(recursive: true);
  Future<dynamic> js(
    String body, {
    Map<String, dynamic> arguments = const {},
  }) async {
    if (web == null) throw StateError('EPUB 尚未就绪');
    final value = await web!.callAsyncJavaScript(
      functionBody:
          '''try {
        const value=await (async()=>{ $body })();
        return {ok:true,value:value ?? null};
      } catch(error) {return {ok:false,error:String(error),stack:String(error.stack)};}''',
      arguments: arguments,
    );
    if (value?.error != null) throw StateError(value!.error.toString());
    final envelope = value?.value;
    if (envelope is! Map || envelope['ok'] != true) {
      throw StateError('原生 JS 验收失败：$envelope');
    }
    return envelope['value'];
  }

  requests = (request) async {
    final command = jsonDecode(request!) as Map<String, dynamic>;
    switch (command['action']) {
      case 'state':
        final cards = await repo.listCards(project.id);
        final maps = await repo.listMaps(project.id);
        final map = await repo.loadMap(maps.first.id);
        final position = await repo.loadReadingPosition(epub.activeRevisionId);
        final resume = await repo.loadProjectResume(project.id);
        return jsonEncode({
          'ready': ready,
          'epub': epub.id,
          'pdf': pdf.id,
          'media': media.id,
          'mediaRevision': media.activeRevisionId,
          'webRevision': webRevision,
          'revision': epub.activeRevisionId,
          'cards': cards
              .map(
                (c) => {
                  'id': c.id,
                  'title': c.title,
                  'text': c.excerptSnapshot,
                  'image': c.imageResourceId,
                },
              )
              .toList(),
          'nodes': map.nodes
              .map((n) => {'id': n.id, 'card': n.cardId})
              .toList(),
          'indexed': (await repo.indexedEpubSections(epub.activeRevisionId))
              .length,
          'active': resume?.activeDocumentId,
          'settings': position?.settings.toJson(),
        });
      case 'select':
        final data = await js('return await window.openNote.probe();');
        final anchor = (data as Map)['anchor'];
        await js(
          'await window.openNote.jump(anchor,30);',
          arguments: {'anchor': anchor},
        );
        await js(
          '''
          const frame=document.querySelector('#reader iframe');const doc=frame.contentDocument;
          const walker=doc.createTreeWalker(doc.body,NodeFilter.SHOW_TEXT);let node;
          while((node=walker.nextNode()) && !node.textContent.trim()) {}
          const range=doc.createRange();range.setStart(node,0);range.setEnd(node,Math.min(node.length,8));
          const selected=frame.contentWindow.getSelection();selected.removeAllRanges();selected.addRange(range);
          doc.dispatchEvent(new MouseEvent('mouseup',{bubbles:true}));return range.toString();''',
        );
        return jsonEncode({'quote': anchor['quote'], 'cfi': anchor['cfi']});
      case 'verifySources':
        final cards = await repo.listCards(project.id);
        for (final card in cards) {
          for (final source in await repo.getAnchors(card.id)) {
            if (source.epubLocator != null &&
                source.revisionId == webRevision) {
              final result = await js(
                'return await window.openNote.jump(anchor,40);',
                arguments: {'anchor': source.epubLocator!.toJson()},
              );
              if (result is! Map || result['success'] != true) {
                throw StateError('来源验收请求被取消或缺少成功回执：$result');
              }
            }
          }
        }
        return 'passed';
      case 'searchTarget':
        final hits = await repo.search(project.id, command['query'] as String);
        final index = hits.indexWhere(
          (hit) =>
              hit.epubLocator != null &&
              hit.revisionId == epub.activeRevisionId,
        );
        if (index < 0) throw StateError('真实书籍原文搜索结果缺失');
        return jsonEncode({'index': index});
      case 'selectImage':
        await js('await window.openNote.chapter("OPS/ch1.xhtml");');
        final result = await js('''
          const frame=document.querySelector('#reader iframe');const doc=frame.contentDocument;
          const image=doc.querySelector('img');image.scrollIntoView({block:'center'});
          await doc.fonts.ready;await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));
          image.dispatchEvent(new MouseEvent('contextmenu',{bubbles:true,cancelable:true}));
          return window.openNote.selection();''');
        return jsonEncode(result);
      case 'verifyMedia':
        final loaded = await js(
          'return [...document.querySelector("#reader iframe").contentDocument.querySelectorAll("img")].every(image=>image.complete && image.naturalWidth>0);',
        );
        if (loaded != true) throw StateError('书内可见图片未真实加载');
        final cards = await repo.listCards(project.id);
        var regions = 0;
        for (final card in cards.where((c) => c.imageResourceId != null)) {
          final anchors = await repo.getAnchors(card.id);
          if (anchors.any((a) => a.epubLocator?.crop.isNotEmpty == true)) {
            regions++;
          }
          final path = await repo.resourcePath(card.imageResourceId!);
          if (!await File(path).exists()) throw StateError('图片摘录资源缺失');
        }
        if (regions == 0) throw StateError('区域截图未保存图片内部的相对来源');
        if ((await repo.search(
          project.id,
          '知识整理',
          documentId: media.id,
        )).isEmpty) {
          throw StateError('图片 OCR 未保存来源');
        }
        return 'passed';
      case 'screenshot':
        final pixels = await web!.takeScreenshot();
        if (pixels == null || pixels.isEmpty) {
          throw StateError('真实 WebView 截图为空');
        }
        await File('${directory.path}/${command['name']}.png')
            .writeAsBytes(pixels);
        return 'passed';
      case 'restore':
        await lifecycle.prepareToLeave();
        await ocr.pauseAndDrain();
        runApp(const SizedBox());
        await WidgetsBinding.instance.endOfFrame;
        final backup = await repo.backupTo(
          '${directory.path}/mixed-backup.zip',
        );
        await repo.restoreFrom(backup);
        await ocr.resume();
        mount();
        return 'passed';
      case 'close':
        await lifecycle.prepareToLeave();
        await ocr.pauseAndDrain();
        runApp(const SizedBox());
        await WidgetsBinding.instance.endOfFrame;
        await ocr.disposeAsync();
        await repo.close();
        return 'passed';
    }
    throw ArgumentError('未知验收操作');
  };
  mount();
  await WidgetsBinding.instance.endOfFrame;
  initialized.complete();
}
