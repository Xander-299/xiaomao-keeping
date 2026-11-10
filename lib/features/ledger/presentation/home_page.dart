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
import 'package:yanxin/features/calendar/application/calendar_controller.dart';
import 'package:yanxin/features/ledger/presentation/tx_restore_message.dart';
import 'package:yanxin/features/reports/application/reports_controller.dart';
import 'package:yanxin/features/search/presentation/search_overlay.dart';
import 'package:yanxin/features/shared/write_failure.dart';
import 'package:yanxin/features/stats/application/stats_controller.dart';
import 'package:yanxin/ui_kit/app_page_state.dart';

import '../application/ledger_controller.dart';
import 'dashboard/dashboard_config.dart';
import 'dashboard/dashboard_config_controller.dart';
import 'dashboard/dashboard_module.dart';
import 'dashboard/dashboard_view.dart';
import 'widgets/tx_delete_dialog.dart';

/// 首页。
class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ledger = ref.watch(ledgerProvider);
    final bookAsync = ref.watch(currentBookProvider);
    final categoriesAsync = ref.watch(categoriesProvider);

    final nameOf = _categoryNameResolver(categoriesAsync.value);
    final DashboardConfig dashboardConfig =
        ref.watch(dashboardConfigProvider).value ?? DashboardConfig.defaults;

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
              loading: () => const AppPageLoading(),
              error: (Object e, StackTrace _) =>
                  AppPageError(error: e),
              data: (LedgerState state) => DashboardView(
                state: state,
                config: dashboardConfig,
                deps: DashboardDeps(
                  categoryNameOf: nameOf,
                  onEdit: (TxRow tx) =>
                      context.push('/record', extra: tx.id),
                  onDelete: (TxRow tx) =>
                      _confirmDelete(context, ref, tx),
                  onPrevMonth: () =>
                      ref.read(ledgerProvider.notifier).shiftMonth(-1),
                  onNextMonth: () =>
                      ref.read(ledgerProvider.notifier).shiftMonth(1),
                  params: dashboardConfig.params,
                ),
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
    final bool deleted;
    try {
      deleted = await ref.read(ledgerProvider.notifier).removeTx(tx.id);
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
    // P3：受影响行数 0 = 这行早被别的入口删掉了。此时既不报「已删除」，也不给撤销
    //（撤销会把用户其实没删的那笔恢复出来，语义是反的），只刷新 + 说实话。
    if (!deleted) {
      showToonFeedback(context, kTxAlreadyGoneMessage);
      return;
    }
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
