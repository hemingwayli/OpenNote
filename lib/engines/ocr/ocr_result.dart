/// 原生 OCR 返回输入图像坐标；持久化前必须由 PDF 适配层映射至页坐标。
class OcrPoint {
  const OcrPoint(this.x, this.y);
  final double x;
  final double y;
  List<double> toJson() => [x, y];
}

class OcrCharacter {
  const OcrCharacter({
    required this.text,
    required this.confidence,
    required this.quad,
    required this.precision,
  });
  final String text;
  final double confidence;
  final List<OcrPoint> quad;

  /// CTC 对齐是近似定位，不能宣称精确字符框。
  final String precision;
  factory OcrCharacter.fromJson(Map<String, dynamic> json) => OcrCharacter(
    text: json['text'] as String,
    confidence: (json['confidence'] as num).toDouble(),
    quad: _readQuad(json['quad']),
    precision: json['precision'] as String,
  );
  Map<String, Object> toJson() => {
    'text': text,
    'confidence': confidence,
    'quad': quad.map((p) => p.toJson()).toList(),
    'precision': precision,
  };
}

class OcrLine {
  const OcrLine({
    required this.order,
    required this.text,
    required this.confidence,
    required this.detectionConfidence,
    required this.quad,
    required this.precision,
    required this.characters,
  });
  final int order;
  final String text;
  final double confidence;
  final double detectionConfidence;
  final List<OcrPoint> quad;
  final String precision;
  final List<OcrCharacter> characters;
  factory OcrLine.fromJson(Map<String, dynamic> json) => OcrLine(
    order: json['order'] as int,
    text: json['text'] as String,
    confidence: (json['confidence'] as num).toDouble(),
    detectionConfidence: (json['detectionConfidence'] as num).toDouble(),
    quad: _readQuad(json['quad']),
    precision: json['precision'] as String,
    characters: List.unmodifiable(
      (json['characters'] as List).map(
        (value) =>
            OcrCharacter.fromJson(Map<String, dynamic>.from(value as Map)),
      ),
    ),
  );
  Map<String, Object> toJson() => {
    'order': order,
    'text': text,
    'confidence': confidence,
    'detectionConfidence': detectionConfidence,
    'quad': quad.map((p) => p.toJson()).toList(),
    'precision': precision,
    'characters': characters.map((c) => c.toJson()).toList(),
  };
}

class OcrResult {
  const OcrResult({
    required this.width,
    required this.height,
    required this.elapsedMs,
    required this.model,
    required this.engine,
    required this.lines,
    this.readingOrder = 'basicRows',
    this.writingDirection = 'horizontalLtr',
    this.directionDetection = const {},
  });
  final int width;
  final int height;
  final int elapsedMs;
  final String model;
  final String engine;
  final List<OcrLine> lines;
  final String readingOrder;
  final String writingDirection;
  final Map<String, dynamic> directionDetection;
  String get text => lines.map((line) => line.text).join('\n');
  String get coordinateSpace => 'inputImagePixelsTopLeft';
  factory OcrResult.fromJson(Map<String, dynamic> json) {
    if (json['formatVersion'] != 1 ||
        json['coordinateSpace'] != 'inputImagePixelsTopLeft') {
      throw const FormatException(
        'Unsupported OCR result format or coordinates',
      );
    }
    return OcrResult(
      width: json['width'] as int,
      height: json['height'] as int,
      elapsedMs: json['elapsedMs'] as int,
      model: json['model'] as String,
      engine: json['engine'] as String,
      readingOrder: json['readingOrder'] as String? ?? 'basicRows',
      writingDirection: json['writingDirection'] as String? ?? 'horizontalLtr',
      directionDetection: Map.unmodifiable(
        Map<String, dynamic>.from(json['directionDetection'] as Map? ?? {}),
      ),
      lines: List.unmodifiable(
        (json['lines'] as List).map(
          (value) => OcrLine.fromJson(Map<String, dynamic>.from(value as Map)),
        ),
      ),
    );
  }
  Map<String, Object> toJson() => {
    'formatVersion': 1,
    'width': width,
    'height': height,
    'elapsedMs': elapsedMs,
    'model': model,
    'engine': engine,
    'coordinateSpace': coordinateSpace,
    'readingOrder': readingOrder,
    'writingDirection': writingDirection,
    'directionDetection': directionDetection,
    'lines': lines.map((line) => line.toJson()).toList(),
  };
}

List<OcrPoint> _readQuad(dynamic value) {
  final points = (value as List)
      .map((p) => OcrPoint((p[0] as num).toDouble(), (p[1] as num).toDouble()))
      .toList(growable: false);
  if (points.length != 4 || points.any((p) => !p.x.isFinite || !p.y.isFinite)) {
    throw const FormatException('Invalid OCR quadrilateral');
  }
  return List.unmodifiable(points);
}
