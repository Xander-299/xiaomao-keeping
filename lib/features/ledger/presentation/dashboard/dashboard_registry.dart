/// 首页模块注册表：默认顺序与用户配置解析。
library;

import 'dashboard_config.dart';
import 'dashboard_module.dart';
import 'dashboard_param.dart';
import 'modules/auto_book_banner_module.dart';
import 'modules/budget_strip_module.dart';
import 'modules/chat_entry_module.dart';
import 'modules/month_hero_module.dart';
import 'modules/tx_list_module.dart';

class DashboardRegistry {
  const DashboardRegistry._();

  /// 默认模块顺序 = 当前首页的视觉顺序。
  static const List<DashboardModule> modules = <DashboardModule>[
    AutoBookBannerModule(),
    MonthHeroModule(),
    BudgetStripModule(),
    ChatEntryModule(),
    TxListModule(),
  ];

  static List<String> get defaultOrderIds {
    final List<DashboardModule> sorted = <DashboardModule>[...modules]
      ..sort((a, b) => a.order.compareTo(b.order));
    return sorted.map((m) => m.id).toList();
  }

  static Set<String> get allIds =>
      modules.map((m) => m.id).toSet();

  static Set<String> effectiveEnabledIds(DashboardConfig config) =>
      config.enabledIds ?? allIds;

  static List<String> effectiveOrderIds(DashboardConfig config) =>
      config.orderIds ?? defaultOrderIds;

  /// 找某个模块的某个参数声明（模块级 + 内部组件级都找）。
  ///
  /// 写入时要用它做归一：`setParam` 拿到的是 `Object`，得知道这个 key 该怎么校验。
  /// 找不到 = 未知参数（模块或参数已被删掉 / 拼错），调用方应拒绝写入。
  static DashboardParamSpec? specOf(String moduleId, String paramId) {
    for (final DashboardModule m in modules) {
      if (m.id != moduleId) continue;
      for (final DashboardParamSpec s in <DashboardParamSpec>[
        ...m.paramSpecs,
        ...m.childSpecs,
      ]) {
        if (s.id == paramId) return s;
      }
    }
    return null;
  }

  /// 清洗脏数据：丢弃未知 id、补齐缺失模块、强制核心模块启用。
  static DashboardConfig sanitize(DashboardConfig config) {
    final Set<String> known = allIds;
    final Set<String> enabled = <String>{
      ...(config.enabledIds ?? known),
    }..removeWhere((String id) => !known.contains(id));
    for (final DashboardModule m in modules) {
      if (!m.canHide) enabled.add(m.id);
    }

    final List<String> order = <String>[];
    for (final String id in effectiveOrderIds(config)) {
      if (known.contains(id) && !order.contains(id)) order.add(id);
    }
    for (final String id in defaultOrderIds) {
      if (!order.contains(id)) order.add(id);
    }
    return DashboardConfig(
      enabledIds: enabled,
      orderIds: order,
      params: config.params,
    );
  }

  /// 按配置过滤 + 排序。
  static List<DashboardModule> resolve(DashboardConfig config) {
    final Set<String> enabled = effectiveEnabledIds(config);
    final List<String> order = effectiveOrderIds(config);
    final Map<String, int> position = <String, int>{
      for (int i = 0; i < order.length; i++) order[i]: i,
    };

    final List<DashboardModule> result = modules
        .where((m) => enabled.contains(m.id))
        .toList();
    result.sort((a, b) {
      final int ai = position[a.id] ?? 1 << 20;
      final int bi = position[b.id] ?? 1 << 20;
      return ai.compareTo(bi);
    });
    return result;
  }
}
