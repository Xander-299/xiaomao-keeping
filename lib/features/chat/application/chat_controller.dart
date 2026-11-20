/// 聊天会话：**文字问账本 + 图片记账**合并成一条流（首页入口的唯一落点）。
///
/// 一条消息只有两种来源：
/// ```
/// 用户文字 ──► answerQuestion()（复用 M1：意图 → 查账本 → 模板回答）
/// 用户图片 ──► OCR（端上 ML Kit）→ parseReceipt() → 待确认账单卡 → 用户确认 → writeReceipt()
/// ```
/// 三条硬规矩（沿用 HANDOFF 不变量）：
/// 1. **写库只有一处**：图片记账仍走 `TransactionRepository.importTransaction(source:'screenshot')`，
///    指纹幂等；OCR / 解析层永远不碰 DB；
/// 2. **未确认绝不写库**：识别出来的只是「待确认卡片」，用户点确认才落库；
/// 3. **写后刷新只调 `refreshAfterWrite`**（不复制第五份）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/database.dart';
import '../../../core/providers/after_write.dart';
import '../../../core/utils/money.dart';
import '../../../data/providers/account_providers.dart';
import '../../../data/providers/book_providers.dart';
import '../../../data/providers/category_providers.dart';
import '../../../data/providers/database.dart';
import '../../assistant/application/finance_answer.dart';
import '../../assistant/application/finance_intent.dart';
import '../../receipt/application/receipt_draft.dart';
import '../../receipt/application/receipt_write.dart';
import '../../receipt/data/mlkit_ocr_engine.dart';
import '../../receipt/data/ocr_engine.dart';
import '../../receipt/data/receipt_parse.dart';
import 'answer_question.dart';

/// 一条聊天消息。
sealed class ChatMessage {
  const ChatMessage();
}

/// 用户发的一句话。
final class UserTextMessage extends ChatMessage {
  const UserTextMessage(this.text);
  final String text;
}

/// 用户发的一条图片消息（本地路径）。
final class UserImageMessage extends ChatMessage {
  const UserImageMessage(this.path);
  final String path;
}

/// 系统的文字答复（问答卡）。
final class AnswerMessage extends ChatMessage {
  const AnswerMessage(this.answer);
  final FinanceAnswer answer;
}

/// 系统的一句提示 / 错误（不是账本数据，纯文案）。
final class NoticeMessage extends ChatMessage {
  const NoticeMessage(this.text, {this.tone = NoticeTone.info});
  final String text;
  final NoticeTone tone;
}

enum NoticeTone { info, warn, good }

/// 识别出的「待确认账单」。
///
/// 只有用户在卡片上点「确认记账」才会落库；[done]/[resultText] 是确认后的终态。
final class ReceiptMessage extends ChatMessage {
  const ReceiptMessage({
    required this.imagePath,
    required this.draft,
    required this.type,
    required this.amountCents,
    required this.categoryId,
    required this.accountId,
    required this.occurredAtMs,
    required this.note,
    this.similar = const <TxRow>[],
    this.saving = false,
    this.done = false,
    this.resultText,
    this.error,
  });

  final String imagePath;
  final ReceiptDraft draft;

  /// 卡片上的**当前值**（用户可能已经改过）。
  final String type;
  final int amountCents;
  final String? categoryId;
  final String? accountId;
  final int occurredAtMs;
  final String note;

  /// 疑似同一笔（只提示，不阻断）。
  final List<TxRow> similar;

  final bool saving;
  final bool done;

  /// 终态文案（`已记账 · 支出 ¥22.98 · 2026-10-24 16:28` / `这笔之前已经记过了`）。
  final String? resultText;
  final String? error;

  /// 阻断项（支付失败 / 金额缺失 …）—— 有阻断时不允许确认。
  List<ReceiptIssue> get blockers => draft.blockers;

  ReceiptMessage copyWith({
    String? type,
    int? amountCents,
    String? categoryId,
    String? accountId,
    int? occurredAtMs,
    String? note,
    bool? saving,
    bool? done,
    String? resultText,
    String? error,
  }) => ReceiptMessage(
    imagePath: imagePath,
    draft: draft,
    type: type ?? this.type,
    amountCents: amountCents ?? this.amountCents,
    categoryId: categoryId ?? this.categoryId,
    accountId: accountId ?? this.accountId,
    occurredAtMs: occurredAtMs ?? this.occurredAtMs,
    note: note ?? this.note,
    similar: similar,
    saving: saving ?? this.saving,
    done: done ?? this.done,
    resultText: resultText ?? this.resultText,
    error: error ?? this.error,
  );
}

/// 会话状态。
class ChatState {
  const ChatState({this.messages = const <ChatMessage>[], this.busy = false});

  final List<ChatMessage> messages;

  /// 有请求在飞（查账本 / OCR / 写库）。
  final bool busy;

  ChatState copyWith({List<ChatMessage>? messages, bool? busy}) =>
      ChatState(messages: messages ?? this.messages, busy: busy ?? this.busy);
}

/// 会话。
final chatProvider = NotifierProvider<ChatController, ChatState>(
  ChatController.new,
);

class ChatController extends Notifier<ChatState> {
  /// 上一句问到的区间 / 方向（多轮追问用）。会话级状态，不放进消息列表。
  AssistantContext _context = const AssistantContext();

  @override
  ChatState build() => const ChatState();

  int get _nowMs => DateTime.now().millisecondsSinceEpoch;

  // ────────────────────────────── 文字 ──────────────────────────────

  /// 问一句。[nowMs] 仅供测试固定"现在"。
  Future<void> ask(String raw, {int? nowMs}) async {
    final String question = raw.trim();
    if (question.isEmpty || state.busy) return;

    state = ChatState(
      messages: <ChatMessage>[
        ...state.messages,
        UserTextMessage(question),
        const _Pending(),
      ],
      busy: true,
    );

    try {
      final ({FinanceAnswer answer, AssistantContext context}) result =
          await answerQuestion(
            ref,
            question,
            nowMs: nowMs ?? _nowMs,
            context: _context,
          );
      _context = result.context;
      _settle(AnswerMessage(result.answer));
    } catch (_) {
      _settle(const NoticeMessage('查询失败了，稍后再试一次。', tone: NoticeTone.warn));
    }
  }

  // ────────────────────────────── 图片 ──────────────────────────────

  /// 发一张图（已经在本地缓存里的路径）。
  Future<void> sendImage(String path, {int? nowMs}) async {
    if (path.isEmpty || state.busy) return;
    final int now = nowMs ?? _nowMs;
    state = ChatState(
      messages: <ChatMessage>[
        ..._withoutPending(),
        UserImageMessage(path),
        const _Pending(),
      ],
      busy: true,
    );

    try {
      final OcrResult ocr = await ref.read(ocrEngineProvider).recognize(path);
      final ReceiptDraft draft = parseReceipt(ocr.lineTexts, nowMs: now);

      // ⚠️ 必须 await：`ref.read(provider)` 拿到的是 AsyncValue，首次读时 value 还是 null，
      // 直接 `.value ?? []` 会让分类/账户永远是空的 → 卡片上「请选择分类」，用户点确认永远失败。
      final List<Category> categories = await ref.read(
        categoriesProvider.future,
      );
      final List<Account> accounts = await ref.read(accountsProvider.future);
      final String type = draft.direction.value ?? 'expense';
      final String? categoryId = matchCategoryId(
        categories,
        type,
        draft.categoryName.value,
      );
      final String? accountId =
          matchAccountId(accounts, draft.paymentType) ??
          (accounts.isEmpty ? null : accounts.first.id);
      final int amount = draft.amountCents.value ?? 0;

      // 疑似重复：只提示，不阻断（判据与截图页一致：同方向同金额 ±15 分钟）
      List<TxRow> similar = const <TxRow>[];
      final String? bookId = await ref.read(activeBookIdProvider.future);
      if (bookId != null && amount > 0) {
        similar = await findSimilarReceipts(
          ref.read(transactionRepositoryProvider),
          bookId: bookId,
          type: type,
          amountCents: amount,
          occurredAtMs: draft.occurredAtMs.value ?? now,
        );
      }

      _settle(
        ReceiptMessage(
          imagePath: path,
          draft: draft,
          type: type,
          amountCents: amount,
          categoryId: categoryId,
          accountId: accountId,
          occurredAtMs: draft.occurredAtMs.value ?? now,
          note: draft.merchant.value ?? '',
          similar: similar,
        ),
      );
    } on OcrFailure catch (e) {
      _settle(NoticeMessage(e.userMessage, tone: NoticeTone.warn));
    } catch (_) {
      _settle(const NoticeMessage('识别失败了，换一张清楚的截图再试。', tone: NoticeTone.warn));
    }
  }

  // ────────────────────────────── 确认写库 ──────────────────────────────

  /// 用户点了「确认记账」。参数都是**卡片上当前显示的值**。
  Future<void> confirmReceipt(
    int index, {
    required String type,
    required int amountCents,
    required String? categoryId,
    required String? accountId,
    required int occurredAtMs,
    required String note,
  }) async {
    final ChatMessage? message = _at(index);
    if (message is! ReceiptMessage || message.done || message.saving) return;

    if (amountCents <= 0) {
      _replace(index, message.copyWith(error: '金额要大于 0'));
      return;
    }
    if (categoryId == null || categoryId.isEmpty) {
      _replace(index, message.copyWith(error: '先选一个分类'));
      return;
    }
    if (accountId == null || accountId.isEmpty) {
      _replace(index, message.copyWith(error: '账本里还没有账户'));
      return;
    }

    final String? bookId = await ref.read(activeBookIdProvider.future);
    if (bookId == null) {
      _replace(index, message.copyWith(error: '账本还没就绪，稍后再试'));
      return;
    }

    _replace(index, message.copyWith(saving: true, error: null));

    final ReceiptWriteResult result = await writeReceipt(
      ref.read(transactionRepositoryProvider),
      bookId: bookId,
      accountId: accountId,
      type: type,
      amountCents: amountCents,
      occurredAtMs: occurredAtMs,
      categoryId: categoryId,
      note: note.trim(),
      textHash: message.draft.textHash,
    );

    final ChatMessage? fresh = _at(index);
    if (fresh is! ReceiptMessage) return;

    switch (result) {
      case ReceiptWritten(tx: final TxRow tx):
        _replace(
          index,
          fresh.copyWith(
            saving: false,
            done: true,
            type: tx.type,
            amountCents: tx.amountCents,
            occurredAtMs: tx.occurredAt,
            note: tx.note,
            resultText:
                '已记账 · ${tx.type == 'income' ? '收入' : '支出'} ¥${centsToYuan(tx.amountCents)}'
                ' · ${_formatDateTime(tx.occurredAt)}',
          ),
        );
        refreshAfterWrite(ref);
      case ReceiptDuplicate(existing: final TxRow tx):
        _replace(
          index,
          fresh.copyWith(
            saving: false,
            done: true,
            resultText: '这笔之前已经记过了 · ¥${centsToYuan(tx.amountCents)}，没有重复入账',
          ),
        );
      case ReceiptWriteFailed(message: final String message):
        _replace(index, fresh.copyWith(saving: false, error: message));
    }
  }

  /// 取消这一单（只从会话里移除卡片，不写库）。
  void dismissReceipt(int index) {
    final ChatMessage? message = _at(index);
    if (message is! ReceiptMessage || message.done) return;
    _replace(index, const NoticeMessage('已取消，这一笔没有记账。'));
  }

  /// 清空会话。
  void clear() => state = const ChatState();

  // ────────────────────────────── 内部 ──────────────────────────────

  /// 占位消息：UI 显示「处理中…」，不入最终列表（每次 settle 前剔除）。
  ChatMessage? _at(int index) => index >= 0 && index < state.messages.length
      ? state.messages[index]
      : null;

  List<ChatMessage> _withoutPending() =>
      state.messages.where((ChatMessage m) => m is! _Pending).toList();

  /// 用 [message] 替换掉末尾的 pending 占位。
  void _settle(ChatMessage message) {
    final List<ChatMessage> kept = _withoutPending()..add(message);
    state = ChatState(messages: kept, busy: false);
  }

  void _replace(int index, ChatMessage message) {
    final List<ChatMessage> next = <ChatMessage>[...state.messages];
    if (index < 0 || index >= next.length) return;
    next[index] = message;
    state = ChatState(messages: next, busy: state.busy);
  }
}

/// 处理中的占位（不展示内容，只用来占位 / 判断 busy）。内部使用。
final class _Pending extends ChatMessage {
  const _Pending();
}

String _formatDateTime(int ms) {
  final DateTime d = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}

/// 分类名 → id（同名「其他」有两个，必须按 kind 收窄）。
///
/// 与截图页 / 导入页口径一致：先精确命中 → 再退「其他」→ 最后退该方向第一个。
String? matchCategoryId(List<Category> categories, String kind, String? name) {
  final List<Category> sameKind = <Category>[
    for (final Category c in categories)
      if (c.kind == kind) c,
  ];
  if (sameKind.isEmpty) return null;
  if (name == null) return sameKind.first.id;
  for (final Category c in sameKind) {
    if (c.name == name) return c.id;
  }
  for (final Category c in sameKind) {
    if (c.name == '其他') return c.id;
  }
  return sameKind.first.id;
}

/// 支付方式 → 账户 id（找不到返回 null，由调用方退回第一个账户）。
String? matchAccountId(List<Account> accounts, String? paymentType) {
  if (paymentType == null) return null;
  for (final Account a in accounts) {
    if (a.type == paymentType) return a.id;
  }
  return null;
}
