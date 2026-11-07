/// 设计令牌 —— 几何量 + **Material 3** 主题构建。
///
/// 历史：F7.6 是「卡通」主题（2.5dp 墨线描边 + 零模糊硬阴影 + 手绘装饰），F7.17 做了深浅两套。
/// 2026-10-28 起改走 **Material 3**：色板从 `ColorScheme.fromSeed(森绿)` 派生
/// （见 `palette.dart` 的 `_fromScheme`），组件走 M3 的 surface / elevation / 发丝描边。
///
/// 约定不变：
/// - 产品代码里**不出现裸 `Color(0x…)`**（除 `lib/core/theme/` 内）；
/// - 几何量走 [Tok]，颜色走 `context.toon`（`p.ink` / `p.paper` …）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'palette.dart';

/// 与主题无关的形体令牌（两套主题共用）。
abstract final class Tok {
  /// 发丝描边宽度（M3 默认 1dp；卡通时代的 2.5dp 粗描边已废弃）。
  static const double bw = 1;

  /// 圆角：Xl 用于底部弹层/对话框，Lg 用于卡片，Md 用于输入框/按钮，Sm 用于小件。
  static const double rXl = 28;
  static const double rLg = 16;
  static const double rMd = 12;
  static const double rSm = 8;

  /// 通用间距：轻提示内图标与文案之间需要的最小刻度。
  static const double s8 = 8;
}

/// 构建一套 Material 3 主题（浅色 / 深色同一份结构，色板来自 [p]）。
///
/// 关键点：
/// - `colorScheme` 用**同一个 seed** 生成，**和 [p] 同源**，所以 `Theme.of(context).colorScheme`
///   与 `context.toon` 不会互相打架；换主题色时把 [seed] 换成用户选的那个即可；
/// - `extensions: [p]` —— 155 处 `context.toon` 靠它取色；
/// - 卡片/按钮/输入框/弹层的形状统一走 M3（无描边 + 轻 elevation + 胶囊按钮）。
ThemeData buildToonTheme(
  ToonPalette p,
  Brightness brightness, {
  Color seed = ToonPalette.seed,
}) {
  final bool isDark = brightness == Brightness.dark;
  final ColorScheme scheme = ColorScheme.fromSeed(
    seedColor: seed,
    brightness: brightness,
  );
  final ThemeData base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
  );
  final TextTheme text = base.textTheme;

  return base.copyWith(
    scaffoldBackgroundColor: scheme.surfaceContainerLowest,
    canvasColor: scheme.surfaceContainerLowest,
    splashFactory: InkSparkle.splashFactory,
    extensions: <ThemeExtension<dynamic>>[p],
    textTheme: text.copyWith(
      titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w600),
      titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      titleSmall: text.titleSmall?.copyWith(fontWeight: FontWeight.w600),
      bodyLarge: text.bodyLarge?.copyWith(fontSize: 15),
      bodyMedium: text.bodyMedium?.copyWith(fontSize: 14),
      labelLarge: text.labelLarge?.copyWith(fontWeight: FontWeight.w600),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: scheme.surfaceTint,
      elevation: 0,
      scrolledUnderElevation: 2,
      // M3 默认左对齐；iOS 风格才居中
      centerTitle: false,
      systemOverlayStyle: isDark
          ? SystemUiOverlayStyle.light
          : SystemUiOverlayStyle.dark,
      titleTextStyle: text.titleLarge?.copyWith(
        color: scheme.onSurface,
        fontSize: 20,
        fontWeight: FontWeight.w600,
      ),
    ),
    cardTheme: CardThemeData(
      color: scheme.surface,
      surfaceTintColor: scheme.surfaceTint,
      elevation: 1,
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Tok.rMd),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant,
      thickness: 1,
      space: 1,
    ),
    iconTheme: IconThemeData(color: scheme.onSurfaceVariant),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: scheme.inverseSurface,
      contentTextStyle: TextStyle(
        color: scheme.onInverseSurface,
        fontSize: 14,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Tok.rSm),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      elevation: 3,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Tok.rXl),
      ),
      titleTextStyle: text.titleLarge?.copyWith(
        color: scheme.onSurface,
        fontSize: 20,
      ),
      contentTextStyle: text.bodyMedium?.copyWith(
        color: scheme.onSurfaceVariant,
        fontSize: 14,
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      modalBackgroundColor: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      elevation: 1,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Tok.rXl)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHighest,
      hintStyle: TextStyle(color: scheme.onSurfaceVariant),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Tok.rMd),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Tok.rMd),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Tok.rMd),
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: 24),
        textStyle: text.labelLarge,
        shape: const StadiumBorder(),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: 24),
        textStyle: text.labelLarge,
        shape: const StadiumBorder(),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        textStyle: text.labelLarge,
        shape: const StadiumBorder(),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: scheme.surfaceContainerHigh,
      selectedColor: scheme.secondaryContainer,
      side: BorderSide.none,
      shape: const StadiumBorder(),
      labelStyle: text.labelLarge?.copyWith(fontSize: 13),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        selectedBackgroundColor: scheme.secondaryContainer,
        selectedForegroundColor: scheme.onSecondaryContainer,
        side: BorderSide(color: scheme.outlineVariant),
        shape: const StadiumBorder(),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surfaceContainer,
      surfaceTintColor: Colors.transparent,
      indicatorColor: scheme.secondaryContainer,
      elevation: 0,
      labelTextStyle: WidgetStatePropertyAll<TextStyle?>(
        text.labelMedium?.copyWith(fontWeight: FontWeight.w600),
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: scheme.primary),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: scheme.primary,
      selectionColor: scheme.primary.withValues(alpha: 0.24),
    ),
  );
}
