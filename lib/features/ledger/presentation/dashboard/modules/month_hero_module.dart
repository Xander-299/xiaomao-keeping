/// 首页模块：月份 hero（月度收支 + 翻月）。
library;

import 'package:flutter/material.dart';

import 'package:yanxin/features/ledger/application/ledger_controller.dart';
import 'package:yanxin/features/ledger/presentation/widgets/month_hero.dart';

import '../dashboard_module.dart';

class MonthHeroModule extends DashboardModule {
  const MonthHeroModule();

  @override
  String get id => 'month_hero';

  @override
  String get title => '本月收支';

  @override
  String get description => '月度收入 / 支出 / 结余与翻月';

  @override
  bool get canHide => false;

  @override
  int get order => 10;

  @override
  List<Widget> buildSlivers(
    BuildContext context,
    LedgerState state,
    DashboardDeps deps,
  ) => <Widget>[
    SliverToBoxAdapter(
      child: MonthHero(
        year: state.year,
        month: state.month,
        summary: state.summary,
        canNext: canGoNext(state.year, state.month),
        onPrevMonth: deps.onPrevMonth,
        onNextMonth: deps.onNextMonth,
      ),
    ),
  ];
}
