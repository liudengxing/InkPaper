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
  }) =>
      selectWidgetCandidatesFrom<Note>(
        notes: notes,
        reviewDays: reviewDays,
        reviewCount: reviewCount,
        random: random,
        displayDayKey: (note) => _dayKey(note.displayTime),
        contentOf: (note) => note.content,
      );

  /// [selectWidgetCandidates] 的通用版本：不关心调用方拿的是完整 [Note] 还是
  /// 只带 ISO 字符串的统计行（`WidgetStatNote`），日期比较与可见文字判定都
  /// 由回调提供。
  ///
  /// 时间范围按「自然日」比较：`reviewDays = 7` 就是今天往前数 7 个日历日，
  /// 而不是精确到时分秒的 168 小时。窗口最多宽出不到一天，换来的是统计行不必
  /// 为了过滤而解析 1500 个本地 `DateTime`（每次都要查时区，约 45µs）。
  static List<T> selectWidgetCandidatesFrom<T>({
    required List<T> notes,
    required String Function(T note) displayDayKey,
    required String Function(T note) contentOf,
    int reviewDays = allDays,
    int reviewCount = 8,
    Random? random,
  }) {
    if (notes.isEmpty || reviewCount <= 0) {
      return <T>[];
    }

    final rng = random ?? Random();
    final inRange = _withinDays<T>(notes, reviewDays, displayDayKey);
    final primary = inRange.isEmpty ? notes : inRange;

    final picked = _takeWithVisibleText<T>(
      primary,
      reviewCount,
      rng,
      contentOf,
    );
    if (picked.isNotEmpty) {
      return picked;
    }

    // 范围内的笔记全是没有可见文字的（图片型日记）：回到全库找带文字的，
    // 和旧口径「范围内筛不到就退回全库文本笔记」一致。
    if (primary.length < notes.length) {
      final wider = _takeWithVisibleText<T>(notes, reviewCount, rng, contentOf);
      if (wider.isNotEmpty) {
        return wider;
      }
    }

    // 全库都没有可见文字：退回任意笔记，别让回顾卡片空着。
    return (List<T>.from(primary)..shuffle(rng)).take(reviewCount).toList();
  }

  static List<T> _withinDays<T>(
    List<T> notes,
    int reviewDays,
    String Function(T note) displayDayKey,
  ) {
    final normalizedDays = reviewDays <= 0 ? allDays : reviewDays;
    // 999999 天 ≈ 2738 年，等于「不限」；顺带避开把 cutoff 算到公元前之后
    // 日期字符串比较失效的问题。
    if (normalizedDays >= allDays) {
      return notes;
    }
    final cutoff = DateTime.now().subtract(Duration(days: normalizedDays));
    final cutoffKey = _dayKey(cutoff);
    return notes
        .where((note) => displayDayKey(note).compareTo(cutoffKey) >= 0)
        .toList();
  }

  static List<T> _takeWithVisibleText<T>(
    List<T> notes,
    int reviewCount,
    Random random,
    String Function(T note) contentOf,
  ) {
    final order = List<T>.from(notes)..shuffle(random);
    final picked = <T>[];
    for (final note in order) {
      if (MemosContentHelper.previewVisibleText(contentOf(note))
          .trim()
          .isEmpty) {
        continue;
      }
      picked.add(note);
      if (picked.length >= reviewCount) {
        break;
      }
    }
    return picked;
  }

  /// 日历日键（yyyy-MM-dd），按字段值取，不做时区换算。
  static String _dayKey(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)}';
  }
}
