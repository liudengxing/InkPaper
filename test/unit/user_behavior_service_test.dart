import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/services/user_behavior_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('UserBehaviorService 浏览埋点', () {
    test('点击 + 详情页关闭回填：同一笔浏览只落一条记录且时长被写入', () async {
      final service = UserBehaviorService();

      await service.recordClick(
        noteId: 'n1',
        noteTags: ['java', '并发'],
        source: 'related_sheet',
      );

      await service.completeView(
        noteId: 'n1',
        noteTags: ['java', '并发'],
        viewDurationSeconds: 42,
      );

      final history = await service.getClickHistory();
      expect(history, hasLength(1));
      expect(history.first.noteId, 'n1');
      expect(history.first.viewDuration, 42);
      expect(history.first.source, 'related_sheet');
    });

    test('没有前置点击时 completeView 独立落一条记录', () async {
      final service = UserBehaviorService();

      await service.completeView(
        noteId: 'n2',
        noteTags: ['jvm'],
        viewDurationSeconds: 30,
      );

      final history = await service.getClickHistory();
      expect(history, hasLength(1));
      expect(history.first.noteId, 'n2');
      expect(history.first.viewDuration, 30);
      expect(history.first.source, 'detail');
    });

    test('浏览不足 3 秒视为误触，不落任何记录', () async {
      final service = UserBehaviorService();

      await service.completeView(
        noteId: 'n3',
        noteTags: const [],
        viewDurationSeconds: 2,
      );

      final history = await service.getClickHistory();
      expect(history, isEmpty);
    });

    test('平均时长只统计有时长的记录，不再被 0 时长点击拉低', () async {
      final service = UserBehaviorService();

      // 两次真实浏览：20s 和 40s
      await service.completeView(
        noteId: 'n4',
        noteTags: const ['mysql'],
        viewDurationSeconds: 20,
      );
      await service.completeView(
        noteId: 'n5',
        noteTags: const ['mysql'],
        viewDurationSeconds: 40,
      );

      final preference = await service.getUserPreference();
      expect(preference.totalClicks, 2);
      expect(preference.avgViewDuration, 30);
    });

    test('偏好画像：结构化标签与关系类型进入统计，样本足够后给个性化加成', () async {
      final service = UserBehaviorService();

      for (var i = 0; i < 6; i++) {
        await service.recordClick(
          noteId: 'n$i',
          noteTags: const ['docker'],
          source: 'card',
        );
      }

      final preference = await service.getUserPreference();
      expect(preference.hasEnoughData, isTrue);
      expect(preference.favoriteTags['docker'], 6);
      expect(preference.getTopTags(1), ['docker']);
    });

    test('清除数据后历史与偏好都归零', () async {
      final service = UserBehaviorService();

      await service.completeView(
        noteId: 'n6',
        noteTags: const ['redis'],
        viewDurationSeconds: 10,
      );
      await service.clearAllData();

      final history = await service.getClickHistory();
      final preference = await service.getUserPreference();
      expect(history, isEmpty);
      expect(preference.totalClicks, 0);
    });
  });
}
