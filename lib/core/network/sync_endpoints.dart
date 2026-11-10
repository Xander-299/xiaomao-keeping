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

/// 内置默认地址。**正式部署前这里是占位** —— P6.2 上线时替换成真实域名，
/// 并同步更新 [SyncEndpoints.allowlistedHosts]。
const String _kDefaultBaseUrl = 'https://sync.xiaomao.app';

/// 允许请求的主机白名单（不含端口）。子域**不**自动放行。
const Set<String> _kDefaultHosts = <String>{'sync.xiaomao.app'};

class SyncEndpoints {
  const SyncEndpoints._();

  /// 解析后的根地址（末尾不带斜杠）。
  static String get baseUrl {
    final String raw = kSyncBaseUrlEnv.trim();
    final String value = raw.isEmpty ? _kDefaultBaseUrl : raw;
    return value.endsWith('/') ? value.substring(0, value.length - 1) : value;
  }

  /// 是否配过真实地址（占位域名视为「没配」）。
  static bool get isConfigured =>
      baseUrl.isNotEmpty && Uri.tryParse(baseUrl)?.host.isNotEmpty == true;

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
