import 'dart:convert'; // Added for jsonEncode and jsonDecode
import 'package:flutter/foundation.dart';
import 'package:inkpaper/config/app_config.dart';
import 'package:inkpaper/models/note_media_filter.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

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

  Future<Database> get database async {
    if (_database != null) {
      return _database!;
    }
    _database = await _initDatabase();
    return _database!;
  }

  // 初始化数据库
  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
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

    // 编辑历史版本（v13）
    await db.execute(createEditHistorySql);

    // 洞察历史（v14）
    await db.execute(createInsightReportsSql);
    await db.execute(createInsightReportsIndexSql);
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

  /// 编辑历史版本（v13）：编辑过程中自动快照，供「历史版本」回看与恢复。
  /// 只存正文 markdown（图片在快照里是路径，原图还在即可恢复）；
  /// 不进同步，纯本地。
  static const String tableEditHistory = 'note_edit_history';

  static const String createEditHistorySql = '''
    CREATE TABLE IF NOT EXISTS $tableEditHistory(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      note_id TEXT NOT NULL,
      content TEXT NOT NULL,
      created_at TEXT NOT NULL
    )
  ''';

  static const String createEditHistoryIndexSql = '''
    CREATE INDEX IF NOT EXISTS idx_edit_history_note
    ON $tableEditHistory(note_id, created_at DESC)
  ''';

  /// 洞察历史（v14）：每生成一份洞察存一条，供「历史」里回看。
  ///
  /// v15 起补三列：标题（模型从正文里提炼的那句）、思考过程、来源笔记 id。
  /// 思考过程本来没打算存（动辄上万字），但没有它回看时就只剩结论、看不到
  /// 论证过程，而报告本身最值钱的部分恰恰在那条推理链上。全文纯本地，不
  /// 进同步，体积不是问题。
  static const String tableInsightReports = 'insight_reports';

  static const String createInsightReportsSql = '''
    CREATE TABLE IF NOT EXISTS $tableInsightReports(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      lens_id TEXT NOT NULL,
      lens_name TEXT NOT NULL,
      scope_label TEXT NOT NULL,
      note_count INTEGER DEFAULT 0,
      content TEXT NOT NULL,
      title TEXT DEFAULT '',
      summary TEXT DEFAULT '',
      reasoning TEXT DEFAULT '',
      source_ids TEXT DEFAULT '',
      created_at TEXT NOT NULL
    )
  ''';

  static const String createInsightReportsIndexSql = '''
    CREATE INDEX IF NOT EXISTS idx_insight_reports_created
    ON $tableInsightReports(created_at DESC)
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
    if (oldVersion < 13) {
      // v13: 编辑历史版本
      await db.execute(createEditHistorySql);
      await db.execute(createEditHistoryIndexSql);
    }
    if (oldVersion < 14) {
      // v14: 洞察历史
      await db.execute(createInsightReportsSql);
      await db.execute(createInsightReportsIndexSql);
    }
    if (oldVersion < 15) {
      // v15: 洞察历史补标题、思考过程与来源笔记 id。
      // 老库的表里没有这三列，必须逐列补；_hasColumn 兜一下，重复升级不报错。
      const additions = <String, String>{
        'title': "TEXT DEFAULT ''",
        'reasoning': "TEXT DEFAULT ''",
        'source_ids': "TEXT DEFAULT ''",
      };
      for (final entry in additions.entries) {
        if (!await _hasColumn(db, tableInsightReports, entry.key)) {
          await db.execute(
            'ALTER TABLE $tableInsightReports '
            'ADD COLUMN ${entry.key} ${entry.value}',
          );
        }
      }
    }
    if (oldVersion < 16) {
      // v16: 洞察历史补「分析摘要」列。必须排在 v14 建表、v15 补列之后，
      // 老库才能一路升上来。老记录没有摘要，读出来是空串，界面不挂卡片。
      if (!await _hasColumn(db, tableInsightReports, 'summary')) {
        await db.execute(
          'ALTER TABLE $tableInsightReports '
          "ADD COLUMN summary TEXT DEFAULT ''",
        );
      }
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

  /// 按媒体类型筛选笔记（「有图片」/「有视频」）。
  ///
  /// 首页是 50 条一页的分页缓存，没滑到的笔记根本不在内存里，所以画廊那套
  /// 「扫 appProvider.notes」的做法天然只覆盖已加载的部分。这里直接查库：
  ///
  /// 1. 先用 `content LIKE '%!['`（图片和视频共用 markdown 写法）加
  ///    resourceList 非空做粗筛，把候选压到「可能带媒体」的那部分；
  /// 2. 再用 [NoteMediaFilter.matches] 精确判定，口径与卡片九宫格、详情页
  ///    完全一致（视频在那边已经和图片互斥）。
  ///
  /// SQL 不做精确判定是有意的：视频扩展名、alt 约定、服务端无扩展名资源
  /// 这几条规则散在 `MediaPaths` 里，抄一份到 SQL 里迟早和 Dart 侧对不上。
  Future<List<Note>> getNotesByMedia(
    NoteMediaFilter filter, {
    String orderBy = 'createdAt DESC',
    DatabaseExecutor? executor,
  }) async {
    final db = executor ?? await database;
    final List<Map<String, dynamic>> maps;
    if (filter == NoteMediaFilter.all) {
      maps = await db.query(viewActiveNotes, orderBy: orderBy);
    } else {
      maps = await db.query(
        viewActiveNotes,
        where: "(content LIKE '%![%' "
            "OR (IFNULL(resourceList, '') <> '' "
            "AND IFNULL(resourceList, '') <> '[]'))",
        orderBy: orderBy,
      );
    }

    final notes = maps.map(Note.fromMap);
    return notes.where(filter.matches).toList();
  }

  /// 查询「往年同月同日」的笔记，按创建时间倒序（最近的年份在前）。
  ///
  /// createdAt 在库里存的是本地时区的 ISO8601 文本，SQLite 的 strftime
  /// 可以直接按月-日匹配，不必把整库笔记读进内存再过滤。
  Future<List<Note>> getNotesOnMonthDay({
    required int month,
    required int day,
    required int excludeYear,
    DatabaseExecutor? executor,
  }) async {
    final db = executor ?? await database;
    String two(int value) => value.toString().padLeft(2, '0');
    final maps = await db.rawQuery(
      'SELECT * FROM $viewActiveNotes '
      "WHERE strftime('%m-%d', createdAt) = ? "
      "AND strftime('%Y', createdAt) <> ? "
      'ORDER BY createdAt DESC',
      ['${two(month)}-${two(day)}', two(excludeYear)],
    );
    return maps.map(Note.fromMap).toList();
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

  /// 批量查这些 id 里哪些已经存在。
  ///
  /// 刻意查 `notes` 表而不是 `viewActiveNotes`：**软删行也算存在**。导入类
  /// 功能（微信读书同步）用它做幂等，若把回收站里的笔记当成不存在，用户删
  /// 掉的记录会在下一轮同步被重新写回来。
  Future<Set<String>> getExistingNoteIds(Set<String> ids) async {
    if (ids.isEmpty) {
      return <String>{};
    }
    final db = await database;
    final result = <String>{};
    // SQLite 的变量上限是 999，分批查避免超限。
    final all = ids.toList();
    const batchSize = 900;
    for (var start = 0; start < all.length; start += batchSize) {
      final slice = all.sublist(
        start,
        (start + batchSize).clamp(0, all.length),
      );
      final placeholders = List.filled(slice.length, '?').join(',');
      final rows = await db.rawQuery(
        'SELECT id FROM notes WHERE id IN ($placeholders)',
        slice,
      );
      for (final row in rows) {
        final id = row['id'];
        if (id is String) {
          result.add(id);
        }
      }
    }
    return result;
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
  /// 导致 WebDAV 快照、引用关系全部跟着漂移。
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

  /// 把云备份的笔记合并进本地库（不清空现有数据）。
  ///
  /// WebDAV 备份本身就是本地库的快照，id 与本地同源，所以按 id 直接对齐：
  /// - 本地没有这条 → 插入；
  /// - 两边都有 → `updatedAt` 较新的赢，时间相同保留本地（本地编辑不丢）；
  /// - 本地这条已软删、且删除动作（updatedAt）不早于备份版本 → 不复活。
  ///
  /// 与 [replaceAllNotes] 不同：提醒表与待同步队列原样保留——合并场景里
  /// 本地的删除/改动仍然有效，清掉队列反而会把未补交的同步动作弄丢。
  /// 返回 (新增数, 更新数, 保留本地数)。
  Future<(int, int, int)> mergeNotes(
    List<Note> notes, {
    DatabaseExecutor? executor,
  }) async {
    Future<(int, int, int)> runMerge(DatabaseExecutor txn) async {
      var inserted = 0;
      var updated = 0;
      var keptLocal = 0;
      for (final note in notes) {
        final rows = await txn.query(
          'notes',
          where: 'id = ?',
          whereArgs: [note.id],
          limit: 1,
        );
        if (rows.isEmpty) {
          await txn.insert('notes', note.toMap());
          inserted++;
          continue;
        }
        final local = Note.fromMap(rows.first);
        final isLocalDeleted = local.rowStatus == 'DELETED';
        if (isLocalDeleted && !local.updatedAt.isBefore(note.updatedAt)) {
          // 本地删过、且删除发生在备份之后 → 尊重删除，不复活
          keptLocal++;
          continue;
        }
        if (note.updatedAt.isAfter(local.updatedAt)) {
          await txn.update(
            'notes',
            note.toMap(),
            where: 'id = ?',
            whereArgs: [note.id],
          );
          updated++;
        } else {
          keptLocal++;
        }
      }
      return (inserted, updated, keptLocal);
    }

    final db = executor ?? await database;
    if (executor != null) {
      // 调用方已在事务里（测试场景），不再嵌套
      return runMerge(db);
    }
    return (await database).transaction(runMerge);
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
  /// 创建时间、更新时间、标签、提醒等本地字段。
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
