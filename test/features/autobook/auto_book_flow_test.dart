/// 自动记账编排单测（F7.15 SPEC §3.1 / §3.6 / §3.7）。
///
/// 用内存 drift 库 + **假通道**（`FakeAutoBookBridge`）跑通：
/// drain → 解析 → 入账 → 记批次 → 回执通知 / 指纹去重 / 整批撤销 / 冷启动撤销命令。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/data/providers/book_providers.dart';
import 'package:yanxin/data/providers/database.dart';
import 'package:yanxin/data/repositories/account_repository.dart';
import 'package:yanxin/data/repositories/app_meta_repository.dart';
import 'package:yanxin/data/repositories/book_repository.dart';
import 'package:yanxin/data/repositories/category_repository.dart';
import 'package:yanxin/data/repositories/transaction_repository.dart';
import 'package:yanxin/features/autobook/application/auto_book_controller.dart';
import 'package:yanxin/features/autobook/application/auto_book_notice.dart';
import 'package:yanxin/features/autobook/data/auto_book_batches.dart';
import 'package:yanxin/features/autobook/data/auto_book_bridge.dart';
import 'package:yanxin/features/autobook/data/auto_book_diagnostics.dart';

import '../../helpers/test_database.dart';

const int _t = 1759200000000;

/// Kotlin 侧落盘的 JSONL 行（与 `AutoBookQueue.enqueueNotification` 的字段一致）。
String _notify(String text, {int at = _t, String pkg = 'com.tencent.mm'}) =>
    '{"kind":"notification","pkg":"$pkg","title":"微信支付",'
    '"text":"$text","bigText":"","subText":"","postTimeMs":$at}';

String _share(String text, {int at = _t}) =>
    '{"kind":"share","text":"$text","postTimeMs":$at}';

/// 假通道：把「落盘队列 + 命令 + 通知」三件事都换成内存，绕开原生链路。
class FakeAutoBookBridge extends AutoBookBridge {
  List<String> queue = <String>[];
  String? command;
  bool listener = true;
  bool notifications = true;

  /// 被回写的原始行（每次调用记一条）—— 用于断言「临时失败不丢账」。
  final List<List<String>> restored = <List<String>>[];

  /// 发过的回执（count / amountText / batchId / lines）。
  final List<Map<String, Object?>> receipts = <Map<String, Object?>>[];
  int cancelCount = 0;
  int openSettingsCount = 0;

  @override
  bool get supported => true;

  @override
  Future<List<String>> drainQueue() async {
    final List<String> out = queue;
    queue = <String>[];
    return out;
  }

  /// 补抓时「通知栏里现存的」原始行 —— 由用例预置，`catchUp()` 会把它注入队列。
  List<String> catchUpRows = <String>[];

  /// 补抓被调用的次数（用于断言「补抓排在取队列之前」）。
  int catchUpCount = 0;

  @override
  Future<int> catchUp() async {
    catchUpCount++;
    final int n = catchUpRows.length;
    if (n == 0) return 0;
    queue = <String>[...catchUpRows, ...queue];
    catchUpRows = <String>[];
    return n;
  }

  @override
  Future<void> restoreQueue(List<String> lines) async {
    restored.add(List<String>.of(lines));
    queue = <String>[...lines, ...queue];
  }

  @override
  Future<String?> takeCommand() async {
    final String? out = command;
    command = null;
    return out;
  }

  @override
  Future<bool> listenerEnabled() async => listener;

  @override
  Future<bool> notificationsAllowed() async => notifications;

  @override
  Future<int> pendingCount() async => queue.length;

  @override
  Future<void> showReceipt({
    required int count,
    required String amountText,
    required String batchId,
    List<String> lines = const <String>[],
  }) async {
    receipts.add(<String, Object?>{
      'count': count,
      'amountText': amountText,
      'batchId': batchId,
      'lines': lines,
    });
  }

  @override
  Future<void> cancelReceipt() async {
    cancelCount++;
  }

  @override
  Future<void> openListenerSettings() async {
    openSettingsCount++;
  }

  @override
  Future<void> requestNotificationPermission() async {}

  @override
  Future<void> openAppNotificationSettings() async {}
}

/// 批量撤销在「软删完成、批次记录摘除」这一步失败，用来验证事务回滚。
class _ThrowingForgetStore extends AutoBookBatchStore {
  // 父类字段名是私有的 `_meta`，跨库不能写成 super 参数；这里保留显式转发。
  // ignore: use_super_parameters
  _ThrowingForgetStore(AppMetaRepository meta) : super(meta);

  @override
  Future<void> forget(String batchId) async {
    throw StateError('forget failed for $batchId');
  }
}

void main() {
  late AppDatabase db;
  late FakeAutoBookBridge bridge;
  late ProviderContainer container;
  late String bookId;

  setUp(() async {
    db = openTestDatabase();
    bridge = FakeAutoBookBridge();
    // Riverpod 3 未公开导出 Override 类型 → 不能写类型注解
    container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        autoBookBridgeProvider.overrideWithValue(bridge),
      ],
    );
    addTearDown(container.dispose);
    bookId = (await container.read(activeBookIdProvider.future))!;
  });

  tearDown(() async {
    // 「写库失败」用例会先 close 一次 → 这里再 close 需容错
    try {
      await db.close();
    } catch (_) {}
  });

  Future<List<TxRow>> visibleTxs() =>
      TransactionRepository(db).listByBook(bookId);

  AutoBookController controller() =>
      container.read(autoBookControllerProvider);

  Future<String> createTx({String? book, String note = '撤销测试'}) async {
    final String targetBook = book ?? bookId;
    final Account account =
        (await AccountRepository(db).listByBook(targetBook)).first;
    final Category category =
        (await CategoryRepository(db).listByBook(targetBook, kind: 'expense'))
            .first;
    final TxRow tx = await TransactionRepository(db).create(
      bookId: targetBook,
      accountId: account.id,
      categoryId: category.id,
      type: 'expense',
      amountCents: 1200,
      occurredAt: _t,
      note: note,
    );
    return tx.id;
  }

  AutoBookBatch batchOf(
    String batchId,
    List<String> txIds, {
    String? book,
  }) => AutoBookBatch(
    batchId: batchId,
    txIds: txIds,
    count: txIds.length,
    totalCents: 1200 * txIds.length,
    atMs: _t,
    bookId: book ?? bookId,
  );

  test('首次 drain：2 笔入账 + 记批次 + 发回执通知', () async {
    bridge.queue = <String>[
      _notify('你已成功支付 12.00元', at: _t),
      _notify('你已成功支付 8.00元', at: _t + 60000),
    ];

    final AutoBookDrainResult r = await controller().drain();

    expect(r.imported, 2);
    expect(r.dropped, 0);
    expect(r.batch, isNotNull);
    expect(r.batch!.count, 2);
    expect(r.batch!.totalCents, 2000);
    expect(r.batch!.txIds.length, 2);

    // 提示条（会话内）已出现
    expect(container.read(autoBookNoticeProvider)?.batchId, r.batch!.batchId);
    // 批次已落到 schema_meta KV（冷启动撤销要靠它）
    expect(
      (await container.read(autoBookBatchStoreProvider).latest())?.batchId,
      r.batch!.batchId,
    );
    // 回执通知：正文与批次 id
    expect(bridge.receipts.length, 1);
    expect(bridge.receipts.single['count'], 2);
    expect(bridge.receipts.single['amountText'], '20.00');
    expect(bridge.receipts.single['batchId'], r.batch!.batchId);

    // 真的落库了：2 笔，来源是 notify_wechat，备注退化为主通道名
    final List<TxRow> txs = await visibleTxs();
    expect(txs.length, 2);
    expect(txs.every((TxRow t) => t.source == 'notify_wechat'), isTrue);
    expect(txs.every((TxRow t) => t.type == 'expense'), isTrue);
    expect(txs.map((TxRow t) => t.note).toSet(), <String>{'微信支付'});
  });

  test('同一批再 drain 一次：指纹去重 → 零新增、不发新回执', () async {
    final List<String> lines = <String>[
      _notify('你已成功支付 12.00元', at: _t),
      _notify('你已成功支付 8.00元', at: _t + 60000),
    ];
    bridge.queue = List<String>.of(lines);
    await controller().drain();
    expect((await visibleTxs()).length, 2);

    // 队列残留 / 通知被监听两次：同样的行再来一遍
    bridge.queue = List<String>.of(lines);
    final AutoBookDrainResult again = await controller().drain();

    expect(again.imported, 0);
    expect(again.duplicates, 2);
    expect((await visibleTxs()).length, 2); // 零重复入账
    expect(bridge.receipts.length, 1); // 仍是第一次那条回执
    expect(bridge.cancelCount, 1); // 没有新增 → 收起旧提示
  });

  test('非消费通知 / 坏行：只丢弃，不入账、不发回执', () async {
    bridge.queue = <String>[
      _notify('微信转账给张三 50.00元'),
      _notify('你收到一个红包 6.66元'),
      'not-json-at-all',
    ];

    final AutoBookDrainResult r = await controller().drain();

    expect(r.imported, 0);
    expect(r.dropped, 3);
    expect(await visibleTxs(), isEmpty);
    expect(bridge.receipts, isEmpty);
    expect(bridge.cancelCount, 1);
  });

  test('健康度检查：微信 + 支付宝两条通知分别进各自账户', () async {
    bridge.queue = <String>[
      _notify('你已成功支付 12.00元', at: _t),
      _notify(
        '付款成功 8.00元',
        at: _t + 1000,
        pkg: 'com.eg.android.AlipayGphone',
      ),
    ];

    final AutoBookDrainResult r = await controller().drain();
    expect(r.imported, 2);

    final List<TxRow> txs = await visibleTxs();
    final Set<String> sources =
        txs.map((TxRow t) => t.source).toSet();
    expect(sources, <String>{'notify_wechat', 'notify_alipay'});

    // 两个账户各自独立存在且名称为平台名
    final List<Account> accounts =
        await AccountRepository(db).listByBook(bookId);
    final Set<String> names = accounts.map((Account a) => a.name).toSet();
    expect(names.contains('微信'), isTrue);
    expect(names.contains('支付宝'), isTrue);
  });

  test('撤销本批：软删整批 + 摘除批次记录（同一批撤不了第二次）', () async {
    bridge.queue = <String>[
      _notify('你已成功支付 12.00元', at: _t),
      _notify('你已成功支付 8.00元', at: _t + 1000),
    ];
    final AutoBookDrainResult r = await controller().drain();
    final String batchId = r.batch!.batchId;

    final int deleted =
        await container.read(autoBookNoticeProvider.notifier).undo(batchId);

    expect(deleted, 2);
    expect(r.batch!.bookId, bookId); // Batch A / A3：批次记录带账本
    expect(await visibleTxs(), isEmpty); // 软删（deleted_at 非空 → 列表里消失）
    expect(container.read(autoBookNoticeProvider), isNull); // 提示条收起
    expect(await container.read(autoBookBatchStoreProvider).latest(), isNull);

    // 再撤一次：0 笔，且不能假装成功
    expect(
      await container.read(autoBookNoticeProvider.notifier).undo(batchId),
      0,
    );
  });

  test('批量撤销中途失败 → 流水与批次记录一起回滚', () async {
    final String id1 = await createTx(note: '回滚1');
    final String id2 = await createTx(note: '回滚2');
    final AutoBookBatch batch = batchOf('rollback', <String>[id1, id2]);

    final _ThrowingForgetStore failingStore =
        _ThrowingForgetStore(AppMetaRepository(db));
    final ProviderContainer failing = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        autoBookBatchStoreProvider.overrideWithValue(failingStore),
      ],
    );
    addTearDown(failing.dispose);
    await failingStore.remember(batch);

    await expectLater(
      failing.read(autoBookNoticeProvider.notifier).undo(batch.batchId),
      throwsA(isA<StateError>()),
    );

    // 软删被回滚：两笔仍然活跃
    expect(
      (await TransactionRepository(db).listByBook(bookId)).length,
      2,
    );
    // 批次记录也还在，用户可重试
    expect(await failingStore.byId(batch.batchId), isNotNull);
  });

  test('撤销一个批次不影响其他批次或其他账本', () async {
    final String idA1 = await createTx(note: 'A1');
    final String idA2 = await createTx(note: 'A2');
    final Book bookB = await BookRepository(db).create(name: '第二账本');
    final String idB = await createTx(book: bookB.id, note: 'B1');

    final AutoBookBatchStore store =
        container.read(autoBookBatchStoreProvider);
    final AutoBookBatch batchA =
        batchOf('batch-a', <String>[idA1, idA2]);
    final AutoBookBatch batchB =
        batchOf('batch-b', <String>[idB], book: bookB.id);
    await store.remember(batchA);
    await store.remember(batchB);

    final int deleted =
        await container.read(autoBookNoticeProvider.notifier).undo('batch-a');

    expect(deleted, 2);
    expect(await TransactionRepository(db).listByBook(bookId), isEmpty);
    // 另一个账本的流水、批次都不受影响
    expect(
      (await TransactionRepository(db).listByBook(bookB.id)).length,
      1,
    );
    expect(await store.byId('batch-b'), isNotNull);
  });

  test('批次包含其他账本流水 → 拒绝撤销并整体回滚', () async {
    final String idA = await createTx(note: 'A');
    final Book bookB = await BookRepository(db).create(name: '第二账本');
    final String idB = await createTx(book: bookB.id, note: 'B');

    final AutoBookBatchStore store =
        container.read(autoBookBatchStoreProvider);
    final AutoBookBatch mixed =
        batchOf('mixed', <String>[idA, idB], book: bookId);
    await store.remember(mixed);

    await expectLater(
      container.read(autoBookNoticeProvider.notifier).undo('mixed'),
      throwsA(isA<StateError>()),
    );

    // 两边都保持活跃；批次记录保留，避免静默丢账
    expect((await TransactionRepository(db).listByBook(bookId)).length, 1);
    expect(
      (await TransactionRepository(db).listByBook(bookB.id)).length,
      1,
    );
    expect(await store.byId('mixed'), isNotNull);
  });

  test('冷启动撤销：命令文件里的 batchId 在下次 drain 时执行', () async {
    bridge.queue = <String>[_notify('你已成功支付 12.00元', at: _t)];
    final AutoBookDrainResult r = await controller().drain();
    expect((await visibleTxs()).length, 1);

    // 用户杀掉 App → 点通知栏「撤销」→ 命令落盘，App 冷启动
    bridge.command = '{"action":"undo","batchId":"${r.batch!.batchId}"}';
    final AutoBookDrainResult after = await controller().drain();

    expect(after.undone, 1);
    expect(await visibleTxs(), isEmpty);
    expect(bridge.cancelCount, greaterThanOrEqualTo(1));
  });

  test('旧批次 JSON 没有 bookId：按流水反推账本后仍能撤销', () async {
    final String id = await createTx(note: '旧批次');
    final AutoBookBatchStore store =
        container.read(autoBookBatchStoreProvider);
    // 不带 bookId，模拟 A3 之前落库的批次 JSON
    await store.remember(
      AutoBookBatch(
        batchId: 'legacy',
        txIds: <String>[id],
        count: 1,
        totalCents: 1200,
        atMs: _t,
      ),
    );

    expect(
      await container.read(autoBookNoticeProvider.notifier).undo('legacy'),
      1,
    );
    expect(await visibleTxs(), isEmpty);
    expect(await store.byId('legacy'), isNull);
  });

  test('批次记录最多留 3 批，最旧的被裁撤', () async {
    final AutoBookBatchStore store =
        container.read(autoBookBatchStoreProvider);
    for (var i = 0; i < 4; i++) {
      await store.remember(
        AutoBookBatch(
          batchId: 'b$i',
          txIds: <String>['t$i'],
          count: 1,
          totalCents: 100 * (i + 1),
          atMs: _t + i,
        ),
      );
    }
    final List<AutoBookBatch> all = await store.readAll();
    expect(all.length, kAutoBookBatchKeep);
    expect(all.first.batchId, 'b3'); // 最近在前
    expect(all.any((AutoBookBatch b) => b.batchId == 'b0'), isFalse);
    expect(await store.byId('b0'), isNull);
  });

  test('分享文本走同一条链路，source = share', () async {
    bridge.queue = <String>[_share('微信支付 你已成功支付 12.00元')];

    final AutoBookDrainResult r = await controller().drain();
    expect(r.imported, 1);

    final List<TxRow> txs = await visibleTxs();
    expect(txs.single.source, 'share');
    expect(txs.single.amountCents, 1200);
  });

  test('空队列 + 无命令：drain 是彻底的 no-op', () async {
    final AutoBookDrainResult r = await controller().drain();
    expect(r.touched, isFalse);
    expect(bridge.cancelCount, 0);
    expect(bridge.receipts, isEmpty);
  });

  test('写库失败 → 原始行回写队列，不丢账（等下次重试）', () async {
    bridge.queue = <String>[_notify('你已成功支付 12.00元', at: _t)];
    // 制造写库失败（账本/流水查询都会抛）
    await db.close();

    final AutoBookDrainResult r = await controller().drain();

    expect(r.imported, 0);
    expect(bridge.restored, hasLength(1)); // 回写过一次
    expect(bridge.restored.single, hasLength(1)); // 内容就是原始行
    expect(bridge.queue, hasLength(1)); // 队列里还有，没被清掉
    expect(bridge.receipts, isEmpty); // 没入账就不发回执
  });

  test('全部解析不出（非消费通知）→ 丢弃而不回写（否则会无限重试）', () async {
    bridge.queue = <String>[
      _notify('微信转账给张三 50.00元'),
      _notify('你收到一个红包 6.66元'),
    ];

    final AutoBookDrainResult r = await controller().drain();

    expect(r.imported, 0);
    expect(r.dropped, 2);
    expect(bridge.restored, isEmpty); // 永久性失败 → 不回写
    expect(bridge.queue, isEmpty);
  });

  test('最近一次检查结果落 KV（跨启动可查）', () async {
    bridge.queue = <String>[_notify('你已成功支付 12.00元', at: _t)];
    await controller().drain();

    final String? raw = await container
        .read(appMetaRepositoryProvider)
        .get(kAutoBookLastRunKey);
    final AutoBookLastRun? run = AutoBookLastRun.parse(raw);

    expect(run, isNotNull);
    expect(run!.imported, 1);
    expect(run.summary, contains('新入账 1 笔'));
  });

  test('空 drain 不覆盖「上次检查」的成功结果（走查修复的回归守卫）', () async {
    // 先成功入账一笔 → last_run 记下「新入账 1 笔」
    bridge.queue = <String>[_notify('你已成功支付 12.00元', at: _t)];
    await controller().drain();

    // 再跑一次空 drain（模拟冷启动 / 从后台回来的例行检查）
    final AutoBookDrainResult again = await controller().drain();
    expect(again.touched, isFalse);

    final String? raw = await container
        .read(appMetaRepositoryProvider)
        .get(kAutoBookLastRunKey);
    final AutoBookLastRun? run = AutoBookLastRun.parse(raw);

    // 真机走查现场：入账 7 秒后的空 drain 曾把这里写成 imported:0，
    // 于是页面「上次检查」变成「没有新的支付通知」，盖住刚发生的成功。
    expect(run!.imported, 1);
    expect(run.summary, contains('新入账 1 笔'));
  });

  test('空队列但有撤销命令：「上次检查」仍要记撤销（有效动作不丢）', () async {
    bridge.queue = <String>[_notify('你已成功支付 12.00元', at: _t)];
    final AutoBookDrainResult r = await controller().drain();

    // 队列已空，只剩一条撤销命令 —— 这是「有动作」的 drain，不能当 no-op
    bridge.command = '{"action":"undo","batchId":"${r.batch!.batchId}"}';
    final AutoBookDrainResult after = await controller().drain();
    expect(after.undone, 1);

    final String? raw = await container
        .read(appMetaRepositoryProvider)
        .get(kAutoBookLastRunKey);
    final AutoBookLastRun? run = AutoBookLastRun.parse(raw);

    expect(run!.undone, 1);
    expect(run.summary, contains('撤销 1 笔'));
  });

  test('软忽略：真实回执含「优惠」仍入账（走查修复的回归守卫）', () async {
    bridge.queue = <String>[_notify('你已付款成功，优惠 0.50元，实付 12.00元', at: _t)];

    final AutoBookDrainResult r = await controller().drain();

    expect(r.imported, 1);
    expect((await visibleTxs()).single.amountCents, 1200);
  });

  test('补抓：服务未连接期间错过的支付通知仍能入账（真机事故回归守卫）', () async {
    // 2026-10-08 Redmi K50 事故：支付宝付款通知 22:29:37 发布，监听服务 22:31:28 才连上
    // → `onNotificationPosted` 是推送式回调，系统不会补发 → 那笔支付永久丢失。
    // 修法 = 每次 drain 前先补抓通知栏里仍存在的通知。
    bridge.queue = <String>[]; // 实时回调一条都没接到
    bridge.catchUpRows = <String>[_notify('你已成功支付 12.00元', at: _t)];

    final AutoBookDrainResult r = await controller().drain();

    expect(bridge.catchUpCount, 1);
    expect(r.caughtUp, 1);
    // 补抓必须排在取队列之前，否则这一批要等到下一次 drain 才入账
    expect(r.imported, 1);
    expect((await visibleTxs()).single.amountCents, 1200);
  });

  test('补抓没捞到东西：仍不覆盖「上次检查」的成功结果', () async {
    bridge.queue = <String>[_notify('你已成功支付 12.00元', at: _t)];
    await controller().drain();

    // 第二次 drain：补抓跑了，但通知栏里已没有可捞的通知 → 队列仍空
    bridge.catchUpRows = <String>[];
    final AutoBookDrainResult again = await controller().drain();
    expect(bridge.catchUpCount, 2); // 每轮 drain 都会补抓一次
    expect(again.touched, isFalse);

    final String? raw = await container
        .read(appMetaRepositoryProvider)
        .get(kAutoBookLastRunKey);
    final AutoBookLastRun? run = AutoBookLastRun.parse(raw);

    // 若补抓把「已入过队的通知」重复入队，这里会被写成 duplicates:1 / imported:0，
    // 页面「上次检查」就会从「新入账 1 笔」变成「重复 1 笔」。
    expect(run!.imported, 1);
    expect(run.summary, contains('新入账 1 笔'));
  });
}
