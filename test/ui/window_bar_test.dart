import 'dart:ui'
    show AppExitResponse, AppExitType, PointerDeviceKind, ImageByteFormat;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opennote/platform/window_chrome.dart';
import 'package:opennote/platform/window_fullscreen.dart';
import 'package:opennote/ui/theme/open_note_theme.dart';
import 'package:opennote/ui/theme/open_note_window_bar.dart';

class _ExitRecordingBinding extends AutomatedTestWidgetsFlutterBinding {
  final exits = <AppExitType>[];

  @override
  Future<AppExitResponse> exitApplication(
    AppExitType exitType, [
    int exitCode = 0,
  ]) async {
    exits.add(exitType);
    return super.exitApplication(exitType, exitCode);
  }
}

void main() {
  final binding = _ExitRecordingBinding();
  final calls = <MethodCall>[];
  setUp(() {
    calls.clear();
    WindowChrome.maximized.value = false;
    WindowChrome.maximizeInteraction.value = (hovered: false, pressed: false);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(WindowFullscreen.channel, (call) async {
          calls.add(call);
          return call.method == 'setChromeRegions' ? false : null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(WindowFullscreen.channel, null);
  });

  Widget app(Widget bar) => MaterialApp(
    theme: openNoteTheme(),
    home: Scaffold(body: Column(children: [bar])),
  );
  Widget bar({bool active = true}) => OpenNoteWindowBar(
    active: active,
    child: const OpenNoteWindowDrag(child: SizedBox.expand()),
  );

  testWidgets('窗口栏只将标题空白与最大化按钮交给原生命中', (tester) async {
    await tester.pumpWidget(app(bar()));
    await tester.pumpAndSettle();
    final regions =
        calls.lastWhere((c) => c.method == 'setChromeRegions').arguments
            as List;
    expect(regions, hasLength(2));
    final maximum = regions.singleWhere((r) => r['role'] == 1.0) as Map;
    final rect = Rect.fromLTWH(
      maximum['x'],
      maximum['y'],
      maximum['width'],
      maximum['height'],
    );
    expect(rect.contains(tester.getCenter(find.byTooltip('最大化'))), isTrue);
    expect(rect.contains(tester.getCenter(find.byTooltip('关闭窗口'))), isFalse);
    await tester.tap(find.byTooltip('关闭窗口'));
    await tester.pump();
    expect(calls.last.method, 'requestClose');
    await tester.tap(find.byTooltip('最小化'));
    await tester.pump();
    expect(calls.last.method, 'minimize');
    WindowChrome.maximized.value = true;
    await tester.pump();
    expect(find.byTooltip('还原窗口'), findsOneWidget);
    await tester.tap(find.byTooltip('还原窗口'));
    await tester.pump();
    expect(calls.last.method, 'toggleMaximize');
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('弹窗覆盖与沉浸式隐藏会清除原生标题命中区域', (tester) async {
    late StateSetter update;
    var hidden = false;
    await tester.pumpWidget(
      app(
        StatefulBuilder(
          builder: (_, setState) {
            update = setState;
            return Offstage(
              offstage: hidden,
              child: bar(active: !hidden),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(OpenNoteWindowBar));
    showDialog<void>(
      context: context,
      builder: (_) =>
          const AlertDialog(title: Text('确认'), content: Text('保留原来的模态流程')),
    );
    await tester.pumpAndSettle();
    expect(
      calls.lastWhere((c) => c.method == 'setChromeRegions').arguments,
      isEmpty,
    );
    Navigator.of(context).pop();
    await tester.pumpAndSettle();
    expect(
      calls.lastWhere((c) => c.method == 'setChromeRegions').arguments,
      isNotEmpty,
    );
    update(() => hidden = true);
    await tester.pumpAndSettle();
    expect(
      calls.lastWhere((c) => c.method == 'setChromeRegions').arguments,
      isEmpty,
    );
    update(() => hidden = false);
    await tester.pumpAndSettle();
    expect(
      calls.lastWhere((c) => c.method == 'setChromeRegions').arguments,
      isNotEmpty,
    );
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('原生最大化悬停与按压使用最小化按钮的同一套动效', (tester) async {
    final imageKey = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(key: imageKey, child: app(bar())));
    await tester.pumpAndSettle();
    final minimum = find.byWidgetPredicate(
      (widget) => widget is IconButton && widget.tooltip == '最小化',
    );
    final maximum = find.byWidgetPredicate(
      (widget) => widget is IconButton && widget.tooltip == '最大化',
    );
    final minButton = tester.widget<IconButton>(minimum);
    final maxButton = tester.widget<IconButton>(maximum);
    final maxStates = maxButton.statesController!;
    Future<List<int>> backgroundPixel(Finder button) async {
      final point = tester.getCenter(button) + const Offset(12, 0);
      return (await tester.runAsync(() async {
        final boundary =
            imageKey.currentContext!.findRenderObject()
                as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = (await image.toByteData(
          format: ImageByteFormat.rawRgba,
        ))!;
        final offset = (point.dy.floor() * image.width + point.dx.floor()) * 4;
        final pixel = bytes.buffer.asUint8List(offset, 4).toList();
        image.dispose();
        return pixel;
      }))!;
    }

    final normalPixel = await backgroundPixel(minimum);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(minimum));
    await tester.pumpAndSettle();
    final minInk = tester.widget<InkWell>(
      find.descendant(of: minimum, matching: find.byType(InkWell)),
    );
    expect(minInk.statesController!.value, contains(WidgetState.hovered));
    final minHoverPixel = await backgroundPixel(minimum);
    expect(minHoverPixel, isNot(normalPixel));
    await mouse.removePointer();
    await tester.pumpAndSettle();

    Future<void> nativeState(bool hovered, bool pressed) async {
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            WindowFullscreen.channel.name,
            const StandardMethodCodec().encodeMethodCall(
              MethodCall('maximizeInteraction', {
                'hovered': hovered,
                'pressed': pressed,
              }),
            ),
            (_) {},
          );
      await tester.pumpAndSettle();
    }

    await nativeState(true, false);
    expect(maxStates.value, contains(WidgetState.hovered));
    expect(maxStates.value, isNot(contains(WidgetState.pressed)));
    expect(
      maxButton.style!.backgroundColor!.resolve(maxStates.value),
      minButton.style!.backgroundColor!.resolve({WidgetState.hovered}),
    );
    expect(tester.getSize(maximum), tester.getSize(minimum));
    expect(await backgroundPixel(maximum), minHoverPixel);
    await nativeState(true, true);
    expect(
      maxStates.value,
      containsAll([WidgetState.hovered, WidgetState.pressed]),
    );
    await nativeState(false, false);
    expect(maxStates.value, isNot(contains(WidgetState.hovered)));
    expect(maxStates.value, isNot(contains(WidgetState.pressed)));
    expect(calls.where((call) => call.method == 'toggleMaximize'), isEmpty);
    expect(calls.where((call) => call.method == 'setFullscreen'), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await nativeState(true, false);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('原生关闭明确请求可取消退出而非直接销毁窗口', (tester) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    binding.exits.clear();
    await tester.pumpWidget(app(bar()));
    await tester.pumpAndSettle();
    await messenger.handlePlatformMessage(
      WindowFullscreen.channel.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('requestAppExit'),
      ),
      (_) {},
    );
    await tester.pumpAndSettle();
    expect(binding.exits, [AppExitType.cancelable]);
    expect(find.byType(OpenNoteWindowBar), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
