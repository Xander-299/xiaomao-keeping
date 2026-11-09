/// 卡通主题调色板（浅色 / 深色两套）。
///
/// 背景：F7.6 把色值做成了 `Tok` 的**编译期常量**，无法随主题切换（`const Color` 不会变，
/// 且 `const` 构造的 widget 实例会被 Element 判 `identical` 直接跳过重建）。
/// F7.17 起颜色全部从 `Theme.of(context)` 解析：**`ThemeExtension` + 实例方法**。
///
/// 用法（widget / build 内）：
/// ```dart
/// final ToonPalette p = context.toon;
/// Container(decoration: BoxDecoration(color: p.paper, border: p.inkBorder(), boxShadow: p.hard()));
/// ```
///
/// 约定：
/// - **产品代码里不出现裸 `Color(0x…)`**（本文件与 `toon.dart` 的画布细节除外）；
/// - 几何量（描边宽度 / 圆角）仍留在 [Tok]（与主题无关，不随深浅变）；
/// - 自定义绘制的画笔颜色**由构造函数注入**，不要在 `paint()` 里读 context。
library;

import 'package:flutter/material.dart';

import 'theme_seed.dart';
import 'tokens.dart';

/// 一整套卡通视觉色板。
@immutable
class ToonPalette extends ThemeExtension<ToonPalette> {
  const ToonPalette({
    required this.ink,
    required this.ink2,
    required this.ink3,
    required this.paper,
    required this.canvas,
    required this.canvas2,
    required this.brand,
    required this.brandDeep,
    required this.onBrand,
    required this.brandInk,
    required this.brandTint,
    required this.brandTint2,
    required this.red,
    required this.redTint,
    required this.redInk,
    required this.onRed,
    required this.green,
    required this.greenTint,
    required this.blue,
    required this.blueTint,
    required this.purple,
    required this.purpleTint,
    required this.pink,
    required this.lemon,
    required this.line,
    required this.dash,
    required this.track,
    required this.heroInk,
    required this.snout,
    required this.blush,
    required this.decorInk,
    required this.shadow,
    required this.veil,
    required this.pie,
  });

  // ── 墨色：描边与文字三阶 ──
  final Color ink;
  final Color ink2;
  final Color ink3;

  // ── 纸与画布 ──
  final Color paper;
  final Color canvas;
  final Color canvas2;

  // ── 品牌色 ──

  /// 品牌主色（**两套主题共用**：森绿是品牌锚点）。
  final Color brand;

  /// 品牌深色：浅底上的品牌字 / 光标（深色主题下提亮）。
  final Color brandDeep;

  /// **品牌实心底上的字**（主按钮 / 选中 chip / 中央 +）。
  final Color onBrand;

  /// **品牌浅底（[brandTint]）上的字**（深浅主题各取 M3 对应角色）。
  final Color brandInk;

  final Color brandTint;
  final Color brandTint2;

  // ── 语义色（糖果色） ──
  final Color red;
  final Color redTint;

  /// 红底提示条上的深红字（[red] 铺在 [redTint] 上对比不足，单列）。
  final Color redInk;

  /// **实心 [red] 底上的字 / 图标**（左滑删除的动作区）。
  ///
  /// 不能直接用 [veil]（白）：[red] 在暗底上要够亮才能当金额色，亮度被顶到 0.30 上下，
  /// 白字压上去只有 ~2.8:1（深色）/ ~3.0:1（浅色）。用深暖黑才够 4.5:1。
  final Color onRed;

  final Color green;
  final Color greenTint;
  final Color blue;
  final Color blueTint;
  final Color purple;
  final Color purpleTint;
  final Color pink;
  final Color lemon;

  // ── 线条 ──

  /// 实线分割 / 卡片内浅分隔。
  final Color line;

  /// 虚线分隔（半透明墨色）。
  final Color dash;

  /// 环形进度 / 柱状 / 饼图的底槽。
  final Color track;

  /// hero 卡上的字色（hero 恒为品牌浅底，语义角色随主题切换）。
  final Color heroInk;

  /// 小猪鼻子的奶白。
  final Color snout;

  /// 腮红。
  final Color blush;

  /// **插画描边**（小猪的轮廓 / 眼睛、星星贴纸的边）：两套主题都恒为深色。
  ///
  /// 这些插画永远画在**品牌底或白底**上，若跟着 [ink] 在深色主题下反成浅色，
  /// 就会得到「白底白描边」的一团。
  final Color decorInk;

  /// 硬阴影色：浅色直接用墨色，深色用纯黑（浅色阴影在暗底上会像发光）。
  final Color shadow;

  /// 品牌色底上的半透明覆盖（hero 上的小胶囊 / 装饰圆）：两套主题都是白。
  final Color veil;

  /// 分类占比调色板（按占比顺序取用）。
  final List<Color> pie;

  // ─────────────────────────── 形体助手（Material 3 观感） ───────────────────────────

  /// 卡片阴影（M3 elevation 观感）：柔和、向下、无描边。
  ///
  /// 名字保留 `hard` 只为不改 42 处调用点；现在 `d` 表示**强度**（1≈elevation1，4≈elevation3），
  /// `blurRadius: 0` 的「硬边」已废弃 —— 那是卡通风，不是 Material。
  List<BoxShadow> hard({double d = 4, Color? color}) => <BoxShadow>[
    BoxShadow(
      color: (color ?? shadow).withValues(alpha: 0.14),
      offset: Offset(0, d * 0.6),
      blurRadius: d * 1.6,
    ),
  ];

  /// 发丝描边（M3 `outlineVariant`）：1dp，不再是 2.5dp 墨线。
  ///
  /// [on] 参数保留仅为兼容旧调用点（曾经用于「亮底换深色描边」）；M3 下统一走 outline。
  Border inkBorder({double w = Tok.bw, Color? on}) =>
      Border.all(color: on == null ? line : on.withValues(alpha: 0.24), width: w);

  /// 任意底色上的前景色：**亮底用深墨、暗底用白**。
  ///
  /// 用于「底色不是主题色」的场合（如账户自选色 `#FF6B8A` 这类用户数据）：
  /// 深色主题下 [ink] 是暖白，直接铺在亮色块上会读不清。
  Color inkOn(Color background) =>
      background.computeLuminance() > 0.45 ? decorInk : veil;

  /// 卡片装饰：M3 表面 + 柔和阴影（默认无描边）。
  BoxDecoration cardDeco({
    Color? color,
    double radius = Tok.rLg,
    double depth = 4,
    bool bordered = false,
  }) => BoxDecoration(
    color: color ?? paper,
    borderRadius: BorderRadius.circular(radius),
    border: bordered ? Border.all(color: line) : null,
    boxShadow: depth > 0 ? hard(d: depth * 0.5) : null,
  );

  // ─────────────────────────── 调色板本体 ───────────────────────────

  /// 品牌主色（Material 3 的 seed）：2026-10-28 由琥珀改为森绿（方案 B）。
  ///
  /// 这只是**默认**种子；用户可在「设置 → 主题色」里换（[ToonSeed]），
  /// 换完由 [lightOf] / [darkOf] 现算调色板。
  static const Color seed = Color(0xFFFFB627);

  static final Map<ToonSeed, ToonPalette> _lightCache = <ToonSeed, ToonPalette>{};
  static final Map<ToonSeed, ToonPalette> _darkCache = <ToonSeed, ToonPalette>{};

  /// 指定主题色的浅色板（按 seed 缓存：`fromSeed` 调一次约 1ms，别在 build 里重算）。
  static ToonPalette lightOf(ToonSeed s) => _lightCache.putIfAbsent(
    s,
    () => _fromScheme(
      ColorScheme.fromSeed(seedColor: s.seed, brightness: Brightness.light),
    ),
  );

  /// 指定主题色的深色板。
  static ToonPalette darkOf(ToonSeed s) => _darkCache.putIfAbsent(
    s,
    () => _fromScheme(
      ColorScheme.fromSeed(seedColor: s.seed, brightness: Brightness.dark),
    ),
  );

  /// 浅色 / 深色两套（默认森绿）：**全部从 `ColorScheme.fromSeed` 派生**（M3 语义角色 → 旧字段名）。
  ///
  /// 为什么保留旧字段名：全仓 155 处 `context.toon`、432 处 `Toon*` 调用都按旧名取色；
  /// 换风格时改「色板怎么来」比改「谁在用」便宜得多。
  static ToonPalette get light => lightOf(ToonSeed.amber);
  static ToonPalette get dark => darkOf(ToonSeed.amber);

  static ToonPalette _fromScheme(ColorScheme s) => ToonPalette(
    ink: s.onSurface,
    ink2: s.onSurfaceVariant,
    ink3: s.outline,
    paper: s.surface,
    canvas: s.surfaceContainerLowest,
    canvas2: s.surfaceContainerHigh,
    brand: s.primary,
    brandDeep: s.primary,
    onBrand: s.onPrimary,
    brandInk: s.onPrimaryContainer,
    brandTint: s.primaryContainer,
    brandTint2: s.primaryFixedDim,
    red: s.error,
    redTint: s.errorContainer,
    redInk: s.onErrorContainer,
    onRed: s.onError,
    green: s.tertiary,
    greenTint: s.tertiaryContainer,
    blue: s.secondary,
    blueTint: s.secondaryContainer,
    purple: s.tertiary,
    purpleTint: s.tertiaryContainer,
    pink: s.tertiary,
    lemon: s.primaryFixed,
    line: s.outlineVariant,
    dash: s.outlineVariant,
    track: s.surfaceContainerHighest,
    heroInk: s.onPrimaryContainer,
    snout: s.surfaceContainerHighest,
    blush: s.tertiaryContainer,
    decorInk: s.onSurface,
    shadow: s.shadow,
    veil: s.surface,
    // 第一瓣跟品牌色走，换主题时图表也跟着协调；其余 8 色固定（要保证互异）
    pie: <Color>[s.primary, ...pieColors.skip(1)],
  );

  /// 分类占比调色板的**源常量**（两套主题共用；测试与画笔也直接引用它）。
  /// 2026-10-28 随换肤调整：品牌森绿打头，原首位的琥珀移到原亮绿位（保 9 色互异）。
  static const List<Color> pieColors = <Color>[
    Color(0xFF1F8F63),
    Color(0xFFFF6B8A),
    Color(0xFF4DC9C0),
    Color(0xFF5A8DFF),
    Color(0xFFB18CFF),
    Color(0xFFFFB627),
    Color(0xFFFF8A3D),
    Color(0xFFF06FC0),
    Color(0xFF9AA5B1),
  ];

  /// 取当前上下文的调色板；主题没注册时回落浅色（测试里裸 `MaterialApp` 也不炸）。
  static ToonPalette of(BuildContext context) =>
      Theme.of(context).extension<ToonPalette>() ?? light;

  @override
  ToonPalette copyWith({
    Color? ink,
    Color? ink2,
    Color? ink3,
    Color? paper,
    Color? canvas,
    Color? canvas2,
    Color? brand,
    Color? brandDeep,
    Color? onBrand,
    Color? brandInk,
    Color? brandTint,
    Color? brandTint2,
    Color? red,
    Color? redTint,
    Color? redInk,
    Color? onRed,
    Color? green,
    Color? greenTint,
    Color? blue,
    Color? blueTint,
    Color? purple,
    Color? purpleTint,
    Color? pink,
    Color? lemon,
    Color? line,
    Color? dash,
    Color? track,
    Color? heroInk,
    Color? snout,
    Color? blush,
    Color? decorInk,
    Color? shadow,
    Color? veil,
    List<Color>? pie,
  }) => ToonPalette(
    ink: ink ?? this.ink,
    ink2: ink2 ?? this.ink2,
    ink3: ink3 ?? this.ink3,
    paper: paper ?? this.paper,
    canvas: canvas ?? this.canvas,
    canvas2: canvas2 ?? this.canvas2,
    brand: brand ?? this.brand,
    brandDeep: brandDeep ?? this.brandDeep,
    onBrand: onBrand ?? this.onBrand,
    brandInk: brandInk ?? this.brandInk,
    brandTint: brandTint ?? this.brandTint,
    brandTint2: brandTint2 ?? this.brandTint2,
    red: red ?? this.red,
    redTint: redTint ?? this.redTint,
    redInk: redInk ?? this.redInk,
    onRed: onRed ?? this.onRed,
    green: green ?? this.green,
    greenTint: greenTint ?? this.greenTint,
    blue: blue ?? this.blue,
    blueTint: blueTint ?? this.blueTint,
    purple: purple ?? this.purple,
    purpleTint: purpleTint ?? this.purpleTint,
    pink: pink ?? this.pink,
    lemon: lemon ?? this.lemon,
    line: line ?? this.line,
    dash: dash ?? this.dash,
    track: track ?? this.track,
    heroInk: heroInk ?? this.heroInk,
    snout: snout ?? this.snout,
    blush: blush ?? this.blush,
    decorInk: decorInk ?? this.decorInk,
    shadow: shadow ?? this.shadow,
    veil: veil ?? this.veil,
    pie: pie ?? this.pie,
  );

  @override
  ToonPalette lerp(covariant ToonPalette? other, double t) {
    if (other == null) return this;
    return ToonPalette(
      ink: Color.lerp(ink, other.ink, t)!,
      ink2: Color.lerp(ink2, other.ink2, t)!,
      ink3: Color.lerp(ink3, other.ink3, t)!,
      paper: Color.lerp(paper, other.paper, t)!,
      canvas: Color.lerp(canvas, other.canvas, t)!,
      canvas2: Color.lerp(canvas2, other.canvas2, t)!,
      brand: Color.lerp(brand, other.brand, t)!,
      brandDeep: Color.lerp(brandDeep, other.brandDeep, t)!,
      onBrand: Color.lerp(onBrand, other.onBrand, t)!,
      brandInk: Color.lerp(brandInk, other.brandInk, t)!,
      brandTint: Color.lerp(brandTint, other.brandTint, t)!,
      brandTint2: Color.lerp(brandTint2, other.brandTint2, t)!,
      red: Color.lerp(red, other.red, t)!,
      redTint: Color.lerp(redTint, other.redTint, t)!,
      redInk: Color.lerp(redInk, other.redInk, t)!,
      onRed: Color.lerp(onRed, other.onRed, t)!,
      green: Color.lerp(green, other.green, t)!,
      greenTint: Color.lerp(greenTint, other.greenTint, t)!,
      blue: Color.lerp(blue, other.blue, t)!,
      blueTint: Color.lerp(blueTint, other.blueTint, t)!,
      purple: Color.lerp(purple, other.purple, t)!,
      purpleTint: Color.lerp(purpleTint, other.purpleTint, t)!,
      pink: Color.lerp(pink, other.pink, t)!,
      lemon: Color.lerp(lemon, other.lemon, t)!,
      line: Color.lerp(line, other.line, t)!,
      dash: Color.lerp(dash, other.dash, t)!,
      track: Color.lerp(track, other.track, t)!,
      heroInk: Color.lerp(heroInk, other.heroInk, t)!,
      snout: Color.lerp(snout, other.snout, t)!,
      blush: Color.lerp(blush, other.blush, t)!,
      decorInk: Color.lerp(decorInk, other.decorInk, t)!,
      shadow: Color.lerp(shadow, other.shadow, t)!,
      veil: Color.lerp(veil, other.veil, t)!,
      pie: <Color>[
        for (int i = 0; i < pie.length; i++)
          Color.lerp(pie[i], other.pie[i % other.pie.length], t)!,
      ],
    );
  }
}

/// `context.toon` —— 取当前主题的调色板。
extension ToonPaletteContext on BuildContext {
  ToonPalette get toon => ToonPalette.of(this);
}
