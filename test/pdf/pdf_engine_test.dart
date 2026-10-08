import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:opennote/engines/pdf/pdf_read_engine.dart';
import 'package:opennote/engines/pdf/pdf_text_selection.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fixtureRoot = Directory('tools/fixtures/pdf').absolute.path;

  setUpAll(() async {
    final dll = File('build/windows/x64/runner/Release/pdfium.dll');
    if (dll.existsSync()) Pdfrx.pdfiumModulePath = dll.absolute.path;
    await pdfrxInitialize();
  });

  test('真实页字典保留非零框、四种旋转、UserUnit与压缩对象流', () async {
    for (final name in ['rotate_cropbox.pdf', 'compressed_geometry.pdf']) {
      final geometry = await PdfReadEngine.loadSourceGeometry(
        '$fixtureRoot/$name',
      );
      expect(geometry, hasLength(4));
      for (var index = 0; index < 4; index++) {
        final page = geometry[index];
        expect(page.pageIndex, index);
        expect(page.rotation, index * 90);
        expect(page.userUnit, 1.5);
        expect(page.cropBox.points.map((point) => [point.x, point.y]), [
          [40, 750],
          [570, 750],
          [570, 60],
          [40, 60],
        ]);
        expect(page.mediaBox.points.map((point) => [point.x, point.y]), [
          [-30, 850],
          [650, 850],
          [650, -50],
          [-30, -50],
        ]);
      }
    }
  });

  test('真实原生中英文字、扫描页与混合页面可分别识别', () async {
    final document = await PdfDocument.openFile('$fixtureRoot/mixed.pdf');
    try {
      final geometry = await PdfReadEngine.loadGeometry(
        document,
        filePath: '$fixtureRoot/mixed.pdf',
      );
      final layers = [];
      for (var index = 0; index < document.pages.length; index++) {
        layers.add(
          await PdfReadEngine.extractNativeText(
            revisionId: 'fixture',
            page: document.pages[index],
            geometry: geometry[index],
          ),
        );
      }
      expect(layers[0].text, contains('Mixed document native page'));
      expect(layers[0].text, contains('混合文档的原生页'));
      expect(layers[1].text.trim(), isEmpty);
      expect(layers[1].fragments, isEmpty);
      expect(layers[2].text, contains('Mixed document final page'));
      expect(layers[0].fragments.length, greaterThan(20));
    } finally {
      await document.dispose();
    }
  });

  test('原生字符恢复原始PDF坐标，显示缩放旋转往返保持同一位置', () async {
    final document = await PdfDocument.openFile(
      '$fixtureRoot/rotate_cropbox.pdf',
    );
    try {
      final geometry = await PdfReadEngine.loadGeometry(
        document,
        filePath: '$fixtureRoot/rotate_cropbox.pdf',
      );
      for (var index = 0; index < document.pages.length; index++) {
        final originalPage = document.pages[index];
        final layer = await PdfReadEngine.extractNativeText(
          revisionId: 'fixture',
          page: originalPage,
          geometry: geometry[index],
        );
        expect(layer.text, contains('OpenNote native text first page'));
        final headingStart = layer.text.indexOf(
          'OpenNote native text first page',
        );
        final first = layer.fragments.firstWhere(
          (fragment) => fragment.start == headingStart,
        );
        final rawBounds = PdfCoordinateAdapter.quadBounds(first.quad);
        expect(rawBounds.left, closeTo(70, 3));
        expect(rawBounds.top, inInclusiveRange(695, 710));
        expect(rawBounds.bottom, inInclusiveRange(710, 725));
        final adapter = PdfCoordinateAdapter(geometry[index]);
        for (final rotation in PdfPageRotation.values) {
          final displayedPage = originalPage.rotatedTo(rotation);
          for (final scale in [0.5, 1.0, 2.5]) {
            final size = ui.Size(
              displayedPage.width * scale,
              displayedPage.height * scale,
            );
            final pageRect = ui.Rect.fromLTWH(0, 0, size.width, size.height);
            final box = adapter.effectiveBox;
            final offsets = first.quad.points
                .map(
                  (point) => PdfPoint(
                    point.x - box.left,
                    point.y - box.top,
                  ).toOffsetInDocument(page: displayedPage, pageRect: pageRect),
                )
                .toList();
            final restored = adapter.displayQuadToQuad(
              offsets,
              displayedPage,
              size,
            );
            for (var corner = 0; corner < 4; corner++) {
              expect(
                restored.points[corner].x,
                closeTo(first.quad.points[corner].x, .000001),
              );
              expect(
                restored.points[corner].y,
                closeTo(first.quad.points[corner].y, .000001),
              );
            }
          }
        }
      }
    } finally {
      await document.dispose();
    }
  });

  test('真实PDF矩形摘录编码PNG，阅读操作不修改原始字节', () async {
    final file = File('$fixtureRoot/native.pdf');
    final before = sha256.convert(await file.readAsBytes());
    final document = await PdfDocument.openFile(file.path);
    try {
      expect(await document.loadOutline(), hasLength(2));
      final png = await PdfReadEngine.captureRect(
        document.pages.first,
        const ui.Rect.fromLTRB(.08, .08, .8, .23),
      );
      expect(png.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
      final codec = await ui.instantiateImageCodec(png);
      try {
        final frame = await codec.getNextFrame();
        expect(frame.image.width, greaterThan(300));
        expect(frame.image.height, greaterThan(100));
        final pixels = await frame.image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        expect(
          pixels!.buffer.asUint8List().where((value) => value < 100).length,
          greaterThan(100),
        );
        frame.image.dispose();
      } finally {
        codec.dispose();
      }
      document.pages = document.pages
          .map((page) => page.rotatedTo(PdfPageRotation.values[1]))
          .toList();
    } finally {
      await document.dispose();
    }
    expect(sha256.convert(await file.readAsBytes()), before);
  });

  test('真实PDF跨页选区正向和反向均分段保存，文本范围不跨页', () async {
    final document = await PdfDocument.openFile('$fixtureRoot/native.pdf');
    try {
      final geometry = await PdfReadEngine.loadGeometry(
        document,
        filePath: '$fixtureRoot/native.pdf',
      );
      final layers = <int, PdfSelectableText>{};
      for (var index = 0; index < 2; index++) {
        final draft = await PdfReadEngine.extractNativeText(
          revisionId: 'fixture',
          page: document.pages[index],
          geometry: geometry[index],
        );
        layers[index] = PdfSelectableText(
          'layer-$index',
          draft.text,
          draft.fragments,
        );
      }
      final first = layers[0]!;
      final second = layers[1]!;
      final a = PdfSelectionPoint(
        0,
        first.fragments[2].start,
        first.fragments[2].start + 1,
      );
      final b = PdfSelectionPoint(
        1,
        second.fragments[8].start,
        second.fragments[8].start + 1,
      );
      for (final points in [
        [a, b],
        [b, a],
      ]) {
        final anchors = selectTextAcrossPages(
          revisionId: 'fixture',
          a: points[0],
          b: points[1],
          layerForPage: (index) => layers[index],
        );
        expect(anchors, hasLength(2));
        expect(anchors[0].pageIndex, 0);
        expect(anchors[1].pageIndex, 1);
        expect(anchors[0].textLayerId, 'layer-0');
        expect(anchors[1].textLayerId, 'layer-1');
        expect(anchors[0].textStart, a.start);
        expect(anchors[0].textEnd, first.text.length);
        expect(anchors[1].textStart, 0);
        expect(anchors[1].textEnd, b.end);
        expect(anchors[0].context, first.text.substring(a.start));
        expect(anchors[1].context, second.text.substring(0, b.end));
        expect(anchors.every((anchor) => anchor.quads.isNotEmpty), isTrue);
      }
    } finally {
      await document.dispose();
    }
  });
}
