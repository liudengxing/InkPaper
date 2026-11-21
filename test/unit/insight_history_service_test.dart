import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/services/insight_history_service.dart';

InsightReportEntry _entry(String content) => InsightReportEntry(
      id: 1,
      lensId: 'inversion',
      lensName: '逆向思考',
      scopeLabel: '全部笔记',
      noteCount: 210,
      content: content,
      createdAt: DateTime(2026, 11, 21, 20, 30),
    );

void main() {
  group('InsightReportEntry.preview', () {
    test('IH-01 压平换行、去掉引用角标', () {
      final entry = _entry('第一段判断。\n\n第二段带引用 [12][45]，还有 空格。');
      expect(entry.preview, '第一段判断。 第二段带引用 ，还有 空格。');
      expect(entry.preview, isNot(contains('[12]')));
      expect(entry.preview, isNot(contains('\n')));
    });

    test('IH-02 超长摘要截断到 90 字以内并加省略号', () {
      final entry = _entry('字' * 300);
      expect(entry.preview.length, 91);
      expect(entry.preview.endsWith('…'), isTrue);
    });

    test('IH-03 短文不截断', () {
      expect(_entry('短的一句话。').preview, '短的一句话。');
    });
  });
}
