/// 首页：账本 header + hero 月支出卡 + 预算占位卡 + 本月账单列表。
///
/// 视觉对齐 docs/design/home_ui.jpg；对应旧栈 `pages/index/index.vue`。
/// 页面本身无 Scaffold（壳路由 AppShell 提供抽屉与底栏）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/core/providers/data_epoch.dart';
import 'package:yanxin/core/theme/toon.dart';
import 'package:yanxin/core/utils/money.dart';
import 'package:yanxin/data/providers/book_providers.dart';
import 'package:yanxin/data/providers/category_providers.dart';
import 'package:yanxin/data/repositories/transaction_repository.dart';
import 'package:yanxin/features/autobook/presentation/widgets/auto_book_banner.dart';
import 'package:yanxin/features/calendar/application/calendar_controller.dart';
import 'package:yanxin/features/chat/presentation/widgets/chat_entry_card.dart';
import 'package:yanxin/features/ledger/presentation/tx_restore_message.dart';
import 'package:yanxin/features/reports/application/reports_controller.dart';
import 'package:yanxin/features/search/presentation/search_overlay.dart';
import 'package:yanxin/features/shared/write_failure.dart';
import 'package:yanxin/features/stats/application/stats_controller.dart';

import '../application/ledger_controller.dart';
import 'widgets/budget_strip.dart';
import 'widgets/month_hero.dart';
import 'widgets/tx_delete_dialog.dart';
import 'widgets/tx_group_list.dart';

/// 首页竖向节奏（dp）—— 改首屏呼吸感只动这三个数，别在子组件里各写一份 margin。
///
/// hero 卡片带 4px 硬阴影，会在视觉上吃掉半格缝，所以「hero ↔ 预算条」给到 24（实测视觉缝 ≈17dp）。
const double kHomeGapHeroToStrip = 24;
const double kHomeGapStripToEntry = 20;
const double kHomeGapEntryToSection = 20;

/// 首页。
class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ledger = ref.watch(ledgerProvider);
    final bookAsync = ref.watch(currentBookProvider);
    final categoriesAsync = ref.watch(categoriesProvider);

    final nameOf = _categoryNameResolver(categoriesAsync.value);

    return SafeArea(
      bottom: false,
      child: Column(
        children: <Widget>[
          _Header(bookName: bookAsync.value?.name ?? '…'),
          Expanded(
            child: ledger.when(
              // 翻月 / 写后刷新不再切 loading（controller 侧已改），这里再加一道保险：
              // 即使状态短暂回到 loading，也继续画旧数据，不闪转圈。
              skipLoadingOnReload: true,
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (Object e, StackTrace _) =>
                  Center(child: Text('加载失败：$e')),
              data: (LedgerState state) => CustomScrollView(
                slivers: <Widget>[
                  // 自动记账提示条（F7.15）：无待提示批次时零高度，不占位
                  const SliverToBoxAdapter(child: AutoBookBanner()),
                  SliverToBoxAdapter(
                    child: MonthHero(
                      year: state.year,
                      month: state.month,
                      summary: state.summary,
                      canNext: canGoNext(state.year, state.month),
                      onPrevMonth: () =>
                          ref.read(ledgerProvider.notifier).shiftMonth(-1),
                      onNextMonth: () =>
                          ref.read(ledgerProvider.notifier).shiftMonth(1),
                    ),
                  ),
                  // 预算降级成一行（腾出首屏给「记一笔 / 问一句」入口；2026-10-28 改版）
                  // 竖向节奏：hero →(24) 预算条 →(20) 入口卡 →(20) 本月账单
                  const SliverToBoxAdapter(child: SizedBox(height: kHomeGapHeroToStrip)),
                  const SliverToBoxAdapter(child: BudgetStrip()),
                  const SliverToBoxAdapter(child: SizedBox(height: kHomeGapStripToEntry)),
                  const SliverToBoxAdapter(child: ChatEntryCard()),
                  const SliverToBoxAdapter(child: SizedBox(height: kHomeGapEntryToSection)),
                  const SliverToBoxAdapter(child: _SectionHeader()),
                  if (state.items.isEmpty)
                    SliverToBoxAdapter(
                      child: _EmptyMonth(
                        year: state.year,
                        month: state.month,
                      ),
                    )
                  else
                    SliverToBoxAdapter(
                      child: TxGroupList(
                        items: state.items,
                        categoryNameOf: nameOf,
                        shrinkWrap: true,
                        onEdit: (TxRow tx) =>
                            context.push('/record', extra: tx.id),
                        onDelete: (TxRow tx) => _confirmDelete(context, ref, tx),
                      ),
                    ),
                  const SliverToBoxAdapter(child: SizedBox(height: 24)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String Function(String?) _categoryNameResolver(List<Category>? categories) {
    if (categories == null) {
      return (String? _) => '未分类';
    }
    final map = <String, String>{
      for (final c in categories) c.id: c.name,
    };
    return (String? id) => (id == null ? null : map[id]) ?? '未分类';
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    TxRow tx,
  ) async {
    if (!await confirmDeleteTx(context)) return;
    try {
      await ref.read(ledgerProvider.notifier).removeTx(tx.id);
    } catch (e) {
      // 数据库锁 / 磁盘 / Drift 等异常：不弹 Undo，让用户知道删除没成功。
      if (context.mounted) {
        showToonError(context, writeFailureMessage(e, action: '删除'));
      }
      return;
    }
    ref.invalidate(yearDayIndexProvider);
    // 日历是同月数据的另一视图，保持一致
    unawaited(ref.read(calendarProvider.notifier).refresh());
    // 统计页同理（常驻 Notifier，不会自己感知删除）
    unawaited(ref.read(statsProvider.notifier).refresh());
    // 资产页 watch 数据版本号，bump 即重算
    ref.read(dataEpochProvider.notifier).bump();
    if (!context.mounted) return;
    final String label = tx.note.isNotEmpty
        ? tx.note
        : '${centsToYuan(tx.amountCents, group: true)} 元';
    showToonUndo(
      context,
      '已删除「$label」',
      onUndo: () async {
        final TxRestoreResult result;
        try {
          result = await ref.read(ledgerProvider.notifier).restoreTx(tx.id);
        } catch (e) {
          if (context.mounted) {
            showToonError(context, writeFailureMessage(e, action: '撤销'));
          }
          return;
        }
        if (result.isRestored) {
          ref.invalidate(yearDayIndexProvider);
          unawaited(ref.read(calendarProvider.notifier).refresh());
          unawaited(ref.read(statsProvider.notifier).refresh());
          ref.read(dataEpochProvider.notifier).bump();
        } else if (context.mounted) {
          showToonError(context, txRestoreFailureMessage(result));
        }
      },
    );
  }
}

/// 顶部栏：左侧账本名（点开抽屉）+ 右侧搜索 / 报表（占位）/ 统计。
class _Header extends StatelessWidget {
  const _Header({required this.bookName});

  final String bookName;

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 8, 2),
      child: Row(
        children: <Widget>[
          Expanded(
            child: ToonPress(
              dx: 0,
              dy: 0,
              onTap: Scaffold.maybeOf(context)?.openDrawer,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Flexible(
                    child: Text(
                      bookName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.4,
                        color: p.ink,
                      ),
                    ),
                  ),
                  Icon(Icons.expand_more, size: 24, color: p.ink),
                ],
              ),
            ),
          ),
          ToonIconButton(
            icon: Icons.search_rounded,
            tooltip: '搜索',
            boxed: true,
            // F7.5：不再是独立路由，改为覆盖在首页之上的浮层（首页留在底下当背景）
            onPressed: () => unawaited(showSearchOverlay(context)),
          ),
          ToonIconButton(
            icon: Icons.receipt_long_rounded,
            tooltip: '报表',
            boxed: true,
            // 首页 header 的「报表」默认落在「分类」档（SPEC-F7.7 §A.2.3）
            onPressed: () => context.push(
              '/reports',
              extra: const ReportsArgs(tab: kReportTabCategory),
            ),
          ),
          ToonIconButton(
            icon: Icons.bar_chart_rounded,
            tooltip: '统计',
            boxed: true,
            onPressed: () => context.push('/stats'),
          ),
        ],
      ),
    );
  }
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
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
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
              textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
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
