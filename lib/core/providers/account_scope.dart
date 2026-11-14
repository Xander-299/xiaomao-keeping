/// 「当前是哪个账号」的 KV 约定（P6.5 多账号）。
///
/// 为什么放在 core 而不是 `features/sync`：账本仓储（data 层）要按账号过滤、
/// 账本状态（data providers）要按账号取 `active_book_id`，它们都不该反过来依赖
/// `features/sync`。这里只定义**键名与解析**，不碰网络、不碰 UI。
///
/// 三个键：
/// - `sync_accounts`：已保存账号列表（JSON，登录过就有；**判断「用过云同步」的唯一依据**）；
/// - `active_account_email`：当前账号（退出登录时删除 = null）；
/// - `sync_session:<email>`：每个账号各自的 token（在 Keystore，不在这里）。
library;

import 'dart:convert';

/// 已保存账号列表（`schema_meta`）。
const String kSyncAccountsKey = 'sync_accounts';

/// 当前账号邮箱（`schema_meta`）；缺失 = 未登录。
const String kActiveAccountKey = 'active_account_email';

/// 单个账号的安全存储键（每个账号一份 token）。
String sessionKeyFor(String email) => 'sync_session:${email.trim()}';

/// 已保存账号。
class SavedAccount {
  const SavedAccount({required this.email, required this.lastUsedAt});

  factory SavedAccount.fromJson(Map<String, Object?> json) => SavedAccount(
    email: (json['email'] as String? ?? '').trim(),
    lastUsedAt: json['lastUsedAt'] is num
        ? (json['lastUsedAt']! as num).toInt()
        : 0,
  );

  final String email;

  /// 毫秒时间戳，用于列表排序（最近用的在最上面）。
  final int lastUsedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'email': email,
    'lastUsedAt': lastUsedAt,
  };

  SavedAccount touch(int at) => SavedAccount(email: email, lastUsedAt: at);
}

/// 解析 `sync_accounts`；坏数据 / 空值一律当「没有保存过账号」。
List<SavedAccount> parseSavedAccounts(String? raw) {
  if (raw == null || raw.trim().isEmpty) return const <SavedAccount>[];
  try {
    final Object? decoded = jsonDecode(raw);
    if (decoded is! List) return const <SavedAccount>[];
    final List<SavedAccount> out = <SavedAccount>[
      for (final Object? item in decoded)
        if (item is Map) SavedAccount.fromJson(Map<String, Object?>.from(item)),
    ];
    out.removeWhere((SavedAccount a) => a.email.isEmpty);
    out.sort((SavedAccount a, SavedAccount b) => b.lastUsedAt - a.lastUsedAt);
    return out;
  } catch (_) {
    return const <SavedAccount>[];
  }
}

String encodeSavedAccounts(List<SavedAccount> accounts) =>
    jsonEncode(<Object?>[for (final SavedAccount a in accounts) a.toJson()]);
