/// 云同步的账号状态（P6.2）。
///
/// 分工：
/// - 本文件只管「谁登录了、token 在哪、开关开没开」，**不碰账本**；
/// - 真正发请求的是 [SyncApi]（`lib/core/network/sync_api.dart`），
///   每次请求前都要过 [CloudSyncGate]（不变量 #8）；
/// - 登录态只存本机：token 进 Keystore 通道，邮箱与开关进 `schema_meta`
///   （都不进备份 JSON）。
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/core/models/email.dart';
import 'package:yanxin/core/models/saved_account.dart';
import 'package:yanxin/core/network/cloud_sync_gate.dart';
import 'package:yanxin/core/network/sync_api.dart';
import 'package:yanxin/core/network/sync_endpoints.dart';
import 'package:yanxin/core/providers/account_keys.dart';
import 'package:yanxin/core/providers/after_write.dart';
import 'package:yanxin/core/security/token_store.dart';
import 'package:yanxin/data/providers/database.dart';
import 'package:yanxin/data/repositories/app_meta_repository.dart';
import 'package:yanxin/features/sync/application/backup_bytes.dart';

/// **旧版**单槽登录态的键（P6.2 起）。P6.5 起改为每账号一个槽
/// （[sessionKeyFor] = `sync_session:<email>`），这个常量只用于**迁移**与兼容测试。
const String kSyncSessionKey = 'sync_session';

/// 上次登录的邮箱（**不是**敏感凭据；用于下次登录预填）。
const String kSyncEmailKey = 'sync_email';

/// 「云同步」用户开关在 `schema_meta` 里的键。缺省 / 脏值 = 关。
const String kCloudSyncEnabledKey = 'cloud_sync_enabled';

/// 安全存储（生产 = Keystore 通道；测试覆盖成内存实现）。
final tokenStoreProvider = Provider<TokenStore>((Ref ref) => KeystoreTokenStore());

/// HTTP 传输（测试覆盖成假实现，不建真 socket）。
final syncTransportProvider = Provider<SyncTransport>((Ref ref) {
  final HttpSyncTransport transport = HttpSyncTransport();
  ref.onDispose(transport.close);
  return transport;
});

/// 端点是否已配置（生产 = [SyncEndpoints.isConfigured]）。
///
/// 单独抽成 provider 只为一个目的：单测里把「占位域名 = 未配置」这一关打开，
/// 否则所有登录相关用例都会停在 `notConfigured`。
final syncEndpointConfiguredProvider = Provider<bool>(
  (Ref ref) => SyncEndpoints.isConfigured,
);

/// 云同步 API。
final syncApiProvider = Provider<SyncApi>(
  (Ref ref) => SyncApi(
    transport: ref.watch(syncTransportProvider),
    // 用 read 而不是 watch：闸门随登录态变化，但 API 实例不该因此重建
    gate: () => ref.read(cloudSyncGateProvider),
  ),
);

/// 当前登录态。
class AuthState {
  const AuthState({
    this.session,
    this.email,
    this.accounts = const <SavedAccount>[],
  });

  final AuthSession? session;

  /// 上次登录 / 当前登录的邮箱（未登录时也可能有值，用于预填）。
  ///
  /// 类型是 [Email] 而不是 String：能到这里的一定**已归一化**（trim + 小写），
  /// 拼会话键、比账号、写账本 `ownerId` 都用它，不再各自 trim/小写一遍。
  final Email? email;

  /// 已保存账号（登录过就在列表里，按最近使用排序）。
  final List<SavedAccount> accounts;

  bool get signedIn => session != null;

  /// 这台手机**用过云同步**吗？—— 「未登录是否空态」的判据（SPEC-P6.5 D3）。
  bool get hasSavedAccounts => accounts.isNotEmpty;

  AuthState copyWith({
    AuthSession? session,
    Email? email,
    List<SavedAccount>? accounts,
    bool clearSession = false,
    bool clearEmail = false,
  }) => AuthState(
    session: clearSession ? null : (session ?? this.session),
    email: clearEmail ? null : (email ?? this.email),
    accounts: accounts ?? this.accounts,
  );
}

/// 账号控制器。
final authControllerProvider =
    AsyncNotifierProvider<AuthController, AuthState>(AuthController.new);

/// 「云同步」用户开关（本机偏好，默认关）。
final cloudSyncEnabledProvider =
    AsyncNotifierProvider<CloudSyncEnabledController, bool>(
      CloudSyncEnabledController.new,
    );

/// 当前闸门：由「已登录 + 用户开关 + 端点是否配置」派生。
///
/// 默认（未登录 / 没开 / 没配域名）**一律拒绝**，与 [kClosedCloudSyncGate] 语义一致。
final cloudSyncGateProvider = Provider<CloudSyncGate>((Ref ref) {
  final bool signedIn = ref.watch(
    authControllerProvider.select(
      (AsyncValue<AuthState> v) => v.value?.signedIn ?? false,
    ),
  );
  final bool enabled = ref.watch(cloudSyncEnabledProvider).value ?? false;
  return CloudSyncGate(
    signedIn: signedIn,
    userEnabled: enabled,
    endpointConfigured: ref.watch(syncEndpointConfiguredProvider),
  );
});

class AuthController extends AsyncNotifier<AuthState> {
  /// 邮箱形状校验（UI 在提交前调一次，避免无谓请求）。真正的归一化在 [Email]。
  static bool isValidEmail(String value) => Email.isValid(value);

  /// 解析并归一化；不合法就抛「邮箱格式不对」（调用方不必再自己校验）。
  static Email _requireEmail(String raw) {
    final Email? email = Email.tryParse(raw);
    if (email == null) {
      throw const SyncApiException('invalidInput', message: '邮箱格式不对');
    }
    return email;
  }

  /// 冷启动只读本机，**不发网络**（避免启动即联网 / 启动被网络卡住）。
  @override
  Future<AuthState> build() async {
    final TokenStore store = ref.watch(tokenStoreProvider);
    final meta = ref.read(appMetaRepositoryProvider);
    Email? lastEmail;
    List<SavedAccount> accounts = const <SavedAccount>[];
    try {
      // 旧版把邮箱写在 Keystore（`_save` 里），新版也写一份进 schema_meta；
      // 迁移时两边都要看，否则 v0.8.9 升级上来的用户会被当成「没登录过」。
      lastEmail = Email.tryParse(
        (await store.read(kSyncEmailKey)) ?? await meta.get(kSyncEmailKey),
      );
      accounts = parseSavedAccounts(await meta.get(kSyncAccountsKey));
      if (accounts.isEmpty) {
        accounts = await _migrateLegacySlot(store, meta, lastEmail);
      }
      final Email? current = Email.tryParse(await meta.get(kActiveAccountKey));
      if (current == null) {
        // 未登录（可能是「退出但保留 token」）：token 不动，只暴露账号列表
        return AuthState(email: lastEmail, accounts: accounts);
      }
      final String? raw = await store.read(sessionKeyFor(current));
      // 迁移 / 冷启动也要把「账本范围」补齐：老库里的账本 ownerId 为空，
      // 不绑的话迁移用户一升级就看不到自己的账本（真机 v0.8.9 → P6.5 踩到）。
      // 冷启动没有缓存要刷（provider 都是刚建的），只做绑定，不触发写后刷新 ——
      // 在 build 里刷新会让 ledger/calendar 立刻查库，测试里容器已 dispose 时会炸。
      await _applyAccountScope(current, refresh: false);
      return AuthState(
        session: AuthSession.tryParse(raw),
        email: current,
        accounts: accounts,
      );
    } on SecureStoreException {
      // 读不出来 = 未登录，不能让一个坏 key 把 App 拦在启动页
      return AuthState(email: lastEmail, accounts: accounts);
    }
  }

  /// P6.2 的单槽 `sync_session` → P6.5 的 `sync_session:<email>`。
  ///
  /// 只跑一次（跑完就把旧键删掉、写入 `sync_accounts`）；坏数据按「没有账号」处理。
  Future<List<SavedAccount>> _migrateLegacySlot(
    TokenStore store,
    AppMetaRepository meta,
    Email? email,
  ) async {
    if (email == null) return const <SavedAccount>[];
    final String? legacy = await store.read(kSyncSessionKey);
    if (legacy == null || legacy.isEmpty) return const <SavedAccount>[];
    await store.write(sessionKeyFor(email), legacy);
    await store.delete(kSyncSessionKey);
    final List<SavedAccount> accounts = <SavedAccount>[
      SavedAccount(
        email: email,
        lastUsedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    ];
    await meta.set(kSyncAccountsKey, encodeSavedAccounts(accounts));
    await meta.set(kActiveAccountKey, email.value);
    return accounts;
  }

  /// 发验证码。
  Future<void> requestCode(String email) async {
    await ref.read(syncApiProvider).requestCode(_requireEmail(email).value);
  }

  /// 校验验证码并登录。
  Future<void> signIn({required String email, required String code}) async {
    final Email address = _requireEmail(email);
    final AuthSession session = await ref
        .read(syncApiProvider)
        .verify(address.value, code.trim());
    await _save(session, address);
    await _enterAccount(address);
  }

  /// 退出登录：**只回到未登录视图，保留 token**（用户 2026-11-14 裁定）。
  ///
  /// 这样再点一次该账号就能回来，不用重新收验证码。
  /// 想彻底清掉某个账号的登录态，用 [removeAccount]。
  Future<void> signOut() async {
    final AuthState current = state.value ?? const AuthState();
    try {
      await ref.read(appMetaRepositoryProvider).remove(kActiveAccountKey);
    } catch (_) {
      // 写失败也要把内存态切走：用户点了退出就得退
    }
    state = AsyncData(current.copyWith(clearSession: true, clearEmail: true));
    // 退出后账本范围变了（空态）：账本列表/当前账本必须重建，否则界面还挂着上个账号的账本。
    refreshAfterAccountChange(ref);
  }

  /// 注销账号：云端硬删成功后才清本机（失败要把异常交给 UI）。
  ///
  /// 本地**账本保留但隐藏**（与「移除账号」同口径）：云端已经没了，
  /// 但用户可能还想把本机这份导出去，不能替他删。
  Future<void> deleteAccount() async {
    final Email? email = state.value?.email;
    await _withAuth(
      (String token) => ref.read(syncApiProvider).deleteAccount(token),
    );
    await ref.read(cloudSyncEnabledProvider.notifier).setEnabled(false);
    if (email != null) {
      await removeAccount(email.value);
    } else {
      await _clearSession();
    }
  }

  // ── 云备份（P6.3）────────────────────────────────────────────────

  /// 上传当前账本备份到云端（覆盖「最新备份」）。
  Future<BackupInfo> uploadCurrentBackup() async {
    final Uint8List bytes = await ref.read(currentBackupBytesProvider.future);
    return _withAuth(
      (String token) => ref.read(syncApiProvider).uploadLatestBackup(
        accessToken: token,
        bytes: bytes,
      ),
    );
  }

  /// 云端最新备份的元数据；没有备份返回 null。
  Future<BackupInfo?> latestBackup() async {
    final List<BackupInfo> list = await _withAuth(
      (String token) => ref.read(syncApiProvider).listBackups(token),
    );
    return list.isEmpty ? null : list.first;
  }

  /// 下载云端最新备份原文。
  Future<Uint8List> downloadLatestBackup() => _withAuth(
    (String token) => ref.read(syncApiProvider).downloadLatestBackup(token),
  );

  /// 供同步引擎复用「401 自动续期」。
  Future<T> authorized<T>(Future<T> Function(String accessToken) run) =>
      _withAuth(run);

  /// 带一次 401 续期的调用：refresh 成功 → 落新 token → 重放一次。
  Future<T> _withAuth<T>(Future<T> Function(String token) run) async {
    final AuthState? current = state.value;
    final AuthSession? session = current?.session;
    if (session == null) {
      throw const SyncApiException('unauthorized', statusCode: 401);
    }

    try {
      return await run(session.accessToken);
    } on SyncApiException catch (e) {
      if (e.code != 'unauthorized') rethrow;

      AuthSession? refreshed;
      try {
        refreshed = await ref
            .read(syncApiProvider)
            .refresh(session.refreshToken);
      } on Object {
        refreshed = null;
      }
      if (refreshed == null) {
        await _clearSession();
        rethrow;
      }
      final Email? currentEmail = current?.email;
      if (currentEmail == null) {
        await _clearSession();
        rethrow;
      }
      await _save(refreshed, currentEmail);
      return run(refreshed.accessToken);
    }
  }

  Future<void> _save(AuthSession session, Email email) async {
    final TokenStore store = ref.read(tokenStoreProvider);
    // token 先落盘：写失败就让登录失败，不能只改内存状态
    await store.write(sessionKeyFor(email), session.toStorageJson());
    // 两份都写：Keystore 那份是旧版口径，schema_meta 那份给账本层看
    try {
      await store.write(kSyncEmailKey, email.value);
    } on SecureStoreException {
      // 兼容旧口径失败不影响登录
    }
    await ref.read(appMetaRepositoryProvider).set(kSyncEmailKey, email.value);
    state = AsyncData(state.value?.copyWith(session: session, email: email) ??
        AuthState(session: session, email: email));
  }

  /// 登录 / 切号成功后的「进入该账号」：写账号列表 + 当前账号 + 账本范围。
  Future<void> _enterAccount(Email email) async {
    final meta = ref.read(appMetaRepositoryProvider);
    final DateTime now = DateTime.now();
    final List<SavedAccount> accounts = <SavedAccount>[
      for (final SavedAccount a in state.value?.accounts ?? const <SavedAccount>[])
        if (a.email != email) a,
      SavedAccount(email: email, lastUsedAt: now.millisecondsSinceEpoch),
    ]..sort((SavedAccount a, SavedAccount b) => b.lastUsedAt - a.lastUsedAt);
    await meta.set(kSyncAccountsKey, encodeSavedAccounts(accounts));
    await meta.set(kActiveAccountKey, email.value);
    state = AsyncData(
      (state.value ?? const AuthState()).copyWith(
        email: email,
        accounts: accounts,
      ),
    );

    await _applyAccountScope(email);
  }

  /// 让账本范围与 [email] 对齐：绑定本机账本（若该账号还没有账本）、确保有账本、落 active id。
  ///
  /// 失败不抛：账本层异常不能把登录判失败，下一次进 App 再兜。
  Future<void> _applyAccountScope(Email email, {bool refresh = true}) async {
    final books = ref.read(bookRepositoryProvider);
    final String owner = email.value;
    try {
      await books.bindUnownedBooksTo(owner);
      final Book? visible = await books.ensureVisibleBook();
      final String? active = await books.getActiveBookIdFor(owner);
      if (visible != null && active == null) {
        await books.setActiveBookIdFor(owner, visible.id);
      }
    } catch (_) {
      // 见上
    }
    if (refresh) refreshAfterAccountChange(ref);
  }

  /// 切到另一个已保存账号（不校验 token 是否仍有效 —— 用的时候 401 会续期）。
  Future<void> switchTo(String email) async {
    final Email address = _requireEmail(email);
    final TokenStore store = ref.read(tokenStoreProvider);
    final String? raw = await store.read(sessionKeyFor(address));
    final AuthSession? session = AuthSession.tryParse(raw);
    if (session == null) {
      throw const SyncApiException(
        'unauthorized',
        statusCode: 401,
        message: '这个账号的登录已失效，请重新登录',
      );
    }
    state = AsyncData(
      (state.value ?? const AuthState()).copyWith(
        session: session,
        email: address,
      ),
    );
    await _enterAccount(address);
  }

  /// 移除账号：删本地 token + 从列表移除；**账本保留但隐藏**（同邮箱再登录自动恢复）。
  Future<void> removeAccount(String email) async {
    final Email address = _requireEmail(email);
    final TokenStore store = ref.read(tokenStoreProvider);
    try {
      await store.delete(sessionKeyFor(address));
    } on SecureStoreException {
      // 删不掉也继续：至少把它从列表里拿掉
    }
    final Email? active = Email.tryParse(
      await ref.read(appMetaRepositoryProvider).get(kActiveAccountKey),
    );
    final List<SavedAccount> accounts = <SavedAccount>[
      for (final SavedAccount a in state.value?.accounts ?? const <SavedAccount>[])
        if (a.email != address) a,
    ];
    await ref
        .read(appMetaRepositoryProvider)
        .set(kSyncAccountsKey, encodeSavedAccounts(accounts));
    final bool isCurrent = active == address;
    if (isCurrent) {
      await ref.read(appMetaRepositoryProvider).remove(kActiveAccountKey);
    }
    state = AsyncData(
      (state.value ?? const AuthState()).copyWith(
        accounts: accounts,
        clearSession: isCurrent,
        clearEmail: isCurrent,
      ),
    );
    refreshAfterAccountChange(ref);
  }

  Future<void> _clearSession() async {
    final Email? email = state.value?.email;
    final TokenStore store = ref.read(tokenStoreProvider);
    if (email != null) {
      try {
        await store.delete(sessionKeyFor(email));
      } on SecureStoreException {
        // 删不掉也只能当作已退出
      }
    }
    await ref.read(appMetaRepositoryProvider).remove(kActiveAccountKey);
    state = AsyncData((state.value ?? const AuthState()).copyWith(clearSession: true));
  }
}

class CloudSyncEnabledController extends AsyncNotifier<bool> {
  @override
  Future<bool> build() async {
    try {
      final String? raw = await ref
          .watch(appMetaRepositoryProvider)
          .get(kCloudSyncEnabledKey);
      return raw == '1';
    } catch (_) {
      return false;
    }
  }

  /// 切换开关：先切 UI 再写库（写失败本次会话仍生效，与主题控制器同口径）。
  Future<void> setEnabled(bool value) async {
    state = AsyncData<bool>(value);
    try {
      await ref
          .read(appMetaRepositoryProvider)
          .set(kCloudSyncEnabledKey, value ? '1' : '0');
    } catch (_) {
      // 低风险偏好，不打断用户
    }
  }
}
