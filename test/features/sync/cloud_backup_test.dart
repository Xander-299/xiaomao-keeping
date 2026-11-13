/// P6.3 · 备份字节构建：产物必须能被 `restoreBackupJson` 直接吃回去。
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/data/providers/database.dart';
import 'package:yanxin/features/import/application/backup_restore.dart';
import 'package:yanxin/features/sync/application/backup_bytes.dart';

import '../../helpers/test_database.dart';

void main() {
  test('buildCurrentBackupBytes：是合法备份 JSON，且可被 restoreBackupJson 恢复', () async {
    final AppDatabase db = openTestDatabase();
    addTearDown(db.close);
    final ProviderContainer container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);

    final List<int> bytes = await container.read(
      currentBackupBytesProvider.future,
    );
    expect(bytes, isNotEmpty);

    final Object? decoded = jsonDecode(utf8.decode(bytes));
    expect(decoded, isA<Map<String, Object?>>());
    final Map<String, Object?> json = decoded! as Map<String, Object?>;
    expect(json['book'], isA<Map<String, Object?>>());
    expect(json['transactions'], isA<List<Object?>>());
    expect(json['exportedAt'], isA<String>());
    // 空账本不应该带 settings 段（白名单里没有值就不写）
    expect(json.containsKey('settings'), isFalse);

    // 恢复到另一个空库：格式必须被认，且不误报数据
    final AppDatabase target = openTestDatabase();
    addTearDown(target.close);
    final BackupRestoreReport report = await restoreBackupJson(
      target,
      bytes: bytes,
      createBook: false,
    );
    expect(report.dataRows, 0);
    expect(report.imported, 0);
  });
}
