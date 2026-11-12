/// 数据导出纯函数测试（SPEC-F7.7 §B.3 / §B.4）。
///
/// 只测 `csv_export.dart`：不碰数据库、不碰 file_picker（落盘在真机上走查）。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/features/export/application/csv_export.dart';

/// 固定基准时间：2026-09-23 16:30:05（本地时区）。
final int _nowMs = DateTime(2026, 9, 23, 16, 30, 5).millisecondsSinceEpoch;

TxRow _tx({
  String id = 't1',
  String accountId = 'a1',
  String? categoryId,
  String type = 'expense',
  required int cents,
  String note = '',
  String source = 'manual',
  int? at,
  String? fingerprint,
}) {
  final int ts = at ?? _nowMs;
  return TxRow(
    id: id,
    bookId: 'b1',
    accountId: accountId,
    categoryId: categoryId,
    type: type,
    amountCents: cents,
    note: note,
    occurredAt: ts,
    source: source,
    fingerprint: fingerprint,
    createdAt: ts,
    updatedAt: ts,
    dirty: 1,
  );
}

Book _book({String name = '默认账本'}) => Book(
  id: 'b1',
  name: name,
  type: 'personal',
  currency: 'CNY',
  icon: '',
  color: '',
  sortOrder: 0,
  createdAt: _nowMs,
  updatedAt: _nowMs,
  dirty: 0,
);

Account _account({String id = 'a1', String name = '现金'}) => Account(
  id: id,
  bookId: 'b1',
  name: name,
  type: 'cash',
  initialBalanceCents: 0,
  icon: '',
  color: '',
  sortOrder: 0,
  createdAt: _nowMs,
  updatedAt: _nowMs,
  dirty: 1,
);

Category _category({
  String id = 'c1',
  String name = '餐饮',
  String kind = 'expense',
}) => Category(
  id: id,
  bookId: 'b1',
  name: name,
  kind: kind,
  icon: '',
  color: '',
  sortOrder: 0,
  isPreset: 1,
  isArchived: 0,
  createdAt: _nowMs,
  updatedAt: _nowMs,
  dirty: 1,
);

BudgetRow _budget({String period = '2026-09', int cents = 300000}) => BudgetRow(
  id: 'g1',
  bookId: 'b1',
  period: period,
  amountCents: cents,
  createdAt: _nowMs,
  updatedAt: _nowMs,
  dirty: 1,
);

/// 固定名字映射。
const Map<String, String> _catNames = <String, String>{'c1': '餐饮', 'c2': '交通'};
const Map<String, String> _accNames = <String, String>{'a1': '现金', 'a2': '工资卡'};

void main() {
  group('buildBillCsv', () {
    test('表头固定 + UTF-8 BOM 打头', () {
      final String csv = buildBillCsv(rows: <TxRow>[]);
      expect(csv, '$kUtf8Bom$kBillCsvHeader');
      expect(csv.codeUnitAt(0), 0xFEFF);
    });

    test('空账本：只有表头、没有换行（SPEC §B.4.6）', () {
      expect(buildBillCsv(rows: <TxRow>[]).contains('\r\n'), isFalse);
    });

    test('一行流水：日期 / 类型 / 金额 / 分类 / 账户 / 备注 / 来源 / 流水ID', () {
      final String csv = buildBillCsv(
        rows: <TxRow>[
          _tx(
            categoryId: 'c1',
            cents: 1234,
            note: '午饭',
            source: 'wechat_csv',
            at: DateTime(2026, 9, 23, 12, 5).millisecondsSinceEpoch,
          ),
        ],
        categoryNames: _catNames,
        accountNames: _accNames,
      );
      // 2026-11-13 起最后一列是「流水ID」：导入端靠它精确判断「这条已经在了」
      expect(
        csv.split('\r\n').last,
        '2026-09-23 12:05,支出,12.34,餐饮,现金,午饭,wechat_csv,t1',
      );
    });

    test('金额取绝对值且无符号：收入 / 转账也照原样（方向看类型列）', () {
      final String csv = buildBillCsv(
        rows: <TxRow>[
          _tx(id: 'i1', type: 'income', cents: 100000, categoryId: 'c2'),
          _tx(id: 'x1', type: 'transfer', cents: 5000),
        ],
        categoryNames: _catNames,
        accountNames: _accNames,
      );
      final List<String> lines = csv.split('\r\n');
      expect(lines[1], contains(',收入,1000.00,交通,现金,,manual'));
      // 转账没有分类 → 该列留空（SPEC §B.4.9）
      expect(lines[2], contains(',转账,50.00,,现金,,manual'));
    });

    test('分类 id 为空或查不到名字都留空；账户同理', () {
      final String csv = buildBillCsv(
        rows: <TxRow>[
          _tx(id: 't1', categoryId: null, cents: 100, accountId: 'a9'),
          _tx(id: 't2', categoryId: 'cX', cents: 200, accountId: 'a9'),
        ],
        categoryNames: _catNames,
        accountNames: _accNames,
      );
      final List<String> lines = csv.split('\r\n');
      expect(lines[1], contains(',支出,1.00,,,'));
      expect(lines[2], contains(',支出,2.00,,,'));
    });

    test('类型未知时原样输出（不静默吞掉脏数据）', () {
      final String csv = buildBillCsv(rows: <TxRow>[_tx(type: 'weird', cents: 1)]);
      expect(csv.split('\r\n').last, contains(',weird,'));
    });

    test('RFC4180 转义：逗号 / 引号 / 换行', () {
      expect(csvField('普通'), '普通');
      expect(csvField('a,b'), '"a,b"');
      expect(csvField('说"好"'), '"说""好"""');
      expect(csvField('第一行\n第二行'), '"第一行\n第二行"');
      expect(csvField('回车\r'), '"回车\r"');
    });

    test('备注里的逗号与换行不会串列（整行仍 7 列）', () {
      final String csv = buildBillCsv(
        rows: <TxRow>[
          _tx(categoryId: 'c1', cents: 100, note: '买菜,顺便\n取快递'),
        ],
        categoryNames: _catNames,
        accountNames: _accNames,
      );
      // 换行被引号包住 → 只多出表头那一个 \r\n 之外的 1 个内嵌 \n
      expect('\r\n'.allMatches(csv).length, 1);
      expect(csv, contains('"买菜,顺便\n取快递"'));
    });

    test('行尾统一 CRLF', () {
      final String csv = buildBillCsv(
        rows: <TxRow>[_tx(id: 't1', cents: 1), _tx(id: 't2', cents: 2)],
      );
      expect(csv.split('\r\n').length, 3); // 表头 + 2 行
    });
  });

  group('formatCsvDateTime', () {
    test('零填充到 YYYY-MM-DD HH:mm', () {
      expect(
        formatCsvDateTime(DateTime(2026, 1, 2, 3, 4).millisecondsSinceEpoch),
        '2026-01-02 03:04',
      );
    });
  });

  group('exportFileName', () {
    test('正常：小耄记账_{账本名}_{YYYYMMDD}.csv', () {
      expect(
        exportFileName(bookName: '默认账本', ext: 'csv', nowMs: _nowMs),
        '小耄记账_默认账本_20260923.csv',
      );
    });

    test('非法字符全部换下划线', () {
      expect(
        exportFileName(bookName: 'a/b:c*d?e"f<g>h|i', ext: 'json', nowMs: _nowMs),
        '小耄记账_a_b_c_d_e_f_g_h_i_20260923.json',
      );
    });

    test('空名退回「账本」', () {
      expect(
        exportFileName(bookName: '   ', ext: 'csv', nowMs: _nowMs),
        '小耄记账_账本_20260923.csv',
      );
    });

    test('月份 / 日期零填充', () {
      expect(
        exportFileName(
          bookName: 'x',
          ext: 'csv',
          nowMs: DateTime(2026, 1, 5).millisecondsSinceEpoch,
        ),
        '小耄记账_x_20260105.csv',
      );
    });
  });

  group('buildBackupJson', () {
    String jsonOf({List<TxRow>? rows}) => buildBackupJson(
      book: _book(),
      accounts: <Account>[_account(), _account(id: 'a2', name: '工资卡')],
      categories: <Category>[_category()],
      transactions: rows ?? <TxRow>[_tx(categoryId: 'c1', cents: 1234)],
      budgets: <BudgetRow>[_budget()],
      exportedAtMs: _nowMs,
    );

    test('顶层结构与 schemaVersion', () {
      final Map<String, Object?> m =
          jsonDecode(jsonOf()) as Map<String, Object?>;
      expect(m.keys.toList(), <String>[
        'schemaVersion',
        'exportedAt',
        'book',
        'accounts',
        'categories',
        'transactions',
        'budgets',
      ]);
      expect(m['schemaVersion'], 2);
      expect(m['book'], isA<Map<String, Object?>>());
      expect((m['book']! as Map<String, Object?>)['name'], '默认账本');
      expect((m['accounts']! as List<Object?>).length, 2);
      expect((m['categories']! as List<Object?>).length, 1);
      expect((m['transactions']! as List<Object?>).length, 1);
      expect((m['budgets']! as List<Object?>).length, 1);
    });

    test('exportedAt 带时区偏移（不留歧义）', () {
      final Map<String, Object?> m =
          jsonDecode(jsonOf()) as Map<String, Object?>;
      final String at = m['exportedAt']! as String;
      expect(at, startsWith('2026-09-23T16:30:05'));
      expect(RegExp(r'[+-]\d{2}:\d{2}$').hasMatch(at), isTrue);
      expect(formatIsoWithOffset(_nowMs), at);
    });

    test('金额是整数「分」，与库一致（SPEC §B.4.3）', () {
      final Map<String, Object?> m =
          jsonDecode(jsonOf()) as Map<String, Object?>;
      final Map<String, Object?> tx =
          (m['transactions']! as List<Object?>).first as Map<String, Object?>;
      expect(tx['amountCents'], 1234);
      final Map<String, Object?> budget =
          (m['budgets']! as List<Object?>).first as Map<String, Object?>;
      expect(budget['period'], '2026-09');
      expect(budget['amountCents'], 300000);
    });

    test('流水字段齐全，且不含本地同步标记 dirty', () {
      final Map<String, Object?> m =
          jsonDecode(jsonOf()) as Map<String, Object?>;
      final Map<String, Object?> tx =
          (m['transactions']! as List<Object?>).first as Map<String, Object?>;
      expect(tx.keys.toList(), <String>[
        'id',
        'bookId',
        'accountId',
        'categoryId',
        'type',
        'amountCents',
        'note',
        'occurredAt',
        'transferGroupId',
        'source',
        'fingerprint',
        'ownerId',
        'createdAt',
        'updatedAt',
      ]);
      expect(tx['occurredAt'], _nowMs);
    });

    test('空账本：数组为空但结构完整', () {
      final Map<String, Object?> m = jsonDecode(
        buildBackupJson(
          book: _book(),
          accounts: <Account>[],
          categories: <Category>[],
          transactions: <TxRow>[],
          budgets: <BudgetRow>[],
          exportedAtMs: _nowMs,
        ),
      ) as Map<String, Object?>;
      expect(m['transactions'], isEmpty);
      expect(m['budgets'], isEmpty);
    });
  });

  group('utf8Bytes', () {
    test('中文编码正确，且 BOM 是 EF BB BF 打头的 3 字节', () {
      final List<int> bytes = utf8Bytes(buildBillCsv(rows: <TxRow>[]));
      expect(bytes.sublist(0, 3), <int>[0xEF, 0xBB, 0xBF]);
      // ⚠️ Dart 的 utf8 解码器会吃掉开头的 BOM（实测），所以解码回来**不会**
      // 带 U+FEFF：BOM 只保证在字节层（Excel 看的就是字节层）。
      final String decoded = utf8.decode(bytes);
      expect(decoded.startsWith(kBillCsvHeader), isTrue);
      expect(decoded.codeUnitAt(0), isNot(0xFEFF));
    });
  });
}
