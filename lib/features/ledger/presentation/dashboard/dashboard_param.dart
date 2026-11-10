/// 模块参数：声明 + 读写。
///
/// 三种类型（P5）：
/// - [DashboardParamKind.toggle] —— 开关（P4 就有，默认值 `true`）
/// - [DashboardParamKind.choice] —— 几选一（字符串枚举，值域由 [DashboardParamSpec.options] 定）
/// - [DashboardParamKind.count]  —— 小整数（范围由 [DashboardParamSpec.min] / `max` 定）
///
/// 铁律：**读的时候一律容错**。配置里可能是脏数据（类型不对 / 值不在选项里 / 越界 /
/// 被手改过 JSON），任何一种都必须回落默认值，绝不能让首页崩掉或显示成空白。
/// 写的时候同样先归一（[DashboardParamSpec.coerce]），脏值不落库。
library;

/// 参数类型。
enum DashboardParamKind {
  /// 布尔开关（默认 `true`）。
  toggle,

  /// 几选一，值是 [DashboardParamSpec.options] 里的 `value`。
  choice,

  /// 小整数（设置页用步进器渲染），范围 [DashboardParamSpec.min]–[DashboardParamSpec.max]。
  count,
}

/// [DashboardParamKind.choice] 的一个选项。
class DashboardParamOption {
  const DashboardParamOption(this.value, this.label);

  /// 落库的值。**不要**用中文当值：文案改了不该让老配置失效。
  final String value;

  /// 设置页显示的文字（可以随便改）。
  final String label;
}

/// 一个模块参数的声明。
class DashboardParamSpec {
  const DashboardParamSpec({
    required this.id,
    required this.title,
    this.kind = DashboardParamKind.toggle,
    this.defaultValue = true,
    this.options = const <DashboardParamOption>[],
    this.min = 0,
    this.max = 99,
  });

  final String id;
  final String title;
  final DashboardParamKind kind;

  /// 缺键 / 脏值时用的值。类型必须与 [kind] 对得上（toggle→bool、choice→String、count→int）。
  final Object defaultValue;

  /// [DashboardParamKind.choice] 的可选值；其他类型为空。
  final List<DashboardParamOption> options;

  /// [DashboardParamKind.count] 的闭区间上下限。
  final int min;
  final int max;

  /// 按类型读值：脏数据一律回落 [defaultValue]。
  Object value(Map<String, Object?>? params) => coerce(params?[id]);

  /// 把任意原始值归一成本参数类型；归不了就用默认值。
  Object coerce(Object? raw) {
    switch (kind) {
      case DashboardParamKind.toggle:
        return raw is bool ? raw : defaultValue;

      case DashboardParamKind.choice:
        if (raw is String &&
            options.any((DashboardParamOption o) => o.value == raw)) {
          return raw;
        }
        return defaultValue;

      case DashboardParamKind.count:
        final int? n = _asIntOrNull(raw);
        if (n == null) return defaultValue;
        final int d = defaultValue is int ? defaultValue as int : min;
        if (n < min || n > max) {
          // 越界不夹到边界，而是回落默认 —— 「手改 JSON 成 999」不该变成「显示 50 条」，
          // 那等于帮用户做了个他没要过的选择。
          return d.clamp(min, max);
        }
        return n;
    }
  }

  // ── 取值便捷方法（模块代码用）────────────────────────────────────────

  bool boolOf(Map<String, Object?>? params) => value(params) as bool;

  String choiceOf(Map<String, Object?>? params) => value(params) as String;

  int countOf(Map<String, Object?>? params) => value(params) as int;

  /// P4 口径的静态入口（既有调用方与测试都在用，别删）。
  static bool boolValue(
    Map<String, Object?>? params,
    DashboardParamSpec spec,
  ) => spec.boolOf(params);
}

int? _asIntOrNull(Object? raw) {
  if (raw is int) return raw;
  // JSON 里 10 可能解成 10.0；手改可能写成字符串。两种都认，但真小数直接判脏。
  if (raw is double) return raw == raw.roundToDouble() ? raw.toInt() : null;
  if (raw is String) return int.tryParse(raw.trim());
  return null;
}

/// 模块参数表（模块 → 参数键值）。
typedef DashboardParams = Map<String, Map<String, Object?>>;

Map<String, Object?>? paramsOf(DashboardParams? params, String moduleId) =>
    params?[moduleId];
