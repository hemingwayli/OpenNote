import '../theme/open_note_icon.dart';

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';

import '../../data/open_note_repository.dart';
import '../../domain/models.dart';
import '../theme/open_note_theme.dart';
import '../theme/open_note_window_bar.dart';
import '../theme/open_note_search.dart';
import '../workspace/text_input_dialog.dart';
import 'library_actions.dart';
import 'project_cover.dart';

class ProjectHome extends StatefulWidget {
  const ProjectHome({
    super.key,
    required this.repository,
    required this.covers,
    required this.onOpenProject,
    required this.onLibraryAction,
    this.active = true,
    this.busy = false,
  });
  final OpenNoteRepository repository;
  final ProjectCoverCache covers;
  final Future<void> Function(String) onOpenProject;
  final Future<void> Function(String) onLibraryAction;
  final bool active;
  final bool busy;
  @override
  State<ProjectHome> createState() => _ProjectHomeState();
}

class _ProjectHomeState extends State<ProjectHome> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final _scroll = ScrollController();
  final _positions = <String, double>{};
  final _loadedCounts = <String, int>{};
  final _scaffold = GlobalKey<ScaffoldState>();
  late final StreamSubscription<int> _subscription;
  Timer? _refreshTimer;
  Timer? _searchTimer;
  List<ProjectFolder> _folders = [];
  List<ProjectSummary> _items = [];
  String _folder = 'all';
  String _query = '';
  ProjectSort _sort = ProjectSort.recent;
  int _total = 0;
  int _allTotal = 0;
  int _generation = 0;
  bool _loading = true;
  bool _loadingMore = false;
  bool _working = false;
  String? _error;
  String? _hoveredProject;
  String? _focusedProject;
  bool get _busy => _working || widget.busy;
  String get _positionKey => '$_folder:${_sort.name}:$_query';
  String get _heading => _query.isNotEmpty
      ? '搜索结果'
      : _folder == 'all'
      ? '全部项目'
      : _folder == 'unclassified'
      ? '未分类'
      : _folders.where((f) => f.id == _folder).firstOrNull?.title ?? '全部项目';

  @override
  void initState() {
    super.initState();
    _subscription = widget.repository.changes.listen((_) {
      if (!widget.active) return;
      _refreshTimer?.cancel();
      _refreshTimer = Timer(const Duration(milliseconds: 250), () => _reload());
    });
    _scroll.addListener(() {
      if (_scroll.hasClients && _scroll.position.extentAfter < 700) _loadMore();
    });
    unawaited(_reload());
  }

  @override
  void didUpdateWidget(ProjectHome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active && !widget.active) _rememberPosition();
    if (!oldWidget.active && widget.active) unawaited(_reload());
  }

  void _rememberPosition() {
    if (_scroll.hasClients) _positions[_positionKey] = _scroll.offset;
    _loadedCounts[_positionKey] = _items.length;
  }

  Future<ProjectPage> _page(int offset) => widget.repository.queryProjectPage(
    query: _query,
    folderId: _folder == 'all' || _folder == 'unclassified' ? null : _folder,
    unclassified: _folder == 'unclassified',
    sort: _sort,
    offset: offset,
  );
  Future<void> _reload({bool remember = true, bool clearError = true}) async {
    if (!mounted || !widget.active) return;
    if (remember) _rememberPosition();
    final generation = ++_generation;
    setState(() {
      _loading = true;
      if (clearError) _error = null;
    });
    try {
      final folders = await widget.repository.listProjectFolders();
      final all = await widget.repository.queryProjectPage(limit: 1);
      if (!mounted || generation != _generation) return;
      if (_folder != 'all' &&
          _folder != 'unclassified' &&
          !folders.any((f) => f.id == _folder)) {
        _folder = 'all';
      }
      final page = await _page(0);
      final items = [...page.items];
      final restoreCount = math.min(
        _loadedCounts[_positionKey] ?? 0,
        page.total,
      );
      while (items.length < restoreCount &&
          mounted &&
          generation == _generation) {
        final more = await _page(items.length);
        if (more.items.isEmpty) break;
        items.addAll(more.items);
      }
      if (!mounted || generation != _generation) return;
      setState(() {
        _folders = folders;
        _allTotal = all.total;
        _items = items;
        _total = page.total;
        _loading = false;
        _loadingMore = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || generation != _generation || !_scroll.hasClients) {
          return;
        }
        _scroll.jumpTo(
          (_positions[_positionKey] ?? 0).clamp(
            0,
            _scroll.position.maxScrollExtent,
          ),
        );
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = '$error';
          _loading = false;
        });
      }
    }
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || _items.length >= _total || !widget.active) {
      return;
    }
    final generation = _generation;
    setState(() => _loadingMore = true);
    try {
      final page = await _page(_items.length);
      if (mounted && generation == _generation) {
        setState(() {
          _items.addAll(page.items);
          _loadingMore = false;
        });
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = '$error';
          _loadingMore = false;
        });
      }
    }
  }

  void _selectFolder(String id) {
    _searchTimer?.cancel();
    _rememberPosition();
    if (_scroll.hasClients) _scroll.jumpTo(0);
    setState(() {
      _folder = id;
      _query = '';
      _search.clear();
    });
    unawaited(_reload(remember: false));
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    var failed = false;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      failed = true;
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) {
        setState(() => _working = false);
        // 失败后的列表刷新不清掉操作错误；下一次操作或用户重试再解除。
        await _reload(clearError: !failed);
      }
    }
  }

  Future<String?> _name(String title, {String initial = ''}) async {
    final result = await showDialog<TextInputResult>(
      context: context,
      builder: (context) => TextInputDialog(
        title: title,
        hint: '名称',
        initialText: initial,
        confirmLabel: initial.isEmpty ? '创建' : '保存',
        requireText: true,
      ),
    );
    return result?.text.trim();
  }

  Future<void> _createProject() => _run(() async {
    final title = await _name('新建学习项目');
    if (title == null) return;
    final project = await widget.repository.createProject(
      title,
      folderId: _folder == 'all' || _folder == 'unclassified' ? null : _folder,
    );
    await widget.onOpenProject(project.id);
  });
  Future<void> _folderAction(String action, [ProjectFolder? folder]) =>
      _run(() async {
        if (action == 'delete') {
          if (await LibraryActions(context, widget.repository).confirm(
            '删除文件夹“${folder!.title}”',
            '${folder.projectCount} 个项目将移至“未分类”，项目内容保留。',
            '删除文件夹',
          )) {
            await widget.repository.deleteProjectFolder(folder.id);
          }
          return;
        }
        final title = await _name(
          folder == null ? '新建文件夹' : '重命名文件夹',
          initial: folder?.title ?? '',
        );
        if (title == null) return;
        if (folder == null) {
          await widget.repository.createProjectFolder(title);
        } else {
          await widget.repository.renameProjectFolder(folder.id, title);
        }
      });
  Future<void> _projectAction(
    String action,
    ProjectSummary item,
  ) => _run(() async {
    final project = item.project;
    if (action == 'rename') {
      final title = await _name('重命名学习项目', initial: project.title);
      if (title != null) {
        await widget.repository.renameProject(project.id, title);
      }
    } else if (action == 'delete') {
      if (await LibraryActions(context, widget.repository).confirm(
        '将“${project.title}”移入回收站？',
        '包含 ${item.documentCount} 份文档、${item.mapCount} 张脑图、${item.cardCount} 张卡片。可以在回收站恢复。',
        '移入回收站',
      )) {
        await widget.repository.trashProject(project.id);
      }
    } else {
      final destination = await showDialog<String>(
        context: context,
        builder: (context) => SimpleDialog(
          title: const Text('移动到文件夹'),
          children: [
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, ''),
              child: const Text('未分类'),
            ),
            for (final folder in _folders)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, folder.id),
                child: Text(folder.title),
              ),
          ],
        ),
      );
      if (destination != null) {
        await widget.repository.moveProjectToFolder(
          project.id,
          destination.isEmpty ? null : destination,
        );
      }
    }
  });
  @override
  void dispose() {
    _generation++;
    _subscription.cancel();
    _refreshTimer?.cancel();
    _searchTimer?.cancel();
    _search.dispose();
    _searchFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Widget _navigation() => Material(
    color: OpenNoteTokens.background,
    child: Column(
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(24, 20, 24, 24),
          child: Row(
            children: [
              OpenNoteIcon(Icons.folder_open_outlined, size: 20),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  '资料库',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
        _folderRow('all', '全部项目', Icons.grid_view_outlined, _allTotal),
        _folderRow('unclassified', '未分类', Icons.inbox_outlined, null),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 12, 8),
          child: Row(
            children: [
              Text('文件夹', style: Theme.of(context).textTheme.bodySmall),
              const Spacer(),
              IconButton(
                tooltip: '新建文件夹',
                onPressed: _busy ? null : () => _folderAction('create'),
                icon: const OpenNoteIcon(Icons.add, size: 18),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: _folders.length,
            itemBuilder: (_, index) {
              final folder = _folders[index];
              return _folderRow(
                folder.id,
                folder.title,
                Icons.folder_outlined,
                folder.projectCount,
                folder: folder,
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              const Spacer(),
              PopupMenuButton<String>(
                tooltip: '资料库设置',
                enabled: !_busy,
                onSelected: (value) => value == 'about'
                    ? showAboutDialog(
                        context: context,
                        applicationName: 'OpenNote',
                        applicationVersion: '0.1.2',
                        children: [const Text('离线文档阅读与知识整理')],
                      )
                    : _run(() => widget.onLibraryAction(value)),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'trash', child: Text('回收站')),
                  PopupMenuDivider(),
                  PopupMenuItem(value: 'backup', child: Text('完整备份…')),
                  PopupMenuItem(value: 'restore', child: Text('恢复整个资料库…')),
                  PopupMenuItem(value: 'undo', child: Text('撤销')),
                  PopupMenuItem(value: 'redo', child: Text('重做')),
                  PopupMenuItem(value: 'licenses', child: Text('开源许可')),
                  PopupMenuItem(value: 'about', child: Text('关于 OpenNote')),
                ],
                icon: const OpenNoteIcon(Icons.more_horiz),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _folderRow(
    String id,
    String title,
    IconData icon,
    int? count, {
    ProjectFolder? folder,
  }) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
    child: ListTile(
      key: ValueKey('project-folder-$id'),
      selected: _folder == id && _query.isEmpty,
      selectedTileColor: OpenNoteTokens.selected,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      leading: OpenNoteIcon(icon, size: 19),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: _busy
          ? null
          : () {
              _selectFolder(id);
              if (_scaffold.currentState?.isDrawerOpen == true) {
                Navigator.pop(context);
              }
            },
      trailing: folder == null
          ? (count == null
                ? null
                : Text('$count', style: Theme.of(context).textTheme.bodySmall))
          : PopupMenuButton<String>(
              tooltip: '管理文件夹 $title',
              enabled: !_busy,
              onSelected: (value) => _folderAction(value, folder),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'rename', child: Text('重命名')),
                PopupMenuItem(value: 'delete', child: Text('删除文件夹')),
              ],
              icon: const OpenNoteIcon(Icons.more_horiz, size: 18),
            ),
    ),
  );

  Widget _card(ProjectSummary item, {bool loadCover = true}) {
    final stamp = item.lastOpenedAt?.toLocal();
    final recent = stamp == null
        ? '尚未开始阅读'
        : '最近打开 ${stamp.month}月${stamp.day}日';
    final details =
        '${item.documentCount} 文档  ·  ${item.mapCount} 脑图  ·  ${item.cardCount} 卡片';
    final caption = _query.isNotEmpty
        ? '${item.folderTitle ?? '未分类'} · $recent'
        : recent;
    return Material(
      color: _hoveredProject == item.project.id
          ? const Color(0xfff7f8f9)
          : Colors.transparent,
      animationDuration: const Duration(milliseconds: 140),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: _focusedProject == item.project.id
              ? OpenNoteTokens.accent
              : Colors.transparent,
          width: _focusedProject == item.project.id ? 2 : 1,
        ),
      ),
      child: Semantics(
        container: true,
        identifier: 'project-card-${item.project.id}',
        button: true,
        enabled: !_busy,
        child: InkWell(
          key: ValueKey('project-card-${item.project.id}'),
          onHover: (value) =>
              setState(() => _hoveredProject = value ? item.project.id : null),
          onFocusChange: (value) =>
              setState(() => _focusedProject = value ? item.project.id : null),
          onTap: _busy
              ? null
              : () => _run(() => widget.onOpenProject(item.project.id)),
          focusColor: OpenNoteTokens.selected,
          hoverColor: const Color(0x04292c30),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: 232,
                  child: ProjectCover(
                    cache: widget.covers,
                    path: loadCover ? item.coverPath : null,
                    hash: loadCover ? item.coverHash : null,
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 4),
                          // 日期跟随实际标题高度，不为单行名称预留第二行。
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Tooltip(
                              message: item.project.title,
                              child: Text(
                                item.project.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 16,
                                  height: 1.4,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Tooltip(
                              message: '$caption\n$details',
                              child: Text(
                                caption,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 11,
                                  height: 1.4,
                                  color: Color(0xff8a8e94),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 36,
                      height: 36,
                      child: PopupMenuButton<String>(
                        tooltip: '管理项目 ${item.project.title}',
                        enabled: !_busy,
                        padding: EdgeInsets.zero,
                        icon: const OpenNoteIcon(
                          Icons.more_horiz,
                          size: 18,
                          color: OpenNoteTokens.secondary,
                        ),
                        onSelected: (value) => _projectAction(value, item),
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'rename', child: Text('重命名')),
                          PopupMenuItem(value: 'move', child: Text('移动到文件夹…')),
                          PopupMenuItem(value: 'delete', child: Text('移入回收站')),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) return const SizedBox.shrink();
    return Focus(
      autofocus: true,
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent ||
            !HardwareKeyboard.instance.isControlPressed) {
          return KeyEventResult.ignored;
        }
        if (event.logicalKey == LogicalKeyboardKey.keyF) {
          _searchFocus.requestFocus();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.keyN) {
          unawaited(_createProject());
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final sidebar = constraints.maxWidth >= 760;
          return Scaffold(
            key: _scaffold,
            drawer: sidebar ? null : SizedBox(width: 232, child: _navigation()),
            body: Column(
              children: [
                OpenNoteWindowBar(
                  child: OpenNoteWindowDrag(
                    child: Container(
                      color: OpenNoteTokens.surface,
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: const Row(
                        children: [
                          OpenNoteIcon(Icons.auto_stories_outlined, size: 22),
                          SizedBox(width: 12),
                          Text(
                            'OpenNote',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: Row(
                    children: [
                      if (sidebar) SizedBox(width: 232, child: _navigation()),
                      Expanded(
                        child: Padding(
                          padding: EdgeInsets.all(
                            constraints.maxWidth < 1000 ? 24 : 36,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  if (!sidebar)
                                    IconButton(
                                      tooltip: '项目文件夹',
                                      onPressed: () =>
                                          _scaffold.currentState?.openDrawer(),
                                      icon: const OpenNoteIcon(Icons.menu),
                                    ),
                                  Expanded(
                                    child: Row(
                                      children: [
                                        Flexible(
                                          child: Text(
                                            '项目',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: Theme.of(context)
                                                .textTheme
                                                .headlineMedium
                                                ?.copyWith(
                                                  fontSize: 24,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                          ),
                                        ),
                                        if (constraints.maxWidth >= 1000) ...[
                                          const SizedBox(width: 16),
                                          Text(
                                            '$_total 个项目',
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodySmall,
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                  SizedBox(
                                    width:
                                        (constraints.maxWidth -
                                                (sidebar ? 232 : 0) -
                                                240)
                                            .clamp(120.0, 280.0),
                                    child: OpenNoteSearch(
                                      inputKey: const Key('project-search'),
                                      controller: _search,
                                      focusNode: _searchFocus,
                                      label: '搜索项目 Ctrl+F',
                                      collapsedAlignment: Alignment.centerRight,
                                      onChanged: (value) {
                                        _searchTimer?.cancel();
                                        _searchTimer = Timer(
                                          const Duration(milliseconds: 180),
                                          () {
                                            _rememberPosition();
                                            if (_scroll.hasClients) {
                                              _scroll.jumpTo(0);
                                            }
                                            setState(
                                              () => _query = value.trim(),
                                            );
                                            unawaited(_reload(remember: false));
                                          },
                                        );
                                      },
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  PopupMenuButton<ProjectSort>(
                                    tooltip:
                                        '排序：${switch (_sort) {
                                          ProjectSort.recent => '最近打开',
                                          ProjectSort.name => '项目名称',
                                          ProjectSort.created => '创建时间',
                                        }}',
                                    icon: const OpenNoteIcon(Icons.sort),
                                    enabled: !_busy,
                                    onSelected: (value) {
                                      _rememberPosition();
                                      setState(() => _sort = value);
                                      unawaited(_reload(remember: false));
                                    },
                                    itemBuilder: (_) => [
                                      CheckedPopupMenuItem(
                                        checked: _sort == ProjectSort.recent,
                                        value: ProjectSort.recent,
                                        child: Text('最近打开'),
                                      ),
                                      CheckedPopupMenuItem(
                                        checked: _sort == ProjectSort.name,
                                        value: ProjectSort.name,
                                        child: Text('项目名称'),
                                      ),
                                      CheckedPopupMenuItem(
                                        checked: _sort == ProjectSort.created,
                                        value: ProjectSort.created,
                                        child: Text('创建时间'),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(width: 4),
                                  Tooltip(
                                    message: '新建学习项目 Ctrl+N',
                                    child: IconButton(
                                      key: const Key('home-new-project'),
                                      onPressed: _busy ? null : _createProject,
                                      style: IconButton.styleFrom(
                                        foregroundColor: OpenNoteTokens.accent,
                                        backgroundColor: OpenNoteTokens.surface,
                                      ),
                                      icon: const OpenNoteIcon(
                                        Icons.add,
                                        size: 18,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 24),
                              Row(
                                key: ValueKey('project-results-$_total'),
                                children: [
                                  Text(
                                    _heading,
                                    style: const TextStyle(
                                      fontSize: 13,
                                      color: OpenNoteTokens.secondary,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              const Divider(height: 1, thickness: 1),
                              const SizedBox(height: 24),
                              if (_error != null)
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        _error!,
                                        style: const TextStyle(
                                          color: Colors.red,
                                        ),
                                      ),
                                    ),
                                    TextButton(
                                      onPressed: _reload,
                                      child: const Text('重试'),
                                    ),
                                  ],
                                ),
                              Expanded(
                                child: _items.isEmpty
                                    ? Center(
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const OpenNoteIcon(
                                              Icons.auto_stories_outlined,
                                              size: 52,
                                              color: OpenNoteTokens.muted,
                                            ),
                                            const SizedBox(height: 20),
                                            Text(
                                              _loading
                                                  ? '正在整理项目…'
                                                  : _query.isNotEmpty
                                                  ? '没有找到项目'
                                                  : '暂无项目',
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .titleLarge,
                                            ),
                                            if (!_loading && _query.isEmpty)
                                              Padding(
                                                padding: const EdgeInsets.only(
                                                  top: 24,
                                                ),
                                                child: OutlinedButton(
                                                  onPressed: _busy
                                                      ? null
                                                      : _createProject,
                                                  child: const Text('创建第一个项目'),
                                                ),
                                              ),
                                          ],
                                        ),
                                      )
                                    : LayoutBuilder(
                                        builder: (context, box) {
                                          final scale =
                                              MediaQuery.textScalerOf(context)
                                                  .scale(16) /
                                              16;
                                          // 固定书格宽度，空位留白；窗口增宽只增加列数。
                                          final cardWidth = math.min(
                                            200.0,
                                            box.maxWidth,
                                          );
                                          const gap = 64.0;
                                          const rowGap = 48.0;
                                          final columns = math.max(
                                            1,
                                            ((box.maxWidth + gap) /
                                                    (cardWidth + gap))
                                                .floor(),
                                          );
                                          final height =
                                              232.0 +
                                              16.0 +
                                              math.max(
                                                36.0,
                                                4.0 +
                                                    (44.8 * scale)
                                                        .ceilToDouble() +
                                                    4.0 +
                                                    (15.4 * scale)
                                                        .ceilToDouble(),
                                              ) +
                                              24.0;
                                          final trailingSpace = math.max(
                                            0.0,
                                            box.maxWidth -
                                                columns * cardWidth -
                                                (columns - 1) * gap,
                                          );
                                          return CustomScrollView(
                                            key: const Key(
                                              'project-grid-scroll',
                                            ),
                                            controller: _scroll,
                                            scrollCacheExtent:
                                                ScrollCacheExtent.pixels(
                                                  height + rowGap,
                                                ),
                                            slivers: [
                                              SliverLayoutBuilder(
                                                builder: (context, viewport) {
                                                  final rowHeight =
                                                      height + rowGap;
                                                  final firstRow =
                                                      (viewport.scrollOffset /
                                                              rowHeight)
                                                          .floor();
                                                  final lastRow =
                                                      ((viewport.scrollOffset +
                                                                  viewport
                                                                      .remainingPaintExtent) /
                                                              rowHeight)
                                                          .ceil();
                                                  return SliverPadding(
                                                    padding: EdgeInsets.only(
                                                      right: trailingSpace,
                                                    ),
                                                    sliver: SliverGrid(
                                                      gridDelegate:
                                                          SliverGridDelegateWithFixedCrossAxisCount(
                                                            crossAxisCount:
                                                                columns,
                                                            mainAxisExtent:
                                                                height,
                                                            crossAxisSpacing:
                                                                gap,
                                                            mainAxisSpacing:
                                                                rowGap,
                                                          ),
                                                      delegate: SliverChildBuilderDelegate(
                                                        (
                                                          context,
                                                          index,
                                                        ) => _card(
                                                          _items[index],
                                                          loadCover:
                                                              index ~/
                                                                      columns >=
                                                                  firstRow &&
                                                              index ~/
                                                                      columns <=
                                                                  lastRow,
                                                        ),
                                                        childCount:
                                                            _items.length,
                                                      ),
                                                    ),
                                                  );
                                                },
                                              ),
                                              if (_loadingMore)
                                                const SliverToBoxAdapter(
                                                  child: Padding(
                                                    padding: EdgeInsets.all(20),
                                                    child: Center(
                                                      child:
                                                          CircularProgressIndicator(),
                                                    ),
                                                  ),
                                                ),
                                            ],
                                          );
                                        },
                                      ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
