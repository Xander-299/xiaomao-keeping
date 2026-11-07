/// 自动记账的**批次记录**（F7.15 SPEC §3.6）—— 零迁移，落在既有 `schema_meta` KV 表。
///
/// 为什么需要它：通知栏「撤销」按钮可能在**冷启动**后点击（进程已被系统杀掉），
/// 那时会话内的提示条状态是空的 → 批次必须落库，且要用 `batchId` 精确定位。
///
/// 纪律：
/// - 只保留**最近 3 批**（超出按时间裁撤最旧的），防止 KV 值无限增长；
/// - 撤销成功后**立刻** `forget()`，否则同一批能被撤两次（第二次静默失败，用户困惑）；
/// - 该表只有 `key` / `value` 两列，值是 JSON 数组字符串，**不动 schema**。
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:yanxin/data/providers/database.dart';
import 'package:yanxin/data/repositories/app_meta_repository.dart';

/// KV 键名（与 `active_book_id` / `search_history` / `onboarding_done` 同表）。
const String kAutoBookBatchesKey = 'autobook_batches';

/// 保留的批次数上限。
const int kAutoBookBatchKeep = 3;

/// 单批自动记账结果。
class AutoBookBatch {
  const AutoBookBatch({
    required this.batchId,
    required this.txIds,
    required this.count,
    required this.totalCents,
    required this.atMs,
    this.bookId,
  });

  final String batchId;
  final List<String> txIds;
  final int count;
  final int totalCents;
  final int atMs;

  /// 这批流水所属账本。Batch A / A3 新增；旧版 JSON 没有该字段时为 null，
  /// 撤销时由 `TransactionRepository.bookIdOfTransactions` 反推。
  final String? bookId;

  Map<String, Object?> toJson() => <String, Object?>{
    'batchId': batchId,
    'txIds': txIds,
    'count': count,
    'totalCents': totalCents,
    'atMs': atMs,
    if (bookId != null) 'bookId': bookId,
  };

  /// 结构不对返回 null（坏数据不阻断读取）。
  static AutoBookBatch? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final Map<String, Object?> map = raw.cast<String, Object?>();
    final Object? id = map['batchId'];
    if (id is! String || id.isEmpty) return null;
    final List<String> txIds = <String>[
      if (map['txIds'] is List)
        for (final Object? t in map['txIds'] as List<Object?>)
          if (t is String && t.isNotEmpty) t,
    ];
    final Object? count = map['count'];
    final Object? total = map['totalCents'];
    final Object? at = map['atMs'];
    final Object? book = map['bookId'];
    return AutoBookBatch(
      batchId: id,
      txIds: txIds,
      count: count is num ? count.toInt() : txIds.length,
      totalCents: total is num ? total.toInt() : 0,
      atMs: at is num ? at.toInt() : 0,
      bookId: book is String && book.isNotEmpty ? book : null,
    );
  }
}

class AutoBookBatchStore {
  AutoBookBatchStore(this._meta);

  final AppMetaRepository _meta;

  /// 最近批次在前。
  Future<List<AutoBookBatch>> readAll() async {
    final String? raw = await _meta.get(kAutoBookBatchesKey);
    if (raw == null || raw.isEmpty) return const <AutoBookBatch>[];
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! List) return const <AutoBookBatch>[];
      final List<AutoBookBatch> out = <AutoBookBatch>[];
      for (final Object? e in decoded) {
        final AutoBookBatch? b = AutoBookBatch.tryFromJson(e);
        if (b != null) out.add(b);
      }
      return out;
    } catch (_) {
      return const <AutoBookBatch>[];
    }
  }

  Future<AutoBookBatch?> latest() async {
    final List<AutoBookBatch> all = await readAll();
    return all.isEmpty ? null : all.first;
  }

  Future<AutoBookBatch?> byId(String batchId) async {
    final List<AutoBookBatch> all = await readAll();
    for (final AutoBookBatch b in all) {
      if (b.batchId == batchId) return b;
    }
    return null;
  }

  /// 记一批（写在前，最多 [kAutoBookBatchKeep] 批）。
  Future<void> remember(AutoBookBatch batch) async {
    final List<AutoBookBatch> all = await readAll();
    final List<AutoBookBatch> next = <AutoBookBatch>[
      batch,
      for (final AutoBookBatch b in all)
        if (b.batchId != batch.batchId) b,
    ];
    await _write(
      next.length > kAutoBookBatchKeep
          ? next.sublist(0, kAutoBookBatchKeep)
          : next,
    );
  }

  /// 撤销成功后摘除该批次。
  Future<void> forget(String batchId) async {
    final List<AutoBookBatch> all = await readAll();
    await _write(
      <AutoBookBatch>[
        for (final AutoBookBatch b in all)
          if (b.batchId != batchId) b,
      ],
    );
  }

  Future<void> _write(List<AutoBookBatch> batches) {
    if (batches.isEmpty) return _meta.remove(kAutoBookBatchesKey);
    final String raw = jsonEncode(
      <Object?>[for (final AutoBookBatch b in batches) b.toJson()],
    );
    return _meta.set(kAutoBookBatchesKey, raw);
  }
}

final autoBookBatchStoreProvider = Provider<AutoBookBatchStore>(
  (Ref ref) => AutoBookBatchStore(ref.watch(appMetaRepositoryProvider)),
);
