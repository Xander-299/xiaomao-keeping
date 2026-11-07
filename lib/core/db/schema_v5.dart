/// schema v5：把流水指纹唯一性从「全局」收紧到「账本内」。
///
/// 背景（Batch A / A1）：v1 的 `idx_tx_fingerprint` 只按 `fingerprint` 唯一，
/// 同一笔外部账单先导入账本 A、再导入账本 B 会被误判为重复。
/// v5 改为 `(book_id, fingerprint)` 部分唯一索引：
/// - 同一账本内同一指纹仍然只能有一条未删流水；
/// - 不同账本允许相同指纹；
/// - 仍只约束 `deleted_at IS NULL`，删掉后可以重新导入。
///
/// 迁移策略：**只替换索引，不重建表、不改任何既有行**。
/// 旧库的全局索引在升级时先 `DROP` 再按新列组合创建。
library;

/// v5 的全部索引 DDL（ADR-9：索引一律原始 SQL）。
const kSchemaV5Indexes = <String>[
  'DROP INDEX IF EXISTS idx_tx_fingerprint',
  'CREATE UNIQUE INDEX IF NOT EXISTS idx_tx_fingerprint '
      'ON transactions(book_id, fingerprint) '
      'WHERE fingerprint IS NOT NULL AND deleted_at IS NULL',
];
