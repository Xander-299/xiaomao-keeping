/// 导入编排 — 旧栈 `bill-import/importer.js` 的移植（去重 ADR-7）。
///
/// 流程（幂等铁律：同一文件重复导入必须零新增）：
///  1. 逐行分类 + 计算指纹
///  2. 文件内去重（内存集合，同文件重复行只保留首条）
///  3. 单事务内：
///     a. 指纹分批（500/批）`IN` 预查已入账的（drift 参数绑定，天然免疫注入，
///        旧栈 ADR-5 escapeLiteral 在新栈不再需要）
///     b. 逐条 importTransaction()：duplicate 计数不抛错；
///        其他异常 → 整体回滚，绝不留半截脏数据
///  4. dryRun=true：完整跑一遍事务后抛哨兵回滚，返回报告但不落库（预览页试算）
library;

import 'package:drift/drift.dart' hide isNull;

import '../../../core/db/database.dart';
import '../../../core/utils/fingerprint.dart';
import '../../../data/repositories/account_repository.dart';
import '../../../data/repositories/category_repository.dart';
import '../../../data/repositories/transaction_repository.dart';
import '../data/bill_normalize.dart';
import '../data/category_rules.dart';

const int _inChunk = 500;

/// dryRun 回滚哨兵。
class _DryRunRollback {
  const _DryRunRollback();
}

const _dryRunRollback = _DryRunRollback();

/// 导入报告。
class ImportReport {
  const ImportReport({
    required this.total,
    required this.imported,
    required this.duplicates,
    required this.fileDuplicates,
    required this.uncategorized,
    required this.unknownStatus,
    required this.cancelled,
    this.importedIds = const <String>[],
    this.importedAmountCents = 0,
  });

  final int total;
  final int imported;
  final int duplicates;
  final int fileDuplicates;

  /// 真正入库的流水 id（按入库顺序）。自动记账（F7.15）用它支撑「整批撤销」；
  /// 导入页不关心，默认空列表 —— **既有调用方零改动**。
  final List<String> importedIds;

  /// 真正入库的金额合计（分，**带方向前的绝对值之和**）。只服务于自动记账回执文案。
  final int importedAmountCents;

  /// 真正入库的行中，分类规则未命中（暂归「其他」）的条数。
  /// 只统计已入库行 —— 重复跳过的行与分类匹配无关，计入会让人误以为有新增。
  final int uncategorized;
  final int unknownStatus;
  final int cancelled;
}

/// 预览页的单条选项（可取消单条，与 rows 等长传入）。
class RowOption {
  const RowOption({this.cancelled = false});

  final bool cancelled;
}

/// 确保账本下存在「导入账户」（所有导入统一记到该账户），返回其 id。
Future<String> ensureImportAccount(
  AccountRepository accountRepo,
  String bookId,
) async {
  final accounts = await accountRepo.listByBook(bookId);
  for (final a in accounts) {
    if (a.name == '导入账户') return a.id;
  }
  final created = await accountRepo.create(
    bookId: bookId,
    name: '导入账户',
    type: 'other',
  );
  return created.id;
}

/// 分类名 -> id 映射（按账本的分类表；用户的自定义/改名分类同样生效）。
Future<({Map<String, String> expense, Map<String, String> income})>
buildCategoryMaps(CategoryRepository categoryRepo, String bookId) async {
  final cats = await categoryRepo.listByBook(bookId);
  final expense = <String, String>{};
  final income = <String, String>{};
  for (final c in cats) {
    if (c.kind == 'expense') {
      expense[c.name] = c.id;
    } else if (c.kind == 'income') {
      income[c.name] = c.id;
    }
  }
  return (expense: expense, income: income);
}

/// 分类映射（方向 -> 名称 -> id）。
typedef BillCategoryMaps = ({Map<String, String> expense, Map<String, String> income});

class _Prepared {
  _Prepared(this.row);

  final ParsedRow row;
  String categoryName = '';
  bool matched = false;
  String? categoryId;
  late final String fingerprint = computeFingerprint(
    source: row.source,
    externalId: row.externalId,
    amountCents: row.amountCents,
    occurredAt: row.occurredAt,
  );
}

/// 把一批 ParsedRow 导入 transactions。
///
/// [options]：预览页「取消单条」标记数组（与 rows 等长，可传 null）。
/// [dryRun]：试算模式，报告算完即回滚，库零变化。
Future<ImportReport> importRows(
  AppDatabase db, {
  required String bookId,
  required String accountId,
  required BillCategoryMaps categoryMaps,
  required List<ParsedRow> rows,
  List<RowOption>? options,
  bool dryRun = false,

  /// 按行解析账户名用（「小耄记账 CSV」自带 `账户` 列）。
  /// 传 null 时所有行仍落到 [accountId]（微信/支付宝的行为不变）。
  AccountRepository? accountRepo,
}) async {
  final txRepo = TransactionRepository(db);

  // 0. 预览页取消的单条不参与导入
  final active = <ParsedRow>[];
  var cancelled = 0;
  for (var i = 0; i < rows.length; i++) {
    final isCancelled =
        options != null && i < options.length && options[i].cancelled;
    if (isCancelled) {
      cancelled++;
    } else {
      active.add(rows[i]);
    }
  }

  // 1. 分类 + 指纹（Prepared 内联计算）
  final prepared = active.map(_Prepared.new).toList();
  var unknownStatusCount = 0;
  for (final p in prepared) {
    final map = p.row.direction == 'expense'
        ? categoryMaps.expense
        : categoryMaps.income;

    // ① 行内自带分类名（自己导出的 CSV）→ 按名字直取，**不再让规则猜**
    final String hint = p.row.categoryHint;
    if (hint.isNotEmpty && map.containsKey(hint)) {
      p.categoryName = hint;
      p.matched = true;
      p.categoryId = map[hint];
      continue;
    }

    // ② 平台账单：走关键词规则
    final cat = categorizeRow(p.row);
    p.categoryName = cat.categoryName;
    p.matched = cat.matched;
    p.categoryId = map[cat.categoryName];
    // 规则落「其他」但用户已删/改名「其他」时，兜底取该方向任一分类；
    // 完全无分类的账本无法入账（categoryId 为 null，入账时抛错回滚）
    if (p.categoryId == null) {
      const fallbackNames = ['其他', '其他支出', '未分类'];
      for (final n in fallbackNames) {
        if (map.containsKey(n)) {
          p.categoryId = map[n];
          break;
        }
      }
    }
    if (p.row.unknownStatus) unknownStatusCount++;
  }

  // 2. 文件内去重（指纹相同只保留首条）
  final fingerprints = <String>[];
  final fpSeen = <String>{};
  for (final p in prepared) {
    if (fpSeen.add(p.fingerprint)) {
      fingerprints.add(p.fingerprint);
    }
  }
  final fileDuplicates = prepared.length - fingerprints.length;

  // 3+4. 单事务：预查重 → 逐条入账 → 任何异常整体回滚
  ImportReport? report;
  try {
    await db.transaction(() async {
      final existing = <String>{};
      for (var start = 0; start < fingerprints.length; start += _inChunk) {
        final end = (start + _inChunk) < fingerprints.length
            ? start + _inChunk
            : fingerprints.length;
        final chunk = fingerprints.sublist(start, end);
        final placeholders = List.filled(chunk.length, '?').join(',');
        final q = db.customSelect(
          'SELECT fingerprint FROM transactions '
          'WHERE book_id = ? AND fingerprint IN ($placeholders) '
          'AND deleted_at IS NULL',
          variables: <Variable<Object>>[
            Variable.withString(bookId),
            for (final fp in chunk) Variable.withString(fp),
          ],
        );
        for (final r in await q.get()) {
          existing.add(r.read<String>('fingerprint'));
        }
      }

      // 精确去重：表里已有的流水 id（自有 CSV 带 `流水ID` 列）。
      // 指纹去重只覆盖「以前导入过的行」，而把导出文件导回**原账本**时，
      // 那些手工记账的行 fingerprint 是 null —— 只有 id 能认出它们。
      final Set<String> existingIds = <String>{};
      final List<String> idProbe = <String>[
        for (final _Prepared p in prepared)
          if (p.row.externalId.isNotEmpty) p.row.externalId,
      ];
      for (var start = 0; start < idProbe.length; start += _inChunk) {
        final int end = (start + _inChunk) < idProbe.length
            ? start + _inChunk
            : idProbe.length;
        final List<String> chunk = idProbe.sublist(start, end);
        final String marks = List.filled(chunk.length, '?').join(',');
        final q = db.customSelect(
          'SELECT id FROM transactions WHERE book_id = ? AND id IN ($marks)',
          variables: <Variable<Object>>[
            Variable.withString(bookId),
            for (final String id in chunk) Variable.withString(id),
          ],
        );
        for (final r in await q.get()) {
          existingIds.add(r.read<String>('id'));
        }
      }

      var imported = 0;
      var uncategorized = 0; // 只统计真正入库的未匹配行（重复跳过的与分类无关）
      var duplicates = existing.length; // 预查命中的直接计为重复
      final importedIds = <String>[];
      var importedAmountCents = 0;
      final Map<String, String> accountByName = <String, String>{};
      for (final p in prepared) {
        if (existing.contains(p.fingerprint)) continue;
        if (p.row.externalId.isNotEmpty &&
            existingIds.contains(p.row.externalId)) {
          duplicates++; // 这条已经在账本里（同一份导出反复导 / 导回原账本）
          continue;
        }

        // 自有 CSV 带 `账户` 列：按名字找，缺了就建（同一文件内缓存，避免重复建）
        String rowAccountId = accountId;
        final String accName = p.row.accountName;
        if (accountRepo != null && accName.isNotEmpty) {
          final String? cached = accountByName[accName];
          if (cached != null) {
            rowAccountId = cached;
          } else {
            String? found;
            for (final a in await accountRepo.listByBook(bookId)) {
              if (a.name == accName) {
                found = a.id;
                break;
              }
            }
            rowAccountId = found ??
                (await accountRepo.create(
                  bookId: bookId,
                  name: accName,
                  type: 'other',
                ))
                    .id;
            accountByName[accName] = rowAccountId;
          }
        }

        final res = await txRepo.importTransaction(
          bookId: bookId,
          accountId: rowAccountId,
          categoryId: p.categoryId,
          type: p.row.direction,
          amountCents: p.row.amountCents,
          occurredAt: p.row.occurredAt,
          note: p.row.note.isNotEmpty
              ? p.row.note
              : [p.row.counterparty, p.row.product]
                    .where((s) => s.isNotEmpty)
                    .join(' · '),
          source: p.row.source,
          externalId: p.row.externalId,
        );
        switch (res) {
          case ImportOk(tx: final tx):
            imported++;
            importedIds.add(tx.id);
            importedAmountCents += p.row.amountCents;
            if (!p.matched) uncategorized++;
          case ImportDuplicate():
            duplicates++; // 并发/边界下唯一索引兜底，同样不算错误
        }
      }

      report = ImportReport(
        total: rows.length,
        imported: imported,
        duplicates: duplicates,
        fileDuplicates: fileDuplicates,
        uncategorized: uncategorized,
        unknownStatus: unknownStatusCount,
        cancelled: cancelled,
        importedIds: importedIds,
        importedAmountCents: importedAmountCents,
      );
      if (dryRun) throw _dryRunRollback;
    });
  } on _DryRunRollback {
    // dryRun 预期回滚
  }

  return report!;
}
