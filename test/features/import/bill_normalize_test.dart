/// 移植自旧栈 tests/bill-import/normalize.test.js。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:yanxin/features/import/data/bill_decode.dart';
import 'package:yanxin/features/import/data/bill_normalize.dart';
import 'package:yanxin/features/import/data/bill_profiles.dart';

void main() {
  group('parseAmountCents（金额字符串 -> 有符号整数分）', () {
    test('¥12.30 -> 1230', () {
      expect(parseAmountCents('¥12.30'), 1230);
    });
    test('全角货币符 ￥ 与空白', () {
      expect(parseAmountCents('￥ 88.00'), 8800);
    });
    test('千分位 1,234.00 -> 123400', () {
      expect(parseAmountCents('1,234.00'), 123400);
    });
    test('负数 -12.30 -> -1230', () {
      expect(parseAmountCents('-12.30'), -1230);
    });
    test('0.00 -> 0', () {
      expect(parseAmountCents('0.00'), 0);
    });
    test('非法格式抛错', () {
      expect(() => parseAmountCents('abc'), throwsA(isA<FormatException>()));
    });
  });

  group('parseTimeMs', () {
    test('标准格式 -> 本地时区毫秒', () {
      final ts = parseTimeMs('2026-08-01 12:30:05')!;
      final d = DateTime.fromMillisecondsSinceEpoch(ts);
      expect(d.year, 2026);
      expect(d.month, 8);
      expect(d.day, 1);
      expect(d.hour, 12);
      expect(d.minute, 30);
      expect(d.second, 5);
    });
    test('非法文本 -> null', () {
      expect(parseTimeMs('not-a-time'), isNull);
      expect(parseTimeMs(''), isNull);
    });
  });

  group('locateHeader（前 30 行定位表头）', () {
    test('微信：跳过元信息头部，命中真实表头行', () {
      final text = File('test/fixtures/wechat-sample.csv').readAsStringSync();
      final rows =
          text.split('\n').map((l) => l.split(',')).toList();
      final loc = locateHeader(rows, wechatProfile);
      expect(loc.headerRowIndex, 7); // 第 8 行是表头
      expect(loc.columns['金额(元)'], 5);
      expect(loc.columns['交易单号'], 8);
    });

    test('全角/半角括号金额列都认', () {
      final rows = [
        ['交易时间', '收/支', '金额（元）', '当前状态', '交易单号'],
      ];
      final loc = locateHeader(rows, wechatProfile);
      expect(loc.columns['金额(元)'], 2);
    });

    test('必需列缺失 -> 报错并列出缺失列', () {
      final rows = [
        ['交易时间', '收/支', '金额(元)'],
      ];
      expect(
        () => locateHeader(rows, wechatProfile),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('当前状态、交易单号'),
          ),
        ),
      );
    });
  });

  group('parseBillCsv 端到端（微信 fixture，UTF-8）', () {
    final result = parseBillCsv(
      wechatProfile,
      File('test/fixtures/wechat-sample.csv').readAsStringSync(),
    );

    test('导入 4 条（3 正常 + 1 未知状态）', () {
      expect(result.stats.imported, 4);
      expect(result.rows, hasLength(4));
    });

    test('金额转分正确且恒正', () {
      final amounts = result.rows.map((r) => r.amountCents).toList()..sort();
      expect(amounts, [100, 1230, 2330, 8800]);
    });

    test('商品名含逗号（引号包裹）不错位', () {
      final first = result.rows
          .firstWhere((r) => r.externalId == '1000120260801123012300123456');
      expect(first.product, '外卖订单（满减,含配送费）');
      expect(first.direction, 'expense');
      expect(first.counterparty, '美团平台商户');
      expect(first.method, '零钱');
    });

    test('中性交易（/）与黑名单（已关闭）被跳过，理由可区分', () {
      expect(result.stats.skipped, 2);
      expect(result.stats.skipReasons['neutral'], 1);
      expect(result.stats.skipReasons['blacklisted'], 1);
    });

    // 中性交易单独记账（条数 + 金额）：账单头部的收支合计是含它的，
    // 报告里不单列，用户会以为「导入丢了这笔钱」。
    test('中性交易的金额被单独累计（¥100.00 = 10000 分）', () {
      expect(result.stats.neutralSkipped, 1);
      expect(result.stats.neutralSkippedCents, 10000);
    });

    test('未知状态（处理中）默认导入并标记 unknownStatus', () {
      final unknown = result.rows.where((r) => r.unknownStatus).toList();
      expect(unknown, hasLength(1));
      expect(unknown[0].status, '处理中');
      expect(result.stats.unknownStatus, 1);
    });

    test('source 与 occurredAt 正确', () {
      expect(result.source, 'wechat_csv');
      final first = result.rows.first;
      expect(first.occurredAt, parseTimeMs('2026-08-01 12:30:00'));
    });
  });

  group('parseBillCsv 端到端（支付宝 fixture，GBK 解码）', () {
    // 真实支付宝导出是 GBK：读原始字节走 decodeBillBytes，覆盖完整解码链路
    final bytes = File('test/fixtures/alipay-sample.csv').readAsBytesSync();
    final result = parseBillCsv(alipayProfile, decodeBillBytes(bytes).text);

    test('导入 2 条', () {
      expect(result.stats.imported, 2);
      expect(result.source, 'alipay_csv');
    });

    test('全角「金额（元）」表头被正确匹配', () {
      expect(result.rows[0].amountCents, 1230);
    });

    test('付款时间为空 -> 回退交易创建时间', () {
      final income =
          result.rows.firstWhere((r) => r.direction == 'income');
      expect(income.occurredAt, parseTimeMs('2026-08-02 09:00:00'));
    });

    test('不计收支跳过；交易关闭跳过；尾部分隔线后不再解析', () {
      expect(result.stats.skipped, 2);
      expect(result.stats.skipReasons['neutral'], 1);
      expect(result.stats.skipReasons['blacklisted'], 1);
      expect(result.stats.dataRows, 4); // 结束线不计入数据行
    });

    test('不计收支的金额单独累计（¥100.00），退款/关闭不计入', () {
      expect(result.stats.neutralSkipped, 1);
      expect(result.stats.neutralSkippedCents, 10000);
    });

    test('method 为空（支付宝无支付方式列）', () {
      expect(result.rows.every((r) => r.method == ''), isTrue);
    });
  });

  group('坏行不中断（malformed 计数）', () {
    test('金额非法/时间非法的行计入 malformed，其余照常导入', () {
      const text = '交易时间,交易类型,交易对方,商品,收/支,金额(元),支付方式,当前状态,交易单号,商户单号,备注\n'
          '2026-08-01 12:00:00,x,甲,商品A,支出,¥10.00,零钱,支付成功,ID1,M1,/\n'
          '2026-08-02 12:00:00,x,乙,商品B,支出,¥abc,零钱,支付成功,ID2,M2,/\n'
          'bad-time,x,丙,商品C,支出,¥1.00,零钱,支付成功,ID3,M3,/\n'
          '2026-08-03 12:00:00,x,丁,商品D,支出,¥5.50,零钱,支付成功,ID4,M4,/';
      final r = parseBillCsv(wechatProfile, text);
      expect(r.stats.imported, 2);
      expect(r.stats.malformed, 2);
    });

    test('收/支 取值未知（空）计 malformed 而非静默跳过', () {
      const text = '交易时间,交易类型,交易对方,商品,收/支,金额(元),支付方式,当前状态,交易单号,商户单号,备注\n'
          '2026-08-01 12:00:00,x,甲,商品A,,¥10.00,零钱,支付成功,ID1,M1,/';
      final r = parseBillCsv(wechatProfile, text);
      expect(r.stats.malformed, 1);
    });
  });
}
