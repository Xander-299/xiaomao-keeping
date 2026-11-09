/// 首页模块注册表：默认顺序在这里维护，页面只消费 resolve 的结果。
library;

import 'dashboard_config.dart';
import 'dashboard_module.dart';
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

  /// 按配置过滤后，再按 [DashboardModule.order] 排序。
  static List<DashboardModule> resolve(DashboardConfig config) {
    final List<DashboardModule> result = modules
        .where(config.isEnabled)
        .toList();
    result.sort(
      (DashboardModule a, DashboardModule b) => a.order.compareTo(b.order),
    );
    return result;
  }
}
