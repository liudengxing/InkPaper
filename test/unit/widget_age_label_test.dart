// ============================================================
// 桌面小组件 · 语境标签（「去年今日」这类时间层）
// ============================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/services/widget_snapshot_service.dart';

void main() {
  // 固定「今天」，所有断言都在它上面偏移，跑多久都不会漂。
  final now = DateTime(2026, 11, 17, 15, 30);

  String label(DateTime time) =>
      WidgetSnapshotService.formatReviewAgeLabel(time, now: now);

  group('WS-A 语境标签', () {
    test('WS-A01 一小时内是「刚刚」', () {
      expect(label(DateTime(2026, 11, 17, 15, 10)), '刚刚');
    });

    test('WS-A02 当天几小时前按小时说', () {
      expect(label(DateTime(2026, 11, 17, 11, 30)), '4 小时前');
    });

    test('WS-A03 落在「未来」的脏数据按今天处理', () {
      // Memos 的伪 UTC 会让绝对时刻看起来晚 8 小时，不能因此显示成负数天。
      expect(label(DateTime(2026, 11, 17, 23)), '今天');
    });

    test('WS-A04 昨天 / N 天前 / 上周', () {
      expect(label(DateTime(2026, 11, 16, 9)), '昨天');
      expect(label(DateTime(2026, 11, 14)), '3 天前');
      expect(label(DateTime(2026, 11, 8)), '上周');
      expect(label(DateTime(2026, 11, 2)), '2 周前');
    });

    test('WS-A05 同月同日给周年说法', () {
      expect(label(DateTime(2025, 11, 17, 8)), '去年今日');
      expect(label(DateTime(2023, 11, 17, 8)), '3 年前的今天');
    });

    test('WS-A06 更久远的按月、按年、按年月', () {
      expect(label(DateTime(2026, 10, 3)), '上个月');
      expect(label(DateTime(2026, 8, 20)), '2 个月前');
      expect(label(DateTime(2025, 9)), '去年');
      expect(label(DateTime(2024, 5, 6)), '2 年前');
      expect(label(DateTime(2021, 3, 2)), '2021 年 3 月');
    });
  });
}
