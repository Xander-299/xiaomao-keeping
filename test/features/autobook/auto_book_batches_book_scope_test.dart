/// 自动记账批次**按账本取**（F7.20 余项）。
///
/// 事故形态：批次存在全库共用的一份 KV 里（最多 3 条）。切到另一个账本后，
/// `/autobook` 的「最近一次自动记账」仍显示**上一个账本**的那批，用户点「撤销」
/// 必然得到「这批已撤销或不复存在」—— 信息是真的，但指向了错的账本。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/data/repositories/app_meta_repository.dart';
import 'package:yanxin/features/autobook/data/auto_book_batches.dart';

import '../../helpers/test_database.dart';

AutoBookBatch _batch(String id, {String? bookId, int atMs = 1}) {
  return AutoBookBatch(
    batchId: id,
    txIds: <String>['tx-$id'],
    count: 1,
    totalCents: 1234,
    atMs: atMs,
    bookId: bookId,
  );
}

void main() {
  late AppDatabase db;
  late AutoBookBatchStore store;

  setUp(() {
    db = openTestDatabase();
    store = AutoBookBatchStore(AppMetaRepository(db));
  });

  tearDown(() async {
    await db.close();
  });

  test('按账本取：拿回本项目的那批，不被别的账本顶掉', () async {
    // remember 是「后写的排前面」：先 book1 再 book2，最近一批就该是 book2 的
    await store.remember(_batch('b1-1', bookId: 'book1', atMs: 100));
    await store.remember(_batch('b2-1', bookId: 'book2', atMs: 200));

    // 最近一批是 book2 的，但查 book1 时要拿到 book1 自己那批
    expect((await store.latest())!.batchId, 'b2-1');
    expect((await store.latestFor('book1'))!.batchId, 'b1-1');
    expect((await store.latestFor('book2'))!.batchId, 'b2-1');
  });

  test('当前账本没有批次 → null（宁可空着，也不挂别人账本的流水）', () async {
    await store.remember(_batch('b1-1', bookId: 'book1'));
    expect(await store.latestFor('book3'), isNull);
  });

  test('旧批次没有 bookId → 不当作任何账本的兜底', () async {
    // v0.8.10 之前的 JSON 没有 bookId 字段
    await store.remember(_batch('legacy', atMs: 50));
    expect(await store.latestFor('book1'), isNull);
    // 但没选账本时（null）仍然照旧取最近一批
    expect((await store.latestFor(null))!.batchId, 'legacy');
  });
}
