/// 首页模块配置：显示集合 + 用户排序。
///
/// 持久化格式（`schema_meta.dashboard_config`）：
/// `{"enabled": ["..."], "order": ["..."]}`
/// null = 使用注册表默认值（兼容首次启动 / 脏数据）。
library;

import 'dashboard_module.dart';

class DashboardConfig {
  const DashboardConfig({this.enabledIds, this.orderIds});

  /// null = 全部启用。
  final Set<String>? enabledIds;

  /// null = 按模块默认 order 排序。
  final List<String>? orderIds;

  static const DashboardConfig defaults = DashboardConfig();

  bool isEnabled(DashboardModule module) =>
      enabledIds == null || enabledIds!.contains(module.id);

  Map<String, Object?> toJson() => <String, Object?>{
    if (enabledIds != null) 'enabled': enabledIds!.toList()..sort(),
    if (orderIds != null) 'order': orderIds,
  };

  factory DashboardConfig.fromJson(Map<String, Object?> json) {
    final Object? enabled = json['enabled'];
    final Object? order = json['order'];
    return DashboardConfig(
      enabledIds: enabled is List
          ? enabled.whereType<String>().toSet()
          : null,
      orderIds: order is List ? order.whereType<String>().toList() : null,
    );
  }

  DashboardConfig copyWith({Set<String>? enabledIds, List<String>? orderIds}) =>
      DashboardConfig(
        enabledIds: enabledIds ?? this.enabledIds,
        orderIds: orderIds ?? this.orderIds,
      );
}
