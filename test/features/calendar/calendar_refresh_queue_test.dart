/// Batch C / C1：CalendarController.refresh 的 busy 合并语义。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/data/providers/book_providers.dart';
import 'package:yanxin/data/providers/database.dart';
import 'package:yanxin/data/repositories/book_repository.dart';
import 'package:yanxin/data/repositories/transaction_repository.dart';
import 'package:yanxin/features/calendar/application/calendar_controller.dart';

import '../../helpers/test_database.dart';

class _QueuedTxRepo extends TransactionRepository {
  _QueuedTxRepo(super.db);

  final List<Completer<List<TxRow>>> day = <Completer<List<TxRow>>>[];
  final List<Completer<List<TxRow>>> month = <Completer<List<TxRow>>>[];
  int dayCalls = 0;
  int monthCalls = 0;

  @override
  Future<List<TxRow>> listByRange(String bookId, int startMs, int endMs) {
    dayCalls++;
    final Completer<List<TxRow>> c = Completer<List<TxRow>>();
    day.add(c);
    return c.future;
  }

  @override
  Future<List<TxRow>> listByMonth(String bookId, int year, int month) {
    monthCalls++;
    final Completer<List<TxRow>> c = Completer<List<TxRow>>();
    this.month.add(c);
    return c.future;
  }

  Completer<List<TxRow>> takeDay() => day.removeAt(0);
  Completer<List<TxRow>> takeMonth() => month.removeAt(0);
}

Future<void> _settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> _waitFor(bool Function() predicate) async {
  for (var i = 0; i < 50; i++) {
    if (predicate()) return;
    await Future<void>.delayed(Duration.zero);
  }
  throw StateError('等待条件超时');
}

void main() {
  late AppDatabase db;
  late _QueuedTxRepo repo;
  late ProviderContainer container;
  late CalendarController controller;

  setUp(() async {
    db = openTestDatabase();
    addTearDown(db.close);
    await BookRepository(db).ensureDefaultBook();
    repo = _QueuedTxRepo(db);
    container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        transactionRepositoryProvider.overrideWithValue(repo),
      ],
    );
    addTearDown(() {
      try {
        container.dispose();
      } catch (_) {
        // dispose 用例会主动 dispose；tearDown 再 dispose 不应让用例失败。
      }
    });
    await container.read(activeBookIdProvider.future);
    controller = container.read(calendarProvider.notifier);

    // 吃掉 build 触发的首次 refresh。
    await _waitFor(() => repo.dayCalls >= 1);
    repo.takeDay().complete(const <TxRow>[]);
    await _waitFor(() => repo.monthCalls >= 1);
    repo.takeMonth().complete(const <TxRow>[]);
    await _settle();
  });

  test('refresh A 执行期间触发 refresh B：B 不丢，A 完成后补跑一次', () async {
    final Future<void> a = controller.refresh();
    await _waitFor(() => repo.dayCalls == 2);

    final Future<void> b = controller.refresh();
    await b; // busy 时立即返回，但请求已标记 pending
    expect(repo.dayCalls, 2, reason: 'B 不能在 A 未完成时并发启动');

    repo.takeDay().complete(const <TxRow>[]);
    await _waitFor(() => repo.monthCalls == 2);
    repo.takeMonth().complete(const <TxRow>[]);
    await a;

    // A 的 finally 合并补跑 B
    await _waitFor(() => repo.dayCalls == 3);
    repo.takeDay().complete(const <TxRow>[]);
    await _waitFor(() => repo.monthCalls == 3);
    repo.takeMonth().complete(const <TxRow>[]);
    await _settle();

    expect(repo.dayCalls, 3);
    expect(repo.monthCalls, 3);
  });

  test('多个 pending refresh 合并成一次，不产生无限请求', () async {
    final Future<void> a = controller.refresh();
    await _waitFor(() => repo.dayCalls == 2);

    await controller.refresh();
    await controller.refresh();
    await controller.refresh();
    expect(repo.dayCalls, 2);

    repo.takeDay().complete(const <TxRow>[]);
    await _waitFor(() => repo.monthCalls == 2);
    repo.takeMonth().complete(const <TxRow>[]);
    await a;

    await _waitFor(() => repo.dayCalls == 3);
    repo.takeDay().complete(const <TxRow>[]);
    await _waitFor(() => repo.monthCalls == 3);
    repo.takeMonth().complete(const <TxRow>[]);
    await _settle();

    expect(repo.dayCalls, 3, reason: '3 次 pending 只补跑 1 次');
    expect(repo.monthCalls, 3);
  });

  test('dispose 后 pending refresh 不再启动，迟到结果不写 state', () async {
    final Future<void> a = controller.refresh();
    await _waitFor(() => repo.dayCalls == 2);
    await controller.refresh(); // 标记 pending

    container.dispose();
    repo.takeDay().complete(const <TxRow>[]);
    await a;
    await _settle();

    expect(repo.monthCalls, 1, reason: 'dispose 后不应再走第二次 refresh 的 month');
    expect(repo.dayCalls, 2);
  });
}
