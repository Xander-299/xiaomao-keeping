/// 已保存账号的模型与编解码（P6.5 多账号）。
///
/// 从 `core/providers/account_scope.dart` 分出来的：那个文件同时装着键约定、
/// 键派生、模型与编解码三件事，改哪一件都得看另外两件。现在：
/// - 键与派生 → `core/providers/account_keys.dart`
/// - 模型与编解码 → 本文件
///
/// 仍然留在 core 而不是 `features/sync`：`BookRepository`（data 层）也要用
/// `parseSavedAccounts` 判断「这台机器有没有登录过云同步」，data 不能反向依赖 features。
library;

import 'dart:convert';

import 'email.dart';

/// 已保存账号。
class SavedAccount {
  const SavedAccount({required this.email, required this.lastUsedAt});

  /// 解析一条账号记录；邮箱不合法（或缺失）返回 null —— 坏数据直接丢，
  /// 不要让它以「空邮箱账号」的形态混进列表。
  static SavedAccount? tryFromJson(Map<String, Object?> json) {
    final Email? email = Email.tryParse(json['email'] as String?);
    if (email == null) return null;
    return SavedAccount(
      email: email,
      lastUsedAt: json['lastUsedAt'] is num
          ? (json['lastUsedAt']! as num).toInt()
          : 0,
    );
  }

  final Email email;

  /// 毫秒时间戳，用于列表排序（最近用的在最上面）。
  final int lastUsedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'email': email.value,
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
        if (item is Map)
          ?SavedAccount.tryFromJson(Map<String, Object?>.from(item)),
    ];
    out.sort((SavedAccount a, SavedAccount b) => b.lastUsedAt - a.lastUsedAt);
    return out;
  } catch (_) {
    return const <SavedAccount>[];
  }
}

String encodeSavedAccounts(List<SavedAccount> accounts) =>
    jsonEncode(<Object?>[for (final SavedAccount a in accounts) a.toJson()]);
