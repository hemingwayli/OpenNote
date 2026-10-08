import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:opennote/data/open_note_repository.dart';
import 'package:opennote/domain/models.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late OpenNoteRepository repository;
  late StudyProject project;
  late MindMap map;
  late ManagedDocument document;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('opennote-color-sync-');
    repository = await OpenNoteRepository.open(
      rootPath: '${temp.path}/library',
    );
    project = await repository.createProject('卡片标注颜色');
    map = (await repository.listMaps(project.id)).single;
    document = await repository.importPdf(
      projectId: project.id,
      filePath: File('tools/fixtures/pdf/native.pdf').absolute.path,
      pageCount: 2,
    );
  });

  tearDown(() async {
    await repository.close();
    await temp.delete(recursive: true);
  });

  AnchorDraft anchor(int page) => AnchorDraft(
    revisionId: document.activeRevisionId,
    pageIndex: page,
    quads: [PdfQuad.rect(20, 100, 200, 120)],
    context: '原文位置$page',
  );

  Future<ExcerptResult> excerpt({
    List<AnchorDraft> anchors = const [],
    String? parent,
  }) => repository.createExcerpt(
    ExcerptDraft(
      projectId: project.id,
      mapId: map.id,
      title: '颜色卡片',
      text: '保留正文',
      note: '保留个人思考',
      anchors: anchors,
      parentNodeId: parent,
      createHighlight: true,
    ),
  );

  Future<List<AppAnnotation>> marks() =>
      repository.listAnnotations(document.activeRevisionId);

  test('卡片标注改色：多页同步一次撤销重做，几何与独立副本不变', () async {
    final card = await excerpt(anchors: [anchor(0), anchor(1)]);
    final original = await marks();
    final copy = await repository.copyBranch(card.node.id, map.id);
    final independent = await repository.createAnnotation(
      anchor: anchor(0),
      color: '#EB8C91',
      text: '独立标注',
    );
    final history = repository.undoEntryCount;
    await repository.updateCard(card.card.id, color: '#80B9EB');
    expect(repository.undoEntryCount, history + 1);
    final changed = await marks();
    for (final before in original) {
      final after = changed.singleWhere((value) => value.id == before.id);
      expect(after.color, '#80B9EB');
      expect(after.cardId, card.card.id);
      expect(after.pageIndex, before.pageIndex);
      expect(after.kind, before.kind);
      expect(after.text, before.text);
      expect(
        after.quads.map((value) => value.toJson()).toList(),
        before.quads.map((value) => value.toJson()).toList(),
      );
    }
    expect(
      changed.singleWhere((value) => value.id == independent.id).color,
      '#EB8C91',
    );
    final copyCardId = copy.cardIds[card.card.id]!;
    expect((await repository.getCard(copyCardId)).color, card.card.color);
    expect((await repository.getCard(card.card.id)).body, '保留正文');
    expect((await repository.getCard(card.card.id)).note, '保留个人思考');
    await repository.undo();
    expect((await repository.getCard(card.card.id)).color, card.card.color);
    expect(
      (await marks())
          .where((value) => value.cardId == card.card.id)
          .every((value) => value.color == card.card.color),
      isTrue,
    );
    await repository.redo();
    expect((await repository.getCard(card.card.id)).color, '#80B9EB');
    expect(
      (await marks())
          .where((value) => value.cardId == card.card.id)
          .every((value) => value.color == '#80B9EB'),
      isTrue,
    );
    await repository.updateCard(copyCardId, color: '#91C69A');
    expect(
      (await marks())
          .where((value) => value.cardId == card.card.id)
          .every((value) => value.color == '#80B9EB'),
      isTrue,
      reason: '副本没有自己的标注，不能按相同来源改写原卡标注',
    );
    await repository.updateCard(card.card.id, body: '只修改正文');
    expect(
      (await marks())
          .where((value) => value.cardId == card.card.id)
          .every((value) => value.color == '#80B9EB'),
      isTrue,
    );
  });

  test('卡片标注改色：重选当前色修正旧差异，完全一致不新增历史且保留重做', () async {
    final card = await excerpt(anchors: [anchor(0)]);
    final annotation = (await marks()).single;
    await repository.updateAnnotation(annotation.id, color: '#EB8C91');
    final history = repository.undoEntryCount;
    await repository.updateCard(card.card.id, color: card.card.color);
    expect(repository.undoEntryCount, history + 1);
    expect((await marks()).single.color, card.card.color);
    await repository.undo();
    expect((await marks()).single.color, '#EB8C91');
    await repository.redo();
    await repository.updateCard(card.card.id, body: '准备撤销正文');
    await repository.undo();
    final unchangedHistory = repository.undoEntryCount;
    final redo = repository.redoEntryCount;
    await repository.updateCard(card.card.id, color: card.card.color);
    expect(repository.undoEntryCount, unchangedHistory);
    expect(repository.redoEntryCount, redo);
    expect((await marks()).single.color, card.card.color);
  });

  test('卡片标注改色：批量只同步精确选中卡片，无来源卡也可改色', () async {
    final parent = await excerpt(anchors: [anchor(0)]);
    final child = await excerpt(anchors: [anchor(1)], parent: parent.node.id);
    final plain = await excerpt();
    final history = repository.undoEntryCount;
    await repository.setCardsColor(map.id, [
      parent.node.id,
      plain.node.id,
    ], '#91C69A');
    expect(repository.undoEntryCount, history + 1);
    expect((await repository.getCard(plain.card.id)).color, '#91C69A');
    expect((await repository.getCard(child.card.id)).color, child.card.color);
    expect(
      (await marks())
          .singleWhere((value) => value.cardId == parent.card.id)
          .color,
      '#91C69A',
    );
    expect(
      (await marks())
          .singleWhere((value) => value.cardId == child.card.id)
          .color,
      child.card.color,
    );
    await repository.undo();
    expect((await repository.getCard(plain.card.id)).color, plain.card.color);
    expect(
      (await marks())
          .singleWhere((value) => value.cardId == parent.card.id)
          .color,
      parent.card.color,
    );
  });

  test('卡片标注改色：标注保存失败整笔回滚，队列恢复后可重试', () async {
    final card = await excerpt(anchors: [anchor(0), anchor(1)]);
    final db = sqlite3.open('${repository.libraryPath}/library.sqlite');
    try {
      db.execute(
        "CREATE TRIGGER reject_color_sync BEFORE UPDATE OF color ON annotations "
        "WHEN OLD.page_index=1 BEGIN SELECT RAISE(ABORT, '验证标注改色失败'); END",
      );
      final history = repository.undoEntryCount;
      await expectLater(
        repository.updateCard(card.card.id, color: '#80B9EB'),
        throwsA(anything),
      );
      expect(repository.undoEntryCount, history);
      expect((await repository.getCard(card.card.id)).color, card.card.color);
      expect(
        (await marks()).every((value) => value.color == card.card.color),
        isTrue,
      );
      db.execute('DROP TRIGGER reject_color_sync');
      await repository.updateCard(card.card.id, color: '#80B9EB');
      expect(repository.undoEntryCount, history + 1);
      expect(
        (await marks()).every((value) => value.color == '#80B9EB'),
        isTrue,
      );
    } finally {
      db.close();
    }
  });

  test('卡片标注改色：图片区域标注沿用几何和类型', () async {
    final result = await repository.createExcerpt(
      ExcerptDraft(
        projectId: project.id,
        mapId: map.id,
        title: '图片区域',
        text: '',
        anchors: [anchor(0)],
        createHighlight: true,
        imageBytes: base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jLr8AAAAASUVORK5CYII=',
        ),
      ),
    );
    final original = (await marks()).single;
    expect(original.kind, 'region');
    await repository.updateCard(result.card.id, color: '#B7A0DD');
    final changed = (await marks()).single;
    expect(changed.color, '#B7A0DD');
    expect(changed.kind, original.kind);
    expect(
      changed.quads.map((value) => value.toJson()).toList(),
      original.quads.map((value) => value.toJson()).toList(),
    );
  });

  test('卡片标注改色：跨项目副本只同步副本的文档标注', () async {
    final card = await excerpt(anchors: [anchor(0)]);
    final nextProject = await repository.createProject('独立项目');
    final nextMap = (await repository.listMaps(nextProject.id)).single;
    final copied = await repository.copyBranch(card.node.id, nextMap.id);
    final copiedCardId = copied.cardIds[card.card.id]!;
    final copiedAnchor = (await repository.getAnchors(copiedCardId)).single;
    await repository.updateCard(copiedCardId, color: '#B7A0DD');
    expect(
      (await repository.listAnnotations(copiedAnchor.revisionId)).single.color,
      '#B7A0DD',
    );
    expect((await marks()).single.color, card.card.color);
    expect((await repository.getCard(card.card.id)).color, card.card.color);
  });
}
