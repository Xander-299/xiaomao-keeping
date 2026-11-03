/// 自动记账的编排（F7.15 SPEC §3.1）。
///
/// 流程：drain 队列 → 解析（纯函数）→ 按 source 分组 → `ensureSourceAccount` →
/// **复用 `importRows()`**（每组一次事务，指纹唯一索引兜底）→ 记批次 → 刷新视图 → 回执通知。
///
/// 为什么入账要绕回 Dart：drift 是唯一 DB writer，Kotlin 侧只落盘（见 SPEC §3.1）。
/// 代价是「入账延迟到下次打开 App」—— 用户本来就要打开 App 才看得到提示条，几乎无感。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yanxin/core/utils/money.dart';
import 'package:yanxin/data/providers/book_providers.dart';
import 'package:yanxin/data/providers/database.dart';
import 'package:yanxin/features/autobook/application/auto_book_accounts.dart';
import 'package:yanxin/features/autobook/application/auto_book_notice.dart';
import 'package:yanxin/features/autobook/data/auto_book_batches.dart';
import 'package:yanxin/features/autobook/data/auto_book_bridge.dart';
import 'package:yanxin/features/autobook/data/auto_book_diagnostics.dart';
import 'package:yanxin/features/autobook/data/auto_book_rules.dart';
import 'package:yanxin/features/import/application/bill_importer.dart';
import 'package:yanxin/features/import/data/bill_normalize.dart' show ParsedRow;

/// 一次 drain 的结果（用于日志 / 测试断言；页面不直接消费）。
class AutoBookDrainResult {
  const AutoBookDrainResult({
    this.imported = 0,
    this.duplicates = 0,
    this.dropped = 0,
    this.undone = 0,
    this.restored = false,
    this.caughtUp = 0,
    this.batch,
  });

  /// 真正入账的笔数。
  final int imported;

  /// 指纹重复跳过的笔数。
  final int duplicates;

  /// 解析失败被丢弃的条数（坏数据 / 非消费通知）。
  final int dropped;

  /// 本次 drain 顺带执行的通知栏「撤销」笔数。
  final int undone;

  /// 本次因**临时性失败**（账本未就绪 / 写库异常）把队列回写了 —— 不是丢账，是等下次。
  final bool restored;

  /// 本次**补抓**（通知栏里仍存在、但服务未连接期间漏掉的通知）入队的条数。
  final int caughtUp;

  /// 本批（imported > 0 时非空）。
  final AutoBookBatch? batch;

  bool get touched => imported > 0 || undone > 0;
}

final autoBookControllerProvider = Provider<AutoBookController>(
  AutoBookController.new,
);

class AutoBookController {
  AutoBookController(this._ref);

  final Ref _ref;

  /// 防重入：首帧后与生命周期 resumed 可能几乎同时触发。
  bool _draining = false;

  /// 取队列 → 入账。**任何异常都被吞掉**（静默失败不得阻断冷启动）。
  Future<AutoBookDrainResult> drain() async {
    if (_draining) return const AutoBookDrainResult();
    _draining = true;
    try {
      return await _drain();
    } catch (_) {
      return const AutoBookDrainResult();
    } finally {
      _draining = false;
    }
  }

  Future<AutoBookDrainResult> _drain() async {
    final AutoBookBridge bridge = _ref.read(autoBookBridgeProvider);

    // A. 先处理通知栏「撤销」命令 —— 队列空也要处理（命令可能在冷启动前就落下）
    var undone = 0;
    final String? command = await bridge.takeCommand();
    if (command != null && command.isNotEmpty) {
      undone = await _handleCommand(command, bridge);
    }

    // B. 补抓 —— **必须在取队列之前**：通知在服务未连接期间发布时系统不会补发回调，
    //    所以要主动把通知栏里仍存在的通知捞回队列（真机事故：支付宝付款通知发布早于
    //    服务连接 1 分 51 秒 → 那笔支付永久丢失）。去重由原生侧持久指纹保证，
    //    重复补抓不会重复入队。
    //    顺带补一次守护排期：闹钟是「一次性 + 醒来续期」的，进程被杀后没人续期 →
    //    每次 drain 前补排，让「进程活着期间守护在转」成为不变量。
    await bridge.ensureGuardScheduled();
    final int caughtUp = await bridge.catchUp();

    // C. 取队列（原生侧是「取走即清空」，所以从这一行起原始数据只在内存里）
    final List<String> raw = await bridge.drainQueue();
    if (raw.isEmpty) {
      // 空队列 = 没有新通知，**不覆盖**「上次检查」：冷启动 / 从后台回来的例行 drain
      // 绝大多数是空的，若照写 `imported: 0`，就会把刚发生的「新入账 N 笔」抹成
      // 「没有新的支付通知」（真机走查实测：入账 7 秒后的空 drain 就把结果盖掉了）。
      // 撤销是**有效动作**，仍要记下来。
      if (undone > 0) {
        await _rememberLastRun(AutoBookLastRun(atMs: _nowMs, undone: undone));
      }
      return AutoBookDrainResult(undone: undone, caughtUp: caughtUp);
    }

    try {
      return await _process(raw, bridge: bridge, undone: undone, caughtUp: caughtUp);
    } catch (e) {
      // **临时性失败**（写库异常 / 处理中断）→ 把原始行放回队列，等下次重试。
      // 不做这一步，这批通知会随「取走即清空」永久消失 —— 这正是「只成功过一次」的典型成因。
      await _restoreQuietly(bridge, raw);
      await _rememberLastRun(
        AutoBookLastRun(
          atMs: _nowMs,
          undone: undone,
          restored: true,
          error: _shortError(e),
        ),
      );
      rethrow; // 由 drain() 的 catch 吞掉，不冒泡到 UI
    }
  }

  /// 解析 + 入账（队列内容已在内存；这里的失败分「永久」与「临时」两类）。
  Future<AutoBookDrainResult> _process(
    List<String> raw, {
    required AutoBookBridge bridge,
    required int undone,
    int caughtUp = 0,
  }) async {
    final AutoBookBatchStore store = _ref.read(autoBookBatchStoreProvider);

    final List<ParsedRow> rows = <ParsedRow>[];
    var dropped = 0;
    for (final String line in raw) {
      final ParsedRow? row = _parseLine(line);
      if (row == null) {
        dropped++;
      } else {
        rows.add(row);
      }
    }

    if (rows.isEmpty) {
      // 全部是坏数据 / 非消费通知 → **永久性失败**：丢弃是正确的（回写会无限重试）。
      // 清掉「识别到 N 笔」，别让通知一直挂着。
      await bridge.cancelReceipt();
      await _rememberLastRun(
        AutoBookLastRun(atMs: _nowMs, dropped: dropped, undone: undone),
      );
      return AutoBookDrainResult(dropped: dropped, undone: undone, caughtUp: caughtUp);
    }

    final String? bookId = await _ref.read(activeBookIdProvider.future);
    if (bookId == null) {
      // 账本还没就绪（冷启动首帧）→ **临时性失败**：回写等下次，不能丢。
      await _restoreQuietly(bridge, raw);
      await _rememberLastRun(
        AutoBookLastRun(
          atMs: _nowMs,
          dropped: dropped,
          undone: undone,
          restored: true,
          error: '账本未就绪',
        ),
      );
      return AutoBookDrainResult(
        dropped: dropped,
        undone: undone,
        restored: true,
        caughtUp: caughtUp,
      );
    }

    final BillCategoryMaps categoryMaps = await buildCategoryMaps(
      _ref.read(categoryRepositoryProvider),
      bookId,
    );
    final db = _ref.read(appDatabaseProvider);
    final accountRepo = _ref.read(accountRepositoryProvider);

    // 按 source 分组：每组一次事务，账户独立
    final Map<String, List<ParsedRow>> groups = <String, List<ParsedRow>>{};
    for (final ParsedRow r in rows) {
      groups.putIfAbsent(r.source, () => <ParsedRow>[]).add(r);
    }

    var imported = 0;
    var duplicates = 0;
    var amountCents = 0;
    final List<String> txIds = <String>[];
    final List<String> receiptLines = <String>[];

    for (final MapEntry<String, List<ParsedRow>> entry in groups.entries) {
      final String accountId = await ensureSourceAccount(
        accountRepo,
        bookId,
        entry.key,
      );
      final ImportReport report = await importRows(
        db,
        bookId: bookId,
        accountId: accountId,
        categoryMaps: categoryMaps,
        rows: entry.value,
      );
      imported += report.imported;
      duplicates += report.duplicates + report.fileDuplicates;
      amountCents += report.importedAmountCents;
      txIds.addAll(report.importedIds);
      if (report.imported > 0) {
        receiptLines.add(
          '${kSourceLabel[entry.key] ?? entry.key} ${report.imported} 笔',
        );
      }
    }

    if (imported == 0) {
      // 全是重复（同一通知被监听两次 / 队列残留）：不发回执，收起旧提示
      await bridge.cancelReceipt();
      await _rememberLastRun(
        AutoBookLastRun(
          atMs: _nowMs,
          duplicates: duplicates,
          dropped: dropped,
          undone: undone,
        ),
      );
      return AutoBookDrainResult(
        duplicates: duplicates,
        dropped: dropped,
        undone: undone,
        caughtUp: caughtUp,
      );
    }

    final AutoBookBatch batch = AutoBookBatch(
      batchId: 'b${DateTime.now().millisecondsSinceEpoch}',
      txIds: txIds,
      count: imported,
      totalCents: amountCents,
      atMs: DateTime.now().millisecondsSinceEpoch,
      bookId: bookId,
    );
    await store.remember(batch);
    _ref.read(autoBookNoticeProvider.notifier).show(batch);
    refreshAfterAutoBookWrite(_ref);
    await _rememberLastRun(
      AutoBookLastRun(
        atMs: _nowMs,
        imported: imported,
        duplicates: duplicates,
        dropped: dropped,
        undone: undone,
      ),
    );
    unawaited(
      bridge.showReceipt(
        count: imported,
        amountText: centsToYuan(amountCents),
        batchId: batch.batchId,
        lines: receiptLines,
      ),
    );

    return AutoBookDrainResult(
      imported: imported,
      duplicates: duplicates,
      dropped: dropped,
      undone: undone,
      caughtUp: caughtUp,
      batch: batch,
    );
  }

  /// 回写失败只能接受：指纹去重保证不会因此重复入账，而抛出去会盖掉原始异常。
  Future<void> _restoreQuietly(AutoBookBridge bridge, List<String> raw) async {
    try {
      await bridge.restoreQueue(raw);
    } catch (_) {
      // 忽略：诊断记录里已写明「已保留待下次重试」的意图
    }
  }

  /// 记下「最近一次检查」（跨启动可见），失败不影响记账。
  Future<void> _rememberLastRun(AutoBookLastRun run) async {
    try {
      await _ref
          .read(appMetaRepositoryProvider)
          .set(kAutoBookLastRunKey, jsonEncode(run.toJson()));
    } catch (_) {
      // 诊断写不进去不影响主流程
    }
  }

  int get _nowMs => DateTime.now().millisecondsSinceEpoch;

  String _shortError(Object e) {
    final String s = e.toString().replaceAll('\n', ' ');
    return s.length > 80 ? '${s.substring(0, 80)}…' : s;
  }

  /// 通知按钮落下的命令（`{"action":"undo","batchId":"..."}`）。
  Future<int> _handleCommand(String command, AutoBookBridge bridge) async {
    try {
      final Object? decoded = jsonDecode(command);
      if (decoded is! Map) return 0;
      final Map<String, Object?> map = decoded.cast<String, Object?>();
      if (map['action'] != kAutoBookActionUndo) return 0;
      final Object? batchId = map['batchId'];
      if (batchId is! String || batchId.isEmpty) return 0;
      final int deleted = await _ref
          .read(autoBookNoticeProvider.notifier)
          .undo(batchId);
      await bridge.cancelReceipt();
      return deleted;
    } catch (_) {
      return 0;
    }
  }

  /// 单行 JSONL → ParsedRow（通知或分享；坏行返回 null）。
  ParsedRow? _parseLine(String line) {
    final RawNotification? n = RawNotification.tryParse(line);
    if (n != null) return parseNotification(n);
    final RawShare? s = RawShare.tryParse(line);
    if (s != null) return parseSharedText(s);
    return null;
  }
}
