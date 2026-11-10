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

/// 预算条参数：副行显示「还剩」还是「已花」（P5 · choice 类型）。
///
/// 两种口径都成立：剩余派关心还能花多少，支出派关心已经花掉多少。
/// 值用英文 key，文案随时可改而不影响老配置。
const DashboardParamSpec kBudgetDetailParam = DashboardParamSpec(
  id: 'detail',
  title: '副行显示',
  kind: DashboardParamKind.choice,
  defaultValue: 'remaining',
  options: <DashboardParamOption>[
    DashboardParamOption('remaining', '还剩'),
    DashboardParamOption('spent', '已花'),
  ],
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
  List<DashboardParamSpec> get childSpecs => const <DashboardParamSpec>[
    kBudgetShowDailyParam,
    kBudgetDetailParam,
  ];

  @override
  List<Widget> buildSlivers(
    BuildContext context,
    LedgerState state,
    DashboardDeps deps,
  ) {
    final Map<String, Object?>? params = paramsOf(deps.params, id);
    final bool showDaily = kBudgetShowDailyParam.boolOf(params);
    final String detail = kBudgetDetailParam.choiceOf(params);
    return <Widget>[
      SliverToBoxAdapter(
        child: BudgetStrip(
          showDaily: showDaily,
          detail: detail == 'spent'
              ? BudgetStripDetail.spent
              : BudgetStripDetail.remaining,
        ),
      ),
    ];
  }
}
