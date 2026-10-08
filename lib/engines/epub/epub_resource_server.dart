import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';

import 'epub_publication.dart';

/// 一个阅读会话的本地资源服务；只监听回环地址，路径必须命中原始资源清单。
class EpubResourceServer {
  EpubResourceServer._(
    this._server,
    this.publication,
    this.token,
    this._assets,
  );
  final HttpServer _server;
  final EpubPublication publication;
  final String token;
  final Map<String, List<int>> _assets;
  Future<void>? _closing;
  String get origin => 'http://127.0.0.1:${_server.port}';
  String get baseUrl => '$origin/$token';
  String get readerUrl => '$baseUrl/app/reader.html';
  String get packageUrl => '$baseUrl/book/${publication.packagePath}';

  static Future<EpubResourceServer> start(EpubPublication publication) async {
    final assets = <String, List<int>>{};
    for (final name in [
      'reader.html',
      'reader.js',
      'epub.min.js',
      'jszip.min.js',
    ]) {
      final data = await rootBundle.load('assets/epub/$name');
      assets[name] = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
    }
    // 书籍样式使用应用已分发的字体，避免依赖用户安装。
    final font = await rootBundle.load(
      'assets/fonts/source-han-sans/SourceHanSansCN-Regular.otf',
    );
    assets['reading-font.otf'] = font.buffer.asUint8List(
      font.offsetInBytes,
      font.lengthInBytes,
    );
    final random = Random.secure();
    final token = base64Url
        .encode(List.generate(24, (_) => random.nextInt(256)))
        .replaceAll('=', '');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final result = EpubResourceServer._(server, publication, token, assets);
    server.listen(result._serve);
    return result;
  }

  void _serve(HttpRequest request) {
    final path = request.uri.path;
    final appPrefix = '/$token/app/';
    final bookPrefix = '/$token/book/';
    final List<int>? data;
    final String name;
    if (request.method != 'GET' && request.method != 'HEAD') {
      request.response.statusCode = HttpStatus.methodNotAllowed;
      unawaited(request.response.close());
      return;
    }
    if (path.startsWith(appPrefix)) {
      name = path.substring(appPrefix.length);
      data = _assets[name];
    } else if (path.startsWith(bookPrefix)) {
      name = path.substring(bookPrefix.length);
      data = publication.resources[name];
    } else {
      name = '';
      data = null;
    }
    final response = request.response;
    response.headers.set('Cache-Control', 'no-store');
    response.headers.set('X-Content-Type-Options', 'nosniff');
    response.headers.set(
      'Content-Security-Policy',
      "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; "
          "img-src 'self' data: blob:; font-src 'self' data: blob:; "
          "connect-src 'self'; frame-src 'self' blob:; media-src 'none'; object-src 'none'; base-uri 'self'",
    );
    if (data == null) {
      response.statusCode = HttpStatus.notFound;
    } else {
      response.headers.set('Content-Type', _contentType(name));
      response.contentLength = data.length;
      if (request.method != 'HEAD') response.add(data);
    }
    unawaited(response.close().catchError((Object _) {}));
  }

  Future<void> close() => _closing ??= _server.close(force: true).then((_) {});
}

String _contentType(String path) {
  final extension = path.split('.').last.toLowerCase();
  return switch (extension) {
    'html' || 'htm' => 'text/html; charset=utf-8',
    'xhtml' => 'application/xhtml+xml; charset=utf-8',
    'opf' || 'ncx' || 'xml' => 'application/xml; charset=utf-8',
    'js' => 'application/javascript; charset=utf-8',
    'css' => 'text/css; charset=utf-8',
    'svg' => 'image/svg+xml',
    'png' => 'image/png',
    'jpg' || 'jpeg' => 'image/jpeg',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'otf' => 'font/otf',
    'ttf' => 'font/ttf',
    'woff' => 'font/woff',
    'woff2' => 'font/woff2',
    _ => 'application/octet-stream',
  };
}
