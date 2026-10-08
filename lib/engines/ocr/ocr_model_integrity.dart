import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

const ocrProcessingVersion = 'opennote-ppocrv6-small-cpu-v2';

/// 与已核验官方归档及派生字典绑定，不能信任用户可写的 manifest 自报新哈希。
const ocrPinnedModelFiles = <String, (int, String)>{
  'det/inference.onnx': (
    9880512,
    'd73e0058b7a8086bbd57f3d10b8bcd4ff95363f67e06e2762b5e814fe9c9410e',
  ),
  'det/inference.yml': (
    885,
    '193f435274bf9f0b5f71a929bbfbcf148282df7e633b34e7c373e8f44741b516',
  ),
  'rec/inference.onnx': (
    21159378,
    '5435fd747c9e0efe15a96d0b378d5bd157e9492ed8fd80edf08f30d02fa24634',
  ),
  'rec/inference.yml': (
    150579,
    'ab078671bb49f06228eadccd34f1bb501e157f7a047095ffb943ba81512c77d1',
  ),
  'characters.txt': (
    74949,
    'd051391881962ec266c4b4ee7b6a493fa2aeabaa2cd9ee369148cf3f6980af99',
  ),
};

/// 服务 create 的后台 isolate 调用一次，流式校验不会在 UI 线程读取模型大文件。
Future<void> verifyOcrModelPackage(String directory) async {
  final manifestFile = File(path.join(directory, 'manifest.json'));
  if (await manifestFile.length() > 256 * 1024) {
    throw const FormatException('OCR manifest exceeds the supported size');
  }
  final manifest = jsonDecode(
    await manifestFile.readAsString(encoding: utf8),
  ) as Map<String, dynamic>;
  if (manifest['formatVersion'] != 1 ||
      manifest['model'] != 'PP-OCRv6_small' ||
      manifest['processingVersion'] != ocrProcessingVersion ||
      manifest['backend'] != 'onnxruntime-cpu' ||
      manifest['onnxruntime'] != '1.21.0') {
    throw const FormatException(
      'OCR manifest does not describe the pinned package',
    );
  }
  final entries = manifest['files'] as List;
  if (entries.length != ocrPinnedModelFiles.length) {
    throw const FormatException(
      'OCR manifest file set differs from the pinned package',
    );
  }
  final seen = <String>{};
  for (final entry in entries) {
    final name = entry['path'] as String;
    final expected = ocrPinnedModelFiles[name];
    if (expected == null ||
        !seen.add(name) ||
        entry['size'] != expected.$1 ||
        entry['sha256'] != expected.$2) {
      throw FormatException(
        'OCR manifest hash is not the pinned package: $name',
      );
    }
  }
  for (final entry in ocrPinnedModelFiles.entries) {
    final file = File(path.joinAll([directory, ...entry.key.split('/')]));
    if (await file.length() != entry.value.$1) {
      throw FormatException('OCR model file size mismatch: ${entry.key}');
    }
    final digest = await sha256.bind(file.openRead()).first;
    if (digest.toString() != entry.value.$2) {
      throw FormatException('OCR model file SHA-256 mismatch: ${entry.key}');
    }
  }
}
