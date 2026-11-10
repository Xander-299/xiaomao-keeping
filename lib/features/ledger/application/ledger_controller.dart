/// 首页流水状态：当前账本 + 当前月份 + 该月流水。
///
/// 对应旧栈 `stores/transaction.js`。切换账本时 build() 会自动重跑（watch 了
/// activeBookIdProvider）；翻月/删流水后走 [refresh]。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/database.dart';
import '../../../data/providers/book_providers.dart';
import '../../../data/providers/database.dart';
import '../../../data/repositories/transaction_repository.dart';
import 'month_summary.dart';

/// 首页状态快照。
class LedgerState {
  const LedgerState({
    required this.bookId,
    required this.year,
    required this.month,
    required this.items,
  });

  /// 当前账本 id。
  final String bookId;

  final int year;

  /// 1-12。
  final int month;

  /// 该月流水（发生时间倒序）。
  final List<TxRow> items;

  /// 月度汇总。
  MonthSummary get summary => summarize(items);
}

/// 是否能往后翻一个月（不能超过当前真实月份）。
bool canGoNext(int year, int month) {
  final now = DateTime.now();
  return year * 12 + month < now.year * 12 + now.month;
}

final ledgerProvider =
    AsyncNotifierProvider<LedgerController, LedgerState>(LedgerController.new);

class LedgerController extends AsyncNotifier<LedgerState> {
  @override
  Future<LedgerState> build() async {
    final bookId = await ref.watch(activeBookIdProvider.future);
    if (bookId == null) {
      throw StateError('当前账本未就绪');
    }
    final now = DateTime.now();
    return _load(bookId, now.year, now.month);
  }

  Future<LedgerState> _load(String bookId, int year, int month) async {
    final items = await ref
        .read(transactionRepositoryProvider)
        .listByMonth(bookId, year, month);
    return LedgerState(
      bookId: bookId,
      year: year,
      month: month,
      items: items,
    );
  }

  Future<void> _reload(String bookId, int year, int month) async {
    // **不切 loading**（2026-10-28 排查日历页「翻月生硬」时统一）：翻月 / 记完一笔后的
    // 刷新都走这里，切 loading 会让首页整屏闪转圈再瞬切。保留旧数据，新数据到了再替换。
    try {
      state = AsyncData<LedgerState>(await _load(bookId, year, month));
    } catch (e, st) {
      state = AsyncError<LedgerState>(e, st);
    }
  }

  /// 翻月：delta = -1 上一月，+1 下一月（调用方先判 [canGoNext]）。
  Future<void> shiftMonth(int delta) async {
    final current = state.value;
    if (current == null) return;
    var y = current.year;
    var m = current.month + delta;
    if (m < 1) {
      m = 12;
      y--;
    } else if (m > 12) {
      m = 1;
      y++;
    }
    await _reload(current.bookId, y, m);
  }

  /// 重新加载当前账本当前月。
  Future<void> refresh() async {
    final current = state.value;
    if (current == null) return;
    await _reload(current.bookId, current.year, current.month);
  }

  /// 直接切到指定年月（导入账单后跳到数据所在月用）。
  ///
  /// 与 [shiftMonth] 的区别：不依赖当前月份，也不受 [canGoNext] 限制，
  /// 因为导入的历史账单可能远早于当前月。
  Future<void> jumpToMonth(int year, int month) async {
    // state.value 可能为 null（首页 tab 还没构建过就先导入的场景）→ 退回到
    // future 等 build 完成，保证 jumpToMonth 在任何入口都成立。
    final current = state.value ?? await future;
    await _reload(current.bookId, year, month);
  }

  /// 软删除一笔并从列表移除（不物理删，DB 里 deleted_at 非空）。
  ///
  /// 返回**是否真的删掉了**（受影响行数 > 0）。P3：这行可能已被别的入口删过，
  /// 那时不能弹「已删除 + 撤销」，调用方据此改口为「这笔已经不在了」。
  Future<bool> removeTx(String id) async {
    final int changed = await ref
        .read(transactionRepositoryProvider)
        .softDelete(id);
    await refresh();
    return changed > 0;
  }

  /// 撤销软删：返回可识别的结果；只有恢复成功才刷新列表。
  Future<TxRestoreResult> restoreTx(String id) async {
    final TxRestoreResult result = await ref
        .read(transactionRepositoryProvider)
        .restoreTx(id);
    if (result.isRestored) await refresh();
    return result;
  }
}
