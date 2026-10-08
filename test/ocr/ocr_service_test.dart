import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'package:opennote/engines/ocr/ocr_model_integrity.dart';
import 'package:opennote/engines/ocr/ocr_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final root = Directory.current.path;
  final library = '$root/native/build/Release/opennote_ocr.dll';
  final models = '$root/assets/ocr/models/PP-OCRv6_small';
  late NativeOcrService service;
  late ui.Image image;

  setUpAll(() async {
    if (!Platform.isWindows) return;
    service = await NativeOcrService.create(
      libraryPath: library,
      modelDirectory: models,
    );
    final codec = await ui.instantiateImageCodec(
      await File('test/ocr/fixtures/bilingual.png').readAsBytes(),
    );
    image = (await codec.getNextFrame()).image;
    codec.dispose();
  });
  tearDownAll(() async {
    if (!Platform.isWindows) return;
    image.dispose();
    await service.dispose();
    await service.dispose();
  });

  test('Windows FFI isolate produces bilingual text and honest input-space geometry', () async {
    final pixels = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final result = await service.recognize(
      pixels!.buffer.asUint8List(),
      width: image.width,
      height: image.height,
      stride: image.width * 4,
    );
    expect(result.model, 'PP-OCRv6_small');
    expect(result.coordinateSpace, 'inputImagePixelsTopLeft');
    expect(result.writingDirection, 'horizontalLtr');
    expect(result.lines, hasLength(6));
    expect(result.text, contains('离线阅读与知识整理'));
    expect(
      result.text,
      contains('OpenNote keeps your documents on this device.'),
    );
    expect(
      result.text,
      contains('Offline OCR works with Chinese and English books.'),
    );
    for (final line in result.lines) {
      expect(line.precision, 'detectedLine');
      expect(line.characters.map((c) => c.text).join(), line.text);
      for (final char in line.characters) {
        expect(char.precision, 'approximateCtcAlignment');
        for (final point in char.quad) {
          expect(point.x, inInclusiveRange(0, result.width.toDouble()));
          expect(point.y, inInclusiveRange(0, result.height.toDouble()));
        }
      }
    }
    expect(OcrResult.fromJson(result.toJson()).text, result.text);
  }, skip: !Platform.isWindows);

  test(
    '真实中英文扫描页自动识别主文方向，横排混排不被短竖注释误判',
    () async {
      for (final sample in [
        ('chinese-page20.jpg', 'verticalRtl'),
        ('austen-page11.jpg', 'horizontalLtr'),
        ('hillier-page110.jpg', 'horizontalLtr'),
      ]) {
        final codec = await ui.instantiateImageCodec(
          await File('test/ocr/fixtures/real-books/${sample.$1}').readAsBytes(),
        );
        final scan = (await codec.getNextFrame()).image;
        codec.dispose();
        try {
          final pixels = await scan.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          final result = await service.recognize(
            pixels!.buffer.asUint8List(),
            width: scan.width,
            height: scan.height,
            stride: scan.width * 4,
          );
          expect(result.writingDirection, sample.$2, reason: sample.$1);
          expect(
            OcrResult.fromJson(result.toJson()).writingDirection,
            sample.$2,
          );
          if (sample.$2 == 'verticalRtl') {
            final body = result.lines.where((line) {
              final x = line.quad.map((p) => p.x).reduce((a, b) => a + b) / 4;
              final y = line.quad.map((p) => p.y).reduce((a, b) => a + b) / 4;
              return x >= 918 && x <= 1170 && y >= 350 && y <= 1810;
            }).toList();
            expect(body, hasLength(3));
            expect(body[0].text, startsWith('十一征'));
            expect(body[1].text, contains('五興五衰'));
            expect(body[2].text, startsWith('復奉之歸於亳'));
            expect(
              result.directionDetection['verticalVotes'],
              greaterThanOrEqualTo(3),
            );
          }
        } finally {
          scan.dispose();
        }
      }
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('固定模型包拒绝模型配置改字节及伪造manifest哈希', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'opennote-ocr-integrity-',
    );
    try {
      for (final relative in ['manifest.json', ...ocrPinnedModelFiles.keys]) {
        final target = File('${temporary.path}/$relative');
        await target.parent.create(recursive: true);
        await File('$models/$relative').copy(target.path);
      }
      final configuration = File('${temporary.path}/rec/inference.yml');
      final bytes = await configuration.readAsBytes();
      bytes[bytes.length - 1] ^= 1;
      await configuration.writeAsBytes(bytes, flush: true);
      await expectLater(
        NativeOcrService.create(
          libraryPath: library,
          modelDirectory: temporary.path,
        ),
        throwsA(
          isA<OcrException>().having(
            (e) => e.message,
            'message',
            contains('SHA-256 mismatch: rec/inference.yml'),
          ),
        ),
      );
      final manifestFile = File('${temporary.path}/manifest.json');
      final manifest = jsonDecode(
        await manifestFile.readAsString(encoding: utf8),
      ) as Map<String, dynamic>;
      for (final entry in manifest['files'] as List) {
        if (entry['path'] == 'rec/inference.yml') {
          entry['sha256'] = sha256.convert(bytes).toString();
        }
      }
      await manifestFile.writeAsString(jsonEncode(manifest), encoding: utf8);
      await expectLater(
        NativeOcrService.create(
          libraryPath: library,
          modelDirectory: temporary.path,
        ),
        throwsA(
          isA<OcrException>().having(
            (e) => e.message,
            'message',
            contains('not the pinned package: rec/inference.yml'),
          ),
        ),
      );
    } finally {
      await temporary.delete(recursive: true);
    }
  }, skip: !Platform.isWindows);

  test(
    'native cancellation and service reuse keep buffer lifetime safe',
    () async {
      final pixels = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final operation = service.recognize(
        pixels!.buffer.asUint8List(),
        width: image.width,
        height: image.height,
        stride: image.width * 4,
      );
      final cancelled = expectLater(
        operation,
        throwsA(isA<OcrCancelledException>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));
      service.cancel();
      await cancelled;
      final result = await service.recognize(
        pixels.buffer.asUint8List(),
        width: image.width,
        height: image.height,
        stride: image.width * 4,
      );
      expect(result.lines, hasLength(6));
    },
    skip: !Platform.isWindows,
  );

  test(
    'invalid buffers are rejected before passing them to native code',
    () async {
      final pixels = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      await expectLater(
        service.recognize(
          pixels!.buffer.asUint8List(),
          width: image.width,
          height: image.height,
          stride: 4,
        ),
        throwsArgumentError,
      );
    },
    skip: !Platform.isWindows,
  );
}
