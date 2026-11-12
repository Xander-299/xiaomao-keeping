/// 「小耄记账 CSV」导出 → 导入 的闭环（2026-11-13）。
///
/// 之前导入只认微信 / 支付宝，用户把自己导出的 CSV 再导回来会被判成
/// 「无法识别的账单文件格式」—— 导出与导入必须闭环。
///
/// 这里覆盖四件事：
/// 1. 自有表头能被 [parseBillFileAuto] 认出来（且不会误吃微信/支付宝）；
/// 2. 分类 / 账户 / 备注 **直通**（不走关键词规则二次猜）；
/// 3. 同一份文件反复导、或导回**原账本**都不翻倍（靠 `流水ID` 精确去重）；
/// 4. 转账行按「不计收支」跳过并计入报告。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/data/repositories/account_repository.dart';
import 'package:yanxin/data/repositories/book_repository.dart';
import 'package:yanxin/data/repositories/category_repository.dart';
import 'package:yanxin/data/repositories/transaction_repository.dart';
import 'package:yanxin/features/export/application/csv_export.dart';
import 'package:yanxin/features/import/application/bill_importer.dart';
import 'package:yanxin/features/import/data/bill_normalize.dart';
import 'package:yanxin/features/import/data/bill_parse.dart';

import '../../helpers/test_database.dart';

Future<({AppDatabase db, Book book})> _seed() async {
  final AppDatabase db = openTestDatabase();
  final Book book = await BookRepository(db).ensureDefaultBook();
  return (db: db, book: book);
}

Future<({List<TxRow> rows, Map<String, String> cats, Map<String, String> accs})>
_seedRows(AppDatabase db, Book book) async {
  final CategoryRepository catRepo = CategoryRepository(db);
  final AccountRepository accRepo = AccountRepository(db);
  final TransactionRepository txRepo = TransactionRepository(db);

  final List<Category> cats = await catRepo.listByBook(book.id, kind: 'expense');
  final Category food = cats.firstWhere((Category c) => c.name == '餐饮');
  final Category other = cats.firstWhere((Category c) => c.name == '其他');

  final Account cash = (await accRepo.listByBook(book.id)).first;
  final Account bank = await accRepo.create(bookId: book.id, name: '工资卡');

  final DateTime at = DateTime(2026, 9, 23, 12, 5);
  final List<TxRow> rows = <TxRow>[
    await txRepo.create(
      bookId: book.id,
      accountId: cash.id,
      categoryId: food.id,
      type: 'expense',
      amountCents: 1234,
      occurredAt: at.millisecondsSinceEpoch,
      note: '午饭',
    ),
    await txRepo.create(
      bookId: book.id,
      accountId: bank.id,
      categoryId: other.id,
      type: 'income',
      amountCents: 100000,
      occurredAt: at.add(const Duration(hours: 2)).millisecondsSinceEpoch,
      note: '报销',
    ),
  ];
  return (
    rows: rows,
    cats: <String, String>{
      for (final Category c in await catRepo.listByBook(book.id)) c.id: c.name,
    },
    accs: <String, String>{
      for (final Account a in await accRepo.listByBook(book.id)) a.id: a.name,
    },
  );
}

void main() {
  test('自有 CSV 表头能被识别（source = yanxin_csv）', () async {
    final seeded = await _seed();
    addTearDown(seeded.db.close);
    final data = await _seedRows(seeded.db, seeded.book);

    final String csv = buildBillCsv(
      rows: data.rows,
      categoryNames: data.cats,
      accountNames: data.accs,
    );
    final ParseOutcome outcome = parseBillFileAuto(utf8.encode(csv));

    expect(outcome, isA<BillRowsOutcome>());
    final BillParseResult result = (outcome as BillRowsOutcome).result;
    expect(result.source, 'yanxin_csv');
    expect(result.rows, hasLength(2));
    expect(result.stats.malformed, 0);
    expect(result.stats.skipped, 0);

    // 分类 / 账户 / 备注 都从文件里直读，不靠规则猜
    final ParsedRow lunch =
        result.rows.firstWhere((ParsedRow r) => r.note == '午饭');
    expect(lunch.categoryHint, '餐饮');
    expect(lunch.accountName, '现金');
    expect(lunch.direction, 'expense');
    expect(lunch.amountCents, 1234);
    expect(lunch.externalId, data.rows.first.id);
  });

  test('微信 / 支付宝表头不会被自有 profile 抢走', () {
    // 微信表头（没有「日期 / 类型 / 金额」三列），应回落到 wechat 判定
    const String wechat = '交易时间,交易类型,交易对方,商品,收/支,金额(元),支付方式,当前状态,交易单号,商户单号\n'
        '2026-08-01 12:30:00,商户消费,美团,外卖,支出,¥12.30,零钱,支付成功,T1,M1\n';
    final ParseOutcome outcome = parseBillFileAuto(utf8.encode(wechat));
    expect(outcome, isA<BillRowsOutcome>());
    expect((outcome as BillRowsOutcome).result.source, 'wechat_csv');
  });

  test('导回原账本：靠流水ID 精确去重，一条都不新增', () async {
    final seeded = await _seed();
    addTearDown(seeded.db.close);
    final data = await _seedRows(seeded.db, seeded.book);

    final String csv = buildBillCsv(
      rows: data.rows,
      categoryNames: data.cats,
      accountNames: data.accs,
    );
    final BillParseResult parsed =
        (parseBillFileAuto(utf8.encode(csv)) as BillRowsOutcome).result;

    final ImportReport report = await importRows(
      seeded.db,
      bookId: seeded.book.id,
      accountId: (await AccountRepository(seeded.db)
              .listByBook(seeded.book.id))
          .first
          .id,
      categoryMaps: await buildCategoryMaps(
        CategoryRepository(seeded.db),
        seeded.book.id,
      ),
      rows: parsed.rows,
      accountRepo: AccountRepository(seeded.db),
    );

    expect(report.imported, 0, reason: '这 2 条本来就在账本里');
    expect(report.duplicates, 2);
    expect(
      (await TransactionRepository(seeded.db).listByBook(seeded.book.id)),
      hasLength(2),
    );
  });

  test('导进新账本：分类 / 账户 / 备注 保真，且不会重复建同名账户', () async {
    final src = await _seed();
    addTearDown(src.db.close);
    final data = await _seedRows(src.db, src.book);
    final String csv = buildBillCsv(
      rows: data.rows,
      categoryNames: data.cats,
      accountNames: data.accs,
    );

    final dst = await _seed();
    addTearDown(dst.db.close);
    final Book target = await (BookRepository(dst.db)).create(name: '新手机');
    final BillParseResult parsed =
        (parseBillFileAuto(utf8.encode(csv)) as BillRowsOutcome).result;

    final ImportReport report = await importRows(
      dst.db,
      bookId: target.id,
      accountId: (await AccountRepository(dst.db).listByBook(target.id)).first.id,
      categoryMaps: await buildCategoryMaps(
        CategoryRepository(dst.db),
        target.id,
      ),
      rows: parsed.rows,
      accountRepo: AccountRepository(dst.db),
    );

    expect(report.imported, 2);
    expect(report.uncategorized, 0, reason: '分类列是直通的，不该落「其他」');

    final List<TxRow> got =
        await TransactionRepository(dst.db).listByBook(target.id);
    expect(got.map((TxRow t) => t.note).toSet(), <String>{'午饭', '报销'});

    final List<Account> accounts =
        await AccountRepository(dst.db).listByBook(target.id);
    expect(
      accounts.where((Account a) => a.name == '工资卡'),
      hasLength(1),
      reason: '按名字复用，不能每行建一个',
    );
  });

  test('老格式（没有流水ID 列）仍能导：按指纹去重', () async {
    final seeded = await _seed();
    addTearDown(seeded.db.close);
    final data = await _seedRows(seeded.db, seeded.book);
    final String csv = buildBillCsv(
      rows: data.rows,
      categoryNames: data.cats,
      accountNames: data.accs,
    );
    // 去掉最后一列（流水ID），模拟 v0.8.4 及以前导出的文件
    final String legacy = csv
        .split('\r\n')
        .map((String line) {
          final int i = line.lastIndexOf(',');
          return i < 0 ? line : line.substring(0, i);
        })
        .join('\r\n');

    final BillParseResult parsed =
        (parseBillFileAuto(utf8.encode(legacy)) as BillRowsOutcome).result;
    final ImportReport first = await importRows(
      seeded.db,
      bookId: seeded.book.id,
      accountId: (await AccountRepository(seeded.db).listByBook(seeded.book.id))
          .first
          .id,
      categoryMaps: await buildCategoryMaps(
        CategoryRepository(seeded.db),
        seeded.book.id,
      ),
      rows: parsed.rows,
      accountRepo: AccountRepository(seeded.db),
    );
    // 没有 id 列 → 与库里 existing 的 manual 行指纹不同，会新增一份（这是已知取舍，
    // 老文件无法精确识别；同一份老文件再次导入则按指纹去重）。
    expect(first.imported, 2);

    final ImportReport second = await importRows(
      seeded.db,
      bookId: seeded.book.id,
      accountId: (await AccountRepository(seeded.db).listByBook(seeded.book.id))
          .first
          .id,
      categoryMaps: await buildCategoryMaps(
        CategoryRepository(seeded.db),
        seeded.book.id,
      ),
      rows: parsed.rows,
      accountRepo: AccountRepository(seeded.db),
    );
    expect(second.imported, 0);
    expect(second.duplicates, 2);
  });

  test('转账行：按「不计收支」跳过，金额计入 neutralSkipped', () async {
    final seeded = await _seed();
    addTearDown(seeded.db.close);
    final data = await _seedRows(seeded.db, seeded.book);

    // 手工拼一行转账（buildBillCsv 会写「转账」）
    const String csv = '$kUtf8Bom日期,类型,金额,分类,账户,备注,来源,流水ID\r\n'
        '2026-09-24 10:00,转账,50.00,,现金,还信用卡,manual,x1\r\n';
    final BillParseResult parsed =
        (parseBillFileAuto(utf8.encode(csv)) as BillRowsOutcome).result;

    expect(parsed.rows, isEmpty, reason: '转账没有对侧腿，不当收支导入');
    expect(parsed.stats.neutralSkipped, 1);
    expect(parsed.stats.neutralSkippedCents, 5000);
    expect(data.rows, hasLength(2)); // 只用到种子数据，避免未使用告警
  });
}
