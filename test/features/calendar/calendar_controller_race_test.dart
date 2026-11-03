/// Batch B / B1：日历选中日异步竞态。
///
/// 用可控的 TransactionRepository 延迟 A/B 两天的查询，验证：
/// - B 先返回、A 后返回时，最终仍是 B；
/// - 过期请求失败不能覆盖当前日期的成功状态；
/// - 快速切日过程中 loading 不闪回旧内容；
/// - provider dispose 后迟到结果不写 state。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/data/providers/book_providers.dart';
import 'package:yanxin/data/providers/database.dart';
import 'package:yanxin/data/repositories/account_repository.dart';
import 'package:yanxin/data/repositories/book_repository.dart';
import 'package:yanxin/data/repositories/category_repository.dart';
import 'package:yanxin/data/repositories/transaction_repository.dart';
import 'package:yanxin/features/calendar/application/calendar_controller.dart';

import '../../helpers/test_database.dart';

class _ControlledTxRepo extends TransactionRepository {
  _ControlledTxRepo(super.db);

  final Map<int, List<Completer<List<TxRow>>>> pending =
      <int, List<Completer<List<TxRow>>>>{};
  final List<int> rangeCalls = <int>[];

  @override
  Future<List<TxRow>> listByRange(
    String bookId,
    int startMs,
    int endMs,
  ) {
    rangeCalls.add(startMs);
    final Completer<List<TxRow>> completer = Completer<List<TxRow>>();
    pending.putIfAbsent(startMs, () => <Completer<List<TxRow>>>[]).add(completer);
    return completer.future;
  }

  @override
  Future<List<TxRow>> listByMonth(String bookId, int year, int month) async {
    // 月聚合不是 B1 的竞态点，直接给空数据。
    return const <TxRow>[];
  }

  Completer<List<TxRow>> take(int startMs) {
    final List<Completer<List<TxRow>>>? list = pending[startMs];
    if (list == null || list.isEmpty) {
      throw StateError('没有待完成的 listByRange 请求：$startMs');
    }
    return list.removeAt(0);
  }
}

Future<void> _settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> _waitForPending(_ControlledTxRepo repo, int startMs) async {
  for (var i = 0; i < 30; i++) {
    final List<Completer<List<TxRow>>>? list = repo.pending[startMs];
    if (list != null && list.isNotEmpty) return;
    await Future<void>.delayed(Duration.zero);
  }
  throw StateError('等待 listByRange 请求超时：$startMs');
}

void main() {
  late AppDatabase db;
  late _ControlledTxRepo repo;
  late ProviderContainer container;
  late TxRow rowA;
  late TxRow rowB;
  late int dayA;
  late int dayB;
  late int startA;
  late int startB;

  setUp(() async {
    db = openTestDatabase();
    addTearDown(db.close);
    final Book book = await BookRepository(db).ensureDefaultBook();
    final Account account = (await AccountRepository(db).listByBook(book.id)).first;
    final Category category =
        (await CategoryRepository(db).listByBook(book.id, kind: 'expense')).first;
    final DateTime now = DateTime.now();
    final List<int> days = <int>[1, 2, 3, 4]
        .where((int d) => d != now.day)
        .take(2)
        .toList();
    dayA = days[0];
    dayB = days[1];
    startA = DateTime(now.year, now.month, dayA).millisecondsSinceEpoch;
    startB = DateTime(now.year, now.month, dayB).millisecondsSinceEpoch;

    final TransactionRepository baseRepo = TransactionRepository(db);
    rowA = await baseRepo.create(
      bookId: book.id,
      accountId: account.id,
      categoryId: category.id,
      type: 'expense',
      amountCents: 111,
      occurredAt: DateTime(now.year, now.month, dayA, 10).millisecondsSinceEpoch,
      note: 'A 日',
    );
    rowB = await baseRepo.create(
      bookId: book.id,
      accountId: account.id,
      categoryId: category.id,
      type: 'expense',
      amountCents: 222,
      occurredAt: DateTime(now.year, now.month, dayB, 10).millisecondsSinceEpoch,
      note: 'B 日',
    );

    repo = _ControlledTxRepo(db);
    container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        transactionRepositoryProvider.overrideWithValue(repo),
      ],
    );
    addTearDown(container.dispose);

    await container.read(activeBookIdProvider.future);
    container.read(calendarProvider); // 触发 build 的首次 refresh
    await _settle();

    // 吃掉初始「今天」请求，避免它干扰后续 A/B。
    final DateTime today = DateTime.now();
    final int todayStart =
        DateTime(today.year, today.month, today.day).millisecondsSinceEpoch;
    await _waitForPending(repo, todayStart);
    repo.take(todayStart).complete(const <TxRow>[]);
    await _settle();
  });

  test('A 后选 B：B 先返回、A 后返回，最终仍是 B', () async {
    final CalendarController controller = container.read(calendarProvider.notifier);

    controller.selectDay(dayA);
    await _waitForPending(repo, startA);
    expect(container.read(calendarProvider).selectedDate.day, dayA);
    expect(container.read(calendarProvider).day.isLoading, isTrue);

    controller.selectDay(dayB);
    await _waitForPending(repo, startB);
    expect(container.read(calendarProvider).selectedDate.day, dayB);
    expect(container.read(calendarProvider).day.isLoading, isTrue);

    // B 先回来
    repo.take(startB).complete(<TxRow>[rowB]);
    await _settle();
    expect(container.read(calendarProvider).day.value?.single.id, rowB.id);

    // A 后回来：不得覆盖 B
    repo.take(startA).complete(<TxRow>[rowA]);
    await _settle();
    final CalendarState state = container.read(calendarProvider);
    expect(state.selectedDate.day, dayB);
    expect(state.day.value?.single.id, rowB.id);
  });

  test('过期请求失败不能覆盖当前日期的成功状态', () async {
    final CalendarController controller = container.read(calendarProvider.notifier);

    controller.selectDay(dayA);
    await _waitForPending(repo, startA);
    controller.selectDay(dayB);
    await _waitForPending(repo, startB);

    repo.take(startB).complete(<TxRow>[rowB]);
    await _settle();
    expect(container.read(calendarProvider).day.hasError, isFalse);

    // A 失败时已经过期 → 不能把 B 的 data 改成 error
    repo.take(startA).completeError(StateError('stale A failure'));
    await _settle();

    final CalendarState state = container.read(calendarProvider);
    expect(state.selectedDate.day, dayB);
    expect(state.day.hasError, isFalse);
    expect(state.day.value?.single.id, rowB.id);
  });

  test('快速切日：当前请求失败时进入 error，而不是回退到旧日期数据', () async {
    final CalendarController controller = container.read(calendarProvider.notifier);

    controller.selectDay(dayA);
    await _waitForPending(repo, startA);
    controller.selectDay(dayB);
    await _waitForPending(repo, startB);

    repo.take(startB).completeError(StateError('B failed'));
    await _settle();

    final CalendarState state = container.read(calendarProvider);
    expect(state.selectedDate.day, dayB);
    expect(state.day.hasError, isTrue);
  });

  test('provider dispose 后迟到的请求不写 state，也不产生未处理异常', () async {
    final CalendarController controller = container.read(calendarProvider.notifier);
    controller.selectDay(dayA);
    await _waitForPending(repo, startA);

    container.dispose();
    repo.take(startA).complete(<TxRow>[rowA]);
    await _settle();

    // 能执行到这里且没有异常/Zone error，说明 _disposed 守卫生效。
    expect(true, isTrue);
  });
}
