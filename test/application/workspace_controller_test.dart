import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opennote/application/workspace_controller.dart';
import 'package:opennote/data/open_note_repository.dart';
import 'package:opennote/domain/models.dart';
import 'package:opennote/engines/pdf/pdf_excerpt_text.dart';
import 'package:opennote/engines/pdf/pdf_text_selection.dart';
import 'package:opennote/ui/reader/reader_contract.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late OpenNoteRepository repository;
  late WorkspaceController controller;
  late StudyProject project;
  late MindMap map;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('opennote-theme-');
    repository = await OpenNoteRepository.open(
      rootPath: p.join(temp.path, 'library'),
    );
    project = await repository.createProject('快捷主题真实资料库');
    map = (await repository.listMaps(project.id)).single;
    controller = WorkspaceController(repository);
    await controller.selectProject(project);
  });

  tearDown(() async {
    controller.dispose();
    await repository.close();
    await temp.delete(recursive: true);
  });

  test('并发刷新：先等待的保存仍等待最新有效快照，撤销后坐标及时交还', () async {
    final node = await controller.addTheme('原坐标', parentNodeId: null);
    await repository.moveNode(node.node.id, 370, 260);
    final first = controller.refresh();
    final latest = controller.refresh();
    await first;
    expect(controller.map!.nodes.single.x, 370);
    expect(controller.map!.nodes.single.y, 260);
    await latest;
    await repository.undo();
    final undoRefresh = controller.refresh();
    final backgroundRefresh = controller.refresh();
    await undoRefresh;
    expect(controller.map!.nodes.single.x, node.node.x);
    expect(controller.map!.nodes.single.y, node.node.y);
    await backgroundRefresh;
    expect(repository.canRedo, isTrue);
  });

  test('并发刷新：切换脑图后的旧读取不替换当前快照和选择', () async {
    final original = await controller.addTheme('旧图', parentNodeId: null);
    final destination = await repository.createMap(project.id, '目标图');
    final reading = controller.refresh();
    final switching = controller.selectMap(destination.id);
    await Future.wait([reading, switching]);
    expect(controller.map!.map.id, destination.id);
    expect(controller.map!.nodes, isEmpty);
    expect(controller.selectedNodeId, isNull);
    expect(controller.selectedCardId, isNull);
    expect(
      (await repository.loadMap(map.id)).nodes.single.id,
      original.node.id,
    );
  });

  test('自由布局快捷主题使用显式父目标，顶层同级不回退当前选择并按同父底边追加', () async {
    await repository.setMapLayout(map.id, MapLayoutKind.free);
    await controller.refresh();
    final first = await controller.addTheme(
      '主题 A',
      parentNodeId: null,
      x: 120,
      y: 200,
    );
    final second = await controller.addTheme(
      '主题 B',
      parentNodeId: null,
      x: 700,
      y: 30,
    );
    controller.selectNode(second.node);
    final child = await controller.addTheme(
      'A 的子主题',
      parentNodeId: first.node.id,
    );
    expect(child.node.parentNodeId, first.node.id);
    expect(child.node.x, 410);
    expect(child.node.y, 200);
    expect(controller.selectedNodeId, child.node.id);
    expect(controller.selectedCardId, child.card.id);
    controller.selectNode(second.node);
    final sibling = await controller.addTheme(
      'A 下的同级主题',
      parentNodeId: child.node.parentNodeId,
    );
    expect(sibling.node.parentNodeId, first.node.id);
    expect(sibling.node.x, child.node.x);
    expect(sibling.node.y, child.node.y + child.node.height + 24);

    controller.selectNode(child.node);
    final rootSibling = await controller.addTheme(
      '顶层同级主题',
      parentNodeId: first.node.parentNodeId,
    );
    expect(rootSibling.node.parentNodeId, isNull);
    expect(rootSibling.node.x, 80);
    expect(rootSibling.node.y, first.node.y + first.node.height + 24);
    final clicked = await controller.addTheme(
      '指定画布落点',
      parentNodeId: null,
      x: 0,
      y: 0,
    );
    expect(clicked.node.x, 0);
    expect(clicked.node.y, 0);
    expect(clicked.node.parentNodeId, isNull);
    expect(
      [
        first,
        second,
        child,
        sibling,
        rootSibling,
        clicked,
      ].map((result) => result.card.id).toSet().length,
      6,
    );
    expect(
      [
        first,
        second,
        child,
        sibling,
        rootSibling,
        clicked,
      ].map((result) => result.node.id).toSet().length,
      6,
    );
    for (final result in [
      first,
      second,
      child,
      sibling,
      rootSibling,
      clicked,
    ]) {
      expect(result.card.body, isEmpty);
      expect(result.card.note, isEmpty);
      expect(result.card.excerptSnapshot, isEmpty);
      expect(result.card.imageResourceId, isNull);
      expect(await repository.getAnchors(result.card.id), isEmpty);
    }
    final snapshot = await repository.loadMap(map.id);
    expect(
      snapshot.nodes.singleWhere((node) => node.id == first.node.id).x,
      first.node.x,
    );
    expect(
      snapshot.nodes.singleWhere((node) => node.id == second.node.id).y,
      second.node.y,
    );
    expect(snapshot.edges, isEmpty);
  });

  test('快捷主题创建与折叠父路径展开共用一次业务撤销，其他分支保持折叠', () async {
    final ancestor = await controller.addTheme('祖主题', parentNodeId: null);
    final parent = await controller.addTheme(
      '父主题',
      parentNodeId: ancestor.node.id,
    );
    final unrelated = await controller.addTheme('另一分支', parentNodeId: null);
    await repository.setNodeCollapsed(ancestor.node.id, true);
    await repository.setNodeCollapsed(parent.node.id, true);
    await repository.setNodeCollapsed(unrelated.node.id, true);
    await controller.refresh();
    controller.selectNode(unrelated.node);
    final historyBefore = repository.undoEntryCount;
    final created = await controller.addTheme(
      '沿显式父目标创建',
      parentNodeId: parent.node.id,
    );
    expect(repository.undoEntryCount, historyBefore + 1);
    final snapshot = await repository.loadMap(map.id);
    expect(
      snapshot.nodes
          .singleWhere((node) => node.id == ancestor.node.id)
          .collapsed,
      isFalse,
    );
    expect(
      snapshot.nodes.singleWhere((node) => node.id == parent.node.id).collapsed,
      isFalse,
    );
    expect(
      snapshot.nodes
          .singleWhere((node) => node.id == unrelated.node.id)
          .collapsed,
      isTrue,
    );
    expect(created.node.parentNodeId, parent.node.id);
    expect(controller.selectedNodeId, created.node.id);

    await repository.undo();
    await controller.refresh();
    final undone = await repository.loadMap(map.id);
    expect(undone.nodes.any((node) => node.id == created.node.id), isFalse);
    expect(
      (await repository.listCards(project.id))
          .any((card) => card.id == created.card.id),
      isFalse,
    );
    expect(
      undone.nodes.singleWhere((node) => node.id == ancestor.node.id).collapsed,
      isTrue,
    );
    expect(
      undone.nodes.singleWhere((node) => node.id == parent.node.id).collapsed,
      isTrue,
    );
    expect(controller.selectedNodeId, isNull);
    await repository.redo();
    final redone = await repository.loadMap(map.id);
    expect(
      redone.nodes.singleWhere((node) => node.id == created.node.id).cardId,
      created.card.id,
    );
    expect(
      redone.nodes.singleWhere((node) => node.id == ancestor.node.id).collapsed,
      isFalse,
    );
  });

  test('快捷主题提交期间切换脑图仍返回原结果，不反选新脑图中的不存在节点', () async {
    final destination = await repository.createMap(project.id, '切换后的脑图');
    await controller.refresh();
    final creating = controller.addTheme('原脑图中的新主题', parentNodeId: null);
    // selectMap 在首次 await 前推进代次；真实仓储仍完成已接受的创建。
    final switching = controller.selectMap(destination.id);
    await switching;
    final result = await creating;
    await controller.refresh();
    expect(result.node.mapId, map.id);
    expect((await repository.loadMap(map.id)).nodes.single.id, result.node.id);
    expect(controller.map!.map.id, destination.id);
    expect(controller.map!.nodes, isEmpty);
    expect(controller.selectedNodeId, isNull);
    expect(controller.selectedCardId, isNull);
  });

  test('文字拖入：显式空白落点不跟随当前选择，子目标一次创建来源与高亮且可撤销', () async {
    await repository.setMapLayout(map.id, MapLayoutKind.free);
    await controller.refresh();
    final root = await controller.addTheme(
      '当前选择',
      parentNodeId: null,
      x: 80,
      y: 80,
    );
    final document = await repository.importPdf(
      projectId: project.id,
      filePath: p.join(Directory.current.path, 'tools/fixtures/pdf/native.pdf'),
      pageCount: 2,
    );
    final layer = await repository.saveTextLayer(
      TextLayerDraft(
        revisionId: document.activeRevisionId,
        pageIndex: 0,
        source: TextLayerSource.nativePdf,
        text: '第一行  保留空格\n第二行',
        fragments: const [],
        engineVersion: 'test',
        parameters: const {},
      ),
      sessionId: repository.sessionId,
    );
    await controller.refresh();
    controller.selectNode(root.node);
    final excerpt = SelectedExcerpt(
      text: layer.text,
      anchors: [
        AnchorDraft(
          revisionId: document.activeRevisionId,
          pageIndex: 0,
          textLayerId: layer.id,
          textStart: 0,
          textEnd: layer.text.length,
          context: layer.text,
          quads: [PdfQuad.rect(10, 20, 80, 40)],
        ),
      ],
    );
    final history = repository.undoEntryCount;
    final top = await controller.addExcerptAt(
      excerpt,
      mapId: map.id,
      position: const PdfPoint(520, 310),
      parentNodeId: null,
    );
    expect(top.node.parentNodeId, isNull);
    expect(top.node.x, 520);
    expect(top.node.y, 310);
    expect(top.card.body, layer.text);
    expect(repository.undoEntryCount, history + 1);
    final child = await controller.addExcerptAt(
      excerpt,
      mapId: map.id,
      position: const PdfPoint(730, 480),
      parentNodeId: root.node.id,
    );
    expect(child.node.parentNodeId, root.node.id);
    expect(child.node.x, 730);
    expect(child.node.y, 480);
    expect(controller.selectedNodeId, child.node.id);
    expect(repository.undoEntryCount, history + 2);
    final anchors = await repository.getAnchors(child.card.id);
    expect(anchors.single.textLayerId, layer.id);
    expect(anchors.single.textStart, 0);
    expect(anchors.single.textEnd, layer.text.length);
    expect(
      (await repository.listAnnotations(document.activeRevisionId))
          .where((a) => a.cardId == child.card.id),
      hasLength(1),
    );
    await repository.undo();
    expect(
      (await repository.loadMap(map.id)).nodes
          .any((n) => n.id == child.node.id),
      isFalse,
    );
    expect(
      (await repository.listAnnotations(document.activeRevisionId))
          .any((a) => a.cardId == child.card.id),
      isFalse,
    );
    final secondLayer = await repository.saveTextLayer(
      TextLayerDraft(
        revisionId: document.activeRevisionId,
        pageIndex: 1,
        source: TextLayerSource.nativePdf,
        text: '跨页末行',
        fragments: const [],
        engineVersion: 'test',
        parameters: const {},
      ),
      sessionId: repository.sessionId,
    );
    final beforeAcross = repository.undoEntryCount;
    final across = await controller.addExcerptAt(
      SelectedExcerpt(
        text: '${layer.text}\n${secondLayer.text}',
        anchors: [
          excerpt.anchors.single,
          AnchorDraft(
            revisionId: document.activeRevisionId,
            pageIndex: 1,
            textLayerId: secondLayer.id,
            textStart: 0,
            textEnd: secondLayer.text.length,
            context: secondLayer.text,
            quads: [PdfQuad.rect(10, 20, 80, 40)],
          ),
        ],
      ),
      mapId: map.id,
      position: const PdfPoint(300, 300),
      parentNodeId: null,
    );
    expect(repository.undoEntryCount, beforeAcross + 1);
    expect(
      (await repository.getAnchors(across.card.id)).map((a) => a.pageIndex),
      [0, 1],
    );
    expect(
      (await repository.listAnnotations(document.activeRevisionId))
          .where((a) => a.cardId == across.card.id),
      hasLength(2),
    );
    await repository.undo();
    expect(
      (await repository.listCards(project.id))
          .any((c) => c.id == across.card.id),
      isFalse,
    );
    expect(
      (await repository.listAnnotations(document.activeRevisionId))
          .any((a) => a.cardId == across.card.id),
      isFalse,
    );
  });

  test('文字拖入：已提交结果遇到新会话意图，不抢占当前卡片选择', () async {
    final root = await controller.addTheme('保留当前选择', parentNodeId: null);
    final history = repository.undoEntryCount;
    final inserted = await controller.addExcerptAt(
      const SelectedExcerpt(text: '已接受的拖入', anchors: []),
      mapId: map.id,
      position: const PdfPoint(300, 300),
      parentNodeId: null,
      selectionIsCurrent: () => false,
    );
    expect(
      (await repository.loadMap(map.id)).nodes
          .any((n) => n.id == inserted.node.id),
      isTrue,
    );
    expect(controller.selectedNodeId, root.node.id);
    expect(controller.selectedCardId, root.card.id);
    expect(repository.undoEntryCount, history + 1);
  });

  test('文字拖入：失效脑图或已删除父级拒绝创建，不留下卡片、高亮或撤销记录', () async {
    final root = await controller.addTheme('将被移除的目标', parentNodeId: null);
    await repository.removeTopicOnly(root.node.id);
    await controller.refresh();
    final before = await repository.loadMap(map.id);
    final history = repository.undoEntryCount;
    const excerpt = SelectedExcerpt(text: '不能错误落到顶层', anchors: []);
    expect(
      () => controller.addExcerptAt(
        excerpt,
        mapId: 'stale-map',
        position: const PdfPoint(0, 0),
        parentNodeId: null,
      ),
      throwsStateError,
    );
    await expectLater(
      controller.addExcerptAt(
        excerpt,
        mapId: map.id,
        position: const PdfPoint(0, 0),
        parentNodeId: root.node.id,
      ),
      throwsA(isA<RepositoryException>()),
    );
    final after = await repository.loadMap(map.id);
    expect(after.nodes.length, before.nodes.length);
    expect(after.cards.keys, before.cards.keys);
    expect(repository.undoEntryCount, history);
  });

  test('PDF摘录折行整理：正文和标题完整，旧卡片、来源、高亮与撤销保留', () async {
    final document = await repository.importPdf(
      projectId: project.id,
      filePath: p.join(Directory.current.path, 'tools', 'fixtures', 'pdf', 'native.pdf'),
      pageCount: 2,
    );
    final rows = [
      '感到焦虑的人会反复疑虑和沉思。对即将发生的负',
      '面事件的疑虑趋向被称为忧虑。焦虑也连带一些不适的生理反应。',
      '这些感觉让人不安。',
    ];
    final raw = rows.join('\n');
    final fragments = <TextFragment>[];
    var offset = 0;
    for (var index = 0; index < rows.length; index++) {
      fragments.add(TextFragment(start: offset, length: rows[index].length,
        quad: PdfQuad.rect(40, 680 - index * 20,
            index == 2 ? 170 : 340, 692 - index * 20),
        order: index, precision: GeometryPrecision.line,
      ));
      offset += rows[index].length + 1;
    }
    final savedLayer = await repository.saveTextLayer(TextLayerDraft(
      revisionId: document.activeRevisionId, pageIndex: 0,
      source: TextLayerSource.ocr, text: raw, fragments: fragments,
      engineVersion: 'fixture',
      parameters: const {'writingDirection': 'horizontalLtr'},
    ), sessionId: repository.sessionId);
    final layer = PdfSelectableText.fromPersisted(savedLayer);
    final start = raw.indexOf('对即将'), end = raw.indexOf('忧虑。') + 3;
    final anchors = selectTextAcrossPages(
      revisionId: document.activeRevisionId,
      a: PdfSelectionPoint(0, start, start + 1),
      b: PdfSelectionPoint(0, end - 1, end), layerForPage: (_) => layer,
    );
    final original = anchors.single.context;
    final old = await repository.createExcerpt(ExcerptDraft(
      projectId: project.id, mapId: map.id, title: '旧摘录',
      text: original, anchors: anchors,
    ));
    final text = formatPdfExcerptText(anchors: anchors, layerForPage: (_) => layer,
      geometryForPage: (_) => PdfPageGeometry(pageIndex: 0,
        cropBox: PdfQuad.rect(0, 0, 600, 800),
        mediaBox: PdfQuad.rect(0, 0, 600, 800),
      ),
    );
    expect(text, '对即将发生的负面事件的疑虑趋向被称为忧虑。');
    await controller.refresh();
    final excerpt = SelectedExcerpt(text: text, anchors: anchors);
    await controller.addExcerpt(excerpt);
    final buttonCardId = controller.selectedCardId!;
    final dropped = await controller.addExcerptAt(excerpt, mapId: map.id,
      position: const PdfPoint(600, 80), parentNodeId: null,
    );
    final snapshot = await repository.loadMap(map.id);
    for (final id in [buttonCardId, dropped.card.id]) {
      final card = snapshot.cards[id]!;
      expect(card.body, text);
      expect(card.excerptSnapshot, text);
      expect(card.title, text);
      final savedAnchor = (await repository.getAnchors(id)).single;
      expect(savedAnchor.context, original);
      expect(savedAnchor.textLayerId, savedLayer.id);
      expect(savedAnchor.textStart, start);
      expect(savedAnchor.textEnd, end);
      expect(savedAnchor.quads.map((q) => q.toJson()),
          anchors.single.quads.map((q) => q.toJson()));
      expect((await repository.listAnnotations(document.activeRevisionId))
          .where((a) => a.cardId == id), hasLength(1));
    }
    expect(snapshot.cards[old.card.id]!.body, original);
    expect(snapshot.cards[old.card.id]!.title, '旧摘录');
    expect((await repository.loadTextLayers(document.activeRevisionId)).single.text, raw);
    await repository.undo();
    expect((await repository.loadMap(map.id)).cards.containsKey(dropped.card.id), isFalse);
    await repository.redo();
    expect((await repository.loadMap(map.id)).cards[dropped.card.id]!.body, text);
  });

  test('PDF摘录沿用当前选中父与自由布局，原文锚点高亮和标题规则不变', () async {
    await repository.setMapLayout(map.id, MapLayoutKind.free);
    await controller.refresh();
    final root = await controller.addTheme(
      'PDF 摘录父主题',
      parentNodeId: null,
      x: 130,
      y: 230,
    );
    await controller.addTheme('已有子主题', parentNodeId: root.node.id);
    final document = await repository.importPdf(
      projectId: project.id,
      filePath: p.join(
        Directory.current.path,
        'tools',
        'fixtures',
        'pdf',
        'native.pdf',
      ),
      pageCount: 2,
    );
    await controller.refresh();
    controller.selectNode(root.node);
    const text = '第一行\n第二行';
    await controller.addExcerpt(
      SelectedExcerpt(
        text: text,
        anchors: [
          AnchorDraft(
            revisionId: document.activeRevisionId,
            pageIndex: 0,
            quads: [PdfQuad.rect(10, 20, 40, 50)],
          ),
        ],
      ),
    );
    final snapshot = await repository.loadMap(map.id);
    final node = snapshot.nodes.singleWhere(
      (node) => node.id == controller.selectedNodeId,
    );
    final card = snapshot.cards[node.cardId]!;
    expect(node.parentNodeId, root.node.id);
    expect(node.x, 420);
    expect(node.y, 370);
    expect(card.title, '第一行');
    expect(card.body, text);
    expect(card.excerptSnapshot, text);
    expect(
      (await repository.getAnchors(card.id)).single.revisionId,
      document.activeRevisionId,
    );
    expect(
      (await repository.listAnnotations(document.activeRevisionId))
          .single
          .cardId,
      card.id,
    );
    controller.selectedNodeId = null;
    await controller.addExcerpt(
      SelectedExcerpt(text: '顶层摘录', anchors: const []),
    );
    final topLevel = (await repository.loadMap(map.id)).nodes
        .singleWhere((node) => node.id == controller.selectedNodeId);
    expect(topLevel.parentNodeId, isNull);
    expect(topLevel.x, 80);
    expect(topLevel.y, 230);
  });

  test('多选切换成员与主选按加入顺序保持一致，只读快照不产生业务历史', () async {
    final first = await controller.addTheme('多选 A', parentNodeId: null);
    final second = await controller.addTheme('多选 B', parentNodeId: null);
    final third = await controller.addTheme('多选 C', parentNodeId: null);
    final historyBefore = repository.undoEntryCount;
    controller.selectNode(first.node);
    controller.selectNode(second.node, additive: true);
    final captured = controller.selectedNodeIds;
    controller.selectNode(third.node, additive: true);
    expect(controller.selectedNodeIds.toList(), [
      first.node.id,
      second.node.id,
      third.node.id,
    ]);
    expect(controller.selectedNodeId, third.node.id);
    expect(controller.selectedCardId, third.card.id);
    expect(captured.toList(), [first.node.id, second.node.id]);
    expect(() => captured.add(third.node.id), throwsA(isA<UnsupportedError>()));

    controller.selectNode(second.node, additive: true);
    expect(controller.selectedNodeIds.toList(), [first.node.id, third.node.id]);
    expect(controller.selectedNodeId, third.node.id);
    controller.selectNode(second.node, additive: true);
    expect(controller.selectedNodeId, second.node.id);
    expect(controller.selectedCardId, second.card.id);
    controller.selectNode(second.node, additive: true);
    expect(controller.selectedNodeId, third.node.id);
    expect(controller.selectedCardId, third.card.id);
    controller.selectNode(third.node, additive: true);
    expect(controller.selectedNodeId, first.node.id);
    expect(controller.selectedCardId, first.card.id);
    controller.selectNode(first.node, additive: true);
    expect(controller.selectedNodeIds, isEmpty);
    expect(controller.selectedNodeId, isNull);
    expect(controller.selectedCardId, isNull);
    expect(repository.undoEntryCount, historyBefore);
  });

  test('多选的单选赋值、项目卡选择与新主题创建同步唯一选择集合', () async {
    final first = await controller.addTheme('选择 A', parentNodeId: null);
    final second = await controller.addTheme('选择 B', parentNodeId: null);
    controller.selectNode(first.node);
    controller.selectNode(second.node, additive: true);
    controller.selectedNodeId = first.node.id;
    expect(controller.selectedNodeIds, {first.node.id});
    expect(controller.selectedCardId, first.card.id);
    controller.selectNode(second.node, additive: true);
    controller.selectNode(first.node);
    expect(controller.selectedNodeIds, {first.node.id});
    expect(controller.selectedCardId, first.card.id);

    controller.selectNode(second.node, additive: true);
    controller.selectCard(first.card);
    expect(controller.selectedNodeIds, {first.node.id});
    expect(controller.selectedNodeId, first.node.id);
    expect(controller.selectedCardId, first.card.id);
    await repository.removeBranch(second.node.id);
    await controller.refresh();
    controller.selectCard(await repository.getCard(second.card.id));
    expect(controller.selectedNodeIds, isEmpty);
    expect(controller.selectedNodeId, isNull);
    expect(controller.selectedCardId, second.card.id);
    expect(controller.selectedCard!.id, second.card.id);

    controller.selectNode(first.node);
    final created = await controller.addTheme('创建后只选新主题', parentNodeId: null);
    expect(controller.selectedNodeIds, {created.node.id});
    expect(controller.selectedNodeId, created.node.id);
    expect(controller.selectedCardId, created.card.id);
    controller.selectedNodeId = null;
    expect(controller.selectedNodeIds, isEmpty);
    expect(controller.selectedNodeId, isNull);
    expect(controller.selectedCardId, isNull);
  });

  test('多选同图刷新保留折叠后代，移除失效主选后回退有效节点并拒绝旧事件', () async {
    final root = await controller.addTheme('折叠父主题', parentNodeId: null);
    final child = await controller.addTheme(
      '折叠下仍选中的主题',
      parentNodeId: root.node.id,
    );
    final other = await controller.addTheme('即将移除的主选', parentNodeId: null);
    controller.selectNode(child.node);
    controller.selectNode(other.node, additive: true);
    await repository.setNodeCollapsed(root.node.id, true);
    await controller.refresh();
    expect(
      controller.map!.nodes.singleWhere((n) => n.id == root.node.id).collapsed,
      isTrue,
    );
    expect(controller.selectedNodeIds.toList(), [child.node.id, other.node.id]);
    expect(controller.selectedNodeId, other.node.id);

    await repository.removeBranch(other.node.id);
    await controller.refresh();
    expect(controller.selectedNodeIds, {child.node.id});
    expect(controller.selectedNodeId, child.node.id);
    expect(controller.selectedCardId, child.card.id);
    controller.selectNode(other.node, additive: true);
    expect(controller.selectedNodeIds, {child.node.id});
    expect(controller.selectedNodeId, child.node.id);
    await repository.removeBranch(child.node.id);
    await controller.refresh();
    expect(controller.selectedNodeIds, isEmpty);
    expect(controller.selectedNodeId, isNull);
  });

  test('多选切图切项目及工作区清理不继承集合，旧图节点事件不污染新选择', () async {
    final first = await controller.addTheme('旧图 A', parentNodeId: null);
    final second = await controller.addTheme('旧图 B', parentNodeId: null);
    final destination = await repository.createMap(project.id, '另一张图');
    await controller.refresh();
    controller.selectNode(first.node);
    controller.selectNode(second.node, additive: true);
    await controller.selectMap(destination.id);
    expect(controller.selectedNodeIds, isEmpty);
    expect(controller.selectedNodeId, isNull);
    expect(controller.selectedCardId, isNull);
    final destinationTheme = await controller.addTheme(
      '新图主题',
      parentNodeId: null,
    );
    controller.selectNode(first.node, additive: true);
    expect(controller.selectedNodeIds, {destinationTheme.node.id});
    expect(controller.selectedNodeId, destinationTheme.node.id);
    expect(controller.selectedCardId, destinationTheme.card.id);

    await controller.selectMap(map.id);
    expect(controller.selectedNodeIds, isEmpty);
    controller.selectNode(first.node);
    controller.selectNode(second.node, additive: true);
    final otherProject = await repository.createProject('另一学习项目');
    await controller.selectProject(otherProject);
    expect(controller.selectedNodeIds, isEmpty);
    expect(controller.selectedNodeId, isNull);
    expect(controller.selectedCardId, isNull);
    controller.selectNode(first.node);
    expect(controller.selectedNodeIds, isEmpty);
    final otherTheme = await controller.addTheme('其他项目主题', parentNodeId: null);
    expect(controller.selectedNodeIds, {otherTheme.node.id});
    controller.clearWorkspace();
    expect(controller.selectedNodeIds, isEmpty);
    expect(controller.selectedNodeId, isNull);
    expect(controller.selectedCardId, isNull);
  });

  test('多选当前脑图回收后的刷新切换备用图并清空旧卡选择', () async {
    final first = await controller.addTheme('待回收图 A', parentNodeId: null);
    final second = await controller.addTheme('待回收图 B', parentNodeId: null);
    final destination = await repository.createMap(project.id, '备用脑图');
    await controller.refresh();
    controller.selectNode(first.node);
    controller.selectNode(second.node, additive: true);
    await repository.trashMap(map.id);
    await controller.refresh();
    expect(controller.map!.map.id, destination.id);
    expect(controller.selectedNodeIds, isEmpty);
    expect(controller.selectedNodeId, isNull);
    expect(controller.selectedCardId, isNull);
    expect((await repository.listCards(project.id)).length, 2);
  });

  test('多选完整备份恢复后的新会话即使节点身份相同也不继承旧选择', () async {
    final first = await controller.addTheme('恢复后身份 A', parentNodeId: null);
    final second = await controller.addTheme('恢复后身份 B', parentNodeId: null);
    final backupPath = p.join(temp.path, '选择会话回归.opennote');
    await repository.backupTo(backupPath);
    controller.selectNode(first.node);
    controller.selectNode(second.node, additive: true);
    final oldSession = repository.sessionId;
    await repository.restoreFrom(backupPath);
    expect(repository.sessionId, isNot(oldSession));
    await controller.refresh();
    expect(controller.map!.map.id, map.id);
    expect(controller.map!.nodes.map((node) => node.id).toSet(), {
      first.node.id,
      second.node.id,
    });
    expect(controller.selectedNodeIds, isEmpty);
    expect(controller.selectedNodeId, isNull);
    expect(controller.selectedCardId, isNull);
  });
}
