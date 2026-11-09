/// 首页模块：「记一笔 / 问一句」入口卡。
library;

import 'package:flutter/material.dart';

import 'package:yanxin/features/chat/presentation/widgets/chat_entry_card.dart';
import 'package:yanxin/features/ledger/application/ledger_controller.dart';

import '../dashboard_module.dart';

class ChatEntryModule extends DashboardModule {
  const ChatEntryModule();

  @override
  String get id => 'chat_entry';

  @override
  int get order => 30;

  @override
  double get spacingBefore => 20;

  @override
  List<Widget> buildSlivers(
    BuildContext context,
    LedgerState state,
    DashboardDeps deps,
  ) => const <Widget>[SliverToBoxAdapter(child: ChatEntryCard())];
}
