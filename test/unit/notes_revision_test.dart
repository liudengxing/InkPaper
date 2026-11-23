// ============================================================
// OPT-03 · 探索索引的语料版本号
//
// 随机漫步 / 相关笔记的索引从全库笔记派生。以前任何 `notifyListeners()`
// 都把缓存的索引 Future 置空，于是切排序、翻页、切媒体筛选也会让下一次
// 探索重查全库并重跑后台 isolate。
//
// 现在改为比较 `DatabaseService.notesRevision`：写一笔记一行才自增，读
// 路径一律不动。这里用真 SQLite 逐条验证「哪些操作算语料变化」。
// ============================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/models/note_media_filter.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/models/sort_order.dart';
import 'package:inkpaper/services/database_service.dart';
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

Note _note(String id, {String? content, bool synced = true}) => Note(
      id: id,
      content: content ?? '正文 $id',
      createdAt: DateTime(2026, 3),
      updatedAt: DateTime(2026, 3),
      isSynced: synced,
    );

void main() {
  late Database db;

  setUp(() async {
    db = await _openTestDb();
  });

  tearDown(() async {
    await db.close();
  });

  test('REV-01 新写入与更新各让版本号 +1', () async {
    final before = DatabaseService.notesRevision;

    await DatabaseService.upsertNote(db, _note('a'));
    expect(DatabaseService.notesRevision, before + 1, reason: '插入也要算语料变化');

    await DatabaseService.upsertNote(
      db,
      _note('a', content: '正文改过了'),
    );
    expect(
      DatabaseService.notesRevision,
      before + 2,
      reason: '更新走的是 update 分支',
    );
  });

  test('REV-02 分页、媒体筛选、往年今日、删除列表都不动版本号', () async {
    await DatabaseService.upsertNote(db, _note('a'));
    await DatabaseService.upsertNote(
      db,
      Note(
        id: 'b',
        content: '带图\n![图](file:///x.jpg)',
        createdAt: DateTime(2025, 3),
        updatedAt: DateTime(2025, 3),
      ),
    );
    final before = DatabaseService.notesRevision;

    await DatabaseService().getNotesPaged(
      pageSize: 10,
      sortOrder: SortOrder.updated,
      executor: db,
    );
    await DatabaseService().getNotesByMedia(
      NoteMediaFilter.all,
      sortOrder: SortOrder.oldest,
      executor: db,
    );
    await DatabaseService().getNotesOnMonthDay(
      month: 3,
      day: 1,
      excludeYear: 2026,
      executor: db,
    );
    await DatabaseService().getDeletedNotes(executor: db);

    expect(
      DatabaseService.notesRevision,
      before,
      reason: '首页翻页与筛选是列表视图操作，不该让探索索引失效',
    );
  });

  test('REV-03 软删与恢复各让版本号 +1', () async {
    await DatabaseService.upsertNote(db, _note('a'));
    final before = DatabaseService.notesRevision;

    await DatabaseService().softDeleteNote('a', executor: db);
    expect(DatabaseService.notesRevision, before + 1);

    await DatabaseService().restoreDeletedNote('a', executor: db);
    expect(DatabaseService.notesRevision, before + 2);
  });

  test('REV-04 彻底删除与批量清空只在真的有行被删时自增', () async {
    await DatabaseService.upsertNote(db, _note('a'));
    await DatabaseService.upsertNote(db, _note('b'));
    await DatabaseService().softDeleteNote('a', executor: db);
    await DatabaseService().softDeleteNote('b', executor: db);

    var before = DatabaseService.notesRevision;
    await DatabaseService().purgeDeletedNote('a', executor: db);
    expect(DatabaseService.notesRevision, before + 1);

    before = DatabaseService.notesRevision;
    expect(await DatabaseService().purgeAllDeletedNotes(executor: db), 1);
    expect(DatabaseService.notesRevision, before + 1);

    before = DatabaseService.notesRevision;
    expect(await DatabaseService().purgeAllDeletedNotes(executor: db), 0);
    expect(
      DatabaseService.notesRevision,
      before,
      reason: '没有行被删就不算语料变化',
    );
  });

  test('REV-05 备份合并（WebDAV）也算语料变化', () async {
    final before = DatabaseService.notesRevision;
    final result = await DatabaseService().mergeNotes(
      [_note('a'), _note('b')],
      executor: db,
    );
    expect(result.$1, 2, reason: '两条都是新增');
    expect(DatabaseService.notesRevision, before + 1);
  });

  test('REV-06 空的服务端清单提前返回，不动版本号也不碰数据库', () async {
    final before = DatabaseService.notesRevision;
    await DatabaseService().deleteSyncedNotesNotIn(const []);
    expect(DatabaseService.notesRevision, before);
  });
}
