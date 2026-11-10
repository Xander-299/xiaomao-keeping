/// P5 · 模块参数的类型系统（toggle / choice / count）。
///
/// 重点是**容错**：配置是用户可写、可手改、跨版本迁移的 JSON，任何脏值都必须回落默认，
/// 不能让首页崩掉或显示成空白。这里逐条把「脏」的形态钉死。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:yanxin/features/ledger/presentation/dashboard/dashboard_config.dart';
import 'package:yanxin/features/ledger/presentation/dashboard/dashboard_param.dart';
import 'package:yanxin/features/ledger/presentation/dashboard/dashboard_registry.dart';

const DashboardParamSpec _toggle = DashboardParamSpec(
  id: 't',
  title: '开关',
);

const DashboardParamSpec _choice = DashboardParamSpec(
  id: 'c',
  title: '几选一',
  kind: DashboardParamKind.choice,
  defaultValue: 'b',
  options: <DashboardParamOption>[
    DashboardParamOption('a', '甲'),
    DashboardParamOption('b', '乙'),
  ],
);

const DashboardParamSpec _count = DashboardParamSpec(
  id: 'n',
  title: '条数',
  kind: DashboardParamKind.count,
  defaultValue: 3,
  min: 1,
  max: 5,
);

Map<String, Object?> _p(String id, Object? v) => <String, Object?>{id: v};

void main() {
  group('toggle', () {
    test('缺键 / 脏值回落默认 true', () {
      expect(_toggle.boolOf(null), isTrue);
      expect(_toggle.boolOf(const <String, Object?>{}), isTrue);
      expect(_toggle.boolOf(_p('t', 'true')), isTrue);
      expect(_toggle.boolOf(_p('t', 1)), isTrue);
    });

    test('明确 false 时读回 false', () {
      expect(_toggle.boolOf(_p('t', false)), isFalse);
    });
  });

  group('choice', () {
    test('合法值原样读回', () {
      expect(_choice.choiceOf(_p('c', 'a')), 'a');
      expect(_choice.choiceOf(_p('c', 'b')), 'b');
    });

    test('不在选项里 / 类型不对 / 缺键 → 默认值', () {
      expect(_choice.choiceOf(_p('c', 'zzz')), 'b');
      expect(_choice.choiceOf(_p('c', 123)), 'b');
      expect(_choice.choiceOf(_p('c', null)), 'b');
      expect(_choice.choiceOf(null), 'b');
    });
  });

  group('count', () {
    test('区间内整数原样读回', () {
      expect(_count.countOf(_p('n', 1)), 1);
      expect(_count.countOf(_p('n', 5)), 5);
    });

    test('JSON double 只要整值就认（10.0 → 10）', () {
      expect(_count.countOf(_p('n', 4.0)), 4);
    });

    test('字符串数字也认（手改 JSON 的常见形态）', () {
      expect(_count.countOf(_p('n', '2')), 2);
      expect(_count.countOf(_p('n', ' 4 ')), 4);
    });

    test('真小数 / 非数字 / 缺键 → 默认值', () {
      expect(_count.countOf(_p('n', 3.7)), 3, reason: '3.7 判脏，回落默认 3');
      expect(_count.countOf(_p('n', 4.7)), 3);
      expect(_count.countOf(_p('n', 'abc')), 3);
      expect(_count.countOf(_p('n', true)), 3);
      expect(_count.countOf(null), 3);
    });

    test('越界回落默认值，而不是夹到边界', () {
      // 「手改 JSON 成 999」不该变成「显示 5 条」—— 那等于替用户做了选择。
      expect(_count.countOf(_p('n', 999)), 3);
      expect(_count.countOf(_p('n', 0)), 3);
      expect(_count.countOf(_p('n', -5)), 3);
    });

    test('默认值本身被夹进区间（声明写错也不至于越界）', () {
      const DashboardParamSpec bad = DashboardParamSpec(
        id: 'n',
        title: '条数',
        kind: DashboardParamKind.count,
        defaultValue: 99,
        min: 1,
        max: 5,
      );
      expect(bad.countOf(_p('n', 999)), 5);
    });
  });

  group('specOf', () {
    test('能找到模块的参数（含内部组件）', () {
      expect(DashboardRegistry.specOf('budget_strip', 'show_daily'), isNotNull);
      expect(DashboardRegistry.specOf('budget_strip', 'detail'), isNotNull);
      expect(DashboardRegistry.specOf('tx_list', 'limit'), isNotNull);
      expect(
        DashboardRegistry.specOf('chat_entry', 'sample_count')?.kind,
        DashboardParamKind.count,
      );
    });

    test('未知模块 / 未知参数 → null（调用方据此拒绝写入）', () {
      expect(DashboardRegistry.specOf('nope', 'limit'), isNull);
      expect(DashboardRegistry.specOf('tx_list', 'nope'), isNull);
    });
  });

  group('JSON 往返', () {
    test('三种类型的值都能原样存取（sanitize 不吃 params）', () {
      const DashboardConfig config = DashboardConfig(
        params: <String, Map<String, Object?>>{
          'budget_strip': <String, Object?>{'show_daily': false, 'detail': 'spent'},
          'chat_entry': <String, Object?>{'sample_count': 2},
        },
      );
      final DashboardConfig back = DashboardConfig.fromJson(
        jsonDecode(jsonEncode(config.toJson())) as Map<String, Object?>,
      );
      final DashboardConfig clean = DashboardRegistry.sanitize(back);
      expect(clean.params?['budget_strip']?['show_daily'], isFalse);
      expect(clean.params?['budget_strip']?['detail'], 'spent');
      expect(clean.params?['chat_entry']?['sample_count'], 2);
    });
  });
}
