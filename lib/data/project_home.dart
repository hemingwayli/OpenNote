part of 'open_note_repository.dart';

extension ProjectHomeRepository on OpenNoteRepository {
  Future<List<ProjectFolder>> listProjectFolders() => _exclusive(
    () async =>
        (await _rows(
              '''SELECT f.*, COUNT(p.id) AS project_count FROM project_folders f
      LEFT JOIN project_memberships m ON m.folder_id=f.id
      LEFT JOIN projects p ON p.id=m.id AND p.deleted_at IS NULL
      GROUP BY f.id ORDER BY f.title COLLATE NOCASE, f.id''',
            ))
            .map(
              (r) => ProjectFolder(
                id: r['id'] as String,
                title: r['title'] as String,
                projectCount: r['project_count'] as int,
              ),
            )
            .toList(),
  );

  Future<String> createProjectFolder(String title) =>
      _mutate('新建项目文件夹', (w) async {
        final id = _id();
        await w.put('project_folders', {
          'id': id,
          'title': _title(title),
          'created_at': _now(),
        });
        return id;
      });

  Future<void> renameProjectFolder(String id, String title) =>
      _mutate('重命名项目文件夹', (w) async {
        final row = await _require('project_folders', id);
        await w.put('project_folders', {...row, 'title': _title(title)});
      });

  Future<void> deleteProjectFolder(String id) => _mutate('删除项目文件夹', (w) async {
    await _require('project_folders', id);
    for (final row in await _rows(
      'SELECT * FROM project_memberships WHERE folder_id=?',
      [id],
    )) {
      await w.put('project_memberships', {...row, 'folder_id': null});
    }
    await w.remove('project_folders', id);
  });

  Future<void> moveProjectToFolder(String projectId, String? folderId) =>
      _mutate('移动项目分类', (w) async {
        await _require('projects', projectId, active: true);
        if (folderId != null) await _require('project_folders', folderId);
        await w.put('project_memberships', {
          'id': projectId,
          'folder_id': folderId,
        });
      });

  Future<ProjectPage> queryProjectPage({
    String query = '',
    String? folderId,
    bool unclassified = false,
    ProjectSort sort = ProjectSort.recent,
    int offset = 0,
    int limit = 60,
  }) => _exclusive(() async {
    if (offset < 0 || limit < 1 || limit > 200) _invalid('项目分页范围无效');
    final conditions = ['p.deleted_at IS NULL'];
    final arguments = <Object?>[];
    if (query.trim().isNotEmpty) {
      conditions.add('instr(lower(p.title),lower(?)) > 0');
      arguments.add(query.trim());
    } else if (unclassified) {
      conditions.add('m.folder_id IS NULL');
    } else if (folderId != null) {
      conditions.add('m.folder_id=?');
      arguments.add(folderId);
    }
    final where = conditions.join(' AND ');
    final order = switch (sort) {
      ProjectSort.recent =>
        'COALESCE(s.last_opened_at,p.created_at) DESC, p.id',
      ProjectSort.name => 'p.title COLLATE NOCASE, p.id',
      ProjectSort.created => 'p.created_at DESC, p.id',
    };
    final total =
        (await _rows(
              '''SELECT COUNT(*) AS n FROM projects p
      LEFT JOIN project_memberships m ON m.id=p.id WHERE $where''',
              arguments,
            )).single['n']
            as int;
    final rows = await _rows(
      '''SELECT p.*, m.folder_id, f.title AS folder_title,
      s.last_opened_at, r.content_hash AS cover_hash, a.relative_path AS cover_path,
      (SELECT COUNT(*) FROM documents WHERE project_id=p.id AND deleted_at IS NULL) AS document_count,
      (SELECT COUNT(*) FROM maps WHERE project_id=p.id AND deleted_at IS NULL) AS map_count,
      (SELECT COUNT(*) FROM cards WHERE project_id=p.id AND deleted_at IS NULL) AS card_count
      FROM projects p LEFT JOIN project_memberships m ON m.id=p.id
      LEFT JOIN project_folders f ON f.id=m.folder_id
      LEFT JOIN project_sessions s ON s.id=p.id
      LEFT JOIN documents d ON d.id=COALESCE(
        (SELECT id FROM documents WHERE id=s.last_read_document_id AND project_id=p.id AND deleted_at IS NULL),
        (SELECT id FROM documents WHERE project_id=p.id AND deleted_at IS NULL ORDER BY title,id LIMIT 1))
      LEFT JOIN revisions r ON r.id=d.active_revision_id
      LEFT JOIN resources a ON a.id=r.resource_id
      WHERE $where ORDER BY $order LIMIT ? OFFSET ?''',
      [...arguments, limit, offset],
    );
    return ProjectPage(
      rows
          .map(
            (r) => ProjectSummary(
              project: _project(r),
              folderId: r['folder_id'] as String?,
              folderTitle: r['folder_title'] as String?,
              lastOpenedAt: _date(r['last_opened_at']),
              documentCount: r['document_count'] as int,
              mapCount: r['map_count'] as int,
              cardCount: r['card_count'] as int,
              coverHash: r['cover_hash'] as String?,
              coverPath: r['cover_path'] == null
                  ? null
                  : _safeResourcePath(libraryPath, r['cover_path'] as String),
            ),
          )
          .toList(),
      total,
    );
  });

  Future<ProjectResumeState?> loadProjectResume(String projectId) =>
      _exclusive(() async {
        final rows = await _rows('SELECT * FROM project_sessions WHERE id=?', [
          projectId,
        ]);
        if (rows.isEmpty) return null;
        final row = rows.single;
        return ProjectResumeState(
          lastOpenedAt: _date(row['last_opened_at']),
          activeDocumentId: row['active_document_id'] as String?,
          lastReadDocumentId: row['last_read_document_id'] as String?,
          mapId: row['map_id'] as String?,
          openedDocumentIds: (jsonDecode(
            row['opened_document_ids'] as String,
          ) as List).cast<String>(),
        );
      });

  Future<void> saveProjectResume(
    String projectId, {
    String? activeDocumentId,
    String? mapId,
    required List<String> openedDocumentIds,
    bool markOpened = false,
    String? successfullyReadDocumentId,
  }) => _mutate(
    '保存项目阅读会话',
    (w) async {
      await _require('projects', projectId, active: true);
      final documents = (await _rows(
        'SELECT id FROM documents WHERE project_id=? AND deleted_at IS NULL',
        [projectId],
      )).map((r) => r['id'] as String).toSet();
      final maps = (await _rows(
        'SELECT id FROM maps WHERE project_id=? AND deleted_at IS NULL',
        [projectId],
      )).map((r) => r['id'] as String).toSet();
      final previous = (await _rows(
        'SELECT * FROM project_sessions WHERE id=?',
        [projectId],
      )).firstOrNull;
      await w.put('project_sessions', {
        'id': projectId,
        'last_opened_at': markOpened ? _now() : previous?['last_opened_at'],
        'active_document_id': documents.contains(activeDocumentId)
            ? activeDocumentId
            : null,
        'last_read_document_id': documents.contains(successfullyReadDocumentId)
            ? successfullyReadDocumentId
            : previous?['last_read_document_id'],
        'map_id': maps.contains(mapId) ? mapId : null,
        'opened_document_ids': encodeJson(
          openedDocumentIds.where(documents.contains).toSet().toList(),
        ),
      });
    },
    recordUndo: false,
    invalidateRedo: false,
    notifyChanges: false,
  );
}
