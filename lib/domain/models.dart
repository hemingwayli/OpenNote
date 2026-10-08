import 'dart:convert';

import 'personal_thought.dart';
import 'document_locator.dart';
export 'personal_thought.dart';
export 'document_locator.dart';
export 'pdf_reading_settings.dart';

part 'relationship_style.dart';
part 'map_boundary.dart';
part 'map_summary.dart';
part 'topic_style.dart';

/// 所有坐标均为原 PDF 页面用户空间，页码从 0 开始。
class PdfPoint {
  const PdfPoint(this.x, this.y);
  final double x;
  final double y;
  Map<String, Object?> toJson() => {'x': x, 'y': y};
  factory PdfPoint.fromJson(Map<String, dynamic> value) =>
      PdfPoint((value['x'] as num).toDouble(), (value['y'] as num).toDouble());
}

class PdfQuad {
  const PdfQuad(this.points) : assert(points.length == 4);
  final List<PdfPoint> points;
  factory PdfQuad.rect(double left, double bottom, double right, double top) =>
      PdfQuad([
        PdfPoint(left, top),
        PdfPoint(right, top),
        PdfPoint(right, bottom),
        PdfPoint(left, bottom),
      ]);
  Map<String, Object?> toJson() => {
    'points': points.map((p) => p.toJson()).toList(),
  };
  factory PdfQuad.fromJson(Map<String, dynamic> value) => PdfQuad(
    (value['points'] as List)
        .map((p) => PdfPoint.fromJson(Map<String, dynamic>.from(p as Map)))
        .toList(),
  );
}

class PdfPageGeometry {
  const PdfPageGeometry({
    required this.pageIndex,
    required this.cropBox,
    required this.mediaBox,
    this.rotation = 0,
    this.userUnit = 1,
  });
  final int pageIndex;
  final PdfQuad cropBox;
  final PdfQuad mediaBox;
  final int rotation;
  final double userUnit;
  Map<String, Object?> toJson() => {
    'pageIndex': pageIndex,
    'cropBox': cropBox.toJson(),
    'mediaBox': mediaBox.toJson(),
    'rotation': rotation,
    'userUnit': userUnit,
  };
  factory PdfPageGeometry.fromJson(Map<String, dynamic> value) =>
      PdfPageGeometry(
        pageIndex: value['pageIndex'] as int,
        cropBox: PdfQuad.fromJson(
          Map<String, dynamic>.from(value['cropBox'] as Map),
        ),
        mediaBox: PdfQuad.fromJson(
          Map<String, dynamic>.from(value['mediaBox'] as Map),
        ),
        rotation: value['rotation'] as int,
        userUnit: (value['userUnit'] as num).toDouble(),
      );
}

enum TextLayerSource { nativePdf, ocr }

enum GeometryPrecision { line, word, character, approximateCharacter }

/// start/length 使用 Dart 的 UTF-16 索引；精度如实表示引擎输出。
class TextFragment {
  const TextFragment({
    required this.start,
    required this.length,
    required this.quad,
    required this.order,
    this.confidence,
    this.precision = GeometryPrecision.word,
  });
  final int start;
  final int length;
  final PdfQuad quad;
  final int order;
  final double? confidence;
  final GeometryPrecision precision;
  Map<String, Object?> toJson() => {
    'start': start,
    'length': length,
    'quad': quad.toJson(),
    'order': order,
    'confidence': confidence,
    'precision': precision.name,
  };
  factory TextFragment.fromJson(Map<String, dynamic> value) => TextFragment(
    start: value['start'] as int,
    length: value['length'] as int,
    quad: PdfQuad.fromJson(Map<String, dynamic>.from(value['quad'] as Map)),
    order: value['order'] as int,
    confidence: (value['confidence'] as num?)?.toDouble(),
    precision: GeometryPrecision.values.byName(value['precision'] as String),
  );
}

class PageTextLayer {
  const PageTextLayer({
    required this.id,
    required this.revisionId,
    required this.pageIndex,
    required this.source,
    required this.text,
    required this.fragments,
    required this.engineVersion,
    required this.createdAt,
    this.parameters = const {},
    this.isCurrent = true,
  });
  final String id;
  final String revisionId;
  final int pageIndex;
  final TextLayerSource source;
  final String text;
  final List<TextFragment> fragments;
  final String engineVersion;
  final Map<String, Object?> parameters;
  final DateTime createdAt;
  final bool isCurrent;
}

class TextLayerDraft {
  const TextLayerDraft({
    required this.revisionId,
    required this.pageIndex,
    required this.source,
    required this.text,
    required this.fragments,
    required this.engineVersion,
    this.parameters = const {},
  });
  final String revisionId;
  final int pageIndex;
  final TextLayerSource source;
  final String text;
  final List<TextFragment> fragments;
  final String engineVersion;
  final Map<String, Object?> parameters;
}

class StudyProject {
  const StudyProject({
    required this.id,
    required this.title,
    required this.createdAt,
    this.deletedAt,
  });
  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime? deletedAt;
}

enum ProjectSort { recent, name, created }

class ProjectFolder {
  const ProjectFolder({
    required this.id,
    required this.title,
    required this.projectCount,
  });
  final String id;
  final String title;
  final int projectCount;
}

class ProjectResumeState {
  const ProjectResumeState({
    this.lastOpenedAt,
    this.activeDocumentId,
    this.lastReadDocumentId,
    this.mapId,
    this.openedDocumentIds = const [],
  });
  final DateTime? lastOpenedAt;
  final String? activeDocumentId;
  final String? lastReadDocumentId;
  final String? mapId;
  final List<String> openedDocumentIds;
}

class ProjectSummary {
  const ProjectSummary({
    required this.project,
    required this.documentCount,
    required this.mapCount,
    required this.cardCount,
    this.folderId,
    this.folderTitle,
    this.lastOpenedAt,
    this.coverPath,
    this.coverHash,
  });
  final StudyProject project;
  final String? folderId;
  final String? folderTitle;
  final DateTime? lastOpenedAt;
  final int documentCount;
  final int mapCount;
  final int cardCount;
  final String? coverPath;
  final String? coverHash;
}

class ProjectPage {
  const ProjectPage(this.items, this.total);
  final List<ProjectSummary> items;
  final int total;
}

class ResourceRecord {
  const ResourceRecord({
    required this.id,
    required this.sha256,
    required this.kind,
    required this.size,
    required this.relativePath,
  });
  final String id;
  final String sha256;
  final String kind;
  final int size;
  final String relativePath;
}

class ManagedDocument {
  const ManagedDocument({
    required this.id,
    required this.projectId,
    required this.title,
    required this.activeRevisionId,
    this.deletedAt,
    this.format = DocumentFormat.pdf,
  });
  final String id;
  final String projectId;
  final String title;
  final String activeRevisionId;
  final DateTime? deletedAt;
  final DocumentFormat format;
}

class DocumentRevision {
  const DocumentRevision({
    required this.id,
    required this.documentId,
    required this.resourceId,
    required this.contentHash,
    required this.pageCount,
    this.pageGeometry = const [],
    this.format = DocumentFormat.pdf,
    this.metadata = const {},
  });
  final String id;
  final String documentId;
  final String resourceId;
  final String contentHash;
  final int pageCount;
  final List<PdfPageGeometry> pageGeometry;
  final DocumentFormat format;
  final Map<String, dynamic> metadata;
  ReaderCapabilities get capabilities=>format==DocumentFormat.pdf?ReaderCapabilities.pdf:ReaderCapabilities.epub;
}

class ReadingPosition {
  const ReadingPosition({
    required this.revisionId,
    this.pageIndex = 0,
    this.offset = 0,
    this.epubLocator,
    this.settings = const EpubReadingSettings(),
  });
  final String revisionId;
  final int pageIndex;
  final double offset;
  final EpubLocator? epubLocator;
  final EpubReadingSettings settings;
}

class NoteCard {
  const NoteCard({
    required this.id,
    required this.projectId,
    required this.title,
    required this.excerptSnapshot,
    required this.body,
    required this.note,
    required this.color,
    this.thoughtEntries,
    this.imageResourceId,
    this.deletedAt,
  });
  final String id;
  final String projectId;
  final String title;
  final String excerptSnapshot;
  final String body;
  final String note;
  final List<PersonalThought>? thoughtEntries;
  List<PersonalThought> get thoughts =>
      thoughtEntries ?? legacyPersonalThoughts(id, note);
  final String color;
  final String? imageResourceId;
  final DateTime? deletedAt;
}

class AnchorDraft {
  const AnchorDraft({
    required this.revisionId,
    this.pageIndex = 0,
    this.quads = const [],
    this.epubLocator,
    this.textLayerId,
    this.textStart,
    this.textEnd,
    this.context = '',
  });
  final String revisionId;
  final EpubLocator? epubLocator;
  final int pageIndex;
  final List<PdfQuad> quads;
  final String? textLayerId;
  final int? textStart;
  final int? textEnd;
  final String context;
}

class SourceAnchor extends AnchorDraft {
  const SourceAnchor({
    required this.id,
    required this.cardId,
    required super.revisionId,
    required super.pageIndex,
    required super.quads,
    super.textLayerId,
    super.textStart,
    super.textEnd,
    super.context,
    super.epubLocator,
  });
  final String id;
  final String cardId;
}

class AppAnnotation {
  const AppAnnotation({
    required this.id,
    required this.revisionId,
    required this.pageIndex,
    required this.quads,
    required this.kind,
    required this.text,
    required this.color,
    this.cardId,
    this.epubLocator,
  });
  final String id;
  final String revisionId;
  final int pageIndex;
  final List<PdfQuad> quads;
  final String kind;
  final String text;
  final String color;
  final String? cardId;
  final EpubLocator? epubLocator;
}

enum MapLayoutKind {
  free,
  right,
  left,
  mindMap,
  down,
  up,
  treeRight,
  treeLeft,
  braceRight,
  braceLeft,
  timeline,
  timelineVertical,
  fishboneLeft,
  fishboneRight;

  bool get vertical => this == down || this == up || this == timelineVertical;
  bool get extended => index >= treeRight.index;
  bool get tree => this == treeRight || this == treeLeft;
  bool get brace => this == braceRight || this == braceLeft;
  bool get chronological => this == timeline || this == timelineVertical;
  bool get fishbone => this == fishboneLeft || this == fishboneRight;
  bool get spine => chronological || fishbone;
  bool get siblingsHorizontal =>
      vertical && !chronological || this == timeline || fishbone;
  bool get reverseSiblingOrder => this == fishboneRight;
  MapLayoutKind get primaryDirection => switch (this) {
    treeLeft || braceLeft || fishboneRight => left,
    treeRight || braceRight || timeline || fishboneLeft => right,
    timelineVertical => down,
    _ => this,
  };
  String get label => switch (this) {
    free => '自由布局',
    right => '逻辑图 · 向右',
    left => '逻辑图 · 向左',
    mindMap => '双侧脑图',
    down => '组织结构 · 向下',
    up => '组织结构 · 向上',
    treeRight => '树形图 · 向右',
    treeLeft => '树形图 · 向左',
    braceRight => '大括号图 · 向右',
    braceLeft => '大括号图 · 向左',
    timeline => '时间线 · 横向',
    timelineVertical => '时间线 · 纵向',
    fishboneLeft => '鱼骨图 · 头向左',
    fishboneRight => '鱼骨图 · 头向右',
  };
}

class MindMap {
  const MindMap({
    required this.id,
    required this.projectId,
    required this.title,
    this.deletedAt,
    this.layout = MapLayoutKind.right,
    this.defaultStyle = const TopicStyle(),
  });
  final String id;
  final String projectId;
  final String title;
  final DateTime? deletedAt;
  final MapLayoutKind layout;
  final TopicStyle defaultStyle;
}

class MapNode {
  const MapNode({
    required this.id,
    required this.mapId,
    required this.cardId,
    required this.x,
    required this.y,
    this.parentNodeId,
    this.width = 220,
    this.height = 116,
    this.collapsed = false,
    this.sortIndex,
    this.branchSide,
    this.style,
    this.branchLayout,
  });
  final String id;
  final String mapId;
  final String cardId;
  final String? parentNodeId;
  final double x;
  final double y;
  final double width;
  final double height;
  final bool collapsed;
  final int? sortIndex;

  /// 双侧结构主题的直接分支方向，-1 向左、1 向右；后代继承所属方向。
  final int? branchSide;
  final TopicStyle? style;

  /// 该主题子树的结构；空值跟随上层分支，双侧结构的后代跟随所属左右方向。
  final MapLayoutKind? branchLayout;
  MapNode withStyle(TopicStyle? value) => MapNode(
    id: id,
    mapId: mapId,
    cardId: cardId,
    parentNodeId: parentNodeId,
    x: x,
    y: y,
    width: width,
    height: height,
    collapsed: collapsed,
    sortIndex: sortIndex,
    branchSide: branchSide,
    style: value,
    branchLayout: branchLayout,
  );
  MapNode withBranchLayout(MapLayoutKind? value) => MapNode(
    id: id,
    mapId: mapId,
    cardId: cardId,
    parentNodeId: parentNodeId,
    x: x,
    y: y,
    width: width,
    height: height,
    collapsed: collapsed,
    sortIndex: sortIndex,
    branchSide: branchSide,
    style: style,
    branchLayout: value,
  );
}

int compareMapNodes(MapNode left, MapNode right) {
  if ((left.sortIndex == null) != (right.sortIndex == null)) {
    return left.sortIndex == null ? 1 : -1;
  }
  if (left.sortIndex != null && right.sortIndex != null) {
    final order = left.sortIndex!.compareTo(right.sortIndex!);
    if (order != 0) return order;
  }
  final y = left.y.compareTo(right.y);
  if (y != 0) return y;
  final x = left.x.compareTo(right.x);
  return x != 0 ? x : left.id.compareTo(right.id);
}

/// 快速插入保持卡片独立；上层主题只改变被选分支的直接父关系。
enum TopicInsertKind { child, siblingAfter, siblingBefore, parent }

class MapEdge {
  const MapEdge({
    required this.id,
    required this.mapId,
    required this.fromNodeId,
    required this.toNodeId,
    this.label = '',
    this.style = const RelationshipStyle(),
  });
  final String id;
  final String mapId;
  final String fromNodeId;
  final String toNodeId;
  final String label;
  final RelationshipStyle style;
}

class MapSnapshot {
  const MapSnapshot({
    required this.map,
    required this.nodes,
    required this.cards,
    required this.anchors,
    required this.edges,
    this.boundaries = const [],
    this.summaries = const [],
  });
  final MindMap map;
  final List<MapNode> nodes;
  final Map<String, NoteCard> cards;
  final Map<String, List<SourceAnchor>> anchors;
  final List<MapEdge> edges;
  final List<MapBoundary> boundaries;
  final List<MapSummary> summaries;
}

class ExcerptDraft {
  const ExcerptDraft({
    required this.projectId,
    required this.mapId,
    required this.title,
    required this.text,
    this.note = '',
    this.color = '#F7D976',
    this.parentNodeId,
    this.anchors = const [],
    this.imageBytes,
    this.imageExtension = 'png',
    this.x = 0,
    this.y = 0,
    this.createHighlight = true,
  });
  final String projectId;
  final String mapId;
  final String title;
  final String text;
  final String note;
  final String color;
  final String? parentNodeId;
  final List<AnchorDraft> anchors;
  final List<int>? imageBytes;
  final String imageExtension;
  final double x;
  final double y;
  final bool createHighlight;
}

class ExcerptResult {
  const ExcerptResult({required this.card, required this.node});
  final NoteCard card;
  final MapNode node;
}

class BranchCopyResult {
  const BranchCopyResult({
    required this.rootNodeId,
    required this.cardIds,
    required this.nodeIds,
  });
  final String rootNodeId;
  final Map<String, String> cardIds;
  final Map<String, String> nodeIds;
}

enum OcrTaskStatus { queued, running, completed, cancelled, failed }

class OcrTask {
  const OcrTask({
    required this.id,
    required this.revisionId,
    required this.pageIndex,
    required this.modelVersion,
    required this.status,
    required this.error,
    this.sessionId,
  });
  final String id;
  final String revisionId;
  final int pageIndex;
  final String modelVersion;
  final OcrTaskStatus status;
  final String error;
  final String? sessionId;
}

enum SearchHitKind { card, page }

class SearchHit {
  const SearchHit({
    required this.kind,
    required this.id,
    required this.text,
    required this.start,
    required this.end,
    this.cardId,
    this.documentId,
    this.revisionId,
    this.textLayerId,
    this.pageIndex,
    this.quads = const [],
    this.epubLocator,
  });
  final SearchHitKind kind;
  final String id;
  final String text;
  final int start;
  final int end;
  final String? cardId;
  final String? documentId;
  final String? revisionId;
  final String? textLayerId;
  final int? pageIndex;
  final List<PdfQuad> quads;
  final EpubLocator? epubLocator;
}

enum TrashKind { project, document, card, map }

class TrashEntry {
  const TrashEntry({
    required this.id,
    required this.kind,
    required this.entityId,
    required this.projectId,
    required this.title,
    required this.deletedAt,
  });
  final String id;
  final TrashKind kind;
  final String entityId;
  final String projectId;
  final String title;
  final DateTime deletedAt;
}

/// 永久清理先报告引用边界；备份 ZIP 自带资源，不占用活动文件。
class TrashPurgePreview {
  const TrashPurgePreview({
    required this.blockers,
    required this.cardCount,
    required this.documentCount,
    required this.mapCount,
    required this.resourceCount,
    required this.reclaimableBytes,
    this.pendingResourcePaths = const [],
  });
  final List<String> blockers;
  final int cardCount;
  final int documentCount;
  final int mapCount;
  final int resourceCount;
  final int reclaimableBytes;

  /// 文件被操作系统占用时逻辑清理已提交；稍后可重试资源回收。
  final List<String> pendingResourcePaths;
  bool get canPurge => blockers.isEmpty;
}

enum RepositoryError {
  invalidInput,
  notFound,
  wrongProject,
  cycle,
  conflict,
  referenced,
  corruptBackup,
  unsupportedVersion,
  staleSession,
  disposed,
}

class RepositoryException implements Exception {
  const RepositoryException(this.code, this.message);
  final RepositoryError code;
  final String message;
  @override
  String toString() => message;
}

String encodeJson(Object? value) => jsonEncode(value);
List<Map<String, dynamic>> decodeObjectList(String value) =>
    (jsonDecode(value) as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
