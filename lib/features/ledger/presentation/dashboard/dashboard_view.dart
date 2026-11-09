/// 首页 Dashboard：按注册表把模块拼成 CustomScrollView。
library;

import 'package:flutter/material.dart';

import 'package:yanxin/features/ledger/application/ledger_controller.dart';

import 'dashboard_config.dart';
import 'dashboard_module.dart';
import 'dashboard_registry.dart';

class DashboardView extends StatelessWidget {
  const DashboardView({
    super.key,
    required this.state,
    required this.deps,
    this.config = DashboardConfig.defaults,
  });

  final LedgerState state;
  final DashboardDeps deps;
  final DashboardConfig config;

  @override
  Widget build(BuildContext context) {
    final List<DashboardModule> modules = DashboardRegistry.resolve(config);
    return CustomScrollView(
      slivers: <Widget>[
        for (final DashboardModule module in modules) ...<Widget>[
          if (module.spacingBefore > 0)
            SliverToBoxAdapter(
              child: SizedBox(height: module.spacingBefore),
            ),
          ...module.buildSlivers(context, state, deps),
        ],
      ],
    );
  }
}
