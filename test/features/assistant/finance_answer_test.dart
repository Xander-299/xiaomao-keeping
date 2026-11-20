/// 「意图 + 数据 → 中文回答」的纯函数测试（M1 的嘴）。
///
/// 这里断言的是**具体金额与文案要点**：模型会编数，模板不会 —— 所以每一分钱都要对上。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/features/assistant/application/finance_answer.dart';
import 'package:yanxin/features/assistant/application/finance_intent.dart';

final int _nowMs = DateTime(2026, 10, 25, 15).millisecondsSinceEpoch;

const Map<String, String> _names = <String, String>{
  'c-food': '餐饮',
  'c-shop': '购物',
  'c-trans': '交通',
  'c-salary': '工资',
};

TxRow _tx({
  required String id,
  required String type,
  required int cents,
  required DateTime at,
  String? categoryId,
  String note = '',
}) => TxRow(
  id: id,
  bookId: 'b1',
  accountId: 'a1',
  categoryId: categoryId,
  type: type,
  amountCents: cents,
  note: note,
  occurredAt: at.millisecondsSinceEpoch,
  source: 'manual',
  createdAt: at.millisecondsSinceEpoch,
  updatedAt: at.millisecondsSinceEpoch,
  dirty: 1,
);

/// 10 月：餐饮 1280.50 + 购物 980 + 交通 460 = 2720.50；收入 12000
/// 9 月：餐饮 890 + 购物 400 = 1290
final List<TxRow> _rows = <TxRow>[
  _tx(id: 'o1', type: 'expense', cents: 128050, at: DateTime(2026, 10, 3), categoryId: 'c-food', note: '午饭'),
  _tx(id: 'o2', type: 'expense', cents: 98000, at: DateTime(2026, 10, 8), categoryId: 'c-shop', note: '外套'),
  _tx(id: 'o3', type: 'expense', cents: 46000, at: DateTime(2026, 10, 12), categoryId: 'c-trans', note: '打车'),
  _tx(id: 'o4', type: 'income', cents: 1200000, at: DateTime(2026, 10, 1), categoryId: 'c-salary', note: '工资'),
  _tx(id: 's1', type: 'expense', cents: 89000, at: DateTime(2026, 9, 10), categoryId: 'c-food'),
  _tx(id: 's2', type: 'expense', cents: 40000, at: DateTime(2026, 9, 20), categoryId: 'c-shop'),
];

FinanceData _data({int? budget, List<TxRow>? rows}) => FinanceData(
  rows: rows ?? _rows,
  categoryNames: _names,
  budgetCents: budget,
  nowMs: _nowMs,
);

/// 同一个 10 月，额外多一笔「餐饮 → 早餐」的二级账单（¥20）。
FinanceData _dataWithChild() => FinanceData(
  rows: <TxRow>[
    ..._rows,
    _tx(
      id: 'o5',
      type: 'expense',
      cents: 2000,
      at: DateTime(2026, 10, 5),
      categoryId: 'c-breakfast',
      note: '包子',
    ),
  ],
  categoryNames: <String, String>{..._names, 'c-breakfast': '早餐'},
  categoryParents: <String, String>{'c-breakfast': 'c-food'},
  nowMs: _nowMs,
);

final Period _oct = Period.month(2026, 10);
final Period _sep = Period.month(2026, 9);

void main() {
  group('月度汇总', () {
    test('支出：金额、分类、占比都对', () {
      final FinanceAnswer a = buildFinanceAnswer(
        MonthSummaryIntent(period: _oct, kind: 'expense'),
        _data(),
      );
      expect(a.headline, '¥2,720.50');
      expect(a.title, contains('2026年10月'));
      expect(a.narrative, contains('¥2,720.50'));
      expect(a.narrative, contains('餐饮'));
      expect(a.narrative, contains('47.1%')); // 128050 / 272050
      expect(a.facts.any((AnswerFact f) => f.label == '支出'), isTrue);
      expect(a.facts.any((AnswerFact f) => f.label == '结余'), isTrue);
    });

    test('收入口径：大字是收入，且同时给出支出与结余', () {
      final FinanceAnswer a = buildFinanceAnswer(
        MonthSummaryIntent(period: _oct, kind: 'income'),
        _data(),
      );
      expect(a.headline, '¥12,000.00');
      expect(a.facts.any((AnswerFact f) => f.label == '支出'), isTrue);
      expect(a.narrative, contains('结余'));
    });

    test('空账本：明说没有记录，不返回 0 元结论', () {
      final FinanceAnswer a = buildFinanceAnswer(
        MonthSummaryIntent(period: _oct, kind: 'expense'),
        _data(rows: const <TxRow>[]),
      );
      expect(a.narrative, contains('还没有记账记录'));
      expect(a.headline, isNull);
    });
  });

  group('分类支出', () {
    test('命中：金额 + 笔数 + 占比', () {
      final FinanceAnswer a = buildFinanceAnswer(
        CategorySpendingIntent(period: _oct, categoryName: '餐饮', kind: 'expense'),
        _data(),
      );
      expect(a.headline, '¥1,280.50');
      expect(a.narrative, contains('1 笔'));
      expect(a.narrative, contains('47.1%'));
    });

    test('没这个分类的支出：明说没有，不伪造 0 元', () {
      final FinanceAnswer a = buildFinanceAnswer(
        CategorySpendingIntent(period: _oct, categoryName: '娱乐', kind: 'expense'),
        _data(),
      );
      expect(a.narrative, contains('没有「娱乐」'));
      expect(a.headline, isNull);
    });

    test('二级账单计入父级：问「餐饮」要把记在「早餐」上的钱算进来', () {
      final FinanceAnswer a = buildFinanceAnswer(
        CategorySpendingIntent(period: _oct, categoryName: '餐饮', kind: 'expense'),
        _dataWithChild(),
      );
      expect(a.headline, '¥1,300.50', reason: '餐饮 1280.50 + 早餐 20.00');
      expect(a.narrative, contains('2 笔'));
    });

    test('问二级分类只算它自己，不会倒推整个父级', () {
      final FinanceAnswer a = buildFinanceAnswer(
        CategorySpendingIntent(period: _oct, categoryName: '早餐', kind: 'expense'),
        _dataWithChild(),
      );
      expect(a.headline, '¥20.00');
      expect(a.narrative, contains('1 笔'));
    });
  });

  group('预算', () {
    test('没超支：剩余、日均、每日可花', () {
      final FinanceAnswer a = buildFinanceAnswer(
        BudgetIntent(period: _oct),
        _data(budget: 300000),
      );
      expect(a.headline, '¥279.50');
      expect(a.narrative, contains('还剩 ¥279.50'));
      expect(a.narrative, contains('90.7%'));
      expect(a.narrative, contains('每天还能花'));
      expect(a.tone, AnswerTone.good);
    });

    test('超支：给超支额与「不要再花」的结论', () {
      final FinanceAnswer a = buildFinanceAnswer(
        BudgetIntent(period: _oct),
        _data(budget: 200000),
      );
      expect(a.tone, AnswerTone.warn);
      expect(a.narrative, contains('超支 ¥720.50'));
      expect(a.headline, '¥720.50');
    });

    test('没设预算：说清楚，并给已花金额', () {
      final FinanceAnswer a = buildFinanceAnswer(
        BudgetIntent(period: _oct),
        _data(),
      );
      expect(a.narrative, contains('还没设预算'));
      expect(a.narrative, contains('已经花了 ¥2,720.50'));
    });
  });

  group('环比对比', () {
    test('涨了：差额、百分比、涨最多的两个分类', () {
      final FinanceAnswer a = buildFinanceAnswer(
        CompareIntent(current: _oct, previous: _sep, categoryFocus: true),
        _data(),
      );
      expect(a.headline, '+¥1,430.50'); // 2720.50 - 1290.00
      expect(a.narrative, contains('多 ¥1,430.50'));
      expect(a.narrative, contains('110.9%'));
      expect(a.narrative, contains('餐饮'));
      expect(a.narrative, contains('购物'));
    });

    test('上期没有数据：明说没法比较', () {
      final FinanceAnswer a = buildFinanceAnswer(
        CompareIntent(current: _oct, previous: _sep, categoryFocus: false),
        _data(rows: _rows.where((TxRow t) => t.occurredAt >= _oct.startMs).toList()),
      );
      expect(a.narrative, contains('没有支出记录，没法比较'));
      expect(a.headline, isNull);
    });

    test('两期天数相当：不啰嗦，不加「注意」', () {
      final FinanceAnswer a = buildFinanceAnswer(
        CompareIntent(current: _oct, previous: _sep, categoryFocus: false),
        _data(),
      );
      expect(a.narrative, isNot(contains('注意')));
      expect(a.facts.any((AnswerFact f) => f.label.startsWith('日均')), isFalse);
    });

    // 真实场景回归：微信账单只导出了 8/29–9/29，8 月只有 3 天有记录 →
    // 直接拿总额比会把差距放大十几倍（实测线上出现过）。
    test('一期数据不完整（天数差一倍以上）：点破并给日均', () {
      final List<TxRow> sparse = <TxRow>[
        // 10 月：20 天都有记录
        for (int d = 1; d <= 20; d++)
          _tx(id: 'x$d', type: 'expense', cents: 10000, at: DateTime(2026, 10, d), categoryId: 'c-food'),
        // 9 月：只有 1 天有记录（相当于「上个月只有几天数据」）
        _tx(id: 'y1', type: 'expense', cents: 5000, at: DateTime(2026, 9, 30), categoryId: 'c-food'),
      ];
      final FinanceAnswer a = buildFinanceAnswer(
        CompareIntent(current: _oct, previous: _sep, categoryFocus: false),
        _data(rows: sparse),
      );
      expect(a.narrative, contains('注意'));
      expect(a.narrative, contains('直接比总额会放大差距'));
      expect(a.narrative, contains('按每天算'));
      expect(
        a.facts.where((AnswerFact f) => f.label.startsWith('日均')).length,
        2,
      );
    });
  });

  group('大额支出', () {
    test('按金额降序取前 N 笔，并给出占比', () {
      final FinanceAnswer a = buildFinanceAnswer(
        TopExpensesIntent(period: _oct, limit: 2),
        _data(),
      );
      expect(a.facts.length, 2);
      expect(a.facts.first.value, '¥1,280.50');
      expect(a.facts[1].value, '¥980.00');
      expect(a.narrative, contains('¥2,260.50')); // 1280.50 + 980
      expect(a.narrative, contains('83.1%'));
    });
  });

  group('储蓄目标', () {
    test('纯算术：月数向上取整 + 大约几月', () {
      final FinanceAnswer a = buildFinanceAnswer(
        const SavingsGoalIntent(monthlyCents: 200000, targetCents: 2000000),
        FinanceData(nowMs: _nowMs),
      );
      expect(a.headline, '10 个月');
      expect(a.narrative, contains('2027 年 8 月'));
      expect(a.narrative, contains('不含利息'));
    });

    test('除不尽时向上取整', () {
      final FinanceAnswer a = buildFinanceAnswer(
        const SavingsGoalIntent(monthlyCents: 300000, targetCents: 2000000),
        FinanceData(nowMs: _nowMs),
      );
      expect(a.headline, '7 个月'); // 20000 / 3000 = 6.67 → 7
    });
  });

  group('商户 / 备注', () {
    // 10 月：星巴克 3 笔（45 + 32 + 61），另有一笔「星巴克臻选」不该被「星巴克」以外的词影响
    final List<TxRow> rows = <TxRow>[
      _tx(id: 'm1', type: 'expense', cents: 4500, at: DateTime(2026, 10, 3), categoryId: 'c-food', note: '星巴克 拿铁'),
      _tx(id: 'm2', type: 'expense', cents: 3200, at: DateTime(2026, 10, 9), categoryId: 'c-food', note: '星巴克'),
      _tx(id: 'm3', type: 'expense', cents: 6100, at: DateTime(2026, 10, 20), categoryId: 'c-food', note: '星巴克 蛋糕'),
      _tx(id: 'm4', type: 'expense', cents: 2000, at: DateTime(2026, 10, 21), categoryId: 'c-food', note: '瑞幸'),
    ];

    test('合计 / 笔数 / 最近一笔都对得上', () {
      final FinanceAnswer a = buildFinanceAnswer(
        MerchantSpendingIntent(
          period: Period.month(2026, 10),
          keyword: '星巴克',
          kind: 'expense',
        ),
        FinanceData(rows: rows, categoryNames: _names, nowMs: _nowMs),
      );
      expect(a.headline, '¥138.00'); // 45 + 32 + 61
      expect(a.narrative, contains('共 3 笔'));
      expect(a.narrative, contains('10月20日')); // 最近一笔（不是最后插入的那条）
      expect(a.narrative, contains('¥61.00'));
    });

    test('没有匹配 → 明说没有，不编数字', () {
      final FinanceAnswer a = buildFinanceAnswer(
        MerchantSpendingIntent(
          period: Period.month(2026, 10),
          keyword: '肯德基',
          kind: 'expense',
        ),
        FinanceData(rows: rows, categoryNames: _names, nowMs: _nowMs),
      );
      expect(a.headline, isNull);
      expect(a.narrative, contains('没有备注里带「肯德基」的支出'));
    });

    test('只认方向：收入关键词不会把支出算进来', () {
      final List<TxRow> mixed = <TxRow>[
        ...rows,
        _tx(id: 'i1', type: 'income', cents: 50000, at: DateTime(2026, 10, 5), note: '星巴克 退款'),
      ];
      final FinanceAnswer a = buildFinanceAnswer(
        MerchantSpendingIntent(
          period: Period.month(2026, 10),
          keyword: '星巴克',
          kind: 'expense',
        ),
        FinanceData(rows: mixed, categoryNames: _names, nowMs: _nowMs),
      );
      expect(a.headline, '¥138.00', reason: '收入那笔不能被算进「花了多少」');
    });
  });

  group('不认识', () {
    test('给示例问题，不编答案', () {
      final FinanceAnswer a = buildFinanceAnswer(
        const UnknownIntent('帮我写首诗'),
        FinanceData(nowMs: _nowMs),
      );
      expect(a.suggestions, kExampleQuestions);
      expect(a.headline, isNull);
      expect(a.narrative, contains('只能答「账本里的数」'));
    });
  });
}
