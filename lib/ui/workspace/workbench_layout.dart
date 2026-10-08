import 'package:flutter/material.dart';

import '../theme/open_note_theme.dart';
import '../theme/open_note_window_bar.dart';

/// 只负责响应式呈现；资料、编辑和分栏命令仍由工作台持有。
class WorkbenchLayout extends StatelessWidget {
  const WorkbenchLayout({
    super.key,
    required this.libraryVisible,
    required this.library,
    required this.panesBuilder,
    this.immersive = false,
    this.editor,
  });
  final bool libraryVisible;
  final Widget library;
  final Widget Function(double editorInset) panesBuilder;
  final bool immersive;
  final Widget? editor;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final showLibrary = !immersive && libraryVisible && box.maxWidth >= 1280;
      final dockEditor = box.maxWidth >= 1600;
      return Stack(
        children: [
          Positioned.fill(
            child: Row(
              children: [
                Visibility(
                  visible: showLibrary,
                  maintainState: true,
                  child: SizedBox(width: 208, child: library),
                ),
                Expanded(
                  child: panesBuilder(editor != null && dockEditor ? 372 : 0),
                ),
              ],
            ),
          ),
          if (editor != null)
            Positioned(
              key: const Key('workspace-card-editor'),
              right: immersive && dockEditor ? 0 : (dockEditor ? 6 : 16),
              top: immersive && dockEditor ? 0 : (dockEditor ? 6 : 16),
              bottom: immersive && dockEditor ? 0 : (dockEditor ? 6 : 16),
              width: dockEditor ? 360 : (box.maxWidth - 32).clamp(0.0, 360.0),
              // 固定层级与 key，跨断点时保留输入、选区与焦点。
              child: Material(
                elevation: dockEditor ? 0 : 1,
                shadowColor: const Color(0x14292c30),
                clipBehavior: Clip.antiAlias,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(
                    OpenNoteTokens.paneRadius,
                  ),
                  side: const BorderSide(color: OpenNoteTokens.border),
                ),
                child: editor,
              ),
            ),
        ],
      );
    },
  );
}

class WorkbenchSplit extends StatelessWidget {
  const WorkbenchSplit({
    super.key,
    required this.pdfVisible,
    required this.mapVisible,
    required this.fraction,
    required this.onChanged,
    required this.pdf,
    required this.map,
    this.mapTrailingInset = 0,
  });
  final bool pdfVisible;
  final bool mapVisible;
  final double fraction;
  final ValueChanged<double> onChanged;
  final Widget pdf;
  final Widget map;
  final double mapTrailingInset;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      if (!pdfVisible || !mapVisible) {
        return PaneSurface(
          child: Padding(
            padding: EdgeInsets.only(right: mapTrailingInset),
            child: mapVisible ? map : pdf,
          ),
        );
      }
      final usable = box.maxWidth - 8;
      final left = (usable * fraction).clamp(
        usable >= 640 ? 360.0 : usable * .4,
        usable >= 640 ? usable - 280 - mapTrailingInset : usable * .6,
      );
      return Row(
        children: [
          SizedBox(
            width: left,
            child: PaneSurface(child: pdf),
          ),
          MouseRegion(
            cursor: SystemMouseCursors.resizeColumn,
            child: GestureDetector(
              key: const Key('workspace-divider'),
              onHorizontalDragUpdate: (event) => onChanged(
                (fraction + event.delta.dx / usable).clamp(.25, .75),
              ),
              child: Container(
                width: 8,
                color: OpenNoteTokens.surface,
                child: const Center(
                  child: SizedBox(
                    width: 1,
                    height: double.infinity,
                    child: ColoredBox(color: OpenNoteTokens.border),
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(right: mapTrailingInset),
              child: PaneSurface(child: map),
            ),
          ),
        ],
      );
    },
  );
}

class PaneSurface extends StatelessWidget {
  const PaneSurface({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      color: OpenNoteTokens.surface,
      // 文档与画布连续铺开，浮动工具组承担视觉分区。
      borderRadius: BorderRadius.zero,
    ),
    child: child,
  );
}

class WorkbenchBar extends StatelessWidget {
  const WorkbenchBar({super.key, required this.child, this.active = true});
  final Widget child;
  final bool active;
  @override
  Widget build(BuildContext context) =>
      OpenNoteWindowBar(active: active, child: child);
}
