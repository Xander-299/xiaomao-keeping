/// 主题色（品牌 seed）目录：设置页里可切换的几套配色。
///
/// 为什么只换 **seed**：整套色板（`ToonPalette`）是由 `ColorScheme.fromSeed(seed)`
/// 派生出来的（见 `palette.dart`），所以换主题 = 换一个种子色，
/// hero / 按钮 / 选中态 / 图表配色会整族跟着变，页面代码一行不用改。
///
/// 约定：**只追加、不改已有的 name**（落库值就是 `name`，改了老用户的选择会失效）。
library;

import 'package:flutter/material.dart';

/// 可选的品牌主色。
enum ToonSeed {
  /// 默认：琥珀（与启动图标的橙底对齐，设置页排第一位）。
  amber('琥珀', Color(0xFFFFB627), '默认 · 元气黄'),

  /// 2026-10-28 换肤时的森绿（保留给喜欢冷色的用户）。
  forest('森绿', Color(0xFF2E5E4E), '沉稳 · 墨绿'),

  /// 冷色系，长时间记账更安静。
  indigo('黛蓝', Color(0xFF3F5A8A), '冷静 · 靛青'),

  /// 柔和偏暖，适合偏好暖粉的用户。
  rose('藕粉', Color(0xFFB0576F), '柔和 · 豆沙'),

  /// 深一点的紫，夜间/深色模式下层次更足。
  ink('墨紫', Color(0xFF5B4B8A), '安静 · 紫罗兰');

  const ToonSeed(this.label, this.seed, this.hint);

  /// 设置页显示名。
  final String label;

  /// 品牌种子色（喂给 `ColorScheme.fromSeed`）。
  final Color seed;

  /// 设置页副标题。
  final String hint;

  /// 落库值（= 枚举名）。
  String get storageValue => name;

  /// 解析落库值：未知 / null / 脏数据一律回落 [amber]（不能因为一个脏值起不来）。
  static ToonSeed parse(String? raw) {
    final String v = (raw ?? '').trim().toLowerCase();
    for (final ToonSeed s in ToonSeed.values) {
      if (s.name == v) return s;
    }
    return ToonSeed.amber;
  }
}
