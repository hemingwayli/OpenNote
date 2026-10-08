part of 'open_note_repository.dart';

extension EpubDocumentCommands on OpenNoteRepository {
  /// EPUB 导入不打开浏览器；元数据和原件在同一仓储事务中绑定。
  Future<ManagedDocument> importEpub({
    required String projectId,
    required String filePath,
    String? title,
    EpubPublication? publication,
  }) async {
    final parsed = publication ?? await EpubPublication.open(filePath);
    return _mutate('导入 EPUB', (w) async {
      await _require('projects', projectId, active: true);
      final resource = await _importResource(w, File(filePath), 'epub', 'epub');
      if (resource.sha256 != parsed.contentHash) {
        _invalid('EPUB 在解析与复制之间发生变化，请重新导入。');
      }
      final documentId = _id(), revisionId = _id();
      final row = <String, Object?>{
        'id': documentId,
        'project_id': projectId,
        'title': _title(title ?? parsed.title),
        'active_revision_id': revisionId,
        'deleted_at': null,
      };
      await w.put('documents', row);
      await w.put('revisions', {
        'id': revisionId,
        'document_id': documentId,
        'resource_id': resource.id,
        'content_hash': resource.sha256,
        'page_count': 0,
        'geometry': '[]',
        'format': 'epub',
        'metadata_json': encodeJson(parsed.metadata()),
      });
      for (final section in parsed.sections) {
        await w.put('epub_sections', {
          'id': _id(),
          'revision_id': revisionId,
          'spine_index': section.index,
          'href': section.href,
          'title': section.title,
          'fixed_layout': section.fixedLayout ? 1 : 0,
          'text': null,
          'fragments': '[]',
          'engine_version': '',
        });
      }
        return _document({...row,'format':'epub'});
    }, recordUndo: false);
  }

  Future<List<int>> indexedEpubSections(String revisionId) => _exclusive(
    () async => (await _rows(
      'SELECT spine_index FROM epub_sections WHERE revision_id=? AND text IS NOT NULL ORDER BY spine_index',
      [revisionId],
    )).map((r) => r['spine_index'] as int).toList(),
  );

  Future<void> saveEpubSection(
    String revisionId,
    Map<String, dynamic> data, {
    required String sessionId,
  }) => _mutate(
    '保存 EPUB 正文索引',
    (w) async {
      _checkSession(sessionId);
      final revision = await _require('revisions', revisionId);
      if (revision['format'] != 'epub') _invalid('正文索引格式不一致。');
      final rows = await _rows(
        'SELECT * FROM epub_sections WHERE revision_id=? AND spine_index=?',
        [revisionId, data['index']],
      );
      if (rows.length != 1 ||
          rows.single['href'] != data['href'] ||
          data['text'] is! String ||
          data['fragments'] is! List) {
        _invalid('EPUB 索引章节或内容不一致。');
      }
      final text = data['text'] as String;
      final fragments = List<Map<String, dynamic>>.from(
        (data['fragments'] as List).map(
          (v) => Map<String, dynamic>.from(v as Map),
        ),
      );
      _validateEpubFragments(text, fragments);
      await w.put('epub_sections', {
        ...rows.single,
        'text': text,
        'fragments': encodeJson(fragments),
        'engine_version': 'epubjs-0.3.93-index-v1',
      });
    },
    recordUndo: false,
    invalidateRedo: false,
    notifyChanges: false,
  );

  Future<void> saveEpubPosition(
    ReadingPosition position, {
    required String sessionId,
  }) => _mutate(
    '保存 EPUB 阅读位置',
    (w) async {
      _checkSession(sessionId);
      final revision = await _require('revisions', position.revisionId);
      if (position.epubLocator == null) _invalid('EPUB 阅读位置缺少 CFI。');
      await _validateEpubLocator(revision, position.epubLocator!);
      EpubReadingSettings.fromJson(
        Map<String, dynamic>.from(position.settings.toJson()),
      );
      await w.put('reading_positions', {
        'id': position.revisionId,
        'page_index': null,
        'offset': 0.0,
        'locator_json': position.epubLocator!.encode(),
        'settings_json': encodeJson(position.settings.toJson()),
      });
    },
    recordUndo: false,
    invalidateRedo: false,
    notifyChanges: false,
  );

  Future<void> _validateEpubLocator(_Row revision, EpubLocator locator) async {
    EpubLocator.fromJson(Map<String, dynamic>.from(locator.toJson()));
    if (revision['format'] != 'epub' ||
        (await _rows(
          'SELECT id FROM epub_sections WHERE revision_id=? AND href=?',
          [revision['id'], locator.href],
        )).isEmpty) {
      _invalid('EPUB 定位不属于此文档版本。');
    }
  }

  Future<void> saveEpubImageOcr({
    required String revisionId,
    required EpubLocator locator,
    required List<int> image,
    required String text,
    required Map<String, dynamic> result,
    required String engineVersion,
    required String sessionId,
  }) => _mutate(
    '保存 EPUB 图片识别',
    (w) async {
      _checkSession(sessionId);
      final revision = await _require('revisions', revisionId);
      await _validateEpubLocator(revision, locator);
      if (image.isEmpty || engineVersion.isEmpty) _invalid('图片识别结果缺少原图或引擎身份。');
      final temporary = File(p.join(libraryPath, 'pending', '${_id()}.png'));
      await temporary.parent.create(recursive: true);
      try {
        await temporary.writeAsBytes(image, flush: true);
        final resource = await _importResource(w, temporary, 'image', 'png');
        await w.put('epub_image_ocr', {
          'id': _id(),
          'revision_id': revisionId,
          'image_resource_id': resource.id,
          'locator_json': locator.encode(),
          'text': text,
          'result_json': encodeJson(result),
          'engine_version': engineVersion,
          'created_at': _now(),
        });
      } finally {
        if (await temporary.exists()) await temporary.delete();
      }
    },
    recordUndo: false,
    invalidateRedo: false,
  );
}

void _validateEpubFragments(String text, List<Map<String, dynamic>> fragments) {
  var cursor = 0;
  for (final fragment in fragments) {
    final start = fragment['start'],
        length = fragment['length'],
        cfi = fragment['cfi'];
    if (start is! int ||
        length is! int ||
        start != cursor ||
        length <= 0 ||
        start + length > text.length ||
        cfi is! String ||
        !isEpubCfi(cfi)) {
      _invalid('EPUB 正文与来源映射无效。');
    }
    cursor = start + length;
  }
  if (cursor != text.length) _invalid('EPUB 正文来源映射不完整。');
}

/// 将两个文本节点的 CFI 点合成为合法范围，不依赖屏幕排版。
String _epubRangeCfi(String from, int start, String to, int end) {
  return epubTextRangeCfi(from, start, to, end);
}
