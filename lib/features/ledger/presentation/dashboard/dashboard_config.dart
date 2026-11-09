/// 首页模块配置：显示集合 + 用户排序。
///
/// 持久化格式（`schema_meta.dashboard_config`）：
/// `{"enabled": ["..."], "order": ["..."]}`
/// null = 使用注册表默认值（兼容首次启动 / 脏数据）。
library;

import 'dashboard_module.dart';
import 'dashboard_param.dart';

class DashboardConfig {
  const DashboardConfig({this.enabledIds, this.orderIds, this.params});

  /// null = 全部启用。
  final Set<String>? enabledIds;

  /// null = 按模块默认 order 排序。
  final List<String>? orderIds;

  /// 每个模块自己的参数键值；缺键 = 参数默认值。
  final DashboardParams? params;

  static const DashboardConfig defaults = DashboardConfig();

  bool isEnabled(DashboardModule module) =>
      enabledIds == null || enabledIds!.contains(module.id);

  Map<String, Object?> toJson() => <String, Object?>{
    if (enabledIds != null) 'enabled': enabledIds!.toList()..sort(),
    if (orderIds != null) 'order': orderIds,
    if (params != null) 'params': params,
  };

  factory DashboardConfig.fromJson(Map<String, Object?> json) {
    final Object? enabled = json['enabled'];
    final Object? order = json['order'];
    final Object? params = json['params'];
    return DashboardConfig(
      enabledIds: enabled is List
          ? enabled.whereType<String>().toSet()
          : null,
      orderIds: order is List ? order.whereType<String>().toList() : null,
      params: params is Map
          ? params.map(
              (Object? k, Object? v) => MapEntry(
                k.toString(),
                v is Map ? Map<String, Object?>.from(v) : <String, Object?>{},
              ),
            )
          : null,
    );
  }

  DashboardConfig copyWith({
    Set<String>? enabledIds,
    List<String>? orderIds,
    DashboardParams? params,
  }) => DashboardConfig(
    enabledIds: enabledIds ?? this.enabledIds,
    orderIds: orderIds ?? this.orderIds,
    params: params ?? this.params,
  );
}
