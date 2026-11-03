/// 移植自旧栈 tests/bill-import/importer.test.js（ADR-7 去重 + 事务编排）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/data/repositories/account_repository.dart';
import 'package:yanxin/data/repositories/book_repository.dart';
import 'package:yanxin/data/repositories/category_repository.dart';
import 'package:yanxin/features/import/application/bill_importer.dart';
import 'package:yanxin/features/import/data/bill_normalize.dart';
import 'package:yanxin/features/import/data/bill_profiles.dart';

import '../../helpers/test_database.dart';

/// 构造 ParsedRow 的快捷方式。
int _extSeq = 0;

ParsedRow _row({
  String? externalId,
  int amountCents = 1230,
  String direction = 'expense',
  String counterparty = '美团平台商户',
  String product = '外卖订单',
  bool unknownStatus = false,
}) {
  _extSeq++;
  return ParsedRow(
    source: 'wechat_csv',
    externalId: externalId ?? 'EXT$_extSeq',
    occurredAt: DateTime(2026, 8, 1, 12).millisecondsSinceEpoch,
    amountCents: amountCents,
    direction: direction,
    counterparty: counterparty,
    product: product,
    method: '零钱',
    status: '支付成功',
    unknownStatus: unknownStatus,
    rawIndex: 0,
  );
}

void main() {
  late AppDatabase db;
  late Book book;
  late String accountId;
  late ({Map<String, String> expense, Map<String, String> income}) categoryMaps;

  setUp(() async {
    db = openTestDatabase();
    book = await BookRepository(db).ensureDefaultBook();
    accountId = await ensureImportAccount(AccountRepository(db), book.id);
    categoryMaps =
        await buildCategoryMaps(CategoryRepository(db), book.id);
  });

  tearDown(() => db.close());

  Future<int> countRows() async {
    final n = await db
        .customSelect('SELECT COUNT(*) AS n FROM transactions WHERE deleted_at IS NULL')
        .getSingle();
    return n.read<int>('n');
  }

  test('首导 N 条全部入账；金额/方向/分类/备注正确', () async {
    final rows = [
      _row(externalId: 'A1', amountCents: 1230, direction: 'expense'),
      _row(
        externalId: 'A2',
        amountCents: 8800,
        direction: 'income',
        counterparty: '公司',
        product: '工资代发',
      ),
    ];
    final report = await importRows(
      db,
      bookId: book.id,
      accountId: accountId,
      categoryMaps: categoryMaps,
      rows: rows,
    );
    expect(report.imported, 2);
    expect(await countRows(), 2);

    final all = await db
        .customSelect('SELECT * FROM transactions ORDER BY amount_cents')
        .get();
    final income = all.firstWhere((t) => t.read<String>('type') == 'income');
    final expense = all.firstWhere((t) => t.read<String>('type') == 'expense');
    expect(income.read<int>('amount_cents'), 8800);
    expect(income.read<String>('note'), '公司 · 工资代发');
    expect(expense.read<int>('amount_cents'), 1230);
    expect(expense.read<String>('source'), 'wechat_csv');
    expect(expense.read<String>('fingerprint'), isNotEmpty);
  });

  test('分类映射：关键词命中入库；未命中落「其他」并计入 uncategorized', () async {
    final rows = [
      _row(externalId: 'B1', counterparty: '滴滴出行', product: '快车'), // → 交通
      _row(externalId: 'B2', counterparty: '无关键词', product: '神秘商品'), // → 其他
    ];
    final report = await importRows(
      db,
      bookId: book.id,
      accountId: accountId,
      categoryMaps: categoryMaps,
      rows: rows,
    );
    expect(report.uncategorized, 1);

    final cats = await db
        .customSelect(
          'SELECT c.name AS name, t.note AS note FROM transactions t '
          'JOIN categories c ON c.id = t.category_id WHERE t.deleted_at IS NULL',
        )
        .get();
    final byNote = {
      for (final c in cats) c.read<String>('note'): c.read<String>('name'),
    };
    expect(byNote['滴滴出行 · 快车'], '交通');
    expect(byNote['无关键词 · 神秘商品'], '其他');
  });

  test('同一文件导入两个账本：各自首次入账，账本内二次导入仍 duplicate', () async {
    final Book bookB = await BookRepository(db).create(name: '第二账本');
    final String accountB = await ensureImportAccount(
      AccountRepository(db),
      bookB.id,
    );
    final categoryMapsB = await buildCategoryMaps(
      CategoryRepository(db),
      bookB.id,
    );
    final rows = [
      _row(externalId: 'CROSS1'),
      _row(externalId: 'CROSS2'),
    ];

    final rA1 = await importRows(
      db,
      bookId: book.id,
      accountId: accountId,
      categoryMaps: categoryMaps,
      rows: rows,
    );
    expect(rA1.imported, 2);

    // 相同指纹进入另一个账本：必须成功，不能被全局指纹误判为重复
    final rB1 = await importRows(
      db,
      bookId: bookB.id,
      accountId: accountB,
      categoryMaps: categoryMapsB,
      rows: rows,
    );
    expect(rB1.imported, 2);

    // 同一个账本内二次导入仍然全部 duplicate
    final rA2 = await importRows(
      db,
      bookId: book.id,
      accountId: accountId,
      categoryMaps: categoryMaps,
      rows: rows,
    );
    expect(rA2.imported, 0);
    expect(rA2.duplicates, 2);
  });

  test('同一文件连导两次 → 第二次全部 duplicate，零新增', () async {
    final rows = [
      _row(externalId: 'C1'),
      _row(externalId: 'C2'),
      _row(externalId: 'C3'),
    ];
    final r1 = await importRows(
      db,
      bookId: book.id,
      accountId: accountId,
      categoryMaps: categoryMaps,
      rows: rows,
    );
    expect(r1.imported, 3);

    final r2 = await importRows(
      db,
      bookId: book.id,
      accountId: accountId,
      categoryMaps: categoryMaps,
      rows: rows,
    );
    expect(r2.imported, 0);
    expect(r2.duplicates, 3);
    expect(await countRows(), 3);
  });

  test('删掉 1 笔（软删）后重导 → 仅该笔重新入账', () async {
    final rows = [
      _row(externalId: 'D1', counterparty: '商户一', product: '商品一'),
      _row(externalId: 'D2', counterparty: '待删商户', product: '商品二'),
      _row(externalId: 'D3', counterparty: '商户三', product: '商品三'),
    ];
    await importRows(
      db,
      bookId: book.id,
      accountId: accountId,
      categoryMaps: categoryMaps,
      rows: rows,
    );
    await db.customStatement(
      "UPDATE transactions SET deleted_at = strftime('%s','now') "
      "WHERE note = '待删商户 · 商品二' AND deleted_at IS NULL",
    );

    final r2 = await importRows(
      db,
      bookId: book.id,
      accountId: accountId,
      categoryMaps: categoryMaps,
      rows: rows,
    );
    expect(r2.imported, 1);
    expect(r2.duplicates, 2);
    expect(await countRows(), 3);
  });

  test('文件内重复行（指纹相同）内存去重，只入账一次', () async {
    final same = _row(externalId: 'E1');
    final rows = [same, same, same];
    final report = await importRows(
      db,
      bookId: book.id,
      accountId: accountId,
      categoryMaps: categoryMaps,
      rows: rows,
    );
    expect(report.fileDuplicates, 2);
    expect(report.imported, 1);
    expect(await countRows(), 1);
  });

  test('非 duplicate 异常 → 整体回滚（分类缺失触发约束）', () async {
    final rows = [
      _row(externalId: 'F1'),
      _row(externalId: 'F2', direction: 'expense'),
    ];
    // 破坏 categoryMaps：让所有 expense 都找不到分类 → categoryId null → create 抛错
    final brokenMaps =
        (expense: <String, String>{}, income: categoryMaps.income);
    await expectLater(
      importRows(
        db,
        bookId: book.id,
        accountId: accountId,
        categoryMaps: brokenMaps,
        rows: rows,
      ),
      throwsA(anything),
    );

    // F1 之前可能已插入，但事务必须整体回滚 → 库里仍是 0 行
    expect(await countRows(), 0);
  });

  test('options.cancelled 的单条不参与导入', () async {
    final rows = [_row(externalId: 'G1'), _row(externalId: 'G2')];
    final report = await importRows(
      db,
      bookId: book.id,
      accountId: accountId,
      categoryMaps: categoryMaps,
      rows: rows,
      options: const [RowOption(), RowOption(cancelled: true)],
    );
    expect(report.cancelled, 1);
    expect(report.imported, 1);
  });

  test('IN 预查分批 500 的边界：510 条全入账', () async {
    final rows =
        List.generate(510, (i) => _row(externalId: 'H$i'));
    final report = await importRows(
      db,
      bookId: book.id,
      accountId: accountId,
      categoryMaps: categoryMaps,
      rows: rows,
    );
    expect(report.imported, 510);
    expect(await countRows(), 510);
  });

  test('微信 fixture 端到端：导入 → 二次导入全 duplicate', () async {
    final text = File('test/fixtures/wechat-sample.csv').readAsStringSync();
    final parsed = parseBillCsv(wechatProfile, text);
    final r1 = await importRows(
      db,
      bookId: book.id,
      accountId: accountId,
      categoryMaps: categoryMaps,
      rows: parsed.rows,
    );
    expect(r1.imported, 4);

    final r2 = await importRows(
      db,
      bookId: book.id,
      accountId: accountId,
      categoryMaps: categoryMaps,
      rows: parsed.rows,
    );
    expect(r2.imported, 0);
    expect(r2.duplicates, 4);
  });

  // 回归：首次使用验收 P3 —— 零新增却报「未匹配分类 N 笔」自相矛盾。
  // 未匹配分类只对真正入库的行有意义；重复跳过的行与分类规则无关。
  test('二次导入零新增 → uncategorized 归零（不虚报未匹配分类）', () async {
    final rows = [
      _row(externalId: 'P3A', counterparty: '无关键词甲', product: '神秘甲'),
      _row(externalId: 'P3B', counterparty: '无关键词乙', product: '神秘乙'),
    ];
    final r1 = await importRows(
      db,
      bookId: book.id,
      accountId: accountId,
      categoryMaps: categoryMaps,
      rows: rows,
    );
    expect(r1.imported, 2);
    expect(r1.uncategorized, 2); // 首导：两笔都未命中规则

    final r2 = await importRows(
      db,
      bookId: book.id,
      accountId: accountId,
      categoryMaps: categoryMaps,
      rows: rows,
    );
    expect(r2.imported, 0);
    expect(r2.duplicates, 2);
    expect(r2.uncategorized, 0); // 零新增 → 不得再有「未匹配分类」
  });

  test('ensureImportAccount 幂等：多次调用不重复建账户', () async {
    final id1 = await ensureImportAccount(AccountRepository(db), book.id);
    final id2 = await ensureImportAccount(AccountRepository(db), book.id);
    expect(id1, id2);
    final accounts = await AccountRepository(db).listByBook(book.id);
    expect(accounts.where((a) => a.name == '导入账户'), hasLength(1));
  });

  group('dryRun 试算（预览页用）', () {
    test('dryRun 报告与真实导入一致，但库零变化', () async {
      final rows = [
        _row(externalId: 'X1', counterparty: '滴滴出行', product: '快车'),
        _row(externalId: 'X2'),
      ];
      // 先真实导入 X1，制造一个「已存在」
      await importRows(
        db,
        bookId: book.id,
        accountId: accountId,
        categoryMaps: categoryMaps,
        rows: [rows[0]],
      );

      final preview = await importRows(
        db,
        bookId: book.id,
        accountId: accountId,
        categoryMaps: categoryMaps,
        rows: rows,
        dryRun: true,
      );
      expect(preview.imported, 1); // X2 会导入
      expect(preview.duplicates, 1); // X1 重复

      // 库零变化：仍然只有 1 条
      expect(await countRows(), 1);
    });

    test('dryRun 后再真实导入，结果一致', () async {
      final rows = [_row(externalId: 'Y1'), _row(externalId: 'Y2')];
      final preview = await importRows(
        db,
        bookId: book.id,
        accountId: accountId,
        categoryMaps: categoryMaps,
        rows: rows,
        dryRun: true,
      );
      final real = await importRows(
        db,
        bookId: book.id,
        accountId: accountId,
        categoryMaps: categoryMaps,
        rows: rows,
      );
      expect(real.imported, preview.imported);
      expect(real.duplicates, preview.duplicates);
    });
  });
}
