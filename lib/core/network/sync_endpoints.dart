/// 云同步的服务端地址与**白名单**（P6.1）。
///
/// 三条硬约束（改这里之前先读 `docs/spec/SPEC-P6-cloud-sync.md` §4 / §6）：
/// 1. **只认 HTTPS**：`http://` 一律视为不可用，不是「警告」而是拒绝（`network_security_config`
///    在系统层也拦，这里是第二道）；
/// 2. **只认白名单主机**：地址写死在代码里，不从服务端下发、不从本地配置读 ——
///    否则一份被改过的配置就能把整本账导去任意域名；
/// 3. **可关闭**：构建期用 `--dart-define=SYNC_BASE_URL=...` 覆盖（测试 / 自建部署），
///    但覆盖值同样要过 ①② 两关。
library;

/// 构建期覆盖（测试环境 / 自建部署用）；空 = 用内置默认值。
const String kSyncBaseUrlEnv = String.fromEnvironment('SYNC_BASE_URL');

/// 早期的占位地址（已退役，保留只用于 [SyncEndpoints.isUsingPlaceholder] 判定）。
const String _kPlaceholderBaseUrl = 'https://sync.xiaomao.app';

/// 内置默认地址：Cloudflare named tunnel → ECS `127.0.0.1:8787`。
///
/// 2026-11-13 起为真实端点（`xanders.ccwu.cc` 托管在 Cloudflare，证书由 CF 边缘提供）。
/// 若将来换域名：只改这一行 + [SyncEndpoints.allowlistedHosts]。
const String _kDefaultBaseUrl = 'https://sync.xanders.ccwu.cc';

/// 允许请求的主机白名单（不含端口）。子域**不**自动放行。
const Set<String> _kDefaultHosts = <String>{'sync.xanders.ccwu.cc'};

class SyncEndpoints {
  const SyncEndpoints._();

  /// 解析后的根地址（末尾不带斜杠）。
  static String get baseUrl {
    final String raw = kSyncBaseUrlEnv.trim();
    final String value = raw.isEmpty ? _kDefaultBaseUrl : raw;
    return value.endsWith('/') ? value.substring(0, value.length - 1) : value;
  }

  /// 是否还在用**内置占位域名**（构建期没给 `SYNC_BASE_URL`，默认值也没换成真实域名）。
  ///
  /// 占位域名我们不保证持有：如果把它当「已配置」，用户输入的邮箱与验证码会发到
  /// 一个别人可能注册的域名上 —— 这不是体验问题，是账号安全边界。
  static bool get isUsingPlaceholder =>
      kSyncBaseUrlEnv.trim().isEmpty && _kDefaultBaseUrl == _kPlaceholderBaseUrl;

  /// 是否配过真实地址（占位域名视为「没配」）。
  static bool get isConfigured {
    if (isUsingPlaceholder) return false;
    final Uri? uri = Uri.tryParse(baseUrl);
    return uri != null && uri.host.isNotEmpty;
  }

  /// 白名单主机集合：内置的 + 覆盖地址自己那个（覆盖只在构建期生效，不来自运行时输入）。
  static Set<String> get allowlistedHosts {
    final String? overrideHost = Uri.tryParse(kSyncBaseUrlEnv.trim())?.host;
    return <String>{
      ..._kDefaultHosts,
      if (overrideHost != null && overrideHost.isNotEmpty) overrideHost,
    };
  }

  /// 把相对路径拼成完整 URL（`/v1/backups` → `https://host/v1/backups`）。
  static Uri resolve(String path) {
    final String p = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$baseUrl$p');
  }
}
