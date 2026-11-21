import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/utils/typewriter_text.dart';

void main() {
  group('typewriteStep', () {
    test('目标与已显示一致时原样返回', () {
      expect(typewriteStep('今天', '今天'), '今天');
      expect(typewriteStep('', ''), '');
    });

    test('积压少时一次只吐一个字', () {
      expect(typewriteStep('今天爬山', ''), '今');
      expect(typewriteStep('今天爬山', '今'), '今天');
      expect(typewriteStep('今天爬山', '今天'), '今天爬');
    });

    test('积压多时按比例加速，且不会越界', () {
      final target = '字' * 100;
      final next = typewriteStep(target, '');
      // 1 + (100 - 1) ~/ 4 = 25
      expect(next.length, 25);
      expect(target.startsWith(next), isTrue);
      expect(typewriteStep(target, '字' * 90).length, greaterThan(90));
      expect(typewriteStep(target, '字' * 99), target);
    });

    test('目标换了内容时直接对齐，不做逐字', () {
      expect(typewriteStep('新的正文', '旧的内'), '新的正文');
    });

    test('不把 emoji 的代理对劈成半个字符', () {
      // 目标开头是一个 emoji（两个 UTF-16 单元），落点正好卡在中间
      const target = '🙂好';
      final next = typewriteStep(target, '');
      expect(next, '🙂');
      expect(typewriteStep(target, next), target);
    });
  });
}
