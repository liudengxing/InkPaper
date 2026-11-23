// ============================================================
// OPT-10 · 笔记引用优先按 ID 查找
//
// 背景：保存一条正文里带 `[[引用]]` 的笔记时，`updateReferencesFromContent`
// 一进来就 `getNotes()` 全表加载，接着对每个引用再各调一次
// `createReference` / `removeReference` —— 那两个内部又是 `getNotes()`。
// 于是一条引用三个笔记的正文，保存一次要把整库读四遍。
//
// 编辑器插入的引用就是 `[[<id>]]`（`note_editor.dart` 的
// `[[${referencedNote.id}]]`），所以这里验证：明确的 ID 走一次批量查，
// 只有按 ID 解析不到的旧式 `[[正文 / 正文前缀]]` 才回落到读全库的兼容路径。
// ============================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/models/note_model.dart';
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

Note _note(String id, String content, DateTime created) => Note(
      id: id,
      content: content,
      createdAt: created,
      updatedAt: created,
    );

/// 四个现代笔记（正文里存的是 id 引用）+ 两条旧式正文引用的老笔记。
final List<Note> _samples = [
  _note('n-1', '主笔记，稍后写入 [[n-2]]', DateTime(2026, 11, 1, 9)),
  _note('n-2', '目标 A', DateTime(2026, 11, 2, 9)),
  _note('n-3', '目标 B', DateTime(2026, 11, 3, 9)),
  _note('n-4', '目标 C', DateTime(2026, 11, 4, 9)),
  // 两条同前缀的老笔记：旧式 `[[今天读书笔记]]` 必须落到「按 createdAt 倒序
  // 的第一条」，与改造前的 getNotes() 顺序一致。
  _note('old-1', '今天读书笔记：读了《人类简史》第一章', DateTime(2024, 1, 1, 9)),
  _note('old-2', '今天读书笔记：换一本书接着读', DateTime(2023, 1, 1, 9)),
];

Set<String> _referenceTargets(Note note) => note.relations
    .where((rel) => rel['type'] == 'REFERENCE')
    .map((rel) => rel['relatedMemoId']?.toString() ?? '')
    .toSet();

void main() {
  late Database db;
  late DatabaseService service;
  late List<Note> notified;

  setUp(() async {
    db = await _openTestDb();
    DatabaseService.debugOverrideDatabase(db);
    service = DatabaseService();
    for (final note in _samples) {
      await service.saveNote(note);
    }
    notified = <Note>[];
    UnifiedReferenceManager().initialize(
      databaseService: service,
      onNotesChanged: (notes) => notified.addAll(notes),
    );
    // 播种结束后归零，后面只统计「保存引用」这条路径读了什么。
    DatabaseService.debugFullTableReadCount = 0;
  });

  tearDown(() async {
    UnifiedReferenceManager().initialize(databaseService: service);
    DatabaseService.debugOverrideDatabase(null);
    await db.close();
  });

  /// 把正文写回库（模拟编辑器保存），再跑引用更新。
  Future<bool> saveContent(String noteId, String content) async {
    final note = await service.getNoteById(noteId);
    await service.updateNote(note!.copyWith(content: content));
    return UnifiedReferenceManager().updateReferencesFromContent(
      noteId,
      content,
    );
  }

  test('REF-01 明确的 ID：建立双向关系且不读全库', () async {
    final ok = await saveContent('n-1', '主笔记，引用 [[n-2]]');

    expect(ok, isTrue);
    final source = await service.getNoteById('n-1');
    final target = await service.getNoteById('n-2');
    expect(_referenceTargets(source!), {'n-2'});
    expect(
      target!.relations.any(
        (rel) =>
            rel['type'] == 'REFERENCED_BY' &&
            rel['memoId'] == 'n-1' &&
            rel['relatedMemoId'] == 'n-2',
      ),
      isTrue,
      reason: '反向关系必须一起建好',
    );
    expect(
      DatabaseService.debugFullTableReadCount,
      0,
      reason: 'ID 引用不该触发任何全表读取（改造前是 1 次解析 + 1 次 createReference）',
    );
  });

  test('REF-02 三个 ID 引用：一次批量查解决，仍然不读全库', () async {
    final ok = await saveContent('n-1', '引用 [[n-2]] [[n-3]] [[n-4]]');

    expect(ok, isTrue);
    final source = await service.getNoteById('n-1');
    expect(_referenceTargets(source!), {'n-2', 'n-3', 'n-4'});
    expect(
      DatabaseService.debugFullTableReadCount,
      0,
      reason: '改造前这里是 4 次 getNotes()（解析 1 次 + 每个引用 1 次）',
    );
  });

  test('REF-03 getNotesByIds 按 900 分批，超过 SQLite 变量上限也不炸', () async {
    final ids = <String>[
      'n-2',
      'n-4',
      for (var i = 0; i < 1200; i++) 'missing-$i',
    ];
    final notes = await service.getNotesByIds(ids);
    expect(notes.map((note) => note.id).toSet(), {'n-2', 'n-4'});
  });

  test('REF-04 移除最后一个引用：双向关系一起清掉', () async {
    await saveContent('n-1', '主笔记，引用 [[n-2]]');
    expect(_referenceTargets((await service.getNoteById('n-1'))!), {'n-2'});

    final ok = await saveContent('n-1', '主笔记，引用改成了纯文字');

    expect(ok, isTrue);
    final source = await service.getNoteById('n-1');
    final target = await service.getNoteById('n-2');
    expect(_referenceTargets(source!), isEmpty);
    expect(
      target!.relations.where((rel) => rel['type'] == 'REFERENCED_BY'),
      isEmpty,
    );
    expect(DatabaseService.debugFullTableReadCount, 0);
  });

  test('REF-05 历史正文前缀：解析不到 ID 才读一次全库', () async {
    final ok = await saveContent('n-1', '看到 [[今天读书笔记]] 想起了旧文');

    expect(ok, isTrue);
    final source = await service.getNoteById('n-1');
    expect(
      _referenceTargets(source!),
      {'old-1'},
      reason: '同前缀取 getNotes() 顺序（createdAt DESC）的第一条，与改造前一致',
    );
    expect(
      DatabaseService.debugFullTableReadCount,
      1,
      reason: '兼容路径只读一次全库，不是每个引用读一次',
    );
  });

  test('REF-06 ID 与历史引用混合：ID 走批量，剩下一条回落兼容路径', () async {
    final ok = await saveContent(
      'n-1',
      '引用 [[n-3]] 和旧文 [[今天读书笔记：换一本书接着读]]',
    );

    expect(ok, isTrue);
    final source = await service.getNoteById('n-1');
    expect(_referenceTargets(source!), {'n-3', 'old-2'});
    expect(DatabaseService.debugFullTableReadCount, 1);
  });

  test('REF-07 目标被软删：引用不建立，也不留半条关系', () async {
    await service.softDeleteNote('n-2');

    final ok = await saveContent('n-1', '引用一下 [[n-2]]');

    expect(ok, isTrue);
    final source = await service.getNoteById('n-1');
    expect(_referenceTargets(source!), isEmpty);
  });

  test('REF-08 回调只带受影响的笔记，不是整库', () async {
    await saveContent('n-1', '引用 [[n-2]] [[n-3]]');

    final ids = notified.map((note) => note.id).toSet();
    expect(ids, {'n-1', 'n-2', 'n-3'});
    expect(
      ids.length,
      lessThan(_samples.length),
      reason: '回调语义是「改了哪条给哪条」，传整表会让分页列表被整体替换',
    );
  });
}
