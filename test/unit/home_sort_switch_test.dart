// ============================================================
// OPT-02A 返修 · 排序切换与混合时间戳
//
// 复验要求：统一混合 UTC / 本地时间戳的 SQL 与 Dart 排序，补跨页时间样本，
// 并验证「快速切换」时旧查询的迟到结果不会覆盖新列表。
//
// 样本里同一面墙时间会以两种写法落库：偶数条走本地 `DateTime`（库里写
// `...T09:00:00.000`），奇数条走 `DateTime.utc`（库里写 `...T09:00:00.000Z`，
// 等价于 Memos 把北京时间当 UTC 存）。墙钟先后必须与用户看到的时刻一致。
// ============================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/models/sort_order.dart';
import 'package:inkpaper/providers/app_provider.dart';
import 'package:inkpaper/services/database_service.dart';
import 'package:inkpaper/utils/note_sorting_helper.dart';
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

/// 第 [index] 条的墙钟时间：2026-01-01 起每小时一条。
DateTime _wallClock(int index) => DateTime(2026).add(Duration(hours: index));

/// 偶数条用本地写法、奇数条用 UTC 写法，但墙钟数字完全相同。
DateTime _mixedStamp(int index) {
  final wall = _wallClock(index);
  if (index.isEven) {
    return wall;
  }
  return DateTime.utc(
    wall.year,
    wall.month,
    wall.day,
    wall.hour,
    wall.minute,
  );
}

Note _sample(int index) {
  final created = _mixedStamp(index);
  // 每 10 条里有 1 条「老笔记最近编辑」，让「最近编辑」与「最近创建」不同序
  final updated = index % 10 == 0 ? _mixedStamp(200 + index) : created;
  return Note(
    id: 'h-${index.toString().padLeft(3, '0')}',
    content: '混合来源第 $index 条',
    createdAt: created,
    updatedAt: updated,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Database db;
  late AppProvider provider;
  late List<Note> samples;

  setUp(() async {
    db = await _openTestDb();
    DatabaseService.debugOverrideDatabase(db);
    samples = List<Note>.generate(120, _sample);
    for (final note in samples) {
      await DatabaseService.upsertNote(db, note);
    }
    provider = AppProvider();
  });

  tearDown(() async {
    provider.dispose();
    DatabaseService.debugOverrideDatabase(null);
    await db.close();
  });

  List<String> expectedFirstPage(SortOrder order) =>
      sortedNotesCopy(samples, order).take(50).map((note) => note.id).toList();

  test('HSW-01 首批按墙钟排序：本地写法的 09:00 在远端写法的 02:00 之前', () async {
    await DatabaseService.upsertNote(
      db,
      Note(
        id: 'mx-local-09',
        content: '本地 09:00',
        createdAt: DateTime(2026, 11, 23, 9),
        updatedAt: DateTime(2026, 11, 23, 9),
      ),
    );
    await DatabaseService.upsertNote(
      db,
      Note(
        id: 'mx-remote-02',
        content: 'Memos 02:00Z',
        createdAt: DateTime.utc(2026, 11, 23, 2),
        updatedAt: DateTime.utc(2026, 11, 23, 2),
      ),
    );

    await provider.loadInitialNotes();
    final ids = provider.notes.map((note) => note.id).toList();
    expect(
      ids.indexOf('mx-local-09'),
      lessThan(ids.indexOf('mx-remote-02')),
      reason: '两者都未置顶，墙钟 09:00 应排在 02:00 前面',
    );
  });

  test('HSW-02 快速连续切换两次，最终停在最后一次的排序', () async {
    // 不 await 第一次：它的首屏查询还在飞，第二次已经改了口径
    final first = provider.setSortOrder(SortOrder.oldest);
    final second = provider.setSortOrder(SortOrder.updated);
    await Future.wait([first, second]);

    expect(
      provider.notes.map((note) => note.id).toList(),
      expectedFirstPage(SortOrder.updated),
      reason: '先发起的那次必须整份丢弃，不能把旧口径的结果写回列表',
    );
    expect(provider.notes.length, 50);
    expect(provider.hasMoreData, isTrue);
  });

  test('HSW-03 连切四种排序，最终顺序是最后一种且无重复', () async {
    final futures = <Future<void>>[];
    for (final order in SortOrder.values) {
      futures.add(provider.setSortOrder(order));
    }
    await Future.wait(futures);

    final ids = provider.notes.map((note) => note.id).toList();
    expect(ids, expectedFirstPage(SortOrder.values.last));
    expect(ids.toSet().length, ids.length, reason: '切换过程中不能把两批结果叠在一起');
  });

  test('HSW-04 切换排序后翻完三页，与整库墙钟排序逐位一致', () async {
    // 默认就是 newest，换成 oldest 才会真正重查（也顺便覆盖「反向」口径）
    await provider.setSortOrder(SortOrder.oldest);
    expect(provider.notes.length, 50);

    await provider.loadMoreNotes();
    await provider.loadMoreNotes();
    final ids = provider.notes.map((note) => note.id).toList();

    expect(ids.length, 120);
    expect(
      ids,
      sortedNotesCopy(samples, SortOrder.oldest)
          .map((note) => note.id)
          .toList(),
      reason: '跨页拼接必须等于整库墙钟排序（120 条恰好三页）',
    );
    expect(ids.toSet().length, ids.length);
  });

  test('HSW-05 续页飞行途中切换排序，旧偏移的那一页被丢弃', () async {
    await provider.loadInitialNotes();
    expect(provider.notes.length, 50);

    // 第 2 页（旧口径的偏移）在飞的时候切排序：首屏会从第 0 页重查
    final more = provider.loadMoreNotes();
    final switched = provider.setSortOrder(SortOrder.oldest);
    await Future.wait([more, switched]);

    expect(
      provider.notes.length,
      50,
      reason: '旧续页结果不能追加到新首屏后面（会导致重复或跳条）',
    );
    expect(
      provider.notes.map((note) => note.id).toList(),
      expectedFirstPage(SortOrder.oldest),
    );
  });
}
