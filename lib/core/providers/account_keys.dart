/// 「当前是哪个账号」的 KV 键约定（P6.5 多账号）。
///
/// 这里只放**键名与键的派生**，不放模型、不放解析 —— 模型在
/// `core/models/saved_account.dart`，会话 token 在 Keystore（`sessionKeyFor` 只是键）。
///
/// 为什么放在 core：账本仓储（data 层）要按账号过滤、账本状态要按账号取
/// `active_book_id`，它们都不该反过来依赖 `features/sync`。
library;

import '../models/email.dart';

/// 已保存账号列表（`schema_meta`）。
const String kSyncAccountsKey = 'sync_accounts';

/// 当前账号邮箱（`schema_meta`）；缺失 = 未登录。
const String kActiveAccountKey = 'active_account_email';

/// 单个账号的安全存储键（每个账号一份 token）。
///
/// 参数是 [Email] 而不是 String：键必须用**归一化后**的地址拼，否则
/// `A@B.com` 与 `a@b.com` 会各存一份会话、互相看不见（P6.5 D2 的成因之一）。
String sessionKeyFor(Email email) => 'sync_session:${email.value}';
