/// 首页 Dashboard 注册表：默认顺序、配置过滤、模块间距。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:yanxin/features/ledger/presentation/dashboard/dashboard_config.dart';
import 'package:yanxin/features/ledger/presentation/dashboard/dashboard_module.dart';
import 'package:yanxin/features/ledger/presentation/dashboard/dashboard_param.dart';
import 'package:yanxin/features/ledger/presentation/dashboard/dashboard_registry.dart';

void main() {
  test('默认模块顺序 = 当前首页视觉顺序', () {
    final List<String> ids = DashboardRegistry.resolve(
      DashboardConfig.defaults,
    ).map((m) => m.id).toList();

    expect(ids, <String>[
      'autobook_banner',
      'month_hero',
      'budget_strip',
      'chat_entry',
      'tx_list',
    ]);
  });

  test('enabledIds 只保留配置里的模块', () {
    final List<String> ids = DashboardRegistry.resolve(
      const DashboardConfig(
        enabledIds: <String>{'tx_list', 'month_hero'},
      ),
    ).map((m) => m.id).toList();

    expect(ids, <String>['month_hero', 'tx_list']);
  });

  test('默认间距：预算 24 / 入口 20 / 账单 20', () {
    final Map<String, double> spacing = <String, double>{
      for (final m in DashboardRegistry.modules) m.id: m.spacingBefore,
    };

    expect(spacing['autobook_banner'], 0);
    expect(spacing['month_hero'], 0);
    expect(spacing['budget_strip'], 24);
    expect(spacing['chat_entry'], 20);
    expect(spacing['tx_list'], 20);
  });

  test('orderIds 覆盖默认排序', () {
    final List<String> ids = DashboardRegistry.resolve(
      const DashboardConfig(
        orderIds: <String>[
          'tx_list',
          'month_hero',
          'budget_strip',
          'chat_entry',
          'autobook_banner',
        ],
      ),
    ).map((m) => m.id).toList();

    expect(ids.first, 'tx_list');
    expect(ids[1], 'month_hero');
  });

  test('sanitize 丢弃未知 id、补齐缺失模块、强制核心模块', () {
    final DashboardConfig cleaned = DashboardRegistry.sanitize(
      const DashboardConfig(
        enabledIds: <String>{'bogus'},
        orderIds: <String>['tx_list', 'bogus'],
      ),
    );

    expect(cleaned.enabledIds, containsAll(<String>['month_hero', 'tx_list']));
    expect(cleaned.enabledIds, isNot(contains('bogus')));
    expect(cleaned.orderIds!.first, 'tx_list');
    expect(cleaned.orderIds, hasLength(DashboardRegistry.modules.length));
    expect(cleaned.orderIds, isNot(contains('bogus')));
  });

  test('配置 JSON 往返', () {
    const DashboardConfig config = DashboardConfig(
      enabledIds: <String>{'month_hero', 'tx_list'},
      orderIds: <String>['tx_list', 'month_hero'],
    );
    final DashboardConfig back = DashboardConfig.fromJson(config.toJson());

    expect(back.enabledIds, <String>{'month_hero', 'tx_list'});
    expect(back.orderIds, <String>['tx_list', 'month_hero']);
  });

  test('参数默认值：未配置时走 spec.defaultValue', () {
    final DashboardModule budget = DashboardRegistry.modules
        .firstWhere((m) => m.id == 'budget_strip');
    final DashboardParamSpec spec = budget.childSpecs.single;

    expect(spec.id, 'show_daily');
    expect(spec.defaultValue, isTrue);
    expect(
      DashboardParamSpec.boolValue(null, spec),
      isTrue,
      reason: '配置缺失 = 默认开（旧数据零迁移）',
    );
    expect(
      DashboardParamSpec.boolValue(
        const <String, Object?>{'show_daily': false},
        spec,
      ),
      isFalse,
    );
    // 脏值（非 bool）也回落默认
    expect(
      DashboardParamSpec.boolValue(
        const <String, Object?>{'show_daily': 'yes'},
        spec,
      ),
      isTrue,
    );
  });

  test('配置 JSON 带 params 往返', () {
    const DashboardConfig config = DashboardConfig(
      params: <String, Map<String, Object?>>{
        'budget_strip': <String, Object?>{'show_daily': false},
        'chat_entry': <String, Object?>{'show_samples': false},
      },
    );
    final DashboardConfig back = DashboardConfig.fromJson(config.toJson());

    expect(
      back.params!['budget_strip'],
      <String, Object?>{'show_daily': false},
    );
    expect(
      back.params!['chat_entry'],
      <String, Object?>{'show_samples': false},
    );
  });

  test('sanitize 不丢 params', () {
    const DashboardConfig config = DashboardConfig(
      enabledIds: <String>{'bogus'},
      orderIds: <String>['tx_list', 'bogus'],
      params: <String, Map<String, Object?>>{
        'budget_strip': <String, Object?>{'show_daily': false},
      },
    );
    final DashboardConfig cleaned = DashboardRegistry.sanitize(config);

    expect(
      cleaned.params!['budget_strip'],
      <String, Object?>{'show_daily': false},
    );
  });

  test('sanitize 保留 params（P4 回归）', () {
    final DashboardConfig cleaned = DashboardRegistry.sanitize(
      const DashboardConfig(
        enabledIds: <String>{'unknown_module'},
        params: <String, Map<String, Object?>>{
          'chat_entry': <String, Object?>{'show_samples': false},
        },
      ),
    );

    expect(
      cleaned.params!['chat_entry'],
      <String, Object?>{'show_samples': false},
      reason: 'sanitize 丢 params 会让参数改动写不进库（真机踩过）',
    );
  });
}
