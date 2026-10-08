import 'dart:io';
import 'dart:isolate';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

const currentDatabaseVersion = 11;

const anchorsTableSchema = '''CREATE TABLE anchors (
    id TEXT PRIMARY KEY, card_id TEXT NOT NULL REFERENCES cards(id),
    revision_id TEXT NOT NULL REFERENCES revisions(id),
    page_index INTEGER CHECK(page_index IS NULL OR page_index >= 0), quads TEXT NOT NULL,
    text_layer_id TEXT REFERENCES text_layers(id), text_start INTEGER,
    text_end INTEGER, context TEXT NOT NULL, locator_json TEXT,
    CHECK((locator_json IS NULL AND page_index IS NOT NULL) OR
      (locator_json IS NOT NULL AND page_index IS NULL AND quads='[]'
       AND text_layer_id IS NULL AND text_start IS NULL AND text_end IS NULL)))''';
const annotationsTableSchema = '''CREATE TABLE annotations (
    id TEXT PRIMARY KEY, revision_id TEXT NOT NULL REFERENCES revisions(id) ON DELETE CASCADE,
    page_index INTEGER CHECK(page_index IS NULL OR page_index >= 0), quads TEXT NOT NULL,
    kind TEXT NOT NULL, text TEXT NOT NULL, color TEXT NOT NULL,
    card_id TEXT REFERENCES cards(id), locator_json TEXT,
    CHECK((locator_json IS NULL AND page_index IS NOT NULL) OR
      (locator_json IS NOT NULL AND page_index IS NULL AND quads='[]')))''';
const readingPositionsTableSchema = '''CREATE TABLE reading_positions (
    id TEXT PRIMARY KEY REFERENCES revisions(id) ON DELETE CASCADE, page_index INTEGER,
    offset REAL NOT NULL, locator_json TEXT, settings_json TEXT NOT NULL DEFAULT '{}',
    CHECK((locator_json IS NULL AND page_index IS NOT NULL) OR
      (locator_json IS NOT NULL AND page_index IS NULL)))''';
const epubSchema = <String>[
  '''CREATE TABLE epub_sections (
    id TEXT PRIMARY KEY, revision_id TEXT NOT NULL REFERENCES revisions(id) ON DELETE CASCADE,
    spine_index INTEGER NOT NULL CHECK(spine_index >= 0), href TEXT NOT NULL,
    title TEXT NOT NULL, fixed_layout INTEGER NOT NULL CHECK(fixed_layout IN (0,1)),
    text TEXT, fragments TEXT NOT NULL DEFAULT '[]', engine_version TEXT NOT NULL DEFAULT '',
    UNIQUE(revision_id,spine_index), UNIQUE(revision_id,href))''',
  '''CREATE TABLE epub_image_ocr (
    id TEXT PRIMARY KEY, revision_id TEXT NOT NULL REFERENCES revisions(id) ON DELETE CASCADE,
    image_resource_id TEXT NOT NULL REFERENCES resources(id), locator_json TEXT NOT NULL,
    text TEXT NOT NULL, result_json TEXT NOT NULL, engine_version TEXT NOT NULL,
    created_at INTEGER NOT NULL)''',
  'CREATE INDEX epub_ocr_revision ON epub_image_ocr(revision_id)',
];

const _unexpectedDocumentObjects = '''SELECT COUNT(*) AS count FROM sqlite_master
  WHERE tbl_name IN ('anchors','annotations','reading_positions') AND (type='trigger' OR
    (type='index' AND sql IS NOT NULL AND name NOT IN ('anchors_card','anchors_revision','annotations_revision')))''';

const persistedMapLayouts =
    "'free','right','left','mindMap','down','up','treeRight','treeLeft','braceRight','braceLeft','timeline','timelineVertical','fishboneLeft','fishboneRight'";
const legacyPersistedMapLayouts = "'free','right','left','mindMap','down','up'";
const mapsTableSchema = '''CREATE TABLE maps (
    id TEXT PRIMARY KEY, project_id TEXT NOT NULL REFERENCES projects(id),
    title TEXT NOT NULL, deleted_at INTEGER,
    default_style_json TEXT NOT NULL DEFAULT '{}',
    layout_kind TEXT NOT NULL DEFAULT 'free' CHECK(layout_kind IN ($persistedMapLayouts)))''';
const nodesTableSchema = '''CREATE TABLE nodes (
    id TEXT PRIMARY KEY, map_id TEXT NOT NULL REFERENCES maps(id),
    card_id TEXT NOT NULL REFERENCES cards(id), parent_node_id TEXT REFERENCES nodes(id)
      DEFERRABLE INITIALLY DEFERRED,
    x REAL NOT NULL, y REAL NOT NULL, width REAL NOT NULL, height REAL NOT NULL,
    collapsed INTEGER NOT NULL CHECK(collapsed IN (0,1)), deleted_at INTEGER,
    sort_index INTEGER CHECK(sort_index IS NULL OR (typeof(sort_index)='integer' AND sort_index >= 0)),
    branch_side INTEGER CHECK(branch_side IS NULL OR branch_side IN (-1,1)),
    topic_style_json TEXT,
    branch_layout TEXT CHECK(branch_layout IS NULL OR branch_layout IN ($persistedMapLayouts)))''';

const _unexpectedLayoutObjects = '''SELECT COUNT(*) AS count FROM sqlite_master
  WHERE tbl_name IN ('maps','nodes') AND (type='trigger' OR
    (type='index' AND sql IS NOT NULL AND name NOT IN ('maps_project','nodes_map','nodes_parent')))''';

const _layoutColumns = {
  'maps': {
    'id',
    'project_id',
    'title',
    'deleted_at',
    'layout_kind',
    'default_style_json',
  },
  'nodes': {
    'id',
    'map_id',
    'card_id',
    'parent_node_id',
    'x',
    'y',
    'width',
    'height',
    'collapsed',
    'deleted_at',
    'sort_index',
    'branch_side',
    'topic_style_json',
    'branch_layout',
  },
};

void _requireKnownLayoutColumns(Map<String, Set<String>> actual) {
  for (final entry in _layoutColumns.entries) {
    final columns = actual[entry.key]!;
    if (columns.length != entry.value.length ||
        !columns.containsAll(entry.value)) {
      throw StateError('脑图表 ${entry.key} 的字段与版本不匹配，保留原库，不执行结构迁移。');
    }
  }
}

/// 在 Drift 开始升级前保存含 WAL 提交数据的一致性快照。
Future<void> prepareDatabaseUpgrade(String path) => Isolate.run(() {
  if (!File(path).existsSync()) return;
  final database = sqlite.sqlite3.open(path);
  try {
    final version = database.select('PRAGMA user_version').single.values.single;
    if (version is int && version >= 1 && version < currentDatabaseVersion) {
      final backup =
          '$path.before-v$currentDatabaseVersion-${DateTime.now().microsecondsSinceEpoch}.sqlite';
      database.execute('VACUUM INTO ?', [backup]);
      final check = sqlite.sqlite3.open(backup, mode: sqlite.OpenMode.readOnly);
      try {
        if (check.select('PRAGMA integrity_check').single.values.single !=
            'ok') {
          throw StateError('升级前数据库快照校验失败');
        }
      } finally {
        check.close();
      }
    } else if (version != 0 && version != currentDatabaseVersion) {
      throw StateError('不支持数据库版本 $version');
    }
  } finally {
    database.close();
  }
});

/// 暂存恢复库先独立升级，校验成功后才允许切换活动资料库。
Future<void> upgradeStagedDatabase(String path) async {
  await prepareDatabaseUpgrade(path);
  await Isolate.run(() {
    final database = sqlite.sqlite3.open(path);
    try {
      final version = database
          .select('PRAGMA user_version')
          .single
          .values
          .single;
      if (version == currentDatabaseVersion) return;
      if (version is! int || version < 1 || version >= currentDatabaseVersion) {
        throw StateError('不支持备份数据库版本 $version');
      }
      database.execute('PRAGMA foreign_keys = OFF');
      database.execute('BEGIN IMMEDIATE');
      try {
        if (database.select(_unexpectedLayoutObjects).single['count'] != 0) {
          throw StateError('脑图表存在非标准索引或触发器，保留原库，不执行结构迁移。');
        }
        if (database.select(_unexpectedDocumentObjects).single['count'] != 0) {
          throw StateError('来源表存在非标准索引或触发器，保留原库，不执行迁移。');
        }
        for (final statement in upgradeStatements(version)) {
          if (statement == extendedStructureSchema.first) {
            _requireKnownLayoutColumns({
              for (final table in _layoutColumns.keys)
                table: database
                    .select('PRAGMA table_info($table)')
                    .map((r) => r['name'] as String)
                    .toSet(),
            });
          }
          database.execute(statement);
        }
        if (database.select('PRAGMA foreign_key_check').isNotEmpty) {
          throw StateError('数据库升级后引用检查失败，保留原库。');
        }
        database.execute('PRAGMA user_version = $currentDatabaseVersion');
        database.execute('COMMIT');
      } catch (_) {
        database.execute('ROLLBACK');
        rethrow;
      }
    } finally {
      database.close();
    }
  });
}

/// SQL 在 Drift 后台 isolate 执行；领域命令负责唯一的写入规则。
class OpenNoteDatabase extends GeneratedDatabase {
  OpenNoteDatabase(String path)
    : super(NativeDatabase.createInBackground(File(path)));

  @override
  int get schemaVersion => currentDatabaseVersion;

  @override
  Iterable<TableInfo<Table, dynamic>> get allTables => const [];

  @override
  Iterable<DatabaseSchemaEntity> get allSchemaEntities => const [];

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (_) async {
      for (final statement in schemaStatements) {
        await customStatement(statement);
      }
    },
    onUpgrade: (_, from, to) async {
      if (from < 1 ||
          from >= currentDatabaseVersion ||
          to != currentDatabaseVersion) {
        throw StateError('不支持数据库从 $from 升级到 $to；禁止破坏性重建。');
      }
      // 扩展 CHECK 约束按 SQLite 表重建流程执行；关闭外键只限升级事务。
      // 删除旧表不能触发级联清理，提交前仍检查全部引用，失败完整回滚。
      await customStatement('PRAGMA foreign_keys = OFF');
      try {
        await transaction(() async {
          if ((await customSelect(
                _unexpectedLayoutObjects,
              ).getSingle()).read<int>('count') !=
              0) {
            throw StateError('脑图表存在非标准索引或触发器，保留原库，不执行结构迁移。');
          }
          for (final statement in upgradeStatements(from)) {
            if (statement == epubMigrationSchema.first &&
                (await customSelect(_unexpectedDocumentObjects).getSingle()).read<int>('count') != 0) {
              throw StateError('来源表存在非标准索引或触发器，保留原库，不执行迁移。');
            }
            if (statement == extendedStructureSchema.first) {
              _requireKnownLayoutColumns({
                for (final table in _layoutColumns.keys)
                  table: (await customSelect(
                    'PRAGMA table_info($table)',
                  ).get()).map((r) => r.read<String>('name')).toSet(),
              });
            }
            await customStatement(statement);
          }
          if ((await customSelect(
            'PRAGMA foreign_key_check',
          ).get()).isNotEmpty) {
            throw StateError('数据库升级后引用检查失败，保留原库。');
          }
        });
      } finally {
        await customStatement('PRAGMA foreign_keys = ON');
      }
    },
    beforeOpen: (_) async {
      await customStatement('PRAGMA foreign_keys = ON');
      await customStatement('PRAGMA journal_mode = WAL');
      await customStatement('PRAGMA synchronous = FULL');
      await customStatement('PRAGMA busy_timeout = 5000');
    },
  );
}

const schemaStatements = <String>[
  '''CREATE TABLE projects (
    id TEXT PRIMARY KEY, title TEXT NOT NULL, created_at INTEGER NOT NULL,
    deleted_at INTEGER)''',
  '''CREATE TABLE resources (
    id TEXT PRIMARY KEY, sha256 TEXT NOT NULL UNIQUE, kind TEXT NOT NULL,
    size INTEGER NOT NULL CHECK(size >= 0), relative_path TEXT NOT NULL UNIQUE)''',
  '''CREATE TABLE documents (
    id TEXT PRIMARY KEY, project_id TEXT NOT NULL REFERENCES projects(id),
    title TEXT NOT NULL, active_revision_id TEXT NOT NULL
      REFERENCES revisions(id) DEFERRABLE INITIALLY DEFERRED,
    deleted_at INTEGER)''',
  '''CREATE TABLE revisions (
    id TEXT PRIMARY KEY, document_id TEXT NOT NULL REFERENCES documents(id),
    resource_id TEXT NOT NULL REFERENCES resources(id), content_hash TEXT NOT NULL,
    page_count INTEGER NOT NULL CHECK(page_count >= 0), geometry TEXT NOT NULL,
    format TEXT NOT NULL DEFAULT 'pdf' CHECK(format IN ('pdf','epub')),
    metadata_json TEXT NOT NULL DEFAULT '{}')''',
  '''CREATE TABLE cards (
    id TEXT PRIMARY KEY, project_id TEXT NOT NULL REFERENCES projects(id),
    title TEXT NOT NULL, excerpt_snapshot TEXT NOT NULL, body TEXT NOT NULL,
    note TEXT NOT NULL, thoughts_json TEXT NOT NULL DEFAULT '[]', color TEXT NOT NULL,
    image_resource_id TEXT REFERENCES resources(id),
    updated_at INTEGER NOT NULL, deleted_at INTEGER)''',
  '''CREATE TABLE text_layers (
    id TEXT PRIMARY KEY, revision_id TEXT NOT NULL REFERENCES revisions(id) ON DELETE CASCADE,
    page_index INTEGER NOT NULL CHECK(page_index >= 0), source TEXT NOT NULL,
    text TEXT NOT NULL, fragments TEXT NOT NULL, engine_version TEXT NOT NULL,
    parameters TEXT NOT NULL, created_at INTEGER NOT NULL,
    is_current INTEGER NOT NULL CHECK(is_current IN (0,1)))''',
  '''CREATE UNIQUE INDEX current_page_layer ON text_layers(revision_id,page_index)
    WHERE is_current = 1''',
  anchorsTableSchema,
  annotationsTableSchema,
  mapsTableSchema,
  nodesTableSchema,
  '''CREATE TABLE edges (
    id TEXT PRIMARY KEY, map_id TEXT NOT NULL REFERENCES maps(id),
    from_node_id TEXT NOT NULL REFERENCES nodes(id) DEFERRABLE INITIALLY DEFERRED,
    to_node_id TEXT NOT NULL REFERENCES nodes(id) DEFERRABLE INITIALLY DEFERRED,
    label TEXT NOT NULL DEFAULT '', style_json TEXT NOT NULL DEFAULT '{}',
    CHECK(from_node_id < to_node_id), UNIQUE(map_id,from_node_id,to_node_id))''',
  '''CREATE TABLE ocr_tasks (
    id TEXT PRIMARY KEY, revision_id TEXT NOT NULL REFERENCES revisions(id) ON DELETE CASCADE,
    page_index INTEGER NOT NULL CHECK(page_index >= 0), model_version TEXT NOT NULL,
    status TEXT NOT NULL, error TEXT NOT NULL, session_id TEXT,
    updated_at INTEGER NOT NULL,
    UNIQUE(revision_id,page_index,model_version))''',
  '''CREATE TABLE trash (
    id TEXT PRIMARY KEY, kind TEXT NOT NULL, entity_id TEXT NOT NULL,
    project_id TEXT NOT NULL REFERENCES projects(id), title TEXT NOT NULL,
    payload TEXT NOT NULL, deleted_at INTEGER NOT NULL,
    UNIQUE(kind,entity_id))''',
  readingPositionsTableSchema,
  'CREATE INDEX documents_project ON documents(project_id,deleted_at)',
  'CREATE INDEX cards_project ON cards(project_id,deleted_at,updated_at)',
  'CREATE INDEX maps_project ON maps(project_id,deleted_at)',
  'CREATE INDEX nodes_map ON nodes(map_id,deleted_at)',
  'CREATE INDEX nodes_parent ON nodes(parent_node_id)',
  'CREATE INDEX anchors_card ON anchors(card_id)',
  'CREATE INDEX anchors_revision ON anchors(revision_id,page_index)',
  'CREATE INDEX annotations_revision ON annotations(revision_id,page_index)',
  'CREATE INDEX text_layers_revision ON text_layers(revision_id,page_index,is_current)',
  'CREATE INDEX ocr_queue ON ocr_tasks(status,updated_at)',
  ...projectHomeSchema,
  ...boundarySchema,
  ...summarySchema,
  ...epubSchema,
];

List<String> upgradeStatements(int from) => [
  if (from < 2) ...projectHomeSchema,
  if (from < 3) ...mapLayoutSchema,
  if (from < 4) ...relationshipSchema,
  if (from < 5) ...boundarySchema,
  if (from < 6) ...summarySchema,
  if (from < 7) ...topicStyleSchema,
  if (from < 8) ...mixedStructureSchema,
  if (from < 9) ...extendedStructureSchema,
  if (from < 10) ...personalThoughtsSchema,
  if (from < 11) ...epubMigrationSchema,
];

final epubMigrationSchema = <String>[
  "ALTER TABLE revisions ADD COLUMN format TEXT NOT NULL DEFAULT 'pdf' CHECK(format IN ('pdf','epub'))",
  "ALTER TABLE revisions ADD COLUMN metadata_json TEXT NOT NULL DEFAULT '{}'",
  anchorsTableSchema.replaceFirst('CREATE TABLE anchors', 'CREATE TABLE anchors_v11'),
  '''INSERT INTO anchors_v11 (id,card_id,revision_id,page_index,quads,text_layer_id,text_start,text_end,context)
    SELECT id,card_id,revision_id,page_index,quads,text_layer_id,text_start,text_end,context FROM anchors''',
  'DROP TABLE anchors', 'ALTER TABLE anchors_v11 RENAME TO anchors',
  'CREATE INDEX anchors_card ON anchors(card_id)',
  'CREATE INDEX anchors_revision ON anchors(revision_id,page_index)',
  annotationsTableSchema.replaceFirst('CREATE TABLE annotations', 'CREATE TABLE annotations_v11'),
  '''INSERT INTO annotations_v11 (id,revision_id,page_index,quads,kind,text,color,card_id)
    SELECT id,revision_id,page_index,quads,kind,text,color,card_id FROM annotations''',
  'DROP TABLE annotations', 'ALTER TABLE annotations_v11 RENAME TO annotations',
  'CREATE INDEX annotations_revision ON annotations(revision_id,page_index)',
  readingPositionsTableSchema.replaceFirst('CREATE TABLE reading_positions', 'CREATE TABLE reading_positions_v11'),
  'INSERT INTO reading_positions_v11 (id,page_index,offset) SELECT id,page_index,offset FROM reading_positions',
  'DROP TABLE reading_positions', 'ALTER TABLE reading_positions_v11 RENAME TO reading_positions',
  ...epubSchema,
];

const personalThoughtsSchema = <String>[
  "ALTER TABLE cards ADD COLUMN thoughts_json TEXT NOT NULL DEFAULT '[]'",
  '''UPDATE cards SET thoughts_json=json_array(json_object('id',id || ':thought','text',note))
    WHERE note<>'' ''',
];

final extendedStructureSchema = <String>[
  mapsTableSchema.replaceFirst('CREATE TABLE maps', 'CREATE TABLE maps_v9'),
  nodesTableSchema.replaceFirst('CREATE TABLE nodes', 'CREATE TABLE nodes_v9'),
  '''INSERT INTO maps_v9 (id,project_id,title,deleted_at,default_style_json,layout_kind)
    SELECT id,project_id,title,deleted_at,default_style_json,layout_kind FROM maps''',
  '''INSERT INTO nodes_v9 (id,map_id,card_id,parent_node_id,x,y,width,height,collapsed,
    deleted_at,sort_index,branch_side,topic_style_json,branch_layout)
    SELECT id,map_id,card_id,parent_node_id,x,y,width,height,collapsed,deleted_at,
      sort_index,branch_side,topic_style_json,branch_layout FROM nodes''',
  'DROP TABLE nodes',
  'DROP TABLE maps',
  'ALTER TABLE maps_v9 RENAME TO maps',
  'ALTER TABLE nodes_v9 RENAME TO nodes',
  'CREATE INDEX maps_project ON maps(project_id,deleted_at)',
  'CREATE INDEX nodes_map ON nodes(map_id,deleted_at)',
  'CREATE INDEX nodes_parent ON nodes(parent_node_id)',
];

const mixedStructureSchema = <String>[
  "ALTER TABLE nodes ADD COLUMN branch_layout TEXT CHECK(branch_layout IS NULL OR branch_layout IN ('free','right','left','mindMap','down','up'))",
];

const topicStyleSchema = <String>[
  "ALTER TABLE maps ADD COLUMN default_style_json TEXT NOT NULL DEFAULT '{}'",
  'ALTER TABLE nodes ADD COLUMN topic_style_json TEXT',
];

const summarySchema = <String>[
  '''CREATE TABLE summaries (
    id TEXT PRIMARY KEY, map_id TEXT NOT NULL REFERENCES maps(id),
    parent_node_id TEXT REFERENCES nodes(id) DEFERRABLE INITIALLY DEFERRED,
    summary_node_id TEXT NOT NULL UNIQUE REFERENCES nodes(id) DEFERRABLE INITIALLY DEFERRED,
    node_ids TEXT NOT NULL, style_json TEXT NOT NULL DEFAULT '{}')''',
  'CREATE INDEX summaries_map ON summaries(map_id)',
];

const boundarySchema = <String>[
  '''CREATE TABLE boundaries (
    id TEXT PRIMARY KEY, map_id TEXT NOT NULL REFERENCES maps(id),
    parent_node_id TEXT REFERENCES nodes(id) DEFERRABLE INITIALLY DEFERRED,
    node_ids TEXT NOT NULL, label TEXT NOT NULL DEFAULT '',
    style_json TEXT NOT NULL DEFAULT '{}')''',
  'CREATE INDEX boundaries_map ON boundaries(map_id)',
];

const relationshipSchema = <String>[
  "ALTER TABLE edges ADD COLUMN label TEXT NOT NULL DEFAULT ''",
  "ALTER TABLE edges ADD COLUMN style_json TEXT NOT NULL DEFAULT '{}'",
];

const mapLayoutSchema = <String>[
  "ALTER TABLE maps ADD COLUMN layout_kind TEXT NOT NULL DEFAULT 'free' CHECK(layout_kind IN ('free','right','left','mindMap','down','up'))",
  "ALTER TABLE nodes ADD COLUMN sort_index INTEGER CHECK(sort_index IS NULL OR (typeof(sort_index)='integer' AND sort_index >= 0))",
  'ALTER TABLE nodes ADD COLUMN branch_side INTEGER CHECK(branch_side IS NULL OR branch_side IN (-1,1))',
];

const projectHomeSchema = <String>[
  '''CREATE TABLE project_folders (
    id TEXT PRIMARY KEY, title TEXT NOT NULL, created_at INTEGER NOT NULL)''',
  '''CREATE TABLE project_memberships (
    id TEXT PRIMARY KEY REFERENCES projects(id) ON DELETE CASCADE,
    folder_id TEXT REFERENCES project_folders(id) ON DELETE SET NULL)''',
  '''CREATE TABLE project_sessions (
    id TEXT PRIMARY KEY REFERENCES projects(id) ON DELETE CASCADE,
    last_opened_at INTEGER,
    active_document_id TEXT REFERENCES documents(id) ON DELETE SET NULL,
    last_read_document_id TEXT REFERENCES documents(id) ON DELETE SET NULL,
    map_id TEXT REFERENCES maps(id) ON DELETE SET NULL,
    opened_document_ids TEXT NOT NULL DEFAULT '[]')''',
  'CREATE INDEX project_memberships_folder ON project_memberships(folder_id)',
  'CREATE INDEX project_sessions_recent ON project_sessions(last_opened_at)',
];

const databaseTableNames = <String>{
  'projects',
  'resources',
  'documents',
  'revisions',
  'cards',
  'text_layers',
  'anchors',
  'annotations',
  'maps',
  'nodes',
  'edges',
  'ocr_tasks',
  'trash',
  'reading_positions',
  'project_folders',
  'project_memberships',
  'project_sessions',
  'boundaries',
  'summaries',
  'epub_sections',
  'epub_image_ocr',
};

final preEpubDatabaseTableNames = databaseTableNames.difference({'epub_sections','epub_image_ocr'});
final preSummaryDatabaseTableNames = preEpubDatabaseTableNames.difference({
  'summaries',
});
final preBoundaryDatabaseTableNames = preSummaryDatabaseTableNames.difference({
  'boundaries',
});
final legacyDatabaseTableNames = preBoundaryDatabaseTableNames.difference({
  'project_folders',
  'project_memberships',
  'project_sessions',
});
