/// 关键写路径的统一失败文案。
///
/// 目的：页面只负责「捕获 → 用现有 ToonFeedback 显示」，不再各自拼不同的
/// catch 文案。可预期的业务异常保留其 message；数据库锁、磁盘、Drift 等
/// 非预期异常不把技术细节/堆栈暴露给用户。
library;

import '../../data/repositories/category_repository.dart';

String writeFailureMessage(Object error, {required String action}) {
  if (error is CategoryException) return error.message;
  return '$action失败，请稍后重试';
}
