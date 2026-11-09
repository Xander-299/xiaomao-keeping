/// 页面级异步状态：加载 / 错误。
///
/// 只收口页面整块的状态占位，不改各页面自己的数据与重试逻辑。
/// 局部错误仍留在对应卡片 / 区块里，不要用这个组件。
library;

import 'package:flutter/material.dart';

/// 页面整块加载中。
class AppPageLoading extends StatelessWidget {
  const AppPageLoading({super.key});

  @override
  Widget build(BuildContext context) =>
      const Center(child: CircularProgressIndicator());
}

/// 页面整块加载失败。
///
/// 默认文案与旧页面保持一致（`加载失败：<error>`），后续要统一成人话提示时
/// 只改这里，不用逐页改。
class AppPageError extends StatelessWidget {
  const AppPageError({
    super.key,
    required this.error,
    this.prefix = '加载失败',
  });

  final Object error;
  final String prefix;

  @override
  Widget build(BuildContext context) =>
      Center(child: Text('$prefix：$error'));
}
