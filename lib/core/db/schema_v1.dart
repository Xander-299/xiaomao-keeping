/// schema v1 中 drift 声明式建表**无法表达**的部分：带 DESC 的索引与部分索引。
///
/// ADR-8：DDL 与旧库 schema v1 完全一致。drift 的 `@TableIndex` 不支持
/// `DESC` 排序，也不支持部分索引的 `WHERE` 子句，因此索引一律在 `onCreate`
/// 里执行本文件的原始 SQL（与旧栈 `src/db/schema.js` 逐字一致）。
/// 表结构本身由 drift 从 `tables.dart` 生成，字段顺序/类型/默认值与旧 DDL 对齐。
library;

/// v1 的全部索引 DDL（顺序与旧栈 SCHEMA_V1_SQL 一致）。
const kSchemaV1Indexes = <String>[
  'CREATE INDEX IF NOT EXISTS idx_accounts_book ON accounts(book_id, deleted_at)',
  'CREATE INDEX IF NOT EXISTS idx_categories_book_kind ON categories(book_id, kind, deleted_at)',
  'CREATE INDEX IF NOT EXISTS idx_tx_book_occurred ON transactions(book_id, occurred_at DESC)',
  'CREATE INDEX IF NOT EXISTS idx_tx_book_category ON transactions(book_id, category_id)',
  'CREATE INDEX IF NOT EXISTS idx_tx_account ON transactions(account_id)',
  'CREATE INDEX IF NOT EXISTS idx_tx_dirty ON transactions(dirty)',
  // 指纹唯一：同一笔外部交易只能入一次账。仅约束未删除行，
  // 这样用户删掉一笔后可以重新导入同一笔，不会被永久锁死。
  //
  // ⚠️ 这是 v1 的历史 DDL，唯一范围是**全局**。schema v5 起由
  // `schema_v5.dart` 替换成 `(book_id, fingerprint)`，见 Batch A / A1。
  'CREATE UNIQUE INDEX IF NOT EXISTS idx_tx_fingerprint '
      'ON transactions(fingerprint) '
      'WHERE fingerprint IS NOT NULL AND deleted_at IS NULL',
];
