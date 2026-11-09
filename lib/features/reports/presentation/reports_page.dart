/// 报表页：当月流水按 **明细 / 分类 / 账户** 三档呈现。
///
/// 入口（SPEC-F7.7 §A.2.3，4 处占位全部点亮）：
/// - 首页 header「报表」→ 默认**分类**档
/// - 首页「全部账单 ›」/ 日历页 header「报表」/ 月份选择页 header「报表」→ 默认**明细**档
///   （日历与月份选择页还带上自己当前的年月）
///
/// 月份**独立**：报表页翻月不带走首页 / 日历 / 统计。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/core/theme/toon.dart';
import 'package:yanxin/core/utils/money.dart';
import 'package:yanxin/features/ledger/application/ledger_controller.dart';
import 'package:yanxin/ui_kit/app_page_state.dart';

import '../application/report_aggregate.dart';
import '../application/reports_controller.dart';
import 'widgets/report_group_list.dart';

/// 报表页。[args] 由路由 `extra` 传入（档位 / 年月，可空）。
class ReportsPage extends ConsumerStatefulWidget {
  const ReportsPage({super.key, this.args});

  final ReportsArgs? args;

  @override
  ConsumerState<ReportsPage> createState() => _ReportsPageState();
}

class _ReportsPageState extends ConsumerState<ReportsPage> {
  @override
  void initState() {
    super.initState();
    final ReportsArgs? args = widget.args;
    if (args != null && !args.isEmpty) {
      // `open` 在「与当前状态一致」时不动，所以重复进入不会白闪
      unawaited(ref.read(reportsProvider.notifier).open(args));
    }
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<ReportsState> async = ref.watch(reportsProvider);
    final ReportsState? state = async.value;

    return Scaffold(
      appBar: AppBar(
        title: const Text('报表'),
        actions: <Widget>[
          if (state != null) _MonthSwitcher(state: state),
          const SizedBox(width: 8),
        ],
      ),
      body: async.when(
        loading: () => const AppPageLoading(),
        error: (Object e, StackTrace _) => AppPageError(error: e),
        data: (ReportsState data) => Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Center(
                child: ToonSeg(
                  key: const ValueKey<String>('reports-tab-toggle'),
                  labels: kReportTabLabels,
                  index: reportTabIndex(data.tab),
                  onChanged: (int i) =>
                      ref.read(reportsProvider.notifier).setTab(kReportTabs[i]),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: data.items.isEmpty
                  ? const _EmptyMonth()
                  : _bodyOf(data),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bodyOf(ReportsState state) {
    if (state.tab == kReportTabCategory) return _CategoryTab(state: state);
    if (state.tab == kReportTabAccount) return _AccountTab(state: state);
    return ReportDayList(
      items: state.items,
      categoryNameOf: state.categoryNameOf,
    );
  }
}

/// AppBar 右侧的月份切换（‹ 2026年9月 ›），与统计页同样「不能翻到未来月」。
class _MonthSwitcher extends ConsumerWidget {
  const _MonthSwitcher({required this.state});

  final ReportsState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool canNext = canGoNext(state.year, state.month);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        ToonIconButton(
          icon: Icons.chevron_left_rounded,
          tooltip: '上一月',
          size: 36,
          iconSize: 20,
          onPressed: () => ref.read(reportsProvider.notifier).shiftMonth(-1),
        ),
        Text(
          '${state.year}年${state.month}月',
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
        ),
        ToonIconButton(
          icon: Icons.chevron_right_rounded,
          tooltip: '下一月',
          size: 36,
          iconSize: 20,
          // 禁用态用三级灰（与统计页一致）
          muted: !canNext,
          onPressed: canNext
              ? () => ref.read(reportsProvider.notifier).shiftMonth(1)
              : null,
        ),
      ],
    );
  }
}

/// 明细档 = 按天分组（见 [ReportDayList]）。
///
/// 分类档：支出 / 收入两段 + 转账单列一段；账户档：一行一个账户。
class _CategoryTab extends StatelessWidget {
  const _CategoryTab({required this.state});

  final ReportsState state;

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    final List<ReportGroup> expense = state.groupsOf(kReportExpense);
    final List<ReportGroup> income = state.groupsOf(kReportIncome);
    final List<TxRow> transfers = state.transfers;

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: <Widget>[
        ToonSectionTitle(
          title: '支出',
          trailing: Text(
            '¥${centsToYuan(state.summary.expenseCents, group: true)}',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w900,
              color: p.red,
            ),
          ),
        ),
        if (expense.isEmpty)
          const _SectionEmpty(text: '本月没有支出')
        else
          ReportGroupList(
            groups: expense,
            kind: ReportGroupKind.category,
            type: kReportExpense,
            sectionTotalCents: state.summary.expenseCents,
            categoryNameOf: state.categoryNameOf,
          ),
        ToonSectionTitle(
          title: '收入',
          trailing: Text(
            '¥${centsToYuan(state.summary.incomeCents, group: true)}',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w900,
              color: p.green,
            ),
          ),
        ),
        if (income.isEmpty)
          const _SectionEmpty(text: '本月没有收入')
        else
          ReportGroupList(
            groups: income,
            kind: ReportGroupKind.category,
            type: kReportIncome,
            sectionTotalCents: state.summary.incomeCents,
            categoryNameOf: state.categoryNameOf,
          ),
        if (transfers.isNotEmpty) ...<Widget>[
          ToonSectionTitle(
            title: '转账',
            trailing: Text(
              '${transfers.length} 笔 · '
              '¥${centsToYuan(sumCentsOf(transfers, kReportTransfer), group: true)}',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: p.ink2,
              ),
            ),
          ),
          ReportTxCard(
            items: transfers,
            categoryNameOf: state.categoryNameOf,
            neutral: true,
          ),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
          child: Text(
            '转账不计入支出 / 收入（与统计页口径一致）',
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

/// 账户档。
class _AccountTab extends StatelessWidget {
  const _AccountTab({required this.state});

  final ReportsState state;

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: <Widget>[
        ReportGroupList(
          groups: state.accountGroups,
          kind: ReportGroupKind.account,
          categoryNameOf: state.categoryNameOf,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
          child: Text(
            '按流水的 account_id 归集；已删除账户的历史流水归到「其他账户」',
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: p.ink2,
            ),
          ),
        ),
      ],
    );
  }
}

/// 段内空提示（整月有数据、但该方向没有）。
class _SectionEmpty extends StatelessWidget {
  const _SectionEmpty({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 2, 20, 14),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// 整月无流水：卡通空态（虚线圆 + 小猪 + 去记一笔）。
class _EmptyMonth extends StatelessWidget {
  const _EmptyMonth();

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 26),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ToonDashedBorder(
              circle: true,
              background: p.brandTint,
              child: SizedBox(
                width: 76,
                height: 76,
                child: Center(
                  child: Icon(
                    Icons.receipt_long_rounded,
                    size: 34,
                    color: p.brandInk,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 14),
            const Text(
              '这个月还没有记账',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            Text(
              '记一笔后这里会按明细 / 分类 / 账户分别列出',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: p.ink2,
              ),
            ),
            const SizedBox(height: 16),
            ToonButton(
              label: '去记一笔',
              icon: Icons.add,
              onPressed: () => context.push('/record'),
            ),
          ],
        ),
      ),
    );
  }
}
