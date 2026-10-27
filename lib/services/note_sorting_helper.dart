import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/models/sort_order.dart';

int Function(Note a, Note b) noteComparator(SortOrder order) => (a, b) {
      // pinned first
      if (a.isPinned && !b.isPinned) {
        return -1;
      }
      if (!a.isPinned && b.isPinned) {
        return 1;
      }

      return switch (order) {
        SortOrder.newest => b.createdAt.compareTo(a.createdAt),
        SortOrder.oldest => a.createdAt.compareTo(b.createdAt),
        SortOrder.updated => b.updatedAt.compareTo(a.updatedAt),
        SortOrder.updatedOldest => a.updatedAt.compareTo(b.updatedAt),
      };
    };

List<Note> sortedNotesCopy(List<Note> notes, SortOrder order) {
  final sorted = List<Note>.from(notes);
  sorted.sort(noteComparator(order));
  return sorted;
}

/// Infers current sort order from a list already sorted with pinned notes first.
///
/// 用相邻对投票而不是只比较前两条：创建时间整列单调就认定是按创建时间排序，
/// 否则再看编辑时间。只比较前两条时，「创建顺序与编辑顺序恰好相反」的列表
/// 会被误判成按编辑时间排序。
SortOrder inferCurrentSortOrder(List<Note> notes) {
  final unpinned = notes.where((n) => !n.isPinned).toList();
  if (unpinned.length < 2) {
    return SortOrder.newest;
  }

  final pairs = unpinned.length - 1;
  var createdDesc = 0;
  var createdAsc = 0;
  var updatedDesc = 0;
  var updatedAsc = 0;

  for (var i = 0; i < pairs; i++) {
    final a = unpinned[i];
    final b = unpinned[i + 1];
    if (!a.createdAt.isBefore(b.createdAt)) {
      createdDesc++;
    }
    if (!a.createdAt.isAfter(b.createdAt)) {
      createdAsc++;
    }
    if (!a.updatedAt.isBefore(b.updatedAt)) {
      updatedDesc++;
    }
    if (!a.updatedAt.isAfter(b.updatedAt)) {
      updatedAsc++;
    }
  }

  if (createdDesc == pairs) {
    return SortOrder.newest;
  }
  if (createdAsc == pairs) {
    return SortOrder.oldest;
  }
  if (updatedDesc == pairs) {
    return SortOrder.updated;
  }
  if (updatedAsc == pairs) {
    return SortOrder.updatedOldest;
  }

  // 数据不严格单调（例如同一秒创建的笔记）时按多数方向兜底
  if (createdDesc >= createdAsc) {
    return SortOrder.newest;
  }
  return updatedDesc >= updatedAsc
      ? SortOrder.updated
      : SortOrder.updatedOldest;
}
