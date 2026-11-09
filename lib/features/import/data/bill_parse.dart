/// 账单文件统一解析入口 — 旧栈 `bill-import/parse.js` 的移植。
///
/// 页面只调 [parseBillFileAuto]，不感知格式差异：
/// - 小耄记账备份 JSON（`schemaVersion` + `transactions`）→ [BackupParseSignal]
/// - ZIP 魔数（PK\x03\x04）→ xlsx（微信 2025+ 导出格式）→ parseBillRows
/// - 否则按文本解码（UTF-8 / GBK 回退）→ parseBillCsv
/// profile 自动探测：先微信后支付宝，必需列不全即判定不匹配。
library;

import '../application/backup_restore.dart';
import 'bill_decode.dart';
import 'bill_normalize.dart';
import 'bill_profiles.dart';
import 'bill_xlsx.dart';

/// 备份文件嗅探命中。
///
/// 备份不走 ParsedRow 流程（它自带分类/账户/指纹），导入页拿到这个信号后
/// 走 [restoreBackupJson] 整体恢复。
class BackupParseSignal {
  const BackupParseSignal();
}

/// 解析结果：要么是普通账单行，要么是备份文件信号。
sealed class ParseOutcome {
  const ParseOutcome();
}

final class BillRowsOutcome extends ParseOutcome {
  const BillRowsOutcome(this.result);

  final BillParseResult result;
}

final class BackupOutcome extends ParseOutcome {
  const BackupOutcome();
}

/// 账单文件原始字节 → 解析结果。无法识别时抛 [FormatException]。
ParseOutcome parseBillFileAuto(List<int> bytes) {
  // 小耄记账备份优先嗅探（JSON 文本，不会撞 ZIP 魔数）
  if (looksLikeBackupJson(bytes)) {
    return const BackupOutcome();
  }

  List<List<String>>? matrix;
  String? text;

  if (isZipBytes(bytes)) {
    matrix = readXlsxRows(bytes);
  } else {
    try {
      text = decodeBillBytes(bytes).text;
    } on FormatException catch (e) {
      throw FormatException(e.message == '' ? '无法识别的文件编码' : e.message);
    }
  }

  final errors = <String>[];
  for (final profile in billProfiles) {
    try {
      final BillParseResult result = matrix != null
          ? parseBillRows(profile, matrix)
          : parseBillCsv(profile, text!);
      return BillRowsOutcome(result);
    } on FormatException catch (e) {
      errors.add('${profile.name}：${e.message}');
    }
  }
  throw FormatException('无法识别的账单文件格式。${errors.join('；')}');
}
