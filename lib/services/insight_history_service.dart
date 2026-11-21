import 'package:flutter/foundation.dart';
import 'package:inkpaper/services/database_service.dart';
import 'package:sqflite/sqflite.dart';

/// 一份存下来的洞察报告。
///
/// 存的是「当时那份报告的全部」：标题、正文、思考过程、来源笔记 id。思考
/// 过程比正文长好几倍，但没有它回看时就只剩结论、看不到论证怎么走的，而
/// 报告最值钱的恰恰是那条推理链。纯本地、不进同步，体积不是问题。
class InsightReportEntry {
  const InsightReportEntry({
    required this.id,
    required this.lensId,
    required this.lensName,
    required this.scopeLabel,
    required this.noteCount,
    required this.content,
    required this.createdAt,
    this.title = '',
    this.reasoning = '',
    this.sourceIds = const <String>[],
  });

  final int id;
  final String lensId;
  final String lensName;
  final String scopeLabel;
  final int noteCount;
  final String content;
  final DateTime createdAt;

  /// 模型从正文里提炼的标题；老记录为空，界面退回 [lensName]。
  final String title;

  /// 思考链原文，可能为空（非推理模型、或老记录）。
  final String reasoning;

  /// 按编号顺序存下来的来源笔记 id，下标 0 即正文里的编号 1。
  ///
  /// 只存 id 不存正文快照：笔记改了，点开看到的就是现在的版本；笔记删了，
  /// 提示「原笔记已不在」比展示一份过期快照更诚实。
  final List<String> sourceIds;

  /// 列表里显示的一句话摘要：去掉换行与前后的引用标记。
  String get preview {
    final flat = content
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'\[\d+\]'), '')
        .trim();
    return flat.length > 90 ? '${flat.substring(0, 90)}…' : flat;
  }

  /// 按正文编号取来源笔记 id（1 起算），越界返回 null。
  String? sourceIdAt(int index) {
    if (index < 1 || index > sourceIds.length) {
      return null;
    }
    return sourceIds[index - 1];
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

  /// 最多保留多少份。一份正文加思考链大约几十 KB，两百份在 SQLite 里很轻松。
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
    String title = '',
    String reasoning = '',
    List<String> sourceIds = const <String>[],
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
        'title': title.trim(),
        'reasoning': reasoning.trim(),
        // id 里不含逗号，拼起来比 JSON 省事，也不用多一层解码。
        'source_ids': sourceIds.join(','),
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

  InsightReportEntry _fromRow(Map<String, Object?> row) {
    final rawIds = ((row['source_ids'] ?? '') as String).trim();
    return InsightReportEntry(
      id: row['id']! as int,
      lensId: (row['lens_id'] ?? '') as String,
      lensName: (row['lens_name'] ?? '洞察') as String,
      scopeLabel: (row['scope_label'] ?? '') as String,
      noteCount: (row['note_count'] as int?) ?? 0,
      content: (row['content'] ?? '') as String,
      title: (row['title'] ?? '') as String,
      reasoning: (row['reasoning'] ?? '') as String,
      sourceIds: rawIds.isEmpty
          ? const <String>[]
          : rawIds.split(',').where((id) => id.isNotEmpty).toList(),
      createdAt: DateTime.tryParse((row['created_at'] ?? '') as String) ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}
