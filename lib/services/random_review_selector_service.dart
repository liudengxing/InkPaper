import 'dart:math';

import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/utils/memos_content_helper.dart';
import 'package:inkpaper/utils/tag_utils.dart' as tag_utils;

abstract final class RandomReviewSelectorService {
  static const int allDays = 999999;

  /// [customStart] / [customEnd] 非空时优先用自定义区间（左闭右开），
  /// 忽略 [reviewDays]——设置页的「自定义」走这条。
  static List<Note> select({
    required List<Note> notes,
    int reviewDays = allDays,
    DateTime? customStart,
    DateTime? customEnd,
    int reviewCount = 1,
    Set<String> selectedTags = const {},
    Set<String> excludeIds = const {},
    Random? random,
    bool requireVisibleText = false,
  }) {
    if (notes.isEmpty || reviewCount <= 0) {
      return <Note>[];
    }

    final sourceNotes = requireVisibleText
        ? notes
            .where(
              (note) => MemosContentHelper.previewVisibleText(note.content)
                  .trim()
                  .isNotEmpty,
            )
            .toList()
        : notes;
    if (sourceNotes.isEmpty) {
      return <Note>[];
    }

    final normalizedDays = reviewDays <= 0 ? allDays : reviewDays;
    final cutoffDate = DateTime.now().subtract(Duration(days: normalizedDays));
    final hasCustomWindow = customStart != null && customEnd != null;
    var filteredNotes = sourceNotes.where((note) {
      if (hasCustomWindow) {
        return !note.displayTime.isBefore(customStart) &&
            note.displayTime.isBefore(customEnd);
      }
      return note.displayTime.isAfter(cutoffDate);
    }).toList();

    if (selectedTags.isNotEmpty) {
      filteredNotes = filteredNotes.where((note) {
        // 标签既可能在库里的 tags 字段，也可能只写在正文的 # 后面，
        // 只看正文的话，靠 tags 字段存标签的笔记会被整批筛掉。
        final noteTags = <String>{
          ...note.tags,
          ...tag_utils.extractTagsFromContent(note.content),
        };
        return selectedTags.every(noteTags.contains);
      }).toList();
    }

    final availableNotes = filteredNotes.isEmpty ? sourceNotes : filteredNotes;

    // 「换一批」：先把上一批排掉再抽，抽完一条不剩（库比一批还小）才退回
    // 全集，否则小库会越刷越空，看着像坏了。
    var pool = availableNotes;
    if (excludeIds.isNotEmpty) {
      final remaining = availableNotes
          .where((note) => !excludeIds.contains(note.id))
          .toList();
      if (remaining.isNotEmpty) {
        pool = remaining;
      }
    }

    final shuffled = List<Note>.from(pool)..shuffle(random ?? Random());
    return shuffled.take(reviewCount).toList();
  }

  /// 小组件回顾候选：优先挑有可见文字的笔记，挑不到再退回任意笔记。
  ///
  /// 口径与 [select] 的 `requireVisibleText` 一致：先按可见文字过滤、再按
  /// 时间范围取，范围内一条都没有时退回全库。区别只在判定顺序——这里先
  /// 洗牌、再边取边判，取满 [reviewCount] 就停。
  ///
  /// 以前是先对全库每条跑一次 `previewVisibleText`（完整 Markdown 解析）再
  /// 洗牌，1500 条的库上一次快照构建就是 600ms 级的开销。而「洗牌后取前 N 个
  /// 满足条件的」和「先筛出满足条件的再洗牌取前 N 个」分布相同，所以只要
  /// 抽到的前几条带文字，解析量就从整库降到十几条。
  static List<Note> selectWidgetCandidates({
    required List<Note> notes,
    int reviewDays = allDays,
    int reviewCount = 8,
    Random? random,
  }) {
    if (notes.isEmpty || reviewCount <= 0) {
      return <Note>[];
    }

    final rng = random ?? Random();
    final inRange = _withinDays(notes, reviewDays);
    final primary = inRange.isEmpty ? notes : inRange;

    final picked = _takeWithVisibleText(primary, reviewCount, rng);
    if (picked.isNotEmpty) {
      return picked;
    }

    // 范围内的笔记全是没有可见文字的（图片型日记）：回到全库找带文字的，
    // 和旧口径「范围内筛不到就退回全库文本笔记」一致。
    if (primary.length < notes.length) {
      final wider = _takeWithVisibleText(notes, reviewCount, rng);
      if (wider.isNotEmpty) {
        return wider;
      }
    }

    // 全库都没有可见文字：退回任意笔记，别让回顾卡片空着。
    return (List<Note>.from(primary)..shuffle(rng)).take(reviewCount).toList();
  }

  static List<Note> _withinDays(List<Note> notes, int reviewDays) {
    final normalizedDays = reviewDays <= 0 ? allDays : reviewDays;
    final cutoffDate = DateTime.now().subtract(Duration(days: normalizedDays));
    return notes.where((note) => note.displayTime.isAfter(cutoffDate)).toList();
  }

  static List<Note> _takeWithVisibleText(
    List<Note> notes,
    int reviewCount,
    Random random,
  ) {
    final order = List<Note>.from(notes)..shuffle(random);
    final picked = <Note>[];
    for (final note in order) {
      if (!_hasVisibleText(note)) {
        continue;
      }
      picked.add(note);
      if (picked.length >= reviewCount) {
        break;
      }
    }
    return picked;
  }

  static bool _hasVisibleText(Note note) {
    return MemosContentHelper.previewVisibleText(note.content)
        .trim()
        .isNotEmpty;
  }
}
