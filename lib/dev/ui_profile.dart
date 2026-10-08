import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:pdfrx/pdfrx.dart';

import '../domain/models.dart';
import '../ui/map/mind_map_pane.dart';
import '../ui/reader/reader_pane.dart';
import 'component_previews.dart';

/// 独立的 UI 性能探针：只读取自产 PDF 与内存卡片，不打开用户资料库。
Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kProfileMode) throw StateError('请使用 Flutter Profile 构建运行');
  final report = arguments
      .firstWhere((v) => v.startsWith('--report='))
      .substring(9);
  final pdf = arguments.firstWhere((v) => v.startsWith('--pdf=')).substring(6);
  await pdfrxFlutterInitialize();
  runApp(previewFrame(_UiProfile(report: report, pdf: pdf)));
}

class _UiProfile extends StatefulWidget {
  const _UiProfile({required this.report, required this.pdf});
  final String report;
  final String pdf;
  @override
  State<_UiProfile> createState() => _UiProfileState();
}

class _UiProfileState extends State<_UiProfile> {
  final _readerKey = GlobalKey();
  final _graphKey = GlobalKey();
  final _reader = ReaderPaneController();
  final _graph = MindMapPaneController();
  final _frames = <ui.FrameTiming>[];
  final _errors = <String>[];
  final _report = <String, Object?>{
    'mode': 'profile',
    'scope': '真实 ReaderPane 滚动与 500 个内存卡片的 MindMapPane 拖动；不含 OCR 和数据库容量验收',
  };
  bool _recording = false;
  bool _started = false;
  bool _map = false;
  late final _snapshot = MapSnapshot(
    map: const MindMap(
      layout: MapLayoutKind.free,
      id: 'ui-profile',
      projectId: 'ui-profile',
      title: '500 张卡片',
    ),
    nodes: [
      for (var i = 0; i < 500; i++)
        MapNode(
          id: 'node-$i',
          mapId: 'ui-profile',
          cardId: 'card-$i',
          x: (i % 20) * 240,
          y: (i ~/ 20) * 140,
        ),
    ],
    cards: {
      for (var i = 0; i < 500; i++)
        'card-$i': NoteCard(
          id: 'card-$i',
          projectId: 'ui-profile',
          title: '阅读与思考 $i',
          body: '保留原文上下文，建立概念之间的联系。',
          excerptSnapshot: '',
          note: '个人理解',
          color: '#B8D2EB',
        ),
    },
    anchors: const {},
    edges: const [],
  );

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(_timings);
    FlutterError.onError = (details) => _errors.add(details.toString());
  }

  void _timings(List<ui.FrameTiming> frames) {
    if (_recording) _frames.addAll(frames);
  }

  Future<void> _frame() async {
    SchedulerBinding.instance.ensureVisualUpdate();
    await SchedulerBinding.instance.endOfFrame;
  }

  Future<void> _begin() async {
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    _frames.clear();
    _recording = true;
  }

  Future<Map<String, Object?>> _end() async {
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    _recording = false;
    final samples = _frames.skip(5).toList();
    if (samples.length < 90) throw StateError('引擎帧样本不足：${samples.length}');
    double percentile(Iterable<double> values) {
      final sorted = values.toList()..sort();
      return sorted[((sorted.length - 1) * .95).round()];
    }

    return {
      'samples': samples.length,
      'buildP95Ms': percentile(
        samples.map((f) => f.buildDuration.inMicroseconds / 1000),
      ),
      'rasterP95Ms': percentile(
        samples.map((f) => f.rasterDuration.inMicroseconds / 1000),
      ),
      'totalP95Ms': percentile(
        samples.map((f) => f.totalSpan.inMicroseconds / 1000),
      ),
      'rawFrames': [
        for (final f in samples)
          {
            'buildUs': f.buildDuration.inMicroseconds,
            'rasterUs': f.rasterDuration.inMicroseconds,
            'totalUs': f.totalSpan.inMicroseconds,
          },
      ],
    };
  }

  PdfViewerController _viewer() {
    PdfViewerController? result;
    void visit(Element element) {
      if (element.widget case PdfViewer widget) result = widget.controller;
      element.visitChildElements(visit);
    }

    (_readerKey.currentContext! as Element).visitChildElements(visit);
    return result!;
  }

  Future<void> _run() async {
    if (_started) return;
    _started = true;
    try {
      _report['logicalSize'] = [
        MediaQuery.sizeOf(context).width,
        MediaQuery.sizeOf(context).height,
      ];
      _report['dpr'] = View.of(context).devicePixelRatio;
      final viewId = View.of(context).viewId;
      _report['viewId'] = viewId;
      await _begin();
      final box = _readerKey.currentContext!.findRenderObject()! as RenderBox;
      final position = box.localToGlobal(box.size.center(Offset.zero));
      final before = _viewer().visibleRect.top;
      var distance = 0.0;
      for (var i = 0; i < 120; i++) {
        GestureBinding.instance.handlePointerEvent(
          PointerScrollEvent(
            viewId: viewId,
            device: 7070,
            kind: ui.PointerDeviceKind.mouse,
            position: position,
            scrollDelta: const Offset(0, 5),
          ),
        );
        await _frame();
        distance = math.max(
          distance,
          (_viewer().visibleRect.top - before).abs(),
        );
      }
      if (distance < 20) throw StateError('阅读滚动没有改变实际视口');
      _report['reader'] = {...await _end(), 'scrollDistance': distance};
      setState(() => _map = true);
      await _frame();
      await _reader.drainClosedDocuments();
      await _frame();
      _graph.fitAll();
      await _frame();
      if (_graph.renderedNodeCount != 500) throw StateError('未实际绘制 500 张卡片');
      await _begin();
      final graphBox =
          _graphKey.currentContext!.findRenderObject()! as RenderBox;
      final origin = graphBox.localToGlobal(
        Offset(graphBox.size.width - 20, graphBox.size.height - 20),
      );
      final beforeNode = _graphNodeCenter();
      GestureBinding.instance.handlePointerEvent(
        PointerAddedEvent(
          viewId: viewId,
          device: 7071,
          position: origin,
          kind: ui.PointerDeviceKind.mouse,
        ),
      );
      GestureBinding.instance.handlePointerEvent(
        PointerDownEvent(
          viewId: viewId,
          pointer: 71,
          device: 7071,
          position: origin,
          kind: ui.PointerDeviceKind.mouse,
          buttons: kPrimaryMouseButton,
        ),
      );
      var previous = origin;
      for (var i = 1; i <= 120; i++) {
        final next = origin + Offset(-i * .35, math.sin(i / 12) * 12);
        GestureBinding.instance.handlePointerEvent(
          PointerMoveEvent(
            viewId: viewId,
            pointer: 71,
            device: 7071,
            position: next,
            delta: next - previous,
            kind: ui.PointerDeviceKind.mouse,
            buttons: kPrimaryMouseButton,
          ),
        );
        await _frame();
        previous = next;
      }
      GestureBinding.instance.handlePointerEvent(
        PointerUpEvent(
          viewId: viewId,
          pointer: 71,
          device: 7071,
          position: previous,
          kind: ui.PointerDeviceKind.mouse,
        ),
      );
      final pan = (_graphNodeCenter() - beforeNode).distance;
      if (pan < 10) throw StateError('画布拖动没有改变节点位置');
      _report['graph'] = {
        ...await _end(),
        'visibleNodes': _graph.renderedNodeCount,
        'panDistance': pan,
      };
      if (_errors.isNotEmpty) throw StateError(_errors.join('\n'));
      _report['success'] = true;
    } catch (error, stack) {
      _report['success'] = false;
      _report['error'] = '$error\n$stack';
    } finally {
      _report['flutterErrors'] = _errors;
      await File(widget.report)
          .writeAsString(const JsonEncoder.withIndent('  ').convert(_report));
      exit(_report['success'] == true ? 0 : 1);
    }
  }

  Offset _graphNodeCenter() {
    RenderBox? box;
    void visit(Element element) {
      if (element.widget.key == const ValueKey('map-node-node-0')) {
        box = element.findRenderObject() as RenderBox?;
      }
      element.visitChildElements(visit);
    }

    (_graphKey.currentContext! as Element).visitChildElements(visit);
    return box!.localToGlobal(box!.size.center(Offset.zero));
  }

  @override
  Widget build(BuildContext context) => _map
      ? MindMapPane(
          key: _graphKey,
          controller: _graph,
          snapshot: _snapshot,
          onSelect: (_) {},
          onMove: (_, _, _) async {},
          onReparent: (_, _) async {},
          onAssociate: (_, _) async {},
          onRemoveAssociation: (_) {},
          onAction: (_, _) {},
          onToggleCollapsed: (_) {},
        )
      : ReaderPane(
          key: _readerKey,
          filePath: widget.pdf,
          revisionId: 'ui-profile',
          controller: _reader,
          onExcerpt: (_) {},
          onInitialPageReady: () => unawaited(_run()),
        );

  @override
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_timings);
    super.dispose();
  }
}
