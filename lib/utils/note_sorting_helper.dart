import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/models/sort_order.dart';

/// 首页列表的排序子句，供 SQLite 分页查询使用。
///
/// 必须和 [noteComparator] 逐级对应：先置顶，再所选时间字段，最后用 `id`
/// 兜底。没有第三级时，同一秒创建的多条笔记在两次查询里的先后可能不同，
/// 而分页是按 `OFFSET` 取页的 —— 并列项一换位就会重复显示或漏掉。
///
/// `isPinned` 用 `IFNULL` 兜老库里可能存在的 NULL（SQLite 把 NULL 当最小值，
/// 不兜的话 `DESC` 会把它们排到有置顶标记的行后面，和 Dart 侧 `isPinned=false`
/// 的口径对不上）。
String noteOrderBySql(SortOrder order) => switch (order) {
      SortOrder.newest => 'IFNULL(isPinned, 0) DESC, createdAt DESC, id DESC',
      SortOrder.oldest => 'IFNULL(isPinned, 0) DESC, createdAt ASC, id ASC',
      SortOrder.updated => 'IFNULL(isPinned, 0) DESC, updatedAt DESC, id DESC',
      SortOrder.updatedOldest =>
        'IFNULL(isPinned, 0) DESC, updatedAt ASC, id ASC',
    };

/// 该排序是倒序还是正序；`id` 并列兜底跟着同一方向，让「从旧到新」正好是
/// 「从新到旧」的镜像。
bool _isDescending(SortOrder order) =>
    order == SortOrder.newest || order == SortOrder.updated;

int Function(Note a, Note b) noteComparator(SortOrder order) => (a, b) {
      // 置顶优先，和 noteOrderBySql 的第一级一致
      if (a.isPinned != b.isPinned) {
        return a.isPinned ? -1 : 1;
      }

      final byTime = switch (order) {
        SortOrder.newest => b.createdAt.compareTo(a.createdAt),
        SortOrder.oldest => a.createdAt.compareTo(b.createdAt),
        SortOrder.updated => b.updatedAt.compareTo(a.updatedAt),
        SortOrder.updatedOldest => a.updatedAt.compareTo(b.updatedAt),
      };
      if (byTime != 0) {
        return byTime;
      }

      // 时间相同用 id 兜底，保证总序与 SQL 的 ORDER BY 完全一致
      return _isDescending(order) ? b.id.compareTo(a.id) : a.id.compareTo(b.id);
    };

List<Note> sortedNotesCopy(List<Note> notes, SortOrder order) {
  final sorted = List<Note>.from(notes);
  sorted.sort(noteComparator(order));
  return sorted;
}
