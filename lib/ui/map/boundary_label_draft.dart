class BoundaryLabelDraft {
  const BoundaryLabelDraft(
    this.mapId,
    this.boundaryId,
    this.nodeIds,
    this.label,
    this.generation,
  );
  final String mapId, boundaryId, label;
  final List<String> nodeIds;
  final int generation;
}
