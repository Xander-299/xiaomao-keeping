/// 外观模式（F7.17）：解析 / 落库值 / 映射 Flutter `ThemeMode`。
///
/// 纯函数模块，不碰 DB / 不碰 widget —— 用 `test()` 直接覆盖。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:yanxin/core/theme/theme_mode.dart';

void main() {
  group('ToonThemeMode.parse', () {
    test('三个合法值', () {
      expect(ToonThemeMode.parse('light'), ToonThemeMode.light);
      expect(ToonThemeMode.parse('dark'), ToonThemeMode.dark);
      expect(ToonThemeMode.parse('system'), ToonThemeMode.system);
    });

    test('大小写与首尾空白都认（值来自外部存储，别卡格式）', () {
      expect(ToonThemeMode.parse('DARK'), ToonThemeMode.dark);
      expect(ToonThemeMode.parse('  Light  '), ToonThemeMode.light);
    });

    test('键不存在 / 空串 / 脏数据 / 未来枚举一律回落 light，不抛错', () {
      // 「不写库 = 浅色」是默认值的实现前提：老用户覆盖安装后自然浅色
      for (final String? raw in <String?>[null, '', '   ', 'black', 'amoled']) {
        expect(ToonThemeMode.parse(raw), ToonThemeMode.light, reason: '$raw');
      }
    });
  });

  group('落库值与映射', () {
    test('storageValue = 枚举名（parse 能原样读回）', () {
      for (final ToonThemeMode m in ToonThemeMode.values) {
        expect(ToonThemeMode.parse(m.storageValue), m);
        expect(m.storageValue, m.name);
      }
    });

    test('映射到 Flutter ThemeMode', () {
      expect(ToonThemeMode.light.materialMode, ThemeMode.light);
      expect(ToonThemeMode.dark.materialMode, ThemeMode.dark);
      expect(ToonThemeMode.system.materialMode, ThemeMode.system);
    });

    test('三档文案各不相同且非空（设置页靠它区分）', () {
      final labels = <String>{
        for (final ToonThemeMode m in ToonThemeMode.values) m.label,
      };
      expect(labels, hasLength(3));
      expect(labels, <String>{'浅色', '深色', '跟随系统'});
      for (final ToonThemeMode m in ToonThemeMode.values) {
        expect(m.hint, isNotEmpty);
      }
    });
  });
}
