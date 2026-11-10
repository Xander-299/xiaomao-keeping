/// 「小耄记账备份」（`buildBackupJson` 产物）的识别与恢复。
///
/// 解决换机迁移闭环：旧手机导出 JSON → 新手机「导入账单」直接选中 →
/// 账本 / 账户 / 分类 / 流水 / 预算整体恢复，重复导入幂等（指纹去重）。
///
/// 与 CSV/微信/支付宝路径的区别：备份文件**自带分类与账户**，不走过，
/// 金额方向直接取 `type` 字段，指纹优先用导出时的原值（保持与旧库一致）。
library;

import 'dart:convert';

import 'package:drift/drift.dart' hide isNull;

import '../../../core/db/database.dart';
import '../../../core/utils/fingerprint.dart';
import '../../../data/repositories/account_repository.dart';
import '../../../data/repositories/app_meta_repository.dart';
import '../../../data/repositories/book_repository.dart';
import '../../../data/repositories/budget_repository.dart';
import '../../../data/repositories/category_repository.dart';
import '../../../data/repositories/transaction_repository.dart';
import 'backup_settings.dart';

/// 备份文件的 schema 版本标记（与 `csv_export.dart` 的 `kBackupSchemaVersion` 对应）。
const String kBackupSourceTag = '小耄记账备份';

/// 恢复报告。
class BackupRestoreReport {
  BackupRestoreReport({
    required this.dataRows,
    this.imported = 0,
    this.duplicates = 0,
    List<String> importedIds = const <String>[],
    this.importedAmountCents = 0,
    this.bookName,
    this.createdBook = false,
    this.createdAccounts = 0,
    this.createdCategories = 0,
    this.budgetsRestored = 0,
    this.settingsRestored = 0,
  });

  final int dataRows;
  int imported;
  int duplicates;
  late final List<String> importedIds = const <String>[];
  int importedAmountCents = 0;

  /// 恢复到哪个账本（新建时为备份里的账本名）。
  final String? bookName;

  /// 是否新建了账本（false = 恢复进当前账本）。
  bool createdBook;
  int createdAccounts;
  int createdCategories;
  int budgetsRestored;

  /// 随备份恢复的外观 / 布局设置项数（0 = 备份里没有这段，或用户选择不恢复）。
  int settingsRestored;

  /// 落库数据的最新月份（供导入页的「跳转到该月」入口）。
  ({int year, int month})? latestMonth;
}

/// 快速嗅探：这段字节是不是小耄记账备份 JSON（UTF-8）。
///
/// 只看前 2 KB 里有没有 `"schemaVersion"` + `"transactions"` 的组合，
/// 避免完整 JSON 解码的开销；微信/支付宝 CSV 不可能同时含这两个键。
bool looksLikeBackupJson(List<int> bytes) {
  final int n = bytes.length < 2048 ? bytes.length : 2048;
  final String head = utf8.decode(bytes.sublist(0, n), allowMalformed: true);
  return head.contains('"schemaVersion"') && head.contains('"transactions"');
}

/// 备份里是否带 `settings` 段（决定导入页要不要问「一并恢复外观与布局」）。
///
/// 单独一个函数而不是让调用方自己解一遍 JSON：解析口径只此一处，坏文件一律 false。
bool backupHasSettings(List<int> bytes) {
  try {
    final Object? decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map) return false;
    final Object? settings = (decoded as Map<Object?, Object?>)['settings'];
    return settings is Map && settings.isNotEmpty;
  } catch (_) {
    return false;
  }
}

/// 备份 JSON → 恢复报告。解析失败抛 [FormatException]（文案可直接展示）。
Future<BackupRestoreReport> restoreBackupJson(
  AppDatabase db, {
  required List<int> bytes,

  /// 为 null = 恢复进当前账本；否则按备份里的账本名新建账本。
  required bool createBook,

  /// 是否一并恢复备份里的外观 / 布局设置（默认 true；备份没有 `settings` 段时无副作用）。
  bool restoreSettings = true,
}) async {
  final Map<String, Object?> payload;
  try {
    payload = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
  } on FormatException {
    throw const FormatException('备份文件不是有效的 JSON。');
  }
  if (!payload.containsKey('transactions')) {
    throw const FormatException('备份文件缺少 transactions 数据。');
  }
  final Object? bookJson = payload['book'];
  if (bookJson is! Map) {
    throw const FormatException('备份文件缺少 book 信息。');
  }
  final String backupBookName = (bookJson['name'] as String?)?.trim() ?? '';
  final List<Object?> rawTxs = payload['transactions'] as List<Object?>? ?? [];
  final List<Object?> rawAccounts = payload['accounts'] as List<Object?>? ?? [];
  final List<Object?> rawCategories =
      payload['categories'] as List<Object?>? ?? [];
  final List<Object?> rawBudgets = payload['budgets'] as List<Object?>? ?? [];

  final bookRepo = BookRepository(db);
  final accountRepo = AccountRepository(db);
  final categoryRepo = CategoryRepository(db);
  final txRepo = TransactionRepository(db);

  // ── 账本：新建或复用当前 ──
  final Book book;
  bool createdBook;
  if (createBook) {
    final String name = backupBookName.isEmpty
        ? '恢复的账本'
        : backupBookName;
    // 同名账本已存在则直接复用（重复导入幂等）
    Book? existing;
    for (final Book b in await bookRepo.listAll()) {
      if (b.name == name) existing = b;
    }
    if (existing != null) {
      book = existing;
      createdBook = false;
    } else {
      book = await bookRepo.create(name: name);
      createdBook = true;
    }
  } else {
    final Book current = await bookRepo.ensureDefaultBook();
    book = current;
    createdBook = false;
  }
  final String bookId = book.id;

  // ── 账户：按名匹配（幂等），缺失则创建 ──
  final Map<String, String> accountIdByName = <String, String>{};
  var createdAccounts = 0;
  for (final Account a in await accountRepo.listByBook(bookId)) {
    accountIdByName[a.name] = a.id;
  }
  final Map<String, String> backupAccountIdById = <String, String>{};
  for (final Object? raw in rawAccounts) {
    if (raw is! Map) continue;
    final String id = raw['id']?.toString() ?? '';
    final String name = (raw['name']?.toString() ?? '').trim();
    if (name.isEmpty) continue;
    String? accountId = accountIdByName[name];
    if (accountId == null) {
      final int initial = _asInt(raw['initialBalanceCents']);
      final created = await accountRepo.create(
        bookId: bookId,
        name: name,
        type: raw['type']?.toString().isNotEmpty == true
            ? raw['type'].toString()
            : 'other',
        initialBalanceCents: initial,
        id: null,
      );
      accountId = created.id;
      accountIdByName[name] = accountId;
      createdAccounts++;
    }
    if (id.isNotEmpty) backupAccountIdById[id] = accountId;
  }
  if (backupAccountIdById.isEmpty && accountIdByName.isNotEmpty) {
    // 备份无账户数据时兜底：全部记到第一个账户
    backupAccountIdById[''] = accountIdByName.values.first;
  }

  // ── 分类：按 (kind, name) 匹配（幂等），缺失则创建 ──
  final Map<String, String> categoryIdByKindName = <String, String>{};
  var createdCategories = 0;
  for (final Category c in await categoryRepo.listByBook(bookId)) {
    categoryIdByKindName['${c.kind}|${c.name}'] = c.id;
  }
  final Map<String, String> backupCategoryIdById = <String, String>{};
  for (final Object? raw in rawCategories) {
    if (raw is! Map) continue;
    final String id = raw['id']?.toString() ?? '';
    final String kind = raw['kind']?.toString() ?? 'expense';
    final String name = (raw['name']?.toString() ?? '').trim();
    if (name.isEmpty) continue;
    final String key = '$kind|$name';
    String? categoryId = categoryIdByKindName[key];
    if (categoryId == null) {
      final String? parentId = raw['parentId']?.toString();
      String? resolvedParent;
      if (parentId != null && parentId.isNotEmpty) {
        resolvedParent = backupCategoryIdById[parentId];
      }
      final created = await categoryRepo.create(
        bookId: bookId,
        name: name,
        kind: kind,
        parentId: resolvedParent,
        icon: raw['icon']?.toString() ?? '',
        color: raw['color']?.toString() ?? '',
        isPreset: raw['isPreset'] == true,
      );
      categoryId = created.id;
      categoryIdByKindName[key] = categoryId;
      createdCategories++;
    }
    if (id.isNotEmpty) backupCategoryIdById[id] = categoryId;
  }

  // ── 流水：单事务，指纹去重（原值优先）──
  final report = BackupRestoreReport(
    dataRows: rawTxs.length,
    imported: 0,
    duplicates: 0,
    bookName: book.name,
    createdBook: createdBook,
    createdAccounts: createdAccounts,
    createdCategories: createdCategories,
  );
  int? latestMs;

  await db.transaction(() async {
    for (final Object? raw in rawTxs) {
      if (raw is! Map) continue;
      final String type = raw['type']?.toString() ?? '';
      if (type != 'expense' && type != 'income' && type != 'transfer') {
        continue; // 脏行跳过，不让一条坏数据毁掉整份备份
      }
      final int amountCents = _asInt(raw['amountCents']);
      final int occurredAt = _asInt(raw['occurredAt']);
      if (amountCents <= 0 || occurredAt <= 0) continue;

      final String backupAccountId = raw['accountId']?.toString() ?? '';
      final String? accountId =
          backupAccountIdById[backupAccountId] ??
          backupAccountIdById[''] ??
          (accountIdByName.values.isNotEmpty
              ? accountIdByName.values.first
              : null);
      if (accountId == null) continue;

      final String? backupCategoryId = raw['categoryId']?.toString();
      final String? categoryId = backupCategoryId == null
          ? null
          : backupCategoryIdById[backupCategoryId];

      final String source = raw['source']?.toString() ?? 'manual';
      final String fingerprint = raw['fingerprint']?.toString() ?? '';

      // 指纹去重：原指纹（跨机一致）优先；缺失时按相同算法现算
      final String fp = fingerprint.isNotEmpty
          ? fingerprint
          : computeFingerprint(
              source: source,
              externalId: raw['externalId']?.toString(),
              amountCents: amountCents,
              occurredAt: occurredAt,
            );
      final existing = await (_dbSelect(db, bookId, fp));
      if (existing != null) {
        report.duplicates++;
        continue;
      }

      await txRepo.create(
        bookId: bookId,
        accountId: accountId,
        type: type,
        amountCents: amountCents,
        occurredAt: occurredAt,
        categoryId: categoryId,
        note: raw['note']?.toString() ?? '',
        source: source,
        fingerprint: fp,
        transferGroupId: raw['transferGroupId']?.toString(),
        ownerId: raw['ownerId']?.toString(),
      );
      report.imported++;
      if (latestMs == null || occurredAt > latestMs!) latestMs = occurredAt;
    }
  });

  // ── 预算：幂等 upsert（走仓储，跟手动设置同一套校验）──
  for (final Object? raw in rawBudgets) {
    if (raw is! Map) continue;
    final int amount = _asInt(raw['amountCents']);
    final String period = raw['period']?.toString() ?? '';
    final RegExp periodRe = RegExp(r'^(\d{4})-(\d{2})$');
    final Match? m = periodRe.firstMatch(period);
    if (amount <= 0 || m == null) continue;
    try {
      await BudgetRepository(db).setForMonth(
        bookId: bookId,
        year: int.parse(m.group(1)!),
        month: int.parse(m.group(2)!),
        amountCents: amount,
      );
      report.budgetsRestored++;
    } on Object {
      // 预算失败不阻断流水恢复
    }
  }

  // ── 设置（P5-A）：白名单内的外观 / 布局原值写回本机 ──
  //
  // 放在最后：账本数据恢复失败时不该顺手改掉用户的外观。写失败也不打断恢复流程
  // （`applyBackupSettings` 内部逐键 try）。
  if (restoreSettings) {
    report.settingsRestored = await applyBackupSettings(
      AppMetaRepository(db),
      payload['settings'],
    );
  }

  if (latestMs != null) {
    final DateTime d = DateTime.fromMillisecondsSinceEpoch(latestMs!);
    report.latestMonth = (year: d.year, month: d.month);
  }
  return report;
}

int _asInt(Object? v) => v is int ? v : int.tryParse(v?.toString() ?? '') ?? 0;

// drift 查询的小包装，避免上面主流程太噪
Future<TxRow?> _dbSelect(AppDatabase db, String bookId, String fp) {
  return (db.select(db.transactions)
        ..where(
          (t) =>
              t.bookId.equals(bookId) & t.fingerprint.equals(fp) &
              t.deletedAt.isNull(),
        ))
      .getSingleOrNull();
}
