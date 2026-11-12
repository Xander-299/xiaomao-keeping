/// 备份嗅探（`looksLikeBackupJson`）的回归 —— 2026-11-13 的真 bug。
///
/// 现象：用户导出的真备份（1 条流水 + 51 个分类）在「导入账单」里被判「无法识别」，
/// 而项目里的小备份样本能过。
/// 根因：旧实现只看**前 2 KB** 里有没有 `"transactions"`；备份的键序是
/// `schemaVersion / exportedAt / book / accounts / categories / transactions / budgets`，
/// 分类一多就把 `"transactions"` 推到 2 KB 之后（实测 20441 字节；旧版 4 账户 257 流水的备份在 6660 字节）。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/features/import/application/backup_restore.dart';

import '../../helpers/test_database.dart';

/// 造一份「形状像真备份」的 JSON：分类多到把 `transactions` 挤出 2 KB 窗口。
Map<String, Object?> _backup({int categories = 60, int txs = 3}) {
  const int base = 1794000000000;
  return <String, Object?>{
    'schemaVersion': 2,
    'exportedAt': '2026-11-13T12:00:00+08:00',
    'book': <String, Object?>{
      'id': 'bk-1',
      'name': '默认账本',
      'type': 'personal',
      'currency': 'CNY',
      'icon': '',
      'color': '',
      'sortOrder': 0,
      'ownerId': null,
      'createdAt': base,
      'updatedAt': base,
    },
    'accounts': <Map<String, Object?>>[
      <String, Object?>{
        'id': 'acc-1',
        'bookId': 'bk-1',
        'name': '现金',
        'type': 'cash',
        'initialBalanceCents': 0,
        'sortOrder': 0,
        'icon': '',
        'color': '',
        'createdAt': base,
        'updatedAt': base,
      },
    ],
    // 名字故意长一点：真机上 51 个分类就足够把 transactions 推到 20 KB
    'categories': <Map<String, Object?>>[
      for (int i = 0; i < categories; i++)
        <String, Object?>{
          'id': 'cat-$i',
          'bookId': 'bk-1',
          'name': '分类名称样本$i',
          'kind': 'expense',
          'parentId': null,
          'sortOrder': i,
          'icon': '',
          'color': '',
          'isPreset': 0,
          'isArchived': 0,
          'createdAt': base,
          'updatedAt': base,
        },
    ],
    'transactions': <Map<String, Object?>>[
      for (int i = 0; i < txs; i++)
        <String, Object?>{
          'id': 'tx-$i',
          'bookId': 'bk-1',
          'accountId': 'acc-1',
          'categoryId': 'cat-0',
          'type': 'expense',
          'amountCents': 1000 + i,
          'note': '样本$i',
          'occurredAt': base + i * 1000,
          'transferGroupId': null,
          'source': 'manual',
          'fingerprint': null,
          'ownerId': null,
          'createdAt': base,
          'updatedAt': base,
        },
    ],
    'budgets': <Object?>[],
  };
}

List<int> _bytes(Map<String, Object?> payload) =>
    utf8.encode(jsonEncode(payload));

void main() {
  test('小备份（transactions 在前 2 KB 内）→ 认得出', () {
    expect(looksLikeBackupJson(_bytes(_backup(categories: 1, txs: 1))), isTrue);
  });

  test('真备份形状：分类多到 transactions 超过 2 KB → **仍然认得出**（旧实现在这里挂）', () {
    final List<int> bytes = _bytes(_backup());
    final String text = utf8.decode(bytes);
    expect(
      text.indexOf('"transactions"'),
      greaterThan(2048),
      reason: '前置条件：本用例必须复现「挤出 2 KB 窗口」',
    );
    expect(looksLikeBackupJson(bytes), isTrue);
  });

  test('旧版备份形状（4 账户 / 15 分类 / 257 流水）→ 认得出', () {
    final List<int> bytes = _bytes(
      _backup(categories: 15, txs: 257),
    );
    expect(looksLikeBackupJson(bytes), isTrue);
  });

  test('BOM 与前置空白不影响判断', () {
    final List<int> json = _bytes(_backup());
    final List<int> withBom = <int>[0xEF, 0xBB, 0xBF, ...json];
    expect(looksLikeBackupJson(withBom), isTrue);
    expect(looksLikeBackupJson(<int>[0x0A, 0x20, ...json]), isTrue);
  });

  test('CSV / 不是 JSON / 不是小耄备份的 JSON → 一律 false', () {
    expect(looksLikeBackupJson(utf8.encode('日期,类型,金额\r\n2026-11-01,支出,1.00')), isFalse);
    expect(looksLikeBackupJson(utf8.encode('hello world')), isFalse);
    expect(looksLikeBackupJson(utf8.encode('{"foo":1,"bar":2}')), isFalse);
    expect(looksLikeBackupJson(<int>[]), isFalse);
  });

  test('超窗口的真备份能整体恢复（端到端）', () async {
    final AppDatabase db = openTestDatabase();
    addTearDown(db.close);
    final BackupRestoreReport report = await restoreBackupJson(
      db,
      bytes: _bytes(_backup(categories: 60, txs: 3)),
      createBook: false,
    );
    expect(report.imported, 3);
    // 默认账本自带一个「现金」账户，与夹具同名 → 复用而不是重建（这正是幂等该有的样子）
    expect(report.createdAccounts, 0);
    expect(report.createdCategories, greaterThanOrEqualTo(1));
  });
}
