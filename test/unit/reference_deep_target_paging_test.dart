// ============================================================
// OPT-10 · 深页引用目标不能占首屏的位置
//
// 旧实现：引用回调把「不在当前窗口」的对端笔记 `add` 进首页列表。那个列表是
// 分页窗口，续页按 `OFFSET` 取，下一条 SQL 照样会把这条返回——于是同一个 id
// 在列表里出现两次，卡片重复、点击后状态也对不上。
//
// 现在：回调只替换已存在的 id；深页目标的标题由引用面板按 id 查库
// （`AppProvider.getNotesByIds`），不进入分页窗口。
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
    // 120 条，createdAt 递增；按 newest 倒序 → 首屏是 r-119..r-70，
    // 第 51 条（也就是第 2 页第一条）是 r-69。
    for (var i = 0; i < 120; i++) {
      final created = DateTime(2025, 6).add(Duration(minutes: i));
      await service.saveNote(
        Note(
          id: 'r-$i',
          content: '批量笔记 $i',
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

  test('OPT-10 引用深页目标不插进首屏，续页也不会出现同 id 两条', () async {
    await provider.loadInitialNotes();
    expect(provider.notes.length, 50);
    expect(
      provider.notes.map((note) => note.id),
      isNot(contains('r-69')),
      reason: '前置条件：第 51 条还在深页没加载',
    );

    final service = DatabaseService();
    final owner = await service.getNoteById('r-119');
    final deepTarget = await service.getNoteById('r-69');
    expect(owner, isNotNull);
    expect(deepTarget, isNotNull);

    // 引用管理器改到这两条（首页的引用方 + 深页的被引用方）
    provider.applyReferenceNoteChanges(<Note>[owner!, deepTarget!]);

    expect(
      provider.notes.length,
      50,
      reason: '深页目标不能占首屏的位置（旧实现 add 进来会变成 51 条）',
    );
    expect(provider.notes.map((note) => note.id), isNot(contains('r-69')));

    await provider.loadMoreNotes();
    final ids = provider.notes.map((note) => note.id).toList();
    expect(ids.length, 100);
    expect(
      ids.toSet().length,
      ids.length,
      reason: '续页把深页目标返回时不能变成第二条',
    );
    expect(
      ids.where((id) => id == 'r-69').length,
      1,
      reason: '第 51 条只该出现在续页里一次',
    );
  });

  test('OPT-10 窗口内的引用更新仍然就地生效', () async {
    await provider.loadInitialNotes();
    final target = provider.notes.first;
    final updated = target.copyWith(
      relations: <Map<String, dynamic>>[
        ...target.relations,
        <String, dynamic>{
          'type': 'REFERENCED_BY',
          'memoId': 'r-118',
          'relatedMemoId': target.id,
        },
      ],
    );

    provider.applyReferenceNoteChanges(<Note>[updated]);

    expect(
      provider.notes.length,
      50,
      reason: '就地替换不该改变窗口长度',
    );
    final inWindow = provider.notes.firstWhere((note) => note.id == target.id);
    expect(inWindow.relations.length, updated.relations.length);
    expect(inWindow.content, updated.content);
  });

  test('OPT-10 深页目标可以按 id 取到，引用面板据此显示标题', () async {
    await provider.loadInitialNotes();
    expect(provider.notes.map((note) => note.id), isNot(contains('r-69')));

    final fetched = await provider.getNotesByIds(<String>['r-69', 'r-1']);
    expect(
      fetched.map((note) => note.id).toList(),
      unorderedEquals(<String>['r-69', 'r-1']),
      reason: '不靠分页窗口，按 id 直接查库',
    );
  });
}
