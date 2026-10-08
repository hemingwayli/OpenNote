/// 捕获原关联端点和编辑代次，保存期间重连不能误写新的关系。
class RelationshipLabelDraft {
  const RelationshipLabelDraft(
    this.mapId,
    this.edgeId,
    this.fromNodeId,
    this.toNodeId,
    this.label,
    this.generation,
  );
  final String mapId, edgeId, fromNodeId, toNodeId, label;
  final int generation;
}
