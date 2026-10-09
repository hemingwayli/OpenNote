import '../theme/open_note_icon.dart';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../data/open_note_repository.dart';
import '../../domain/models.dart';

/// 首页与项目内回收站共用仓储合同，作用域由调用方明确提供。
class LibraryActions {
  LibraryActions(
    this.context,
    this.repository, {
    this.beforeRestore,
    this.afterRestore,
  });
  final BuildContext context;
  final OpenNoteRepository repository;
  final Future<void> Function()? beforeRestore;
  final Future<void> Function()? afterRestore;

  Future<bool> confirm(String title, String content, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(content),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      ) ==
      true;

  Future<void> backup() async {
    final target = await getSaveLocation(
      suggestedName: 'OpenNote.onbackup',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'OpenNote 完整备份', extensions: ['onbackup']),
      ],
    );
    if (target == null) return;
    await repository.backupTo(target.path);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          behavior: SnackBarBehavior.floating,
          margin: EdgeInsets.fromLTRB(16, 16, 16, 64),
          content: Text('完整备份已保存'),
        ),
      );
    }
  }

  Future<void> restore() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'OpenNote 完整备份',
          extensions: ['onbackup', 'opennote', 'zip'],
        ),
      ],
    );
    if (file == null || !context.mounted) return;
    if (!await confirm(
      '恢复整个资料库',
      '将校验并恢复：\n${file.path}\n\n当前资料库会保留安全备份，恢复后清空本次会话的撤销历史。',
      '恢复',
    )) {
      return;
    }
    try {
      await beforeRestore?.call();
      await repository.restoreFrom(file.path);
    } finally {
      await afterRestore?.call();
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 16, 16, 64),
          content: Text('恢复完成。原资料库备份：${repository.lastSafetyBackupPath}'),
        ),
      );
    }
  }

  Future<void> licenses() async => showLicensePage(
    context: context,
    applicationName: 'OpenNote',
    applicationVersion: '0.1.2',
    applicationLegalese: 'OpenNote contributors · Apache License 2.0',
  );

  Future<void> trash({String? projectId}) async {
    List<TrashEntry> filter(List<TrashEntry> all) => all
        .where(
          (e) =>
              projectId == null ||
              (e.projectId == projectId && e.kind != TrashKind.project),
        )
        .toList();
    var entries = filter(await repository.listTrash());
    if (!context.mounted) return;
    var busy = false;
    String? failure;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) {
          Future<void> perform(Future<void> Function() action) async {
            if (busy) return;
            update(() {
              busy = true;
              failure = null;
            });
            try {
              await action();
              entries = filter(await repository.listTrash());
            } catch (error) {
              failure = '$error';
            } finally {
              if (context.mounted) update(() => busy = false);
            }
          }

          return AlertDialog(
            title: Text(projectId == null ? '回收站' : '当前项目回收站'),
            content: SizedBox(
              width: 640,
              height: 400,
              child: Column(
                children: [
                  if (busy) const LinearProgressIndicator(),
                  if (failure != null)
                    Text(failure!, style: const TextStyle(color: Colors.red)),
                  Expanded(
                    child: entries.isEmpty
                        ? const Center(child: Text('回收站为空'))
                        : ListView.builder(
                            itemCount: entries.length,
                            itemBuilder: (context, index) {
                              final entry = entries[index];
                              return ListTile(
                                title: Text(entry.title),
                                subtitle: Text(switch (entry.kind) {
                                  TrashKind.project => '项目',
                                  TrashKind.document => '文档',
                                  TrashKind.card => '卡片',
                                  TrashKind.map => '脑图',
                                }),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    TextButton(
                                      onPressed: busy
                                          ? null
                                          : () => perform(
                                              () => repository.restoreTrash(
                                                entry.id,
                                              ),
                                            ),
                                      child: const Text('恢复'),
                                    ),
                                    IconButton(
                                      tooltip: '永久清理',
                                      onPressed: busy
                                          ? null
                                          : () => perform(() async {
                                              final preview = await repository
                                                  .previewTrashPurge(
                                                    entry.id,
                                                    discardSessionHistory: true,
                                                  );
                                              if (!context.mounted) return;
                                              if (!preview.canPurge) {
                                                throw StateError(
                                                  preview.blockers.join('\n'),
                                                );
                                              }
                                              if (await confirm(
                                                '永久清理“${entry.title}”',
                                                '将清理 ${preview.cardCount} 张卡片、${preview.documentCount} 份文档、${preview.mapCount} 张脑图。\n此操作不可撤销，并清空本次会话撤销记录。',
                                                '永久清理',
                                              )) {
                                                final result = await repository
                                                    .purgeTrash(
                                                      entry.id,
                                                      discardSessionHistory:
                                                          true,
                                                    );
                                                if (result
                                                    .pendingResourcePaths
                                                    .isNotEmpty) {
                                                  failure =
                                                      '部分文件被占用，将在后续清理时重试。';
                                                }
                                              }
                                            }),
                                      icon: const OpenNoteIcon(
                                        Icons.delete_forever_outlined,
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: busy ? null : () => Navigator.pop(dialogContext),
                child: const Text('关闭'),
              ),
            ],
          );
        },
      ),
    );
  }
}
