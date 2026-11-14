import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/utils/note_timestamp_format.dart';

/// 时间格式化口径的回归测试。
///
/// 背景：Memos 服务端返回的 `createdAt` 是 `2021-08-09T19:53:00Z`，但那个
/// 19:53 本来就是发布者的本地挂钟时间（部署时把北京时间当 UTC 存了）。
/// 解析成 UTC DateTime 后「字段值」才是用户看到的那个时刻，一旦再 toLocal
/// 就会平白多加 8 小时 —— 曾经小部件就因此和详情页差了一天。
void main() {
  group('formatNoteTimestamp', () {
    test('往年：显示完整日期与分钟', () {
      expect(
        formatNoteTimestamp(DateTime(2021, 8, 9, 19, 53)),
        '2021-08-09 19:53',
      );
    });

    test('UTC 标记的时间不做时区换算', () {
      // 用固定往年，避免受运行时的年月影响
      final ts = DateTime.utc(2021, 8, 9, 19, 53);
      expect(ts.isUtc, isTrue);
      expect(formatNoteTimestamp(ts), '2021-08-09 19:53');
    });

    test('同值时间不论本地还是 UTC 标记，输出一致', () {
      final utc = DateTime.utc(2024, 3, 5, 20, 15);
      final local = DateTime(2024, 3, 5, 20, 15);
      expect(formatNoteTimestamp(utc), formatNoteTimestamp(local));
      expect(formatNoteTimestamp(utc), '2024-03-05 20:15');
    });

    test('今年非今天：省掉年份，保留月日与分钟', () {
      final now = DateTime.now();
      // 挑一个与今天不同的日子，避开「今天只显示时间」的分支
      final day = now.month == 1 && now.day == 1
          ? DateTime(now.year, 1, 2, 9, 30)
          : DateTime(now.year, 1, 1, 9, 30);
      final expected =
          day.month == 1 && day.day == 1 ? '01-01 09:30' : '01-02 09:30';
      expect(formatNoteTimestamp(day), expected);
    });

    test('今天：只显示时间', () {
      final now = DateTime.now();
      final ts = DateTime(now.year, now.month, now.day, 9, 30);
      expect(formatNoteTimestamp(ts), '09:30');
    });
  });
}
