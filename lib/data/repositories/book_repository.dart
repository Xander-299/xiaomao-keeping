/// 账本仓储。新建账本时自动带 1 个默认现金账户 + 预置分类组。
///
/// 对应旧栈 `src/repositories/book-repository.js`，含当前账本 id 持久化
/// （旧栈 BUG-016：此前只存内存，切账本后回首页被重置、杀进程后丢失）。
library;

import 'package:drift/drift.dart';

import '../../core/constants/preset.dart';
import '../../core/db/database.dart';
import '../../core/providers/account_scope.dart';
import '../../core/utils/id.dart';
import 'account_repository.dart';
import 'category_repository.dart';

/// active_book_id 在 schema_meta 里的键名（未登录 / 本机账本用这个）。
const kActiveBookKey = 'active_book_id';

/// 多账号（P6.5）下每个账号各自的当前账本键：`active_book_id:<email>`。
String activeBookKeyFor(String email) => '$kActiveBookKey:${email.trim()}';

class BookRepository {
  BookRepository(this._db);

  final AppDatabase _db;

  /// 新建账本（事务内连带建默认账户 + 预置分类）。
  Future<Book> create({
    required String name,
    String type = 'personal',
    String currency = defaultCurrency,
    String icon = '',
    String color = '',
    int sortOrder = 0,
    String? ownerId,
    String? id,
  }) {
    if (name.isEmpty) {
      throw ArgumentError.value(name, 'name', 'book.name 为必填');
    }
    final bookId = id ?? uuidV4();
    final now = DateTime.now().millisecondsSinceEpoch;
    return _db.transaction(() async {
      final book = await _db
          .into(_db.books)
          .insertReturning(
            BooksCompanion.insert(
              id: bookId,
              name: name,
              createdAt: now,
              updatedAt: now,
              type: Value(type),
              currency: Value(currency),
              icon: Value(icon),
              color: Value(color),
              sortOrder: Value(sortOrder),
              ownerId: Value(ownerId),
            ),
          );

      final accounts = AccountRepository(_db);
      final categories = CategoryRepository(_db);
      await accounts.create(
        bookId: bookId,
        name: defaultAccountName,
        type: 'cash',
      );
      // 预置分类（含二级）只有一处写入逻辑 —— 复用幂等补齐，避免「新建账本」和
      // 「老账本补装」两套代码各写一遍、慢慢长歪（2026-10-29 加二级时踩到的重复点）。
      await categories.ensurePresets(bookId);
      return book;
    });
  }

  /// 按 id 取单个账本；[includeDeleted]=true 时可取已软删行。
  Future<Book?> getById(String id, {bool includeDeleted = false}) {
    final q = _db.select(_db.books)..where((t) => t.id.equals(id));
    if (!includeDeleted) {
      q.where((t) => t.deletedAt.isNull());
    }
    return q.getSingleOrNull();
  }

  /// 列出未删除账本。
  Future<List<Book>> listAll() {
    return (_db.select(_db.books)
          ..where((t) => t.deletedAt.isNull())
          ..orderBy([
            (t) => OrderingTerm.asc(t.sortOrder),
            (t) => OrderingTerm.asc(t.createdAt),
          ]))
        .get();
  }

  /// 局部更新。目标不存在或已删则抛错。
  Future<Book> update(
    String id, {
    String? name,
    String? type,
    String? currency,
    String? icon,
    String? color,
    int? sortOrder,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final changed = await (_db.update(_db.books)
          ..where((t) => t.id.equals(id) & t.deletedAt.isNull()))
        .write(
          BooksCompanion(
            name: name == null ? const Value.absent() : Value(name),
            type: type == null ? const Value.absent() : Value(type),
            currency: currency == null ? const Value.absent() : Value(currency),
            icon: icon == null ? const Value.absent() : Value(icon),
            color: color == null ? const Value.absent() : Value(color),
            sortOrder: sortOrder == null
                ? const Value.absent()
                : Value(sortOrder),
            updatedAt: Value(now),
            dirty: const Value(1),
          ),
        );
    if (changed == 0) {
      throw StateError('books 未找到可更新的记录：$id');
    }
    final fresh = await getById(id);
    return fresh!;
  }

  /// 软删除。返回受影响行数。
  Future<int> softDelete(String id) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return (_db.update(_db.books)
          ..where((t) => t.id.equals(id) & t.deletedAt.isNull()))
        .write(
          BooksCompanion(
            deletedAt: Value(now),
            updatedAt: Value(now),
            dirty: const Value(1),
          ),
        );
  }

  /// 持久化的当前账本 id，从未设置过则 null。
  Future<String?> getActiveBookId() async {
    final row = await (_db.select(_db.schemaMeta)
          ..where((t) => t.key.equals(kActiveBookKey)))
        .getSingleOrNull();
    return row?.value;
  }

  /// 写当前账本 id（已存在则覆盖，走参数绑定，不做字符串拼 SQL）。
  Future<void> setActiveBookId(String id) {
    return _db
        .into(_db.schemaMeta)
        .insertOnConflictUpdate(
          SchemaMetaCompanion.insert(key: kActiveBookKey, value: id),
        );
  }

  /// 确保存在一个默认账本（首次启动 / 恢复备份 / 导入等入口调用）。
  ///
  /// P6.5 起跟随**当前账号**：已登录就建带 `ownerId` 的账本，未登录就建本机账本。
  /// 空态（退出后仍有保存账号）时调用方仍需要一个 Book 兜底 —— 这种入口只可能出现在
  /// 已登录流程里，若真的走到这里就当作本机账本建（不会被同步推走，因为未登录不收集上行）。
  Future<Book> ensureDefaultBook() async {
    final Book? visible = await ensureVisibleBook();
    if (visible != null) return visible;
    return create(name: defaultBookName, icon: '📒', color: '#3b82f6');
  }

  // ── 多账号（P6.5）：账本可见性全部按 ownerId 收窄 ───────────────────

  Future<String?> _meta(String key) async {
    final row = await (_db.select(_db.schemaMeta)
          ..where((t) => t.key.equals(key)))
        .getSingleOrNull();
    return row?.value;
  }

  Future<void> _setMeta(String key, String value) =>
      _db.into(_db.schemaMeta).insertOnConflictUpdate(
            SchemaMetaCompanion.insert(key: key, value: value),
          );

  Future<void> _deleteMeta(String key) =>
      (_db.delete(_db.schemaMeta)..where((t) => t.key.equals(key))).go();

  /// 当前账号邮箱（未登录 = null）。
  Future<String?> activeAccountEmail() async {
    final String? raw = await _meta(kActiveAccountKey);
    final String? email = raw?.trim();
    return (email == null || email.isEmpty) ? null : email;
  }

  /// 这台手机**曾经登录过账号**吗？（决定「未登录时是否空态」的唯一依据）
  Future<bool> hasSavedAccounts() async =>
      parseSavedAccounts(await _meta(kSyncAccountsKey)).isNotEmpty;

  /// 当前可见的账本：
  /// - 已登录 → 该账号名下的账本；
  /// - 从未登录 → `ownerId IS NULL` 的本机账本（保持本地优先）；
  /// - 曾经登录但已退出 → **空**（要求选账号，见 SPEC-P6.5 D3）。
  Future<List<Book>> listVisible() async {
    final String? email = await activeAccountEmail();
    if (email != null) {
      return (_db.select(_db.books)
            ..where((t) => t.ownerId.equals(email) & t.deletedAt.isNull())
            ..orderBy(<OrderClauseGenerator<$BooksTable>>[
              (t) => OrderingTerm.asc(t.sortOrder),
              (t) => OrderingTerm.asc(t.createdAt),
            ]))
          .get();
    }
    if (await hasSavedAccounts()) return const <Book>[];
    return (_db.select(_db.books)
          ..where((t) => t.ownerId.isNull() & t.deletedAt.isNull())
          ..orderBy(<OrderClauseGenerator<$BooksTable>>[
            (t) => OrderingTerm.asc(t.sortOrder),
            (t) => OrderingTerm.asc(t.createdAt),
          ]))
        .get();
  }

  /// 可见范围里的第一个账本；没有就按当前范围建一个。
  ///
  /// - 已登录 → 建带 `ownerId = email` 的默认账本；
  /// - 从未登录 → 建 `ownerId = NULL` 的本机账本；
  /// - 空态（退出后有保存账号）→ **返回 null，不建**（否则会凭空冒出本机账本）。
  Future<Book?> ensureVisibleBook() async {
    List<Book> existing = await listVisible();
    if (existing.isNotEmpty) return existing.first;
    final String? email = await activeAccountEmail();
    if (email == null && await hasSavedAccounts()) return null;
    if (email != null) {
      // 先尝试把「本机账本」认领过来，再考虑新建 —— 否则账本 provider 可能抢在
      // 登录绑定之前跑，凭空建出一本空账本、老数据被留在 ownerId 为空的那本里
      //（真机 v0.8.9 → P6.5 升级时踩到）。
      if (await bindUnownedBooksTo(email) > 0) {
        existing = await listVisible();
        if (existing.isNotEmpty) return existing.first;
      }
    }
    return create(
      name: defaultBookName,
      icon: '📒',
      color: '#3b82f6',
      ownerId: email,
    );
  }

  /// 当前账号各自的 `active_book_id`；未登录仍用旧键（保持本机账本行为）。
  Future<String?> getActiveBookIdFor(String? email) => _meta(
    email == null || email.isEmpty ? kActiveBookKey : activeBookKeyFor(email),
  );

  Future<void> setActiveBookIdFor(String? email, String id) => _setMeta(
    email == null || email.isEmpty ? kActiveBookKey : activeBookKeyFor(email),
    id,
  );

  Future<void> clearActiveBookIdFor(String email) =>
      _deleteMeta(activeBookKeyFor(email));

  /// 首次登录时把「本机账本」（ownerId 为空）绑给该账号。
  ///
  /// **只在该账号名下还没有任何账本时才绑** —— 否则第二个账号登录会把
  /// 第一个账号的账本抢走（SPEC-P6.5 §6 风险 2）。
  /// 返回绑定的条数。
  Future<int> bindUnownedBooksTo(String email) async {
    final String normalized = email.trim();
    final int owned = await (_db.select(_db.books)
          ..where((t) => t.ownerId.equals(normalized) & t.deletedAt.isNull()))
        .get()
        .then((List<Book> rows) => rows.length);
    if (owned > 0) return 0;
    final int now = DateTime.now().millisecondsSinceEpoch;
    return (_db.update(_db.books)..where((t) => t.ownerId.isNull())).write(
      BooksCompanion(
        ownerId: Value(normalized),
        updatedAt: Value(now),
        dirty: const Value(1),
      ),
    );
  }
}
