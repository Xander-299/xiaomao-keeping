/// `SavedAccount` 的落盘口径（技术债：`lastUsedAt` int 毫秒 → `DateTime`）。
///
/// 关键约束：**字段类型变了，JSON 形状不能变** —— 老版本写的 `lastUsedAt` 是毫秒 int，
/// 新版本读回来必须还在同一个位置；新版本写下去的也得是老版本能读的毫秒。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:yanxin/core/models/email.dart';
import 'package:yanxin/core/models/saved_account.dart';

void main() {
  test('落盘仍是毫秒 int（老数据/老版本都读得懂）', () {
    final SavedAccount a = SavedAccount(
      email: Email.tryParse('A@Example.com')!,
      lastUsedAt: DateTime.fromMillisecondsSinceEpoch(1700000000123),
    );
    final Map<String, Object?> json = a.toJson();
    expect(json['email'], 'a@example.com');
    expect(json['lastUsedAt'], 1700000000123);
    expect(json['lastUsedAt'], isA<int>());
  });

  test('读写往返：时间精确到毫秒', () {
    final String raw = jsonEncode(<Object?>[
      SavedAccount(
        email: Email.tryParse('b@example.com')!,
        lastUsedAt: DateTime.fromMillisecondsSinceEpoch(1700000000999),
      ).toJson(),
    ]);
    final List<SavedAccount> parsed = parseSavedAccounts(raw);
    expect(parsed.single.lastUsedAt.millisecondsSinceEpoch, 1700000000999);
  });

  test('排序：最近用的在前（跨天也一样）', () {
    final String raw = jsonEncode(<Object?>[
      SavedAccount(
        email: Email.tryParse('old@example.com')!,
        lastUsedAt: DateTime.fromMillisecondsSinceEpoch(1000),
      ).toJson(),
      SavedAccount(
        email: Email.tryParse('new@example.com')!,
        lastUsedAt: DateTime.fromMillisecondsSinceEpoch(9000),
      ).toJson(),
    ]);
    expect(
      parseSavedAccounts(raw).map((SavedAccount a) => a.email.value).toList(),
      <String>['new@example.com', 'old@example.com'],
    );
  });

  test('坏邮箱的账号整条丢掉（不产生「空邮箱账号」）', () {
    final String raw = jsonEncode(<Object?>[
      <String, Object?>{'email': '', 'lastUsedAt': 1},
      <String, Object?>{'email': 'not-an-email', 'lastUsedAt': 2},
      SavedAccount(
        email: Email.tryParse('ok@example.com')!,
        lastUsedAt: DateTime.fromMillisecondsSinceEpoch(3),
      ).toJson(),
    ]);
    expect(parseSavedAccounts(raw).length, 1);
    expect(parseSavedAccounts(raw).single.email.value, 'ok@example.com');
  });

  test('缺 lastUsedAt → 纪元（老数据的兜底）', () {
    final String raw = jsonEncode(<Object?>[
      <String, Object?>{'email': 'x@example.com'},
    ]);
    expect(parseSavedAccounts(raw).single.lastUsedAt.millisecondsSinceEpoch, 0);
  });
}
