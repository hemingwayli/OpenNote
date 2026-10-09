import '../theme/open_note_icon.dart';

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../engines/epub/epub_publication.dart';

typedef CoverRenderer = Future<Uint8List> Function(String path, int width);

/// 可见卡片共享两路渲染队列；离屏排队任务取消，运行中的句柄在 finally 释放。
class ProjectCoverCache {
  ProjectCoverCache(this.directory, {CoverRenderer? renderer})
    : _renderer = renderer ?? _render;
  final String directory;
  final CoverRenderer _renderer;
  final _queue = Queue<_CoverJob>();
  final _jobs = <String, _CoverJob>{};
  int _running = 0;
  bool _disposed = false;
  int get activeRenderCount => _running;
  int get queuedCount => _queue.length;
  bool get isDisposed => _disposed;

  Future<void> discardCorruptImage(String hash, int width) async {
    final key = '$hash-$width-v1';
    final file = File('$directory/$key.png');
    _jobs.remove(key);
    if (await file.exists()) await file.delete();
  }

  Future<Uint8List?> acquire(String path, String hash, int width) {
    if (_disposed) return Future.value(null);
    final key = '$hash-$width-v1';
    final old = _jobs[key];
    if (old != null) {
      old.references++;
      return old.result.future;
    }
    final job = _CoverJob(key, path, width);
    _jobs[key] = job;
    _queue.add(job);
    _pump();
    return job.result.future;
  }

  void release(String hash, int width, {Future<Uint8List?>? request}) {
    final key = '$hash-$width-v1';
    final job = _jobs[key];
    if (job == null ||
        (request != null && request != job.result.future) ||
        --job.references > 0) {
      return;
    }
    if (_queue.remove(job)) {
      job.result.complete(null);
      _jobs.remove(key);
    } else if (job.result.isCompleted) {
      _jobs.remove(key);
    }
  }

  void dispose() {
    _disposed = true;
    for (final job in _queue) {
      job.result.complete(null);
      _jobs.remove(job.key);
    }
    _queue.clear();
  }

  Future<void> disposeAndDrain() async {
    final pending = _jobs.values.map((job) => job.result.future).toList();
    dispose();
    // 渲染失败属于封面错误，不阻止整库恢复；全部 PDF 句柄仍须实际释放。
    await Future.wait(
      pending.map(
        (request) =>
            request.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      ),
    );
  }

  void _pump() {
    while (!_disposed && _running < 2 && _queue.isNotEmpty) {
      final job = _queue.removeFirst();
      _running++;
      unawaited(_load(job));
    }
  }

  Future<void> _load(_CoverJob job) async {
    try {
      final file = File('$directory/${job.key}.png');
      Uint8List bytes;
      if (await file.exists()) {
        bytes = await file.readAsBytes();
      } else {
        bytes = await _renderer(job.path, job.width);
        await file.parent.create(recursive: true);
        final temporary = File('${file.path}.pending');
        await temporary.writeAsBytes(bytes, flush: true);
        await temporary.rename(file.path);
      }
      job.result.complete(_disposed ? null : bytes);
    } catch (error, stack) {
      // 失败项不留在去重表中，否则同一封面的多个卡片会彼此阻止重试。
      _jobs.remove(job.key);
      if (_disposed) {
        job.result.complete(null);
      } else {
        job.result.completeError(error, stack);
      }
    } finally {
      _running--;
      if (job.references <= 0 || _disposed) _jobs.remove(job.key);
      _pump();
    }
  }

  static Future<Uint8List> _render(String path, int width) async {
    if (path.toLowerCase().endsWith('.epub')) {
      final publication = await EpubPublication.open(path);
      final cover = publication.coverPath == null
          ? null
          : publication.resources[publication.coverPath];
      if (cover == null) throw StateError('本书没有封面图片');
      final codec = await ui.instantiateImageCodec(cover, targetWidth: width);
      try {
        final frame = await codec.getNextFrame();
        try {
          final data = await frame.image.toByteData(
            format: ui.ImageByteFormat.png,
          );
          if (data == null) throw StateError('无法编码 EPUB 封面');
          return data.buffer.asUint8List(
            data.offsetInBytes,
            data.lengthInBytes,
          );
        } finally {
          frame.image.dispose();
        }
      } finally {
        codec.dispose();
      }
    }
    final document = await PdfDocument.openFile(path);
    try {
      final page = document.pages.first;
      await page.ensureLoaded();
      final height = (width * page.height / page.width).round();
      final bitmap = await page.render(
        width: width,
        height: height,
        fullWidth: width.toDouble(),
        fullHeight: height.toDouble(),
        backgroundColor: 0xffffffff,
      );
      if (bitmap == null) throw StateError('无法生成 PDF 封面');
      try {
        final image = await bitmap.createImage();
        try {
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          if (data == null) throw StateError('无法编码封面');
          return data.buffer.asUint8List(
            data.offsetInBytes,
            data.lengthInBytes,
          );
        } finally {
          image.dispose();
        }
      } finally {
        bitmap.dispose();
      }
    } finally {
      await document.dispose();
    }
  }
}

class _CoverJob {
  _CoverJob(this.key, this.path, this.width);
  final String key;
  final String path;
  final int width;
  final result = Completer<Uint8List?>();
  int references = 1;
}

class ProjectCover extends StatefulWidget {
  const ProjectCover({super.key, required this.cache, this.path, this.hash});
  final ProjectCoverCache cache;
  final String? path;
  final String? hash;
  @override
  State<ProjectCover> createState() => _ProjectCoverState();
}

class _ProjectCoverState extends State<ProjectCover> {
  Future<Uint8List?>? _future;
  int _width = 0;
  void _release() {
    if (_width > 0 && widget.hash != null) {
      widget.cache.release(widget.hash!, _width, request: _future);
    }
  }

  void _load() {
    if (widget.path != null && widget.hash != null) {
      _future = widget.cache.acquire(widget.path!, widget.hash!, _width);
    }
  }

  Widget _retry({bool corruptImage = false}) => Center(
    child: TextButton.icon(
      onPressed: () async {
        if (corruptImage && widget.hash != null) {
          try {
            await widget.cache.discardCorruptImage(widget.hash!, _width);
          } on FileSystemException {
            // 文件被临时占用时继续保留重试入口。
            return;
          }
        }
        if (!mounted) return;
        setState(() {
          _release();
          _load();
        });
      },
      icon: const OpenNoteIcon(Icons.refresh, size: 18),
      label: const Text('重试封面'),
    ),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final width = (300 * MediaQuery.devicePixelRatioOf(context)).round().clamp(
      300,
      600,
    );
    if (width != _width) {
      _release();
      _width = width;
      _load();
    }
  }

  @override
  void didUpdateWidget(ProjectCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cache != widget.cache || oldWidget.hash != widget.hash) {
      if (oldWidget.hash != null) {
        oldWidget.cache.release(oldWidget.hash!, _width, request: _future);
      }
      _future = null;
      _load();
    }
  }

  @override
  void dispose() {
    _release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.bottomLeft,
    child: FutureBuilder<Uint8List?>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _placeholder(_retry());
        }
        if (snapshot.data != null) {
          return Image.memory(
            snapshot.data!,
            excludeFromSemantics: true,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            frameBuilder: (context, image, frame, synchronous) =>
                frame == null && !synchronous
                ? image
                : DecoratedBox(
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      boxShadow: [
                        BoxShadow(
                          color: Color(0x18292c30),
                          blurRadius: 10,
                          offset: Offset(0, 4),
                        ),
                      ],
                    ),
                    child: image,
                  ),
            errorBuilder: (_, _, _) => _placeholder(_retry(corruptImage: true)),
          );
        }
        return _placeholder(
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const OpenNoteIcon(
                  Icons.menu_book_outlined,
                  size: 40,
                  color: Color(0xffa5a8ad),
                ),
                if (widget.path != null) ...[
                  const SizedBox(height: 10),
                  Text('正在准备封面', style: Theme.of(context).textTheme.bodySmall),
                ],
              ],
            ),
          ),
        );
      },
    ),
  );

  Widget _placeholder(Widget child) => AspectRatio(
    aspectRatio: 2 / 3,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xfff4f5f6),
        borderRadius: BorderRadius.circular(2),
        border: Border.all(color: const Color(0xffe7e8ea)),
      ),
      child: child,
    ),
  );
}
