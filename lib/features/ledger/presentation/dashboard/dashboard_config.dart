/// 首页模块配置。
///
/// P2 只提供内存模型与默认值；P3 再把 enabled / order 持久化并提供设置页。
library;

import 'dashboard_module.dart';

class DashboardConfig {
  const DashboardConfig({this.enabledIds});

  /// null = 全部启用（默认）。
  final Set<String>? enabledIds;

  static const DashboardConfig defaults = DashboardConfig();

  bool isEnabled(DashboardModule module) =>
      enabledIds == null || enabledIds!.contains(module.id);

  DashboardConfig copyWith({Set<String>? enabledIds}) =>
      DashboardConfig(enabledIds: enabledIds ?? this.enabledIds);
}
