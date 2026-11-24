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
      SortOrder.newest =>
        'IFNULL(isPinned, 0) DESC, ${noteTimeKeySql('createdAt')} DESC, id DESC',
      SortOrder.oldest =>
        'IFNULL(isPinned, 0) DESC, ${noteTimeKeySql('createdAt')} ASC, id ASC',
      SortOrder.updated =>
        'IFNULL(isPinned, 0) DESC, ${noteTimeKeySql('updatedAt')} DESC, id DESC',
      SortOrder.updatedOldest =>
        'IFNULL(isPinned, 0) DESC, ${noteTimeKeySql('updatedAt')} ASC, id ASC',
    };

/// SQL 侧的时间比较键，与 [compareNoteWallClock] 同一口径。
///
/// `substr(..., 1, 23)` 取到 `YYYY-MM-DDTHH:MM:SS.mmm`：后缀 `Z` 不参与比较
/// （它只是来源标记，不代表要换算时区），微秒被截掉（Dart 侧同样不比到微秒，
/// 否则同一瞬间两种精度的行会在两边排出不同顺序）。`replace` 把老库里可能
/// 存在的 `DateTime.toString()` 格式（空格分隔）归一成 `T`：空格（0x20）会
/// 被排在 `T`（0x54）之前，同一时刻的两种写法在 SQL 里就成了先后。
String noteTimeKeySql(String column) =>
    "substr(replace($column, ' ', 'T'), 1, 23)";

/// 该排序是倒序还是正序；`id` 并列兜底跟着同一方向，让「从旧到新」正好是
/// 「从新到旧」的镜像。
bool _isDescending(SortOrder order) =>
    order == SortOrder.newest || order == SortOrder.updated;

/// 按**墙上时钟**比较两个时间戳（毫秒精度）。
///
/// 库里两种来源混存：本地笔记写 `2026-11-23T09:00:00.000`（本地时间、无
/// 后缀），Memos 笔记写 `2026-11-23T02:00:00.000Z`（服务端把北京时间当 UTC
/// 存）。直接比字符串是「09 > 02」，直接比 `DateTime` 却是「01:00Z <
/// 02:00Z」——同一对笔记在 SQL 和 Dart 里会得到相反的顺序。
///
/// 项目对时间显示的既有口径是「字段值就是墙上时钟、一律不做时区换算」
/// （见 `note_timestamp_format.dart`），排序跟着这个口径：只比年月日时分秒
/// 毫秒这些字段，两个来源便落在同一条坐标轴上，也与用户看到的时刻一致。
/// 微秒被截掉，对应 SQL 侧取到毫秒的 `substr(..., 1, 23)`。
int compareNoteWallClock(DateTime a, DateTime b) {
  var result = a.year.compareTo(b.year);
  if (result != 0) {
    return result;
  }
  result = a.month.compareTo(b.month);
  if (result != 0) {
    return result;
  }
  result = a.day.compareTo(b.day);
  if (result != 0) {
    return result;
  }
  result = a.hour.compareTo(b.hour);
  if (result != 0) {
    return result;
  }
  result = a.minute.compareTo(b.minute);
  if (result != 0) {
    return result;
  }
  result = a.second.compareTo(b.second);
  if (result != 0) {
    return result;
  }
  return a.millisecond.compareTo(b.millisecond);
}

int Function(Note a, Note b) noteComparator(SortOrder order) => (a, b) {
      // 置顶优先，和 noteOrderBySql 的第一级一致
      if (a.isPinned != b.isPinned) {
        return a.isPinned ? -1 : 1;
      }

      // 时间这一级必须和 SQL 的 [noteTimeKeySql] 用同一个口径：比墙上时钟的
      // 字段，而不是比绝对时间点。混存两种来源时两者会给出相反顺序。
      final byTime = switch (order) {
        SortOrder.newest => compareNoteWallClock(b.createdAt, a.createdAt),
        SortOrder.oldest => compareNoteWallClock(a.createdAt, b.createdAt),
        SortOrder.updated => compareNoteWallClock(b.updatedAt, a.updatedAt),
        SortOrder.updatedOldest =>
          compareNoteWallClock(a.updatedAt, b.updatedAt),
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
