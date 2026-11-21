import 'dart:math';

import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/utils/memos_content_helper.dart';
import 'package:inkpaper/utils/tag_utils.dart' as tag_utils;

abstract final class RandomReviewSelectorService {
  static const int allDays = 999999;

  static List<Note> select({
    required List<Note> notes,
    int reviewDays = allDays,
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
    var filteredNotes = sourceNotes
        .where((note) => note.displayTime.isAfter(cutoffDate))
        .toList();

    if (selectedTags.isNotEmpty) {
      filteredNotes = filteredNotes.where((note) {
        final noteTags = tag_utils.extractTagsFromContent(note.content).toSet();
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

  static List<Note> selectWidgetCandidates({
    required List<Note> notes,
    int reviewDays = allDays,
    int reviewCount = 8,
    Random? random,
  }) {
    final textNotes = select(
      notes: notes,
      reviewDays: reviewDays,
      reviewCount: reviewCount,
      random: random,
      requireVisibleText: true,
    );
    if (textNotes.isNotEmpty) {
      return textNotes;
    }

    return select(
      notes: notes,
      reviewDays: reviewDays,
      reviewCount: reviewCount,
      random: random,
    );
  }
}
