import 'package:flutter/material.dart';

import '../ui/theme/open_note_theme.dart';

import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/widget_previews.dart';
import 'package:material_ui/material_ui.dart' as material_ui;

import '../domain/models.dart';
import '../ui/map/map_outline_pane.dart';
import '../ui/map/mind_map_pane.dart';
import '../ui/workspace/card_editor.dart';
import '../ui/workspace/text_input_dialog.dart';

/// 开发预览只持有内存样例；不打开资料库、文件、PDF 或 OCR。
Widget previewFrame(Widget child) => MaterialApp(
  debugShowCheckedModeBanner: false,
  locale: const Locale('zh', 'CN'),
  supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
  localizationsDelegates: const [
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    material_ui.GlobalMaterialLocalizations.delegate,
  ],
  theme: openNoteTheme(),
  builder: (context, child) =>
      material_ui.Theme(data: material_ui.ThemeData.light(), child: child!),
  home: Scaffold(body: child),
);

@Preview(group: '输入与按钮', name: '项目命名 · 可编辑与禁用状态', size: Size(520, 320))
Widget namingDialogPreview() => previewFrame(
  const Center(
    child: TextInputDialog(
      title: '新建学习项目',
      initialText: '阅读与思考',
      hint: '输入项目名称',
      requireText: true,
    ),
  ),
);

@Preview(group: '卡片与工具栏', name: '卡片编辑 · 桌面', size: Size(420, 660))
@Preview(
  group: '卡片与工具栏',
  name: '卡片编辑 · 窄栏与放大文字',
  size: Size(320, 660),
  textScaleFactor: 1.25,
)
Widget cardEditorPreview() => previewFrame(const _CardPreview());

class _CardPreview extends StatefulWidget {
  const _CardPreview();

  @override
  State<_CardPreview> createState() => _CardPreviewState();
}

class _CardPreviewState extends State<_CardPreview> {
  final _controller = CardEditorController();
  String _status = '内存预览';

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Expanded(
        child: CardEditor(
          card: _cards['card-root']!,
          controller: _controller,
          imagePath: null,
          onSave: (title, body, note) async {},
          onBackToSource: () => setState(() => _status = '预览未连接 PDF'),
          onSaveState: (value) => setState(() => _status = value),
          onClose: () => setState(() => _status = '收起按钮已响应'),
        ),
      ),
      Padding(padding: const EdgeInsets.all(8), child: Text(_status)),
    ],
  );
}

@Preview(group: '脑图卡片', name: '实际画布 · 选中与缩放', size: Size(900, 520))
Widget mindMapPreview() => previewFrame(const _MapPreview(outline: false));

@Preview(group: '侧栏与工具栏', name: '实际大纲侧栏', size: Size(360, 540))
@Preview(
  group: '侧栏与工具栏',
  name: '大纲侧栏 · 窄栏与放大文字',
  size: Size(280, 540),
  textScaleFactor: 1.25,
)
Widget outlineSidebarPreview() =>
    previewFrame(const _MapPreview(outline: true));

class _MapPreview extends StatefulWidget {
  const _MapPreview({required this.outline});
  final bool outline;

  @override
  State<_MapPreview> createState() => _MapPreviewState();
}

class _MapPreviewState extends State<_MapPreview> {
  String? _selected = 'root';
  final _collapsed = <String>{};
  final _positions = <String, PdfPoint>{};

  MapSnapshot get _snapshot => MapSnapshot(
    map: const MindMap(
      layout: MapLayoutKind.free,
      id: 'preview-map',
      projectId: 'preview',
      title: '阅读与思考',
    ),
    nodes: [
      for (final node in _nodes)
        MapNode(
          id: node.id,
          mapId: node.mapId,
          cardId: node.cardId,
          parentNodeId: node.parentNodeId,
          x: _positions[node.id]?.x ?? node.x,
          y: _positions[node.id]?.y ?? node.y,
          collapsed: _collapsed.contains(node.id),
        ),
    ],
    cards: _cards,
    anchors: const {},
    edges: const [],
  );

  void _select(MapNode node) => setState(() => _selected = node.id);

  void _toggle(String id) => setState(() {
    if (!_collapsed.add(id)) _collapsed.remove(id);
  });

  @override
  Widget build(BuildContext context) => widget.outline
      ? MapOutlinePane(
          snapshot: _snapshot,
          selectedNodeId: _selected,
          onSelect: _select,
          onAction: (_, _) {},
          onToggleCollapsed: _toggle,
        )
      : MindMapPane(
          snapshot: _snapshot,
          selectedNodeId: _selected,
          onSelect: _select,
          onMove: (id, x, y) async =>
              setState(() => _positions[id] = PdfPoint(x, y)),
          onReparent: (_, _) async {},
          onAssociate: (_, _) async {},
          onRemoveAssociation: (_) {},
          onAction: (_, _) {},
          onToggleCollapsed: _toggle,
        );
}

const _nodes = [
  MapNode(id: 'root', mapId: 'preview-map', cardId: 'card-root', x: 40, y: 140),
  MapNode(
    id: 'child',
    mapId: 'preview-map',
    cardId: 'card-child',
    parentNodeId: 'root',
    x: 340,
    y: 70,
  ),
  MapNode(
    id: 'another',
    mapId: 'preview-map',
    cardId: 'card-another',
    parentNodeId: 'root',
    x: 340,
    y: 240,
  ),
];

const _cards = {
  'card-root': NoteCard(
    id: 'card-root',
    projectId: 'preview',
    title: '阅读与思考',
    excerptSnapshot: '知识需要通过联系与实践加深理解。',
    body: '知识需要通过联系与实践加深理解。\nRead, connect, and reflect.',
    note: '将原文摘录与个人理解分别保存。',
    color: '#F7D976',
  ),
  'card-child': NoteCard(
    id: 'card-child',
    projectId: 'preview',
    title: '建立概念之间的联系',
    excerptSnapshot: '比较相同点与不同点。',
    body: '比较相同点与不同点。',
    note: '支持中文与 English 混合文本。',
    color: '#BFE4D0',
  ),
  'card-another': NoteCard(
    id: 'card-another',
    projectId: 'preview',
    title: '回到原文验证',
    excerptSnapshot: '保留来源与上下文。',
    body: '保留来源与上下文。',
    note: '',
    color: '#BFDAF7',
  ),
};
