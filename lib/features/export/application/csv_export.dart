/// 数据导出纯函数（`F7.7 B 批`，见 `docs/spec/SPEC-F7.7-backlog.md` §B）。
///
/// 只负责「把已经读出来的行变成一段文本 / 一个文件名」——
/// **不碰数据库、不碰文件系统**，所以全部可单测（`test/features/export/csv_export_test.dart`）。
/// 落盘由 `presentation/export_sheet.dart` 通过 `FilePicker.saveFile` 完成。
///
/// 口径（用户 2026-09-23 签字确认，SPEC §B.4）：
/// - CSV 金额：**元、两位小数、无符号**，方向由「类型」列表达；
/// - 来源列：`transactions.source` **原样英文**，不做中文映射；
/// - 备份 JSON 金额：**整数分**（与库一致，可无损还原）；
/// - 只导出**未软删**行（调用方用 `listByBook` 取数，天然已过滤）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/core/utils/money.dart';

/// CSV 表头（`SPEC` §B.1 固定顺序，勿随意调整）。
/// 表头。`流水ID` 是 2026-11-13 追加的**最后一列**：
/// 导入时用它做「这条已经在了」的精确判据（同一份文件反复导、或把导出文件导回原账本都不会翻倍）。
/// 老文件没有这一列照样能导（退化为按指纹去重）。
const String kBillCsvHeader = '日期,类型,金额,分类,账户,备注,来源,流水ID';

/// UTF-8 BOM：Excel 双击打开中文 CSV 不乱码的关键（`SPEC` §B.1）。
const String kUtf8Bom = '\uFEFF';

/// 备份 JSON 的 schema 版本，与 drift `AppDatabase.schemaVersion` 对齐。
const int kBackupSchemaVersion = 2;

/// 导出文件的统一前缀。
const String kExportFilePrefix = '小耄记账';

/// 类型内部值 → 中文。未知值原样输出（便于发现脏数据，不静默吞掉）。
String billTypeLabel(String type) => switch (type) {
  'expense' => '支出',
  'income' => '收入',
  'transfer' => '转账',
  _ => type,
};

/// 发生时间（毫秒）→ `YYYY-MM-DD HH:mm`（**本地时区**，与用户看到的一致）。
String formatCsvDateTime(int occurredAtMs) {
  final DateTime d = DateTime.fromMillisecondsSinceEpoch(occurredAtMs);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} '
      '${two(d.hour)}:${two(d.minute)}';
}

/// 毫秒 → 带时区偏移的 ISO8601（如 `2026-09-23T16:30:00+08:00`）。
///
/// 备份文件可能被搬到别的时区打开，所以 `exportedAt` 显式带偏移，不留歧义。
String formatIsoWithOffset(int ms) {
  final DateTime d = DateTime.fromMillisecondsSinceEpoch(ms);
  final Duration off = d.timeZoneOffset;
  final String sign = off.isNegative ? '-' : '+';
  final int hours = off.inHours.abs();
  final int minutes = off.inMinutes.abs() % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)}T'
      '${two(d.hour)}:${two(d.minute)}:${two(d.second)}'
      '$sign${two(hours)}:${two(minutes)}';
}

/// RFC4180 字段转义：含 `,` / `"` / CR / LF 时整体加引号，内部 `"` 翻倍。
String csvField(String raw) {
  final bool needQuote =
      raw.contains(',') ||
      raw.contains('"') ||
      raw.contains('\r') ||
      raw.contains('\n');
  if (!needQuote) return raw;
  return '"${raw.replaceAll('"', '""')}"';
}

/// 导出文件名：`小耄记账_{账本名}_{YYYYMMDD}.{ext}`。
///
/// 账本名允许任意字符，而文件名不许 —— 把 Windows / SAF 都敏感的
/// `/ \ : * ? " < > |` 与控制字符统一换成 `_`；空名或全被替换时退回「账本」。
String exportFileName({
  required String bookName,
  required String ext,
  required int nowMs,
}) {
  final String safe = bookName
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_')
      .trim();
  final String base = safe.isEmpty ? '账本' : safe;
  final DateTime d = DateTime.fromMillisecondsSinceEpoch(nowMs);
  final String stamp =
      '${d.year}${d.month.toString().padLeft(2, '0')}'
      '${d.day.toString().padLeft(2, '0')}';
  return '${kExportFilePrefix}_${base}_$stamp.$ext';
}

/// 「当前账本 · 全时间」流水 CSV 文本（含 BOM，行尾 `\r\n`，**末行不带换行**）。
///
/// - 分类：`categoryId` 为空或查不到名字 → 空串（不写「未分类」，导出件留白更中性）；
/// - 账户：查不到名字 → 空串；
/// - 空账本（0 笔）→ 只有表头（`SPEC` §B.4.6）。
String buildBillCsv({
  required List<TxRow> rows,
  Map<String, String> categoryNames = const <String, String>{},
  Map<String, String> accountNames = const <String, String>{},
}) {
  final StringBuffer buf = StringBuffer()
    ..write(kUtf8Bom)
    ..write(kBillCsvHeader);
  for (final TxRow r in rows) {
    buf
      ..write('\r\n')
      ..write(csvField(formatCsvDateTime(r.occurredAt)))
      ..write(',')
      ..write(csvField(billTypeLabel(r.type)))
      ..write(',')
      ..write(csvField(centsToYuan(r.amountCents.abs())))
      ..write(',')
      ..write(csvField(_nameOf(categoryNames, r.categoryId)))
      ..write(',')
      ..write(csvField(_nameOf(accountNames, r.accountId)))
      ..write(',')
      ..write(csvField(r.note))
      ..write(',')
      ..write(csvField(r.source))
      ..write(',')
      ..write(csvField(r.id));
  }
  return buf.toString();
}

String _nameOf(Map<String, String> names, String? id) =>
    id == null ? '' : (names[id] ?? '');

/// 备份 JSON（当前账本全量：账本 / 账户 / 分类 / 流水 / 预算 + 可选的外观与布局设置）。
///
/// 金额一律**整数分**；`dirty`（本地同步标记）不导出 —— 它不是用户数据。
/// [settings] 是白名单内的 `schema_meta` 原值（见 `backup_settings.dart`），
/// 空 / null 时不写这个键 —— 老备份本来就该长得跟以前一样。
/// 传 `exportedAtMs` 而不是内部取 `now()`，便于单测固定输出。
String buildBackupJson({
  required Book book,
  required List<Account> accounts,
  required List<Category> categories,
  required List<TxRow> transactions,
  required List<BudgetRow> budgets,
  required int exportedAtMs,
  Map<String, Object?>? settings,
}) {
  final Map<String, Object?> payload = <String, Object?>{
    'schemaVersion': kBackupSchemaVersion,
    'exportedAt': formatIsoWithOffset(exportedAtMs),
    'book': _bookJson(book),
    'accounts': <Map<String, Object?>>[for (final Account a in accounts) _accountJson(a)],
    'categories': <Map<String, Object?>>[
      for (final Category c in categories) _categoryJson(c),
    ],
    'transactions': <Map<String, Object?>>[
      for (final TxRow t in transactions) _txJson(t),
    ],
    'budgets': <Map<String, Object?>>[for (final BudgetRow b in budgets) _budgetJson(b)],
    if (settings != null && settings.isNotEmpty) 'settings': settings,
  };
  return const JsonEncoder.withIndent('  ').convert(payload);
}

/// 文本 → UTF-8 字节（BOM 已在文本里，此处不重复加）。
Uint8List utf8Bytes(String text) => Uint8List.fromList(utf8.encode(text));

Map<String, Object?> _bookJson(Book b) => <String, Object?>{
  'id': b.id,
  'name': b.name,
  'type': b.type,
  'currency': b.currency,
  'icon': b.icon,
  'color': b.color,
  'sortOrder': b.sortOrder,
  'ownerId': b.ownerId,
  'createdAt': b.createdAt,
  'updatedAt': b.updatedAt,
};

Map<String, Object?> _accountJson(Account a) => <String, Object?>{
  'id': a.id,
  'bookId': a.bookId,
  'name': a.name,
  'type': a.type,
  'initialBalanceCents': a.initialBalanceCents,
  'sortOrder': a.sortOrder,
  'ownerId': a.ownerId,
  'createdAt': a.createdAt,
  'updatedAt': a.updatedAt,
};

Map<String, Object?> _categoryJson(Category c) => <String, Object?>{
  'id': c.id,
  'bookId': c.bookId,
  'name': c.name,
  'kind': c.kind,
  if (c.parentId != null) 'parentId': c.parentId,
  'icon': c.icon,
  'color': c.color,
  'sortOrder': c.sortOrder,
  'isPreset': c.isPreset,
  'ownerId': c.ownerId,
  'createdAt': c.createdAt,
  'updatedAt': c.updatedAt,
};

Map<String, Object?> _txJson(TxRow t) => <String, Object?>{
  'id': t.id,
  'bookId': t.bookId,
  'accountId': t.accountId,
  'categoryId': t.categoryId,
  'type': t.type,
  'amountCents': t.amountCents,
  'note': t.note,
  'occurredAt': t.occurredAt,
  'transferGroupId': t.transferGroupId,
  'source': t.source,
  'fingerprint': t.fingerprint,
  'ownerId': t.ownerId,
  'createdAt': t.createdAt,
  'updatedAt': t.updatedAt,
};

Map<String, Object?> _budgetJson(BudgetRow b) => <String, Object?>{
  'id': b.id,
  'bookId': b.bookId,
  'period': b.period,
  'amountCents': b.amountCents,
  'ownerId': b.ownerId,
  'createdAt': b.createdAt,
  'updatedAt': b.updatedAt,
};
