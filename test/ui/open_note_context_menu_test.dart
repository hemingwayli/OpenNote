import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opennote/ui/theme/open_note_context_menu.dart';
import 'package:opennote/ui/theme/open_note_theme.dart';

void main() {
  testWidgets('共享菜单：整块同步淡入淡出，所有帧尺寸与位置稳定', (tester) async {
    final host = await _mount(tester);
    await _open(tester);
    final menu = find.byKey(const Key('context-menu-main'));
    final rect = tester.getRect(menu);
    final first = tester.getRect(find.byKey(const Key('menu-group')));
    final last = tester.getRect(find.byKey(const Key('menu-delete')));
    final fade = tester.widget<FadeTransition>(
      find.byKey(const Key('context-menu-opacity')),
    );
    expect(fade.opacity.value, 0);
    expect(find.byType(OpenNoteMenuItem<String>), findsNWidgets(3));
    await tester.pump(const Duration(milliseconds: 60));
    expect(fade.opacity.value, closeTo(.5, .01));
    expect(tester.getRect(menu), rect);
    expect(tester.getRect(find.byKey(const Key('menu-group'))), first);
    expect(tester.getRect(find.byKey(const Key('menu-delete'))), last);
    await tester.pump(const Duration(milliseconds: 60));
    expect(fade.opacity.value, 1);
    await tester.tap(find.byKey(const Key('menu-delete')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(fade.opacity.value, closeTo(.5, .01));
    expect(tester.getRect(menu), rect);
    expect(find.byKey(const Key('menu-delete')).hitTestable(), findsNothing);
    await tester.pumpAndSettle();
    expect(host.actions, ['delete']);
    expect(menu, findsNothing);
  });

  testWidgets('共享菜单：悬停250ms展开，侧向菜单保留父菜单且移入不收起', (tester) async {
    final host = await _mount(tester);
    await _open(tester);
    await tester.pumpAndSettle();
    final rect = tester.getRect(find.byKey(const Key('context-menu-main')));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(2, 2));
    await mouse.moveTo(tester.getCenter(find.byKey(const Key('menu-group'))));
    await tester.pump(const Duration(milliseconds: 249));
    expect(find.byKey(const Key('menu-copy')), findsNothing);
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.byKey(const Key('menu-copy')), findsOneWidget);
    expect(tester.getRect(find.byKey(const Key('context-menu-main'))), rect);
    await tester.pump(const Duration(milliseconds: 120));
    final child = tester.getRect(find.byKey(const Key('context-menu-child-0')));
    expect(child.left, rect.right + 4);
    await mouse.moveTo(tester.getCenter(find.byKey(const Key('menu-copy'))));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('menu-copy')).hitTestable(), findsOneWidget);
    await tester.tap(find.byKey(const Key('menu-copy')));
    await tester.pumpAndSettle();
    expect(host.actions, ['copy']);
    await mouse.removePointer();
    expect(tester.takeException(), isNull);
  });

  testWidgets('共享菜单：点击立即展开，方向键跳过禁用项，Esc逐层关闭', (tester) async {
    final host = await _mount(tester);
    await _open(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('menu-group')));
    await tester.pump();
    expect(find.byKey(const Key('menu-copy')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('menu-copy')), findsNothing);
    expect(find.byKey(const Key('context-menu-main')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(host.actions, ['paste']);
    expect(find.byKey(const Key('context-menu-main')), findsNothing);
  });

  testWidgets('共享菜单：外部点击只取消并恢复焦点，不执行底层点击', (tester) async {
    final host = await _mount(tester);
    host.focus.requestFocus();
    await tester.pump();
    await _open(tester);
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(850, 550));
    await tester.pumpAndSettle();
    expect(host.actions, isEmpty);
    expect(host.backgroundClicks, 0);
    expect(host.focus.hasFocus, isTrue);
    expect(find.byKey(const Key('context-menu-main')), findsNothing);
  });

  testWidgets('共享菜单：右边缘向左避让，窄视口和150%文字仍完整可操作', (tester) async {
    await _mount(
      tester,
      size: const Size(420, 520),
      scale: 1.5,
      position: const Offset(415, 510),
    );
    await _open(tester);
    await tester.pumpAndSettle();
    final main = tester.getRect(find.byKey(const Key('context-menu-main')));
    await tester.tap(find.byKey(const Key('menu-group')));
    await tester.pumpAndSettle();
    final child = tester.getRect(find.byKey(const Key('context-menu-child-0')));
    expect(child.right, main.left - 4);
    for (final rect in [main, child]) {
      expect(rect.left, greaterThanOrEqualTo(8));
      expect(rect.top, greaterThanOrEqualTo(8));
      expect(rect.right, lessThanOrEqualTo(412));
      expect(rect.bottom, lessThanOrEqualTo(512));
    }
    expect(tester.getRect(find.byKey(const Key('context-menu-main'))), main);
    expect(find.byKey(const Key('menu-copy')).hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('共享菜单：超高菜单键盘滚动到底，失效取消与减少动画生效', (tester) async {
    final host = await _mount(
      tester,
      reduced: true,
      size: const Size(500, 300),
      long: true,
    );
    await _open(tester);
    expect(
      tester
          .widget<FadeTransition>(find.byKey(const Key('context-menu-opacity')))
          .opacity
          .value,
      1,
    );
    for (var index = 0; index < 17; index++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
    }
    expect(find.byKey(const Key('long-17')).hitTestable(), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(host.actions, ['long-17']);
    await _open(tester);
    host.valid = false;
    host.controller.cancel();
    await tester.pumpAndSettle();
    expect(host.actions, ['long-17']);
    expect(find.byKey(const Key('context-menu-main')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('共享菜单：斜向跨父项保护，子菜单淡入尺寸稳定且离开200ms才收起', (tester) async {
    await _mount(tester);
    await _open(tester);
    await tester.pumpAndSettle();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(2, 2));
    await mouse.moveTo(tester.getCenter(find.byKey(const Key('menu-group'))));
    await tester.pump(const Duration(milliseconds: 250));
    final menu = find.byKey(const Key('context-menu-child-0'));
    final rect = tester.getRect(menu);
    final copy = tester.getRect(find.byKey(const Key('menu-copy')));
    await tester.pump(const Duration(milliseconds: 60));
    expect(tester.getRect(menu), rect);
    expect(tester.getRect(find.byKey(const Key('menu-copy'))), copy);
    await tester.pump(const Duration(milliseconds: 60));
    final main = tester.getRect(find.byKey(const Key('context-menu-main')));
    await mouse.moveTo(
      Offset(
        main.right - 5,
        tester.getCenter(find.byKey(const Key('menu-delete'))).dy,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const Key('menu-copy')).hitTestable(), findsOneWidget);
    expect(
      tester
          .widget<OpenNoteMenuItem<String>>(
            find.byKey(const Key('menu-delete')),
          )
          .highlighted,
      isFalse,
    );
    await mouse.moveTo(tester.getCenter(find.byKey(const Key('menu-copy'))));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('menu-copy')).hitTestable(), findsOneWidget);
    await mouse.moveTo(const Offset(850, 550));
    await tester.pump(const Duration(milliseconds: 199));
    expect(find.byKey(const Key('menu-copy')).hitTestable(), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.byKey(const Key('menu-copy')).hitTestable(), findsNothing);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump();
    final childFade = find.descendant(
      of: menu,
      matching: find.byType(FadeTransition),
    );
    expect(tester.widget<FadeTransition>(childFade).opacity.value, 0);
    // 动画在120ms已透明；下一帧完成浮点端点判定并移除表面。
    await tester.pump(const Duration(milliseconds: 16));
    expect(menu, findsNothing);
    expect(tester.getRect(find.byKey(const Key('context-menu-main'))), main);
    await mouse.removePointer();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
  });

  testWidgets('共享菜单：窗口变窄关闭整组，不遗留透明拦截层', (tester) async {
    final host = await _mount(tester);
    await _open(tester);
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(750, 500);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('context-menu-main')), findsNothing);
    expect(host.controller.isOpen, isFalse);
    await tester.tapAt(const Offset(700, 450));
    expect(host.backgroundClicks, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('共享菜单：同内容按钮在目标变更后取消旧菜单且不派发旧动作', (tester) async {
    var current = 'a';
    late StateSetter refresh;
    final actions = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: openNoteTheme(),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, update) {
              refresh = update;
              final scope = current;
              return Center(
                child: OpenNoteContextMenuButton<String>(
                  key: const Key('same-menu-button'),
                  icon: const Icon(Icons.more_horiz),
                  tooltip: '操作',
                  entries: () => [OpenNoteMenuEntry('edit', '编辑 $scope')],
                  isValid: () => current == scope,
                  onSelected: (action) => actions.add('$scope:$action'),
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('same-menu-button')));
    await tester.pumpAndSettle();
    expect(find.text('编辑 a'), findsOneWidget);
    refresh(() => current = 'b');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('context-menu-main')), findsNothing);
    expect(actions, isEmpty);
    await tester.tap(find.byKey(const Key('same-menu-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑 b'));
    await tester.pumpAndSettle();
    expect(actions, ['b:edit']);
  });

  testWidgets('共享菜单：悬停切换同层子菜单不被旧关闭计时器中断', (tester) async {
    await _mount(tester, extraGroup: true);
    await _open(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('menu-group')));
    await tester.pumpAndSettle();
    final main = tester.getRect(find.byKey(const Key('context-menu-main')));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(2, 2));
    await mouse.moveTo(
      tester.getCenter(find.byKey(const Key('menu-second-group'))),
    );
    await tester.pump(const Duration(milliseconds: 249));
    expect(find.byKey(const Key('menu-second-leaf')), findsNothing);
    await tester.pump(const Duration(milliseconds: 1));
    expect(
      find.byKey(const Key('menu-second-leaf')).hitTestable(),
      findsOneWidget,
    );
    expect(find.byKey(const Key('menu-copy')).hitTestable(), findsNothing);
    expect(tester.getRect(find.byKey(const Key('context-menu-main'))), main);
    await mouse.removePointer();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}

class _Host {
  final actions = <String>[];
  final focus = FocusNode();
  final controller = OpenNoteContextMenuController();
  var backgroundClicks = 0;
  var valid = true;
}

Future<_Host> _mount(
  WidgetTester tester, {
  Size size = const Size(1000, 650),
  double scale = 1,
  bool reduced = false,
  Offset position = const Offset(100, 100),
  bool long = false,
  bool extraGroup = false,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final host = _Host();
  addTearDown(host.focus.dispose);
  final entries = long
      ? [
          for (var index = 0; index < 18; index++)
            OpenNoteMenuEntry(
              'long-$index',
              '命令 $index',
              key: Key('long-$index'),
            ),
        ]
      : <OpenNoteMenuEntry<String>>[
          const OpenNoteMenuEntry(
            'group',
            '复制与移动',
            icon: Icons.copy,
            key: Key('menu-group'),
            children: [
              OpenNoteMenuEntry(
                'copy',
                '复制',
                shortcut: 'Ctrl+C',
                key: Key('menu-copy'),
              ),
              OpenNoteMenuEntry('disabled', '不可用', enabled: false),
              OpenNoteMenuEntry(
                'paste',
                '粘贴',
                shortcut: 'Ctrl+V',
                key: Key('menu-paste'),
              ),
            ],
          ),
          if (extraGroup)
            const OpenNoteMenuEntry(
              'secondGroup',
              '样式',
              key: Key('menu-second-group'),
              children: [
                OpenNoteMenuEntry(
                  'secondLeaf',
                  '主题格式…',
                  key: Key('menu-second-leaf'),
                ),
              ],
            ),
          const OpenNoteMenuEntry('disabled', '不可用', enabled: false),
          const OpenNoteMenuEntry.divider(),
          const OpenNoteMenuEntry(
            'delete',
            '删除',
            danger: true,
            key: Key('menu-delete'),
          ),
        ];
  await tester.pumpWidget(
    MaterialApp(
      theme: openNoteTheme(),
      home: MediaQuery(
        data: MediaQueryData(
          size: size,
          textScaler: TextScaler.linear(scale),
          disableAnimations: reduced,
        ),
        child: Scaffold(
          body: Focus(
            focusNode: host.focus,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => host.backgroundClicks++,
              child: Center(
                child: Builder(
                  builder: (context) => TextButton(
                    key: const Key('open-menu'),
                    onPressed: () async {
                      final action = await showOpenNoteContextMenu<String>(
                        context: context,
                        position: position,
                        entries: entries,
                        controller: host.controller,
                        isValid: () => host.valid,
                      );
                      if (action != null) host.actions.add(action);
                    },
                    child: const Text('菜单'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  return host;
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('open-menu')));
  await tester.pump();
  await tester.pump();
}
