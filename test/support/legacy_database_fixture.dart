/// 冻结的 v1 表结构，不能用当前结构伪造旧资料库，避免漏掉真实升级冲突。
const legacySchemaV1 = <String>[
  'CREATE TABLE projects (id TEXT PRIMARY KEY,title TEXT NOT NULL,created_at INTEGER NOT NULL,deleted_at INTEGER)',
  'CREATE TABLE resources (id TEXT PRIMARY KEY,sha256 TEXT NOT NULL UNIQUE,kind TEXT NOT NULL,size INTEGER NOT NULL CHECK(size>=0),relative_path TEXT NOT NULL UNIQUE)',
  'CREATE TABLE documents (id TEXT PRIMARY KEY,project_id TEXT NOT NULL REFERENCES projects(id),title TEXT NOT NULL,active_revision_id TEXT NOT NULL REFERENCES revisions(id) DEFERRABLE INITIALLY DEFERRED,deleted_at INTEGER)',
  'CREATE TABLE revisions (id TEXT PRIMARY KEY,document_id TEXT NOT NULL REFERENCES documents(id),resource_id TEXT NOT NULL REFERENCES resources(id),content_hash TEXT NOT NULL,page_count INTEGER NOT NULL CHECK(page_count>=0),geometry TEXT NOT NULL)',
  'CREATE TABLE cards (id TEXT PRIMARY KEY,project_id TEXT NOT NULL REFERENCES projects(id),title TEXT NOT NULL,excerpt_snapshot TEXT NOT NULL,body TEXT NOT NULL,note TEXT NOT NULL,color TEXT NOT NULL,image_resource_id TEXT REFERENCES resources(id),updated_at INTEGER NOT NULL,deleted_at INTEGER)',
  'CREATE TABLE text_layers (id TEXT PRIMARY KEY,revision_id TEXT NOT NULL REFERENCES revisions(id) ON DELETE CASCADE,page_index INTEGER NOT NULL CHECK(page_index>=0),source TEXT NOT NULL,text TEXT NOT NULL,fragments TEXT NOT NULL,engine_version TEXT NOT NULL,parameters TEXT NOT NULL,created_at INTEGER NOT NULL,is_current INTEGER NOT NULL CHECK(is_current IN (0,1)))',
  'CREATE UNIQUE INDEX current_page_layer ON text_layers(revision_id,page_index) WHERE is_current=1',
  'CREATE TABLE anchors (id TEXT PRIMARY KEY,card_id TEXT NOT NULL REFERENCES cards(id),revision_id TEXT NOT NULL REFERENCES revisions(id),page_index INTEGER NOT NULL CHECK(page_index>=0),quads TEXT NOT NULL,text_layer_id TEXT REFERENCES text_layers(id),text_start INTEGER,text_end INTEGER,context TEXT NOT NULL)',
  'CREATE TABLE annotations (id TEXT PRIMARY KEY,revision_id TEXT NOT NULL REFERENCES revisions(id) ON DELETE CASCADE,page_index INTEGER NOT NULL CHECK(page_index>=0),quads TEXT NOT NULL,kind TEXT NOT NULL,text TEXT NOT NULL,color TEXT NOT NULL,card_id TEXT REFERENCES cards(id))',
  'CREATE TABLE maps (id TEXT PRIMARY KEY,project_id TEXT NOT NULL REFERENCES projects(id),title TEXT NOT NULL,deleted_at INTEGER)',
  'CREATE TABLE nodes (id TEXT PRIMARY KEY,map_id TEXT NOT NULL REFERENCES maps(id),card_id TEXT NOT NULL REFERENCES cards(id),parent_node_id TEXT REFERENCES nodes(id) DEFERRABLE INITIALLY DEFERRED,x REAL NOT NULL,y REAL NOT NULL,width REAL NOT NULL,height REAL NOT NULL,collapsed INTEGER NOT NULL CHECK(collapsed IN (0,1)),deleted_at INTEGER)',
  'CREATE TABLE edges (id TEXT PRIMARY KEY,map_id TEXT NOT NULL REFERENCES maps(id),from_node_id TEXT NOT NULL REFERENCES nodes(id) DEFERRABLE INITIALLY DEFERRED,to_node_id TEXT NOT NULL REFERENCES nodes(id) DEFERRABLE INITIALLY DEFERRED,CHECK(from_node_id<to_node_id),UNIQUE(map_id,from_node_id,to_node_id))',
  'CREATE TABLE ocr_tasks (id TEXT PRIMARY KEY,revision_id TEXT NOT NULL REFERENCES revisions(id) ON DELETE CASCADE,page_index INTEGER NOT NULL CHECK(page_index>=0),model_version TEXT NOT NULL,status TEXT NOT NULL,error TEXT NOT NULL,session_id TEXT,updated_at INTEGER NOT NULL,UNIQUE(revision_id,page_index,model_version))',
  'CREATE TABLE trash (id TEXT PRIMARY KEY,kind TEXT NOT NULL,entity_id TEXT NOT NULL,project_id TEXT NOT NULL REFERENCES projects(id),title TEXT NOT NULL,payload TEXT NOT NULL,deleted_at INTEGER NOT NULL,UNIQUE(kind,entity_id))',
  'CREATE TABLE reading_positions (id TEXT PRIMARY KEY REFERENCES revisions(id) ON DELETE CASCADE,page_index INTEGER NOT NULL,offset REAL NOT NULL)',
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
];

const legacyHomeSchemaV2 = <String>[
  'CREATE TABLE project_folders (id TEXT PRIMARY KEY,title TEXT NOT NULL,created_at INTEGER NOT NULL)',
  'CREATE TABLE project_memberships (id TEXT PRIMARY KEY REFERENCES projects(id) ON DELETE CASCADE,folder_id TEXT REFERENCES project_folders(id) ON DELETE SET NULL)',
  "CREATE TABLE project_sessions (id TEXT PRIMARY KEY REFERENCES projects(id) ON DELETE CASCADE,last_opened_at INTEGER,active_document_id TEXT REFERENCES documents(id) ON DELETE SET NULL,last_read_document_id TEXT REFERENCES documents(id) ON DELETE SET NULL,map_id TEXT REFERENCES maps(id) ON DELETE SET NULL,opened_document_ids TEXT NOT NULL DEFAULT '[]')",
  'CREATE INDEX project_memberships_folder ON project_memberships(folder_id)',
  'CREATE INDEX project_sessions_recent ON project_sessions(last_opened_at)',
];

/// 冻结的 v3 增量结构，用于真实旧布局库升级，不引用当前迁移定义。
const legacyMapLayoutSchemaV3 = <String>[
  "ALTER TABLE maps ADD COLUMN layout_kind TEXT NOT NULL DEFAULT 'free' CHECK(layout_kind IN ('free','right','left','mindMap','down','up'))",
  "ALTER TABLE nodes ADD COLUMN sort_index INTEGER CHECK(sort_index IS NULL OR (typeof(sort_index)='integer' AND sort_index >= 0))",
  'ALTER TABLE nodes ADD COLUMN branch_side INTEGER CHECK(branch_side IS NULL OR branch_side IN (-1,1))',
];

/// 冻结的 v4 关联结构，不能使用当前源码伪造旧库。
const legacyRelationshipSchemaV4 = <String>[
  "ALTER TABLE edges ADD COLUMN label TEXT NOT NULL DEFAULT ''",
  "ALTER TABLE edges ADD COLUMN style_json TEXT NOT NULL DEFAULT '{}'",
];

/// 冻结 v5 外框结构，概要升级用真实旧表验证。
const legacyBoundarySchemaV5 = <String>[
  "CREATE TABLE boundaries (id TEXT PRIMARY KEY,map_id TEXT NOT NULL REFERENCES maps(id),parent_node_id TEXT REFERENCES nodes(id) DEFERRABLE INITIALLY DEFERRED,node_ids TEXT NOT NULL,label TEXT NOT NULL DEFAULT '',style_json TEXT NOT NULL DEFAULT '{}')",
  'CREATE INDEX boundaries_map ON boundaries(map_id)',
];

/// 冻结 v6 概要结构；验证普通主题格式升级时不引用当前迁移源码。
const legacySummarySchemaV6 = <String>[
  "CREATE TABLE summaries (id TEXT PRIMARY KEY,map_id TEXT NOT NULL REFERENCES maps(id),parent_node_id TEXT REFERENCES nodes(id) DEFERRABLE INITIALLY DEFERRED,summary_node_id TEXT NOT NULL UNIQUE REFERENCES nodes(id) DEFERRABLE INITIALLY DEFERRED,node_ids TEXT NOT NULL,style_json TEXT NOT NULL DEFAULT '{}')",
  'CREATE INDEX summaries_map ON summaries(map_id)',
];

/// 冻结 v7 主题格式字段；混合结构迁移不得引用当前迁移源码制造旧库。
const legacyTopicStyleSchemaV7 = <String>[
  "ALTER TABLE maps ADD COLUMN default_style_json TEXT NOT NULL DEFAULT '{}'",
  'ALTER TABLE nodes ADD COLUMN topic_style_json TEXT',
];

/// 冻结 v8 混合结构字段；扩展结构升级用旧 CHECK 约束验证安全重建。
const legacyMixedStructureSchemaV8 = <String>[
  "ALTER TABLE nodes ADD COLUMN branch_layout TEXT CHECK(branch_layout IS NULL OR branch_layout IN ('free','right','left','mindMap','down','up'))",
];
