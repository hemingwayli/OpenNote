import '../theme/open_note_icon.dart';

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../domain/models.dart';
import '../../engines/epub/epub_publication.dart';
import '../../engines/epub/epub_resource_server.dart';
import '../../platform/epub_webview_lifecycle.dart';
import '../workspace/card_color_palette.dart';
import 'reader_contract.dart';

typedef EpubReaderReady = Future<void> Function(
  InAppWebViewController,
  EpubPublication,
);

/// EPUB 与 PDF 共用摘录、来源请求及生命周期合同，正文交给本地 WebView2。
class EpubReaderPane extends StatefulWidget {
  const EpubReaderPane({
    super.key,
    required this.revisionId,
    required this.filePath,
    required this.sessionId,
    required this.onExcerpt,
    this.title = 'EPUB',
    this.controller,
    this.closing = false,
    this.enableTextDrag = false,
    this.textDragContext,
    this.initialPosition,
    this.annotations = const [],
    this.completedSections = const [],
    this.onIndexSection,
    this.onReadingPositionChanged,
    this.onAnnotationCreated,
    this.onAnnotationActivated,
    this.onInitialPageReady,
    this.onImageOcr,
    this.onImageOcrCancel,
    this.onSearch,
    this.onEscape,
    this.onProbeReady,
    this.runtimeVersion,
  });
  final String revisionId;
  final String filePath;
  final String sessionId;
  final String title;
  final ReaderPaneController? controller;
  final bool closing;
  final bool enableTextDrag;
  final Object? textDragContext;
  final ReadingPosition? initialPosition;
  final List<AppAnnotation> annotations;
  final List<int> completedSections;
  final void Function(SelectedExcerpt) onExcerpt;
  final Future<void> Function(Map<String, dynamic>)? onIndexSection;
  final void Function(ReadingPosition)? onReadingPositionChanged;
  final void Function(ReaderAnnotationDraft)? onAnnotationCreated;
  final void Function(AppAnnotation)? onAnnotationActivated;
  final VoidCallback? onInitialPageReady;
  final Future<String> Function(SelectedExcerpt)? onImageOcr;
  final VoidCallback? onImageOcrCancel;
  final VoidCallback? onSearch;
  final VoidCallback? onEscape;
  final EpubReaderReady? onProbeReady;

  /// 原生验收可注入不可用运行时；普通应用始终探测系统运行时。
  final Future<String?> Function()? runtimeVersion;
  @override
  State<EpubReaderPane> createState() => _EpubReaderPaneState();
}

class _EpubReaderPaneState extends State<EpubReaderPane> {
  EpubResourceServer? _server;
  WebViewEnvironment? _environment;
  InAppWebViewController? _web;
  EpubPublication? _publication;
  EpubReadingSettings _settings = const EpubReadingSettings();
  EpubLocator? _position;
  SelectedExcerpt? _selection;
  String? _selectedImageHref;
  Rect? _selectedImageRect;
  String? _error;
  String _status = '正在准备 EPUB…';
  bool _ready = false;
  bool _outline = false;
  bool _regionMode = false;
  bool _busy = false;
  int _generation = 0;
  int _section = 0;
  double _progress = 0;
  double _fixedZoom = 1;
  Offset? _regionStart;
  Rect? _regionRect;
  Future<void>? _shutdown;
  ReaderExcerptDrag? _drag;

  @override
  void initState() {
    super.initState();
    _settings = widget.initialPosition?.settings ?? const EpubReadingSettings();
    _fixedZoom = _settings.fixedZoom;
    _position = widget.initialPosition?.epubLocator;
    _attach();
    unawaited(_open());
  }

  void _attach() {
    widget.controller?.activateRevision(widget.revisionId);
    widget.controller?.jumpToAnchorsDelegate = _jump;
    widget.controller?.goToPageDelegate = null;
    widget.controller?.currentZoomDelegate = () => _fixedZoom;
    widget.controller?.clearSelectionDelegate = _clearSelection;
    widget.controller?.clearHighlightsDelegate = () {
      if (_ready) unawaited(_call('annotations', [_annotationData()]));
    };
  }

  @override
  void didUpdateWidget(covariant EpubReaderPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.closing && !oldWidget.closing) _trackShutdown();
    if (!identical(widget.annotations, oldWidget.annotations) && _ready) {
      unawaited(_run(() => _call('annotations', [_annotationData()])));
    }
    if (widget.textDragContext != oldWidget.textDragContext) _drag?.cancel();
  }

  bool _current(int generation) =>
      mounted && generation == _generation && !widget.closing;

  Future<void> _open() async {
    final generation = ++_generation;
    try {
      if (!Platform.isWindows) throw StateError('EPUB 原生阅读器仅支持 Windows 11 x64');
      final version =
          await (widget.runtimeVersion?.call() ??
              WebViewEnvironment.getAvailableVersion());
      if (!_current(generation)) return;
      if (version == null || version.isEmpty) {
        throw StateError(
          '本机缺少 Microsoft Edge WebView2 Runtime。请安装运行时后重新打开 EPUB；PDF 可继续阅读。',
        );
      }
      final publication = await EpubPublication.open(widget.filePath);
      if (!_current(generation)) return;
      final server = await EpubResourceServer.start(publication);
      if (!_current(generation)) {
        await server.close();
        return;
      }
      _server = server;
      final local = Platform.environment['LOCALAPPDATA'];
      final environment = await WebViewEnvironment.create(
        settings: WebViewEnvironmentSettings(
          userDataFolder:
              '${local ?? Directory.systemTemp.path}${Platform.pathSeparator}OpenNote-WebView2',
        ),
      );
      if (!_current(generation)) {
        await closeEpubWindowsView(
          environmentId: environment.id,
          disposeEnvironment: environment.dispose,
        );
        await server.close();
        return;
      }
      _environment = environment;
      setState(() {
        _publication = publication;
        _status = '正在打开 EPUB…';
      });
    } catch (error) {
      if (_current(generation)) {
        setState(() {
          _error = error.toString();
        });
      }
    }
  }

  Future<dynamic> _call(String method, List<Object?> arguments) async {
    final web = _web;
    if (web == null || widget.closing) throw StateError('EPUB 阅读会话已关闭');
    // 异步 JS 方法必须实际等待完成，不能把 Promise 当作定位成功。
    final result = await web.callAsyncJavaScript(
      functionBody:
          'try {return {ok:true,value:await window.openNote.$method(...argumentsList)}} '
          'catch(error) {return {ok:false,error:String(error?.message || error)}}',
      arguments: {'argumentsList': arguments},
    );
    if (result?.error != null) throw StateError(result!.error.toString());
    final response = result?.value;
    if (response is! Map || response['ok'] != true) {
      throw StateError(
        response is Map ? response['error'].toString() : 'EPUB 引擎响应无效',
      );
    }
    return response['value'];
  }

  Future<void> _message(List<dynamic> arguments) async {
    if (arguments.isEmpty || arguments.first is! Map) return;
    final data = Map<String, dynamic>.from(arguments.first as Map);
    if (!mounted ||
        widget.closing ||
        data['session'] != widget.sessionId ||
        data['revision'] != widget.revisionId ||
        data['generation'] != _generation) {
      return;
    }
    switch (data['type']) {
      case 'ready':
        setState(() {
          _ready = true;
          _status = '';
        });
        await _call('annotations', [_annotationData()]);
        await _call('zoom', [_fixedZoom]);
        widget.onInitialPageReady?.call();
        final pending = widget.controller?.pendingSourceRequest;
        if (pending != null) await _run(() => _jump(pending));
        if (widget.onIndexSection != null) {
          unawaited(
            _run(() => _call('indexAll', [widget.completedSections, _section])),
          );
        }
        final web = _web;
        if (web != null) await widget.onProbeReady?.call(web, _publication!);
      case 'selection':
        final anchors = (data['anchors'] as List)
            .map(
              (value) => AnchorDraft(
                revisionId: widget.revisionId,
                epubLocator: EpubLocator.fromJson(
                  Map<String, dynamic>.from(value as Map),
                ),
                context: value['quote'] as String? ?? '',
              ),
            )
            .toList();
        final rect = data['rect'];
        _drag?.cancel();
        setState(() {
          _selection = SelectedExcerpt(
            text: data['text'] as String? ?? '',
            anchors: anchors,
          );
          _selectedImageHref = data['imageHref'] as String?;
          _selectedImageRect = rect is Map
              ? Rect.fromLTWH(
                  (rect['x'] as num).toDouble(),
                  (rect['y'] as num).toDouble(),
                  (rect['width'] as num).toDouble(),
                  (rect['height'] as num).toDouble(),
                )
              : null;
        });
      case 'position':
        final locator = EpubLocator.fromJson(
          Map<String, dynamic>.from(data['locator'] as Map),
        );
        setState(() {
          _position = locator;
          _section = data['index'] as int;
          _progress = (data['progress'] as num).toDouble().clamp(0, 1);
        });
        _savePosition();
      case 'index':
        await widget.onIndexSection?.call(data);
        if (mounted) {
          setState(() {
            _status =
                '正在建立正文索引 · ${(data['index'] as int) + 1}/${_publication!.sections.length}';
          });
        }
      case 'indexed':
        if (mounted) {
          setState(() {
            _status = '';
          });
        }
      case 'annotation':
        final annotation = widget.annotations
            .where((a) => a.id == data['id'])
            .firstOrNull;
        if (annotation != null) widget.onAnnotationActivated?.call(annotation);
      case 'escape':
        if (_regionMode || _selection != null) {
          _clearSelection();
        } else {
          widget.onEscape?.call();
        }
      case 'search':
        widget.onSearch?.call();
    }
  }

  List<Map<String, Object?>> _annotationData() => [
    for (final item in widget.annotations)
      if (item.epubLocator != null)
        {
          'id': item.id,
          'color': item.color,
          'locator': item.epubLocator!.toJson(),
        },
  ];

  void _savePosition() {
    if (_position case final position?) {
      widget.onReadingPositionChanged?.call(
        ReadingPosition(
          revisionId: widget.revisionId,
          epubLocator: position,
          settings: _settings,
        ),
      );
    }
  }

  Future<void> _jump(ReaderSourceRequest request) async {
    if (!_ready || request.revisionId != widget.revisionId) return;
    for (final anchor in request.anchors) {
      if (anchor.revisionId != widget.revisionId ||
          anchor.epubLocator == null) {
        throw StateError('EPUB 来源格式或文档版本不一致');
      }
      if (widget.controller?.isCurrentSource(request) == false) {
        return;
      }
      await _call('jump', [anchor.epubLocator!.toJson(), request.sequence]);
    }
    widget.controller?.acceptSource(request);
  }

  Future<void> _run(Future<dynamic> Function() action) async {
    try {
      await action();
    } catch (error) {
      if (mounted && !widget.closing) {
        setState(() {
          _error = error.toString();
        });
      }
    }
  }

  void _clearSelection() {
    _drag?.cancel();
    if (mounted) {
      setState(() {
        _selection = null;
        _selectedImageHref = null;
        _selectedImageRect = null;
        _regionMode = false;
        _regionRect = null;
      });
    }
  }

  Future<Uint8List> _screenshot(Rect? rect) async {
    final image = await _web!.takeScreenshot(
      screenshotConfiguration: ScreenshotConfiguration(
        rect: rect == null
            ? null
            : InAppWebViewRect(
                x: rect.left,
                y: rect.top,
                width: rect.width,
                height: rect.height,
              ),
      ),
    );
    if (image == null || image.isEmpty) throw StateError('EPUB 区域截图失败');
    return image;
  }

  Future<SelectedExcerpt> _prepareSelection() async {
    final selected = _selection;
    if (selected == null || selected.anchors.isEmpty) {
      throw StateError('请先选择文字或图片');
    }
    final generation = _generation;
    Uint8List? image = selected.imageBytes;
    final imageHref = _selectedImageHref;
    if (imageHref != null) {
      image = _publication!.resources[imageHref];
      if (image == null) throw StateError('原图资源缺失');
      // 卡片与备份统一保存 PNG；原书中的 JPEG 等资源仍完整保留。
      final codec = await ui.instantiateImageCodec(image);
      try {
        final frame = await codec.getNextFrame();
        try {
          final png = await frame.image.toByteData(
            format: ui.ImageByteFormat.png,
          );
          if (png == null) throw StateError('原图转换失败');
          image = png.buffer.asUint8List();
        } finally {
          frame.image.dispose();
        }
      } finally {
        codec.dispose();
      }
    } else if (_selectedImageRect != null) {
      image = await _screenshot(_selectedImageRect);
    }
    if (!_current(generation)) throw const ReaderExcerptDragCancelled();
    return SelectedExcerpt(
      text: selected.text,
      anchors: selected.anchors,
      imageBytes: image,
    );
  }

  Future<void> _captureRegion(Rect rect) async {
    await _run(() async {
      final generation = _generation;
      final result = await _call('region', [
        {
          'x': rect.left,
          'y': rect.top,
          'width': rect.width,
          'height': rect.height,
        },
      ]);
      final json = Map<String, dynamic>.from(result as Map);
      final anchors = (json['anchors'] as List)
          .map(
            (a) => AnchorDraft(
              revisionId: widget.revisionId,
              epubLocator: EpubLocator.fromJson(
                Map<String, dynamic>.from(a as Map),
              ),
            ),
          )
          .toList();
      if (anchors.isEmpty) throw StateError('区域没有可定位的原文内容');
      final screenshot = await _screenshot(rect);
      if (!_current(generation)) return;
      setState(() {
        _regionMode = false;
        _regionRect = null;
        _selectedImageHref = null;
        _selectedImageRect = null;
        _selection = SelectedExcerpt(
          text: json['text'] as String,
          anchors: anchors,
          imageBytes: screenshot,
        );
      });
    });
  }

  Future<void> _changeZoom(double ratio) => _run(() async {
    final generation = _generation;
    final zoom = (_fixedZoom * ratio).clamp(.2, 5).toDouble();
    await _call('zoom', [zoom]);
    if (!_current(generation)) return;
    setState(() {
      _fixedZoom = zoom;
      _settings = EpubReadingSettings.fromJson({
        ..._settings.toJson(),
        'fixedZoom': zoom,
      });
    });
    _savePosition();
  });

  Future<void> _changeSettings() async {
    var size = _settings.fontSize,
        line = _settings.lineHeight,
        margin = _settings.margin;
    var font = _settings.font, paginated = _settings.paginated;
    final result = await showDialog<EpubReadingSettings>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('EPUB 阅读设置'),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('字号 ${size.round()}'),
                Slider(
                  key: const Key('epub-font-size-slider'),
                  value: size,
                  min: 12,
                  max: 48,
                  divisions: 36,
                  onChanged: (v) => update(() => size = v),
                ),
                Text('行距 ${line.toStringAsFixed(1)}'),
                Slider(
                  value: line,
                  min: 1,
                  max: 3,
                  divisions: 20,
                  onChanged: (v) => update(() => line = v),
                ),
                Text('页边距 ${margin.round()}'),
                Slider(
                  value: margin,
                  min: 0,
                  max: 100,
                  divisions: 25,
                  onChanged: (v) => update(() => margin = v),
                ),
                DropdownButton<String>(
                  value: font,
                  items: const [
                    DropdownMenuItem(
                      value: 'Source Han Sans CN',
                      child: Text('思源黑体'),
                    ),
                    DropdownMenuItem(
                      value: 'Segoe UI',
                      child: Text('Segoe UI'),
                    ),
                    DropdownMenuItem(value: 'serif', child: Text('衬线字体')),
                  ],
                  onChanged: (v) => update(() => font = v!),
                ),
                SwitchListTile(
                  title: const Text('分页阅读'),
                  value: paginated,
                  onChanged: (v) => update(() => paginated = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                context,
                EpubReadingSettings(
                  fontSize: size,
                  lineHeight: line,
                  margin: margin,
                  font: font,
                  paginated: paginated,
                  fixedZoom: _fixedZoom,
                ),
              ),
              child: const Text('应用'),
            ),
          ],
        ),
      ),
    );
    if (result == null || !mounted || widget.closing) return;
    await _run(() async {
      await _call('settings', [result.toJson()]);
      setState(() {
        _settings = result;
      });
      _savePosition();
    });
  }

  void _trackShutdown() {
    final future = _close();
    widget.controller?.trackClosedDocument(future);
  }

  Future<void> _close() => _shutdown ??= () async {
    _generation++;
    _drag?.cancel();
    final web = _web;
    _web = null;
    if (web != null) {
      // 卸载时子视图已开始原生销毁，不能再等待会被销毁的 JS 回调。
      // 由原生 dispose 回执确认整个 JS 文档与视图已实际关闭。
      web.dispose();
    }
    final environment = _environment;
    if (environment != null) {
      await closeEpubWindowsView(
        environmentId: environment.id,
        disposeEnvironment: environment.dispose,
      );
    }
    assert(() {
      debugPrint('EPUB 生命周期：视图与环境已关闭');
      return true;
    }());
    await _server?.close();
    assert(() {
      debugPrint('EPUB 生命周期：本地服务已关闭');
      return true;
    }());
  }();
  @override
  void dispose() {
    _trackShutdown();
    if (widget.controller?.jumpToAnchorsDelegate == _jump) {
      widget.controller?.jumpToAnchorsDelegate = null;
      widget.controller?.currentZoomDelegate = null;
      widget.controller?.clearSelectionDelegate = null;
    }
    super.dispose();
  }

  Widget _excerptButton() {
    final selected = _selection;
    final button = IconButton(
      key: const Key('epub-excerpt-action'),
      tooltip: '摘录到脑图',
      icon: const OpenNoteIcon(Icons.add_comment_outlined),
      onPressed: !_ready || _busy || selected == null
          ? null
          : () => unawaited(
              _run(() async {
                final excerpt = await _prepareSelection();
                widget.onExcerpt(excerpt);
                _clearSelection();
              }),
            ),
    );
    if (!widget.enableTextDrag || selected == null || !_ready) return button;
    final generation = _generation;
    final drag = _drag ??= ReaderExcerptDrag(
      revisionId: widget.revisionId,
      text: selected.text,
      anchors: selected.anchors,
      sourceIsCurrent: () =>
          _current(generation) && identical(selected, _selection),
      prepareExcerpt: _prepareSelection,
      onCommitted: _clearSelection,
      onFinished: (error) {
        if (mounted) {
          setState(() {
            _drag = null;
            if (error != null) _error = error.toString();
          });
        }
      },
    );
    return Draggable<ReaderExcerptDrag>(
      data: drag,
      onDragStarted: drag.start,
      onDragEnd: (_) {
        if (!drag.isClaimed) drag.cancel();
      },
      feedback: Material(
        elevation: 3,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            selected.text.isEmpty
                ? '图片摘录'
                : selected.text.length > 36
                ? '${selected.text.substring(0, 36)}…'
                : selected.text,
          ),
        ),
      ),
      child: button,
    );
  }

  Widget _outlineItem(EpubOutlineItem item) => item.children.isEmpty
      ? ListTile(
          dense: true,
          title: Text(item.title),
          onTap: () => unawaited(_run(() => _call('chapter', [item.href]))),
        )
      : ExpansionTile(
          title: Text(item.title),
          leading: item.href.isEmpty
              ? null
              : IconButton(
                  tooltip: '阅读这一章节',
                  icon: const OpenNoteIcon(Icons.menu_book_outlined),
                  onPressed: () =>
                      unawaited(_run(() => _call('chapter', [item.href]))),
                ),
          children: [for (final child in item.children) _outlineItem(child)],
        );

  @override
  Widget build(BuildContext context) {
    if (widget.closing || _shutdown != null) return const SizedBox.shrink();
    final publication = _publication;
    if (publication == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error ?? _status, textAlign: TextAlign.center),
        ),
      );
    }
    final fixed = publication
        .sections[_section.clamp(0, publication.sections.length - 1)]
        .fixedLayout;
    return Column(
      children: [
        SizedBox(
          height: 44,
          child: LayoutBuilder(
            builder: (context, constraints) => Row(
              children: [
                IconButton(
                  tooltip: '目录',
                  icon: const OpenNoteIcon(Icons.menu_book_outlined),
                  onPressed: () => setState(() {
                    _outline = !_outline;
                  }),
                ),
                if (constraints.maxWidth >= 360)
                  IconButton(
                    tooltip: '上一章节',
                    icon: const OpenNoteIcon(Icons.chevron_left),
                    onPressed: _ready
                        ? () => unawaited(_run(() => _call('previous', [])))
                        : null,
                  ),
                Flexible(
                  child: Text(
                    '${_section + 1}/${publication.sections.length} · ${(_progress * 100).round()}%',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (constraints.maxWidth >= 360)
                  IconButton(
                    tooltip: '下一章节',
                    icon: const OpenNoteIcon(Icons.chevron_right),
                    onPressed: _ready
                        ? () => unawaited(_run(() => _call('next', [])))
                        : null,
                  ),
                _excerptButton(),
                if (constraints.maxWidth >= 520)
                  IconButton(
                    tooltip: '区域摘录',
                    icon: OpenNoteIcon(
                      _regionMode ? Icons.crop_free : Icons.crop,
                    ),
                    onPressed: !_ready
                        ? null
                        : () => setState(() {
                            _regionMode = !_regionMode;
                          }),
                  ),
                PopupMenuButton<String>(
                  tooltip: '更多阅读工具',
                  icon: const OpenNoteIcon(Icons.more_horiz),
                  onSelected: (value) => unawaited(
                    _run(() async {
                      if (value == 'settings') {
                        await _changeSettings();
                      } else if (value == 'previous' || value == 'next') {
                        await _call(value, []);
                      } else if (value == 'region') {
                        setState(() {
                          _regionMode = !_regionMode;
                        });
                      } else if (value == 'excerpt') {
                        widget.onExcerpt(await _prepareSelection());
                        _clearSelection();
                      } else if (value == 'index-cancel') {
                        await _call('cancelIndex', []);
                        setState(() {
                          _status = '正文索引已暂停';
                        });
                      } else if (value == 'index-resume') {
                        await _call('indexAll', [
                          widget.completedSections,
                          _section,
                        ]);
                      } else if (value == 'zoom-in' || value == 'zoom-out') {
                        await _changeZoom(value == 'zoom-in' ? 1.2 : 1 / 1.2);
                      } else if (value == 'copy') {
                        await Clipboard.setData(
                          ClipboardData(text: _selection?.text ?? ''),
                        );
                      } else if (value == 'ocr-cancel') {
                        widget.onImageOcrCancel?.call();
                      } else if (value == 'ocr') {
                        final excerpt = await _prepareSelection();
                        final generation = _generation;
                        setState(() {
                          _busy = true;
                        });
                        try {
                          final result = await widget.onImageOcr?.call(excerpt);
                          if (!context.mounted ||
                              !_current(generation) ||
                              result == null) {
                            return;
                          }
                          var selectedText = result;
                          final selected = await showDialog<String>(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: const Text('图片识别结果'),
                              content: SizedBox(
                                width: 480,
                                height: 320,
                                child: SingleChildScrollView(
                                  child: SelectionArea(
                                    onSelectionChanged: (value) {
                                      selectedText = value?.plainText ?? result;
                                    },
                                    child: Text(
                                      result.isEmpty ? '未识别到文字' : result,
                                    ),
                                  ),
                                ),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(context),
                                  child: const Text('关闭'),
                                ),
                                if (result.isNotEmpty)
                                  FilledButton(
                                    onPressed: () =>
                                        Navigator.pop(context, selectedText),
                                    child: const Text('摘录识别文字'),
                                  ),
                              ],
                            ),
                          );
                          if (selected != null && _current(generation)) {
                            widget.onExcerpt(
                              SelectedExcerpt(
                                text: selected,
                                anchors: excerpt.anchors,
                                imageBytes: excerpt.imageBytes,
                              ),
                            );
                          }
                        } finally {
                          if (mounted) {
                            setState(() {
                              _busy = false;
                            });
                          }
                        }
                      } else if (value == 'highlight' ||
                          value == 'highlight-color' ||
                          value == 'note') {
                        final anchors = List<AnchorDraft>.from(
                          _selection?.anchors ?? const <AnchorDraft>[],
                        );
                        final generation = _generation;
                        var color = '#F7D976';
                        if (value == 'highlight-color') {
                          final picked = await showDialog<String>(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: const Text('原文高亮颜色'),
                              content: SizedBox(
                                width: 340,
                                child: CardColorPalette(
                                  onSelected: (value) =>
                                      Navigator.pop(context, value),
                                ),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(context),
                                  child: const Text('取消'),
                                ),
                              ],
                            ),
                          );
                          if (picked == null || !_current(generation)) return;
                          color = picked;
                        }
                        if (!context.mounted) return;
                        String text = '';
                        if (value == 'note') {
                          final controller = TextEditingController();
                          final result = await showDialog<String>(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: const Text('原文备注'),
                              content: TextField(
                                controller: controller,
                                autofocus: true,
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(context),
                                  child: const Text('取消'),
                                ),
                                FilledButton(
                                  onPressed: () =>
                                      Navigator.pop(context, controller.text),
                                  child: const Text('保存'),
                                ),
                              ],
                            ),
                          );
                          controller.dispose();
                          if (result == null) return;
                          text = result;
                        }
                        if (!_current(generation)) return;
                        for (final anchor in anchors) {
                          widget.onAnnotationCreated?.call(
                            ReaderAnnotationDraft(
                              revisionId: widget.revisionId,
                              pageIndex: 0,
                              quads: const [],
                              epubLocator: anchor.epubLocator,
                              kind: value == 'note' ? 'note' : 'highlight',
                              color: color,
                              text: text,
                            ),
                          );
                        }
                      }
                    }),
                  ),
                  itemBuilder: (_) => [
                    if (!fixed)
                      const PopupMenuItem(
                        value: 'settings',
                        child: Text('阅读设置'),
                      ),
                    const PopupMenuItem(value: 'previous', child: Text('上一章节')),
                    const PopupMenuItem(value: 'next', child: Text('下一章节')),
                    const PopupMenuItem(value: 'region', child: Text('区域摘录')),
                    if (fixed) ...[
                      const PopupMenuItem(value: 'zoom-in', child: Text('放大')),
                      const PopupMenuItem(value: 'zoom-out', child: Text('缩小')),
                    ],
                    if (widget.onIndexSection != null) ...[
                      const PopupMenuItem(
                        value: 'index-cancel',
                        child: Text('暂停正文索引'),
                      ),
                      const PopupMenuItem(
                        value: 'index-resume',
                        child: Text('继续正文索引'),
                      ),
                    ],
                    if (_busy && widget.onImageOcrCancel != null)
                      const PopupMenuItem(
                        value: 'ocr-cancel',
                        child: Text('取消图片识别'),
                      ),
                    if (_selection != null) ...[
                      const PopupMenuItem(
                        value: 'excerpt',
                        child: Text('摘录到脑图'),
                      ),
                      const PopupMenuItem(value: 'copy', child: Text('复制文字')),
                      const PopupMenuItem(
                        value: 'highlight',
                        child: Text('高亮原文'),
                      ),
                      const PopupMenuItem(
                        value: 'highlight-color',
                        child: Text('选择高亮颜色…'),
                      ),
                      const PopupMenuItem(value: 'note', child: Text('添加备注')),
                      if (widget.onImageOcr != null &&
                          (_selection!.imageBytes != null ||
                              _selectedImageHref != null ||
                              _selectedImageRect != null))
                        const PopupMenuItem(
                          value: 'ocr',
                          child: Text('识别图片文字'),
                        ),
                    ],
                  ],
                ),
                if (fixed && constraints.maxWidth >= 520) ...[
                  IconButton(
                    tooltip: '缩小',
                    icon: const OpenNoteIcon(Icons.remove),
                    onPressed: () => unawaited(_changeZoom(1 / 1.2)),
                  ),
                  IconButton(
                    tooltip: '放大',
                    icon: const OpenNoteIcon(Icons.add),
                    onPressed: () => unawaited(_changeZoom(1.2)),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (_error != null)
          Material(
            color: Theme.of(context).colorScheme.errorContainer,
            child: Row(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(_error!),
                  ),
                ),
                IconButton(
                  icon: const OpenNoteIcon(Icons.close),
                  onPressed: () => setState(() {
                    _error = null;
                  }),
                ),
              ],
            ),
          ),
        if (_busy) const LinearProgressIndicator(),
        Expanded(
          child: Row(
            children: [
              if (_outline)
                SizedBox(
                  width: 240,
                  child: ListView(
                    children: [
                      for (final item in publication.outline)
                        _outlineItem(item),
                    ],
                  ),
                ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) => Stack(
                    children: [
                      InAppWebView(
                        webViewEnvironment: _environment,
                        initialUrlRequest: URLRequest(
                          url: WebUri(_server!.readerUrl),
                        ),
                        initialSettings: InAppWebViewSettings(
                          javaScriptEnabled: true,
                          useShouldOverrideUrlLoading: true,
                          transparentBackground: false,
                          disableContextMenu: true,
                          supportZoom: false,
                        ),
                        onWebViewCreated: (controller) {
                          _web = controller;
                          controller.addJavaScriptHandler(
                            handlerName: 'opennote',
                            callback: _message,
                          );
                        },
                        onConsoleMessage: (_, message) {
                          if (message.messageLevel ==
                                  ConsoleMessageLevel.ERROR &&
                              mounted) {
                            setState(() {
                              _error = message.message;
                            });
                          }
                        },
                        shouldOverrideUrlLoading: (_, action) async =>
                            action.request.url?.toString().startsWith(
                                  _server!.baseUrl,
                                ) ==
                                true
                            ? NavigationActionPolicy.ALLOW
                            : NavigationActionPolicy.CANCEL,
                        onLoadStop: (controller, url) async {
                          if (_ready || widget.closing) return;
                          await _run(
                            () => _call('initialize', [
                              {
                                'session': widget.sessionId,
                                'revision': widget.revisionId,
                                'generation': _generation,
                                'opf': _server!.packageUrl,
                                'fontUrl':
                                    '${_server!.baseUrl}/app/reading-font.otf',
                                'sections': publication.sections
                                    .map((s) => s.toJson())
                                    .toList(),
                                'settings': _settings.toJson(),
                                'position': _position?.toJson(),
                              },
                            ]),
                          );
                        },
                      ),
                      if (_regionMode)
                        Positioned.fill(
                          child: GestureDetector(
                            key: const Key('epub-region-overlay'),
                            behavior: HitTestBehavior.opaque,
                            onPanStart: (d) => setState(() {
                              _regionStart = d.localPosition;
                              _regionRect = null;
                            }),
                            onPanUpdate: (d) => setState(() {
                              _regionRect =
                                  Rect.fromPoints(
                                    _regionStart!,
                                    d.localPosition,
                                  ).intersect(
                                    Rect.fromLTWH(
                                      0,
                                      0,
                                      constraints.maxWidth,
                                      constraints.maxHeight,
                                    ),
                                  );
                            }),
                            onPanEnd: (_) {
                              final rect = _regionRect;
                              if (rect != null &&
                                  rect.width >= 3 &&
                                  rect.height >= 3) {
                                unawaited(_captureRegion(rect));
                              }
                            },
                            child: CustomPaint(
                              painter: _RegionPainter(_regionRect),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _RegionPainter extends CustomPainter {
  const _RegionPainter(this.rect);
  final Rect? rect;
  @override
  void paint(Canvas canvas, Size size) {
    if (rect != null) {
      canvas.drawRect(
        rect!,
        Paint()
          ..color = const Color(0x553574CB)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(_RegionPainter oldDelegate) => rect != oldDelegate.rect;
}
