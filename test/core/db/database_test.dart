import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/core/db/schema_v1.dart';
import 'package:yanxin/core/db/schema_v2.dart';
import 'package:yanxin/core/db/schema_v5.dart';
import 'package:yanxin/data/repositories/account_repository.dart';
import 'package:yanxin/data/repositories/budget_repository.dart';

import '../../helpers/test_database.dart';

/// 从 sqlite_master 取对象名。
Future<Set<String>> _objects(AppDatabase db, String type) async {
  final rows = await db.customSelect(
    "SELECT name FROM sqlite_master WHERE type = '$type'",
  ).get();
  return rows.map((r) => r.read<String>('name')).toSet();
}

void main() {
  group('AppDatabase schema v1 + v2', () {
    late AppDatabase db;

    setUp(() {
      db = openTestDatabase();
      addTearDown(db.close);
    });

    test('空库建出全部表 + schema_meta + budgets', () async {
      final tables = await _objects(db, 'table');
      expect(
        tables,
        containsAll(<String>[
          'books',
          'accounts',
          'categories',
          'transactions',
          'schema_meta',
          'budgets', // v2 新增
          'sync_conflicts', // v6 新增（P6.4b 冲突存档）
        ]),
      );
    });

    test('索引与旧 DDL 一致（含 DESC 与指纹部分唯一索引）', () async {
      final indexes = await _objects(db, 'index');
      expect(
        indexes,
        containsAll(<String>[
          'idx_accounts_book',
          'idx_categories_book_kind',
          'idx_tx_book_occurred',
          'idx_tx_book_category',
          'idx_tx_account',
          'idx_tx_dirty',
          'idx_tx_fingerprint',
        ]),
      );

      final sql = await db
          .customSelect(
            "SELECT sql FROM sqlite_master WHERE name = 'idx_tx_fingerprint'",
          )
          .getSingle();
      expect(sql.read<String>('sql'), contains('UNIQUE'));
      expect(sql.read<String>('sql'), contains('book_id'));
      expect(sql.read<String>('sql'), contains('deleted_at IS NULL'));

      final occurred = await db
          .customSelect(
            "SELECT sql FROM sqlite_master WHERE name = 'idx_tx_book_occurred'",
          )
          .getSingle();
      expect(occurred.read<String>('sql'), contains('DESC'));
    });

    test('v2 索引：预算「账本 + 月份」部分唯一', () async {
      final sql = await db
          .customSelect(
            'SELECT sql FROM sqlite_master '
            "WHERE name = 'idx_budget_book_period'",
          )
          .getSingle();
      final String ddl = sql.read<String>('sql');
      expect(ddl, contains('UNIQUE'));
      expect(ddl, contains('deleted_at IS NULL'));

      // 直接插两行同账本同月份的未删预算 → 唯一冲突
      Future<void> insert(String id, int deleted) => db.customStatement(
            'INSERT INTO budgets(id, book_id, period, amount_cents, '
            'created_at, updated_at, deleted_at) '
            "VALUES('$id','b1','2026-09',100,1,1,"
            '${deleted == 0 ? 'NULL' : deleted})',
          );
      await insert('g1', 1); // 已删
      await insert('g2', 0);
      expect(insert('g3', 0), throwsA(isA<sqlite.SqliteException>()));
      await insert('g4', 1); // 已删的可以有任意多条
    });

    test('schemaVersion 落库为 6（PRAGMA user_version）', () async {
      final row = await db.customSelect('PRAGMA user_version').getSingle();
      expect(row.read<int>('user_version'), 6);
    });

    test('建表/建索引 DDL 幂等：重复执行不报错且版本不变', () async {
      for (final sql in <String>[
        ...kSchemaV1Indexes,
        ...kSchemaV2Indexes,
        ...kSchemaV5Indexes,
      ]) {
        await db.customStatement(sql);
      }
      final row = await db.customSelect('PRAGMA user_version').getSingle();
      expect(row.read<int>('user_version'), 6);
    });

    test('指纹部分唯一索引：同账本重复冲突，跨账本允许', () async {
      const fp = 'same-fingerprint';
      Future<void> insert(String id, String bookId) => db.customStatement(
        'INSERT INTO transactions(id, book_id, account_id, type, amount_cents, '
        'occurred_at, created_at, updated_at, fingerprint) '
        "VALUES('$id','$bookId','a1','expense',100,1,1,1,'$fp')",
      );

      await insert('t1', 'b1');
      // 同一账本第二条 → UNIQUE 冲突
      expect(
        insert('t2', 'b1'),
        throwsA(isA<sqlite.SqliteException>()),
      );
      // 不同账本同指纹 → 允许（Batch A / A1）
      await insert('t3', 'b2');
    });

    test('指纹部分唯一索引：软删后可再写同指纹', () async {
      const fp = 'dup-after-delete';
      await db.customStatement(
        'INSERT INTO transactions(id, book_id, account_id, type, amount_cents, '
        'occurred_at, created_at, updated_at, fingerprint) '
        "VALUES('t1','b1','a1','expense',100,1,1,1,'$fp')",
      );
      await db.customStatement(
        "UPDATE transactions SET deleted_at = 9 WHERE id = 't1'",
      );
      await db.customStatement(
        'INSERT INTO transactions(id, book_id, account_id, type, amount_cents, '
        'occurred_at, created_at, updated_at, fingerprint) '
        "VALUES('t2','b1','a1','expense',100,1,1,1,'$fp')",
      );

      final rows = await db
          .customSelect(
            "SELECT id FROM transactions WHERE fingerprint = '$fp'",
          )
          .get();
      expect(rows.length, 2);
    });

    test('amount_cents 必为正（CHECK 约束生效）', () async {
      Future<void> insert(int cents) => db.customStatement(
        'INSERT INTO transactions(id, book_id, account_id, type, amount_cents, '
        'occurred_at, created_at, updated_at) '
        "VALUES('t$cents','b1','a1','expense',$cents,1,1,1)",
      );
      expect(insert(0), throwsA(isA<sqlite.SqliteException>()));
      expect(insert(-1), throwsA(isA<sqlite.SqliteException>()));
      await insert(1);
    });

    test('budgets.amount_cents 必为正（CHECK 约束生效）', () async {
      Future<void> insert(int cents) => db.customStatement(
        'INSERT INTO budgets(id, book_id, period, amount_cents, '
        'created_at, updated_at) '
        "VALUES('b$cents','b1','2026-09',$cents,1,1)",
      );
      expect(insert(0), throwsA(isA<sqlite.SqliteException>()));
      expect(insert(-1), throwsA(isA<sqlite.SqliteException>()));
      await insert(1);
    });
  });

  // 换机 / 升级路径的回归：老用户手上的库是 v1，装上新版本后必须只「加表」，
  // 既有的账本与流水一笔都不能少。
  group('v1 → v2 迁移', () {
    test('老库升级：加出 budgets 表与索引，既有数据不丢', () async {
      final sqlite.Database raw = sqlite.sqlite3.openInMemory();

      // 先用当前代码建出完整 schema，再退回成「v1 库」：删掉 budgets + 版本号改回 1
      // （first 实例不接管关闭，好让同一个连接交给下一个实例继续用）
      final AppDatabase v1 = AppDatabase(
        NativeDatabase.opened(raw, closeUnderlyingOnClose: false),
      );
      await v1.customSelect('SELECT 1').get(); // 触发建表
      await v1.customStatement(
        'INSERT INTO books(id, name, created_at, updated_at) '
        "VALUES('b1','旧账本',1,1)",
      );
      await v1.customStatement(
        'INSERT INTO transactions(id, book_id, account_id, type, amount_cents, '
        'occurred_at, created_at, updated_at) '
        "VALUES('t1','b1','a1','expense',8888,1,1,1)",
      );
      await v1.customStatement('DROP TABLE budgets');
      await v1.customStatement('DROP INDEX IF EXISTS idx_budget_book_period');
      await v1.customStatement('PRAGMA user_version = 1');
      final int before = (await v1.customSelect('PRAGMA user_version').getSingle())
          .read<int>('user_version');
      expect(before, 1);
      await v1.close();

      // 用「新版本代码」打开同一个库 → 走 onUpgrade(from 1, to 2)
      final AppDatabase v2 = AppDatabase(NativeDatabase.opened(raw));
      addTearDown(v2.close);

      expect(await _objects(v2, 'table'), contains('budgets'));
      expect(await _objects(v2, 'index'), contains('idx_budget_book_period'));
      final int after = (await v2.customSelect('PRAGMA user_version').getSingle())
          .read<int>('user_version');
      expect(after, 6); // 一次走完 1→2→3→4→5→6 五条迁移

      // 老数据仍在
      final book = await v2
          .customSelect("SELECT name FROM books WHERE id = 'b1'")
          .getSingle();
      expect(book.read<String>('name'), '旧账本');
      final tx = await v2
          .customSelect("SELECT amount_cents FROM transactions WHERE id = 't1'")
          .getSingle();
      expect(tx.read<int>('amount_cents'), 8888);

      // 升级后的库能正常读写预算
      final repo = BudgetRepository(v2);
      expect(await repo.getForMonth('b1', 2026, 9), isNull);
      await repo.setForMonth(
        bookId: 'b1',
        year: 2026,
        month: 9,
        amountCents: 100000,
      );
      expect((await repo.getForMonth('b1', 2026, 9))!.amountCents, 100000);
    });
  });

  // F7.7 C 批：accounts 加自选图标 / 颜色两列。v2 老库升级必须只「加列」，
  // 带默认空串，不改任何既有行。
  group('v2 → v3 迁移', () {
    test('老库升级：accounts 加出 icon / color（默认空串），既有数据不丢', () async {
      final sqlite.Database raw = sqlite.sqlite3.openInMemory();

      // 用当前代码建出完整 schema，再「退回 v2」：删掉两列 + 版本号改回 2。
      final AppDatabase v2 = AppDatabase(
        NativeDatabase.opened(raw, closeUnderlyingOnClose: false),
      );
      await v2.customSelect('SELECT 1').get(); // 触发建表
      await v2.customStatement(
        'INSERT INTO books(id, name, created_at, updated_at) '
        "VALUES('b1','旧账本',1,1)",
      );
      await v2.customStatement(
        'INSERT INTO accounts(id, book_id, name, type, initial_balance_cents, '
        'sort_order, created_at, updated_at) '
        "VALUES('a1','b1','现金','cash',0,0,1,1)",
      );
      await v2.customStatement('ALTER TABLE accounts DROP COLUMN icon');
      await v2.customStatement('ALTER TABLE accounts DROP COLUMN color');
      await v2.customStatement('PRAGMA user_version = 2');
      await v2.close();

      // 用「新版本代码」打开同一个库 → 走 onUpgrade(from 2, to 6)
      final AppDatabase v3 = AppDatabase(NativeDatabase.opened(raw));
      addTearDown(v3.close);

      final int after = (await v3.customSelect('PRAGMA user_version').getSingle())
          .read<int>('user_version');
      expect(after, 6);

      // 既有行数据不丢，且新列落默认空串（= 跟随类型）
      final row = await v3
          .customSelect("SELECT name, icon, color FROM accounts WHERE id = 'a1'")
          .getSingle();
      expect(row.read<String>('name'), '现金');
      expect(row.read<String>('icon'), '');
      expect(row.read<String>('color'), '');

      // 升级后的库能正常带 icon / color 写账户
      final repo = AccountRepository(v3);
      final created = await repo.create(
        bookId: 'b1',
        name: '新卡',
        icon: 'piggy',
        color: '#FF6B8A',
      );
      expect(created.icon, 'piggy');
      expect(created.color, '#FF6B8A');
    });
  });

  // Batch A / A1：v4 的指纹索引是全局唯一；v5 必须只替换索引，
  // 既保留旧数据，又允许不同账本使用相同指纹。
  group('v4 → v5 迁移', () {
    test('全局指纹索引升级为账本内唯一，旧数据不丢', () async {
      final sqlite.Database raw = sqlite.sqlite3.openInMemory();

      final AppDatabase v4 = AppDatabase(
        NativeDatabase.opened(raw, closeUnderlyingOnClose: false),
      );
      await v4.customSelect('SELECT 1').get();
      await v4.customStatement(
        'INSERT INTO books(id, name, created_at, updated_at) '
        "VALUES('b1','旧账本',1,1)",
      );
      await v4.customStatement(
        'INSERT INTO transactions(id, book_id, account_id, type, amount_cents, '
        'occurred_at, created_at, updated_at, fingerprint) '
        "VALUES('t1','b1','a1','expense',8888,1,1,1,'legacy-fp')",
      );
      // 退回 v4 的全局唯一索引 + 版本号
      await v4.customStatement('DROP INDEX IF EXISTS idx_tx_fingerprint');
      await v4.customStatement(
        'CREATE UNIQUE INDEX idx_tx_fingerprint ON transactions(fingerprint) '
        'WHERE fingerprint IS NOT NULL AND deleted_at IS NULL',
      );
      await v4.customStatement('PRAGMA user_version = 4');
      await v4.close();

      final AppDatabase v5 = AppDatabase(NativeDatabase.opened(raw));
      addTearDown(v5.close);

      final int after = (await v5.customSelect('PRAGMA user_version').getSingle())
          .read<int>('user_version');
      expect(after, 6);

      final index = await v5
          .customSelect(
            "SELECT sql FROM sqlite_master WHERE name = 'idx_tx_fingerprint'",
          )
          .getSingle();
      expect(index.read<String>('sql'), contains('book_id'));

      final old = await v5
          .customSelect("SELECT amount_cents FROM transactions WHERE id = 't1'")
          .getSingle();
      expect(old.read<int>('amount_cents'), 8888);

      // 不同账本同指纹现在允许
      await v5.customStatement(
        'INSERT INTO transactions(id, book_id, account_id, type, amount_cents, '
        'occurred_at, created_at, updated_at, fingerprint) '
        "VALUES('t2','b2','a1','expense',8888,1,1,1,'legacy-fp')",
      );
      // 同账本同指纹仍冲突
      expect(
        v5.customStatement(
          'INSERT INTO transactions(id, book_id, account_id, type, amount_cents, '
          'occurred_at, created_at, updated_at, fingerprint) '
          "VALUES('t3','b1','a1','expense',8888,1,1,1,'legacy-fp')",
        ),
        throwsA(isA<sqlite.SqliteException>()),
      );
    });
  });
}
