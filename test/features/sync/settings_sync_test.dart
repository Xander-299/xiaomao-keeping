/// P6.4b · 设置同步（entity=setting）：时间戳、上下行、LWW。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/core/network/sync_api.dart';
import 'package:yanxin/core/providers/settings_dirty.dart';
import 'package:yanxin/core/theme/theme_mode.dart';
import 'package:yanxin/data/repositories/app_meta_repository.dart';
import 'package:yanxin/features/sync/application/settings_sync.dart';

import '../../helpers/test_database.dart';

void main() {
  test('写完设置后能生成一条 entity=setting 的变更（白名单三键）', () async {
    final AppDatabase db = openTestDatabase();
    addTearDown(db.close);
    final AppMetaRepository meta = AppMetaRepository(db);
    await meta.set(kThemeModeKey, 'dark');
    await meta.set('onboarding_done', '1'); // 不在白名单，不该被带走

    await markSettingsDirty(meta, at: DateTime.fromMillisecondsSinceEpoch(1000));

    final SyncChange? change = await buildSettingsChange(meta);
    expect(change, isNotNull);
    expect(change!.entity, 'setting');
    expect(change.bookId, 'global');
    expect(change.id, 'global');
    expect(change.updatedAt, 1000);
    expect(change.payload[kThemeModeKey], 'dark');
    expect(change.payload.containsKey('onboarding_done'), isFalse);
    expect(change.payload.containsKey('active_book_id'), isFalse);
  });

  test('没有改动（同步过之后）→ 不生成变更；再次改动 → 又生成', () async {
    final AppDatabase db = openTestDatabase();
    addTearDown(db.close);
    final AppMetaRepository meta = AppMetaRepository(db);
    await meta.set(kThemeModeKey, 'light');
    await markSettingsDirty(meta, at: DateTime.fromMillisecondsSinceEpoch(1000));
    await markSettingsSynced(meta, 1000);

    expect(await buildSettingsChange(meta), isNull);

    await markSettingsDirty(meta, at: DateTime.fromMillisecondsSinceEpoch(2000));
    final SyncChange? again = await buildSettingsChange(meta);
    expect(again?.updatedAt, 2000);
  });

  test('markSettingsSynced 取较大值（应用了远端更新后不会被旧时间戳覆盖）', () async {
    final AppDatabase db = openTestDatabase();
    addTearDown(db.close);
    final AppMetaRepository meta = AppMetaRepository(db);
    await meta.set(kSettingsSyncedAtKey, '5000');
    await markSettingsSynced(meta, 3000);
    expect(await meta.get(kSettingsSyncedAtKey), '5000');
    await markSettingsSynced(meta, 9000);
    expect(await meta.get(kSettingsSyncedAtKey), '9000');
  });

  test('下行应用：服务端更新 → 写回三键，且不会立刻又被当成「本地改动」', () async {
    final AppDatabase db = openTestDatabase();
    addTearDown(db.close);
    final AppMetaRepository meta = AppMetaRepository(db);
    await meta.set(kThemeModeKey, 'light');

    final bool applied = await applySettingsChange(
      meta,
      const SyncChange(
        bookId: 'global',
        entity: 'setting',
        id: 'global',
        updatedAt: 4000,
        deleted: false,
        payload: <String, Object?>{kThemeModeKey: 'dark'},
      ),
    );

    expect(applied, isTrue);
    expect(await meta.get(kThemeModeKey), 'dark');
    expect(await meta.get(kSettingsUpdatedAtKey), '4000');
    expect(await buildSettingsChange(meta), isNull, reason: '不该被反弹回去');
  });

  test('下行应用：本机更新 → 跳过（LWW）', () async {
    final AppDatabase db = openTestDatabase();
    addTearDown(db.close);
    final AppMetaRepository meta = AppMetaRepository(db);
    await meta.set(kThemeModeKey, 'light');
    await markSettingsDirty(meta, at: DateTime.fromMillisecondsSinceEpoch(9000));

    final bool applied = await applySettingsChange(
      meta,
      const SyncChange(
        bookId: 'global',
        entity: 'setting',
        id: 'global',
        updatedAt: 4000,
        deleted: false,
        payload: <String, Object?>{kThemeModeKey: 'dark'},
      ),
    );

    expect(applied, isFalse);
    expect(await meta.get(kThemeModeKey), 'light');
  });
}
