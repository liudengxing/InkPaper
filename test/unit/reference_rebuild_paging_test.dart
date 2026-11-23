// ============================================================
// OPT-10B · 重建引用后的分页状态
//
// 旧实现（`AppProvider.rebuildAllReferences`）中间两次调
// `loadNotesFromLocal()`：那个方法把 `pagingState` 换回初始值（currentPage = 0,
// hasMoreData = true）却把整库塞进 `notes`，于是滑到底会按「第 1 页」再
// `addAll` 一次已经加载的笔记，列表里开始出现重复条目。
//
// 现在重建在库里完成后只重查首屏，分页状态由 `applyInitialPageResult` 按
// 实际加载数 / 总数算，后续翻页接着第 1 页走。
// ============================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/providers/app_provider.dart';
import 'package:inkpaper/services/database_service.dart';
import 'package:inkpaper/services/unified_reference_manager.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Database db;
  late AppProvider provider;

  setUp(() async {
    db = await _openTestDb();
    DatabaseService.debugOverrideDatabase(db);
    final service = DatabaseService();
    // 120 条：两页多一点，带引用的那条最老（首页 50 条缓存里看不到）。
    for (var i = 0; i < 120; i++) {
      final created = DateTime(2025, 6).add(Duration(minutes: i));
      await service.saveNote(
        Note(
          id: 'r-$i',
          content: i == 5 ? '最老的一条，引用 [[r-1]]' : '批量笔记 $i',
          createdAt: created,
          updatedAt: created,
        ),
      );
    }
    UnifiedReferenceManager().initialize(databaseService: service);
    provider = AppProvider();
  });

  tearDown(() async {
    provider.dispose();
    DatabaseService.debugOverrideDatabase(null);
    await db.close();
  });

  test('重建后回到首屏，翻下一页不重复', () async {
    await provider.loadInitialNotes();
    expect(provider.notes.length, 50);
    expect(provider.hasMoreData, isTrue);

    await provider.loadMoreNotes();
    expect(provider.notes.length, 100);

    await provider.rebuildAllReferences();

    expect(provider.notes.length, 50, reason: '重建后只保留首屏，不塞整库');
    expect(provider.hasMoreData, isTrue);
    expect(provider.totalNotesCount, 120);

    await provider.loadMoreNotes();
    final ids = provider.notes.map((note) => note.id).toList();
    expect(ids.length, 100);
    expect(
      ids.toSet().length,
      ids.length,
      reason: '第 1 页不能被追加第二次（旧实现 loadNotesFromLocal 的重复条目）',
    );
  });

  test('重建覆盖首屏之外的笔记', () async {
    await provider.loadInitialNotes();
    expect(
      provider.notes.map((note) => note.id),
      isNot(contains('r-5')),
      reason: '前置条件：这条最老的笔记不在已加载的首屏里',
    );

    await provider.rebuildAllReferences();

    final deep = await DatabaseService().getNoteById('r-5');
    expect(
      deep!.relations.any(
        (rel) => rel['type'] == 'REFERENCE' && rel['relatedMemoId'] == 'r-1',
      ),
      isTrue,
    );
  });
}
