import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/models/widget_stat_note.dart';
import 'package:inkpaper/services/random_review_selector_service.dart';
import 'package:inkpaper/services/widget_snapshot_service.dart';

void main() {
  Note note({
    required String id,
    required String content,
    required DateTime updatedAt,
    DateTime? createdAt,
    DateTime? displayTime,
    String rowStatus = 'NORMAL',
  }) =>
      Note(
        id: id,
        content: content,
        createdAt: createdAt ?? updatedAt,
        updatedAt: updatedAt,
        displayTime: displayTime,
        rowStatus: rowStatus,
      );

  group('RandomReviewSelectorService', () {
    test('excludes the previous batch when shuffling a new one', () {
      final now = DateTime.now();
      final notes = [
        for (var i = 0; i < 10; i++)
          note(
            id: 'note-$i',
            content: '第 $i 条',
            updatedAt: now.subtract(Duration(hours: i)),
          ),
      ];

      final first = RandomReviewSelectorService.select(
        notes: notes,
        reviewCount: 5,
        random: Random(1),
      );
      final second = RandomReviewSelectorService.select(
        notes: notes,
        reviewCount: 5,
        excludeIds: first.map((note) => note.id).toSet(),
        random: Random(2),
      );

      expect(first, hasLength(5));
      expect(second, hasLength(5));
      expect(
        second.map((note) => note.id).toSet().intersection(
              first.map((note) => note.id).toSet(),
            ),
        isEmpty,
        reason: '换一批必须整批换掉，不能和上一批重复',
      );
    });

    test('falls back to the whole pool when everything is excluded', () {
      final now = DateTime.now();
      final notes = [
        note(
          id: 'only-a',
          content: '库里只有两条',
          updatedAt: now.subtract(const Duration(days: 1)),
        ),
        note(
          id: 'only-b',
          content: '第二条',
          updatedAt: now.subtract(const Duration(days: 2)),
        ),
      ];

      final selected = RandomReviewSelectorService.select(
        notes: notes,
        reviewCount: 5,
        excludeIds: {'only-a', 'only-b'},
        random: Random(0),
      );

      // 库比一批还小时不能返回空，否则下拉一次就永远空着
      expect(selected, hasLength(2));
    });

    test('uses the same time range and tag AND filtering as random review', () {
      final now = DateTime.now();
      final notes = [
        note(
          id: 'recent-work-health',
          content: '今天复盘 #工作 #健康',
          updatedAt: now.subtract(const Duration(days: 1)),
        ),
        note(
          id: 'recent-work',
          content: '项目记录 #工作',
          updatedAt: now.subtract(const Duration(days: 2)),
        ),
        note(
          id: 'old-work-health',
          content: '很久以前 #工作 #健康',
          updatedAt: now.subtract(const Duration(days: 90)),
        ),
      ];

      final selected = RandomReviewSelectorService.select(
        notes: notes,
        reviewDays: 30,
        reviewCount: 5,
        selectedTags: {'工作', '健康'},
        random: Random(0),
      );

      expect(selected.map((note) => note.id), ['recent-work-health']);
    });

    test('falls back to all notes when the current filter has no matches', () {
      final now = DateTime.now();
      final notes = [
        note(
          id: 'old-a',
          content: '旧笔记 A #生活',
          updatedAt: now.subtract(const Duration(days: 60)),
        ),
        note(
          id: 'old-b',
          content: '旧笔记 B #生活',
          updatedAt: now.subtract(const Duration(days: 80)),
        ),
      ];

      final selected = RandomReviewSelectorService.select(
        notes: notes,
        reviewDays: 7,
        reviewCount: 5,
        random: Random(0),
      );

      expect(selected.map((note) => note.id).toSet(), {'old-a', 'old-b'});
    });

    test('uses display time instead of updated time for widget range', () {
      final now = DateTime.now();
      final selected = RandomReviewSelectorService.select(
        notes: [
          note(
            id: 'old-created-recently-synced',
            content: '旧笔记最近同步过',
            createdAt: now.subtract(const Duration(days: 120)),
            displayTime: now.subtract(const Duration(days: 120)),
            updatedAt: now,
          ),
          note(
            id: 'recent-created',
            content: '近期真正写下的笔记',
            updatedAt: now.subtract(const Duration(days: 2)),
          ),
        ],
        reviewDays: 30,
        reviewCount: 5,
        random: Random(0),
      );

      expect(selected.map((note) => note.id), ['recent-created']);
    });

    test('widget mode prefers notes with visible preview text', () {
      final now = DateTime.now();
      final notes = [
        note(
          id: 'image-only',
          content: '![](https://example.com/a.png)',
          updatedAt: now,
        ),
        note(
          id: 'text',
          content: '这条能显示在小组件',
          updatedAt: now,
        ),
      ];

      final selected = RandomReviewSelectorService.select(
        notes: notes,
        reviewCount: 5,
        random: Random(0),
        requireVisibleText: true,
      );

      expect(selected.map((note) => note.id), ['text']);
    });

    test('widget mode falls back to real notes when none has visible text', () {
      final now = DateTime.now();
      final notes = [
        note(
          id: 'image-only',
          content: '![](https://example.com/a.png)',
          updatedAt: now,
        ),
      ];

      final selected = RandomReviewSelectorService.selectWidgetCandidates(
        notes: notes,
        reviewCount: 5,
        random: Random(0),
      );

      expect(selected.map((note) => note.id), ['image-only']);
    });
  });

  group('RandomReviewSelectorService · 回顾时间窗', () {
    // OPT-04B：窗口必须精确到时刻，不能被放大成「自然日」
    final now = DateTime(2026, 11, 24, 18);

    test('RRS-01 7 天前同一时刻之后才算「最近 7 天」', () {
      final notes = [
        note(
          id: 'after',
          content: '刚好在界内',
          updatedAt: now,
          displayTime: DateTime(2026, 11, 17, 19),
        ),
        note(
          id: 'before',
          content: '差一小时，界外',
          updatedAt: now,
          displayTime: DateTime(2026, 11, 17, 9),
        ),
      ];

      final picked = RandomReviewSelectorService.selectWidgetCandidates(
        notes: notes,
        reviewDays: 7,
        reviewCount: 5,
        random: Random(0),
        now: now,
      );

      expect(
        picked.map((n) => n.id),
        ['after'],
        reason: '18:00 请求最近 7 天，7 天前 09:00 在范围外；'
            '按自然日比较会把它一起收进来',
      );
    });

    test('RRS-02 正落在下界那一毫秒仍在范围内', () {
      final notes = [
        note(
          id: 'edge',
          content: '正好 168 小时前',
          updatedAt: now,
          displayTime: DateTime(2026, 11, 17, 18),
        ),
      ];

      final picked = RandomReviewSelectorService.selectWidgetCandidates(
        notes: notes,
        reviewDays: 7,
        reviewCount: 5,
        random: Random(0),
        now: now,
      );

      expect(picked.map((n) => n.id), ['edge']);
    });

    test('RRS-03 跨日但不足 168 小时也在范围内', () {
      final notes = [
        note(
          id: 'late-yesterday',
          content: '7 天前 23:30',
          updatedAt: now,
          displayTime: DateTime(2026, 11, 17, 23, 30),
        ),
      ];

      final picked = RandomReviewSelectorService.selectWidgetCandidates(
        notes: notes,
        reviewDays: 7,
        reviewCount: 5,
        random: Random(0),
        now: now,
      );

      expect(picked.map((n) => n.id), ['late-yesterday']);
    });

    test('RRS-04 混存来源按挂钟比较，不按绝对时刻', () {
      // 伪 UTC（Memos 把北京时间当 UTC 存）与本地写法同一面墙的同一时刻
      // 必须落在同一边：19:00Z 的字段值是 19:00，不是 11:00。
      final notes = [
        note(
          id: 'remote-inside',
          content: '远端 19:00',
          updatedAt: now,
          displayTime: DateTime.utc(2026, 11, 17, 19),
        ),
        note(
          id: 'local-outside',
          content: '本地 09:00',
          updatedAt: now,
          displayTime: DateTime(2026, 11, 17, 9),
        ),
        note(
          id: 'remote-outside',
          content: '远端 02:00',
          updatedAt: now,
          displayTime: DateTime.utc(2026, 11, 17, 2),
        ),
        // 这条是分叉点：墙钟 14:00 在下界之前（排除），但按绝对时刻算就是
        // 17 日 22:00（纳入）。两种口径只在这一带给出不同结果。
        note(
          id: 'remote-split',
          content: '远端 14:00，墙钟在界外',
          updatedAt: now,
          displayTime: DateTime.utc(2026, 11, 17, 14),
        ),
      ];

      final picked = RandomReviewSelectorService.selectWidgetCandidates(
        notes: notes,
        reviewDays: 7,
        reviewCount: 5,
        random: Random(0),
        now: now,
      );

      expect(
        picked.map((n) => n.id),
        ['remote-inside'],
        reason: '带 Z 的那条字段值是 19:00，换算成绝对时刻就变成 11:00 了',
      );
    });

    test('RRS-05 统计行只靠 ISO 串比较，不解析 DateTime', () {
      WidgetStatNote row(String id, String displayIso) => WidgetStatNote(
            id: id,
            content: '内容 $id',
            createdAtIso: '2026-11-17T00:00:00.000',
            updatedAtIso: '2026-11-17T00:00:00.000',
            displayTimeIso: displayIso,
          );

      final rows = <WidgetStatNote>[
        row('key-inside', '2026-11-17T19:00:00.000'),
        row('key-outside', '2026-11-17T09:00:00.000'),
        // 库里带 Z 与带微秒的写法混着来，比较前都要截到 23 位
        row('key-remote', '2026-11-18T02:00:00.000Z'),
        row('key-micro', '2026-11-17T09:30:00.000123'),
      ];

      WidgetStatNote.debugLazyParseCount = 0;
      final picked = RandomReviewSelectorService.selectWidgetCandidatesFrom<
          WidgetStatNote>(
        notes: rows,
        reviewDays: 7,
        reviewCount: 5,
        random: Random(0),
        now: now,
        displayTimeKey: (note) => note.displayTimeKey,
        contentOf: (note) => note.content,
      );

      expect(
        picked.map((n) => n.id).toSet(),
        <String>{'key-inside', 'key-remote'},
      );
      expect(
        WidgetStatNote.debugLazyParseCount,
        0,
        reason: '区间判断只看字符串，不该为了过滤解析 DateTime',
      );
    });

    test('RRS-06 坏行（空时间串）被排除且不抛异常', () {
      final broken = WidgetStatNote(
        id: 'broken',
        content: '时间字段是空的',
        createdAtIso: '',
        updatedAtIso: '',
      );
      final good = WidgetStatNote(
        id: 'good',
        content: '正常一条',
        createdAtIso: '2026-11-20T10:00:00.000',
        updatedAtIso: '2026-11-20T10:00:00.000',
      );

      final picked = RandomReviewSelectorService.selectWidgetCandidatesFrom<
          WidgetStatNote>(
        notes: <WidgetStatNote>[broken, good],
        reviewDays: 7,
        reviewCount: 5,
        random: Random(0),
        now: now,
        displayTimeKey: (note) => note.displayTimeKey,
        contentOf: (note) => note.content,
      );

      expect(picked.map((n) => n.id), <String>['good']);
    });
  });

  group('WidgetSnapshotService', () {
    test('keeps image-only real notes in random review snapshot', () {
      final now = DateTime.now();
      final snapshot = WidgetSnapshotService.debugBuildSnapshot(
        notes: [
          note(
            id: 'image-only',
            content: '![](https://example.com/a.png)',
            updatedAt: now,
          ),
        ],
        isLocalMode: true,
        isLoggedIn: false,
        isSyncing: false,
      );

      final reviewNotes = snapshot['reviewNotes']! as List;
      expect(reviewNotes, hasLength(1));
      expect(reviewNotes.single, containsPair('id', 'image-only'));
      expect(reviewNotes.single, containsPair('preview', '这是一条含图片的笔记'));
    });

    test('treats unspecified row status as visible for old local notes', () {
      final now = DateTime.now();
      final snapshot = WidgetSnapshotService.debugBuildSnapshot(
        notes: [
          note(
            id: 'old-local',
            content: '旧数据也应该进入小组件随机回顾',
            updatedAt: now,
            rowStatus: 'ROW_STATUS_UNSPECIFIED',
          ),
        ],
        isLocalMode: true,
        isLoggedIn: false,
        isSyncing: false,
      );

      final reviewNotes = snapshot['reviewNotes']! as List;
      expect(reviewNotes, hasLength(1));
      expect(reviewNotes.single, containsPair('id', 'old-local'));
    });

    test('excludes archived notes from widget random review snapshot', () {
      final now = DateTime.now();
      final snapshot = WidgetSnapshotService.debugBuildSnapshot(
        notes: [
          note(
            id: 'archived',
            content: '归档笔记不应该出现在桌面小组件',
            updatedAt: now,
            rowStatus: 'ARCHIVED',
          ),
        ],
        isLocalMode: true,
        isLoggedIn: false,
        isSyncing: false,
      );

      final reviewNotes = snapshot['reviewNotes']! as List;
      expect(reviewNotes, isEmpty);
    });
  });
}
