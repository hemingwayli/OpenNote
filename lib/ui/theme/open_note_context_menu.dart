import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'open_note_icon.dart';
import 'open_note_theme.dart';

/// 只返回叶子动作，业务命令由调用页面负责。
class OpenNoteMenuEntry<T> {
  const OpenNoteMenuEntry(
    this.value,
    this.label, {
    this.icon,
    this.shortcut,
    this.enabled = true,
    this.danger = false,
    this.key,
    this.children = const [],
  }) : divider = false;
  const OpenNoteMenuEntry.divider()
    : value = null,
      label = '',
      icon = null,
      shortcut = null,
      enabled = false,
      danger = false,
      key = null,
      children = const [],
      divider = true;
  final T? value;
  final String label;
  final IconData? icon;
  final String? shortcut;
  final bool enabled, danger, divider;
  final Key? key;
  final List<OpenNoteMenuEntry<T>> children;
  bool get hasSubmenu => children.isNotEmpty;
}

/// 页面切换或目标失效时，结束尚未派发动作的菜单。
class OpenNoteContextMenuController {
  VoidCallback? _cancel;
  bool get isOpen => _cancel != null;
  void cancel() {
    final cancel = _cancel;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => cancel?.call());
    } else {
      cancel?.call();
    }
  }
}

Future<T?> showOpenNoteContextMenu<T>({
  required BuildContext context,
  required Offset position,
  required List<OpenNoteMenuEntry<T>> entries,
  OpenNoteContextMenuController? controller,
  bool Function()? isValid,
  bool openAbove = false,
}) async {
  if (entries.isEmpty || (isValid != null && !isValid())) return null;
  final previousFocus = FocusManager.instance.primaryFocus;
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  final result = await Navigator.of(context).push<T>(
    _ContextMenuRoute<T>(
      position: overlay.globalToLocal(position),
      openAbove: openAbove,
      entries: entries,
      menuController: controller,
      mediaQuery: MediaQuery.of(context),
      themes: InheritedTheme.capture(
        from: context,
        to: Navigator.of(context).context,
      ),
      isValid: () => context.mounted && (isValid?.call() ?? true),
    ),
  );
  if (context.mounted && previousFocus?.context?.mounted == true) {
    previousFocus!.requestFocus();
  }
  return result;
}

/// 同内容的省略号与右键共用同一个菜单。
class OpenNoteContextMenuButton<T> extends StatefulWidget {
  const OpenNoteContextMenuButton({
    super.key,
    required this.entries,
    required this.onSelected,
    required this.icon,
    required this.tooltip,
    this.onOpened,
    this.isValid,
  });
  final List<OpenNoteMenuEntry<T>> Function() entries;
  final ValueChanged<T> onSelected;
  final Widget icon;
  final String tooltip;
  final VoidCallback? onOpened;
  final bool Function()? isValid;
  @override
  State<OpenNoteContextMenuButton<T>> createState() =>
      _OpenNoteContextMenuButtonState<T>();
}

class _OpenNoteContextMenuButtonState<T>
    extends State<OpenNoteContextMenuButton<T>> {
  final _controller = OpenNoteContextMenuController();
  bool Function()? _openValid;
  @override
  void dispose() {
    _controller.cancel();
    super.dispose();
  }

  Future<void> _open() async {
    if (_controller.isOpen) return;
    widget.onOpened?.call();
    final valid = widget.isValid;
    _openValid = valid;
    final box = context.findRenderObject()! as RenderBox;
    final action = await showOpenNoteContextMenu<T>(
      context: context,
      position: box.localToGlobal(Offset(0, box.size.height)),
      entries: widget.entries(),
      controller: _controller,
      isValid: () => mounted && (valid?.call() ?? true),
    );
    _openValid = null;
    if (mounted && action != null && (valid?.call() ?? true)) {
      widget.onSelected(action);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_controller.isOpen && !(_openValid?.call() ?? true)) {
      _controller.cancel();
    }
    return IconButton(
      tooltip: widget.tooltip,
      onPressed: _open,
      style: IconButton.styleFrom(
        fixedSize: const Size(28, 28),
        minimumSize: const Size(28, 28),
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      icon: widget.icon,
    );
  }
}

class _ContextMenuRoute<T> extends PopupRoute<T> {
  _ContextMenuRoute({
    required this.position,
    required this.openAbove,
    required this.entries,
    required this.isValid,
    required this.mediaQuery,
    required this.themes,
    this.menuController,
  });
  final Offset position;
  final bool openAbove;
  final List<OpenNoteMenuEntry<T>> entries;
  final bool Function() isValid;
  final OpenNoteContextMenuController? menuController;
  final MediaQueryData mediaQuery;
  final CapturedThemes themes;
  @override
  Duration get transitionDuration => Duration.zero;
  @override
  bool get barrierDismissible => false;
  @override
  Color? get barrierColor => null;
  @override
  String get barrierLabel => '关闭菜单';
  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => themes.wrap(
    MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: mediaQuery.textScaler,
        disableAnimations: mediaQuery.disableAnimations,
      ),
      child: _MenuSession<T>(route: this),
    ),
  );
}

class _MenuSession<T> extends StatefulWidget {
  const _MenuSession({required this.route});
  final _ContextMenuRoute<T> route;
  @override
  State<_MenuSession<T>> createState() => _MenuSessionState<T>();
}

class _MenuSessionState<T> extends State<_MenuSession<T>>
    with SingleTickerProviderStateMixin {
  final _anchor = MenuController(), _group = MenuController();
  final _focus = FocusNode(debugLabel: '上下文菜单');
  final _scroll = ScrollController();
  late final _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 120),
  );
  final _children = <_ChildMenu<T>>[];
  Timer? _openDelay, _closeDelay;
  int? _activeChild, _mainIndex, _childIndex;
  int? _pointerMain;
  bool _inChild = false, _closing = false, _finished = false;
  T? _result;
  Rect _mainRect = Rect.zero;
  Offset? _intentOrigin;
  Offset? _pointerMainPosition;
  late _MenuMetrics _mainMetrics;
  late Size _viewport;
  List<OpenNoteMenuEntry<T>> get _entries => widget.route.entries;
  bool get _valid => !_closing && widget.route.isValid();
  Duration get _duration => MediaQuery.disableAnimationsOf(context)
      ? Duration.zero
      : const Duration(milliseconds: 120);

  @override
  void initState() {
    super.initState();
    _mainIndex = _firstEnabled(_entries);
    widget.route.menuController?._cancel = _cancel;
    _scroll.addListener(_closeChild);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!widget.route.isValid()) {
        Navigator.pop(context);
        return;
      }
      _anchor.open();
      _focus.requestFocus();
    });
  }

  void _cancel() => _anchor.close();
  @override
  void dispose() {
    if (widget.route.menuController?._cancel == _cancel) {
      widget.route.menuController?._cancel = null;
    }
    _openDelay?.cancel();
    _closeDelay?.cancel();
    for (final child in _children) {
      child.scroll.dispose();
    }
    _fade.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _closeRequested(VoidCallback hideOverlay) {
    if (_closing || !_anchor.isOpen) return;
    _closing = true;
    _openDelay?.cancel();
    _closeDelay?.cancel();
    setState(() {});
    _fade.duration = _duration;
    _fade.reverse().whenCompleteOrCancel(() {
      hideOverlay();
      _finish();
    });
  }

  void _finish() {
    if (!mounted || _finished) return;
    _finished = true;
    Navigator.pop(context, _result);
  }

  void _choose(OpenNoteMenuEntry<T> entry) {
    if (!_valid) {
      _cancel();
      return;
    }
    if (!entry.enabled || entry.divider) return;
    if (entry.hasSubmenu) {
      _openChild(_entries.indexOf(entry), keyboard: true);
    } else {
      _result = entry.value;
      _cancel();
    }
  }

  int? _firstEnabled(List<OpenNoteMenuEntry<T>> entries) {
    final index = entries.indexWhere(
      (entry) => !entry.divider && entry.enabled,
    );
    return index < 0 ? null : index;
  }

  void _move(int delta) {
    final items = _inChild && _activeChild != null
        ? _entries[_activeChild!].children
        : _entries;
    var index = (_inChild ? _childIndex : _mainIndex) ?? (delta > 0 ? -1 : 0);
    for (var count = 0; count < items.length; count++) {
      index = (index + delta) % items.length;
      if (items[index].enabled && !items[index].divider) {
        setState(() {
          if (_inChild) {
            _childIndex = index;
          } else {
            _mainIndex = index;
          }
        });
        final child = _children.where((item) => item.visible).firstOrNull;
        final scroll = _inChild ? child?.scroll : _scroll;
        final metrics = _inChild ? child?.metrics : _mainMetrics;
        if (scroll != null && metrics != null && scroll.hasClients) {
          final top = metrics.offsets[index],
              bottom = top + metrics.heights[index];
          final position = scroll.position;
          if (top < position.pixels) {
            scroll.jumpTo(top);
          } else if (bottom > position.pixels + position.viewportDimension) {
            scroll.jumpTo(bottom - position.viewportDimension);
          }
        }
        return;
      }
    }
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (!_valid) {
      _cancel();
      return KeyEventResult.handled;
    }
    _openDelay?.cancel();
    _closeDelay?.cancel();
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        _move(1);
      case LogicalKeyboardKey.arrowUp:
        _move(-1);
      case LogicalKeyboardKey.arrowRight:
        if (!_inChild && _mainIndex != null) {
          _openChild(_mainIndex!, keyboard: true);
        }
      case LogicalKeyboardKey.arrowLeft:
        if (_activeChild != null) _closeChild();
      case LogicalKeyboardKey.escape:
        if (_activeChild != null) {
          _closeChild();
        } else {
          _cancel();
        }
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.space:
        final items = _inChild && _activeChild != null
            ? _entries[_activeChild!].children
            : _entries;
        final index = _inChild ? _childIndex : _mainIndex;
        if (index != null) _choose(items[index]);
      case LogicalKeyboardKey.tab:
        _cancel();
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  bool _insideIntent(Offset point) {
    final origin = _intentOrigin;
    final child = _children.where((item) => item.visible).firstOrNull;
    if (origin == null || child == null) return false;
    final x = child.rect.left > _mainRect.left
        ? child.rect.left
        : child.rect.right;
    final a = Offset(x, child.rect.top - 8),
        b = Offset(x, child.rect.bottom + 8);
    double cross(Offset p, Offset q, Offset r) =>
        (p.dx - r.dx) * (q.dy - r.dy) - (q.dx - r.dx) * (p.dy - r.dy);
    final signs = [
      cross(point, origin, a),
      cross(point, a, b),
      cross(point, b, origin),
    ];
    return !(signs.any((value) => value < 0) &&
        signs.any((value) => value > 0));
  }

  void _hoverMain(int index, Offset point) {
    if (!_valid) return;
    _pointerMain = index;
    _pointerMainPosition = point;
    _openDelay?.cancel();
    if (_activeChild != null && _activeChild != index && _insideIntent(point)) {
      _closeDelay?.cancel();
      if (_entries[index].hasSubmenu && _entries[index].enabled) {
        _delayOpen(index);
      } else {
        _closeDelay = Timer(const Duration(milliseconds: 200), () {
          if (!mounted) return;
          _closeChild();
          if (_pointerMain == index) setState(() => _mainIndex = index);
        });
      }
      return;
    }
    setState(() {
      _mainIndex = index;
      _inChild = false;
    });
    if (_activeChild == index) {
      _closeDelay?.cancel();
      _intentOrigin = point;
    } else if (_entries[index].hasSubmenu && _entries[index].enabled) {
      _closeDelay?.cancel();
      _intentOrigin = point;
      _delayOpen(index);
    } else {
      _scheduleClose();
    }
  }

  void _delayOpen(int index) {
    _openDelay = Timer(const Duration(milliseconds: 250), () {
      if (mounted && _valid && _pointerMain == index) _openChild(index);
    });
  }

  void _scheduleClose() {
    if (_activeChild == null || _closeDelay?.isActive == true) return;
    _closeDelay = Timer(const Duration(milliseconds: 200), () {
      if (mounted) _closeChild();
    });
  }

  void _closeChild() {
    _openDelay?.cancel();
    _closeDelay?.cancel();
    if (_activeChild == null) return;
    setState(() {
      for (final child in _children) {
        child.visible = false;
      }
      _activeChild = null;
      _inChild = false;
    });
  }

  void _openChild(int index, {bool keyboard = false}) {
    final entry = _entries[index];
    if (!_valid || !entry.enabled || !entry.hasSubmenu) return;
    _openDelay?.cancel();
    _closeDelay?.cancel();
    if (_pointerMain == index) _intentOrigin = _pointerMainPosition;
    if (_activeChild == index) {
      if (keyboard) setState(() => _inChild = true);
      return;
    }
    final metrics = _MenuMetrics.measure(
      context,
      entry.children,
      (_viewport.width - 20) / 2,
    );
    final rowTop =
        _mainRect.top +
        6 +
        _mainMetrics.offsets[index] -
        (_scroll.hasClients ? _scroll.offset : 0);
    final right = _mainRect.right + 4;
    final x = right + metrics.width <= _viewport.width - 8
        ? right
        : _mainRect.left - 4 - metrics.width;
    final bottom = widget.route.openAbove
        ? math.min(widget.route.position.dy, _viewport.height - 8)
        : _viewport.height - 8;
    final height = math.min(metrics.height, math.max(36.0, bottom - 8));
    final rect = Rect.fromLTWH(
      x,
      rowTop.clamp(8.0, math.max(8.0, bottom - height)),
      metrics.width,
      height,
    );
    setState(() {
      for (final child in _children) {
        child.visible = false;
      }
      // 再次进入同一父项时替换淡出表面，保持键与命中唯一。
      _children.removeWhere((child) {
        if (child.index != index) return false;
        child.scroll.dispose();
        return true;
      });
      _children.add(_ChildMenu(index, metrics, rect));
      _activeChild = index;
      _mainIndex = index;
      _childIndex = _firstEnabled(entry.children);
      _inChild = keyboard;
    });
  }

  Widget _overlay(BuildContext context, RawMenuOverlayInfo info) {
    _viewport = info.overlaySize;
    final hasChildren = _entries.any((entry) => entry.hasSubmenu);
    final limit = hasChildren
        ? (_viewport.width - 20) / 2
        : _viewport.width - 16;
    _mainMetrics = _MenuMetrics.measure(context, _entries, limit);
    final bottom = widget.route.openAbove
        ? math.min(widget.route.position.dy, _viewport.height - 8)
        : _viewport.height - 8;
    final height = math.min(_mainMetrics.height, math.max(36.0, bottom - 8));
    var x = widget.route.position.dx.clamp(
      8.0,
      _viewport.width - 8 - _mainMetrics.width,
    );
    if (hasChildren) {
      final childWidth = _entries
          .where((entry) => entry.hasSubmenu)
          .map(
            (entry) =>
                _MenuMetrics.measure(context, entry.children, limit).width,
          )
          .reduce(math.max);
      final rightBound =
              _viewport.width - 8 - _mainMetrics.width - childWidth - 4,
          leftBound = 8 + childWidth + 4;
      if (x > rightBound && x < leftBound) {
        x = x - rightBound < leftBound - x ? rightBound : leftBound;
      }
    }
    _mainRect = Rect.fromLTWH(
      x,
      (widget.route.position.dy - (widget.route.openAbove ? height : 0)).clamp(
        8.0,
        math.max(8.0, bottom - height),
      ),
      _mainMetrics.width,
      height,
    );
    return TapRegion(
      groupId: info.tapRegionGroupId,
      consumeOutsideTaps: true,
      child: ExcludeFocus(
        excluding: _closing,
        child: ExcludeSemantics(
          excluding: _closing,
          child: IgnorePointer(
            ignoring: _closing,
            child: FadeTransition(
              key: const Key('context-menu-opacity'),
              opacity: _fade,
              child: Stack(
                children: [
                  Positioned.fromRect(
                    rect: _mainRect,
                    child: _MenuPanel<T>(
                      key: const Key('context-menu-main'),
                      entries: _entries,
                      metrics: _mainMetrics,
                      scroll: _scroll,
                      selected: _mainIndex,
                      expanded: _activeChild,
                      onActivate: _choose,
                      onHover: _hoverMain,
                      onExit: (index) {
                        if (_pointerMain == index) _pointerMain = null;
                        _openDelay?.cancel();
                        if (_activeChild == index) _scheduleClose();
                      },
                      onPointerHover: (index, point) {
                        _pointerMainPosition = point;
                        if (_activeChild == index) _intentOrigin = point;
                      },
                    ),
                  ),
                  for (final child in _children)
                    Positioned.fromRect(
                      rect: child.rect,
                      child: _ChildSurface(
                        key: ValueKey('context-menu-child-${child.index}'),
                        visible: child.visible,
                        duration: _duration,
                        onHidden: () {
                          if (mounted && _children.contains(child)) {
                            setState(() => _children.remove(child));
                            child.scroll.dispose();
                          }
                        },
                        child: MouseRegion(
                          onEnter: (_) {
                            _openDelay?.cancel();
                            _closeDelay?.cancel();
                          },
                          onExit: (_) => _scheduleClose(),
                          child: _MenuPanel<T>(
                            entries: _entries[child.index].children,
                            metrics: child.metrics,
                            scroll: child.scroll,
                            selected: _childIndex,
                            onActivate: _choose,
                            onHover: (index, _) {
                              _openDelay?.cancel();
                              _closeDelay?.cancel();
                              setState(() {
                                _inChild = true;
                                _childIndex = index;
                              });
                            },
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Material(
    type: MaterialType.transparency,
    child: Focus(
      focusNode: _focus,
      onKeyEvent: _key,
      child: RawMenuAnchorGroup(
        controller: _group,
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _cancel,
                onSecondaryTap: _cancel,
                child: const SizedBox.expand(),
              ),
            ),
            RawMenuAnchor(
              controller: _anchor,
              consumeOutsideTaps: true,
              onClose: _finish,
              onOpenRequested: (_, showOverlay) {
                showOverlay();
                _fade.duration = _duration;
                _fade.forward();
              },
              onCloseRequested: _closeRequested,
              overlayBuilder: _overlay,
              child: const SizedBox(width: 1, height: 1),
            ),
          ],
        ),
      ),
    ),
  );
}

class _ChildMenu<T> {
  _ChildMenu(this.index, this.metrics, this.rect);
  final int index;
  final _MenuMetrics metrics;
  final Rect rect;
  final scroll = ScrollController();
  bool visible = true;
}

class _ChildSurface extends StatefulWidget {
  const _ChildSurface({
    super.key,
    required this.visible,
    required this.duration,
    required this.onHidden,
    required this.child,
  });
  final bool visible;
  final Duration duration;
  final VoidCallback onHidden;
  final Widget child;
  @override
  State<_ChildSurface> createState() => _ChildSurfaceState();
}

class _ChildSurfaceState extends State<_ChildSurface>
    with SingleTickerProviderStateMixin {
  late final _fade = AnimationController(vsync: this, duration: widget.duration)
    ..forward();
  @override
  void didUpdateWidget(_ChildSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    _fade.duration = widget.duration;
    if (oldWidget.visible && !widget.visible) {
      _fade.reverse().whenCompleteOrCancel(() {
        if (mounted) widget.onHidden();
      });
    }
  }

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: !widget.visible,
    child: ExcludeSemantics(
      excluding: !widget.visible,
      child: FadeTransition(opacity: _fade, child: widget.child),
    ),
  );
}

class _MenuMetrics {
  _MenuMetrics(
    this.width,
    this.height,
    this.heights,
    this.offsets,
    this.iconWidth,
    this.shortcutWidth,
    this.arrowWidth,
  );
  final double width, height, iconWidth, shortcutWidth, arrowWidth;
  final List<double> heights, offsets;
  static _MenuMetrics measure<T>(
    BuildContext context,
    List<OpenNoteMenuEntry<T>> entries,
    double limit,
  ) {
    final scaler = MediaQuery.textScalerOf(context),
        direction = Directionality.of(context);
    final labelStyle = Theme.of(context).textTheme.bodyMedium!
        .copyWith(fontSize: 14, height: 1.4);
    final shortcutStyle = labelStyle.copyWith(fontSize: 12);
    Size measure(
      String text,
      TextStyle style, [
      double maxWidth = double.infinity,
    ]) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: direction,
        textScaler: scaler,
      )..layout(maxWidth: maxWidth);
      final size = painter.size;
      painter.dispose();
      return size;
    }

    final iconWidth = entries.any((entry) => entry.icon != null) ? 28.0 : 0.0;
    final arrowWidth = entries.any((entry) => entry.hasSubmenu) ? 24.0 : 0.0;
    final naturalShortcutWidth = entries
        .map(
          (entry) => entry.shortcut == null
              ? 0.0
              : measure(entry.shortcut!, shortcutStyle).width + 12,
        )
        .fold(0.0, math.max);
    final labelWidth = entries
        .map((entry) => measure(entry.label, labelStyle).width)
        .fold(0.0, math.max);
    final fixedColumns = 24 + iconWidth + arrowWidth;
    final width = (labelWidth + fixedColumns + naturalShortcutWidth)
        .clamp(
          math.min(220.0, limit),
          math.min(320 * scaler.scale(14) / 14, limit),
        )
        .toDouble();
    // 窄菜单给名称与快捷键分别留出空间，按实际换行高度增加行高。
    final shortcutWidth = math.min(
      naturalShortcutWidth,
      math.max(0, width - fixedColumns) / 2,
    );
    final columns = fixedColumns + shortcutWidth;
    final heights = <double>[], offsets = <double>[];
    var offset = 0.0;
    for (final entry in entries) {
      offsets.add(offset);
      final entryColumns =
          columns - (entry.shortcut == null ? shortcutWidth : 0);
      final height = entry.divider
          ? 9.0
          : math.max(
              36.0,
              math.max(
                    measure(
                      entry.label,
                      labelStyle,
                      math.max(1, width - entryColumns),
                    ).height,
                    entry.shortcut == null
                        ? 0.0
                        : measure(
                            entry.shortcut!,
                            shortcutStyle,
                            math.max(1, shortcutWidth - 12),
                          ).height,
                  ) +
                  12,
            );
      heights.add(height);
      offset += height;
    }
    return _MenuMetrics(
      width,
      offset + 12,
      heights,
      offsets,
      iconWidth,
      shortcutWidth,
      arrowWidth,
    );
  }
}

class _MenuPanel<T> extends StatelessWidget {
  const _MenuPanel({
    super.key,
    required this.entries,
    required this.metrics,
    required this.onActivate,
    required this.onHover,
    this.scroll,
    this.selected,
    this.expanded,
    this.onExit,
    this.onPointerHover,
  });
  final List<OpenNoteMenuEntry<T>> entries;
  final _MenuMetrics metrics;
  final ValueChanged<OpenNoteMenuEntry<T>> onActivate;
  final void Function(int, Offset) onHover;
  final void Function(int)? onExit;
  final void Function(int, Offset)? onPointerHover;
  final ScrollController? scroll;
  final int? selected, expanded;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: OpenNoteTokens.surface,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: OpenNoteTokens.border),
      boxShadow: OpenNoteTokens.floatingShadows,
    ),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SingleChildScrollView(
        controller: scroll,
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var index = 0; index < entries.length; index++)
              if (entries[index].divider)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: Divider(height: 9),
                )
              else
                OpenNoteMenuItem<T>(
                  key: entries[index].key,
                  entry: entries[index],
                  height: metrics.heights[index],
                  iconWidth: metrics.iconWidth,
                  shortcutWidth: metrics.shortcutWidth,
                  arrowWidth: metrics.arrowWidth,
                  highlighted: selected == index || expanded == index,
                  onActivate: () => onActivate(entries[index]),
                  onEnter: (point) => onHover(index, point),
                  onExit: () => onExit?.call(index),
                  onHover: (point) => onPointerHover?.call(index, point),
                ),
          ],
        ),
      ),
    ),
  );
}

class OpenNoteMenuItem<T> extends StatelessWidget {
  const OpenNoteMenuItem({
    super.key,
    required this.entry,
    required this.height,
    required this.iconWidth,
    required this.shortcutWidth,
    required this.arrowWidth,
    required this.highlighted,
    required this.onActivate,
    required this.onEnter,
    required this.onExit,
    required this.onHover,
  });
  final OpenNoteMenuEntry<T> entry;
  final double height, iconWidth, shortcutWidth, arrowWidth;
  final bool highlighted;
  final VoidCallback onActivate, onExit;
  final ValueChanged<Offset> onEnter, onHover;
  T? get value => entry.value;
  bool get enabled => entry.enabled;
  @override
  Widget build(BuildContext context) {
    final color = !entry.enabled
        ? OpenNoteTokens.muted
        : entry.danger
        ? OpenNoteTokens.danger
        : OpenNoteTokens.text;
    final style = Theme.of(context).textTheme.bodyMedium!
        .copyWith(fontSize: 14, height: 1.4, color: color);
    return Semantics(
      button: true,
      enabled: entry.enabled,
      focused: highlighted,
      label: entry.label,
      value: entry.shortcut,
      onTap: entry.enabled ? onActivate : null,
      excludeSemantics: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.basic,
        onEnter: (event) => onEnter(event.position),
        onExit: (_) => onExit(),
        onHover: (event) => onHover(event.position),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: entry.enabled ? onActivate : null,
          child: Container(
            height: height,
            color: highlighted && entry.enabled
                ? OpenNoteTokens.hover
                : Colors.transparent,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                if (iconWidth > 0)
                  SizedBox(
                    width: iconWidth,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: entry.icon == null
                          ? null
                          : OpenNoteIcon(entry.icon!, size: 18, color: color),
                    ),
                  ),
                Expanded(child: Text(entry.label, style: style)),
                if (shortcutWidth > 0 && entry.shortcut != null)
                  SizedBox(
                    width: shortcutWidth,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 12),
                      child: Text(
                        entry.shortcut!,
                        textAlign: TextAlign.right,
                        style: style.copyWith(
                          fontSize: 12,
                          color: entry.enabled
                              ? OpenNoteTokens.secondary
                              : OpenNoteTokens.muted,
                        ),
                      ),
                    ),
                  ),
                if (arrowWidth > 0)
                  SizedBox(
                    width: arrowWidth,
                    child: entry.hasSubmenu
                        ? Align(
                            alignment: Alignment.centerRight,
                            child: OpenNoteIcon(
                              Icons.chevron_right,
                              size: 16,
                              color: color,
                            ),
                          )
                        : null,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
