import 'dart:io';

import 'package:drift/isolate.dart' show DriftRemoteException;
import 'package:flutter_test/flutter_test.dart';
import 'package:opennote/data/open_note_repository.dart';
import 'package:opennote/domain/models.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late OpenNoteRepository repository;
  late StudyProject project;
  late MindMap map;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('opennote-batch-');
    repository = await OpenNoteRepository.open(
      rootPath: p.join(temp.path, 'library'),
    );
    project = await repository.createProject('批量操作项目');
    map = (await repository.listMaps(project.id)).single;
  });

  tearDown(() async {
    await repository.close();
    await temp.delete(recursive: true);
  });

  Future<ExcerptResult> excerpt(
    String title, {
    String? parent,
    String? mapId,
  }) => repository.createExcerpt(
    ExcerptDraft(
      projectId: project.id,
      mapId: mapId ?? map.id,
      title: title,
      text: '$title 正文',
      note: '$title 备注',
      parentNodeId: parent,
    ),
  );

  test('批量折叠保留显式后代状态，一次撤销重做恢复完整选择', () async {
    final root = await excerpt('父主题');
    final child = await excerpt('子主题', parent: root.node.id);
    final grandchild = await excerpt('孙主题', parent: child.node.id);
    final other = await excerpt('未选主题');
    final before = _persistedRows(repository);
    final historyBefore = repository.undoEntryCount;

    await repository.setNodesCollapsed(map.id, [
      root.node.id,
      child.node.id,
      root.node.id,
    ], true);

    final snapshot = await repository.loadMap(map.id);
    final collapsed = {
      for (final node in snapshot.nodes) node.id: node.collapsed,
    };
    expect(collapsed[root.node.id], isTrue);
    expect(collapsed[child.node.id], isTrue);
    expect(collapsed[grandchild.node.id], isFalse);
    expect(collapsed[other.node.id], isFalse);
    expect(repository.undoEntryCount, historyBefore + 1);
    final after = _persistedRows(repository);

    await repository.undo();
    expect(_persistedRows(repository), before);
    await repository.redo();
    expect(_persistedRows(repository), after);
  });

  test('Xmind 递归折叠：最新根状态决定整棵分支，一次撤销并保留其他分支', () async {
    final root = await excerpt('父主题');
    final child = await excerpt('子主题', parent: root.node.id);
    final grandchild = await excerpt('孙主题', parent: child.node.id);
    final other = await excerpt('另一分支');
    final otherChild = await excerpt('另一子主题', parent: other.node.id);
    await repository.setNodeCollapsed(child.node.id, true);
    final before = _persistedRows(repository);
    final history = repository.undoEntryCount;
    await repository.toggleNodeBranchCollapsed(root.node.id);
    var snapshot = await repository.loadMap(map.id);
    bool folded(String id) =>
        snapshot.nodes.singleWhere((n) => n.id == id).collapsed;
    expect(folded(root.node.id), isTrue);
    expect(folded(child.node.id), isTrue);
    expect(folded(grandchild.node.id), isFalse);
    expect(folded(other.node.id), isFalse);
    expect(folded(otherChild.node.id), isFalse);
    expect(repository.undoEntryCount, history + 1);
    final after = _persistedRows(repository);
    await repository.undo();
    expect(_persistedRows(repository), before);
    await repository.redo();
    expect(_persistedRows(repository), after);
    await repository.toggleNodeBranchCollapsed(root.node.id);
    snapshot = await repository.loadMap(map.id);
    expect(snapshot.nodes.every((n) => !n.collapsed), isTrue);
    await repository.toggleNodeBranchCollapsed(grandchild.node.id);
    expect(repository.undoEntryCount, history + 2);
    await repository.close();
    repository = await OpenNoteRepository.open(
      rootPath: p.join(temp.path, 'library'),
    );
    expect(
      (await repository.loadMap(map.id)).nodes.every((n) => !n.collapsed),
      isTrue,
    );
  });

  test('Xmind 递归折叠：深层写入失败完整回滚，不留下撤销项', () async {
    final root = await excerpt('父主题');
    final child = await excerpt('子主题', parent: root.node.id);
    await excerpt('孙主题', parent: child.node.id);
    final before = _persistedRows(repository);
    final history = repository.undoEntryCount;
    _executeSql(
      repository,
      "CREATE TRIGGER reject_recursive_fold BEFORE UPDATE OF collapsed ON nodes "
      "WHEN OLD.id='${child.node.id}' BEGIN SELECT RAISE(ABORT,'拒绝折叠'); END",
    );
    await expectLater(
      repository.toggleNodeBranchCollapsed(root.node.id),
      throwsA(
        isA<DriftRemoteException>().having(
          (error) => error.remoteCause,
          'remoteCause',
          isA<SqliteException>().having(
            (error) => error.message,
            'message',
            contains('拒绝折叠'),
          ),
        ),
      ),
    );
    expect(_persistedRows(repository), before);
    expect(repository.undoEntryCount, history);
  });

  test('批量颜色只修改精确选中卡片，正文关系和未选后代不变', () async {
    final root = await excerpt('父卡片');
    final child = await excerpt('选中子卡片', parent: root.node.id);
    final grandchild = await excerpt('未选孙卡片', parent: child.node.id);
    final other = await excerpt('另一根卡片');
    await repository.addAssociation(child.node.id, other.node.id);
    final before = _persistedRows(repository);
    final historyBefore = repository.undoEntryCount;

    await repository.setCardsColor(map.id, [
      root.node.id,
      child.node.id,
      other.node.id,
      root.node.id,
    ], '#80B9EB');

    for (final cardId in [root.card.id, child.card.id, other.card.id]) {
      expect((await repository.getCard(cardId)).color, '#80B9EB');
    }
    expect((await repository.getCard(grandchild.card.id)).color, '#F7D976');
    final after = _persistedRows(repository);
    expect(_withoutCardStyle(after), _withoutCardStyle(before));
    expect(
      after['cards']!.singleWhere((row) => row['id'] == grandchild.card.id),
      before['cards']!.singleWhere((row) => row['id'] == grandchild.card.id),
    );
    expect(repository.undoEntryCount, historyBefore + 1);
    await repository.undo();
    expect(_persistedRows(repository), before);
    await repository.redo();
    expect(_persistedRows(repository), after);
  });

  test('批量移除规范化父子根并含折叠后代，卡片及外部关联保留', () async {
    final root = await excerpt('第一根');
    final child = await excerpt('折叠子主题', parent: root.node.id);
    final grandchild = await excerpt('隐藏孙主题', parent: child.node.id);
    final historical = await excerpt('回收站旧位置', parent: root.node.id);
    final second = await excerpt('第二根');
    await excerpt('第二根子主题', parent: second.node.id);
    final outside = await excerpt('保留根');
    final outsideChild = await excerpt('保留子主题', parent: outside.node.id);
    await repository.trashCard(historical.card.id);
    await repository.setNodeCollapsed(root.node.id, true);
    await repository.setNodeCollapsed(child.node.id, true);
    await repository.addAssociation(root.node.id, grandchild.node.id);
    await repository.addAssociation(child.node.id, second.node.id);
    await repository.addAssociation(grandchild.node.id, outside.node.id);
    final remainingEdge = await repository.addAssociation(
      outside.node.id,
      outsideChild.node.id,
    );
    final before = _persistedRows(repository);
    final historyBefore = repository.undoEntryCount;

    await repository.removeBranches(map.id, [
      child.node.id,
      root.node.id,
      second.node.id,
      root.node.id,
    ]);

    final snapshot = await repository.loadMap(map.id);
    expect(snapshot.nodes.map((node) => node.id).toSet(), {
      outside.node.id,
      outsideChild.node.id,
    });
    expect(snapshot.edges.single.id, remainingEdge.id);
    final after = _persistedRows(repository);
    expect(after['cards'], before['cards']);
    expect(after['trash'], before['trash']);
    final historicalRow = after['nodes']!.singleWhere(
      (row) => row['id'] == historical.node.id,
    );
    expect(historicalRow['parent_node_id'], isNull);
    expect(repository.undoEntryCount, historyBefore + 1);
    await repository.undo();
    expect(_persistedRows(repository), before);
    await repository.redo();
    expect(_persistedRows(repository), after);
  });

  test('全部批量输入先验证，缺失回收或跨图目标不改变数据及撤销重做', () async {
    final root = await excerpt('有效目标');
    final deleted = await excerpt('已回收目标', parent: root.node.id);
    await repository.trashCard(deleted.card.id);
    final otherMap = await repository.createMap(project.id, '另一脑图');
    final foreign = await excerpt('跨图目标', mapId: otherMap.id);
    await repository.renameMap(map.id, '用于建立重做');
    await repository.undo();
    final before = _persistedRows(repository);
    final undoBefore = repository.undoEntryCount;
    final redoBefore = repository.redoEntryCount;
    final commands = <Future<void> Function(List<String>)>[
      (ids) => repository.setNodesCollapsed(map.id, ids, true),
      (ids) => repository.setCardsColor(map.id, ids, '#91C69A'),
      (ids) => repository.removeBranches(map.id, ids),
    ];
    final invalidTargets = [
      ('不存在的节点', RepositoryError.notFound),
      (deleted.node.id, RepositoryError.notFound),
      (foreign.node.id, RepositoryError.invalidInput),
    ];
    for (final command in commands) {
      for (final invalid in invalidTargets) {
        await expectLater(
          command([root.node.id, root.node.id, invalid.$1]),
          throwsA(
            isA<RepositoryException>().having(
              (error) => error.code,
              'code',
              invalid.$2,
            ),
          ),
        );
        expect(_persistedRows(repository), before);
        expect(repository.undoEntryCount, undoBefore);
        expect(repository.redoEntryCount, redoBefore);
      }
    }
  });

  test('空选择和相同折叠颜色不产生历史通知且保留重做', () async {
    final root = await excerpt('无变化目标');
    await repository.renameMap(map.id, '建立重做');
    await repository.undo();
    await Future<void>.delayed(Duration.zero);
    final before = _persistedRows(repository);
    final undoBefore = repository.undoEntryCount;
    final redoBefore = repository.redoEntryCount;
    final changes = <int>[];
    final subscription = repository.changes.listen(changes.add);
    try {
      await repository.setNodesCollapsed(map.id, [root.node.id], false);
      await repository.setCardsColor(map.id, [root.node.id], root.card.color);
      await repository.setNodesCollapsed(map.id, const [], true);
      await repository.setCardsColor(map.id, const [], '#EB8C91');
      await repository.removeBranches(map.id, const []);
      await Future<void>.delayed(Duration.zero);
      expect(_persistedRows(repository), before);
      expect(repository.undoEntryCount, undoBefore);
      expect(repository.redoEntryCount, redoBefore);
      expect(changes, isEmpty);
    } finally {
      await subscription.cancel();
    }
  });

  test('批量目标脑图或所属项目回收后拒绝修改', () async {
    final root = await excerpt('有效节点');
    final commands = <Future<void> Function()>[
      () => repository.setNodesCollapsed(map.id, [root.node.id], true),
      () => repository.setCardsColor(map.id, [root.node.id], '#EB8C91'),
      () => repository.removeBranches(map.id, [root.node.id]),
    ];
    await repository.trashMap(map.id);
    for (final command in commands) {
      final before = _persistedRows(repository);
      final historyBefore = repository.undoEntryCount;
      await expectLater(command(), throwsA(_notFound));
      expect(_persistedRows(repository), before);
      expect(repository.undoEntryCount, historyBefore);
    }
    await repository.undo();
    await repository.trashProject(project.id);
    for (final command in commands) {
      final before = _persistedRows(repository);
      final historyBefore = repository.undoEntryCount;
      await expectLater(command(), throwsA(_notFound));
      expect(_persistedRows(repository), before);
      expect(repository.undoEntryCount, historyBefore);
    }
  });

  test('SQLite中途拒绝写入时三个批量命令整体回滚且不消耗历史', () async {
    final root = await excerpt('先写入目标');
    final child = await excerpt('后代', parent: root.node.id);
    final second = await excerpt('后写入目标');
    await repository.addAssociation(child.node.id, second.node.id);
    await repository.renameMap(map.id, '建立重做');
    await repository.undo();
    final before = _persistedRows(repository);
    final undoBefore = repository.undoEntryCount;
    final redoBefore = repository.redoEntryCount;
    final commands = <({String trigger, Future<void> Function() run})>[
      (
        trigger:
            "BEFORE UPDATE OF collapsed ON nodes WHEN OLD.id='${second.node.id}'",
        run: () => repository.setNodesCollapsed(map.id, [
          root.node.id,
          second.node.id,
        ], true),
      ),
      (
        trigger:
            "BEFORE UPDATE OF color ON cards WHEN OLD.id='${second.card.id}'",
        run: () => repository.setCardsColor(map.id, [
          root.node.id,
          second.node.id,
        ], '#B7A0DD'),
      ),
      (
        trigger: "BEFORE DELETE ON nodes WHEN OLD.id='${root.node.id}'",
        run: () => repository.removeBranches(map.id, [root.node.id]),
      ),
    ];
    for (final command in commands) {
      _executeSql(
        repository,
        'CREATE TRIGGER batch_failure ${command.trigger} '
        "BEGIN SELECT RAISE(ABORT, '真实批量中途失败'); END",
      );
      try {
        // 真实后台数据库保留原 SQLite 异常，并通过 Drift 的远端包装返回。
        await expectLater(
          command.run(),
          throwsA(
            isA<DriftRemoteException>().having(
              (error) => error.remoteCause,
              'remoteCause',
              isA<SqliteException>()
                  .having(
                    (error) => error.extendedResultCode,
                    'extendedResultCode',
                    1811,
                  )
                  .having((error) => error.resultCode, 'resultCode', 19)
                  .having(
                    (error) => error.message,
                    'message',
                    contains('真实批量中途失败'),
                  ),
            ),
          ),
        );
        expect(_persistedRows(repository), before);
        expect(repository.undoEntryCount, undoBefore);
        expect(repository.redoEntryCount, redoBefore);
      } finally {
        _executeSql(repository, 'DROP TRIGGER batch_failure');
      }
    }
  });

  test('批量命令捕获调用时选择，等待期间修改集合不替换目标', () async {
    final first = await excerpt('第一目标');
    final second = await excerpt('第二目标');
    final otherMap = await repository.createMap(project.id, '另一脑图');
    final foreign = await excerpt('后续选择', mapId: otherMap.id);
    final selected = [first.node.id, second.node.id];
    final operation = repository.setNodesCollapsed(map.id, selected, true);
    selected
      ..clear()
      ..add(foreign.node.id);
    await operation;
    expect(
      (await repository.loadMap(map.id)).nodes.every((node) => node.collapsed),
      isTrue,
    );
    expect(
      (await repository.loadMap(otherMap.id)).nodes.single.collapsed,
      isFalse,
    );
  });

  test('布局批量契约捕获调用目标与坐标，原Map变化不影响单次撤销重做', () async {
    final root = await excerpt('布局父目标');
    final child = await excerpt('布局子目标', parent: root.node.id);
    final other = await excerpt('后续未选目标');
    final association = await repository.addAssociation(
      child.node.id,
      other.node.id,
    );
    final before = _persistedRows(repository);
    final historyBefore = repository.undoEntryCount;
    final positions = <String, PdfPoint>{
      root.node.id: const PdfPoint(101, 201),
      child.node.id: const PdfPoint(301, 401),
    };

    final operation = repository.layoutNodes(map.id, positions);
    // 同一同步片段修改调用方 Map，仓储必须仍提交调用时的完整布局。
    positions
      ..clear()
      ..[other.node.id] = const PdfPoint(701, 801);
    await operation;

    final snapshot = await repository.loadMap(map.id);
    final nodes = {for (final node in snapshot.nodes) node.id: node};
    expect(nodes[root.node.id]!.x, 101);
    expect(nodes[root.node.id]!.y, 201);
    expect(nodes[child.node.id]!.x, 301);
    expect(nodes[child.node.id]!.y, 401);
    expect(nodes[child.node.id]!.parentNodeId, root.node.id);
    expect(nodes[root.node.id]!.parentNodeId, isNull);
    expect(nodes[other.node.id]!.x, other.node.x);
    expect(nodes[other.node.id]!.y, other.node.y);
    expect(snapshot.edges.single.id, association.id);
    expect(repository.undoEntryCount, historyBefore + 1);
    final after = _persistedRows(repository);

    // 已提交命令及撤销内容同样不能继续引用调用方的可变容器。
    positions
      ..clear()
      ..['不存在的后续目标'] = const PdfPoint(double.nan, double.infinity);
    expect(repository.undoEntryCount, historyBefore + 1);
    await repository.undo();
    expect(_persistedRows(repository), before);
    expect(repository.undoEntryCount, historyBefore);
    await repository.redo();
    expect(_persistedRows(repository), after);
    expect(repository.undoEntryCount, historyBefore + 1);
  });

  test('布局批量契约拒绝回收项目，保留原坐标及撤销重做和变更通知', () async {
    final root = await excerpt('回收项目内的布局目标');
    final child = await excerpt('回收项目内的子目标', parent: root.node.id);
    final activeProject = await repository.createProject('建立真实重做的有效项目');
    await repository.trashProject(project.id);
    await repository.renameProject(activeProject.id, '临时项目名称');
    await repository.undo();
    await Future<void>.delayed(Duration.zero);
    final before = _persistedRows(repository);
    final undoBefore = repository.undoEntryCount;
    final redoBefore = repository.redoEntryCount;
    expect(redoBefore, greaterThan(0));
    final changes = <int>[];
    final subscription = repository.changes.listen(changes.add);
    try {
      await expectLater(
        repository.layoutNodes(map.id, {
          root.node.id: const PdfPoint(900, 1000),
          child.node.id: const PdfPoint(1100, 1200),
        }),
        throwsA(_notFound),
      );
      await Future<void>.delayed(Duration.zero);
      final after = _persistedRows(repository);
      expect(after, before);
      for (final node in [root.node, child.node]) {
        final row = after['nodes']!.singleWhere((row) => row['id'] == node.id);
        expect(row['x'], node.x);
        expect(row['y'], node.y);
        expect(row['parent_node_id'], node.parentNodeId);
      }
      expect(repository.undoEntryCount, undoBefore);
      expect(repository.redoEntryCount, redoBefore);
      expect(changes, isEmpty);
    } finally {
      await subscription.cancel();
    }
  });
}

final _notFound = isA<RepositoryException>().having(
  (error) => error.code,
  'code',
  RepositoryError.notFound,
);

Map<String, List<Map<String, Object?>>> _persistedRows(
  OpenNoteRepository repository,
) {
  final database = sqlite3.open(
    p.join(repository.libraryPath, 'library.sqlite'),
    mode: OpenMode.readOnly,
  );
  try {
    return {
      for (final table in [
        'projects',
        'maps',
        'cards',
        'nodes',
        'edges',
        'anchors',
        'trash',
      ])
        table: database
            .select('SELECT * FROM $table ORDER BY id')
            .map((row) => Map<String, Object?>.from(row))
            .toList(),
    };
  } finally {
    database.close();
  }
}

Map<String, List<Map<String, Object?>>> _withoutCardStyle(
  Map<String, List<Map<String, Object?>>> rows,
) => {
  for (final table in rows.entries)
    table.key: [
      for (final row in table.value)
        {
          for (final field in row.entries)
            if (table.key != 'cards' ||
                (field.key != 'color' && field.key != 'updated_at'))
              field.key: field.value,
        },
    ],
};

void _executeSql(OpenNoteRepository repository, String statement) {
  final database = sqlite3.open(
    p.join(repository.libraryPath, 'library.sqlite'),
  );
  try {
    database.execute(statement);
  } finally {
    database.close();
  }
}
