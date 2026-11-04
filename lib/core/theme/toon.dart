/// 通用组件库（**Material 3 皮肤**）。
///
/// 历史：F7.6 这里是「卡通」组件（2.5dp 墨线 + 零模糊硬阴影 + 手绘虚线 / 小猪）。
/// 2026-10-28 整体换成 Material 3：卡片走 `Card` + elevation、按钮走 Filled/Outlined、
/// chip 走 `FilterChip`、分段走 `SegmentedButton`、按压反馈走 ripple。
///
/// **组件名保留 `Toon*`**：全仓 432 处调用点按名字使用它们（`ToonCard` / `ToonButton`…），
/// 换皮肤只改这里，不动业务页面 —— 这是当初把这层抽出来的红利。
///
/// 颜色仍一律来自 [ToonPalette]（`context.toon`），而调色板本身由
/// `ColorScheme.fromSeed(森绿)` 派生（见 `palette.dart`）。
library;

import 'package:flutter/material.dart';

import 'palette.dart';
import 'tokens.dart';

export 'palette.dart';

part 'toon/press.dart';
part 'toon/card.dart';
part 'toon/dashed.dart';
part 'toon/button.dart';
part 'toon/chip_seg.dart';
part 'toon/field.dart';
part 'toon/avatar_ring.dart';
part 'toon/section_title.dart';
part 'toon/fade_value.dart';
part 'toon/float_button.dart';
part 'toon/states.dart';
part 'toon/feedback.dart';
