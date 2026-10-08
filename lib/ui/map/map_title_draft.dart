/// 草稿携带目标和编辑代次，异步保存不能关掉后来打开的另一个标题。
class MapTitleDraft {
  const MapTitleDraft(
    this.mapId,
    this.nodeId,
    this.cardId,
    this.title,
    this.generation,
  );
  final String mapId;
  final String nodeId;
  final String cardId;
  final String title;
  final int generation;
}
