import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:pdfrx/pdfrx.dart' show PdfDocument;

import '../data/open_note_repository.dart';
import '../domain/models.dart';
import '../engines/pdf/pdf_read_engine.dart';
import '../ui/reader/reader_contract.dart';

/// 工作区只维护选择和读取结果，所有持久修改仍通过仓储业务命令。
class WorkspaceController extends ChangeNotifier {
  WorkspaceController(this.repository)
    : _selectionSession = repository.sessionId {
    _subscription = repository.changes.listen((_) => _scheduleRefresh());
  }

  final OpenNoteRepository repository;
  late final StreamSubscription<int> _subscription;
  Timer? _refreshTimer;
  Future<void>? _latestRefresh;
  int _activeRefreshReads = 0;
  bool _backgroundRefreshPending = false;
  bool _disposed = false;
  bool _openingProject = false;
  bool _refreshPending = false;
  int _generation = 0;
  int _selectionGeneration = 0;
  int _documentGeneration = 0;
  int _mapGeneration = 0;
  String _selectionSession;
  final Set<String> _selectedNodeIds = {};
  String? _selectedNodeId;
  List<StudyProject> projects = [];
  List<ManagedDocument> documents = [];
  List<ManagedDocument> openedDocuments = [];
  List<MindMap> maps = [];
  List<NoteCard> cards = [];
  StudyProject? project;
  ManagedDocument? document;
  DocumentRevision? revision;
  String? documentPath;
  ReadingPosition? readingPosition;
  PdfReadingSettings pdfReadingSettings = const PdfReadingSettings();
  List<int> epubIndexedSections = const [];
  List<PageTextLayer> textLayers = [];
  List<AppAnnotation> annotations = [];
  MapSnapshot? map;
  String? selectedCardId;
  String status = '资料已保存';
  String? error;
  bool busy = false;

  /// 快照不能被控件修改，后续选择也不改变已捕获的批量操作目标。
  Set<String> get selectedNodeIds => Set.unmodifiable(_selectedNodeIds);

  String? get selectedNodeId => _selectedNodeId;

  /// 保留单选赋值入口；清空或替换主选时同步整个临时集合。
  set selectedNodeId(String? value) {
    _selectedNodeIds.clear();
    _selectedNodeId = value;
    if (value != null) _selectedNodeIds.add(value);
    selectedCardId = map?.nodes
        .where((node) => node.id == value)
        .firstOrNull
        ?.cardId;
  }

  void _clearSelection() {
    _selectedNodeIds.clear();
    _selectedNodeId = null;
    selectedCardId = null;
    _selectionSession = repository.sessionId;
  }

  NoteCard? get selectedCard => selectedCardId == null
      ? null
      : cards.where((c) => c.id == selectedCardId).firstOrNull;

  void reportError(Object value, [StackTrace? trace]) {
    if (_disposed) return;
    error = value.toString();
    status = '操作未完成';
    notifyListeners();
  }

  void clearError() {
    error = null;
    notifyListeners();
  }

  Future<void> initialize({String? projectId}) async {
    projects = await repository.listProjects();
    if (projectId != null) {
      final target = projects.where((p) => p.id == projectId).firstOrNull;
      if (target == null) throw StateError('项目已不存在或已移入回收站');
      await selectProject(target);
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> refresh({bool openingProject = false}) {
    if (_disposed) return Future.value();
    if (_openingProject && !openingProject) {
      _refreshPending = true;
      return Future.value();
    }
    // 显式刷新已覆盖待处理的仓储通知，避免重复读取抢占本次命令的结果。
    _refreshTimer?.cancel();
    _backgroundRefreshPending = false;
    _activeRefreshReads++;
    final reading = _readAndRelease();
    _latestRefresh = reading;
    return _awaitLatestRefresh(reading);
  }

  void _scheduleRefresh() {
    if (_disposed) return;
    _backgroundRefreshPending = true;
    _refreshTimer?.cancel();
    _refreshTimer = Timer(const Duration(milliseconds: 100), () {
      // OCR 等连续通知不抢占正在等待的保存；读完后补齐积累的变化。
      if (_activeRefreshReads > 0) return;
      _backgroundRefreshPending = false;
      unawaited(refresh().catchError(reportError));
    });
  }

  Future<void> _readAndRelease() async {
    try {
      await _readRefresh();
    } finally {
      _activeRefreshReads--;
      if (_activeRefreshReads == 0 && _backgroundRefreshPending) {
        _scheduleRefresh();
      }
    }
  }

  Future<void> _awaitLatestRefresh(Future<void> reading) async {
    while (true) {
      await reading;
      final latest = _latestRefresh;
      if (_disposed || latest == null || identical(latest, reading)) return;
      // 新读取可使旧读取失效，但不能让已等待的保存提前宣告界面刷新完成。
      // 这里只等待实际读取，不等待包装 Future，避免并发刷新相互等待。
      reading = latest;
    }
  }

  Future<void> _readRefresh() async {
    if (_selectionSession != repository.sessionId) _clearSelection();
    final generation = ++_generation;
    final selectionGeneration = _selectionGeneration;
    final documentGeneration = _documentGeneration;
    final mapGeneration = _mapGeneration;
    final session = repository.sessionId;
    final updatedProjects = await repository.listProjects();
    final currentProject = project;
    if (currentProject == null) {
      projects = updatedProjects;
      if (!_disposed) notifyListeners();
      return;
    }
    final exists = updatedProjects.any((p) => p.id == currentProject.id);
    if (!exists) {
      project = null;
      clearWorkspace();
      projects = updatedProjects;
      if (!_disposed) notifyListeners();
      return;
    }
    final updatedDocuments = await repository.listDocuments(currentProject.id);
    final updatedMaps = await repository.listMaps(currentProject.id);
    final updatedCards = await repository.listCards(currentProject.id);
    final currentMapId = updatedMaps.any((m) => m.id == map?.map.id)
        ? map!.map.id
        : updatedMaps.firstOrNull?.id;
    final updatedMap = currentMapId == null
        ? null
        : await repository.loadMap(currentMapId);
    final currentRevision = revision;
    final updatedLayers = currentRevision == null
        ? <PageTextLayer>[]
        : await repository.loadTextLayers(
            currentRevision.id,
            pageIndices: _visiblePages(
              currentRevision,
              readingPosition?.pageIndex ?? 0,
            ),
          );
    final updatedAnnotations = currentRevision == null
        ? <AppAnnotation>[]
        : await repository.listAnnotations(currentRevision.id);
    if (_disposed ||
        generation != _generation ||
        selectionGeneration != _selectionGeneration ||
        documentGeneration != _documentGeneration ||
        mapGeneration != _mapGeneration ||
        session != repository.sessionId) {
      return;
    }
    projects = updatedProjects;
    project = updatedProjects.firstWhere((p) => p.id == currentProject.id);
    documents = updatedDocuments;
    final documentsById = {
      for (final value in updatedDocuments) value.id: value,
    };
    // 已删除原文仍允许既有卡片回源；刷新标题时不丢掉已打开的历史来源。
    openedDocuments = [
      for (final value in openedDocuments) documentsById[value.id] ?? value,
    ];
    if (document != null) document = documentsById[document!.id] ?? document;
    maps = updatedMaps;
    cards = updatedCards;
    if (map?.map.id != updatedMap?.map.id) _clearSelection();
    map = updatedMap;
    textLayers = updatedLayers;
    annotations = updatedAnnotations;
    final nodesById = {
      for (final node in updatedMap?.nodes ?? <MapNode>[]) node.id: node,
    };
    // 折叠只影响可见行，仍有效的后代继续保留选择。
    _selectedNodeIds.removeWhere((id) => !nodesById.containsKey(id));
    if (!_selectedNodeIds.contains(_selectedNodeId)) {
      _selectedNodeId = _selectedNodeIds.lastOrNull;
    }
    if (_selectedNodeId != null) {
      selectedCardId = nodesById[_selectedNodeId]!.cardId;
    }
    if (!cards.any((c) => c.id == selectedCardId)) selectedCardId = null;
    status = '资料已保存';
    notifyListeners();
  }

  List<int> _visiblePages(DocumentRevision revision, int page) => [
    for (var index = page - 1; index <= page + 1; index++)
      if (index >= 0 && index < revision.pageCount) index,
  ];

  void clearWorkspace() {
    _generation++;
    _selectionGeneration++;
    _documentGeneration++;
    _mapGeneration++;
    documents = [];
    openedDocuments = [];
    maps = [];
    cards = [];
    document = null;
    revision = null;
    documentPath = null;
    readingPosition = null;
    pdfReadingSettings = const PdfReadingSettings();
    textLayers = [];
    annotations = [];
    map = null;
    _clearSelection();
  }

  Future<void> selectProject(StudyProject value) async {
    _openingProject = true;
    try {
      clearWorkspace();
      final selectionGeneration = _selectionGeneration;
      final session = repository.sessionId;
      project = value;
      // OCR 进度等仓储通知不能使首次资料查询失效，否则会把空标签覆盖到继续阅读记录。
      await refresh(openingProject: true);
      if (_disposed ||
          selectionGeneration != _selectionGeneration ||
          session != repository.sessionId) {
        return;
      }
      final resume = await repository.loadProjectResume(value.id);
      if (_disposed ||
          selectionGeneration != _selectionGeneration ||
          session != repository.sessionId) {
        return;
      }
      final byId = {for (final item in documents) item.id: item};
      openedDocuments = [
        for (final id in resume?.openedDocumentIds ?? <String>[])
          if (byId[id] != null) byId[id]!,
      ];
      final mapId = resume?.mapId;
      if (mapId != null && maps.any((m) => m.id == mapId)) {
        await selectMap(mapId);
      }
      final document =
          byId[resume?.activeDocumentId] ??
          openedDocuments.firstOrNull ??
          documents.firstOrNull;
      if (document != null) await openDocument(document);
      if (_disposed ||
          selectionGeneration != _selectionGeneration ||
          session != repository.sessionId) {
        return;
      }
      await persistResume(markOpened: true);
    } finally {
      _openingProject = false;
      if (_refreshPending && !_disposed) {
        _refreshPending = false;
        await refresh();
      }
    }
  }

  Future<void> persistResume({
    bool markOpened = false,
    String? successfullyReadDocumentId,
  }) async {
    final id = project?.id;
    if (id == null || _disposed) return;
    await repository.saveProjectResume(
      id,
      activeDocumentId: document?.id,
      mapId: map?.map.id,
      openedDocumentIds: openedDocuments.map((d) => d.id).toList(),
      markOpened: markOpened,
      successfullyReadDocumentId: successfullyReadDocumentId,
    );
  }

  Future<void> createProject(String title) async {
    final created = await repository.createProject(title);
    await selectProject(created);
  }

  Future<void> selectMap(String mapId) async {
    final generation = ++_mapGeneration;
    final selectionGeneration = _selectionGeneration;
    final session = repository.sessionId;
    final result = await repository.loadMap(mapId);
    if (_disposed ||
        generation != _mapGeneration ||
        selectionGeneration != _selectionGeneration ||
        session != repository.sessionId ||
        result.map.projectId != project?.id) {
      return;
    }
    map = result;
    _clearSelection();
    notifyListeners();
  }

  Future<void> openDocument(ManagedDocument value) async {
    if (value.projectId != project?.id) return;
    final generation = ++_documentGeneration;
    final selectionGeneration = _selectionGeneration;
    final session = repository.sessionId;
    final loadedRevision = await repository.getRevision(value.activeRevisionId);
    final path = await repository.resourcePath(loadedRevision.resourceId);
    final position = await repository.loadReadingPosition(loadedRevision.id);
    final pdfSettings = loadedRevision.format == DocumentFormat.pdf
        ? await repository.loadPdfReadingSettings(loadedRevision.id)
        : const PdfReadingSettings();
    final epubSections=loadedRevision.format==DocumentFormat.epub ? await repository.indexedEpubSections(loadedRevision.id) : <int>[];
    final layers = await repository.loadTextLayers(
      loadedRevision.id,
      pageIndices: _visiblePages(loadedRevision, position?.pageIndex ?? 0),
    );
    final marks = await repository.listAnnotations(loadedRevision.id);
    if (_disposed ||
        generation != _documentGeneration ||
        selectionGeneration != _selectionGeneration ||
        session != repository.sessionId ||
        value.projectId != project?.id) {
      return;
    }
    document = value;
    if (!openedDocuments.any((item) => item.id == value.id)) {
      openedDocuments = [...openedDocuments, value];
    } else {
      openedDocuments = [
        for (final item in openedDocuments) item.id == value.id ? value : item,
      ];
    }
    revision = loadedRevision;
    documentPath = path;
    readingPosition = position;
    pdfReadingSettings = pdfSettings;
    epubIndexedSections = epubSections;
    textLayers = layers;
    annotations = marks;
    notifyListeners();
  }

  /// 关闭只改变本次阅读工作区，资料、位置、摘录和后台索引仍由资料库保存。
  Future<void> closeDocumentTab(String documentId) async {
    final index = openedDocuments.indexWhere((item) => item.id == documentId);
    if (index < 0) return;
    openedDocuments = [...openedDocuments]..removeAt(index);
    if (document?.id != documentId) {
      notifyListeners();
      return;
    }
    if (openedDocuments.isNotEmpty) {
      final nextIndex = index.clamp(0, openedDocuments.length - 1);
      await openDocument(openedDocuments[nextIndex]);
      return;
    }
    _documentGeneration++;
    document = null;
    revision = null;
    documentPath = null;
    readingPosition = null;
    pdfReadingSettings = const PdfReadingSettings();
    textLayers = [];
    annotations = [];
    notifyListeners();
  }

  void reorderDocumentTabs(int oldIndex, int newIndex) {
    if (oldIndex < 0 ||
        oldIndex >= openedDocuments.length ||
        newIndex < 0 ||
        newIndex >= openedDocuments.length) {
      throw RangeError('文档标签顺序超出范围');
    }
    if (oldIndex == newIndex) return;
    final reordered = [...openedDocuments];
    final value = reordered.removeAt(oldIndex);
    reordered.insert(newIndex, value);
    openedDocuments = reordered;
    notifyListeners();
  }

  Future<ManagedDocument> importPdf(String filePath) => importDocument(filePath);

  Future<ManagedDocument> importDocument(String filePath) async {
    final selectedProject = project;
    final session = repository.sessionId;
    if (selectedProject == null) throw StateError('请先创建或选择学习项目');
    busy = true;
    status = '正在导入文档…';
    notifyListeners();
    try {
      final input=await File(filePath).open();
      final List<int> header;
      try {header=await input.read(1024);} finally {await input.close();}
      if(!latin1.decode(header).contains('%PDF-')) {
        final imported=await repository.importEpub(projectId:selectedProject.id,filePath:filePath);
        if(selectedProject.id==project?.id && session==repository.sessionId) {await refresh();await openDocument(imported);}
        return imported;
      }
      final geometry = await PdfReadEngine.loadSourceGeometry(filePath);
      final pdf = await PdfDocument.openFile(filePath);
      try {
        if (pdf.pages.length != geometry.length) {
          throw StateError('PDF 页数解析不一致');
        }
        final imported = await repository.importPdf(
          projectId: selectedProject.id,
          filePath: filePath,
          pageCount: pdf.pages.length,
          pageGeometry: geometry,
        );
        if (selectedProject.id == project?.id &&
            session == repository.sessionId) {
          await refresh();
          await openDocument(imported);
        }
        return imported;
      } finally {
        await pdf.dispose();
      }
    } finally {
      busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  void selectNode(MapNode value, {bool additive = false}) {
    if (_selectionSession != repository.sessionId) {
      _clearSelection();
      notifyListeners();
      return;
    }
    if (value.mapId != map?.map.id) return;
    final current = map?.nodes.where((node) => node.id == value.id).firstOrNull;
    if (current == null || current.mapId != value.mapId) return;
    if (!additive) {
      selectedNodeId = current.id;
    } else if (_selectedNodeIds.remove(current.id)) {
      if (_selectedNodeId == current.id) {
        _selectedNodeId = _selectedNodeIds.lastOrNull;
      }
    } else {
      _selectedNodeIds.add(current.id);
      _selectedNodeId = current.id;
    }
    selectedCardId = map?.nodes
        .where((node) => node.id == _selectedNodeId)
        .firstOrNull
        ?.cardId;
    notifyListeners();
  }

  void replaceNodeSelection(Set<String> ids, String? primary) {
    if (_selectionSession != repository.sessionId) return;
    final nodes = {for (final node in map?.nodes ?? <MapNode>[]) node.id: node};
    final valid = ids.where(nodes.containsKey).toSet();
    _selectedNodeIds
      ..clear()
      ..addAll(valid);
    _selectedNodeId = valid.contains(primary) ? primary : valid.lastOrNull;
    selectedCardId = nodes[_selectedNodeId]?.cardId;
    notifyListeners();
  }

  /// 仓储已提交的新节点可能早于被并发刷新取代的界面快照，不能按旧快照过滤身份。
  void selectInsertedNodes(List<MapNode> nodes) {
    if (_selectionSession != repository.sessionId ||
        nodes.any((node) => node.mapId != map?.map.id)) {
      return;
    }
    _selectedNodeIds
      ..clear()
      ..addAll(nodes.map((node) => node.id));
    _selectedNodeId = nodes.firstOrNull?.id;
    selectedCardId = nodes.firstOrNull?.cardId;
    notifyListeners();
  }

  void selectCard(NoteCard value) {
    if (_selectionSession != repository.sessionId) {
      _clearSelection();
      notifyListeners();
      return;
    }
    selectedNodeId = map?.nodes
        .where((n) => n.cardId == value.id)
        .firstOrNull
        ?.id;
    selectedCardId = value.id;
    notifyListeners();
  }

  Future<ExcerptResult> addTheme(
    String title, {
    required String? parentNodeId,
    double? x,
    double? y,
  }) => _createExcerpt(
    SelectedExcerpt(text: '', anchors: const []),
    title: title,
    parentNodeId: parentNodeId,
    x: x,
    y: y,
    appendBelowSiblings: true,
  );

  Future<void> addExcerpt(SelectedExcerpt excerpt, {String? title}) async {
    final parentNodeId = map?.nodes
        .where((node) => node.id == selectedNodeId)
        .firstOrNull
        ?.id;
    await _createExcerpt(excerpt, title: title, parentNodeId: parentNodeId);
  }

  /// 拖入使用明确落点和父级；空白落点不会回退到当前选中的卡片。
  Future<ExcerptResult> addExcerptAt(
    SelectedExcerpt excerpt, {
    required String mapId,
    required PdfPoint position,
    required String? parentNodeId,
    bool Function()? selectionIsCurrent,
  }) {
    if (map?.map.id != mapId) {
      throw StateError('目标脑图已切换，请重新拖入文字');
    }
    return _createExcerpt(
      excerpt,
      parentNodeId: parentNodeId,
      x: position.x,
      y: position.y,
      selectionIsCurrent: selectionIsCurrent,
    );
  }

  Future<ExcerptResult> _createExcerpt(
    SelectedExcerpt excerpt, {
    String? title,
    required String? parentNodeId,
    double? x,
    double? y,
    bool appendBelowSiblings = false,
    bool Function()? selectionIsCurrent,
  }) async {
    final selectedProject = project;
    final selectedMap = map;
    final selectionGeneration = _selectionGeneration;
    final mapGeneration = _mapGeneration;
    final session = repository.sessionId;
    if (selectedProject == null || selectedMap == null) {
      throw StateError('请先选择学习项目与脑图');
    }
    final parent = selectedMap.nodes
        .where((n) => n.id == parentNodeId)
        .firstOrNull;
    final siblings = selectedMap.nodes
        .where((n) => n.parentNodeId == parentNodeId)
        .toList();
    final defaultY = appendBelowSiblings
        ? siblings.isEmpty
              ? parent?.y ?? 80.0
              : siblings
                        .map((node) => node.y + node.height)
                        .reduce(
                          (first, second) => first > second ? first : second,
                        ) +
                    24
        : parent == null
        ? 80.0 + siblings.length * 150
        : parent.y + siblings.length * 140;
    final result = await repository.createExcerpt(
      ExcerptDraft(
        projectId: selectedProject.id,
        mapId: selectedMap.map.id,
        title:
            title ??
            (excerpt.text.trim().isEmpty
                ? '区域摘录'
                : String.fromCharCodes(
                    excerpt.text.trim().split('\n').first.runes.take(32),
                  )),
        text: excerpt.text,
        anchors: excerpt.anchors,
        imageBytes: excerpt.imageBytes,
        parentNodeId: parentNodeId,
        x: x ?? (parent == null ? 80 : parent.x + parent.width + 70),
        y: y ?? defaultY,
        createHighlight: excerpt.anchors.isNotEmpty,
      ),
    );
    await refresh();
    if (_disposed ||
        selectionGeneration != _selectionGeneration ||
        mapGeneration != _mapGeneration ||
        session != repository.sessionId ||
        selectionIsCurrent?.call() == false ||
        map?.map.id != selectedMap.map.id) {
      return result;
    }
    selectedNodeId = result.node.id;
    selectedCardId = result.card.id;
    notifyListeners();
    return result;
  }

  Future<void> saveNativeLayer(
    TextLayerDraft value,
    String capturedSession,
  ) async {
    if (value.text.trim().isEmpty) return;
    final existing = await repository.loadTextLayers(
      value.revisionId,
      pageIndices: [value.pageIndex],
    );
    if (existing.any(
      (layer) =>
          layer.source == TextLayerSource.nativePdf &&
          layer.text == value.text &&
          layer.engineVersion == value.engineVersion,
    )) {
      return;
    }
    await repository.saveTextLayer(value, sessionId: capturedSession);
  }

  Future<void> updatePdfReadingSettings(
    String revisionId,
    PdfReadingSettings value, {
    required String sessionId,
  }) async {
    if (_disposed ||
        repository.sessionId != sessionId ||
        revision?.id != revisionId ||
        revision?.format != DocumentFormat.pdf) {
      return;
    }
    pdfReadingSettings = value;
    await repository.savePdfReadingSettings(
      revisionId,
      value,
      sessionId: sessionId,
    );
  }

  Future<void> updateReadingPosition(ReadingPosition value) async {
    if (revision?.id != value.revisionId) return;
    final previous = readingPosition?.pageIndex;
    readingPosition = value;
    if(value.epubLocator != null) {
      await repository.saveEpubPosition(value,sessionId:repository.sessionId);
      return;
    }
    await repository.saveReadingPosition(
      value.revisionId,
      value.pageIndex,
      value.offset,
    );
    if (previous != value.pageIndex) await refresh();
  }

  Future<void> autoLayout() async {
    final snapshot = map;
    if (snapshot == null) return;
    await repository.organizeMap(snapshot.map.id);
  }

  @override
  void dispose() {
    _disposed = true;
    _refreshTimer?.cancel();
    unawaited(_subscription.cancel());
    super.dispose();
  }
}
