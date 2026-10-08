import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'ocr_result.dart';
import 'ocr_model_integrity.dart';
export 'ocr_result.dart';
export 'ocr_model_integrity.dart' show ocrProcessingVersion;

class OcrException implements Exception {
  const OcrException(this.message, {this.code = 3});
  final String message;
  final int code;
  @override
  String toString() => 'OcrException($code): $message';
}

class OcrCancelledException extends OcrException {
  const OcrCancelledException() : super('OCR 已取消', code: 1);
}

enum OcrPixelFormat { rgba, bgra }

/// 一个服务按顺序识别页面；图像转换、ONNX 推理与 JSON 处理在工作 isolate 完成。
/// cancel 是唯一允许从 UI 线程调用的原生入口，且不执行推理。
class NativeOcrService {
  NativeOcrService._(this._address, this.libraryPath)
    : _bindings = _Bindings(libraryPath);
  final int _address;
  final String libraryPath;
  final _Bindings _bindings;
  Future<OcrResult>? _active;
  Future<void>? _disposal;
  bool _disposed = false;
  int _cancelGeneration = 0;

  static Future<NativeOcrService> create({
    String? libraryPath,
    String? modelDirectory,
    int threads = 2,
  }) async {
    if (!Platform.isWindows) {
      throw const OcrException('首版 OCR 运行库仅支持 Windows x64');
    }
    if (threads < 1 || threads > 8) {
      throw ArgumentError.value(threads, 'threads', 'Must be between 1 and 8');
    }
    final separator = Platform.pathSeparator;
    final executableDirectory = File(Platform.resolvedExecutable).parent.path;
    final dll =
        libraryPath ?? '$executableDirectory${separator}opennote_ocr.dll';
    final models =
        modelDirectory ?? '$executableDirectory${separator}data${separator}ocr';
    final address = await Isolate.run(
      () => _createWorker(dll, models, threads),
    );
    try {
      return NativeOcrService._(address, dll);
    } catch (_) {
      await Isolate.run(() => _destroyWorker(dll, address));
      rethrow;
    }
  }

  Future<OcrResult> recognize(
    Uint8List rgba, {
    required int width,
    required int height,
    required int stride,
    OcrPixelFormat pixelFormat = OcrPixelFormat.rgba,
  }) async {
    if (_disposed) throw StateError('OCR service has been disposed');
    if (_active != null) {
      throw StateError('OCR service already has an active page');
    }
    if (width <= 0 ||
        height <= 0 ||
        width > 16384 ||
        height > 16384 ||
        stride < width * 4 ||
        rgba.length < stride * (height - 1) + width * 4 ||
        width * height > 100000000) {
      throw ArgumentError('Invalid RGBA dimensions, stride or buffer length');
    }
    final generation = _cancelGeneration;
    final address = _address;
    final dll = libraryPath;
    final pixels = TransferableTypedData.fromList([rgba]);
    final bgra = pixelFormat == OcrPixelFormat.bgra;
    final operation = Isolate.run(
      () => _recognizeWorker(dll, address, pixels, width, height, stride, bgra),
    );
    _active = operation;
    try {
      final result = await operation;
      if (generation != _cancelGeneration || _disposed) {
        throw const OcrCancelledException();
      }
      return result;
    } finally {
      _active = null;
    }
  }

  void cancel() {
    if (_disposed || _active == null) return;
    _cancelGeneration++;
    _bindings.cancel(Pointer<Void>.fromAddress(_address));
  }

  Future<void> dispose() => _disposal ??= _dispose();
  Future<void> _dispose() async {
    final current = _active;
    cancel();
    _disposed = true;
    if (current != null) {
      try {
        await current;
      } catch (_) {
        /* 销毁等待当前调用退出，不覆盖识别方异常。 */
      }
    }
    final dll = libraryPath;
    final address = _address;
    await Isolate.run(() => _destroyWorker(dll, address));
  }
}

typedef _CreateNative = Int32 Function(
  Pointer<Utf8>,
  Int32,
  Pointer<Pointer<Void>>,
  Pointer<Pointer<Utf8>>,
);
typedef _CreateDart = int Function(
  Pointer<Utf8>,
  int,
  Pointer<Pointer<Void>>,
  Pointer<Pointer<Utf8>>,
);
typedef _RecognizeNative = Int32 Function(
  Pointer<Void>,
  Pointer<Uint8>,
  UintPtr,
  Int32,
  Int32,
  Int32,
  Pointer<Pointer<Utf8>>,
  Pointer<Pointer<Utf8>>,
);
typedef _RecognizeDart = int Function(
  Pointer<Void>,
  Pointer<Uint8>,
  int,
  int,
  int,
  int,
  Pointer<Pointer<Utf8>>,
  Pointer<Pointer<Utf8>>,
);
typedef _PointerNative = Void Function(Pointer<Void>);
typedef _PointerDart = void Function(Pointer<Void>);

class _Bindings {
  _Bindings(String path) {
    final library = DynamicLibrary.open(path);
    final abi = library.lookupFunction<Int32 Function(), int Function()>(
      'onocr_abi_version',
    )();
    if (abi != 1) throw OcrException('Unsupported native OCR ABI $abi');
    create = library.lookupFunction<_CreateNative, _CreateDart>('onocr_create');
    recognize = library.lookupFunction<_RecognizeNative, _RecognizeDart>(
      'onocr_recognize',
    );
    cancel = library.lookupFunction<_PointerNative, _PointerDart>(
      'onocr_cancel',
    );
    free = library.lookupFunction<_PointerNative, _PointerDart>('onocr_free');
    destroy = library.lookupFunction<_PointerNative, _PointerDart>(
      'onocr_destroy',
    );
  }
  late final _CreateDart create;
  late final _RecognizeDart recognize;
  late final _PointerDart cancel, free, destroy;
}

Future<int> _createWorker(String dll, String models, int threads) async {
  try {
    await verifyOcrModelPackage(models);
  } catch (error) {
    throw OcrException('离线 OCR 模型包完整性校验失败：$error');
  }
  final binding = _Bindings(dll);
  final path = models.toNativeUtf8();
  final handle = calloc<Pointer<Void>>();
  final error = calloc<Pointer<Utf8>>();
  try {
    final status = binding.create(path, threads, handle, error);
    _checkStatus(status, error.value);
    return handle.value.address;
  } finally {
    binding.free(error.value.cast());
    calloc.free(error);
    calloc.free(handle);
    calloc.free(path);
  }
}

OcrResult _recognizeWorker(
  String dll,
  int address,
  TransferableTypedData pixels,
  int width,
  int height,
  int stride,
  bool bgra,
) {
  final binding = _Bindings(dll);
  final bytes = pixels.materialize().asUint8List();
  final buffer = calloc<Uint8>(bytes.length);
  final result = calloc<Pointer<Utf8>>();
  final error = calloc<Pointer<Utf8>>();
  try {
    buffer.asTypedList(bytes.length).setAll(0, bytes);
    if (bgra) {
      final rgba = buffer.asTypedList(bytes.length);
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < width; x++) {
          final offset = y * stride + x * 4;
          final blue = rgba[offset];
          rgba[offset] = rgba[offset + 2];
          rgba[offset + 2] = blue;
        }
      }
    }
    final status = binding.recognize(
      Pointer<Void>.fromAddress(address),
      buffer,
      bytes.length,
      width,
      height,
      stride,
      result,
      error,
    );
    _checkStatus(status, error.value);
    if (result.value == nullptr) {
      throw const OcrException(
        'Native OCR returned an empty result allocation',
      );
    }
    return OcrResult.fromJson(
      jsonDecode(result.value.toDartString()) as Map<String, dynamic>,
    );
  } finally {
    binding.free(result.value.cast());
    binding.free(error.value.cast());
    calloc.free(result);
    calloc.free(error);
    calloc.free(buffer);
  }
}

void _checkStatus(int status, Pointer<Utf8> error) {
  if (status == 0) return;
  if (status == 1) throw const OcrCancelledException();
  throw OcrException(
    error == nullptr ? 'Native OCR failed' : error.toDartString(),
    code: status,
  );
}

void _destroyWorker(String dll, int address) =>
    _Bindings(dll).destroy(Pointer<Void>.fromAddress(address));
