import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_driver/driver_extension.dart';
import 'package:opennote/application/workspace_controller.dart';
import 'package:opennote/data/open_note_repository.dart';
import 'package:opennote/domain/models.dart';
import 'package:opennote/main.dart';
import 'package:opennote/platform/window_fullscreen.dart';
import 'package:pdfrx/pdfrx.dart';

/// UI 验收入口，只用显式 .local 临时资料库，不使用或迁移正式数据。
Future<void> main(List<String> arguments) async {
  final root = arguments
      .singleWhere((a) => a.startsWith('--data-dir='))
      .substring('--data-dir='.length);
  if (!Directory(root).absolute.path.contains('.local')) {
    throw ArgumentError('UI 验收必须使用 .local 隔离资料库');
  }
  late OpenNoteRepository repository;
  final state = <String, Object?>{};
  enableFlutterDriverExtension(
    handler: (request) async {
      final command = jsonDecode(request!) as Map<String, dynamic>;
      if (command['action'] == 'state') {
        final cards = await repository.listCards(state['project'] as String);
        return jsonEncode({
          ...state,
          'cards': [
            for (final card in cards)
              {'id': card.id, 'title': card.title, 'body': card.body},
          ],
        });
      }
      if (command['action'] == 'fullscreen') {
        return jsonEncode(
          await const WindowFullscreen().setFullscreen(
            command['enabled'] as bool,
          ),
        );
      }
      throw ArgumentError('未知验收命令');
    },
  );
  await pdfrxFlutterInitialize();
  repository = await OpenNoteRepository.open(rootPath: root);
  final project = await repository.createProject('阅读与思考');
  final map = (await repository.listMaps(project.id)).single;
  final setup = WorkspaceController(repository);
  await setup.initialize(projectId: project.id);
  final epub = await setup.importDocument(
    'tools/fixtures/epub/epub3-reflow.epub',
  );
  final pdf = await setup.importDocument('tools/fixtures/pdf/ui-reading.pdf');
  final topic = await repository.createExcerpt(
    ExcerptDraft(
      projectId: project.id,
      mapId: map.id,
      title: '从阅读到理解',
      text: '阅读之后，用自己的语言记录核心观点，再连接到已有的经验。',
      anchors: const [],
      x: 80,
      y: 220,
    ),
  );
  for (final title in ['保留原文上下文', '用自己的话表达', '建立概念间的联系']) {
    await repository.createExcerpt(
      ExcerptDraft(
        projectId: project.id,
        mapId: map.id,
        parentNodeId: topic.node.id,
        title: title,
        text: '把阅读内容整理为独立卡片，随时回到原文核对。',
        anchors: const [],
      ),
    );
  }
  await setup.persistResume();
  setup.dispose();
  state.addAll({
    'project': project.id,
    'epub': epub.id,
    'pdf': pdf.id,
    'rootNode': topic.node.id,
    'rootCard': topic.card.id,
  });
  runApp(OpenNoteApp(startup: Future.value(repository)));
}
