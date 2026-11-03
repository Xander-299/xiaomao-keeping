/// 把 [TxRestoreResult] 映射成用户能理解的撤销失败提示。
///
/// 放在 presentation 层，避免数据层拼中文 UI 文案；三个入口（首页 / 日历 /
/// 搜索）共用，防止再次出现「所有失败都说同指纹冲突」。
library;

import '../../../data/repositories/transaction_repository.dart';

String txRestoreFailureMessage(TxRestoreResult result) => switch (result) {
  TxRestoreResult.restored => '',
  TxRestoreResult.notFound => '无法撤销：这条流水不存在',
  TxRestoreResult.notDeleted => '无法撤销：这条流水已经恢复',
  TxRestoreResult.bookUnavailable => '无法撤销：所属账本已删除',
  TxRestoreResult.accountUnavailable => '无法撤销：关联账户已删除或不属于当前账本',
  TxRestoreResult.categoryUnavailable => '无法撤销：关联分类已删除或不属于当前账本',
  TxRestoreResult.categoryKindMismatch => '无法撤销：关联分类与收支方向不一致',
  TxRestoreResult.fingerprintConflict => '无法撤销：同账本已有相同指纹的记录',
};
