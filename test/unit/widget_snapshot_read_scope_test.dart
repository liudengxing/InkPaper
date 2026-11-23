// ============================================================
// OPT-04 · 桌面小组件快照的读取范围
//
// 背景：以前一次快照构建 = `getNotes()` 整库构造完整笔记（每行还要解
// relations / resourceList 两段 JSON）+ 为了挑 8 条回顾候选又对全库每条跑
// 一遍 `previewVisibleText`（完整 Markdown 解析）。
//
// 现在拆成三块：
// - 统计与回顾：`getWidgetStatNotes()` 窄列（不读关系 JSON）
// - 首屏快照：`getRecentActiveNotes(20)` 完整行（落盘要 toMap）
// - 回顾挑选：洗牌后边取边判可见文字，取满就停
//
// 这里验证拆开之后快照内容没变、首屏字段一个不少、已删除行不进来。
// ============================================================

import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/services/database_service.dart';
import 'package:inkpaper/services/random_review_selector_service.dart';
import 'package:inkpaper/services/widget_snapshot_service.dart';
import 'package:inkpaper/utils/memos_content_helper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> _openTestDb() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  return databaseFactory.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(
      version: DatabaseService.schemaVersion,
      singleInstance: false,
      onCreate: (db, version) async {
        await DatabaseService.createSchema(db);
      },
    ),
  );
}

Map<String, Object?> _row(
  String id,
  String content,
  DateTime created, {
  String tag = '随笔',
  bool pinned = false,
  bool synced = true,
  String rowStatus = 'NORMAL',
  List<Map<String, Object?>>? relations,
  List<Map<String, Object?>>? resources,
}) =>
    <String, Object?>{
      'id': id,
      'content': content,
      'createdAt': created.toIso8601String(),
      'updatedAt': created.toIso8601String(),
      'displayTime': created.toIso8601String(),
      'tags': tag,
      'creator': 'local',
      'is_synced': synced ? 1 : 0,
      'isPinned': pinned ? 1 : 0,
      'visibility': 'PRIVATE',
      'resourceList': jsonEncode(resources ?? const <Map<String, Object?>>[]),
      'relations': jsonEncode(relations ?? const <Map<String, Object?>>[]),
      'rowStatus': rowStatus,
    };

Map<String, Object?> _snapshot(
  List<Note> notes, {
  required int seed,
  int reviewRangeDays = 0,
}) =>
    WidgetSnapshotService.debugBuildSnapshot(
      notes: notes,
      isLocalMode: true,
      isLoggedIn: false,
      isSyncing: false,
      reviewRangeDays: reviewRangeDays,
      random: Random(seed),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Database db;
  late DatabaseService service;

  setUp(() async {
    db = await _openTestDb();
    service = DatabaseService();
    DatabaseService.debugOverrideDatabase(db);
  });

  tearDown(() async {
    DatabaseService.debugOverrideDatabase(null);
    await db.close();
  });

  Future<void> seed(List<Map<String, Object?>> rows) async {
    final batch = db.batch();
    for (final row in rows) {
      batch.insert('notes', row);
    }
    await batch.commit(noResult: true);
  }

  test('WSR-01 窄列读取保留统计口径字段，不再带关系 JSON', () async {
    final now = DateTime.now();
    await seed(<Map<String, Object?>>[
      _row(
        'a',
        '有引用的一条 #标签A',
        now,
        tag: '标签A,随笔',
        pinned: true,
        synced: false,
        relations: <Map<String, Object?>>[
          <String, Object?>{
            'type': 'REFERENCE',
            'memoId': 'a',
            'relatedMemoId': 'b',
          },
        ],
        resources: <Map<String, Object?>>[
          <String, Object?>{
            'uid': 'res-1',
            'type': 'image/png',
            'filename': 'cover.png',
          },
        ],
      ),
      _row('b', '普通笔记', now.subtract(const Duration(hours: 1))),
      _row(
        'gone',
        '已删除的笔记',
        now.subtract(const Duration(hours: 2)),
        rowStatus: 'DELETED',
      ),
    ]);

    final statNotes = await service.getWidgetStatNotes();

    expect(statNotes.map((note) => note.id), <String>['a', 'b']);
    final first = statNotes.first;
    expect(first.content, '有引用的一条 #标签A');
    expect(first.tags, <String>['标签A', '随笔']);
    expect(first.isPinned, isTrue);
    expect(first.isSynced, isFalse);
    // 关系不参与统计：窄列读取不解那段 JSON，省掉每行一次 jsonDecode。
    expect(first.relations, isEmpty);
    // 附件要留着：「这是一条含图片的笔记」靠它判断。
    expect(first.resourceList, hasLength(1));
    expect(first.displayTime, now);
  });

  test('WSR-02 窄列读出来的快照与整库完整笔记逐字段一致', () async {
    final now = DateTime.now();
    await seed(<Map<String, Object?>>[
      _row(
        'text-1',
        '今天写了一条带待办的笔记\n- [ ] 还没做\n- [x] 做完了',
        now.subtract(const Duration(minutes: 5)),
        tag: '工作,随笔',
        pinned: true,
      ),
      _row(
        'text-2',
        '另一条正文，带 #标签B',
        now.subtract(const Duration(days: 1)),
        tag: '标签B',
        synced: false,
      ),
      _row(
        'image-only',
        '![](https://example.com/a.png)',
        now.subtract(const Duration(days: 2)),
        resources: <Map<String, Object?>>[
          <String, Object?>{
            'uid': 'res-9',
            'type': 'image/png',
            'filename': 'a.png',
          },
        ],
      ),
      _row(
        'archived',
        '归档笔记不参与回顾，但仍是标签库的一部分',
        now.subtract(const Duration(days: 3)),
        tag: '旧标签',
        rowStatus: 'ARCHIVED',
      ),
    ]);

    final full = await service.getNotes();
    final stat = await service.getWidgetStatNotes();

    // generatedAt 是「构建那一刻」的时间戳，两次构建必然不同。
    Map<String, Object?> withoutTimestamp(Map<String, Object?> snapshot) =>
        Map<String, Object?>.from(snapshot)..remove('generatedAt');

    final fromFull = withoutTimestamp(_snapshot(full, seed: 11));
    final fromStat = withoutTimestamp(_snapshot(stat, seed: 11));

    expect(fromStat, equals(fromFull));
    // 顺带确认这份快照不是空的，否则「一致」没意义
    expect(fromStat['today'], isA<Map<String, Object?>>());
    expect(fromStat['reviewNotes'], isNotEmpty);
  });

  test('WSR-03 首屏快照只取最近 N 条，且保留关系与附件字段', () async {
    final now = DateTime.now();
    final rows = <Map<String, Object?>>[];
    for (var i = 0; i < 30; i++) {
      rows.add(
        _row(
          'n-$i',
          '第 $i 条',
          now.subtract(Duration(minutes: i)),
          relations: i == 0
              ? <Map<String, Object?>>[
                  <String, Object?>{
                    'type': 'REFERENCE',
                    'memoId': 'n-0',
                    'relatedMemoId': 'n-1',
                  },
                ]
              : null,
          resources: i == 1
              ? <Map<String, Object?>>[
                  <String, Object?>{
                    'uid': 'res-2',
                    'type': 'image/png',
                    'filename': 'b.png',
                  },
                ]
              : null,
        ),
      );
    }
    await seed(rows);

    final recent = await service.getRecentActiveNotes(20);

    expect(recent, hasLength(20));
    expect(recent.first.id, 'n-0');
    expect(recent.last.id, 'n-19');
    // 首屏快照要 toMap 落盘，关系与附件必须还在。
    expect(recent.first.relations, hasLength(1));
    expect(recent[1].resourceList, hasLength(1));
  });

  test('WSR-04 回顾挑选只解析抽到的那几条，不跑全库', () async {
    final now = DateTime.now();
    final rows = <Map<String, Object?>>[];
    for (var i = 0; i < 300; i++) {
      rows.add(
        _row(
          'n-$i',
          '第 $i 条带可见文字的笔记',
          now.subtract(Duration(minutes: i)),
        ),
      );
    }
    await seed(rows);

    final stat = await service.getWidgetStatNotes();
    MemosContentHelper.debugPreviewParseCount = 0;
    final picked = RandomReviewSelectorService.selectWidgetCandidates(
      notes: stat,
      random: Random(3),
    );

    expect(picked, hasLength(8));
    expect(picked.map((note) => note.id).toSet(), hasLength(8));
    expect(
      MemosContentHelper.debugPreviewParseCount,
      lessThan(50),
      reason: '旧实现会对 300 条各跑一次 Markdown 解析，现在取满 8 条就停',
    );
  });

  test('WSR-05 范围内全是没有可见文字的笔记时仍会抽出回顾卡片', () async {
    final now = DateTime.now();
    await seed(<Map<String, Object?>>[
      _row('img-1', '![](https://example.com/1.png)', now),
      _row('img-2', '![](https://example.com/2.png)', now),
    ]);

    final stat = await service.getWidgetStatNotes();
    final snapshot = _snapshot(stat, seed: 5);
    final reviewNotes = snapshot['reviewNotes']! as List<Object?>;

    expect(reviewNotes, isNotEmpty);
    expect(
      reviewNotes.map((item) => (item! as Map<String, Object?>)['preview']),
      everyElement('这是一条含图片的笔记'),
    );
  });
}
