/// 账本相关的应用状态：当前账本 id（持久化）+ 当前账本 + 账本列表。
///
/// 对应旧栈 `stores/book.js`（BUG-016 的修复点：当前账本 id 落库，杀进程不丢）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/database.dart';
import 'database.dart';

/// 当前账本 id。首次启动没有值时建默认账本并落库。
final activeBookIdProvider = AsyncNotifierProvider<ActiveBookIdController, String?>(
  ActiveBookIdController.new,
);

class ActiveBookIdController extends AsyncNotifier<String?> {
  /// 本次 build 时「库里**还完全没有**主账本记录」→ 这份 App 数据是本机第一次使用。
  ///
  /// 用途：新手引导（F7.14）**只在全新安装**时自动弹 —— 老用户（含从旧包覆盖安装上来的）
  /// 不弹。`active_book_id` 自 F1 起每次冷启动都会落库，老用户必有值，是「是否新装」的唯一真源。
  ///
  /// ⚠️ 判据是「读到的瞬间 `getActiveBookId()` 返回 null」，**不是**「本次走了
  /// `ensureDefaultBook` 分支」—— 后者在「当前账本被软删」等边缘情况也会命中
  /// （那时 `active_book_id` 其实有值），会把老用户误判成新装。
  bool isFreshInstall = false;

  @override
  Future<String?> build() async {
    final repo = ref.watch(bookRepositoryProvider);
    final String? email = await repo.activeAccountEmail();
    final bool savedAccounts = await repo.hasSavedAccounts();
    // 空态（P6.5 D3）：曾经登录过、当前又没登录 → 不建账本，等用户选账号
    if (email == null && savedAccounts) {
      isFreshInstall = false;
      return null;
    }
    final String? stored = await repo.getActiveBookIdFor(email);
    isFreshInstall = stored == null && !savedAccounts;
    if (stored != null) {
      final visible = await repo.listVisible();
      if (visible.any((Book b) => b.id == stored)) return stored;
    }
    final Book? book = await repo.ensureVisibleBook();
    if (book == null) return null;
    await repo.setActiveBookIdFor(email, book.id);
    return book.id;
  }

  /// 切换当前账本（持久化到**当前账号**的槽）。
  Future<void> select(String id) async {
    final repo = ref.read(bookRepositoryProvider);
    await repo.setActiveBookIdFor(await repo.activeAccountEmail(), id);
    state = AsyncData(id);
  }
}

/// 当前账本对象。切换账本时自动刷新。
final currentBookProvider = FutureProvider<Book?>((ref) async {
  final id = await ref.watch(activeBookIdProvider.future);
  if (id == null) return null;
  return ref.watch(bookRepositoryProvider).getById(id);
});

/// 当前**可见**的未删除账本（P6.5：按账号过滤；未登录空态时为空列表）。
final bookListProvider = FutureProvider<List<Book>>(
  (ref) => ref.watch(bookRepositoryProvider).listVisible(),
);
