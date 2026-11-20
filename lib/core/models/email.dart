/// 邮箱值对象（技术债清理）：把「归一化 + 形状校验」收进一个类型。
///
/// 为什么值得单独一个类：以前邮箱是裸 `String`，归一化（`trim + toLowerCase`）
/// 和校验散在 `AuthController.normalizeEmail` / `isValidEmail`、`SavedAccount.fromJson`、
/// `sessionKeyFor` 三处 —— 任何一处漏了都会变成「同一个账号两种写法」：
/// 账本 `ownerId` 是**精确比较**的，大小写不同即整本账不可见（SPEC-P6.5 D2）。
///
/// 现在只有一条路：`Email.tryParse(raw)`，拿到的值**一定**已归一化且形状合法。
/// 边界（KV / JSON / 输入框）仍然是 `String`，进到领域里就是 `Email`。
library;

/// 已归一化（trim + 小写）且形状校验通过的邮箱。
class Email implements Comparable<Email> {
  const Email._(this.value);

  /// 解析并归一化；形状不合法返回 null（调用方决定抛错还是当「没填」）。
  static Email? tryParse(String? raw) {
    if (raw == null) return null;
    final String v = raw.trim().toLowerCase();
    if (!_looksLikeEmail(v)) return null;
    return Email._(v);
  }

  /// 形状校验（服务端仍会再校验一次）：`local@domain.tld` 的最小约定。
  static bool isValid(String? raw) {
    if (raw == null) return false;
    return _looksLikeEmail(raw.trim().toLowerCase());
  }

  static bool _looksLikeEmail(String v) {
    final int at = v.indexOf('@');
    if (at <= 0 || at == v.length - 1) return false;
    final String domain = v.substring(at + 1);
    return domain.contains('.') &&
        !domain.startsWith('.') &&
        !domain.endsWith('.') &&
        !domain.contains('@');
  }

  /// 归一化后的字符串（落 KV / JSON / 拼会话键时用它）。
  final String value;

  @override
  bool operator ==(Object other) => other is Email && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  int compareTo(Email other) => value.compareTo(other.value);

  @override
  String toString() => value;
}
