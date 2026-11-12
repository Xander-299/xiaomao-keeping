/// 移植自旧栈 tests/bill-import/categorize.test.js。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:yanxin/core/constants/preset.dart';
import 'package:yanxin/features/import/data/bill_normalize.dart';
import 'package:yanxin/features/import/data/category_rules.dart';

ParsedRow _row({
  String counterparty = '',
  String product = '',
  String direction = 'expense',
}) {
  return ParsedRow(
    source: 'wechat_csv',
    externalId: '',
    occurredAt: 0,
    amountCents: 100,
    direction: direction,
    counterparty: counterparty,
    product: product,
    method: '',
    status: '',
    unknownStatus: false,
    rawIndex: 0,
  );
}

void main() {
  group('规则表完整性', () {
    test('规则总数约 40 条（20-60 之间）', () {
      expect(categoryRules.length, greaterThanOrEqualTo(20));
      expect(categoryRules.length, lessThanOrEqualTo(60));
    });

    // ⚠️ 守卫必须**读预置表本身**，不能在这里另抄一份名字清单。
    // 之前就是抄的一份（写的是「人情 / 理财 / 红包」），和 `preset.dart` 里的
    // 「人情社交 / 投资收益 / 红包礼金」早就对不上了 —— 守卫一直是绿的，
    // 而线上导入把这些词全落进了「其他」。
    test('规则只引用预置分类名（直接比对 preset 表），kind 只能是 expense/income', () {
      final Set<String> expenseNames =
          presetExpense.map((PresetCategory p) => p.name).toSet();
      final Set<String> incomeNames =
          presetIncome.map((PresetCategory p) => p.name).toSet();
      for (final CategoryRule r in categoryRules) {
        expect(<String>['expense', 'income'], contains(r.kind));
        final Set<String> valid = r.kind == 'expense' ? expenseNames : incomeNames;
        expect(
          valid,
          contains(r.category),
          reason: '分类「${r.category}」不在预置分类中（导入会静默落「其他」）',
        );
      }
    });
  });

  group('categorizeRow', () {
    test('关键词命中：美团 → 餐饮', () {
      final r = categorizeRow(
        _row(counterparty: '美团平台商户', product: '外卖订单'),
      );
      expect(r.categoryName, '餐饮');
      expect(r.matched, isTrue);
    });

    test('交易对方不命中时匹配商品名', () {
      expect(
        categorizeRow(_row(counterparty: '某某个体', product: '滴滴快车费')).categoryName,
        '交通',
      );
    });

    test('不区分大小写：steam → 娱乐', () {
      expect(
        categorizeRow(_row(counterparty: 'VALVE', product: 'steam purchase')).categoryName,
        '娱乐',
      );
    });

    test('先命中先赢：美团外卖不会被后面的「购物」抢走', () {
      expect(
        categorizeRow(_row(counterparty: '美团', product: '买菜')).categoryName,
        '餐饮',
      );
    });

    test('未命中落「其他」且 matched=false', () {
      final r = categorizeRow(_row(counterparty: '无关键词商户', product: '神秘商品'));
      expect(r.categoryName, '其他');
      expect(r.matched, isFalse);
    });

    test('收入走收入规则：工资代发 → 工资', () {
      final r = categorizeRow(
        _row(counterparty: '某某科技公司', product: '工资代发', direction: 'income'),
      );
      expect(r.categoryName, '工资');
      expect(r.matched, isTrue);
    });

    test('收入不命中 → 收入的「其他」', () {
      expect(
        categorizeRow(_row(counterparty: '某某', product: '返现', direction: 'income')).categoryName,
        '其他',
      );
    });

    // 真机走查（2026-10-27）用真实微信账单抓到的四条偏差，逐条钉死。
    group('真实账单样本（2026-10-27 走查）', () {
      test('手机充值-中国联通 → 通讯（不是居住）', () {
        expect(
          categorizeRow(
            _row(counterparty: '手机充值', product: '中国联通'),
          ).categoryName,
          '通讯',
        );
      });

      test('发给~青年旅社 → 旅行（不是其他）', () {
        expect(
          categorizeRow(
            _row(counterparty: '发给~青年旅社', product: '青年旅社住宿'),
          ).categoryName,
          '旅行',
        );
      });

      test('抖音生活服务 → 娱乐（不是其他）', () {
        expect(
          categorizeRow(
            _row(counterparty: '抖音生活服务', product: '团购'),
          ).categoryName,
          '娱乐',
        );
      });

      test('礼金 / 理财 / 红包 都真的落到分类上（曾经因名字对不上而落「其他」）', () {
        expect(
          categorizeRow(_row(counterparty: '某某', product: '随礼')).categoryName,
          '人情社交',
        );
        expect(
          categorizeRow(
            _row(counterparty: '余额宝', product: '收益', direction: 'income'),
          ).categoryName,
          '投资收益',
        );
        expect(
          categorizeRow(
            _row(counterparty: '张三', product: '红包', direction: 'income'),
          ).categoryName,
          '红包礼金',
        );
      });
    });

    test('同一关键词在支出/收入侧可映射不同分类', () {
      // 「转账/红包」在收入侧是红包；支出侧不命中这些词时仍按其他规则
      expect(
        categorizeRow(_row(counterparty: '张三', product: '转账', direction: 'income')).categoryName,
        '红包礼金',
      );
    });
  });
}
