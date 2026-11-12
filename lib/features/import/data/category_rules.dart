/// 分类关键词规则（v1 内置静态表）— 旧栈 `bill-import/categorize.js` 的移植。
///
/// 约定：
/// - 有序规则表，先命中先赢（顺序即优先级：越具体/越高频的越靠前）
/// - 匹配 `交易对方 + 商品名`，包含匹配，不区分大小写
/// - 未命中落「其他」（支出/收入各自的「其他」）
/// - v1 不做机器学习/自适应；不准就落其他，导入后用户可改
library;

import 'bill_normalize.dart' show ParsedRow;

/// 单条分类规则。
class CategoryRule {
  const CategoryRule(this.kind, this.category, this.pattern);

  final String kind; // 'expense' | 'income'
  final String category; // 预置分类名
  final RegExp pattern;
}

/// 有序规则表（顺序即优先级）。
final categoryRules = <CategoryRule>[
  // ── 支出（高频品牌优先，通用品类词殿后）──
  CategoryRule('expense', '餐饮', RegExp(r'美团|饿了么')),
  CategoryRule(
    'expense',
    '餐饮',
    RegExp(r'肯德基|麦当劳|星巴克|瑞幸|汉堡|比萨|披萨|寿司'),
  ),
  CategoryRule('expense', '餐饮', RegExp(r'外卖|餐饮|餐厅|食堂')),
  CategoryRule(
    'expense',
    '餐饮',
    RegExp(r'咖啡|奶茶|面馆|小吃|烧烤|火锅'),
  ),
  CategoryRule(
    'expense',
    '交通',
    RegExp(r'滴滴|高德|曹操|t3出行|网约车|打车'),
  ),
  CategoryRule('expense', '交通', RegExp(r'地铁|公交|单车|哈啰|摩拜')),
  CategoryRule(
    'expense',
    '交通',
    RegExp(r'加油|中国石化|中国石油|加油站'),
  ),
  CategoryRule('expense', '交通', RegExp(r'停车|高速|etc')),
  CategoryRule(
    'expense',
    '交通',
    RegExp(r'火车|铁路|12306|机票|航空|航班'),
  ),
  CategoryRule('expense', '购物', RegExp(r'淘宝|天猫')),
  CategoryRule('expense', '购物', RegExp(r'京东')),
  CategoryRule(
    'expense',
    '购物',
    RegExp(r'拼多多|唯品会|苏宁|抖音商城'),
  ),
  CategoryRule(
    'expense',
    '购物',
    RegExp(r'超市|便利店|商场|百货|旗舰店|专营店'),
  ),
  // 「零食有鸣」这类零食集合店（F8.1 真实截图样本里出现，落「其他」不合适）
  CategoryRule('expense', '购物', RegExp(r'零食|生鲜|菜市场|水果店')),
  CategoryRule('expense', '购物', RegExp(r'数码|服饰|服装')),
  CategoryRule('expense', '居住', RegExp(r'房租|房东|中介|链家|自如')),
  CategoryRule(
    'expense',
    '居住',
    RegExp(r'物业|水费|电费|水电|燃气|热力|取暖'),
  ),
  // 话费 / 流量 / 宽带 → 通讯。
  //
  // 真机走查（2026-10-27）抓到过：`手机充值-中国联通` 原本落「居住」，用户当场质疑。
  // 预置分类里**本来就有「通讯」**，是规则表写错了组。
  CategoryRule(
    'expense',
    '通讯',
    RegExp(r'话费|充值.*流量|中国移动|中国联通|中国电信|宽带'),
  ),
  CategoryRule('expense', '娱乐', RegExp(r'电影|影院|票房')),
  CategoryRule('expense', '娱乐', RegExp(r'游戏|steam|steam充值|游戏点卡')),
  CategoryRule(
    'expense',
    '娱乐',
    RegExp(r'腾讯视频|爱奇艺|优酷|芒果tv|会员充值'),
  ),
  CategoryRule('expense', '娱乐', RegExp(r'音乐|网易云音乐|qq音乐')),
  // 旅游 / 住宿 / 门票 → 旅行（预置分类里有「旅行」，此前从没被规则命中过）。
  // `发给~青年旅社` 曾是「其他」，用户认为该进旅行。
  CategoryRule(
    'expense',
    '旅行',
    RegExp(r'旅游|门票|景区|酒店|民宿|旅社|住宿|青旅'),
  ),
  CategoryRule('expense', '娱乐', RegExp(r'ktv|团购|生活服务')),
  CategoryRule('expense', '医疗', RegExp(r'医院|诊所|挂号|体检')),
  CategoryRule(
    'expense',
    '医疗',
    RegExp(r'药店|药房|口腔|牙科|眼科|疫苗'),
  ),
  CategoryRule('expense', '教育', RegExp(r'学费|培训|课程|网课|报名费')),
  CategoryRule('expense', '教育', RegExp(r'考试|教育|学堂')),
  CategoryRule('expense', '教育', RegExp(r'书店|图书|新华')),
  // ⚠️ 分类名必须与 `presetExpense` 完全一致：导入是「按名字查 id」，
  // 差一个字就会静默落「其他」（曾经写成人情 / 理财 / 红包，全部查不到）。
  CategoryRule('expense', '人情社交', RegExp(r'礼金|随礼|礼物|鲜花')),
  CategoryRule('expense', '人情社交', RegExp(r'捐赠|捐款|请客|代付')),

  // ── 收入 ──
  CategoryRule('income', '工资', RegExp(r'工资|薪水|薪金|工资代发')),
  CategoryRule('income', '工资', RegExp(r'劳务|报酬')),
  CategoryRule('income', '奖金', RegExp(r'奖金|年终奖|绩效|提成')),
  CategoryRule('income', '投资收益', RegExp(r'理财|基金|股票|债券')),
  CategoryRule(
    'income',
    '投资收益',
    RegExp(r'利息|收益|余额宝|零钱通|分红'),
  ),
  CategoryRule('income', '兼职', RegExp(r'兼职|外快')),
  CategoryRule('income', '兼职', RegExp(r'稿费|稿酬|佣金|赏金|接单')),
  CategoryRule('income', '红包礼金', RegExp(r'红包|现金')),
  CategoryRule('income', '红包礼金', RegExp(r'转账|收款|退款到账')),
  // 退款有独立分类（收入侧），别再并进红包
  CategoryRule('income', '退款', RegExp(r'退款')),
];

/// 分类结果。
class CategorizeResult {
  const CategorizeResult({required this.categoryName, required this.matched});

  final String categoryName;
  final bool matched;
}

/// 归一化后的行 -> 分类名。
CategorizeResult categorizeRow(ParsedRow row) {
  // 拼接后统一小写做包含匹配（中文不受影响，英文/品牌名大小写归一）
  final text = '${row.counterparty} ${row.product}'.toLowerCase();
  for (final rule in categoryRules) {
    if (rule.kind != row.direction) continue;
    if (rule.pattern.hasMatch(text)) {
      return CategorizeResult(categoryName: rule.category, matched: true);
    }
  }
  return const CategorizeResult(categoryName: '其他', matched: false);
}
