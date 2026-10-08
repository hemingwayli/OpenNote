import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';

import '../application/workspace_controller.dart';
import '../data/open_note_repository.dart';
import '../domain/models.dart' as model;
import '../engines/pdf/pdf_read_engine.dart';
import '../ui/map/mind_map_pane.dart';

class CapacityDataset {
  const CapacityDataset({
    required this.project,
    required this.document,
    required this.snapshot,
    required this.report,
  });
  final model.StudyProject project;
  final model.ManagedDocument document;
  final model.MapSnapshot snapshot;
  final Map<String, Object?> report;
}

/// 诊断复用正式 API；拒绝向已有用户项目中填入测试数据。
Future<CapacityDataset> prepareCapacityDataset(
  OpenNoteRepository repository,
  String pdfPath, {
  void Function(String)? onProgress,
}) async {
  if ((await repository.listProjects(includeDeleted: true)).isNotEmpty) {
    throw StateError('容量诊断必须使用空的显式验证资料目录。');
  }
  final whole = Stopwatch()..start();
  final project = await repository.createProject('本机容量验收：5000卡片');
  final map = (await repository.listMaps(project.id)).single;
  final bank = await repository.createMap(project.id, '卡片库：其余4500张');
  // 容量基线使用下方指定的网格坐标；不要在每张导入卡片后重排数千个顶层主题。
  await repository.setMapLayout(map.id, model.MapLayoutKind.free);
  await repository.setMapLayout(bank.id, model.MapLayoutKind.free);
  final pdf = await PdfDocument.openFile(pdfPath);
  late model.ManagedDocument document;
  final sources = <model.AnchorDraft>[];
  final excerptText = <String>[];
  final sourceWatch = Stopwatch()..start();
  try {
    if (pdf.pages.length != 1000) throw StateError('实际 PDF 引擎读取的页数不是1000。');
    final geometry = await PdfReadEngine.loadGeometry(pdf, filePath: pdfPath);
    document = await repository.importPdf(
      projectId: project.id,
      filePath: pdfPath,
      pageCount: pdf.pages.length,
      pageGeometry: geometry,
    );
    for (var index = 0; index < pdf.pages.length; index++) {
      final draft = await PdfReadEngine.extractNativeText(
        revisionId: document.activeRevisionId,
        page: pdf.pages[index],
        geometry: geometry[index],
      );
      if (!draft.text.contains('知识') || draft.fragments.length < 500) {
        throw StateError('第${index + 1}页没有实际中英文字或字符几何。');
      }
      final layer = await repository.saveTextLayer(
        draft,
        sessionId: repository.sessionId,
      );
      final start = layer.text.indexOf('知识');
      final end = math.min(start + 256, layer.text.length);
      final selected = layer.fragments.where(
        (f) => f.start < end && f.start + f.length > start,
      );
      final lines = <int, ui.Rect>{};
      for (final fragment in selected) {
        final bounds = PdfCoordinateAdapter.quadBounds(fragment.quad);
        final key = bounds.top.round();
        lines[key] = lines[key]?.expandToInclude(bounds) ?? bounds;
      }
      final text = layer.text.substring(start, end);
      sources.add(
        model.AnchorDraft(
          revisionId: document.activeRevisionId,
          pageIndex: index,
          textLayerId: layer.id,
          textStart: start,
          textEnd: end,
          context: text,
          quads: lines.values
              .map((r) => model.PdfQuad.rect(r.left, r.top, r.right, r.bottom))
              .toList(),
        ),
      );
      excerptText.add(text);
      if ((index + 1) % 100 == 0) onProgress?.call('真实文字层 ${index + 1}/1000');
    }
  } finally {
    await pdf.dispose();
  }
  sourceWatch.stop();
  final cardWatch = Stopwatch()..start();
  final roots = <int, String>{};
  final visibleNodes = <String>[];
  for (var index = 0; index < 5000; index++) {
    final page = index % 1000;
    final visible = index < 500;
    final result = await repository.createExcerpt(
      model.ExcerptDraft(
        projectId: project.id,
        mapId: visible ? map.id : bank.id,
        title: '中文摘录 ${index + 1}',
        text: excerptText[page],
        note: '原文第${page + 1}页，独立知识卡片。',
        anchors: [sources[page]],
        parentNodeId: visible && index % 5 != 0 ? roots[index ~/ 5] : null,
        x: (index % 20) * 240.0,
        y: (index ~/ 20) * 130.0,
        createHighlight: false,
      ),
    );
    if (visible) {
      visibleNodes.add(result.node.id);
      if (index % 5 == 0) roots[index ~/ 5] = result.node.id;
    }
    if ((index + 1) % 250 == 0) onProgress?.call('真实卡片 ${index + 1}/5000');
  }
  for (var index = 0; index < 500; index += 5) {
    await repository.addAssociation(
      visibleNodes[index],
      visibleNodes[index + 2],
    );
  }
  cardWatch.stop();
  final loadWatch = Stopwatch()..start();
  final cards = await repository.listCards(project.id, limit: 5001);
  final snapshot = await repository.loadMap(map.id);
  loadWatch.stop();
  final pages = await repository.reusableTextPages(
    document.activeRevisionId,
    ocrEngineVersion: 'unused',
  );
  if (cards.length != 5000 ||
      snapshot.nodes.length != 500 ||
      pages.length != 1000) {
    throw StateError('实际卡片、节点、文字层数量与容量基线不符。');
  }
  return CapacityDataset(
    project: project,
    document: document,
    snapshot: snapshot,
    report: {
      'actualPdfPages': 1000,
      'persistedNativeTextPages': pages.length,
      'actualCards': cards.length,
      'graphNodes': snapshot.nodes.length,
      'bankNodes': 4500,
      'associationEdges': snapshot.edges.length,
      'eachCardExcerptCharacters': 256,
      'construction': '1000页真实PDF逐页提取+正式仓储API创建5000卡片，包含本次会话撤销记录',
      'sourceProcessingMs': sourceWatch.elapsedMilliseconds,
      'createCardsMs': cardWatch.elapsedMilliseconds,
      'loadCardsAndGraphMs': loadWatch.elapsedMilliseconds,
      'preparationElapsedMs': whole.elapsedMilliseconds,
    },
  );
}

Future<void> runPerformanceCheck({
  required Future<OpenNoteRepository> startup,
  required String fixtureDirectory,
  required String reportPath,
}) async {
  final report = <String, Object?>{
    'schema': 1,
    'success': false,
    'mode': kReleaseMode
        ? 'release'
        : kProfileMode
        ? 'profile'
        : 'debug',
    'runtimeExecutable': Platform.resolvedExecutable,
    'startedAt': DateTime.now().toUtc().toIso8601String(),
    'minimumBaselineAcceptance': false,
    'limitations': [
      '本机高于4物理核/16GB最低基准，不能外推最低配置结果。',
      '1000页样本为生成的原生中英印刷内容，不代表大型扫描图片书内存或全书OCR时间。',
      '内存诊断包含1000页文字层、5000卡片会话历史、脑图与首图，未激活OCR模型或并行OCR。',
      '生产Workbench完整启动未计时；首页计时为真实PDF打开、页框读取、渲染与图片首次绘制的子路径。',
      '交互使用注入鼠标事件驱动正式脑图组件，帧时间由真实Flutter引擎FrameTiming记录。',
      '组拖复用正式WorkspaceController选择与Pane→仓储路径；未运行Workbench草稿/命令队列、Reader或OCR。',
    ],
  };
  OpenNoteRepository? repository;
  final harness = _PerformanceHarnessController();
  final appReady = Completer<void>();
  runApp(
    _PerformanceApp(controller: harness, onReady: () => appReady.complete()),
  );
  try {
    report['stage'] = 'initialApplicationFrame';
    await appReady.future.timeout(const Duration(seconds: 30));
    repository = await startup;
    final repo = repository;
    final pdfPath = p.join(
      fixtureDirectory,
      'tools',
      'verification',
      'fixtures',
      'long-book-1000.pdf',
    );
    final manifest = jsonDecode(
      await File(p.join(p.dirname(pdfPath), 'manifest.json')).readAsString(),
    ) as Map;
    report['stage'] = 'fixtureHash';
    final hash = await hashPerformanceFixture(pdfPath);
    if (hash != manifest['sha256']) throw StateError('容量PDF的hash与生成清单不符。');
    report['fixture'] = manifest;
    harness.status = '准备1000页实际文字层和5000张卡片…';
    report['stage'] = 'capacityDataset';
    final dataset = await prepareCapacityDataset(
      repo,
      pdfPath,
      onProgress: (s) => harness.status = s,
    );
    report['dataset'] = dataset.report;
    report['sessionHistory'] = {
      'undoEntries': repo.undoEntryCount,
      'redoEntries': repo.redoEntryCount,
      'heldThroughoutMeasurement': true,
    };
    final querySamples = <Map<String, Object?>>[];
    for (final query in ['知', '知识', '中文', '知', '知识', '中文', '知', '知识', '中文']) {
      final watch = Stopwatch()..start();
      final hits = await repo.search(dataset.project.id, query, limit: 100);
      watch.stop();
      if (hits.isEmpty) throw StateError('中文短查询没有返回结果：$query');
      querySamples.add({
        'query': query,
        'elapsedMs': watch.elapsedMicroseconds / 1000,
        'hits': hits.length,
      });
    }
    report['search'] = {
      'samples': querySamples,
      'p95Ms': _percentile(
        querySamples.map((s) => s['elapsedMs'] as double).toList(),
        .95,
      ),
      'maxMs': querySamples
          .map((s) => s['elapsedMs'] as double)
          .reduce(math.max),
      'cache': '同一会话真实数据准备完成，SQLite与OS文件缓存已热；首次查询单独记录',
    };
    harness.status = '500个可见节点：真实拖动和缩放采帧…';
    report['stage'] = 'graphFrames';
    await harness
        .showMap(dataset.snapshot, repo)
        .timeout(const Duration(seconds: 30));
    report['graph'] = await harness.measureGraph().timeout(
      const Duration(seconds: 30),
    );
    harness.status = '500个真实多选节点：整组拖动、事务与撤销验收…';
    report['stage'] = 'graphGroup';
    final groupReport = <String, Object?>{};
    // 中途失败也保留已取得的帧、坐标和事务证据。
    report['graphGroup'] = groupReport;
    await harness
        .measureGraphGroup(repo, dataset, groupReport)
        .timeout(const Duration(seconds: 60));
    // 取消控制器延迟refresh，避免PDF首图阶段被迟到的脑图通知替换。
    harness.releaseWorkspace();
    final revision = await repo.getRevision(dataset.document.activeRevisionId);
    final path = await repo.resourcePath(revision.resourceId);
    harness.status = '1000页PDF：打开、几何读取与首图实际绘制…';
    report['stage'] = 'firstPdfImage';
    final first = Stopwatch()..start();
    final pdf = await PdfDocument.openFile(path);
    try {
      final geometry = await PdfReadEngine.loadGeometry(pdf, filePath: path);
      final image = await pdf.pages.first.render(
        fullWidth: 900,
        fullHeight: 1200,
        width: 900,
        height: 1200,
        backgroundColor: 0xFFFFFFFF,
      );
      if (image == null) throw StateError('首图实际渲染未完成。');
      try {
        final pixels = await image.createImage();
        try {
          final encoded = await pixels.toByteData(
            format: ui.ImageByteFormat.png,
          );
          if (encoded == null) throw StateError('首图编码未完成。');
          await harness
              .showImage(
                encoded.buffer.asUint8List(
                  encoded.offsetInBytes,
                  encoded.lengthInBytes,
                ),
              )
              .timeout(const Duration(seconds: 30));
        } finally {
          pixels.dispose();
        }
      } finally {
        image.dispose();
      }
      first.stop();
      report['firstPdfImage'] = {
        'elapsedMs': first.elapsedMicroseconds / 1000,
        'actualPages': pdf.pages.length,
        'geometryPages': geometry.length,
        'renderPixels': [900, 1200],
        'cache': '新PDF handle，PDFium已初始化且OS文件缓存已热；包含首PNG解码和引擎绘制',
        'isCompleteReaderStartup': false,
      };
    } finally {
      await pdf.dispose();
    }
    report['targets'] = {
      'productionStartup5s': '未测完整生产Workbench启动',
      'productionReaderFirstVisible3s': '测了真实打开/渲染子路径，完整Reader启动未测',
      'graphP95Max33ms': (report['graph'] as Map)['p95TotalSpanMs'] is num
          ? (report['graph'] as Map)['p95TotalSpanMs'] as num <= 33
          : false,
      'graphGroupP95Max33ms': groupReport['within33ms'] == true,
      'graphGroup500NodesAtomicMoveAndUndo':
          groupReport['contractPassed'] == true,
      'searchFirstBatchMax1000ms': querySamples.every(
        (s) => (s['elapsedMs'] as double) <= 1000,
      ),
      'peakMemoryMax2GiB': '由外部启动器GetProcessMemoryInfo填写',
    };
    report['libraryPath'] = repo.libraryPath;
    report['success'] = true;
    report['stage'] = 'complete';
  } catch (error, trace) {
    report['error'] = '$error';
    report['stackTrace'] = '$trace';
  } finally {
    harness.releaseWorkspace();
    await repository?.close();
    report['finishedAt'] = DateTime.now().toUtc().toIso8601String();
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

/// 单独闭包上下文只含路径，避免把 UI 的 Completer 和控制器传入 isolate。
Future<String> hashPerformanceFixture(String path) => Isolate.run(
  () async => (await sha256.bind(File(path).openRead()).first).toString(),
);

class _PerformanceHarnessController {
  _PerformanceAppState? state;
  set status(String value) => state?._setStatus(value);
  Future<void> showMap(
    model.MapSnapshot value,
    OpenNoteRepository repository,
  ) => state!._showMap(value, repository);
  Future<void> showImage(Uint8List value) => state!._showImage(value);
  Future<Map<String, Object?>> measureGraph() => state!._measureGraph();
  Future<void> measureGraphGroup(
    OpenNoteRepository repository,
    CapacityDataset dataset,
    Map<String, Object?> report,
  ) => state!._measureGraphGroup(repository, dataset, report);
  void releaseWorkspace() => state?._releaseWorkspace();
}

class _PerformanceApp extends StatefulWidget {
  const _PerformanceApp({required this.controller, required this.onReady});
  final _PerformanceHarnessController controller;
  final VoidCallback onReady;
  @override
  State<_PerformanceApp> createState() => _PerformanceAppState();
}

class _PerformanceAppState extends State<_PerformanceApp> {
  final _graph = MindMapPaneController();
  final _graphBox = GlobalKey();
  String _status = '准备本机容量与性能诊断…';
  model.MapSnapshot? _snapshot;
  Uint8List? _image;
  final List<FrameTiming> _frames = [];
  OpenNoteRepository? _repository;
  WorkspaceController? _workspace;
  Completer<void>? _groupCommit;
  Map<String, model.PdfPoint>? _groupSubmitted;
  int _layoutCalls = 0;
  int _singleMoveCalls = 0;
  int _relationCalls = 0;
  double? _groupCommitMs;
  bool _recording = false;
  int _sampleStart = 0;
  int? _sampleEnd;
  @override
  void initState() {
    super.initState();
    widget.controller.state = this;
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.onReady());
    SchedulerBinding.instance.addTimingsCallback(_timings);
  }

  void _timings(List<FrameTiming> frames) {
    if (_recording) {
      _frames.addAll(
        frames.where(
          (f) =>
              f.timestampInMicroseconds(ui.FramePhase.vsyncStart) >=
                  _sampleStart &&
              (_sampleEnd == null ||
                  f.timestampInMicroseconds(ui.FramePhase.vsyncStart) <=
                      _sampleEnd!),
        ),
      );
    }
  }

  @override
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_timings);
    _releaseWorkspace(rebuild: false);
    if (identical(widget.controller.state, this)) {
      widget.controller.state = null;
    }
    super.dispose();
  }

  void _setStatus(String value) {
    if (mounted) setState(() => _status = value);
  }

  Future<void> _nextFrame() async {
    SchedulerBinding.instance.ensureVisualUpdate();
    await SchedulerBinding.instance.endOfFrame;
  }

  Future<void> _showMap(
    model.MapSnapshot value,
    OpenNoteRepository repository,
  ) async {
    _repository = repository;
    if (_workspace == null) {
      final workspace = WorkspaceController(repository);
      _workspace = workspace;
      await workspace.initialize(projectId: value.map.projectId);
      await workspace.selectMap(value.map.id);
      workspace.addListener(_workspaceChanged);
    }
    setState(() {
      _snapshot = value;
      _image = null;
    });
    await _nextFrame();
    await _nextFrame();
    _graph.fitAll();
    await _nextFrame();
    if (_graph.renderedNodeCount != 500) {
      throw StateError('当前实际渲染可见节点不是500：${_graph.renderedNodeCount}');
    }
  }

  Future<void> _showImage(Uint8List value) async {
    final provider = MemoryImage(value);
    await precacheImage(provider, context);
    setState(() {
      _image = value;
      _snapshot = null;
    });
    await _nextFrame();
    await _nextFrame();
  }

  Future<Map<String, Object?>> _measureGraph() async {
    final box = _graphBox.currentContext!.findRenderObject()! as RenderBox;
    final actualSize = box.size;
    final devicePixelRatio = View.of(context).devicePixelRatio;
    await Future<void>.delayed(const Duration(milliseconds: 120));
    _frames.clear();
    _sampleEnd = null;
    _sampleStart =
        SchedulerBinding.instance.currentSystemFrameTimeStamp.inMicroseconds;
    _recording = true;
    // 左下角空白处平移，再在中部滚轮缩放；事件走正式手势识别器。
    final origin = box.localToGlobal(
      Offset(actualSize.width - 16, actualSize.height - 16),
    );
    final firstNodeId = _snapshot!.nodes.first.id;
    final nodeBefore = _nodeCenter(firstNodeId);
    final visibleCounts = <int>[];
    GestureBinding.instance.handlePointerEvent(
      PointerAddedEvent(
        device: 9191,
        position: origin,
        kind: ui.PointerDeviceKind.mouse,
      ),
    );
    GestureBinding.instance.handlePointerEvent(
      PointerDownEvent(
        pointer: 91,
        device: 9191,
        position: origin,
        kind: ui.PointerDeviceKind.mouse,
        buttons: kPrimaryMouseButton,
      ),
    );
    var previous = origin;
    for (var i = 1; i <= 90; i++) {
      final position =
          origin + Offset(math.sin(i / 8) * 45, math.cos(i / 8) * 30);
      GestureBinding.instance.handlePointerEvent(
        PointerMoveEvent(
          pointer: 91,
          device: 9191,
          position: position,
          delta: position - previous,
          kind: ui.PointerDeviceKind.mouse,
          buttons: kPrimaryMouseButton,
        ),
      );
      await _nextFrame();
      visibleCounts.add(_graph.renderedNodeCount);
      previous = position;
    }
    GestureBinding.instance.handlePointerEvent(
      PointerUpEvent(
        pointer: 91,
        device: 9191,
        position: previous,
        kind: ui.PointerDeviceKind.mouse,
      ),
    );
    final panDistance = (_nodeCenter(firstNodeId) - nodeBefore).distance;
    if (panDistance < 5) throw StateError('注入拖动没有实际改变脑图视口。');
    final scaleBefore = _graph.scale;
    var maxScale = scaleBefore;
    final center = box.localToGlobal(actualSize.center(Offset.zero));
    for (var i = 0; i < 90; i++) {
      GestureBinding.instance.handlePointerEvent(
        PointerScrollEvent(
          position: center,
          device: 9191,
          kind: ui.PointerDeviceKind.mouse,
          scrollDelta: Offset(0, i < 45 ? -1.5 : 1.5),
        ),
      );
      await _nextFrame();
      visibleCounts.add(_graph.renderedNodeCount);
      maxScale = math.max(maxScale, _graph.scale);
    }
    GestureBinding.instance.handlePointerEvent(
      PointerRemovedEvent(
        device: 9191,
        position: center,
        kind: ui.PointerDeviceKind.mouse,
      ),
    );
    if (maxScale <= scaleBefore + .001) throw StateError('注入滚轮没有实际缩放脑图。');
    // Release引擎会批量回传FrameTiming，保留窗口直到末批交付。
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    _recording = false;
    if (_frames.length < 100) throw StateError('实际引擎帧时间样本不足：${_frames.length}');
    final frames = _frames.skip(5).toList();
    return {
      ..._frameMetrics(frames),
      'visibleNodesBeforeInteraction': 500,
      'visibleNodesAfterInteraction': _graph.renderedNodeCount,
      'minVisibleNodesDuringInput': visibleCounts.reduce(math.min),
      'maxVisibleNodesDuringInput': visibleCounts.reduce(math.max),
      'inputFramesWith500VisibleNodes': visibleCounts
          .where((c) => c == 500)
          .length,
      'viewportLogicalPixels': [actualSize.width, actualSize.height],
      'devicePixelRatio': devicePixelRatio,
      'actualPanDistancePixels': panDistance,
      'scaleBefore': scaleBefore,
      'maxScaleDuringZoom': maxScale,
      'gesture': '90帧注入鼠标空白拖动+90帧真实滚轮缩放；忽略首5个warmup样本',
    };
  }

  void _workspaceChanged() {
    if (mounted && _workspace?.map != null) {
      setState(() => _snapshot = _workspace!.map);
    }
  }

  void _releaseWorkspace({bool rebuild = true}) {
    final workspace = _workspace;
    _workspace = null;
    _snapshot = null;
    workspace?.removeListener(_workspaceChanged);
    workspace?.dispose();
    if (rebuild && mounted) setState(() {});
  }

  Future<void> _reloadMap(String mapId) async {
    final fresh = await _repository!.loadMap(mapId);
    await _workspace!.refresh();
    if (_workspace!.map?.map.id != mapId) {
      throw StateError('性能诊断期间目标脑图发生切换。');
    }
    if (mounted) setState(() => _snapshot = fresh);
  }

  Future<void> _moveSingle(String id, double x, double y) async {
    _singleMoveCalls++;
    final mapId = _snapshot!.map.id;
    await _repository!.moveNode(id, x, y);
    await _reloadMap(mapId);
  }

  Future<void> _moveGroup(Map<String, model.PdfPoint> positions) async {
    _layoutCalls++;
    final mapId = _snapshot!.map.id;
    final submitted = Map<String, model.PdfPoint>.unmodifiable(positions);
    _groupSubmitted = submitted;
    final watch = Stopwatch()..start();
    try {
      await _repository!.layoutNodes(mapId, submitted);
      await _reloadMap(mapId);
      watch.stop();
      _groupCommitMs = watch.elapsedMicroseconds / 1000;
      final completion = _groupCommit;
      if (completion != null && !completion.isCompleted) completion.complete();
    } catch (error, trace) {
      watch.stop();
      _groupCommitMs = watch.elapsedMicroseconds / 1000;
      final completion = _groupCommit;
      if (completion != null && !completion.isCompleted) {
        completion.completeError(error, trace);
      }
      rethrow;
    }
  }

  Future<void> _reparent(String id, String? parent) async {
    _relationCalls++;
    final mapId = _snapshot!.map.id;
    await _repository!.reparentNode(id, parent);
    await _reloadMap(mapId);
  }

  Future<void> _associate(String from, String to) async {
    _relationCalls++;
    final mapId = _snapshot!.map.id;
    await _repository!.addAssociation(from, to);
    await _reloadMap(mapId);
  }

  Future<void> _measureGraphGroup(
    OpenNoteRepository repository,
    CapacityDataset dataset,
    Map<String, Object?> report,
  ) async {
    final workspace = _workspace!;
    final mapId = dataset.snapshot.map.id;
    final before = await repository.loadMap(mapId);
    final otherMaps = (await repository.listMaps(dataset.project.id))
        .where((map) => map.id != mapId)
        .toList();
    if (before.nodes.length != 500 || otherMaps.length != 1) {
      throw StateError('组拖必须使用实际500节点和独立4500节点脑图。');
    }
    final bankId = otherMaps.single.id;
    final bankBefore = await repository.loadMap(bankId);
    if (bankBefore.nodes.length != 4500) throw StateError('其余节点不是4500。');
    final beforeSignature = _mapSignature(before);
    final beforeRelations = _mapSignature(before, coordinates: false);
    final bankSignature = _mapSignature(bankBefore);
    final undoBefore = repository.undoEntryCount;
    final redoBefore = repository.redoEntryCount;
    await workspace.selectMap(mapId);
    // 受控准备通过正式控制器逐次toggle，包含父子重叠选择，不伪造选集。
    for (final node in workspace.map!.nodes) {
      workspace.selectNode(node, additive: true);
    }
    await _showMap(workspace.map!, repository);
    final selected = workspace.selectedNodeIds;
    final roots = before.nodes
        .where((node) => !selected.contains(node.parentNodeId))
        .toList();
    if (selected.length != 500 || roots.length != 100) {
      throw StateError('正式控制器没有选中500节点/100个规范化分支根。');
    }
    report.addAll({
      'scope': '正式WorkspaceController多选→MindMapPane真实鼠标组拖→一次SQLite layoutNodes/loadMap；未运行Workbench命令队列或编辑器',
      'selectedNodes': selected.length,
      'selectedRoots': roots.length,
      'bankNodes': bankBefore.nodes.length,
      'undoEntriesBefore': undoBefore,
      'redoEntriesBefore': redoBefore,
      'visibleNodesBeforeInteraction': _graph.renderedNodeCount,
      'selectionUsesProductionController': true,
      'selectedStyle': '500张卡均使用正式selected样式；详情与LOD由生产Pane决定，诊断不覆写绘制规则',
    });
    _layoutCalls = 0;
    _singleMoveCalls = 0;
    _relationCalls = 0;
    _groupSubmitted = null;
    _groupCommitMs = null;
    final commit = Completer<void>();
    _groupCommit = commit;
    // 先订阅失败，避免组件回滚时诊断的future暂未await而丢失异常证据。
    final commitResult = commit.future.then<Object?>(
      (_) => null,
      onError: (Object error, StackTrace _) => error,
    );
    final box = _graphBox.currentContext!.findRenderObject()! as RenderBox;
    final viewport = box.localToGlobal(Offset.zero) & box.size;
    final dragged = roots.first;
    final nodeBox = _nodeRenderBox(dragged.id);
    final origin = nodeBox.localToGlobal(nodeBox.size.center(Offset.zero));
    var bounds = Rect.fromLTWH(
      before.nodes.first.x,
      before.nodes.first.y,
      before.nodes.first.width,
      before.nodes.first.height,
    );
    for (final node in before.nodes.skip(1)) {
      bounds = bounds.expandToInclude(
        Rect.fromLTWH(node.x, node.y, node.width, node.height),
      );
    }
    final rootWorldCenter = Offset(
      dragged.x + dragged.width / 2,
      dragged.y + dragged.height / 2,
    );
    final scale = _graph.scale;
    final visibleCounts = <int>[];
    var allInside = 0;
    var realMotionFrames = 0;
    var lastNodeCenter = origin;
    await Future<void>.delayed(const Duration(milliseconds: 120));
    _frames.clear();
    _sampleEnd = null;
    _sampleStart =
        SchedulerBinding.instance.currentSystemFrameTimeStamp.inMicroseconds +
        1;
    _recording = true;
    var previous = origin;
    var pointerDown = false;
    GestureBinding.instance.handlePointerEvent(
      PointerAddedEvent(
        device: 9292,
        position: origin,
        kind: ui.PointerDeviceKind.mouse,
      ),
    );
    final firstInputFrame = Stopwatch()..start();
    // 记录实际 ui.Image 句柄及像素尺寸；RGBA估算不等于GPU或整个进程的分配。
    final previousImageCreate = ui.Image.onCreate;
    final previousImageDispose = ui.Image.onDispose;
    final observedImages = Map<ui.Image, int>.identity();
    final imageDimensions = <String, int>{};
    var imagesCreated = 0;
    var imagesDisposed = 0;
    var liveRgbaBytes = 0;
    var peakRgbaBytes = 0;
    var peakImageHandles = 0;
    void observeImageCreate(ui.Image image) {
      previousImageCreate?.call(image);
      final bytes = image.width * image.height * 4;
      observedImages[image] = bytes;
      imagesCreated++;
      liveRgbaBytes += bytes;
      peakRgbaBytes = math.max(peakRgbaBytes, liveRgbaBytes);
      peakImageHandles = math.max(peakImageHandles, observedImages.length);
      final dimensions = '${image.width}x${image.height}';
      imageDimensions.update(
        dimensions,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }

    void observeImageDispose(ui.Image image) {
      previousImageDispose?.call(image);
      final bytes = observedImages.remove(image);
      if (bytes == null) return;
      imagesDisposed++;
      liveRgbaBytes -= bytes;
    }

    try {
      ui.Image.onCreate = observeImageCreate;
      ui.Image.onDispose = observeImageDispose;
      GestureBinding.instance.handlePointerEvent(
        PointerDownEvent(
          pointer: 92,
          device: 9292,
          position: origin,
          kind: ui.PointerDeviceKind.mouse,
          buttons: kPrimaryMouseButton,
        ),
      );
      pointerDown = true;
      for (var i = 1; i <= 180; i++) {
        // 小幅真实平移留在fitAll的物理边界内，不以裁剪节点换取性能。
        final position =
            origin + Offset(20 + math.sin(i / 8) * 8, math.sin(i / 11) * 6);
        GestureBinding.instance.handlePointerEvent(
          PointerMoveEvent(
            pointer: 92,
            device: 9292,
            position: position,
            delta: position - previous,
            kind: ui.PointerDeviceKind.mouse,
            buttons: kPrimaryMouseButton,
          ),
        );
        await _nextFrame();
        if (i == 1) {
          firstInputFrame.stop();
          // 记录冷捕获的首次框架提交；真正栅格耗时另保留前五个引擎帧。
          report['firstInputFrameSubmittedMs'] =
              firstInputFrame.elapsedMicroseconds / 1000;
        }
        if (!nodeBox.attached) throw StateError('拖动节点实际RenderBox已失效。');
        final center = nodeBox.localToGlobal(nodeBox.size.center(Offset.zero));
        if ((center - lastNodeCenter).distance > .001) realMotionFrames++;
        final screenBounds = Rect.fromLTWH(
          center.dx + (bounds.left - rootWorldCenter.dx) * scale,
          center.dy + (bounds.top - rootWorldCenter.dy) * scale,
          bounds.width * scale,
          bounds.height * scale,
        );
        if (viewport.inflate(.01).contains(screenBounds.topLeft) &&
            viewport.inflate(.01).contains(screenBounds.bottomRight)) {
          allInside++;
        }
        visibleCounts.add(_graph.renderedNodeCount);
        report['inputFrameCount'] = visibleCounts.length;
        lastNodeCenter = center;
        previous = position;
      }
      // 截止vsync排除抬起后的事务、查询与undo帧；真实引擎末批可迟到。
      _sampleEnd =
          SchedulerBinding.instance.currentSystemFrameTimeStamp.inMicroseconds;
      GestureBinding.instance.handlePointerEvent(
        PointerUpEvent(
          pointer: 92,
          device: 9292,
          position: previous,
          kind: ui.PointerDeviceKind.mouse,
        ),
      );
      pointerDown = false;
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      _recording = false;
      if (!mounted) {
        throw StateError('组拖诊断视图已关闭，无法读取当前屏幕信息。');
      }
      final devicePixelRatio = View.of(context).devicePixelRatio;
      final capturedFrames = _frames
          .where(
            (frame) =>
                frame.timestampInMicroseconds(ui.FramePhase.vsyncStart) <=
                _sampleEnd!,
          )
          .toList();
      final warmupFrames = capturedFrames.take(5).toList();
      final frames = capturedFrames.skip(5).toList();
      report.addAll({
        if (frames.isNotEmpty) ..._frameMetrics(frames),
        if (warmupFrames.isNotEmpty)
          'warmupEngineFrames': _frameMetrics(warmupFrames),
        'capturedEngineFrameSamples': capturedFrames.length,
        'engineFrameSamples': frames.length,
        'inputFrameCount': visibleCounts.length,
        'inputFramesWith500VisibleNodes': visibleCounts
            .where((count) => count == 500)
            .length,
        'minVisibleNodesDuringInput': visibleCounts.reduce(math.min),
        'maxVisibleNodesDuringInput': visibleCounts.reduce(math.max),
        'inputFramesWithAllNodesInsideViewport': allInside,
        'physicalVisibilityMethod':
            '真实拖动根RenderBox中心＋固定缩放和实际500节点边界；所有节点矩形均须在viewport内',
        'inputFramesWithActualNodeMotion': realMotionFrames,
        'actualDraggedNodeDistancePixels': (lastNodeCenter - origin).distance,
        'samplingFirstAllowedVsyncMicroseconds': _sampleStart,
        'samplingLastAllowedVsyncMicroseconds': _sampleEnd,
        'viewportLogicalPixels': [box.size.width, box.size.height],
        'devicePixelRatio': devicePixelRatio,
        'scale': scale,
        'gesture': '500真实多选/100根：180帧鼠标节点组拖，忽略首5个warmup；提交与undo帧不纳入p95',
        'layoutCalls': _layoutCalls,
        'singleMoveCalls': _singleMoveCalls,
        'relationCalls': _relationCalls,
        'unionNodes': _groupSubmitted?.length ?? 0,
        'commitTimingMethod':
            '正式onMoveGroup回调进入至layoutNodes、loadMap与Controller refresh完成，独立于拖动帧',
      });
      final error = await commitResult.timeout(const Duration(seconds: 20));
      report['commitMs'] = _groupCommitMs;
      if (error != null) throw StateError('组拖正式仓储提交失败：$error');
      final after = await repository.loadMap(mapId);
      final bankAfter = await repository.loadMap(bankId);
      final originals = {for (final node in before.nodes) node.id: node};
      final firstAfter = after.nodes.first;
      final dx = firstAfter.x - originals[firstAfter.id]!.x;
      final dy = firstAfter.y - originals[firstAfter.id]!.y;
      final actualScreenDelta = lastNodeCenter - origin;
      final matchesGesture =
          (dx - actualScreenDelta.dx / scale).abs() < .000001 &&
          (dy - actualScreenDelta.dy / scale).abs() < .000001;
      final allSameDelta =
          after.nodes.length == 500 &&
          after.nodes.every((node) {
            final original = originals[node.id];
            return original != null &&
                (node.x - original.x - dx).abs() < .000001 &&
                (node.y - original.y - dy).abs() < .000001;
          });
      final changed = after.nodes.where((node) {
        final original = originals[node.id];
        return original != null &&
            (node.x != original.x || node.y != original.y);
      }).length;
      final unchangedRelations =
          _mapSignature(after, coordinates: false) == beforeRelations;
      final bankUnchanged = _mapSignature(bankAfter) == bankSignature;
      final undoAfter = repository.undoEntryCount;
      report.addAll({
        'layoutCalls': _layoutCalls,
        'singleMoveCalls': _singleMoveCalls,
        'relationCalls': _relationCalls,
        'unionNodes': _groupSubmitted?.length ?? 0,
        'submittedExact500Nodes':
            _groupSubmitted != null &&
            setEquals(_groupSubmitted!.keys.toSet(), originals.keys.toSet()),
        'changedNodes': changed,
        'deltaX': dx,
        'deltaY': dy,
        'coordinateDeltaMatchesActualGesture': matchesGesture,
        'all500CoordinatesHaveSameDelta':
            allSameDelta && math.sqrt(dx * dx + dy * dy) > .5,
        'identitiesCardsParentsMapFoldEdgesAndAnchorsUnchanged':
            unchangedRelations,
        'other4500NodesAndCardsUnchanged': bankUnchanged,
        'undoEntriesAfterCommit': undoAfter,
        'redoEntriesAfterCommit': repository.redoEntryCount,
        'visibleNodesAfterInteraction': _graph.renderedNodeCount,
        'selectedNodesAfterInteraction': workspace.selectedNodeIds.length,
        'singleUndoEntry': undoAfter == undoBefore + 1,
      });
      final undoWatch = Stopwatch()..start();
      await repository.undo();
      await _reloadMap(mapId);
      undoWatch.stop();
      await _nextFrame();
      final restored = await repository.loadMap(mapId);
      final restoredBank = await repository.loadMap(bankId);
      report.addAll({
        'undoMs': undoWatch.elapsedMicroseconds / 1000,
        'undoTimingMethod':
            '一次undo至SQLite/loadMap/Controller refresh完成；随后等待实际布局核验可见节点',
        'undoRestoredAll500CoordinatesAndRelations':
            _mapSignature(restored) == beforeSignature,
        'undoPreservedOther4500': _mapSignature(restoredBank) == bankSignature,
        'undoEntriesAfterUndo': repository.undoEntryCount,
        'redoEntriesAfterUndo': repository.redoEntryCount,
        'undoRestoredHistoryCounts':
            repository.undoEntryCount == undoBefore &&
            repository.redoEntryCount == 1,
        'visibleNodesAfterUndo': _graph.renderedNodeCount,
      });
      report['contractPassed'] =
          report['layoutCalls'] == 1 &&
          report['singleMoveCalls'] == 0 &&
          report['relationCalls'] == 0 &&
          report['submittedExact500Nodes'] == true &&
          changed == 500 &&
          report['all500CoordinatesHaveSameDelta'] == true &&
          unchangedRelations &&
          matchesGesture &&
          actualScreenDelta.distance > 5 &&
          bankUnchanged &&
          report['singleUndoEntry'] == true &&
          report['undoRestoredAll500CoordinatesAndRelations'] == true &&
          report['undoPreservedOther4500'] == true &&
          report['undoRestoredHistoryCounts'] == true &&
          workspace.selectedNodeIds.length == 500 &&
          visibleCounts.length == 180 &&
          visibleCounts.every((count) => count == 500) &&
          allInside == 180 &&
          realMotionFrames >= 175 &&
          frames.length >= 175;
      report['within33ms'] =
          report['contractPassed'] == true &&
          (report['p95TotalSpanMs'] as num) <= 33;
    } finally {
      if (identical(ui.Image.onCreate, observeImageCreate)) {
        ui.Image.onCreate = previousImageCreate;
      }
      if (identical(ui.Image.onDispose, observeImageDispose)) {
        ui.Image.onDispose = previousImageDispose;
      }
      report['imageHandlesDuringGroup'] = {
        'method': 'Release公开ui.Image生命周期回调，保留原监听；不读取像素或改变绘制',
        'created': imagesCreated,
        'disposed': imagesDisposed,
        'peakLiveHandles': peakImageHandles,
        'liveHandlesAtEnd': observedImages.length,
        'estimatedPeakRgbaBytes': peakRgbaBytes,
        'estimatedLiveRgbaBytesAtEnd': liveRgbaBytes,
        'createdImageDimensions': imageDimensions,
        'scope': '窗口内新建句柄的宽×高×4估算，不含GPU附件、驱动缓存或其他进程分配',
      };
      // 图像仍归渲染组件拥有；观察器不保留跨测量的句柄，也不代替组件dispose。
      observedImages.clear();
      _recording = false;
      _sampleEnd = null;
      if (pointerDown) {
        GestureBinding.instance.handlePointerEvent(
          PointerCancelEvent(
            pointer: 92,
            device: 9292,
            position: previous,
            kind: ui.PointerDeviceKind.mouse,
          ),
        );
      }
      GestureBinding.instance.handlePointerEvent(
        PointerRemovedEvent(
          device: 9292,
          position: previous,
          kind: ui.PointerDeviceKind.mouse,
        ),
      );
      _groupCommit = null;
    }
  }

  Offset _nodeCenter(String id) {
    final box = _nodeRenderBox(id);
    return box.localToGlobal(box.size.center(Offset.zero));
  }

  RenderBox _nodeRenderBox(String id) {
    RenderBox? result;
    void find(Element element) {
      if (result != null) return;
      if (element.widget.key == ValueKey('map-node-$id')) {
        result = element.findRenderObject() as RenderBox;
      } else {
        element.visitChildElements(find);
      }
    }

    find(_graphBox.currentContext! as Element);
    if (result == null) throw StateError('测量节点不在实际控件树中。');
    return result!;
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      fontFamily: 'Segoe UI',
      fontFamilyFallback: const ['Microsoft YaHei'],
    ),
    home: Scaffold(
      appBar: AppBar(title: const Text('OpenNote 本机性能诊断')),
      body: Column(
        children: [
          Padding(padding: const EdgeInsets.all(8), child: Text(_status)),
          Expanded(
            child: _snapshot != null
                ? SizedBox(
                    key: _graphBox,
                    child: MindMapPane(
                      snapshot: _snapshot!,
                      controller: _graph,
                      selectedNodeId: _workspace!.selectedNodeId,
                      selectedNodeIds: _workspace!.selectedNodeIds,
                      canCreate: false,
                      onSelect: (node) => _workspace!.selectNode(node),
                      onToggleSelection: (node) =>
                          _workspace!.selectNode(node, additive: true),
                      onClearSelection: () =>
                          setState(() => _workspace!.selectedNodeId = null),
                      onMove: _moveSingle,
                      onMoveGroup: _moveGroup,
                      onReparent: _reparent,
                      onAssociate: _associate,
                      onRemoveAssociation: (id) => unawaited(() async {
                        _relationCalls++;
                        await _repository!.removeAssociation(id);
                        await _reloadMap(_snapshot!.map.id);
                      }()),
                      onAction: (_, action) =>
                          throw StateError('诊断未安排节点菜单动作：$action'),
                      onToggleCollapsed: (id) => unawaited(() async {
                        final node = _snapshot!.nodes.firstWhere(
                          (node) => node.id == id,
                        );
                        await _repository!.setNodeCollapsed(
                          id,
                          !node.collapsed,
                        );
                        await _reloadMap(_snapshot!.map.id);
                      }()),
                    ),
                  )
                : _image != null
                ? Image.memory(_image!, fit: BoxFit.contain)
                : const Center(child: CircularProgressIndicator()),
          ),
        ],
      ),
    ),
  );
}

double _percentile(List<double> values, double quantile) {
  final sorted = [...values]..sort();
  return sorted[(quantile * sorted.length).ceil().clamp(1, sorted.length) - 1];
}

/// 两种真实手势使用同一FrameTiming口径，不能把build/raster分位数相加代替totalSpan。
Map<String, Object?> _frameMetrics(List<FrameTiming> frames) {
  final total = frames
      .map((frame) => frame.totalSpan.inMicroseconds / 1000)
      .toList();
  return {
    'engineFrameSamples': frames.length,
    'p50TotalSpanMs': _percentile(total, .5),
    'p95TotalSpanMs': _percentile(total, .95),
    'maxTotalSpanMs': total.reduce(math.max),
    'p95BuildMs': _percentile(
      frames.map((frame) => frame.buildDuration.inMicroseconds / 1000).toList(),
      .95,
    ),
    'p95RasterMs': _percentile(
      frames
          .map((frame) => frame.rasterDuration.inMicroseconds / 1000)
          .toList(),
      .95,
    ),
    'p95VsyncOverheadMs': _percentile(
      frames.map((frame) => frame.vsyncOverhead.inMicroseconds / 1000).toList(),
      .95,
    ),
    'p95RasterQueueMs': _percentile(
      frames
          .map(
            (frame) =>
                (frame.timestampInMicroseconds(ui.FramePhase.rasterStart) -
                    frame.timestampInMicroseconds(ui.FramePhase.buildFinish)) /
                1000,
          )
          .toList(),
      .95,
    ),
    'rawEngineFrames': [
      for (final frame in frames)
        {
          'frameNumber': frame.frameNumber,
          'phasesMicroseconds': {
            for (final phase in ui.FramePhase.values)
              phase.name: frame.timestampInMicroseconds(phase),
          },
          'layerCacheCount': frame.layerCacheCount,
          'layerCacheBytes': frame.layerCacheBytes,
          'pictureCacheCount': frame.pictureCacheCount,
          'pictureCacheBytes': frame.pictureCacheBytes,
        },
    ],
  };
}

/// 从实际SQLite返回的完整快照生成稳定签名，查询顺序变化不能掩盖业务数据改变。
String _mapSignature(model.MapSnapshot snapshot, {bool coordinates = true}) {
  final nodes = snapshot.nodes.toList()
    ..sort((left, right) => left.id.compareTo(right.id));
  final cards = snapshot.cards.values.toList()
    ..sort((left, right) => left.id.compareTo(right.id));
  final edges = snapshot.edges.toList()
    ..sort((left, right) => left.id.compareTo(right.id));
  final anchors = snapshot.anchors.values.expand((values) => values).toList()
    ..sort((left, right) => left.id.compareTo(right.id));
  final value = {
    'map': [
      snapshot.map.id,
      snapshot.map.projectId,
      snapshot.map.title,
      snapshot.map.deletedAt?.toIso8601String(),
    ],
    'nodes': [
      for (final node in nodes)
        [
          node.id,
          node.mapId,
          node.cardId,
          node.parentNodeId,
          node.width,
          node.height,
          node.collapsed,
          if (coordinates) node.x,
          if (coordinates) node.y,
        ],
    ],
    'cards': [
      for (final card in cards)
        [
          card.id,
          card.projectId,
          card.title,
          card.excerptSnapshot,
          card.body,
          card.note,
          card.color,
          card.imageResourceId,
          card.deletedAt?.toIso8601String(),
        ],
    ],
    'edges': [
      for (final edge in edges)
        [edge.id, edge.mapId, edge.fromNodeId, edge.toNodeId],
    ],
    'anchors': [
      for (final anchor in anchors)
        [
          anchor.id,
          anchor.cardId,
          anchor.revisionId,
          anchor.pageIndex,
          anchor.textLayerId,
          anchor.textStart,
          anchor.textEnd,
          anchor.context,
          [for (final quad in anchor.quads) quad.toJson()],
        ],
    ],
  };
  return sha256.convert(utf8.encode(jsonEncode(value))).toString();
}
