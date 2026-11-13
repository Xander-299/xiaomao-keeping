/// 生成「当前账本」的备份 JSON 字节（P6.3 云备份用）。
///
/// 与「数据导出 → 备份 JSON」**同一份产物**：同一套仓储取数、同一个
/// `buildBackupJson`、同一个设置白名单。这样「导出文件」与「云端备份」
/// 可以互相恢复，不会出现两套格式。
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:yanxin/data/providers/account_providers.dart';
import 'package:yanxin/data/providers/book_providers.dart';
import 'package:yanxin/data/providers/category_providers.dart';
import 'package:yanxin/data/providers/database.dart';
import 'package:yanxin/features/export/application/csv_export.dart';
import 'package:yanxin/features/import/application/backup_settings.dart';

/// 取数 → 生成备份 JSON → UTF-8 字节。
///
/// 失败抛 [StateError]（账本未就绪）/ 仓储异常，由调用方转成用户提示。
Future<Uint8List> buildCurrentBackupBytes(Ref ref) async {
  final String? bookId = await ref.read(activeBookIdProvider.future);
  if (bookId == null) throw StateError('当前账本未就绪');
  final book = await ref.read(currentBookProvider.future);
  if (book == null) throw StateError('当前账本未就绪');

  final transactions = await ref
      .read(transactionRepositoryProvider)
      .listByBook(bookId);
  final accounts = await ref.read(accountsProvider.future);
  final categories = await ref.read(categoriesProvider.future);
  final budgets = await ref.read(budgetRepositoryProvider).listByBook(bookId);
  final settings = await collectBackupSettings(
    ref.read(appMetaRepositoryProvider),
  );

  final String json = buildBackupJson(
    book: book,
    accounts: accounts,
    categories: categories,
    transactions: transactions,
    budgets: budgets,
    exportedAtMs: DateTime.now().millisecondsSinceEpoch,
    settings: settings,
  );
  return utf8Bytes(json);
}

/// 当前账本备份字节的 provider（页面 / 控制器共用，便于测试直接读）。
final currentBackupBytesProvider = FutureProvider<Uint8List>(
  buildCurrentBackupBytes,
);
