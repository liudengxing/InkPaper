import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/services/database_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> _openDbAtVersion(int version) async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  return databaseFactory.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(
      version: version,
      singleInstance: false,
      onCreate: (db, v) async {
        // Simulate the schema at the requested version by creating the latest schema
        // and then letting upgrade tests explicitly exercise `upgradeSchema`.
        await DatabaseService.createSchema(db);
      },
    ),
  );
}

Future<List<String>> _columns(Database db, String table) async {
  final rows = await db.rawQuery('PRAGMA table_info($table)');
  return rows.map((r) => r['name']! as String).toList();
}

Future<List<String>> _indexes(Database db, String table) async {
  final rows = await db.rawQuery('PRAGMA index_list($table)');
  return rows.map((r) => r['name']! as String).toList();
}

void main() {
  test('DB-MIG-01 createSchema creates notes and reminder tables', () async {
    final db = await _openDbAtVersion(DatabaseService.schemaVersion);
    final tables = await db
        .rawQuery("SELECT name FROM sqlite_master WHERE type='table'")
        .then((rows) => rows.map((r) => r['name']! as String).toList());
    expect(tables, contains('notes'));
    expect(tables, contains('reminder_notifications'));
    await db.close();
  });

  test('DB-MIG-02 upgradeSchema (<8) adds annotations column', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    final db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 1,
        singleInstance: false,
        onCreate: (db, _) async {
          // Create a minimal v1-ish notes table without newer columns
          await db.execute('''
            CREATE TABLE notes(
              id TEXT PRIMARY KEY,
              content TEXT NOT NULL,
              createdAt TEXT NOT NULL,
              updatedAt TEXT NOT NULL
            )
          ''');
        },
      ),
    );

    await DatabaseService.upgradeSchema(db, oldVersion: 1, newVersion: 8);
    final cols = await _columns(db, 'notes');
    expect(cols, contains('annotations'));
    expect(cols, contains('rowStatus'));
    expect(cols, contains('last_sync_time'));
    await db.close();
  });

  test('DB-MIG-03 createSchema 为 notes 建 createdAt / is_synced 索引', () async {
    final db = await _openDbAtVersion(DatabaseService.schemaVersion);
    final indexes = await _indexes(db, 'notes');
    expect(indexes, contains('idx_notes_created_at'));
    expect(indexes, contains('idx_notes_is_synced'));
    await db.close();
  });

  test('DB-MIG-04 upgradeSchema (8 -> 9) 补齐 notes 索引', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    final db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 8,
        singleInstance: false,
        onCreate: (db, _) async {
          await db.execute('''
            CREATE TABLE notes(
              id TEXT PRIMARY KEY,
              content TEXT NOT NULL,
              createdAt TEXT NOT NULL,
              updatedAt TEXT NOT NULL,
              tags TEXT,
              is_synced INTEGER DEFAULT 0
            )
          ''');
        },
      ),
    );

    expect(
      await _indexes(db, 'notes'),
      isNot(contains('idx_notes_created_at')),
    );

    await DatabaseService.upgradeSchema(db, oldVersion: 8, newVersion: 9);

    final indexes = await _indexes(db, 'notes');
    expect(indexes, contains('idx_notes_created_at'));
    expect(indexes, contains('idx_notes_is_synced'));
    await db.close();
  });

  test('DB-MIG-05 从 v1 一路升级到当前版本不报错且索引齐全', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    final db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 1,
        singleInstance: false,
        onCreate: (db, _) async {
          // 真实的 v1 库已包含 v1 迁移补的列
          await db.execute('''
            CREATE TABLE notes(
              id TEXT PRIMARY KEY,
              content TEXT NOT NULL,
              createdAt TEXT NOT NULL,
              updatedAt TEXT NOT NULL,
              tags TEXT,
              is_synced INTEGER DEFAULT 0,
              isPinned INTEGER DEFAULT 0,
              visibility TEXT DEFAULT 'PRIVATE'
            )
          ''');
        },
      ),
    );

    await DatabaseService.upgradeSchema(
      db,
      oldVersion: 1,
      newVersion: DatabaseService.schemaVersion,
    );

    final cols = await _columns(db, 'notes');
    expect(
      cols,
      containsAll(<String>['annotations', 'rowStatus', 'last_sync_time']),
    );
    final indexes = await _indexes(db, 'notes');
    expect(indexes, contains('idx_notes_created_at'));
    expect(indexes, contains('idx_notes_is_synced'));
    final colsAfter = await _columns(db, 'notes');
    expect(colsAfter, contains('deleted_at'));
    await db.close();
  });

  test('DB-MIG-06 createSchema 建立 active_notes 视图并过滤软删行', () async {
    final db = await _openDbAtVersion(DatabaseService.schemaVersion);

    final views = await db
        .rawQuery("SELECT name FROM sqlite_master WHERE type='view'")
        .then((rows) => rows.map((r) => r['name']! as String).toList());
    expect(views, contains(DatabaseService.viewActiveNotes));

    await db.insert('notes', {
      'id': 'alive',
      'content': '正常笔记',
      'createdAt': DateTime(2025).toIso8601String(),
      'updatedAt': DateTime(2025).toIso8601String(),
    });
    await db.insert('notes', {
      'id': 'soft-deleted',
      'content': '已软删',
      'createdAt': DateTime(2025).toIso8601String(),
      'updatedAt': DateTime(2025).toIso8601String(),
      'rowStatus': 'DELETED',
      'deleted_at': DateTime(2025).toIso8601String(),
    });

    final active = await db.query(DatabaseService.viewActiveNotes);
    expect(active.map((row) => row['id']), ['alive']);
    await db.close();
  });

  test('DB-MIG-07 upgradeSchema (9 -> 10) 补 deleted_at 列并建视图', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    final db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 9,
        singleInstance: false,
        onCreate: (db, _) async {
          await db.execute('''
            CREATE TABLE notes(
              id TEXT PRIMARY KEY,
              content TEXT NOT NULL,
              createdAt TEXT NOT NULL,
              updatedAt TEXT NOT NULL,
              tags TEXT,
              is_synced INTEGER DEFAULT 0,
              rowStatus TEXT DEFAULT 'NORMAL'
            )
          ''');
        },
      ),
    );

    await DatabaseService.upgradeSchema(db, oldVersion: 9, newVersion: 10);

    expect(await _columns(db, 'notes'), contains('deleted_at'));
    final views = await db
        .rawQuery("SELECT name FROM sqlite_master WHERE type='view'")
        .then((rows) => rows.map((r) => r['name']! as String).toList());
    expect(views, contains(DatabaseService.viewActiveNotes));
    await db.close();
  });

  test('DB-MIG-08 createSchema 建立待同步操作队列表', () async {
    final db = await _openDbAtVersion(DatabaseService.schemaVersion);
    final tables = await db
        .rawQuery("SELECT name FROM sqlite_master WHERE type='table'")
        .then((rows) => rows.map((r) => r['name']! as String).toList());
    expect(tables, contains(DatabaseService.tablePendingOperations));
    await db.close();
  });

  test('DB-MIG-09 upgradeSchema (10 -> 11) 补建待同步操作队列表', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    final db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 10,
        singleInstance: false,
        onCreate: (db, _) async {
          await db.execute('''
            CREATE TABLE notes(
              id TEXT PRIMARY KEY,
              content TEXT NOT NULL,
              createdAt TEXT NOT NULL,
              updatedAt TEXT NOT NULL,
              rowStatus TEXT DEFAULT 'NORMAL',
              deleted_at TEXT
            )
          ''');
        },
      ),
    );

    await DatabaseService.upgradeSchema(db, oldVersion: 10, newVersion: 11);

    final tables = await db
        .rawQuery("SELECT name FROM sqlite_master WHERE type='table'")
        .then((rows) => rows.map((r) => r['name']! as String).toList());
    expect(tables, contains(DatabaseService.tablePendingOperations));
    await db.close();
  });
}
