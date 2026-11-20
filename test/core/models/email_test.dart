/// `Email` 值对象（技术债清理）：归一化只此一条路。
///
/// 为什么单测它：邮箱以前是裸 `String`，「去空格 + 小写」散在三处，
/// 任何一处漏掉都会让 `ownerId` 精确比较失败 → 整本账不可见（SPEC-P6.5 D2）。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:yanxin/core/models/email.dart';

void main() {
  group('tryParse：归一化', () {
    test('trim + 小写', () {
      expect(Email.tryParse('  Me@Example.COM '), Email.tryParse('me@example.com'));
      expect(Email.tryParse('  Me@Example.COM ')?.value, 'me@example.com');
    });

    test('同一个地址的不同写法 → 相等（可作为 Map key / 切号判据）', () {
      final Email a = Email.tryParse('A@B.com')!;
      final Email b = Email.tryParse(' a@b.com')!;
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(<Email>{a, b}.length, 1);
    });

    test('toString 就是归一化后的值（日志 / 拼键不会拿到脏值）', () {
      expect(Email.tryParse(' X@Y.CN ')!.toString(), 'x@y.cn');
    });
  });

  group('校验：非法一律 null / false', () {
    const List<String> bad = <String>[
      '',
      '   ',
      'a@b',
      '@b.com',
      'a@.com',
      'a@b.',
      'a@b@c.com',
      'no-at-sign',
    ];
    for (final String raw in bad) {
      test('「$raw」→ 非法', () {
        expect(Email.tryParse(raw), isNull);
        expect(Email.isValid(raw), isFalse);
      });
    }

    test('null → 非法（不抛）', () {
      expect(Email.tryParse(null), isNull);
      expect(Email.isValid(null), isFalse);
    });

    test('带加号 / 子域 / 大写 都算合法', () {
      expect(Email.isValid(' a.b+c@sub.example.cn '), isTrue);
    });
  });
}
