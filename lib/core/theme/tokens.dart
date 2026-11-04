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

import 'dart:math' as math;

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

  /// 胶囊圆角：气泡/贴纸/进度槽/抓手等「两端全圆」形状（阶段 0 清点 21 处）。
  static const double rPill = 999;

  /// 间距刻度：现状主导值落在 2dp 母格上（6/10/14 也是高频值），先如实编码；
  /// 页面迁移时再把 9/11/13 等杂值归到最近一档，不在主题层悄悄改。
  static const double s4 = 4;
  static const double s6 = 6;
  static const double s8 = 8;
  static const double s10 = 10;
  static const double s12 = 12;
  static const double s14 = 14;
  static const double s16 = 16;
  static const double s11 = 11;
  static const double s18 = 18;
  static const double s22 = 22;
  static const double s20 = 20;
  static const double s24 = 24;
  static const double s32 = 32;
  static const double s40 = 40;
  static const double s48 = 48;

  /// 控件高度：主按钮等可点大控件的最小高度。
  static const double hControl = 48;

  /// 字号刻度：覆盖绝大多数用点；11.5/12.5 等半档是历史值，迁移时归到最近一档
  ///（该决策留给页面迁移阶段做，主题层不代劳）。
  static const double fs11 = 11;
  static const double fs12 = 12;
  static const double fs13 = 13;
  static const double fs14 = 14;
  static const double fs15 = 15;
  static const double fs16 = 16;
  static const double fs17 = 17;
  static const double fs20 = 20;
  static const double fs22 = 22;
  static const double fs24 = 24;
  static const double fs32 = 32;

  /// 大号金额 / 结果展示（月度总额、导入报告）。
  static const double fsDisplay = 40;

  /// 动效时长：微反馈 / 常规 / 强调。现状 160–240ms 的散值迁移时归并到 dNormal。
  static const Duration dFast = Duration(milliseconds: 150);
  static const Duration dNormal = Duration(milliseconds: 220);
  /// 动效曲线：进场用减速，往复用缓入缓出。
  static const Curve easeOut = Curves.easeOutCubic;
  static const Curve easeInOut = Curves.easeInOutCubic;
}

/// Android 手机优先的窗口分级。
///
/// 项目当前不支持 Web / Desktop；按宽度分四级，避免为“专业感”造更多档位。
enum ToonWindowSize {
  /// 窄屏 / 小屏手机。
  compact,

  /// 常见手机。
  standard,

  /// 大屏手机（横向更大）。
  largePhone,

  /// 平板 / 折叠屏展开态 / 横屏宽窗。
  tablet,
}

/// 响应式断点与内容上限。
///
/// 断点只回答“当前窗口属于哪一档”，不直接驱动业务布局；
/// 页面优先用 Flutter 原生的 `Expanded` / `Flexible` / `Wrap` / `LayoutBuilder`。
abstract final class ToonBreakpoints {
  /// 360 及以下按紧凑手机处理。
  static const double compactMax = 360;

  /// 480 以下按标准手机处理。
  static const double standardMax = 480;

  /// 600 以下仍按大屏手机处理。
  static const double largePhoneMax = 600;

  /// 内容最大宽度：平板 / 宽窗不再无限拉伸。
  static const double contentMaxWidth = 720;

  static ToonWindowSize fromWidth(double width) {
    if (width <= compactMax) return ToonWindowSize.compact;
    if (width < standardMax) return ToonWindowSize.standard;
    if (width < largePhoneMax) return ToonWindowSize.largePhone;
    return ToonWindowSize.tablet;
  }

  /// 取窗口宽度和内容上限中的较小值；用于气泡等按可用内容比例限宽的场景。
  static double contentWidthOf(BuildContext context) =>
      math.min(MediaQuery.sizeOf(context).width, contentMaxWidth);
}

extension ToonResponsiveContext on BuildContext {
  /// 当前窗口属于哪一档。
  ToonWindowSize get windowSize =>
      ToonBreakpoints.fromWidth(MediaQuery.sizeOf(this).width);
}

extension ToonMotionContext on BuildContext {
  /// 系统开启“减少动画”时，自定义动效改为直接落定。
  bool get reducedMotion => MediaQuery.disableAnimationsOf(this);

  /// 自定义动效统一使用动效 Token；减少动画时直接到终态。
  Duration motionDuration([Duration duration = Tok.dNormal]) =>
      reducedMotion ? Duration.zero : duration;
}

/// Component-level geometry tokens for the small set of layouts that repeat
/// across pages. Prefer these over reusing primitive spacing names at call
/// sites when the intent is "page padding" or "sheet padding", not a bare gap.
abstract final class ToonMetrics {
  /// Outer page chrome: common horizontal rail and vertical breathing room.
  static const EdgeInsets pagePad = EdgeInsets.fromLTRB(
    Tok.s16,
    Tok.s12,
    Tok.s16,
    Tok.s24,
  );
  static const EdgeInsets pageHeader = EdgeInsets.fromLTRB(
    Tok.s16,
    Tok.s14,
    Tok.s16,
    0,
  );
  static const EdgeInsets sectionHeader = EdgeInsets.fromLTRB(
    Tok.s16,
    Tok.s12,
    Tok.s16,
    0,
  );

  /// Standard content card body.
  static const EdgeInsets cardPad = EdgeInsets.all(Tok.s14);

  /// Bottom-sheet body paddings. The header variant is used by taller sheets
  /// whose handle and title need more top separation.
  static const EdgeInsets sheetPad = EdgeInsets.fromLTRB(
    Tok.s20,
    Tok.s8,
    Tok.s20,
    Tok.s18,
  );
  static const EdgeInsets sheetFooter = EdgeInsets.fromLTRB(
    Tok.s20,
    Tok.s8,
    Tok.s20,
    Tok.s22,
  );
  static const EdgeInsets sheetHeader = EdgeInsets.fromLTRB(
    Tok.s20,
    Tok.s20,
    Tok.s20,
    Tok.s18,
  );

  /// Confirmation-dialog body.
  static const EdgeInsets dialogPad = EdgeInsets.fromLTRB(
    Tok.s20,
    Tok.s22,
    Tok.s20,
    Tok.s16,
  );

  /// Dense list row used by ledger, reports, and record pickers.
  static const EdgeInsets listRow = EdgeInsets.symmetric(
    horizontal: Tok.s14,
    vertical: Tok.s11,
  );
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
      bodyLarge: text.bodyLarge?.copyWith(fontSize: Tok.fs15),
      bodyMedium: text.bodyMedium?.copyWith(fontSize: Tok.fs14),
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
        fontSize: Tok.fs20,
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
        borderRadius: BorderRadius.circular(Tok.rLg),
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
        fontSize: Tok.fs14,
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
        fontSize: Tok.fs20,
      ),
      contentTextStyle: text.bodyMedium?.copyWith(
        color: scheme.onSurfaceVariant,
        fontSize: Tok.fs14,
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
      // 校验错误态统一走主题：现在页面校验提示多走 SnackBar，
      // 哪天启用 errorText 就直接有统一样式，不用每个表单自己写。
      errorStyle: TextStyle(color: scheme.error, fontSize: Tok.fs12),
      contentPadding: const EdgeInsets.symmetric(horizontal: Tok.s16, vertical: Tok.s14),
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
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Tok.rMd),
        borderSide: BorderSide(color: scheme.error),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Tok.rMd),
        borderSide: BorderSide(color: scheme.error, width: 2),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, Tok.hControl),
        padding: const EdgeInsets.symmetric(horizontal: Tok.s24),
        textStyle: text.labelLarge,
        shape: const StadiumBorder(),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, Tok.hControl),
        padding: const EdgeInsets.symmetric(horizontal: Tok.s24),
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
      labelStyle: text.labelLarge?.copyWith(fontSize: Tok.fs13),
      padding: const EdgeInsets.symmetric(horizontal: Tok.s12, vertical: Tok.s6),
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
