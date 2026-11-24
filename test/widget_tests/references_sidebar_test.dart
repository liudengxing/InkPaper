// ============================================================
// OPT-10 · 引用面板的对端笔记按 id 查库
//
// 面板早先从 `appProvider.notes` 里找对端标题，找不到就显示「笔记未找到」，
// 而那个窗口只有已加载的几十条。为了让它显示标题，引用回调曾把对端笔记塞进
// 首页列表，反而制造了分页重复。
//
// 现在面板自己按 id 查库：目标在深页也能显示真实标题，首页窗口保持干净。
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/providers/app_provider.dart';
import 'package:inkpaper/services/database_service.dart';
import 'package:inkpaper/services/unified_reference_manager.dart';
import 'package:inkpaper/widgets/references_sidebar.dart';
import 'package:provider/provider.dart';
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

  testWidgets('RSB-01 对端在深页时显示真实标题，而不是「笔记未找到」', (tester) async {
    // 真库 IO 在 testWidgets 的 FakeAsync 里不会推进，必须借 runAsync
    late Note owner;
    await tester.runAsync(() async {
      await provider.loadInitialNotes();
      expect(
        provider.notes.map((note) => note.id),
        isNot(contains('r-69')),
        reason: '前置条件：对端还在深页没加载',
      );
      owner = provider.notes.first.copyWith(
        relations: <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'REFERENCE',
            'memoId': provider.notes.first.id,
            'relatedMemoId': 'r-69',
          },
        ],
      );
    });

    await tester.pumpWidget(
      ChangeNotifierProvider<AppProvider>.value(
        value: provider,
        child: MaterialApp(
          home: Scaffold(
            body: ReferencesSidebar(note: owner, onNoteTap: (_) {}),
          ),
        ),
      ),
    );
    // 首帧只知道 id；补查是真实查库，等它完成后再画一帧
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump();

    expect(
      find.textContaining('批量笔记 69'),
      findsOneWidget,
      reason: '按 id 查库能拿到深页目标的正文',
    );
    expect(find.text('笔记未找到'), findsNothing);
    expect(
      provider.notes.length,
      50,
      reason: '面板自己查库，不该把目标塞进分页窗口',
    );
  });
}
