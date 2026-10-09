import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dart_pdf_reader/dart_pdf_reader.dart' as structure;
import 'package:dart_pdf_reader/dart_pdf_reader_io.dart' as structure_io;
import 'package:flutter/widgets.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../domain/models.dart' as model;

/// 引擎页框内坐标与原始 PDF 用户坐标之间的唯一转换入口。
/// pdfrx 返回的文本框已经减去有效页框左下偏移；不能直接持久化。
class PdfCoordinateAdapter {
  const PdfCoordinateAdapter(this.geometry);

  final model.PdfPageGeometry geometry;

  Rect get effectiveBox {
    final crop = quadBounds(geometry.cropBox);
    final media = quadBounds(geometry.mediaBox);
    return crop.intersect(media);
  }

  model.PdfQuad engineRectToQuad(PdfRect rect) {
    final origin = effectiveBox;
    return model.PdfQuad.rect(
      rect.left + origin.left,
      rect.bottom + origin.top,
      rect.right + origin.left,
      rect.top + origin.top,
    );
  }

  PdfRect quadToEngineRect(model.PdfQuad quad) {
    final bounds = quadBounds(quad);
    final origin = effectiveBox;
    return PdfRect(
      bounds.left - origin.left,
      bounds.bottom - origin.top,
      bounds.right - origin.left,
      bounds.top - origin.top,
    );
  }

  /// Rect 的 top/bottom 在此仅作为最小/最大 y；没有屏幕方向含义。
  static Rect quadBounds(model.PdfQuad quad) {
    return Rect.fromLTRB(
      quad.points.map((p) => p.x).reduce(math.min),
      quad.points.map((p) => p.y).reduce(math.min),
      quad.points.map((p) => p.x).reduce(math.max),
      quad.points.map((p) => p.y).reduce(math.max),
    );
  }

  Path quadInDocument(model.PdfQuad quad, PdfPage page, Rect pageRect) {
    final box = effectiveBox;
    final offsets = quad.points.map(
      (point) => PdfPoint(
        point.x - box.left,
        point.y - box.top,
      ).toOffsetInDocument(page: page, pageRect: pageRect),
    );
    return Path()..addPolygon(offsets.toList(), true);
  }

  model.PdfQuad displayRectToQuad(Rect rect, PdfPage page, Size displayedSize) {
    return displayQuadToQuad(
      [rect.topLeft, rect.topRight, rect.bottomRight, rect.bottomLeft],
      page,
      displayedSize,
    );
  }

  model.PdfQuad displayQuadToQuad(
    List<Offset> offsets,
    PdfPage page,
    Size displayedSize,
  ) {
    if (offsets.length != 4) throw ArgumentError('PDF 四边形必须有四个点');
    final box = effectiveBox;
    return model.PdfQuad(
      offsets.map((offset) {
        final point = offset.toPdfPoint(
          page: page,
          scaledPageSize: displayedSize,
        );
        return model.PdfPoint(point.x + box.left, point.y + box.top);
      }).toList(),
    );
  }
}

/// 只读 PDF 接口。所有原始文件、文本版本和批注的写入由仓储统一负责。
class PdfReadEngine {
  static const version = 'pdfrx-2.6.5/pdfium';

  /// PDFium 的 GetView 会把空坐标变为 0；目录需要保留原始 null 语义。
  static Future<List<PdfOutlineNode>> loadOutline(
    PdfDocument document, {
    required String filePath,
  }) async {
    final nodes = await document.loadOutline();
    bool needsCoordinates(List<PdfOutlineNode> nodes) => nodes.any(
      (node) =>
          node.dest == null ||
          (node.dest != null &&
              node.dest!.command != PdfDestCommand.fit &&
              node.dest!.command != PdfDestCommand.fitB) ||
          needsCoordinates(node.children),
    );
    if (!needsCoordinates(nodes)) return nodes;
    try {
      return await Isolate.run(() => _readOutlineParameters(filePath, nodes));
    } catch (error) {
      // 位置元数据损坏不妨碍按有效页码阅读，也不执行未经确认的缩放。
      debugPrint('PDF 目录位置解析失败，已改为页码定位：$error');
      List<PdfOutlineNode> pagesOnly(List<PdfOutlineNode> nodes) => [
        for (final node in nodes)
          PdfOutlineNode(
            title: node.title,
            dest: node.dest == null
                ? null
                : PdfDest(node.dest!.pageNumber, PdfDestCommand.fit, null),
            children: pagesOnly(node.children),
          ),
      ];
      return pagesOnly(nodes);
    }
  }

  static Future<List<model.PdfPageGeometry>> loadGeometry(
    PdfDocument document, {
    required String filePath,
  }) async {
    final geometry = await loadSourceGeometry(filePath);
    if (geometry.length != document.pages.length) {
      throw StateError('PDF 结构页数与阅读引擎不一致，已停止生成来源坐标');
    }
    return geometry;
  }

  /// 只读取页字典：PDFium 公共 API 缺少 UserUnit，使用结构解析器补齐。
  /// 文件按需读取且在独立 isolate 内解析；不复制整本书的字节到主 isolate。
  static Future<List<model.PdfPageGeometry>> loadSourceGeometry(
    String filePath,
  ) {
    return Isolate.run(() => _readSourceGeometry(filePath));
  }

  static Future<model.TextLayerDraft> extractNativeText({
    required String revisionId,
    required PdfPage page,
    required model.PdfPageGeometry geometry,
  }) async {
    await page.ensureLoaded();
    final text = await page.loadStructuredText();
    final coordinates = PdfCoordinateAdapter(geometry);
    final fragments = <model.TextFragment>[];
    // 保留 UTF-16 原始索引，包含换行。可见字符使用准确字符框。
    for (
      var index = 0;
      index < text.charRects.length && index < text.fullText.length;
      index++
    ) {
      final rect = text.charRects[index];
      if (rect.width <= 0 || rect.height <= 0) continue;
      fragments.add(
        model.TextFragment(
          start: index,
          length: 1,
          quad: coordinates.engineRectToQuad(rect),
          order: index,
          precision: model.GeometryPrecision.character,
        ),
      );
    }
    return model.TextLayerDraft(
      revisionId: revisionId,
      pageIndex: page.pageNumber - 1,
      source: model.TextLayerSource.nativePdf,
      text: text.fullText,
      fragments: fragments,
      engineVersion: version,
      parameters: const {
        'coordinates': 'originalPdfUserSpace',
        'textIndex': 'utf16',
      },
    );
  }

  /// 按渲染页面的显示方向截取图片；返回的锚点仍由原始 PDF 坐标描述。
  static Future<Uint8List> captureRect(
    PdfPage page,
    Rect normalizedRect,
  ) async {
    await page.ensureLoaded();
    final rect = normalizedRect.intersect(const Rect.fromLTWH(0, 0, 1, 1));
    if (rect.isEmpty) throw ArgumentError('截图选区为空');
    final fullWidth = math.min(2400.0, math.max(600.0, page.width * 2));
    final fullHeight = fullWidth * page.height / page.width;
    final x = (rect.left * fullWidth).floor();
    final y = (rect.top * fullHeight).floor();
    final width = math.max(1, (rect.width * fullWidth).ceil());
    final height = math.max(1, (rect.height * fullHeight).ceil());
    final bitmap = await page.render(
      x: x,
      y: y,
      width: width,
      height: height,
      fullWidth: fullWidth,
      fullHeight: fullHeight,
      backgroundColor: 0xFFFFFFFF,
    );
    if (bitmap == null) throw StateError('PDF 图片渲染未完成');
    try {
      final image = await bitmap.createImage();
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        if (data == null) throw StateError('无法编码 PNG 摘录');
        return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      } finally {
        image.dispose();
      }
    } finally {
      bitmap.dispose();
    }
  }
}

Future<List<PdfOutlineNode>> _readOutlineParameters(
  String filePath,
  List<PdfOutlineNode> nativeNodes,
) async {
  final file = await File(filePath).open(mode: FileMode.read);
  try {
    final document = await structure.PDFParser(
      structure.BufferedRandomAccessStream(structure_io.FileStream(file)),
    ).parse();
    final catalog = await document.catalog;
    final resolver = catalog.resolver;
    const first = structure.PDFName('First');
    const next = structure.PDFName('Next');
    const dest = structure.PDFName('Dest');
    const d = structure.PDFName('D');
    Map<structure.PDFObject, int>? sourcePages;
    Future<int?> pageNumber(structure.PDFObject raw) async {
      if (sourcePages == null) {
        final indices = <structure.PDFObject, int>{};
        final visited = <structure.PDFObject>{};
        Future<void> visit(structure.PDFObject? page) async {
          if (page == null || !visited.add(page)) return;
          final dictionary = await resolver.resolve<structure.PDFDictionary>(
            page,
          );
          final type = await resolver.resolve<structure.PDFName>(
            dictionary?[const structure.PDFName('Type')],
          );
          if (type?.value == 'Page') {
            indices[page] = indices.length + 1;
          } else if (type?.value == 'Pages') {
            final kids = await resolver.resolve<structure.PDFArray>(
              dictionary?[const structure.PDFName('Kids')],
            );
            if (kids != null) {
              for (final kid in kids) {
                await visit(kid);
              }
            }
          }
        }

        await visit(catalog.dictionary[const structure.PDFName('Pages')]);
        sourcePages = indices;
      }
      return sourcePages![raw];
    }

    final namedVisited = <structure.PDFObject>{};
    Future<structure.PDFObject?> findNamed(
      structure.PDFObject? raw,
      String name,
    ) async {
      if (raw == null || !namedVisited.add(raw) || namedVisited.length > 4096) {
        return null;
      }
      final tree = await resolver.resolve<structure.PDFDictionary>(raw);
      if (tree == null) return null;
      final names = await resolver.resolve<structure.PDFArray>(
        tree[const structure.PDFName('Names')],
      );
      if (names != null) {
        for (var index = 0; index + 1 < names.length; index += 2) {
          final key = await resolver.resolve<structure.PDFStringLike>(
            names[index],
          );
          if (key?.asString() == name) return names[index + 1];
        }
      }
      final kids = await resolver.resolve<structure.PDFArray>(
        tree[const structure.PDFName('Kids')],
      );
      if (kids != null) {
        for (final kid in kids) {
          final found = await findNamed(kid, name);
          if (found != null) return found;
        }
      }
      return null;
    }

    Future<structure.PDFArray?> destinationArray(
      structure.PDFObject? raw,
    ) async {
      var value = await resolver.resolve<structure.PDFObject>(raw);
      if (value is structure.PDFName || value is structure.PDFStringLike) {
        final name = value is structure.PDFName
            ? value.value
            : (value as structure.PDFStringLike).asString();
        final oldNames = await resolver.resolve<structure.PDFDictionary>(
          catalog.dictionary[const structure.PDFName('Dests')],
        );
        raw = oldNames?[structure.PDFName(name)];
        if (raw == null) {
          final names = await resolver.resolve<structure.PDFDictionary>(
            catalog.dictionary[const structure.PDFName('Names')],
          );
          namedVisited.clear();
          raw = await findNamed(names?[const structure.PDFName('Dests')], name);
        }
        value = await resolver.resolve<structure.PDFObject>(raw);
      }
      if (value is structure.PDFDictionary) {
        value = await resolver.resolve<structure.PDFObject>(value[d]);
      }
      return value is structure.PDFArray ? value : null;
    }

    Future<List<PdfOutlineNode>> siblings(
      structure.PDFObject? raw,
      List<PdfOutlineNode> nodes,
    ) async {
      final output = <PdfOutlineNode>[];
      for (final node in nodes) {
        final dictionary = await resolver.resolve<structure.PDFDictionary>(raw);
        final title = await resolver.resolve<structure.PDFStringLike>(
          dictionary?[const structure.PDFName('Title')],
        );
        if (dictionary == null || title?.asString() != node.title) {
          throw const FormatException('目录节点与原始书签不一致');
        }
        var destination = node.dest;
        {
          var rawDestination = dictionary[dest];
          if (rawDestination == null) {
            final action = await resolver.resolve<structure.PDFDictionary>(
              dictionary[const structure.PDFName('A')],
            );
            rawDestination = action?[d];
          }
          final array = await destinationArray(rawDestination);
          if (array != null && array.length >= 2) {
            final targetPage =
                destination?.pageNumber ?? await pageNumber(array[0]);
            final command = await resolver.resolve<structure.PDFName>(array[1]);
            final params = <double?>[];
            for (final value in array.skip(2)) {
              final number = await resolver.resolve<structure.PDFObject>(value);
              params.add(
                number is structure.PDFNumber ? number.toDouble() : null,
              );
            }
            if (targetPage != null) {
              destination = PdfDest(
                targetPage,
                PdfDestCommand.parse(command?.value ?? 'unknown'),
                params,
              );
            }
          }
        }
        output.add(
          PdfOutlineNode(
            title: node.title,
            dest: destination,
            children: await siblings(dictionary[first], node.children),
          ),
        );
        raw = dictionary[next];
      }
      return output;
    }

    final outlines = await resolver.resolve<structure.PDFDictionary>(
      catalog.dictionary[const structure.PDFName('Outlines')],
    );
    return await siblings(outlines?[first], nativeNodes);
  } finally {
    await file.close();
  }
}

Future<List<model.PdfPageGeometry>> _readSourceGeometry(String filePath) async {
  final file = await File(filePath).open(mode: FileMode.read);
  try {
    final stream = structure.BufferedRandomAccessStream(
      structure_io.FileStream(file),
    );
    final document = await structure.PDFParser(stream).parse();
    final pages = await (await document.catalog).getPages();
    final output = <model.PdfPageGeometry>[];
    for (var index = 0; index < pages.pageCount; index++) {
      final page = pages.getPageAtIndex(index);
      Future<model.PdfQuad?> box(String key) async {
        final raw = page.getOrInherited<structure.PDFObject>(
          structure.PDFName(key),
        );
        final array = await page.objectResolver.resolve<structure.PDFArray>(
          raw,
        );
        if (array == null) return null;
        if (array.length != 4) {
          throw FormatException('第 ${index + 1} 页 $key 不是四点页框');
        }
        final values = <double>[];
        for (final element in array) {
          final number = await page.objectResolver.resolve<structure.PDFNumber>(
            element,
          );
          if (number == null) throw FormatException('PDF $key 包含非数值');
          values.add(number.toDouble());
        }
        return model.PdfQuad.rect(values[0], values[1], values[2], values[3]);
      }

      final media = await box('MediaBox');
      if (media == null) throw FormatException('第 ${index + 1} 页没有 MediaBox');
      final crop = await box('CropBox') ?? media;
      final rotationRaw = page.getOrInherited<structure.PDFObject>(
        const structure.PDFName('Rotate'),
      );
      final rotation =
          (await page.objectResolver.resolve<structure.PDFNumber>(rotationRaw))
              ?.toInt() ??
          0;
      // UserUnit 是页级属性，不沿着 Pages 树继承。缺失时的规范默认值确实为 1。
      final unitRaw = page.dictionary[const structure.PDFName('UserUnit')];
      final unit =
          (await page.objectResolver.resolve<structure.PDFNumber>(unitRaw))
              ?.toDouble() ??
          1;
      if (!unit.isFinite || unit <= 0) {
        throw FormatException('第 ${index + 1} 页 UserUnit 无效');
      }
      final geometry = model.PdfPageGeometry(
        pageIndex: index,
        cropBox: crop,
        mediaBox: media,
        rotation: ((rotation % 360) + 360) % 360,
        userUnit: unit,
      );
      if (PdfCoordinateAdapter(geometry).effectiveBox.isEmpty) {
        throw FormatException('第 ${index + 1} 页有效页框为空');
      }
      output.add(geometry);
    }
    return output;
  } finally {
    await file.close();
  }
}
