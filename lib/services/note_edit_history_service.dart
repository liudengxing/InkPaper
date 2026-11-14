import 'package:flutter/foundation.dart';
import 'package:inkpaper/services/database_service.dart';
import 'package:sqflite/sqflite.dart';

/// 一条编辑历史版本。
class NoteEditHistoryEntry {
  const NoteEditHistoryEntry({
    required this.id,
    required this.noteId,
    required this.content,
    required this.createdAt,
  });

  final int id;
  final String noteId;
  final String content;
  final DateTime createdAt;
}

/// 笔记编辑历史版本服务（参考 flomo 历史版本）。
///
/// 只在本地 SQLite 落盘，不进同步；快照是完整正文 markdown（图片是
/// 路径引用，原图还在即可恢复）。
///
/// 快照时机由编辑器决定：
/// * 每次成功保存前，先存下「保存前的内容」——这是天然的版本分界线；
/// * 编辑过程中每 [midEditInterval] 分钟自动存一份（内容有变化才存），
///   中途崩溃/杀进程也能回到几分钟前。
///
/// 每条笔记最多保留 [maxPerNote] 份，超过 30 天的自动清理。
class NoteEditHistoryService {
  NoteEditHistoryService._();

  static final NoteEditHistoryService instance = NoteEditHistoryService._();

  /// 每条笔记保留的版本数上限。
  static const int maxPerNote = 20;

  /// 版本保留时长（flomo 同款 30 天）。
  static const Duration retention = Duration(days: 30);

  /// 编辑中自动快照的最小间隔：太密会让版本列表失去「里程碑」感。
  static const Duration midEditInterval = Duration(minutes: 5);

  Future<Database> get _db => DatabaseService().database;

  /// 写入一份快照；与该笔记最新一份内容相同则跳过。
  Future<void> addSnapshot({
    required String noteId,
    required String content,
  }) async {
    if (noteId.isEmpty) {
      return;
    }
    try {
      final db = await _db;
      final latest = await db.query(
        DatabaseService.tableEditHistory,
        where: 'note_id = ?',
        whereArgs: [noteId],
        orderBy: 'created_at DESC, id DESC',
        limit: 1,
      );
      if (latest.isNotEmpty && latest.first['content'] == content) {
        return;
      }

      await db.insert(DatabaseService.tableEditHistory, {
        'note_id': noteId,
        'content': content,
        'created_at': DateTime.now().toIso8601String(),
      });
      await _prune(db, noteId);
    } on Object catch (e) {
      debugPrint('⚠️ 写入编辑历史失败: $e');
    }
  }

  /// 某条笔记的历史版本（新的在前），已剔除超过保留期的。
  Future<List<NoteEditHistoryEntry>> listSnapshots(String noteId) async {
    try {
      final cutoff = DateTime.now().subtract(retention).toIso8601String();
      final db = await _db;
      final rows = await db.query(
        DatabaseService.tableEditHistory,
        where: 'note_id = ? AND created_at > ?',
        whereArgs: [noteId, cutoff],
        orderBy: 'created_at DESC, id DESC',
      );
      return rows.map(_fromRow).toList();
    } on Object catch (e) {
      debugPrint('⚠️ 读取编辑历史失败: $e');
      return [];
    }
  }

  /// 清掉过期版本与超出上限的旧版本。
  Future<void> _prune(Database db, String noteId) async {
    try {
      final cutoff = DateTime.now().subtract(retention).toIso8601String();
      await db.delete(
        DatabaseService.tableEditHistory,
        where: 'note_id = ? AND created_at <= ?',
        whereArgs: [noteId, cutoff],
      );
      // 超出上限的按时间最旧的删（rowid 序 = 插入序）
      await db.execute(
        'DELETE FROM ${DatabaseService.tableEditHistory} '
        'WHERE note_id = ? AND id NOT IN ('
        '  SELECT id FROM ${DatabaseService.tableEditHistory} '
        '  WHERE note_id = ? ORDER BY created_at DESC, id DESC LIMIT ?'
        ')',
        [noteId, noteId, maxPerNote],
      );
    } on Object catch (e) {
      debugPrint('⚠️ 清理编辑历史失败: $e');
    }
  }

  /// 清空某条笔记的历史（笔记删除时调用；失败不打断主流程）。
  Future<void> clearForNote(String noteId) async {
    try {
      final db = await _db;
      await db.delete(
        DatabaseService.tableEditHistory,
        where: 'note_id = ?',
        whereArgs: [noteId],
      );
    } on Object catch (e) {
      debugPrint('⚠️ 清空笔记编辑历史失败: $e');
    }
  }

  NoteEditHistoryEntry _fromRow(Map<String, Object?> row) =>
      NoteEditHistoryEntry(
        id: row['id']! as int,
        noteId: row['note_id']! as String,
        content: row['content']! as String,
        createdAt: DateTime.tryParse(row['created_at']! as String) ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );
}
