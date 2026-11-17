/// schema v7：分类级预算（FR-BUDGET-10）。
///
/// 背景：v2 的唯一索引是「一账本一月一条」，只够放总预算。分类预算要在同一个月里
/// 共存多条，所以必须换成**两条部分唯一索引**：
/// - 总预算：`category_id IS NULL` 时 `(book_id, period)` 唯一；
/// - 分类预算：`category_id` 非空时 `(book_id, period, category_id)` 唯一。
///
/// 为什么不能只建一条带 `category_id` 的索引：SQLite 的唯一索引把 NULL 当作互不相等，
/// 一条索引放进 `category_id` 就会让「总预算」不再唯一（能插无数条）。
///
/// 迁移策略：**只换索引 + 加列**，不重建表、不改任何既有行。
library;

/// v7 的索引 DDL（ADR-9：索引一律原始 SQL）。
const kSchemaV7Indexes = <String>[
  'DROP INDEX IF EXISTS idx_budget_book_period',
  'CREATE UNIQUE INDEX IF NOT EXISTS idx_budget_book_period_total '
      'ON budgets(book_id, period) '
      'WHERE deleted_at IS NULL AND category_id IS NULL',
  'CREATE UNIQUE INDEX IF NOT EXISTS idx_budget_book_period_category '
      'ON budgets(book_id, period, category_id) '
      'WHERE deleted_at IS NULL AND category_id IS NOT NULL',
];
