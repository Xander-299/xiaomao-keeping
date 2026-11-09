/// 外观模式（F7.17）：浅色 / 深色 / 跟随系统。
///
/// 纯函数模块（不碰 DB / 不碰 widget），解析与默认值均可被 `test()` 直接覆盖。
library;

import 'package:flutter/material.dart';

/// `schema_meta` 里存外观模式的键。**不存在 = 跟随系统**（不写库，老用户自然跟随系统）。
const String kThemeModeKey = 'theme_mode';

/// 三种外观模式。
///
/// 落库值就是这个枚举的 `name`（`light` / `dark` / `system`），便于人肉排查 KV 表。
enum ToonThemeMode {
  /// 恒浅色（默认）。
  light,

  /// 恒深色。
  dark,

  /// 跟随系统深浅色。
  system;

  /// 解析落库值：`dark` / `system` 之外的一切（含 null、空串、脏数据）都按 [light]。
  ///
  /// 脏数据不抛错：手工改库 / 未来枚举增减都不该让 App 起不来。
  static ToonThemeMode parse(String? raw) => switch (raw?.trim().toLowerCase()) {
    'dark' => ToonThemeMode.dark,
    'system' => ToonThemeMode.system,
    _ => ToonThemeMode.light,
  };

  /// 落库值（= 枚举名，见 [parse]）。
  String get storageValue => name;

  /// 设置页标题。
  String get label => switch (this) {
    ToonThemeMode.light => '浅色',
    ToonThemeMode.dark => '深色',
    ToonThemeMode.system => '跟随系统',
  };

  /// 设置页副标题。
  String get hint => switch (this) {
    ToonThemeMode.light => '一直使用浅色',
    ToonThemeMode.dark => '一直使用深色',
    ToonThemeMode.system => '跟随手机系统的深浅色',
  };

  /// 设置页行图标。
  IconData get icon => switch (this) {
    ToonThemeMode.light => Icons.light_mode_rounded,
    ToonThemeMode.dark => Icons.dark_mode_rounded,
    ToonThemeMode.system => Icons.brightness_auto_rounded,
  };

  /// 映射到 Flutter 的 [ThemeMode]。
  ThemeMode get materialMode => switch (this) {
    ToonThemeMode.light => ThemeMode.light,
    ToonThemeMode.dark => ThemeMode.dark,
    ToonThemeMode.system => ThemeMode.system,
  };
}
