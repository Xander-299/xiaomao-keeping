/// P6.5 · 账本归属：可见性 / 首次登录绑定 / 空态不建账本。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/core/providers/account_scope.dart';
import 'package:yanxin/data/repositories/app_meta_repository.dart';
import 'package:yanxin/data/repositories/book_repository.dart';

import '../helpers/test_database.dart';

Future<void> _signInAs(AppDatabase db, String email) async {
  final meta = AppMetaRepository(db);
  await meta.set(kActiveAccountKey, email);
  await meta.set(
    kSyncAccountsKey,
    encodeSavedAccounts(<SavedAccount>[
      SavedAccount(
        email: email,
        lastUsedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    ]),
  );
}

Future<void> _signOutKeepAccount(AppDatabase db) async {
  await AppMetaRepository(db).remove(kActiveAccountKey);
}

void main() {
  test('从未登录：看到的是本机账本（ownerId 为空），本地优先不被破坏', () async {
    final db = openTestDatabase();
    addTearDown(db.close);
    final repo = BookRepository(db);
    final Book local = await repo.create(name: '本机账本');

    final List<Book> visible = await repo.listVisible();
    expect(visible.map((Book b) => b.id), <String>[local.id]);
  });

  test('已登录 A：只看到 A 的账本，本机账本不再出现', () async {
    final db = openTestDatabase();
    addTearDown(db.close);
    final repo = BookRepository(db);
    await repo.create(name: '本机账本');
    final Book aBook = await repo.create(name: 'A 的账本', ownerId: 'a@example.com');
    await _signInAs(db, 'a@example.com');

    final List<Book> visible = await repo.listVisible();
    expect(visible.map((Book b) => b.id), <String>[aBook.id]);
  });

  test('首次登录：本机账本绑给该账号，并标脏等下轮上传', () async {
    final db = openTestDatabase();
    addTearDown(db.close);
    final repo = BookRepository(db);
    final Book local = await repo.create(name: '本机账本');
    await _signInAs(db, 'a@example.com');

    final int bound = await repo.bindUnownedBooksTo('a@example.com');

    expect(bound, 1);
    final Book? after = await repo.getById(local.id);
    expect(after?.ownerId, 'a@example.com');
    expect(after?.dirty, 1);
  });

  test('第二个账号登录不会抢走第一个账号的账本', () async {
    final db = openTestDatabase();
    addTearDown(db.close);
    final repo = BookRepository(db);
    await repo.create(name: 'A 的账本', ownerId: 'a@example.com');
    final Book bBook = await repo.create(name: 'B 的账本', ownerId: 'b@example.com');

    // B 已经有账本 → 绑定 0 条；A 的账本不受影响
    expect(await repo.bindUnownedBooksTo('b@example.com'), 0);
    final Book? aAfter = await (db.select(db.books)
          ..where((t) => t.ownerId.equals('a@example.com')))
        .getSingleOrNull();
    expect(aAfter?.id, isNotNull);
    expect(aAfter?.ownerId, 'a@example.com', reason: 'A 的账本不能被 B 抢走');
    expect((await repo.getById(bBook.id))?.ownerId, 'b@example.com');
  });

  test('空态（退出但有保存账号）：看不到任何账本，也不自动建账本', () async {
    final db = openTestDatabase();
    addTearDown(db.close);
    final repo = BookRepository(db);
    await repo.create(name: 'A 的账本', ownerId: 'a@example.com');
    await _signInAs(db, 'a@example.com');
    await _signOutKeepAccount(db);

    expect(await repo.listVisible(), isEmpty);
    expect(await repo.ensureVisibleBook(), isNull, reason: '空态不许凭空建本机账本');
  });

  test('已登录时 ensureDefaultBook 建的账本带归属', () async {
    final db = openTestDatabase();
    addTearDown(db.close);
    await _signInAs(db, 'a@example.com');

    final Book book = await BookRepository(db).ensureDefaultBook();
    expect(book.ownerId, 'a@example.com');
  });
}
