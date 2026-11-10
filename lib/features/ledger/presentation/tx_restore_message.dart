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

/// 删除时「受影响行数 = 0」的提示（P3）。
///
/// 含义：点删除的那一刻，这行已经被别的入口（另一个 tab、通知栏撤销、另一台设备同步过来的
/// 同库操作）删掉了。不能弹「已删除 + 撤销」—— 那是假装自己删成功，而 Undo 还会去恢复一条
/// 本来就该消失的记录。三个删除入口共用这句，口径一致。
const String kTxAlreadyGoneMessage = '这笔流水已经不在了，列表已刷新';
