/// 归一化 + 过滤规则 — 旧栈 `bill-import/normalize.js` 的移植。
///
/// 输入：profile + 行矩阵（CSV 解出或 xlsx 读出）
/// 输出：ParsedRow[] + 统计报告（skipped/malformed/unknownStatus 计数）
///
/// 铁律：
/// - 金额全程禁止浮点，统一走 yuanToCents 的字符串转分
/// - 坏行只计 malformed，绝不中断整体导入
/// - 数据区在表头之后，遇分隔线/统计行/文件尾即结束
library;

import '../../../core/utils/money.dart';
import 'bill_csv.dart';
import 'bill_profiles.dart';

/// 归一化后的单行（对应旧栈 ParsedRow）。
class ParsedRow {
  const ParsedRow({
    required this.source,
    required this.externalId,
    required this.occurredAt,
    required this.amountCents,
    required this.direction,
    required this.counterparty,
    required this.product,
    required this.method,
    required this.status,
    required this.unknownStatus,
    required this.rawIndex,
  });

  final String source;
  final String externalId;
  final int occurredAt; // 毫秒，本地时区
  final int amountCents; // 恒为正整数分
  final String direction; // 'expense' | 'income'
  final String counterparty;
  final String product;
  final String method;
  final String status;
  final bool unknownStatus;
  final int rawIndex; // 在行矩阵中的原始下标
}

/// 单行归一化结果。
sealed class NormalizeOutcome {
  const NormalizeOutcome();
}

final class NormalizedRow extends NormalizeOutcome {
  const NormalizedRow(this.row);

  final ParsedRow row;
}

final class RowSkipped extends NormalizeOutcome {
  const RowSkipped(this.reason, {this.cents});

  final String reason; // neutral | non-positive | blacklisted

  /// 这一行的金额（分）；有的分支拿得到（`neutral`），有的没意义。
  ///
  /// 为什么要在「跳过」里带金额：微信/支付宝账单**头部**的收支合计是**含**转账、提现、
  /// 还款这些中性交易的，而本 App 按规则不计入 —— 不告诉用户这笔钱去哪了，
  /// 他会以为「导入丢了 78 块」（真机走查原话）。
  final int? cents;
}

final class RowMalformed extends NormalizeOutcome {
  const RowMalformed(this.reason);

  final String reason;
}

/// 整文件解析报告。
class BillParseResult {
  const BillParseResult({
    required this.source,
    required this.rows,
    required this.stats,
  });

  final String source;
  final List<ParsedRow> rows;
  final BillStats stats;
}

class BillStats {
  BillStats();

  int dataRows = 0;
  int imported = 0;
  int skipped = 0;
  int malformed = 0;
  int unknownStatus = 0;
  final Map<String, int> skipReasons = {};

  /// 中性交易（转账 / 提现 / 还款…）的条数与金额合计。
  ///
  /// 单列出来是为了能对用户说清「账单头部的收支为什么比入库多一笔钱」。
  int neutralSkipped = 0;
  int neutralSkippedCents = 0;

  Map<String, Object?> toJson() => <String, Object?>{
    'dataRows': dataRows,
    'imported': imported,
    'skipped': skipped,
    'malformed': malformed,
    'unknownStatus': unknownStatus,
    'skipReasons': skipReasons,
    'neutralSkipped': neutralSkipped,
    'neutralSkippedCents': neutralSkippedCents,
  };
}

/// 表头单元格归一化：全角括号转半角 + 去首尾空白。
String normCell(String s) => s.replaceAll('（', '(').replaceAll('）', ')').trim();

/// profile 的全部列名（columns 值可能是回退数组）。
Set<String> allColumnNames(BillProfile profile) =>
    profile.columns.values.expand((l) => l).where((n) => n.isNotEmpty).toSet();

/// 表头定位结果。
class HeaderLocation {
  const HeaderLocation({required this.headerRowIndex, required this.columns});

  final int headerRowIndex;
  final Map<String, int> columns; // 表头列名 -> 列下标
}

/// 在前 30 行内定位表头（SPEC 第 2 层）。
///
/// 取「命中所列列名最多」的行；必需列不全则抛 [FormatException] 并列出缺失列。
HeaderLocation locateHeader(List<List<String>> rows, BillProfile profile) {
  final names = allColumnNames(profile);
  final limit = rows.length < 30 ? rows.length : 30;

  int? bestRowIndex;
  var bestRequiredHits = 0;
  Map<String, int> bestIndex = {};

  for (var i = 0; i < limit; i++) {
    final cells = rows[i].map(normCell).toList();
    final index = <String, int>{};
    for (final name in names) {
      final idx = cells.indexOf(name);
      if (idx >= 0) index[name] = idx;
    }
    final requiredHits =
        profile.required.where((n) => index[n] != null).length;
    if (bestRowIndex == null || requiredHits > bestRequiredHits) {
      bestRowIndex = i;
      bestRequiredHits = requiredHits;
      bestIndex = index;
    }
    if (requiredHits == profile.required.length) break; // 已全命中，无需再扫
  }

  if (bestRowIndex == null || bestRequiredHits < profile.required.length) {
    final missing = profile.required
        .where((n) => bestRowIndex == null || bestIndex[n] == null)
        .toList();
    throw FormatException(
      '不是有效的${profile.name}账单文件：缺少必需列 ${missing.join('、')}',
    );
  }
  return HeaderLocation(headerRowIndex: bestRowIndex, columns: bestIndex);
}

/// 金额原文 -> 有符号整数分。'¥12.30' -> 1230，'1,234.00' -> 123400，'-12.30' -> -1230。
/// 非法格式抛 [FormatException]（调用方捕获后计 malformed）。全程无浮点。
int parseAmountCents(String raw) {
  var s =
      raw.trim().replaceAll(RegExp(r'[¥￥\s,]'), '');
  final neg = s.startsWith('-');
  s = s.replaceFirst(RegExp(r'^[-+]'), '');
  final cents = yuanToCents(s.isEmpty ? '0' : s);
  return neg ? -cents : cents;
}

/// '2026-08-01 12:30:00' -> 毫秒（本地时区）。
///
/// Excel 日期序列号（微信 xlsx 的时间列）按本地时区换算。
/// 解析失败返回 null。
///
/// 序列号换算：1900 日期系统里 1970-01-01 = 25569；序列号本身是
/// 「无时区的墙上时间」，先按 UTC 展开成时分秒，再用本地时区构造 DateTime，
/// 保证与 CSV 文本时间在同一套语义下。
int? parseTimeMs(String raw) {
  final s = raw.trim();
  final m =
      RegExp(r'(\d{4})-(\d{1,2})-(\d{1,2})[ T](\d{1,2}):(\d{2})(?::(\d{2}))?')
          .firstMatch(s);
  if (m != null) {
    return DateTime(
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
      int.parse(m.group(3)!),
      int.parse(m.group(4)!),
      int.parse(m.group(5)!),
      int.parse(m.group(6) ?? '0'),
    ).millisecondsSinceEpoch;
  }
  // Excel 序列号：20000~80000 覆盖 1954~2119 年；交易单号等长数字串不会落进这个区间
  if (RegExp(r'^\d{4,5}(\.\d+)?$').hasMatch(s)) {
    final serial = num.parse(s);
    if (serial >= 20000 && serial <= 80000) {
      final micros =
          ((serial - 25569) * 86400000).round();
      final asUtc =
          DateTime.fromMillisecondsSinceEpoch(micros, isUtc: true);
      return DateTime(
        asUtc.year,
        asUtc.month,
        asUtc.day,
        asUtc.hour,
        asUtc.minute,
        asUtc.second,
      ).millisecondsSinceEpoch;
    }
  }
  return null;
}

/// 单行归一化为 ParsedRow。
NormalizeOutcome normalizeRow(
  BillProfile profile,
  List<String> cells,
  Map<String, int> columns,
  int rawIndex,
) {
  // 取列值：列名可为数组（按序回退，第一个命中即返回）；单名查不到返回空串
  String cell(List<String> names) {
    for (final n in names) {
      if (n.isEmpty) continue;
      final i = columns[n];
      if (i != null && i < cells.length) return cells[i].trim();
    }
    return '';
  }

  final rawDirection = cell(profile.columns['direction']!);
  final rawAmount = cell(profile.columns['amount']!);
  final rawStatus = cell(profile.columns['status']!);
  final rawExternalId = cell(profile.columns['externalId']!);
  final rawCounterparty = cell(profile.columns['counterparty']!);
  final rawProduct = cell(profile.columns['product']!);
  final rawMethod = cell(profile.columns['method']!);

  // 时间：主列解析失败按序回退（支付宝 付款时间 -> 交易创建时间）
  int? occurredAt;
  for (final c in profile.columns['occurredAt']!) {
    final t = parseTimeMs(cell([c]));
    if (t != null) {
      occurredAt = t;
      break;
    }
  }
  if (occurredAt == null) return const RowMalformed('时间无法解析');

  int amountCents;
  try {
    amountCents = parseAmountCents(rawAmount);
  } on FormatException {
    return const RowMalformed('金额格式非法');
  }

  final direction = profile.directionMap[rawDirection];
  if (direction == null) {
    return RowMalformed('收/支取值未知：${rawDirection.isEmpty ? '(空)' : rawDirection}');
  }
  if (direction == 'skip') return RowSkipped('neutral', cents: amountCents);
  if (amountCents <= 0) return const RowSkipped('non-positive');

  // 黑名单优先：命中即跳过（含「关闭/退款/失败/失效」）
  for (final k in profile.blacklistKeywords) {
    if (rawStatus.contains(k)) return const RowSkipped('blacklisted');
  }

  final unknownStatus = !profile.statusWhitelist.contains(rawStatus);
  return NormalizedRow(
    ParsedRow(
      source: profile.source,
      externalId: rawExternalId,
      occurredAt: occurredAt,
      amountCents: amountCents,
      direction: direction,
      counterparty: rawCounterparty,
      product: rawProduct,
      method: rawMethod,
      status: rawStatus,
      unknownStatus: unknownStatus,
      rawIndex: rawIndex,
    ),
  );
}

/// 整文件解析（CSV 文本路径）：定位表头 -> 逐行归一化 + 过滤 -> 报告。
BillParseResult parseBillCsv(BillProfile profile, String text) =>
    parseBillRows(profile, parseCsvRows(text));

/// 行矩阵解析（CSV 与 xlsx 共用的主流程）。
BillParseResult parseBillRows(BillProfile profile, List<List<String>> rows) {
  final loc = locateHeader(rows, profile);

  final stats = BillStats();
  final out = <ParsedRow>[];

  for (var i = loc.headerRowIndex + 1; i < rows.length; i++) {
    final cells = rows[i];
    final first = cells.isNotEmpty ? cells[0].trim() : '';
    // 数据区结束：分隔线 / 统计行（支付宝尾块、微信账单脚注）
    if (RegExp(r'^[-—#]{3,}').hasMatch(first) ||
        RegExp(r'明细(列表)?结束').hasMatch(first)) {
      break;
    }
    if (cells.every((c) => c.trim() == '')) continue;
    stats.dataRows++;

    final r = normalizeRow(profile, cells, loc.columns, i);
    if (r is RowMalformed) {
      stats.malformed++;
    } else if (r is RowSkipped) {
      stats.skipped++;
      stats.skipReasons[r.reason] = (stats.skipReasons[r.reason] ?? 0) + 1;
      if (r.reason == 'neutral') {
        stats.neutralSkipped++;
        stats.neutralSkippedCents += r.cents ?? 0;
      }
    } else if (r is NormalizedRow) {
      if (r.row.unknownStatus) stats.unknownStatus++;
      out.add(r.row);
      stats.imported++;
    }
  }

  return BillParseResult(source: profile.source, rows: out, stats: stats);
}
