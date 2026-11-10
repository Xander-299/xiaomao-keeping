/// 首页模块：「记一笔 / 问一句」入口卡。
library;

import 'package:flutter/material.dart';

import 'package:yanxin/features/chat/presentation/widgets/chat_entry_card.dart';
import 'package:yanxin/features/ledger/application/ledger_controller.dart';

import '../dashboard_module.dart';
import '../dashboard_param.dart';

/// 入口卡参数：是否显示示例问题（内部组件，树形二级控制）。
const DashboardParamSpec kChatShowSamplesParam = DashboardParamSpec(
  id: 'show_samples',
  title: '示例问题',
  defaultValue: true,
);

/// 示例问题条数（P5 · count 类型）：1–3 条。
const DashboardParamSpec kChatSampleCountParam = DashboardParamSpec(
  id: 'sample_count',
  title: '示例条数',
  kind: DashboardParamKind.count,
  defaultValue: 3,
  min: 1,
  max: 3,
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
  List<DashboardParamSpec> get childSpecs => const <DashboardParamSpec>[
    kChatShowSamplesParam,
    kChatSampleCountParam,
  ];

  @override
  List<Widget> buildSlivers(
    BuildContext context,
    LedgerState state,
    DashboardDeps deps,
  ) {
    final Map<String, Object?>? params = paramsOf(deps.params, id);
    final bool showSamples = kChatShowSamplesParam.boolOf(params);
    final int sampleCount = kChatSampleCountParam.countOf(params);
    return <Widget>[
      SliverToBoxAdapter(
        child: ChatEntryCard(
          showSamples: showSamples,
          sampleCount: sampleCount,
        ),
      ),
    ];
  }
}
