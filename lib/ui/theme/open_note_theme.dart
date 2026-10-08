import 'package:flutter/material.dart';

/// 阅读工作台的统一视觉尺度。业务颜色（卡片、批注）不属于主题色板。
abstract final class OpenNoteTokens {
  static const background = Color(0xfff4f5f6);
  static const surface = Color(0xffffffff);
  static const border = Color(0xffe7e8ea);
  static const text = Color(0xff292c30);
  static const secondary = Color(0xff73777d);
  static const accent = Color(0xff3574cb);
  static const selected = Color(0xffe9eaec);
  static const hover = Color(0xfff0f1f2);
  static const muted = Color(0xffa5a8ad);
  static const danger = Color(0xffba3434);
  static const paneRadius = 10.0;
  static const duration = Duration(milliseconds: 140);
  static const floatingShadows = [
    BoxShadow(color: Color(0x09202124), blurRadius: 5, offset: Offset(0, 1)),
  ];
}

ThemeData openNoteTheme() {
  const shape = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(6)),
  );
  final scheme =
      ColorScheme.fromSeed(
        seedColor: OpenNoteTokens.accent,
        brightness: Brightness.light,
        surface: OpenNoteTokens.surface,
      ).copyWith(
        primary: OpenNoteTokens.accent,
        onPrimary: Colors.white,
        secondary: OpenNoteTokens.text,
        secondaryContainer: OpenNoteTokens.selected,
        onSecondaryContainer: OpenNoteTokens.text,
        onSurface: OpenNoteTokens.text,
        onSurfaceVariant: OpenNoteTokens.secondary,
        outline: OpenNoteTokens.border,
        outlineVariant: OpenNoteTokens.border,
        primaryContainer: OpenNoteTokens.selected,
        onPrimaryContainer: OpenNoteTokens.text,
        tertiary: OpenNoteTokens.secondary,
        tertiaryContainer: OpenNoteTokens.hover,
        onTertiaryContainer: OpenNoteTokens.text,
        surfaceTint: Colors.transparent,
        surfaceContainerLowest: OpenNoteTokens.surface,
        surfaceContainerLow: OpenNoteTokens.surface,
        surfaceContainer: OpenNoteTokens.background,
        surfaceContainerHigh: OpenNoteTokens.hover,
        surfaceContainerHighest: OpenNoteTokens.selected,
        error: OpenNoteTokens.danger,
        errorContainer: const Color(0xfffff1ef),
        onErrorContainer: OpenNoteTokens.danger,
      );
  final base = ThemeData(
    useMaterial3: true,
    visualDensity: VisualDensity.standard,
    colorScheme: scheme,
    fontFamily: 'Segoe UI',
    fontFamilyFallback: const ['Source Han Sans CN', 'Microsoft YaHei'],
  );
  final text = base.textTheme.copyWith(
    titleLarge: base.textTheme.titleLarge?.copyWith(
      fontSize: 20,
      fontWeight: FontWeight.w600,
    ),
    titleMedium: base.textTheme.titleMedium?.copyWith(
      fontSize: 18,
      fontWeight: FontWeight.w600,
    ),
    titleSmall: base.textTheme.titleSmall?.copyWith(
      fontSize: 14,
      fontWeight: FontWeight.w600,
    ),
    bodyLarge: base.textTheme.bodyLarge?.copyWith(fontSize: 16, height: 1.6),
    bodyMedium: base.textTheme.bodyMedium?.copyWith(fontSize: 14, height: 1.5),
    bodySmall: base.textTheme.bodySmall?.copyWith(
      fontSize: 12,
      height: 1.4,
      color: OpenNoteTokens.secondary,
    ),
    labelLarge: base.textTheme.labelLarge?.copyWith(fontSize: 14),
  );
  final button = ButtonStyle(
    minimumSize: const WidgetStatePropertyAll(Size(36, 36)),
    padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12)),
    shape: const WidgetStatePropertyAll(shape),
    animationDuration: OpenNoteTokens.duration,
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    textStyle: WidgetStatePropertyAll(text.labelLarge),
  );
  return base.copyWith(
    textTheme: text,
    scaffoldBackgroundColor: OpenNoteTokens.surface,
    dividerColor: OpenNoteTokens.border,
    hoverColor: OpenNoteTokens.hover,
    focusColor: OpenNoteTokens.selected,
    splashFactory: NoSplash.splashFactory,
    iconTheme: const IconThemeData(size: 20, color: OpenNoteTokens.secondary),
    dividerTheme: const DividerThemeData(
      color: OpenNoteTokens.border,
      thickness: 1,
      space: 1,
    ),
    iconButtonTheme: IconButtonThemeData(
      style: button.copyWith(
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? const Color(0xffb8bec7)
              : states.contains(WidgetState.selected)
              ? OpenNoteTokens.accent
              : OpenNoteTokens.text,
        ),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? OpenNoteTokens.selected
              : Colors.transparent,
        ),
        overlayColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.focused)
              ? OpenNoteTokens.selected
              : OpenNoteTokens.hover,
        ),
        padding: const WidgetStatePropertyAll(EdgeInsets.all(8)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: button.copyWith(
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? OpenNoteTokens.muted
              : OpenNoteTokens.text,
        ),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(style: button),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: button.copyWith(
        foregroundColor: const WidgetStatePropertyAll(OpenNoteTokens.text),
        side: const WidgetStatePropertyAll(
          BorderSide(color: OpenNoteTokens.border),
        ),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: button.copyWith(
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? OpenNoteTokens.surface
              : OpenNoteTokens.background,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? OpenNoteTokens.text
              : OpenNoteTokens.secondary,
        ),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 10),
        ),
        side: const WidgetStatePropertyAll(BorderSide.none),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: OpenNoteTokens.surface,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      labelStyle: const TextStyle(
        fontSize: 14,
        color: OpenNoteTokens.secondary,
      ),
      hintStyle: const TextStyle(fontSize: 14, color: OpenNoteTokens.secondary),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: const BorderSide(color: OpenNoteTokens.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: const BorderSide(color: OpenNoteTokens.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: const BorderSide(color: OpenNoteTokens.accent, width: 1.5),
      ),
    ),
    listTileTheme: ListTileThemeData(
      minTileHeight: 40,
      minLeadingWidth: 20,
      horizontalTitleGap: 8,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      titleTextStyle: text.bodyMedium,
      subtitleTextStyle: text.bodySmall,
      selectedTileColor: OpenNoteTokens.selected,
      selectedColor: OpenNoteTokens.text,
      shape: shape,
    ),
    dialogTheme: DialogThemeData(
      barrierColor: const Color(0x33262b33),
      backgroundColor: OpenNoteTokens.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shadowColor: const Color(0x22202124),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: OpenNoteTokens.border),
      ),
      titleTextStyle: text.titleLarge,
      contentTextStyle: text.bodyLarge,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: OpenNoteTokens.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 3,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: OpenNoteTokens.border),
      ),
      textStyle: text.bodyMedium,
    ),
    tooltipTheme: const TooltipThemeData(
      waitDuration: Duration(milliseconds: 450),
      padding: EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      textStyle: TextStyle(fontSize: 12, color: Colors.white),
      decoration: BoxDecoration(
        color: OpenNoteTokens.text,
        borderRadius: BorderRadius.all(Radius.circular(6)),
      ),
    ),
    scrollbarTheme: const ScrollbarThemeData(
      radius: Radius.circular(4),
      thickness: WidgetStatePropertyAll(6),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: OpenNoteTokens.secondary,
      linearTrackColor: OpenNoteTokens.hover,
    ),
    sliderTheme: const SliderThemeData(
      activeTrackColor: OpenNoteTokens.text,
      thumbColor: OpenNoteTokens.text,
      inactiveTrackColor: OpenNoteTokens.selected,
      overlayColor: Color(0x14292c30),
    ),
    expansionTileTheme: const ExpansionTileThemeData(
      textColor: OpenNoteTokens.text,
      iconColor: OpenNoteTokens.secondary,
      collapsedIconColor: OpenNoteTokens.secondary,
      shape: Border(),
      collapsedShape: Border(),
    ),
  );
}
