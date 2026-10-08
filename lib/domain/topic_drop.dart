import 'models.dart';
import 'branch_structure.dart';

enum TopicDropPlacement { child, before, after }

/// 指针命中时捕获锚点身份与父级，不能在较晚保存时改成另一层级。
class TopicDropTarget {
  const TopicDropTarget(this.anchor, this.placement);
  final MapNode anchor;
  final TopicDropPlacement placement;
  String get label => switch (placement) {
    TopicDropPlacement.child => '加入子主题',
    TopicDropPlacement.before => '插入前面',
    TopicDropPlacement.after => '插入后面',
  };
}

TopicDropTarget? topicDropTargetAt(
  Iterable<MapNode> nodes,
  Set<String> shown,
  Set<String> excluded,
  PdfPoint point,
  MapLayoutKind kind,
  Map<String, MapLayoutKind> layouts, {
  bool allowSiblings = true,
}) {
  TopicDropTarget? result;
  for (final node in nodes) {
    if (!shown.contains(node.id) ||
        excluded.contains(node.id) ||
        point.x < node.x - 5 ||
        point.x > node.x + node.width + 5 ||
        point.y < node.y - 5 ||
        point.y > node.y + node.height + 5) {
      continue;
    }
    final incoming = incomingBranchLayout(node, kind, layouts);
    var placement = TopicDropPlacement.child;
    if (allowSiblings && incoming != MapLayoutKind.free) {
      var fraction = incoming.siblingsHorizontal
          ? (point.x - node.x) / node.width
          : (point.y - node.y) / node.height;
      if (incoming.reverseSiblingOrder) fraction = 1 - fraction;
      if (fraction < .25) placement = TopicDropPlacement.before;
      if (fraction > .75) placement = TopicDropPlacement.after;
    }
    result = TopicDropTarget(node, placement);
  }
  return result;
}
