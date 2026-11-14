/// P6.4b · 冲突存档：写入 / 上限 / 恢复本机版本。
library;

import 'dart:convert';

import 'package:drift/drift.dart' show OrderClauseGenerator, OrderingTerm;
import 'package:flutter_test/flutter_test.dart';

import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/data/repositories/account_repository.dart';
import 'package:yanxin/data/repositories/app_meta_repository.dart';
import 'package:yanxin/data/repositories/book_repository.dart';
import 'package:yanxin/features/sync/application/sync_conflicts.dart';

import '../../helpers/test_database.dart';

void main() {
  test('存档写入后能读到两份 payload', () async {
    final AppDatabase db = openTestDatabase();
    addTearDown(db.close);
    await archiveConflict(
      db,
      entity: 'account',
      bookId: 'b1',
      entityId: 'a1',
      localUpdatedAt: 1000,
      localPayload: <String, Object?>{'name': '本机名'},
      serverUpdatedAt: 2000,
      serverPayload: <String, Object?>{'name': '云端名'},
    );

    final List<SyncConflictEntry> rows = await db.select(db.syncConflicts).get();
    expect(rows.length, 1);
    expect(rows.single.entity, 'account');
    expect(rows.single.localUpdatedAt, 1000);
    expect(rows.single.serverUpdatedAt, 2000);
    expect(
      (jsonDecode(rows.single.localPayload) as Map<String, Object?>)['name'],
      '本机名',
    );
    expect(
      (jsonDecode(rows.single.serverPayload) as Map<String, Object?>)['name'],
      '云端名',
    );
  });

  test('超过 50 条时按时间 FIFO 裁掉最老的', () async {
    final AppDatabase db = openTestDatabase();
    addTearDown(db.close);
    for (int i = 0; i < 55; i++) {
      await archiveConflict(
        db,
        entity: 'account',
        bookId: 'b1',
        entityId: 'a$i',
        localUpdatedAt: 1000 + i,
        localPayload: <String, Object?>{'name': '本机$i'},
        serverUpdatedAt: 2000 + i,
        serverPayload: <String, Object?>{'name': '云端$i'},
      );
    }

    final List<SyncConflictEntry> rows = await (db.select(db.syncConflicts)
          ..orderBy(<OrderClauseGenerator<$SyncConflictsTable>>[
            (t) => OrderingTerm.desc(t.createdAt),
            (t) => OrderingTerm.desc(t.id),
          ]))
        .get();

    expect(rows.length, kSyncConflictLimit);
    // 最新那条一定在；最老的几条已经没了
    expect(rows.first.entityId, 'a54');
    expect(rows.any((SyncConflictEntry r) => r.entityId == 'a0'), isFalse);
  });

  test('恢复本机版本：写回业务表（dirty=1、updatedAt=now）并删掉存档', () async {
    final AppDatabase db = openTestDatabase();
    addTearDown(db.close);
    final AppMetaRepository meta = AppMetaRepository(db);
    final Book book = await BookRepository(db).ensureDefaultBook();
    final Account account = await AccountRepository(
      db,
    ).create(bookId: book.id, name: '云端改名');

    await archiveConflict(
      db,
      entity: 'account',
      bookId: book.id,
      entityId: account.id,
      localUpdatedAt: 1000,
      localPayload: <String, Object?>{
        ...account.toJson(),
        'name': '本机名',
        'updatedAt': 1000,
      },
      serverUpdatedAt: 2000,
      serverPayload: <String, Object?>{...account.toJson(), 'name': '云端改名'},
    );

    final SyncConflictEntry entry =
        (await db.select(db.syncConflicts).get()).single;
    final bool ok = await restoreConflictRows(db, meta, entry);
    expect(ok, isTrue);

    final Account? after = await (db.select(
      db.accounts,
    )..where((t) => t.id.equals(account.id))).getSingleOrNull();
    expect(after?.name, '本机名');
    expect(after?.dirty, 1, reason: '恢复后必须等下一次同步推上去');
    expect(after!.updatedAt, greaterThan(2000));

    expect(await db.select(db.syncConflicts).get(), isEmpty);
  });
}
