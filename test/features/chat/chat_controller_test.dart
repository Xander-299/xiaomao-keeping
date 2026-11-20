/// 聊天流的编排测试：真实内存库 + 真实仓储 + 真实纯函数 + 假 OCR 引擎。
///
/// 覆盖两类输入：
/// - 文字：问账本 → 答案卡（数字与账本一致）、未设预算不编数、不认识给示例、空输入不入会话；
/// - 图片：识别 → 待确认卡 → 用户确认才写库；同图二次确认不重复；支付失败**不写库**。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/data/providers/database.dart';
import 'package:yanxin/data/repositories/account_repository.dart';
import 'package:yanxin/data/repositories/book_repository.dart';
import 'package:yanxin/data/repositories/category_repository.dart';
import 'package:yanxin/data/repositories/transaction_repository.dart';
import 'package:yanxin/features/assistant/application/finance_answer.dart';
import 'package:yanxin/features/chat/application/chat_controller.dart';
import 'package:yanxin/features/receipt/data/mlkit_ocr_engine.dart';
import 'package:yanxin/features/receipt/data/ocr_engine.dart';

import '../../helpers/category_seed.dart';
import '../../helpers/test_database.dart';

final int _nowMs = DateTime(2026, 10, 25, 15).millisecondsSinceEpoch;

/// 假 OCR：把预设文本当识别结果（不碰平台通道）。
class _FakeOcr implements OcrEngine {
  _FakeOcr(this.lines);

  final List<String> lines;

  @override
  Future<OcrResult> recognize(String imagePath) async => OcrResult(
    lines: <OcrLine>[for (final String l in lines) OcrLine(text: l)],
    text: lines.join('\n'),
    elapsedMs: 12,
  );

  @override
  Future<void> dispose() async {}
}

class _ThrowingOcr implements OcrEngine {
  @override
  Future<OcrResult> recognize(String imagePath) async =>
      throw const OcrFailure('unsupported_platform', 'MissingPluginException');

  @override
  Future<void> dispose() async {}
}

const List<String> _wechatLines = <String>[
  '微信支付',
  '支付成功',
  '商户全称：星巴克咖啡',
  '支付金额 ¥36.00',
  '支付时间 2026-10-23 14:05:33',
];

const List<String> _failedLines = <String>[
  '微信支付',
  '支付失败',
  '商户全称：某某商店',
  '金额 ¥5.00',
];

Future<({AppDatabase db, ProviderContainer container, Book book})> _seed({
  OcrEngine? ocr,
}) async {
  final AppDatabase db = openTestDatabase();
  final Book book = await BookRepository(db).ensureDefaultBook();
  final CategoryRepository cats = CategoryRepository(db);
  // v4 起同级不允许重名：预置里已经有「餐饮 / 工资」，这里取现成的（没有才建）
  final Category food = await ensureCategory(cats, book.id, '餐饮');
  final Category salary = await ensureCategory(cats, book.id, '工资', kind: 'income');
  final Account acc = await AccountRepository(db).create(bookId: book.id, name: '现金');
  await TransactionRepository(db).create(
    bookId: book.id,
    accountId: acc.id,
    type: 'expense',
    amountCents: 128050,
    occurredAt: DateTime(2026, 10, 3, 12).millisecondsSinceEpoch,
    categoryId: food.id,
    note: '午饭',
  );
  await TransactionRepository(db).create(
    bookId: book.id,
    accountId: acc.id,
    type: 'expense',
    amountCents: 98000,
    occurredAt: DateTime(2026, 10, 8, 12).millisecondsSinceEpoch,
    categoryId: food.id,
    note: '外套',
  );
  await TransactionRepository(db).create(
    bookId: book.id,
    accountId: acc.id,
    type: 'income',
    amountCents: 1200000,
    occurredAt: DateTime(2026, 10, 1, 9).millisecondsSinceEpoch,
    categoryId: salary.id,
    note: '工资',
  );

  final ProviderContainer container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      if (ocr != null) ocrEngineProvider.overrideWithValue(ocr),
    ],
  );
  return (db: db, container: container, book: book);
}

ChatController _ctrl(ProviderContainer c) => c.read(chatProvider.notifier);

void main() {
  group('多轮追问（同一会话里继承上一句区间）', () {
    test('「这个月花了多少」→「那餐饮呢」：第二句沿用本月', () async {
      final r = await _seed();
      addTearDown(r.db.close);
      addTearDown(r.container.dispose);

      await _ctrl(r.container).ask('这个月花了多少', nowMs: _nowMs);
      await _ctrl(r.container).ask('那餐饮呢', nowMs: _nowMs);

      final List<ChatMessage> msgs = r.container.read(chatProvider).messages;
      expect(msgs.length, 4); // 两问两答
      final AnswerMessage second = msgs.last as AnswerMessage;
      expect(second.answer.title, contains('2026年10月'), reason: '没带时间词也要沿用本月');
      expect(second.answer.title, contains('餐饮'));
    });

    test('先问「上周」再问「那购物呢」：区间要跟上周，不是本月', () async {
      final r = await _seed();
      addTearDown(r.db.close);
      addTearDown(r.container.dispose);

      await _ctrl(r.container).ask('上周花了多少', nowMs: _nowMs);
      await _ctrl(r.container).ask('那购物呢', nowMs: _nowMs);

      final AnswerMessage second =
          r.container.read(chatProvider).messages.last as AnswerMessage;
      // 2026-10-25 是周日 → 上周 = 10-12 ~ 10-19
      expect(second.answer.narrative, contains('10月12日–10月18日'));
    });

    test('不认识的问题不破坏上下文：之后「那餐饮呢」仍能接上', () async {
      final r = await _seed();
      addTearDown(r.db.close);
      addTearDown(r.container.dispose);

      await _ctrl(r.container).ask('这个月花了多少', nowMs: _nowMs);
      await _ctrl(r.container).ask('帮我写首诗', nowMs: _nowMs);
      await _ctrl(r.container).ask('那餐饮呢', nowMs: _nowMs);

      final AnswerMessage last =
          r.container.read(chatProvider).messages.last as AnswerMessage;
      expect(last.answer.title, contains('2026年10月'));
    });
  });

  group('文字', () {
    test('问「这个月花了多少」→ 答案里的金额与账本一致', () async {
      final r = await _seed();
      addTearDown(r.db.close);
      addTearDown(r.container.dispose);

      await _ctrl(r.container).ask('这个月花了多少', nowMs: _nowMs);
      final ChatState state = r.container.read(chatProvider);
      expect(state.busy, isFalse);
      expect(state.messages.length, 2); // 用户 + 回答
      expect(state.messages.first, isA<UserTextMessage>());
      final AnswerMessage answer = state.messages.last as AnswerMessage;
      expect(answer.answer.headline, '¥2,260.50');
      expect(answer.answer.title, contains('2026年10月'));
    });

    test('问「这个月餐饮花了多少」→ 分类口径', () async {
      final r = await _seed();
      addTearDown(r.db.close);
      addTearDown(r.container.dispose);

      await _ctrl(r.container).ask('这个月餐饮花了多少', nowMs: _nowMs);
      final AnswerMessage answer =
          r.container.read(chatProvider).messages.last as AnswerMessage;
      expect(answer.answer.headline, '¥2,260.50'); // 两笔都归到餐饮
    });

    test('未设预算：明说没设，不编数字', () async {
      final r = await _seed();
      addTearDown(r.db.close);
      addTearDown(r.container.dispose);

      await _ctrl(r.container).ask('本月预算还剩多少', nowMs: _nowMs);
      final AnswerMessage answer =
          r.container.read(chatProvider).messages.last as AnswerMessage;
      expect(answer.answer.narrative, contains('还没设预算'));
      expect(answer.answer.headline, isNull);
    });

    test('不认识的问法：给示例，不报错', () async {
      final r = await _seed();
      addTearDown(r.db.close);
      addTearDown(r.container.dispose);

      await _ctrl(r.container).ask('帮我写一首诗', nowMs: _nowMs);
      final ChatMessage last = r.container.read(chatProvider).messages.last;
      expect(last, isA<AnswerMessage>());
      expect((last as AnswerMessage).answer.suggestions, kExampleQuestions);
    });

    test('空问题不入会话', () async {
      final r = await _seed();
      addTearDown(r.db.close);
      addTearDown(r.container.dispose);

      await _ctrl(r.container).ask('   ', nowMs: _nowMs);
      expect(r.container.read(chatProvider).messages, isEmpty);
    });
  });

  group('图片', () {
    test('识别成功 → 待确认卡（不写库）→ 确认后写库', () async {
      final r = await _seed(ocr: _FakeOcr(_wechatLines));
      addTearDown(r.db.close);
      addTearDown(r.container.dispose);

      await _ctrl(r.container).sendImage('/tmp/a.png', nowMs: _nowMs);
      final ChatState afterOcr = r.container.read(chatProvider);
      expect(afterOcr.messages.whereType<UserImageMessage>().length, 1);
      final ReceiptMessage card = afterOcr.messages.whereType<ReceiptMessage>().single;
      expect(card.amountCents, 3600);
      expect(card.type, 'expense');
      expect(card.done, isFalse);

      expect(
        (await TransactionRepository(r.db).listByBook(r.book.id)).length,
        3,
        reason: '识别出来只是草稿，确认前不许写库',
      );

      await _ctrl(r.container).confirmReceipt(
        afterOcr.messages.indexOf(card),
        type: card.type,
        amountCents: card.amountCents,
        categoryId: card.categoryId,
        accountId: card.accountId,
        occurredAtMs: card.occurredAtMs,
        note: card.note,
      );

      final ReceiptMessage done =
          r.container.read(chatProvider).messages.whereType<ReceiptMessage>().single;
      expect(done.done, isTrue);
      expect(done.resultText, contains('已记账'));
      final List<TxRow> rows = await TransactionRepository(r.db).listByBook(r.book.id);
      expect(rows.length, 4);
      expect(rows.first.source, 'screenshot');
      expect(rows.first.amountCents, 3600);
    });

    test('同一张图再发一次 → 指纹命中，不重复入账', () async {
      final r = await _seed(ocr: _FakeOcr(_wechatLines));
      addTearDown(r.db.close);
      addTearDown(r.container.dispose);

      await _ctrl(r.container).sendImage('/tmp/a.png', nowMs: _nowMs);
      ReceiptMessage card =
          r.container.read(chatProvider).messages.whereType<ReceiptMessage>().single;
      await _ctrl(r.container).confirmReceipt(
        r.container.read(chatProvider).messages.indexOf(card),
        type: card.type,
        amountCents: card.amountCents,
        categoryId: card.categoryId,
        accountId: card.accountId,
        occurredAtMs: card.occurredAtMs,
        note: card.note,
      );

      await _ctrl(r.container).sendImage('/tmp/a.png', nowMs: _nowMs);
      final List<ReceiptMessage> cards =
          r.container.read(chatProvider).messages.whereType<ReceiptMessage>().toList();
      card = cards.last;
      await _ctrl(r.container).confirmReceipt(
        r.container.read(chatProvider).messages.indexOf(card),
        type: card.type,
        amountCents: card.amountCents,
        categoryId: card.categoryId,
        accountId: card.accountId,
        occurredAtMs: card.occurredAtMs,
        note: card.note,
      );

      final ReceiptMessage last =
          r.container.read(chatProvider).messages.whereType<ReceiptMessage>().last;
      expect(last.resultText, contains('之前已经记过了'));
      expect((await TransactionRepository(r.db).listByBook(r.book.id)).length, 4);
    });

    test('支付失败的截图：卡片被阻断，没有写库入口', () async {
      final r = await _seed(ocr: _FakeOcr(_failedLines));
      addTearDown(r.db.close);
      addTearDown(r.container.dispose);

      await _ctrl(r.container).sendImage('/tmp/b.png', nowMs: _nowMs);
      final ReceiptMessage card =
          r.container.read(chatProvider).messages.whereType<ReceiptMessage>().single;
      expect(card.blockers, isNotEmpty);
      expect(card.amountCents, 500);
      expect((await TransactionRepository(r.db).listByBook(r.book.id)).length, 3);
    });

    test('OCR 通道不可用：给可读提示，不进待确认卡', () async {
      final r = await _seed(ocr: _ThrowingOcr());
      addTearDown(r.db.close);
      addTearDown(r.container.dispose);

      await _ctrl(r.container).sendImage('/tmp/c.png', nowMs: _nowMs);
      final ChatState state = r.container.read(chatProvider);
      expect(state.messages.whereType<ReceiptMessage>(), isEmpty);
      final NoticeMessage notice = state.messages.whereType<NoticeMessage>().single;
      expect(notice.text, contains('端上文字识别'));
      expect(notice.tone, NoticeTone.warn);
    });
  });

  test('clear 清空会话', () async {
    final r = await _seed();
    addTearDown(r.db.close);
    addTearDown(r.container.dispose);

    await _ctrl(r.container).ask('这个月花了多少', nowMs: _nowMs);
    expect(r.container.read(chatProvider).messages, isNotEmpty);
    _ctrl(r.container).clear();
    expect(r.container.read(chatProvider).messages, isEmpty);
  });
}
