/// 首页模块：本月账单区（区头 + 空态 / 分组列表 + 底部留白）。
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:yanxin/core/theme/toon.dart';
import 'package:yanxin/features/ledger/application/ledger_controller.dart';
import 'package:yanxin/features/ledger/presentation/widgets/tx_group_list.dart';
import 'package:yanxin/features/reports/application/reports_controller.dart';

import '../dashboard_module.dart';

class TxListModule extends DashboardModule {
  const TxListModule();

  @override
  String get id => 'tx_list';

  @override
  String get title => '本月账单';

  @override
  String get description => '按天分组显示本月流水';

  @override
  bool get canHide => false;

  @override
  int get order => 40;

  @override
  double get spacingBefore => 20;

  @override
  List<Widget> buildSlivers(
    BuildContext context,
    LedgerState state,
    DashboardDeps deps,
  ) => <Widget>[
    const SliverToBoxAdapter(child: _SectionHeader()),
    if (state.items.isEmpty)
      SliverToBoxAdapter(
        child: _EmptyMonth(year: state.year, month: state.month),
      )
    else
      SliverToBoxAdapter(
        child: TxGroupList(
          items: state.items,
          categoryNameOf: deps.categoryNameOf,
          shrinkWrap: true,
          onEdit: deps.onEdit,
          onDelete: deps.onDelete,
        ),
      ),
    const SliverToBoxAdapter(child: SizedBox(height: 24)),
  ];
}

/// 「本月账单」区头 + 全部账单入口（→ 报表页「明细」档，文案不变）。
class _SectionHeader extends StatelessWidget {
  const _SectionHeader();

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    return ToonSectionTitle(
      title: '本月账单',
      trailing: ToonPress(
        dx: 2,
        dy: 2,
        onTap: () => context.push(
          '/reports',
          extra: const ReportsArgs(tab: kReportTabDetail),
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: p.paper,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: p.ink, width: 2),
            boxShadow: p.hard(d: 2.5),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Text(
                '全部账单',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
              ),
              Icon(Icons.chevron_right, size: 15, color: p.ink),
            ],
          ),
        ),
      ),
    );
  }
}

/// 空态：必须「不用滚动就能看到」。
///
/// 首页 hero + 预算卡已占满首屏（横屏/大屏尤其明显），因此这里走紧凑单行，
/// 而不是大图标居中块 —— 大块空态会被挤到折叠下方，用户只看到「本月账单」下一片空白。
class _EmptyMonth extends StatelessWidget {
  const _EmptyMonth({required this.year, required this.month});

  final int year;
  final int month;

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 6, 16, 16),
      child: Row(
        children: <Widget>[
          Icon(Icons.receipt_long_rounded, size: 22, color: p.ink),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '$year年$month月还没有记账',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '已有微信 / 支付宝账单？到「我的 → 导入账单」一键导入',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: p.ink2,
                  ),
                ),
              ],
            ),
          ),
          TextButton.icon(
            onPressed: () => context.push('/record'),
            icon: const Icon(Icons.add, size: 15),
            label: const Text('记一笔'),
            style: TextButton.styleFrom(
              foregroundColor: p.brandDeep,
              textStyle: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ],
      ),
    );
  }
}
