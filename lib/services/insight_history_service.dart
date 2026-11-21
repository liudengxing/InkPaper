import 'package:flutter/foundation.dart';
import 'package:inkpaper/services/database_service.dart';
import 'package:sqflite/sqflite.dart';

/// 一份存下来的洞察报告。
///
/// 只保留回看需要的东西：视角、范围、条数、正文、生成时间。思考过程
/// 不存——它动辄上万字，一份记录会膨胀十倍，而回看时没人在意它。
class InsightReportEntry {
  const InsightReportEntry({
    required this.id,
    required this.lensId,
    required this.lensName,
    required this.scopeLabel,
    required this.noteCount,
    required this.content,
    required this.createdAt,
  });

  final int id;
  final String lensId;
  final String lensName;
  final String scopeLabel;
  final int noteCount;
  final String content;
  final DateTime createdAt;

  /// 列表里显示的一句话摘要：去掉换行与前后的引用标记。
  String get preview {
    final flat = content
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'\[\d+\]'), '')
        .trim();
    return flat.length > 90 ? '${flat.substring(0, 90)}…' : flat;
  }
}

/// 洞察历史服务。
///
/// 每生成成功一份洞察就存一条，纯本地 SQLite，不进同步——它是对笔记的
/// 再加工产物，跟着笔记同步反而会互相覆盖。
///
/// 保留上限 [maxEntries]：够翻很久，又不会让库无限长。
class InsightHistoryService {
  InsightHistoryService._();

  static final InsightHistoryService instance = InsightHistoryService._();

  /// 最多保留多少份。一份一两千字，两百份大约几十万字符，SQLite 无压力。
  static const int maxEntries = 200;

  Future<Database> get _db => DatabaseService().database;

  /// 存一份报告，返回新记录的 id（失败返回 null，不抛）。
  ///
  /// 写历史是副作用，不能因为落盘失败就把用户刚看到的报告判成失败。
  Future<int?> save({
    required String lensId,
    required String lensName,
    required String scopeLabel,
    required int noteCount,
    required String content,
  }) async {
    final text = content.trim();
    if (text.isEmpty) {
      return null;
    }
    try {
      final db = await _db;
      final id = await db.insert(DatabaseService.tableInsightReports, {
        'lens_id': lensId,
        'lens_name': lensName,
        'scope_label': scopeLabel,
        'note_count': noteCount,
        'content': text,
        'created_at': DateTime.now().toIso8601String(),
      });
      await _prune(db);
      return id;
    } on Object catch (e) {
      debugPrint('⚠️ 写入洞察历史失败: $e');
      return null;
    }
  }

  /// 历史列表，新的在前。
  Future<List<InsightReportEntry>> list({int limit = maxEntries}) async {
    try {
      final db = await _db;
      final rows = await db.query(
        DatabaseService.tableInsightReports,
        orderBy: 'created_at DESC, id DESC',
        limit: limit,
      );
      return rows.map(_fromRow).toList();
    } on Object catch (e) {
      debugPrint('⚠️ 读取洞察历史失败: $e');
      return const <InsightReportEntry>[];
    }
  }

  /// 某条记录的最新内容（列表页点进去时用，避免把整段正文一直攥在内存里）。
  Future<InsightReportEntry?> get(int id) async {
    try {
      final db = await _db;
      final rows = await db.query(
        DatabaseService.tableInsightReports,
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      return rows.isEmpty ? null : _fromRow(rows.first);
    } on Object catch (e) {
      debugPrint('⚠️ 读取洞察记录失败: $e');
      return null;
    }
  }

  Future<void> delete(int id) async {
    try {
      final db = await _db;
      await db.delete(
        DatabaseService.tableInsightReports,
        where: 'id = ?',
        whereArgs: [id],
      );
    } on Object catch (e) {
      debugPrint('⚠️ 删除洞察记录失败: $e');
    }
  }

  /// 超出上限的旧记录按时间删掉。
  Future<void> _prune(Database db) async {
    try {
      await db.execute(
        'DELETE FROM ${DatabaseService.tableInsightReports} '
        'WHERE id NOT IN ('
        '  SELECT id FROM ${DatabaseService.tableInsightReports} '
        '  ORDER BY created_at DESC, id DESC LIMIT ?'
        ')',
        [maxEntries],
      );
    } on Object catch (e) {
      debugPrint('⚠️ 清理洞察历史失败: $e');
    }
  }

  InsightReportEntry _fromRow(Map<String, Object?> row) => InsightReportEntry(
        id: row['id']! as int,
        lensId: (row['lens_id'] ?? '') as String,
        lensName: (row['lens_name'] ?? '洞察') as String,
        scopeLabel: (row['scope_label'] ?? '') as String,
        noteCount: (row['note_count'] as int?) ?? 0,
        content: (row['content'] ?? '') as String,
        createdAt: DateTime.tryParse((row['created_at'] ?? '') as String) ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );
}
