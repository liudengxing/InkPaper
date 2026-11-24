// ============================================================
// 单元测试 · 桌面小组件快照的统计与置顶字段
// 周/月统计组件完全靠这份快照出图，日期分组错了整个格子墙就偏一天
// ============================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/models/widget_stat_note.dart';
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
      );

  Map<String, Object?> asMap(Object? value) => value! as Map<String, Object?>;

  List<int> asInts(Object? value) => (value! as List<Object?>).cast<int>();

  Map<String, Object?> build(List<Note> notes) =>
      WidgetSnapshotService.debugBuildSnapshot(
        notes: notes,
        isLocalMode: true,
        isLoggedIn: false,
        isSyncing: false,
      );

  /// 直接喂「库里的原始 ISO 串」，模拟本地写法与 Memos 伪 UTC 混存。
  Map<String, Object?> buildFromRows(List<WidgetStatNote> rows) =>
      WidgetSnapshotService.debugBuildSnapshotFromRows(
        notes: rows,
        isLocalMode: true,
        isLoggedIn: false,
        isSyncing: false,
      );

  group('WidgetSnapshotService 统计', () {
    test('WS-S01 周统计按周一起算，todayIndex 指向今天', () {
      final now = DateTime.now();
      final snapshot = build(<Note>[]);
      final week = asMap(asMap(snapshot['stats'])['week']);

      expect(asInts(week['days']).length, 7);
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
          createdAt: today.add(const Duration(hours: 1)),
        ),
        note(
          id: 'c',
          content: '三',
          createdAt: today.add(const Duration(hours: 2)),
        ),
      ]);
      final week = asMap(asMap(snapshot['stats'])['week']);

      expect(asInts(week['days'])[now.weekday - 1], 3);
      expect(week['total'], 3);
    });

    test('WS-S03 月统计的格子数等于当月天数，并带上 1 号是周几与今天的位置', () {
      final now = DateTime.now();
      final snapshot = build(<Note>[]);
      final month = asMap(asMap(snapshot['stats'])['month']);

      expect(
        asInts(month['days']).length,
        DateTime(now.year, now.month + 1, 0).day,
      );
      expect(month['firstWeekday'], DateTime(now.year, now.month).weekday);
      // 月格子墙是顺序铺的，今天那格要能描边，所以必须带出今天的下标。
      expect(month['todayIndex'], now.day - 1);
    });

    test('WS-S04 月统计能把不同日期的笔记分到各自格子', () {
      final now = DateTime.now();
      final snapshot = build(<Note>[
        note(
          id: 'a',
          content: '一号早',
          createdAt: DateTime(now.year, now.month, 1, 8),
        ),
        note(
          id: 'b',
          content: '一号晚',
          createdAt: DateTime(now.year, now.month, 1, 20),
        ),
      ]);
      final days = asInts(asMap(asMap(snapshot['stats'])['month'])['days']);

      expect(days.first, 2);
      expect(days.skip(1).every((count) => count == 0), isTrue);
    });

    test('WS-S05 置顶笔记单独进 pinnedNote，并带上长预览', () {
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
      final pinned = snapshot['pinnedNote'];

      expect(pinned, isNotNull);
      expect(asMap(pinned)['id'], 'pinned');
      expect(asMap(pinned)['previewLong'], contains('置顶这条'));
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
      final stats = asMap(snapshot['stats']);

      expect(asMap(stats['week'])['total'], 0);
      expect(snapshot['pinnedNote'], isNull);
    });
  });

  group('WidgetSnapshotService · 时间口径（OPT-04B）', () {
    String two(int v) => v.toString().padLeft(2, '0');
    final now = DateTime.now();
    final dayKey = '${now.year}-${two(now.month)}-${two(now.day)}';

    WidgetStatNote row({
      required String id,
      required String displayIso,
      bool isPinned = false,
    }) =>
        WidgetStatNote(
          id: id,
          content: '内容 $id',
          createdAtIso: displayIso,
          updatedAtIso: displayIso,
          displayTimeIso: displayIso,
          isPinned: isPinned,
        );

    /// 当月第 [day] 天落在月统计格子的条数
    int countOnMonthDay(Map<String, Object?> snapshot, int day) {
      final month = asMap(asMap(snapshot['stats'])['month']);
      return asInts(month['days'])[day - 1];
    }

    test('WS-S08 伪 UTC 与本地写法按挂钟归到同一天', () {
      final snapshot = buildFromRows(<WidgetStatNote>[
        // Memos 把北京时间当 UTC 存：字段值 23:30 就是 23:30
        row(id: 'remote-late', displayIso: '${dayKey}T23:30:00.000Z'),
        row(id: 'local-morning', displayIso: '${dayKey}T09:00:00.000'),
      ]);

      expect(
        countOnMonthDay(snapshot, now.day),
        2,
        reason: '换算成绝对时刻的话，23:30Z 会落到次日 07:30，这一格就只剩 1 条',
      );
    });

    test('WS-S09 多条置顶取挂钟更晚的那条，不受 Z 后缀影响', () {
      final snapshot = buildFromRows(<WidgetStatNote>[
        row(
          id: 'pinned-remote',
          displayIso: '${dayKey}T02:00:00.000Z',
          isPinned: true,
        ),
        row(
          id: 'pinned-local',
          displayIso: '${dayKey}T09:00:00.000',
          isPinned: true,
        ),
      ]);

      expect(
        asMap(snapshot['pinnedNote'])['id'],
        'pinned-local',
        reason: '挂钟 09:00 晚于 02:00；按绝对时刻算会把远端那条排前面',
      );
    });

    test('WS-S10 坏行（空时间串）不让整份快照失败', () {
      final snapshot = buildFromRows(<WidgetStatNote>[
        WidgetStatNote(
          id: 'broken',
          content: '时间字段是空的',
          createdAtIso: '',
          updatedAtIso: '',
        ),
        row(id: 'good', displayIso: '${dayKey}T09:00:00.000'),
      ]);

      expect(snapshot['stats'], isNotNull);
      expect(countOnMonthDay(snapshot, now.day), 1);
    });
  });
}
