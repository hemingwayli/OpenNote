import 'models.dart';
import 'boundary_geometry.dart';
import 'summary_geometry.dart';
import 'topic_style_resolver.dart';

/// 剪贴板保存复制时的不可变内容，不能在粘贴时重新读取被修改的原卡。
class MapClipboardContent {
  MapClipboardContent._(this.snapshot, this.rootIds, this.text);
  final MapSnapshot snapshot;
  final List<String> rootIds;
  final String text;

  factory MapClipboardContent.capture(MapSnapshot map, Set<String> selection) {
    final byId = {for (final node in map.nodes) node.id: node};
    final styles = topicStylesFor(map);
    final layouts = effectiveBranchLayouts(
      map.nodes,
      map.map.layout,
      summaries: map.summaries,
    );
    if (selection.isEmpty || selection.any((id) => !byId.containsKey(id))) {
      throw StateError('请先选择有效的主题');
    }
    bool covered(MapNode node) {
      var parent = node.parentNodeId;
      final seen = <String>{node.id};
      while (parent != null) {
        if (!seen.add(parent)) throw StateError('脑图层级存在循环');
        if (selection.contains(parent)) return true;
        parent = byId[parent]?.parentNodeId;
      }
      return false;
    }

    final roots =
        selection.map((id) => byId[id]!).where((n) => !covered(n)).toList()
          ..sort(compareMapNodes);
    final children = <String, List<MapNode>>{};
    for (final node in map.nodes) {
      if (node.parentNodeId != null) {
        (children[node.parentNodeId!] ??= []).add(node);
      }
    }
    for (final nodes in children.values) {
      nodes.sort(compareMapNodes);
    }
    final included = <String>{};
    final nodes = <MapNode>[];
    final text = <String>[];
    final stack = <(MapNode, int)>[
      for (final root in roots.reversed) (root, 0),
    ];
    while (stack.isNotEmpty) {
      final (node, depth) = stack.removeLast();
      if (!included.add(node.id)) throw StateError('脑图层级存在循环');
      nodes.add(node);
      text.add(
        '${'\t' * depth}${map.cards[node.cardId]!.title.replaceAll('\n', ' ')}',
      );
      stack.addAll(
        (children[node.id] ?? []).reversed.map((n) => (n, depth + 1)),
      );
    }
    // 完整范围被复制时，连同概要主题及其子主题捕获，部分范围不复制括号。
    var added = true;
    while (added) {
      added = false;
      for (final summary in map.summaries) {
        final scope = summaryRoots(summary, map.nodes, map.summaries);
        final topic = byId[summary.summaryNodeId];
        if (topic == null ||
            included.contains(topic.id) ||
            scope.isEmpty ||
            !scope.every((n) => included.contains(n.id))) {
          continue;
        }
        if (!included.contains(topic.parentNodeId)) roots.add(topic);
        var depth = 0, parent = topic.parentNodeId;
        final seen = <String>{};
        while (parent != null && included.contains(parent)) {
          if (!seen.add(parent)) throw StateError('脑图层级存在循环');
          depth++;
          parent = byId[parent]?.parentNodeId;
        }
        final extra = <(MapNode, int)>[(topic, depth)];
        while (extra.isNotEmpty) {
          final (node, level) = extra.removeLast();
          if (!included.add(node.id)) continue;
          nodes.add(node);
          text.add(
            '${'\t' * level}${map.cards[node.cardId]!.title.replaceAll('\n', ' ')}',
          );
          extra.addAll(
            (children[node.id] ?? []).reversed.map((n) => (n, level + 1)),
          );
        }
        added = true;
      }
    }
    final rootIds = roots.map((n) => n.id).toSet();
    return MapClipboardContent._(
      MapSnapshot(
        map: map.map,
        nodes: List.unmodifiable([
          for (final node in nodes)
            node
                .withStyle(
                  map.summaries.any((s) => s.summaryNodeId == node.id)
                      ? null
                      : styles[node.id],
                )
                .withBranchLayout(
                  rootIds.contains(node.id)
                      ? layouts[node.id]
                      : node.branchLayout,
                ),
        ]),
        cards: Map.unmodifiable({
          for (final node in nodes) node.cardId: map.cards[node.cardId]!,
        }),
        anchors: Map.unmodifiable({
          for (final node in nodes)
            node.cardId: List<SourceAnchor>.unmodifiable(
              map.anchors[node.cardId] ?? [],
            ),
        }),
        edges: List.unmodifiable(
          map.edges.where(
            (e) =>
                included.contains(e.fromNodeId) &&
                included.contains(e.toNodeId),
          ),
        ),
        boundaries: List.unmodifiable([
          for (final boundary in map.boundaries)
            if (boundaryRoots(
                  boundary,
                  map.nodes,
                  auxiliaryRoots: map.summaries
                      .map((s) => s.summaryNodeId)
                      .toSet(),
                ).isNotEmpty &&
                boundaryRoots(
                  boundary,
                  map.nodes,
                  auxiliaryRoots: map.summaries
                      .map((s) => s.summaryNodeId)
                      .toSet(),
                ).every((n) => included.contains(n.id)))
              MapBoundary(
                id: boundary.id,
                mapId: boundary.mapId,
                parentNodeId: boundary.parentNodeId,
                nodeIds: List.unmodifiable(
                  boundaryRoots(
                    boundary,
                    map.nodes,
                    auxiliaryRoots: map.summaries
                        .map((s) => s.summaryNodeId)
                        .toSet(),
                  ).map((n) => n.id),
                ),
                label: boundary.label,
                style: boundary.style,
              ),
        ]),
        summaries: List.unmodifiable([
          for (final s in map.summaries)
            if (included.contains(s.summaryNodeId) &&
                summaryRoots(s, map.nodes, map.summaries).isNotEmpty &&
                summaryRoots(
                  s,
                  map.nodes,
                  map.summaries,
                ).every((n) => included.contains(n.id)))
              MapSummary(
                id: s.id,
                mapId: s.mapId,
                parentNodeId: s.parentNodeId,
                summaryNodeId: s.summaryNodeId,
                style: s.style,
                nodeIds: List.unmodifiable(
                  summaryRoots(s, map.nodes, map.summaries).map((n) => n.id),
                ),
              ),
        ]),
      ),
      List.unmodifiable(roots.map((n) => n.id)),
      text.join('\n'),
    );
  }
}

class TopicTextLine {
  const TopicTextLine(this.title, this.depth);
  final String title;
  final int depth;
}

/// Tab 或四个空格表示一级；容纳常见 Markdown 无序列表，拒绝不连续的层级。
List<TopicTextLine> parseTopicOutline(String text) {
  final result = <TopicTextLine>[];
  var base = 0;
  for (final line in text.split(RegExp(r'\r?\n'))) {
    if (line.trim().isEmpty) continue;
    final prefix = RegExp(r'^[\t ]*').firstMatch(line)!.group(0)!;
    final indent = prefix.replaceAll('\t', '    ').length ~/ 4;
    if (result.isEmpty) base = indent;
    final depth = indent - base;
    if (depth < 0 || depth > (result.isEmpty ? 0 : result.last.depth + 1)) {
      throw const FormatException('大纲缩进不连续，请用 Tab 或四个空格表示一级');
    }
    final title = line.trim().replaceFirst(RegExp(r'^[-*+]\s+'), '');
    if (title.isEmpty) continue;
    result.add(TopicTextLine(title, depth));
    if (result.length > 2000) throw const FormatException('一次最多粘贴 2000 个主题');
  }
  if (result.isEmpty) throw const FormatException('剪贴板中没有可粘贴的主题');
  return result;
}
