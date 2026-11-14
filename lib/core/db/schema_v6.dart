/// schema v6：新增「同步冲突存档」表（P6.4b D2）。
///
/// 迁移策略：**只加表 + 一条索引**，不动任何既有表、不改任何既有行。
/// 老库升级后 `sync_conflicts` 为空（历史冲突没有留档，也无法凭空造出来）。
library;

/// v6 的索引 DDL（ADR-9：索引一律原始 SQL）。
///
/// 清理按时间 FIFO（保留最近 50 条），所以按 `created_at` 建一条普通索引。
const kSchemaV6Indexes = <String>[
  'CREATE INDEX IF NOT EXISTS idx_sync_conflicts_created '
      'ON sync_conflicts(created_at)',
];
