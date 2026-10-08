import '../theme/open_note_icon.dart';

import 'package:flutter/material.dart';

import '../../domain/models.dart';
import '../theme/open_note_theme.dart';
import '../theme/open_note_view_switch.dart';
import '../theme/open_note_search.dart';

/// 资料导航不访问仓储，也不持有工作台命令或编辑会话。
class WorkspaceLibrary extends StatelessWidget {
  const WorkspaceLibrary({
    super.key,
    required this.allDocuments,
    required this.allMaps,
    required this.allCards,
    required this.filter,
    required this.cardsTab,
    required this.onTabChanged,
    required this.onFilterChanged,
    required this.onDocumentSelected,
    required this.onMapSelected,
    required this.onCardSelected,
    required this.onDocumentAction,
    required this.onMapAction,
    required this.onCardAction,
    this.selectedDocumentId,
    this.selectedMapId,
    this.selectedCardId,
    this.onNewMap,
    this.onImportPdf,
  });
  final List<ManagedDocument> allDocuments;
  final List<MindMap> allMaps;
  final List<NoteCard> allCards;
  final TextEditingController filter;
  final bool cardsTab;
  final String? selectedDocumentId, selectedMapId, selectedCardId;
  final ValueChanged<bool> onTabChanged;
  final ValueChanged<String> onFilterChanged;
  final ValueChanged<ManagedDocument> onDocumentSelected;
  final ValueChanged<MindMap> onMapSelected;
  final ValueChanged<NoteCard> onCardSelected;
  final void Function(ManagedDocument, String) onDocumentAction;
  final void Function(MindMap, String) onMapAction;
  final void Function(NoteCard, String) onCardAction;
  final VoidCallback? onNewMap;
  final VoidCallback? onImportPdf;

  @override
  Widget build(BuildContext context) {
    final query = filter.text.trim().toLowerCase();
    final documents = allDocuments
        .where((item) => item.title.toLowerCase().contains(query))
        .toList();
    final maps = allMaps
        .where((item) => item.title.toLowerCase().contains(query))
        .toList();
    final cards = allCards
        .where(
          (item) => '${item.title}\n${item.body}\n${item.note}'
              .toLowerCase()
              .contains(query),
        )
        .toList();
    return Material(
      color: OpenNoteTokens.background,
      child: ListTileTheme(
        data: ListTileTheme.of(context).copyWith(
          selectedColor: OpenNoteTokens.text,
          selectedTileColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          minTileHeight: 40,
          horizontalTitleGap: 6,
          contentPadding: const EdgeInsets.only(left: 10, right: 2),
          titleTextStyle: Theme.of(context).textTheme.bodyMedium?.copyWith(
            fontSize: 13,
            fontWeight: FontWeight.w400,
            color: OpenNoteTokens.text,
          ),
        ),
        child: Column(
          children: [
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SizedBox(
                width: double.infinity,
                child: OpenNoteViewSwitch(
                  value: cardsTab,
                  labels: const ['资料', '卡片'],
                  icons: const [
                    Icons.folder_open_outlined,
                    Icons.layers_outlined,
                  ],
                  expand: true,
                  iconOnly: false,
                  onChanged: onTabChanged,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
              child: OpenNoteSearch(
                inputKey: const Key('workspace-library-filter'),
                controller: filter,
                onChanged: onFilterChanged,
                label: cardsTab ? '筛选卡片' : '筛选资料',
              ),
            ),
            Expanded(
              child: cardsTab
                  ? cards.isEmpty
                        ? const Center(
                            child: Text(
                              '暂无卡片',
                              style: TextStyle(color: OpenNoteTokens.secondary),
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            itemCount: cards.length,
                            itemBuilder: (context, index) {
                              final card = cards[index];
                              return ListTile(
                                dense: false,
                                selected: card.id == selectedCardId,
                                title: Text(
                                  card.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                onTap: () => onCardSelected(card),
                                trailing: PopupMenuButton<String>(
                                  icon: const OpenNoteIcon(
                                    Icons.more_horiz,
                                    size: 18,
                                  ),
                                  tooltip: '卡片操作',
                                  onSelected: (action) =>
                                      onCardAction(card, action),
                                  itemBuilder: (_) => const [
                                    PopupMenuItem(
                                      value: 'place',
                                      child: Text('放入当前脑图'),
                                    ),
                                    PopupMenuItem(
                                      value: 'trash',
                                      child: Text('移入回收站'),
                                    ),
                                  ],
                                ),
                              );
                            },
                          )
                  : ListView(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      children: [
                        Row(
                          children: [
                            const SizedBox(width: 14),
                            const Text(
                              '阅读资料',
                              style: TextStyle(
                                fontSize: 12,
                                color: OpenNoteTokens.secondary,
                              ),
                            ),
                            const Spacer(),
                            IconButton(
                              key: const Key('workspace-library-import-pdf'),
                              icon: const OpenNoteIcon(Icons.add),
                              tooltip: '添加文档',
                              onPressed: onImportPdf,
                            ),
                          ],
                        ),
                        if (documents.isEmpty)
                          Padding(
                            padding: EdgeInsets.all(14),
                            child: Text(
                              query.isEmpty ? '暂无资料' : '没有匹配的文档',
                              style: TextStyle(color: OpenNoteTokens.secondary),
                            ),
                          ),
                        for (final document in documents)
                          ListTile(
                            key: ValueKey('workspace-document-${document.id}'),
                            dense: false,
                            selected: document.id == selectedDocumentId,
                            leading: _LibraryGlyph(
                              document.format == DocumentFormat.epub
                                  ? Icons.menu_book_outlined
                                  : Icons.description_outlined,
                              selected: document.id == selectedDocumentId,
                            ),
                            title: Text(
                              document.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: () => onDocumentSelected(document),
                            trailing: PopupMenuButton<String>(
                              icon: const OpenNoteIcon(
                                Icons.more_horiz,
                                size: 18,
                              ),
                              key: ValueKey('document-menu-${document.id}'),
                              tooltip: '文档操作',
                              onSelected: (action) =>
                                  onDocumentAction(document, action),
                              itemBuilder: (_) => const [
                                PopupMenuItem(
                                  value: 'rename',
                                  child: Text('重命名…'),
                                ),
                                PopupMenuItem(
                                  value: 'trash',
                                  child: Text('移入回收站'),
                                ),
                              ],
                            ),
                          ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            const SizedBox(width: 14),
                            const Text(
                              '知识空间',
                              style: TextStyle(
                                fontSize: 12,
                                color: OpenNoteTokens.secondary,
                              ),
                            ),
                            const Spacer(),
                            IconButton(
                              icon: const OpenNoteIcon(Icons.add),
                              tooltip: '新建脑图',
                              onPressed: onNewMap,
                            ),
                          ],
                        ),
                        for (final map in maps)
                          ListTile(
                            dense: false,
                            selected: map.id == selectedMapId,
                            leading: _LibraryGlyph(
                              Icons.hub_outlined,
                              selected: map.id == selectedMapId,
                            ),
                            title: Text(
                              map.title,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: () => onMapSelected(map),
                            trailing: PopupMenuButton<String>(
                              icon: const OpenNoteIcon(
                                Icons.more_horiz,
                                size: 18,
                              ),
                              key: ValueKey('map-menu-${map.id}'),
                              tooltip: '脑图操作',
                              onSelected: (action) => onMapAction(map, action),
                              itemBuilder: (_) => const [
                                PopupMenuItem(
                                  value: 'rename',
                                  child: Text('重命名…'),
                                ),
                                PopupMenuItem(
                                  value: 'trash',
                                  child: Text('移入回收站'),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LibraryGlyph extends StatelessWidget {
  const _LibraryGlyph(this.icon, {this.selected = false});
  final IconData icon;
  final bool selected;
  @override
  Widget build(BuildContext context) => Container(
    width: 20,
    height: 24,
    decoration: BoxDecoration(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(7),
    ),
    child: OpenNoteIcon(
      icon,
      size: 19,
      color: selected ? OpenNoteTokens.accent : OpenNoteTokens.secondary,
    ),
  );
}
