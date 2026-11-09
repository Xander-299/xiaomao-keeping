/// 首页模块：本月预算条。
library;

import 'package:flutter/material.dart';

import 'package:yanxin/features/ledger/application/ledger_controller.dart';
import 'package:yanxin/features/ledger/presentation/widgets/budget_strip.dart';

import '../dashboard_module.dart';
import '../dashboard_param.dart';

/// 预算条参数：是否在详情里显示「每天可花 ¥X」（内部组件，树形二级控制）。
const DashboardParamSpec kBudgetShowDailyParam = DashboardParamSpec(
  id: 'show_daily',
  title: '每天可花',
  defaultValue: true,
);

class BudgetStripModule extends DashboardModule {
  const BudgetStripModule();

  @override
  String get id => 'budget_strip';

  @override
  String get title => '本月预算';

  @override
  String get description => '预算进度与剩余额度';

  @override
  int get order => 20;

  @override
  double get spacingBefore => 24;

  @override
  List<DashboardParamSpec> get childSpecs =>
      const <DashboardParamSpec>[kBudgetShowDailyParam];

  @override
  List<Widget> buildSlivers(
    BuildContext context,
    LedgerState state,
    DashboardDeps deps,
  ) {
    final bool showDaily = DashboardParamSpec.boolValue(
      paramsOf(deps.params, id),
      kBudgetShowDailyParam,
    );
    return <Widget>[
      SliverToBoxAdapter(child: BudgetStrip(showDaily: showDaily)),
    ];
  }
}
