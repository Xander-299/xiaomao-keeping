/// 首页模块契约：每个首屏区块都是一个可排序、可隐藏的模块。
library;

import 'package:flutter/material.dart';

import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/features/ledger/application/ledger_controller.dart';

/// 模块之间共享的页面动作，避免模块直接依赖 HomePage 的私有方法。
class DashboardDeps {
  const DashboardDeps({
    required this.categoryNameOf,
    required this.onEdit,
    required this.onDelete,
    required this.onPrevMonth,
    required this.onNextMonth,
  });

  final String Function(String?) categoryNameOf;
  final ValueChanged<TxRow> onEdit;
  final Future<void> Function(TxRow) onDelete;
  final VoidCallback onPrevMonth;
  final VoidCallback onNextMonth;
}

/// 首页模块。
///
/// [order] 越小越靠前；[spacingBefore] 是该模块前面的竖向间距。
/// P2 只做默认注册表；P3 再把 enabled / order 落到用户配置。
abstract class DashboardModule {
  const DashboardModule();

  String get id;

  /// 设置页显示名。
  String get title;

  /// 设置页说明。
  String get description;

  int get order;

  /// 是否允许用户隐藏；核心模块（本月收支 / 本月账单）为 false。
  bool get canHide => true;

  double get spacingBefore => 0;

  /// 返回该模块贡献的 sliver 列表；通常 1 个，交易列表会返回多个。
  List<Widget> buildSlivers(
    BuildContext context,
    LedgerState state,
    DashboardDeps deps,
  );
}
