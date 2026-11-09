/// 首页模块：自动记账提示条（无待提示批次时零高度）。
library;

import 'package:flutter/material.dart';

import 'package:yanxin/features/autobook/presentation/widgets/auto_book_banner.dart';
import 'package:yanxin/features/ledger/application/ledger_controller.dart';

import '../dashboard_module.dart';

class AutoBookBannerModule extends DashboardModule {
  const AutoBookBannerModule();

  @override
  String get id => 'autobook_banner';

  @override
  int get order => 0;

  @override
  List<Widget> buildSlivers(
    BuildContext context,
    LedgerState state,
    DashboardDeps deps,
  ) => const <Widget>[SliverToBoxAdapter(child: AutoBookBanner())];
}
