// ============================================================
// 单元测试 · 桌面小组件快照的统计与置顶字段
// 周/月统计组件完全靠这份快照出图，日期分组错了整个格子墙就偏一天
// ============================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/services/widget_snapshot_service.dart';

void main() {
  Note note({
    required String id,
    required String content,
    required DateTime createdAt,
    bool isPinned = false,
  }) =>
      Note(
        id: id,
        content: content,
        createdAt: createdAt,
        updatedAt: createdAt,
        isPinned: isPinned,
        rowStatus: 'NORMAL',
      );

  Map<String, Object?> build(List<Note> notes) =>
      WidgetSnapshotService.debugBuildSnapshot(
        notes: notes,
        isLocalMode: true,
        isLoggedIn: false,
        isSyncing: false,
      );

  group('WidgetSnapshotService 统计', () {
    test('WS-S01 周统计按周一起算，todayIndex 指向今天', () {
      final now = DateTime.now();
      final snapshot = build(<Note>[]);
      final week = (snapshot['stats'] as Map)['week'] as Map;

      expect((week['days'] as List).length, 7);
      expect(week['todayIndex'], now.weekday - 1);
    });

    test('WS-S02 今天记了几条就点几格，总数对得上', () {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day, 9);
      final snapshot = build(<Note>[
        note(id: 'a', content: '一', createdAt: today),
        note(
            id: 'b',
            content: '二',
            createdAt: today.add(const Duration(hours: 1))),
        note(
            id: 'c',
            content: '三',
            createdAt: today.add(const Duration(hours: 2))),
      ]);
      final week = (snapshot['stats'] as Map)['week'] as Map;
      final days = (week['days'] as List).cast<int>();

      expect(days[now.weekday - 1], 3);
      expect(week['total'], 3);
    });

    test('WS-S03 月统计的格子数等于当月天数，并带上 1 号是周几', () {
      final now = DateTime.now();
      final snapshot = build(<Note>[]);
      final month = (snapshot['stats'] as Map)['month'] as Map;

      expect(
        (month['days'] as List).length,
        DateTime(now.year, now.month + 1, 0).day,
      );
      expect(month['firstWeekday'], DateTime(now.year, now.month).weekday);
    });

    test('WS-S04 月统计能把不同日期的笔记分到各自格子', () {
      final now = DateTime.now();
      final first = DateTime(now.year, now.month, 1, 8);
      final second = DateTime(now.year, now.month, 1, 20);
      final snapshot = build(<Note>[
        note(id: 'a', content: '一号早', createdAt: first),
        note(id: 'b', content: '一号晚', createdAt: second),
      ]);
      final days = ((snapshot['stats'] as Map)['month'] as Map)['days'] as List;

      expect(days.first, 2);
      expect(days.skip(1).every((count) => count == 0), isTrue);
    });

    test('WS-S05 没有软删以外的过滤会漏，置顶笔记单独进 pinnedNote', () {
      final now = DateTime.now();
      final snapshot = build(<Note>[
        note(
          id: 'pinned',
          content: '置顶这条',
          createdAt: now.subtract(const Duration(days: 3)),
          isPinned: true,
        ),
        note(
          id: 'normal',
          content: '普通这条',
          createdAt: now.subtract(const Duration(days: 1)),
        ),
      ]);
      final pinned = snapshot['pinnedNote'] as Map?;

      expect(pinned, isNotNull);
      expect(pinned!['id'], 'pinned');
      expect(pinned['previewLong'], contains('置顶这条'));
    });

    test('WS-S06 没有置顶笔记时 pinnedNote 为 null，不留空壳', () {
      final snapshot = build(<Note>[
        note(id: 'a', content: '随便一条', createdAt: DateTime.now()),
      ]);

      expect(snapshot['pinnedNote'], isNull);
    });

    test('WS-S07 软删的笔记不进统计也不当置顶', () {
      final snapshot = build(<Note>[
        Note(
          id: 'deleted',
          content: '删掉的',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          isPinned: true,
          rowStatus: 'ARCHIVED',
        ),
      ]);
      final stats = snapshot['stats'] as Map;

      expect((stats['week'] as Map)['total'], 0);
      expect(snapshot['pinnedNote'], isNull);
    });
  });
}
