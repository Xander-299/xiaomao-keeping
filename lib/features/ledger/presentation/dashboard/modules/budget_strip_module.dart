/// 首页模块：本月预算条。
library;

import 'package:flutter/material.dart';

import 'package:yanxin/features/ledger/application/ledger_controller.dart';
import 'package:yanxin/features/ledger/presentation/widgets/budget_strip.dart';

import '../dashboard_module.dart';

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
  List<Widget> buildSlivers(
    BuildContext context,
    LedgerState state,
    DashboardDeps deps,
  ) => const <Widget>[SliverToBoxAdapter(child: BudgetStrip())];
}
