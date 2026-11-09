/// 首页模块：「记一笔 / 问一句」入口卡。
library;

import 'package:flutter/material.dart';

import 'package:yanxin/features/chat/presentation/widgets/chat_entry_card.dart';
import 'package:yanxin/features/ledger/application/ledger_controller.dart';

import '../dashboard_module.dart';
import '../dashboard_param.dart';

/// 入口卡参数：是否显示三个示例问题。
const DashboardParamSpec kChatShowSamplesParam = DashboardParamSpec(
  id: 'show_samples',
  title: '显示示例问题',
  defaultValue: true,
);

class ChatEntryModule extends DashboardModule {
  const ChatEntryModule();

  @override
  String get id => 'chat_entry';

  @override
  String get title => '记一笔 / 问一句';

  @override
  String get description => '聊天式记账和问账本入口';

  @override
  int get order => 30;

  @override
  double get spacingBefore => 20;

  @override
  List<DashboardParamSpec> get paramSpecs =>
      const <DashboardParamSpec>[kChatShowSamplesParam];

  @override
  List<Widget> buildSlivers(
    BuildContext context,
    LedgerState state,
    DashboardDeps deps,
  ) {
    final bool showSamples = DashboardParamSpec.boolValue(
      paramsOf(deps.params, id),
      kChatShowSamplesParam,
    );
    return <Widget>[
      SliverToBoxAdapter(child: ChatEntryCard(showSamples: showSamples)),
    ];
  }
}
