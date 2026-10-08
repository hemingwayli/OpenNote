import 'open_note_icon.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../platform/window_chrome.dart';
import 'open_note_theme.dart';

/// 标记真正的空白／标题区域，工具按钮不进入原生拖动命中区。
class OpenNoteWindowDrag extends SingleChildRenderObjectWidget {
  const OpenNoteWindowDrag({super.key, super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _DragRegion();
}

class _DragRegion extends RenderProxyBox {}

/// 与页面工具合并的一体式窗口栏。原生层提供贴靠和边框缩放。
class OpenNoteWindowBar extends StatefulWidget {
  const OpenNoteWindowBar({super.key, required this.child, this.active = true});
  final Widget child;
  final bool active;

  @override
  State<OpenNoteWindowBar> createState() => _OpenNoteWindowBarState();
}

class _OpenNoteWindowBarState extends State<OpenNoteWindowBar>
    with WidgetsBindingObserver {
  final _maximum = GlobalKey();
  final _maximumStates = WidgetStatesController();
  bool _scheduled = false;
  List<Map<String, double>>? _lastRegions;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WindowChrome.maximizeInteraction.addListener(_updateMaximumStates);
    _updateMaximumStates();
  }

  @override
  void didChangeMetrics() => _schedule();

  @override
  void dispose() {
    WindowChrome.maximizeInteraction.removeListener(_updateMaximumStates);
    _maximumStates.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _updateMaximumStates() {
    // 原生 HTMAXBUTTON 不向 Flutter 发送鼠标事件，复用按钮自身的同一套动效。
    final interaction = WindowChrome.maximizeInteraction.value;
    _maximumStates.update(WidgetState.hovered, interaction.hovered);
    _maximumStates.update(WidgetState.pressed, interaction.pressed);
  }

  void _schedule() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) return;
      final regions = <Map<String, double>>[];
      void add(RenderBox box, double role) {
        if (box.hasSize && box.size.width > 0) {
          final offset = box.localToGlobal(Offset.zero);
          regions.add({
            'x': offset.dx,
            'y': offset.dy,
            'width': box.size.width,
            'height': box.size.height,
            'role': role,
          });
        }
      }

      void visit(RenderObject object) {
        if (object is _DragRegion) {
          add(object, 0);
        } else {
          object.visitChildren(visit);
        }
      }

      // 弹窗／菜单打开时不能让下方的窗口区域截获鼠标。
      final route = ModalRoute.of(context);
      var visible = true;
      RenderObject? ancestor = context.findRenderObject();
      while (ancestor != null) {
        if (ancestor is RenderOffstage && ancestor.offstage) visible = false;
        ancestor = ancestor.parent;
      }
      if (widget.active &&
          visible &&
          (route == null || route.isCurrent) &&
          !(Scaffold.maybeOf(context)?.isDrawerOpen ?? false)) {
        final box = context.findRenderObject();
        if (box != null && box.attached) visit(box);
        final maximum = _maximum.currentContext?.findRenderObject();
        if (maximum is RenderBox) add(maximum, 1);
      }
      if (_lastRegions.toString() == regions.toString()) return;
      _lastRegions = regions;
      unawaited(
        WindowChrome.updateRegions(regions).catchError((Object error) {
          if (mounted) _error(error);
        }),
      );
    });
  }

  void _error(Object error) {
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text('窗口操作失败：$error')));
  }

  void _action(String action) {
    unawaited(
      WindowChrome.action(action).catchError((Object error) {
        if (mounted) _error(error);
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    ModalRoute.of(context); // 订阅弹窗覆盖状态。
    _schedule();
    return Material(
      color: OpenNoteTokens.surface,
      child: SizedBox(
        height: 56,
        child: Row(
          children: [
            Expanded(child: widget.child),
            const SizedBox(width: 12),
            _control('最小化', Icons.remove, 'minimize'),
            ValueListenableBuilder<bool>(
              valueListenable: WindowChrome.maximized,
              builder: (_, maximized, _) => _control(
                maximized ? '还原窗口' : '最大化',
                maximized ? Icons.filter_none : Icons.crop_square,
                'toggleMaximize',
                key: _maximum,
                statesController: _maximumStates,
              ),
            ),
            _control('关闭窗口', Icons.close, 'requestClose', close: true),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }

  Widget _control(
    String tooltip,
    IconData icon,
    String action, {
    Key? key,
    WidgetStatesController? statesController,
    bool close = false,
  }) => SizedBox(
    key: key,
    width: 40,
    height: 36,
    child: IconButton(
      statesController: statesController,
      tooltip: tooltip,
      onPressed: () => _action(action),
      style: IconButton.styleFrom(hoverColor: Colors.transparent).copyWith(
        // 背景直接按同一按钮状态绘制，原生悬停也能触发 Material 过渡动画。
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.hovered)
              ? close
                    ? const Color(0xffffe5e0)
                    : OpenNoteTokens.hover
              : Colors.transparent,
        ),
      ),
      icon: OpenNoteIcon(icon, size: 16),
    ),
  );
}
