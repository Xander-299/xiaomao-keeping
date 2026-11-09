/// 模块参数：声明 + 读写。
///
/// 参数都是 bool 开关（P4 范围）；默认值在 [DashboardParamSpec.defaultValue]，
/// 配置里没写的键一律按默认走，保证旧数据零迁移。
library;

/// 一个模块参数的声明。
class DashboardParamSpec {
  const DashboardParamSpec({
    required this.id,
    required this.title,
    this.defaultValue = true,
  });

  final String id;
  final String title;
  final bool defaultValue;

  /// 从模块参数表里取值；未配置 = 默认值。
  static bool boolValue(
    Map<String, Object?>? params,
    DashboardParamSpec spec,
  ) {
    final Object? raw = params?[spec.id];
    return raw is bool ? raw : spec.defaultValue;
  }
}

/// 模块参数表（模块 → 参数键值）。
typedef DashboardParams = Map<String, Map<String, Object?>>;

Map<String, Object?>? paramsOf(DashboardParams? params, String moduleId) =>
    params?[moduleId];
