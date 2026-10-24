import 'dart:convert'; // Added for jsonEncode and jsonDecode
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:inkpaper/config/app_config.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 解析备份 JSON 的 `notes` 数组（`ARCH-LAYER-002 / A-07`）。
///
/// 必须是顶层函数才能交给 `compute` 在后台 isolate 执行；只做解码与结构校验，
/// 不构造 `Note`，保证跨 isolate 传输的都是 Map / List / 基本类型。
///
/// 结构非法时抛出 `Exception('Invalid backup file format')`，由调用方包装成
/// 「导入JSON笔记失败」。
List<Map<String, dynamic>> decodeBackupNotesJson(String rawJson) {
  final data = jsonDecode(rawJson) as Map<String, dynamic>;
  if (!data.containsKey('notes') || data['notes'] is! List) {
    throw Exception('Invalid backup file format'); // 无效的备份文件格式
  }

  final notes = <Map<String, dynamic>>[];
  for (final item in data['notes'] as List) {
    if (item is Map<String, dynamic>) {
      notes.add(item);
    } else if (item is Map) {
      notes.add(Map<String, dynamic>.from(item));
    }
  }
  return notes;
}

class DatabaseService {
  factory DatabaseService() => _instance;

  DatabaseService._internal();
  static final DatabaseService _instance = DatabaseService._internal();
  static Database? _database;
  static bool _ffiInitialized = false;

  Future<Database> get database async {
    if (_database != null) {
      return _database!;
    }
    _database = await _initDatabase();
    return _database!;
  }

  // 初始化数据库
  Future<Database> _initDatabase() async {
    if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) {
      if (!_ffiInitialized) {
        sqfliteFfiInit();
        _ffiInitialized = true;
      }
      databaseFactory = databaseFactoryFfi;
    }

    final dbPath = !kIsWeb && (Platform.isWindows || Platform.isLinux)
        ? await _desktopDatabaseDirectory()
        : await getDatabasesPath();
    final path = join(dbPath, AppConfig.databaseName);

    return openDatabase(
      path,
      version: schemaVersion,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: (Database db, int version) => createSchema(db),
      onUpgrade: (db, oldVersion, newVersion) =>
          upgradeSchema(db, oldVersion: oldVersion, newVersion: newVersion),
    );
  }

  Future<String> _desktopDatabaseDirectory() async {
    final supportDirectory = await getApplicationSupportDirectory();
    final databaseDirectory =
        Directory(join(supportDirectory.path, 'databases'));
    if (!await databaseDirectory.exists()) {
      await databaseDirectory.create(recursive: true);
    }
    return databaseDirectory.path;
  }

  static const int schemaVersion = AppConfig.databaseVersion;

  /// 待同步的远端操作队列（目前只有删除）。
  static const String tablePendingOperations = 'pending_note_operations';

  /// 仅包含「未软删」笔记的视图。
  ///
  /// 软删（`rowStatus = 'DELETED'`）的行仍留在 `notes` 表里以便撤销与同步，
  /// 所有列表、分页、搜索、统计查询都必须走这个视图，避免漏加过滤条件。
  static const String viewActiveNotes = 'active_notes';

  static const String createActiveNotesViewSql =
      'CREATE VIEW IF NOT EXISTS $viewActiveNotes AS '
      "SELECT * FROM notes WHERE IFNULL(rowStatus, 'NORMAL') <> 'DELETED'";

  /// Creates all tables/indexes for the latest schema.
  static Future<void> createSchema(Database db) async {
    // notes
    await db.execute('''
      CREATE TABLE notes(
        id TEXT PRIMARY KEY,
        content TEXT NOT NULL,
        createdAt TEXT NOT NULL,
        updatedAt TEXT NOT NULL,
        displayTime TEXT,
        tags TEXT,
        creator TEXT,
        is_synced INTEGER DEFAULT 0,
        isPinned INTEGER DEFAULT 0,
        visibility TEXT DEFAULT 'PRIVATE',
        rowStatus TEXT DEFAULT 'NORMAL',
        resourceList TEXT DEFAULT '[]',
        relations TEXT DEFAULT '[]',
        annotations TEXT DEFAULT '[]',
        reminder_time TEXT,
        last_sync_time TEXT,
        deleted_at TEXT,
        remote_id TEXT
      )
    ''');

    // reminder_notifications
    await db.execute('''
      CREATE TABLE reminder_notifications(
        id TEXT PRIMARY KEY,
        note_id TEXT NOT NULL,
        note_title TEXT NOT NULL,
        note_content TEXT NOT NULL,
        reminder_time TEXT NOT NULL,
        triggered_at TEXT NOT NULL,
        is_read INTEGER DEFAULT 0,
        is_clicked INTEGER DEFAULT 0,
        FOREIGN KEY (note_id) REFERENCES notes (id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_reminder_triggered_at ON reminder_notifications(triggered_at)
    ''');
    await db.execute('''
      CREATE INDEX idx_reminder_note_id ON reminder_notifications(note_id)
    ''');

    // notes 查询索引（v9）：列表按 createdAt 倒序分页、同步按 is_synced 过滤
    await db.execute('''
      CREATE INDEX idx_notes_created_at ON notes(createdAt DESC)
    ''');
    await db.execute('''
      CREATE INDEX idx_notes_is_synced ON notes(is_synced)
    ''');

    // 软删过滤视图（v10）
    await db.execute(createActiveNotesViewSql);

    // 待同步的远端操作队列（v11）
    await db.execute(createPendingOperationsSql);
  }

  static const String createPendingOperationsSql = '''
    CREATE TABLE IF NOT EXISTS $tablePendingOperations(
      note_id TEXT NOT NULL,
      operation TEXT NOT NULL,
      created_at TEXT NOT NULL,
      attempts INTEGER DEFAULT 0,
      last_error TEXT,
      PRIMARY KEY (note_id, operation)
    )
  ''';

  /// 按标签精确匹配的 SQL 片段：tags 列存成逗号拼接串，
  /// 用前后补逗号的方式做整词匹配，避免 `LIKE '%tag%'` 命中同前缀标签。
  static const String tagMatchWhereClause =
      r"',' || IFNULL(tags, '') || ',' LIKE ? ESCAPE '\'";

  /// 构造 [tagMatchWhereClause] 所需的 LIKE 模式。
  static String tagMatchPattern(String tag) =>
      '%,${_escapeLikeValue(tag.trim())},%';

  static String _escapeLikeValue(String value) => value
      .replaceAll(r'\', r'\\')
      .replaceAll('%', r'\%')
      .replaceAll('_', r'\_');

  /// Upgrades an existing DB to the latest schema.
  static Future<void> upgradeSchema(
    Database db, {
    required int oldVersion,
    required int newVersion,
  }) async {
    if (oldVersion < 1) {
      await db.execute(
        'ALTER TABLE notes ADD COLUMN is_synced INTEGER DEFAULT 0',
      );
      await db.execute(
        'ALTER TABLE notes ADD COLUMN isPinned INTEGER DEFAULT 0',
      );
      await db.execute(
        'ALTER TABLE notes ADD COLUMN visibility TEXT DEFAULT "PRIVATE"',
      );
    }
    if (oldVersion < 2) {
      await db.execute(
        'ALTER TABLE notes ADD COLUMN resourceList TEXT DEFAULT "[]"',
      );
    }
    if (oldVersion < 3) {
      await db.execute(
        'ALTER TABLE notes ADD COLUMN relations TEXT DEFAULT "[]"',
      );
    }
    if (oldVersion < 4) {
      await db.execute('ALTER TABLE notes ADD COLUMN reminder_time TEXT');
    }
    if (oldVersion < 5) {
      // v5: reminder_notifications
      await db.execute('''
        CREATE TABLE IF NOT EXISTS reminder_notifications(
          id TEXT PRIMARY KEY,
          note_id TEXT NOT NULL,
          note_title TEXT NOT NULL,
          note_content TEXT NOT NULL,
          reminder_time TEXT NOT NULL,
          triggered_at TEXT NOT NULL,
          is_read INTEGER DEFAULT 0,
          is_clicked INTEGER DEFAULT 0,
          FOREIGN KEY (note_id) REFERENCES notes (id) ON DELETE CASCADE
        )
      ''');

      await db.execute('''
        CREATE INDEX IF NOT EXISTS idx_reminder_triggered_at ON reminder_notifications(triggered_at)
      ''');
      await db.execute('''
        CREATE INDEX IF NOT EXISTS idx_reminder_note_id ON reminder_notifications(note_id)
      ''');
    }
    if (oldVersion < 6) {
      // v6: rowStatus
      await db.execute(
        'ALTER TABLE notes ADD COLUMN rowStatus TEXT DEFAULT "NORMAL"',
      );
    }
    if (oldVersion < 7) {
      // v7: WebDAV last sync time
      await db.execute('ALTER TABLE notes ADD COLUMN last_sync_time TEXT');
    }
    if (oldVersion < 8) {
      // v8: annotations
      await db.execute(
        'ALTER TABLE notes ADD COLUMN annotations TEXT DEFAULT "[]"',
      );
    }
    if (oldVersion < 9) {
      // v9: notes 查询索引
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_notes_created_at ON notes(createdAt DESC)',
      );
      // is_synced 由 v1 迁移补列；对缺列的历史库做防御性判断，避免升级直接失败
      final columns = await db.rawQuery('PRAGMA table_info(notes)');
      final hasIsSynced = columns.any((row) => row['name'] == 'is_synced');
      if (hasIsSynced) {
        await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_notes_is_synced ON notes(is_synced)',
        );
      }
    }
    if (oldVersion < 10) {
      // v10: 软删除
      if (!await _hasColumn(db, 'notes', 'deleted_at')) {
        await db.execute('ALTER TABLE notes ADD COLUMN deleted_at TEXT');
      }
      await db.execute(createActiveNotesViewSql);
    }
    if (oldVersion < 11) {
      // v11: 待同步的远端操作队列
      await db.execute(createPendingOperationsSql);
    }
    if (oldVersion < 12) {
      // v12: 服务端 uid 独立成列，与本地 uuid 主键解耦
      if (!await _hasColumn(db, 'notes', 'remote_id')) {
        await db.execute('ALTER TABLE notes ADD COLUMN remote_id TEXT');
      }
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_notes_remote_id ON notes(remote_id)',
      );
    }
  }

  static Future<bool> _hasColumn(
    Database db,
    String table,
    String column,
  ) async {
    final columns = await db.rawQuery('PRAGMA table_info($table)');
    return columns.any((row) => row['name'] == column);
  }

  // 保存笔记到数据库
  Future<void> saveNote(Note note) async {
    final db = await database;
    await upsertNote(db, note);
  }

  /// 查本地笔记绑定的服务端 uid（Memos memo uid）。
  ///
  /// 未绑定（本地新建尚未上传 / 旧数据）返回 null，调用方回退用本地 id。
  /// 故意不过滤软删行：删除补交时要靠它拿到远端 uid。
  Future<String?> getRemoteIdForNote(String noteId) async {
    final db = await database;
    final rows = await db.query(
      'notes',
      columns: ['remote_id'],
      where: 'id = ?',
      whereArgs: [noteId],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    final value = rows.first['remote_id'] as String?;
    return (value == null || value.isEmpty) ? null : value;
  }

  /// 写入单条笔记。
  ///
  /// 不用 `ConflictAlgorithm.replace`：SQLite 的 REPLACE 是「删旧行 + 插新行」，
  /// 会把 `deleted_at` 一起丢掉，导致软删的笔记被任意一次保存"复活"。
  /// 这里先 UPDATE（已软删的行不命中），再 INSERT（行已存在时忽略），
  /// 因此删除状态是黏性的，只能通过 [restoreDeletedNote] 解除。
  static Future<void> upsertNote(DatabaseExecutor db, Note note) async {
    final map = note.toMap();
    final updated = await db.update(
      'notes',
      map,
      where: "id = ? AND IFNULL(rowStatus, 'NORMAL') <> 'DELETED'",
      whereArgs: [note.id],
    );
    if (updated > 0) {
      return;
    }
    await db.insert(
      'notes',
      map,
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  // 更新笔记
  Future<void> updateNote(Note note) async {
    final db = await database;
    await db.update(
      'notes',
      note.toMap(),
      where: "id = ? AND IFNULL(rowStatus, 'NORMAL') <> 'DELETED'",
      whereArgs: [note.id],
    );
  }

  /// 修正历史数据里「updatedAt 早于 createdAt」的行（时区错位一天等）。
  ///
  /// 读路径已经在 [Note] 构造函数里做过钳制，这里把库里的原始值也写正，
  /// 否则导出的备份、SQL 侧排序仍会带着错误时间。返回修正条数。
  Future<int> fixInvalidNoteTimestamps() async {
    final db = await database;
    final rows = await db.query(
      'notes',
      columns: ['id', 'createdAt', 'updatedAt'],
    );
    var fixed = 0;
    for (final row in rows) {
      final created = DateTime.tryParse(row['createdAt']?.toString() ?? '');
      final updated = DateTime.tryParse(row['updatedAt']?.toString() ?? '');
      if (created == null || updated == null || !updated.isBefore(created)) {
        continue;
      }
      await db.update(
        'notes',
        {'updatedAt': created.toIso8601String()},
        where: 'id = ?',
        whereArgs: [row['id']],
      );
      fixed++;
    }
    if (fixed > 0) {
      debugPrint('DatabaseService: 修正 $fixed 条笔记的 updatedAt（早于 createdAt）');
    }
    return fixed;
  }

  // 物理删除笔记（彻底删除，不可恢复）
  Future<void> deleteNote(String id) async {
    final db = await database;
    await db.delete(
      'notes',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // ── 软删除 / 最近删除 ─────────────────────────────────────────────────

  /// 软删除：保留行以便撤销与「最近删除」，只打删除标记。
  Future<void> softDeleteNote(
    String id, {
    DatabaseExecutor? executor,
    DateTime? deletedAt,
  }) async {
    final db = executor ?? await database;
    await db.update(
      'notes',
      {
        'rowStatus': 'DELETED',
        'deleted_at': (deletedAt ?? DateTime.now()).toIso8601String(),
        'is_synced': 0,
      },
      where: 'id = ?',
      whereArgs: [id],
    );

    // 服务端笔记需要删除远端数据：先入队，删除失败时由同步补交
    if (!Note.isLocalId(id)) {
      await enqueuePendingDelete(id, executor: db);
    }
  }

  /// 从「最近删除」恢复为正常笔记。
  Future<void> restoreDeletedNote(
    String id, {
    DatabaseExecutor? executor,
  }) async {
    final db = executor ?? await database;
    await db.update(
      'notes',
      {
        'rowStatus': 'NORMAL',
        'deleted_at': null,
        'is_synced': 0,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 「最近删除」列表，按删除时间倒序。
  Future<List<Note>> getDeletedNotes({DatabaseExecutor? executor}) async {
    final db = executor ?? await database;
    final maps = await db.query(
      'notes',
      where: "IFNULL(rowStatus, 'NORMAL') = 'DELETED'",
      orderBy: 'deleted_at DESC',
    );
    return maps.map(Note.fromMap).toList();
  }

  /// 「最近删除」中的笔记数量。
  Future<int> getDeletedNotesCount({DatabaseExecutor? executor}) async {
    final db = executor ?? await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM notes '
      "WHERE IFNULL(rowStatus, 'NORMAL') = 'DELETED'",
    );
    return result.isNotEmpty ? (result.first['count'] as int? ?? 0) : 0;
  }

  /// 彻底删除一条已软删的笔记（不可恢复）。
  Future<void> purgeDeletedNote(
    String id, {
    DatabaseExecutor? executor,
  }) async {
    final db = executor ?? await database;
    await db.delete(
      'notes',
      where: "id = ? AND IFNULL(rowStatus, 'NORMAL') = 'DELETED'",
      whereArgs: [id],
    );
  }

  /// 清空「最近删除」，返回被彻底删除的条数。
  Future<int> purgeAllDeletedNotes({DatabaseExecutor? executor}) async {
    final db = executor ?? await database;
    return db.delete(
      'notes',
      where: "IFNULL(rowStatus, 'NORMAL') = 'DELETED'",
    );
  }

  // ── 待同步的远端操作（删除补交） ─────────────────────────────────────

  /// 记录一条「服务端还没删成功」的删除操作，供下次同步补交。
  Future<void> enqueuePendingDelete(
    String noteId, {
    DatabaseExecutor? executor,
  }) async {
    final db = executor ?? await database;
    await db.insert(
      tablePendingOperations,
      {
        'note_id': noteId,
        'operation': 'delete',
        'created_at': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  /// 待补交的删除操作（按加入顺序）。
  Future<List<String>> getPendingDeleteNoteIds({
    DatabaseExecutor? executor,
  }) async {
    final db = executor ?? await database;
    final rows = await db.query(
      tablePendingOperations,
      columns: ['note_id'],
      where: 'operation = ?',
      whereArgs: ['delete'],
      orderBy: 'created_at ASC',
    );
    return rows.map((row) => row['note_id']! as String).toList();
  }

  /// 待补交的删除条数。
  Future<int> getPendingDeleteCount({DatabaseExecutor? executor}) async {
    final db = executor ?? await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM $tablePendingOperations '
      'WHERE operation = ?',
      ['delete'],
    );
    return result.isNotEmpty ? (result.first['count'] as int? ?? 0) : 0;
  }

  /// 服务端删除成功后移除该条待补交记录。
  Future<void> clearPendingDelete(
    String noteId, {
    DatabaseExecutor? executor,
  }) async {
    final db = executor ?? await database;
    await db.delete(
      tablePendingOperations,
      where: 'note_id = ? AND operation = ?',
      whereArgs: [noteId, 'delete'],
    );
  }

  /// 补交失败时累加重试次数并记录原因（不阻塞后续同步）。
  Future<void> markPendingDeleteAttempt(
    String noteId, {
    String? error,
    DatabaseExecutor? executor,
  }) async {
    final db = executor ?? await database;
    await db.rawUpdate(
      'UPDATE $tablePendingOperations '
      'SET attempts = IFNULL(attempts, 0) + 1, last_error = ? '
      'WHERE note_id = ? AND operation = ?',
      [error, noteId, 'delete'],
    );
  }

  // ── 待同步的远端操作（上传失败重试） ─────────────────────────────────

  /// 记录一条「上传失败、待重试」的笔记。
  ///
  /// 与删除补交共用 `pending_note_operations`，用 `operation = 'upsert'` 区分。
  /// 表里已有 `attempts` / `last_error`，不需要再改 schema。
  Future<void> enqueuePendingUpsert(
    String noteId, {
    DatabaseExecutor? executor,
  }) async {
    final db = executor ?? await database;
    await db.insert(
      tablePendingOperations,
      {
        'note_id': noteId,
        'operation': 'upsert',
        'created_at': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  /// 各笔记已累计的上传失败次数。
  Future<Map<String, int>> getPendingUpsertAttempts({
    DatabaseExecutor? executor,
  }) async {
    final db = executor ?? await database;
    final rows = await db.query(
      tablePendingOperations,
      columns: ['note_id', 'attempts'],
      where: 'operation = ?',
      whereArgs: ['upsert'],
    );
    return {
      for (final row in rows)
        row['note_id']! as String: (row['attempts'] as int?) ?? 0,
    };
  }

  /// 累加一次上传失败，并记录原因。
  Future<void> markPendingUpsertAttempt(
    String noteId, {
    String? error,
    DatabaseExecutor? executor,
  }) async {
    final db = executor ?? await database;
    await enqueuePendingUpsert(noteId, executor: db);
    await db.rawUpdate(
      'UPDATE $tablePendingOperations '
      'SET attempts = IFNULL(attempts, 0) + 1, last_error = ? '
      'WHERE note_id = ? AND operation = ?',
      [error, noteId, 'upsert'],
    );
  }

  /// 上传成功后清除失败记录（同时把 attempts 归零）。
  Future<void> clearPendingUpsert(
    String noteId, {
    DatabaseExecutor? executor,
  }) async {
    final db = executor ?? await database;
    await db.delete(
      tablePendingOperations,
      where: 'note_id = ? AND operation = ?',
      whereArgs: [noteId, 'upsert'],
    );
  }

  /// 清理软删超过 [age] 的笔记（回收站保留期）。返回清理条数。
  Future<int> purgeDeletedNotesOlderThan(
    Duration age, {
    DatabaseExecutor? executor,
  }) async {
    final db = executor ?? await database;
    final threshold = DateTime.now().subtract(age).toIso8601String();
    return db.delete(
      'notes',
      where: "IFNULL(rowStatus, 'NORMAL') = 'DELETED' "
          'AND IFNULL(deleted_at, ?) < ?',
      whereArgs: [threshold, threshold],
    );
  }

  // 获取所有笔记
  /// 获取所有笔记（兼容旧代码）
  Future<List<Note>> getNotes() async {
    final db = await database;
    final List<Map<String, dynamic>> maps =
        await db.query(viewActiveNotes, orderBy: 'createdAt DESC');

    return List.generate(maps.length, (i) => Note.fromMap(maps[i]));
  }

  /// 分页获取笔记（性能优化）
  Future<List<Note>> getNotesPaged({
    int page = 0,
    int pageSize = 50,
    String? orderBy,
  }) async {
    final db = await database;
    final offset = page * pageSize;

    final List<Map<String, dynamic>> maps = await db.query(
      viewActiveNotes,
      orderBy: orderBy ?? 'createdAt DESC',
      limit: pageSize,
      offset: offset,
    );

    return List.generate(maps.length, (i) => Note.fromMap(maps[i]));
  }

  /// 获取笔记总数
  Future<int> getNotesCount() async {
    final db = await database;
    final result =
        await db.rawQuery('SELECT COUNT(*) as count FROM $viewActiveNotes');
    return result.isNotEmpty ? (result.first['count'] as int? ?? 0) : 0;
  }

  // 根据ID获取笔记
  Future<Note?> getNoteById(String id) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      viewActiveNotes,
      where: 'id = ?',
      whereArgs: [id],
    );

    if (maps.isEmpty) {
      return null;
    }

    return Note.fromMap(maps[0]);
  }

  // 获取未同步的笔记
  Future<List<Note>> getUnsyncedNotes() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      viewActiveNotes,
      where: 'is_synced = ?',
      whereArgs: [0],
    );

    return List.generate(maps.length, (i) => Note.fromMap(maps[i]));
  }

  /// 回填本地笔记对应的服务端 uid。
  ///
  /// 只写 `remote_id`，主键永远是本地 uuid —— 旧实现会把主键改成服务端 uid，
  /// 导致 WebDAV 快照、引用关系、批注绑定全部跟着漂移。
  Future<void> setRemoteId(String localId, String remoteUid) async {
    final db = await database;
    await db.update(
      'notes',
      {'remote_id': remoteUid},
      where: 'id = ?',
      whereArgs: [localId],
    );
  }

  // 标记笔记为已同步
  Future<void> markNoteSynced(String id) async {
    final db = await database;
    await db.update(
      'notes',
      {'is_synced': 1},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // 清空所有笔记
  Future<void> clearAllNotes() async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('reminder_notifications');
      await txn.delete('notes');
    });
  }

  // 批量保存笔记（upsert：存在则更新，不存在则插入，已软删的行不会被复活）
  Future<void> saveNotes(List<Note> notes) async {
    final db = await database;
    await db.transaction((txn) async {
      for (final note in notes) {
        await upsertNote(txn, note);
      }
    });
  }

  /// 原子替换全部笔记。用于恢复备份，避免先清空后逐条写入导致半恢复状态。
  ///
  /// 同时清空 `pending_note_operations`：待补交的删除/上传都是针对「恢复前」
  /// 那批笔记的，恢复后旧的操作会对不上新数据 —— 若是删除补交，还会把备份里
  /// 仍然存在的服务端 memo 删掉。
  Future<void> replaceAllNotes(List<Note> notes) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('reminder_notifications');
      await txn.delete(tablePendingOperations);
      await txn.delete('notes');
      for (final note in notes) {
        await txn.insert('notes', note.toMap());
      }
    });
  }

  /// 删除服务器已不存在的本地已同步笔记（安全清理，不影响未同步数据）
  Future<void> deleteSyncedNotesNotIn(List<String> serverIds) async {
    if (serverIds.isEmpty) {
      return;
    }
    final db = await database;
    final placeholders = List.filled(serverIds.length, '?').join(',');
    // 软删行由删除同步与 GC 负责，这里不参与剪枝
    await db.delete(
      'notes',
      where: "is_synced = 1 AND IFNULL(rowStatus, 'NORMAL') <> 'DELETED' "
          'AND id NOT IN ($placeholders)',
      whereArgs: serverIds,
    );
  }

  // 按标签获取笔记（整词精确匹配，不会把“工作”匹配到“工作会议”）
  Future<List<Note>> getNotesByTag(String tag) async {
    final normalized = tag.trim();
    if (normalized.isEmpty) {
      return const [];
    }

    final db = await database;
    final List<Map<String, dynamic>> maps = await db.rawQuery(
      'SELECT * FROM $viewActiveNotes WHERE $tagMatchWhereClause '
      'ORDER BY createdAt DESC',
      [tagMatchPattern(normalized)],
    );

    return maps.map(Note.fromMap).toList();
  }

  // 搜索笔记
  Future<List<Note>> searchNotes(String query) async {
    final normalizedQuery = query.trim();
    if (normalizedQuery.isEmpty) {
      return const [];
    }

    final db = await database;
    final pattern = '%$normalizedQuery%';
    final List<Map<String, dynamic>> maps = await db.query(
      viewActiveNotes,
      where: 'content LIKE ? OR tags LIKE ?',
      whereArgs: [pattern, pattern],
      orderBy: 'createdAt DESC',
    );

    return maps.map(Note.fromMap).toList();
  }

  // 获取数据库大小（估算值，单位：字节）
  Future<int> getDatabaseSize() async {
    final db = await database;
    final result = await db.rawQuery('SELECT SUM(LENGTH(content)) FROM notes');
    return (Sqflite.firstIntValue(result) ?? 0) + 1024; // 添加一些额外的元数据大小
  }

  // 将笔记导出为JSON
  Future<String> exportNotesToJson() async {
    final notes = await getNotes();
    final jsonList = notes.map((note) => note.toJson()).toList();
    return jsonEncode({
      'version': '1.0',
      'exportTime': DateTime.now().toIso8601String(),
      'notes': jsonList,
    });
  }

  /// 将单条笔记导出为带元数据的 Markdown。
  ///
  /// 正文仍是用户可读的 Markdown；顶部 front matter 让本应用重新导入时能恢复
  /// 创建时间、更新时间、标签、提醒、批注等本地字段。
  String exportNoteToMarkdown(Note note) {
    final metadata = <String, dynamic>{
      'InkPaperNote': true,
      'id': note.id,
      'createdAt': note.createdAt.toIso8601String(),
      'updatedAt': note.updatedAt.toIso8601String(),
      'displayTime': note.displayTime.toIso8601String(),
      'tags': note.tags,
      'creator': note.creator,
      'isSynced': note.isSynced,
      'isPinned': note.isPinned,
      'visibility': note.visibility,
      'rowStatus': note.rowStatus,
      'resourceList': note.resourceList,
      'relations': note.relations,
      'annotations':
          note.annotations.map((annotation) => annotation.toJson()).toList(),
      'reminderTime': note.reminderTime?.toIso8601String(),
      'lastSyncTime': note.lastSyncTime?.toIso8601String(),
    };

    final buffer = StringBuffer('---\n');
    metadata.forEach((key, value) {
      buffer.writeln('$key: ${jsonEncode(value)}');
    });
    buffer.writeln('---');
    buffer.write(note.content);
    return buffer.toString();
  }

  // 导入JSON格式的笔记
  Future<int> importNotesFromJson(
    String jsonData, {
    bool overwriteExisting = false,
    bool asNewNotes = true,
  }) async {
    try {
      // 大备份文件动辄几十 MB，jsonDecode 放到后台 isolate，避免卡住 UI。
      final jsonNotes = await compute(decodeBackupNotesJson, jsonData);

      final notes = <Note>[];
      for (final item in jsonNotes) {
        try {
          final note = Note.fromJson(item);
          notes.add(note);
        } on Object catch (e) {
          debugPrint('解析笔记失败: $e');
        }
      }

      return await _importNotes(
        notes,
        overwriteExisting: overwriteExisting,
        asNewNotes: asNewNotes,
      );
    } on Object catch (e) {
      debugPrint('导入JSON笔记失败: $e');
      throw Exception('导入JSON笔记失败: $e');
    }
  }

  // 导入Markdown格式的笔记
  Future<int> importNotesFromMarkdown(
    List<String> markdownFiles,
    List<String> contents, {
    bool overwriteExisting = false,
    bool asNewNotes = true,
  }) async {
    if (markdownFiles.length != contents.length) {
      throw Exception('File name and content count mismatch'); // 文件名和内容数量不匹配
    }

    final notes = <Note>[];
    for (var i = 0; i < markdownFiles.length; i++) {
      final content = contents[i];
      final backupNote = _tryParseMarkdownBackupNote(content, index: i);
      if (backupNote != null) {
        notes.add(backupNote);
        continue;
      }

      final importedAt = DateTime.now().add(Duration(milliseconds: i));
      final tags = Note.extractTagsFromContent(content);

      notes.add(
        Note(
          id: 'local_${DateTime.now().millisecondsSinceEpoch}_$i',
          content: content,
          createdAt: importedAt,
          updatedAt: importedAt,
          tags: tags,
        ),
      );
    }

    return _importNotes(
      notes,
      overwriteExisting: overwriteExisting,
      asNewNotes: asNewNotes,
    );
  }

  // 导入纯文本格式的笔记
  Future<int> importNotesFromText(
    List<String> textFiles,
    List<String> contents, {
    bool overwriteExisting = false,
    bool asNewNotes = true,
  }) async {
    if (textFiles.length != contents.length) {
      throw Exception('File name and content count mismatch'); // 文件名和内容数量不匹配
    }

    final notes = <Note>[];

    for (var i = 0; i < textFiles.length; i++) {
      final content = contents[i];
      final backupNotes = _tryParseTextBackupNotes(content);
      if (backupNotes.isNotEmpty) {
        notes.addAll(backupNotes);
        continue;
      }

      final importedAt = DateTime.now().add(Duration(milliseconds: i));
      final tags = Note.extractTagsFromContent(content);

      notes.add(
        Note(
          id: 'local_${DateTime.now().millisecondsSinceEpoch}_$i',
          content: content,
          createdAt: importedAt,
          updatedAt: importedAt,
          tags: tags,
        ),
      );
    }

    return _importNotes(
      notes,
      overwriteExisting: overwriteExisting,
      asNewNotes: asNewNotes,
    );
  }

  Note? _tryParseMarkdownBackupNote(String content, {required int index}) {
    final match = RegExp(
      r'^---\r?\n(.*?)\r?\n---\r?\n?',
      dotAll: true,
    ).firstMatch(content);
    if (match == null) {
      return null;
    }

    final metadata = <String, dynamic>{};
    for (final line in const LineSplitter().convert(match.group(1) ?? '')) {
      final separator = line.indexOf(':');
      if (separator <= 0) {
        continue;
      }
      final key = line.substring(0, separator).trim();
      final rawValue = line.substring(separator + 1).trim();
      if (key.isEmpty) {
        continue;
      }
      try {
        metadata[key] = jsonDecode(rawValue);
      } on Object {
        metadata[key] = rawValue;
      }
    }

    if (metadata['InkPaperNote'] != true) {
      return null;
    }

    final body = content.substring(match.end);
    final json = <String, dynamic>{
      ...metadata,
      'id': metadata['id']?.toString().isNotEmpty ?? false
          ? metadata['id']
          : 'local_${DateTime.now().millisecondsSinceEpoch}_$index',
      'content': body,
    };

    return Note.fromJson(json);
  }

  List<Note> _tryParseTextBackupNotes(String content) {
    final notes = <Note>[];
    final blockRegex = RegExp(
      r'--- 笔记 (.*?) ---\r?\n'
      r'创建时间: (.*?)\r?\n'
      r'更新时间: (.*?)\r?\n'
      r'标签: (.*?)\r?\n'
      r'内容:\r?\n'
      r'(.*?)(?:\r?\n-{20,}\r?\n|$)',
      dotAll: true,
    );

    for (final match in blockRegex.allMatches(content)) {
      final id = match.group(1)?.trim();
      final createdAt = _parseBackupDate(match.group(2));
      final updatedAt = _parseBackupDate(match.group(3));
      final rawTags = match.group(4)?.trim() ?? '';
      final body = match.group(5) ?? '';
      if (createdAt == null || updatedAt == null || id == null || id.isEmpty) {
        continue;
      }

      final tags = rawTags.isEmpty
          ? Note.extractTagsFromContent(body)
          : rawTags
              .split(',')
              .map((tag) => tag.trim())
              .where((tag) => tag.isNotEmpty)
              .toList();
      notes.add(
        Note(
          id: id,
          content: body.trimRight(),
          createdAt: createdAt,
          updatedAt: updatedAt,
          tags: tags,
        ),
      );
    }

    return notes;
  }

  DateTime? _parseBackupDate(String? rawDate) {
    if (rawDate == null) {
      return null;
    }
    final value = rawDate.trim();
    return DateTime.tryParse(value) ??
        DateTime.tryParse(value.replaceFirst(' ', 'T'));
  }

  // 内部方法：导入笔记通用逻辑
  Future<int> _importNotes(
    List<Note> notes, {
    bool overwriteExisting = false,
    bool asNewNotes = true,
  }) async {
    final db = await database;
    var imported = 0;

    await db.transaction((txn) async {
      for (final note in notes) {
        try {
          if (asNewNotes) {
            // 作为新笔记导入，使用新ID
            final newNote = note.copyWith(
              id: 'local_${DateTime.now().millisecondsSinceEpoch}_$imported',
              isSynced: false,
              relations: const [],
              clearLastSyncTime: true,
              // 换了新 id 就必须丢掉 remoteId：否则两条本地记录会指向同一个
              // 服务端 memo，上传时互相覆盖。
              clearRemoteId: true,
            );

            await upsertNote(txn, newNote);
            imported++;
          } else if (overwriteExisting) {
            // 存在则更新、不存在则插入（已软删的行保持删除状态）
            await upsertNote(
              txn,
              await _detachConflictingRemoteId(txn, note),
            );
            imported++;
          } else {
            // 检查是否存在相同ID的笔记
            final exists = Sqflite.firstIntValue(
                  await txn.rawQuery(
                    'SELECT COUNT(*) FROM notes WHERE id = ?',
                    [note.id],
                  ),
                ) ??
                0;

            // 只有不存在时才插入
            if (exists == 0) {
              await upsertNote(
                txn,
                await _detachConflictingRemoteId(txn, note),
              );
              imported++;
            }
          }
        } on Object catch (e) {
          debugPrint('导入单条笔记失败: $e');
        }
      }
    });

    return imported;
  }

  /// 同一个服务端 uid 只能被一条本地笔记认领。
  ///
  /// 导入（合并/覆盖）时如果库里已有别的 id 绑定了这个 uid，就把 uid 从
  /// 导入的这条上摘掉，否则两条记录会抢同一个 memo，上传时互相覆盖。
  static Future<Note> _detachConflictingRemoteId(
    DatabaseExecutor txn,
    Note note,
  ) async {
    final remoteId = note.remoteId;
    if (remoteId == null || remoteId.isEmpty) {
      return note;
    }
    final clash = Sqflite.firstIntValue(
          await txn.rawQuery(
            'SELECT COUNT(*) FROM notes WHERE remote_id = ? AND id <> ?',
            [remoteId, note.id],
          ),
        ) ??
        0;
    return clash > 0 ? note.copyWith(clearRemoteId: true) : note;
  }

  // 批量更新笔记（增量同步专用）
  Future<void> updateNotesBatch(List<Note> notes) async {
    if (notes.isEmpty) {
      return;
    }

    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final note in notes) {
        batch.update(
          'notes',
          note.toMap(),
          where: "id = ? AND IFNULL(rowStatus, 'NORMAL') <> 'DELETED'",
          whereArgs: [note.id],
        );
      }
      await batch.commit(noResult: true);
    });
  }

  // 批量插入笔记（增量同步专用）
  Future<void> insertNotesBatch(List<Note> notes) async {
    if (notes.isEmpty) {
      return;
    }

    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final note in notes) {
        batch.insert(
          'notes',
          note.toMap(),
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
      await batch.commit(noResult: true);
    });
  }
}
