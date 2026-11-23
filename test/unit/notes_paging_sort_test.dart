// ============================================================
// OPT-02A · 首页分页排序：SQL 与内存比较器必须是同一套规则
//
// 背景：首页以前固定按 createdAt DESC 分页取 50 条，再对「已加载的部分」
// 重排。于是切到「最近编辑」时，两年前创建、今天刚编辑的笔记要翻到底才
// 出现；并列时间又没有第二排序键，OFFSET 分页期间可能重复或漏读。
//
// 这里用真 SQLite（sqflite_common_ffi 内存库）跨三页取样，逐页拼起来必须
// 与服务端无关的内存排序结果完全一致。
// ============================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/models/note_media_filter.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/models/sort_order.dart';
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

Note _note({
  required String id,
  required DateTime created,
  required DateTime updated,
  bool pinned = false,
}) =>
    Note(
      id: id,
      content: '正文 $id',
      createdAt: created,
      updatedAt: updated,
      isPinned: pinned,
    );

/// 7 条样本，覆盖：老笔记最近编辑、置顶的老笔记、同一 createdAt 并列。
final List<Note> _samples = [
  _note(
    id: 'n-01',
    created: DateTime(2024, 1, 1, 9),
    updated: DateTime(2024, 1, 1, 9),
  ),
  // 两年前创建、昨天刚编辑：切「最近编辑」时必须出现在第一页
  _note(
    id: 'n-02',
    created: DateTime(2023, 5, 1, 9),
    updated: DateTime(2026, 11, 20, 9),
  ),
  _note(
    id: 'n-03',
    created: DateTime(2025, 3, 3, 9),
    updated: DateTime(2025, 3, 3, 9),
  ),
  // 最老的置顶笔记：任何排序都得排在最前
  _note(
    id: 'n-04',
    created: DateTime(2022, 2, 2, 9),
    updated: DateTime(2022, 2, 2, 9),
    pinned: true,
  ),
  _note(
    id: 'n-05',
    created: DateTime(2026, 1, 1, 10),
    updated: DateTime(2026, 1, 2, 9),
  ),
  // 与 n-05 的 createdAt 完全相同，靠 id 兜底分先后
  _note(
    id: 'n-06',
    created: DateTime(2026, 1, 1, 10),
    updated: DateTime(2025, 12, 31, 9),
  ),
  _note(
    id: 'n-07',
    created: DateTime(2022, 1, 1, 9),
    updated: DateTime(2022, 1, 1, 9),
  ),
];

Future<List<Note>> _collectPages(
  Database db,
  SortOrder order, {
  int pageSize = 3,
  int pages = 3,
}) async {
  final collected = <Note>[];
  for (var page = 0; page < pages; page++) {
    collected.addAll(
      await DatabaseService().getNotesPaged(
        page: page,
        pageSize: pageSize,
        sortOrder: order,
        executor: db,
      ),
    );
  }
  return collected;
}

void main() {
  group('OPT-02A 分页排序', () {
    late Database db;

    setUp(() async {
      db = await _openTestDb();
      for (final note in _samples) {
        await DatabaseService.upsertNote(db, note);
      }
    });

    tearDown(() async {
      await db.close();
    });

    for (final order in SortOrder.values) {
      test('PGSORT-${order.name} 跨三页的顺序与内存比较器完全一致', () async {
        final pages = await _collectPages(db, order);
        final expected = sortedNotesCopy(_samples, order);

        expect(pages.length, _samples.length, reason: '三页应恰好覆盖全部笔记');
        expect(
          pages.map((n) => n.id).toList(),
          expected.map((n) => n.id).toList(),
          reason: '$order 的 SQL 分页顺序必须等于 noteComparator 的顺序',
        );
        expect(
          pages.map((n) => n.id).toSet().length,
          _samples.length,
          reason: '跨页不能出现重复项',
        );
      });
    }

    test('PGSORT-deep 最近编辑排序第一页就包含老笔记', () async {
      final pages = await _collectPages(db, SortOrder.updated);
      expect(
        pages.take(3).map((n) => n.id),
        contains('n-02'),
        reason: '2023 年创建、2026-11-20 编辑过的笔记必须在最近编辑的第一页',
      );
    });

    test('PGSORT-pinned 四种排序下置顶笔记都在首位', () async {
      for (final order in SortOrder.values) {
        final firstPage = await DatabaseService().getNotesPaged(
          pageSize: 3,
          sortOrder: order,
          executor: db,
        );
        expect(firstPage.first.id, 'n-04', reason: '$order');
      }
    });

    test('PGSORT-tie 同一 createdAt 在不同页边界上不重复、不漏读', () async {
      // pageSize=1 时 n-05 / n-06 会落在相邻两页上，正好压 OFFSET 分页的并列风险
      final pages =
          await _collectPages(db, SortOrder.newest, pageSize: 1, pages: 7);
      // 并列时按 id 倒序，所以 n-06 在 n-05 之前，且两者分属相邻两页
      expect(pages.map((n) => n.id).toList().sublist(0, 2), ['n-04', 'n-06']);
      expect(pages.map((n) => n.id).toSet().length, _samples.length);
    });

    test('PGSORT-null isPinned 为 NULL 的老行按未置顶处理，排在置顶之后', () async {
      // 老库可能没有 isPinned 值，SQL 用 IFNULL 兜底
      await db.insert('notes', {
        'id': 'n-null',
        'content': 'NULL 置顶',
        'createdAt': DateTime(2026, 6).toIso8601String(),
        'updatedAt': DateTime(2026, 6).toIso8601String(),
        'isPinned': null,
      });

      final firstPage = await DatabaseService().getNotesPaged(
        pageSize: 2,
        executor: db,
      );
      expect(firstPage.map((n) => n.id).toList(), ['n-04', 'n-null']);
    });

    test('PGSORT-media 「有图片」筛选也走同一套排序', () async {
      // 两年前建的图笔记今天刚编辑过；另一条是上周新建的。按「最近编辑」
      // 老图必须在前 —— 写死 createdAt DESC 时会反过来。
      await DatabaseService.upsertNote(
        db,
        Note(
          id: 'img-old',
          content: '老图\n![图片](file:///a.jpg)',
          createdAt: DateTime(2022, 3, 3),
          updatedAt: DateTime(2026, 11, 22),
        ),
      );
      await DatabaseService.upsertNote(
        db,
        Note(
          id: 'img-new',
          content: '新图\n![图片](file:///b.jpg)',
          createdAt: DateTime(2026, 11, 16),
          updatedAt: DateTime(2026, 11, 16),
        ),
      );

      final matched = await DatabaseService().getNotesByMedia(
        NoteMediaFilter.images,
        sortOrder: SortOrder.updated,
        executor: db,
      );
      expect(matched.map((n) => n.id).toList(), ['img-old', 'img-new']);
    });
  });
}
