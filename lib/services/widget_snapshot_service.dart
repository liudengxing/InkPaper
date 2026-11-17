import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:inkpaper/config/app_config.dart' as Config;
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/services/random_review_selector_service.dart';
import 'package:inkpaper/utils/memos_content_helper.dart';
import 'package:inkpaper/utils/tag_input_helper.dart';
import 'package:inkpaper/utils/todo_parser.dart';

abstract final class WidgetSnapshotService {
  static const String _snapshotPrefsKey = 'inkpaper_widget_snapshot';
  static const String _channelName = Config.AppConfig.channelNativeAlarm;
  static const MethodChannel _channel = MethodChannel(_channelName);
  static Timer? _debounceTimer;
  static String? _lastSnapshotJson;

  static void scheduleUpdate({
    required List<Note> notes,
    required bool isLocalMode,
    required bool isLoggedIn,
    required bool isSyncing,
    int reviewRefreshIntervalMinutes = 60,
    int reviewRangeDays = 0,
    String? syncMessage,
    Duration delay = const Duration(milliseconds: 350),
  }) {
    _debounceTimer?.cancel();
    final snapshotNotes = List<Note>.from(notes);
    _debounceTimer = Timer(delay, () {
      unawaited(
        update(
          notes: snapshotNotes,
          isLocalMode: isLocalMode,
          isLoggedIn: isLoggedIn,
          isSyncing: isSyncing,
          reviewRefreshIntervalMinutes: reviewRefreshIntervalMinutes,
          reviewRangeDays: reviewRangeDays,
          syncMessage: syncMessage,
        ),
      );
    });
  }

  static Future<void> update({
    required List<Note> notes,
    required bool isLocalMode,
    required bool isLoggedIn,
    required bool isSyncing,
    int reviewRefreshIntervalMinutes = 60,
    int reviewRangeDays = 0,
    String? syncMessage,
  }) async {
    try {
      final json = jsonEncode(
        _buildSnapshot(
          notes: notes,
          isLocalMode: isLocalMode,
          isLoggedIn: isLoggedIn,
          isSyncing: isSyncing,
          reviewRefreshIntervalMinutes: reviewRefreshIntervalMinutes,
          reviewRangeDays: reviewRangeDays,
          syncMessage: syncMessage,
        ),
      );

      if (json == _lastSnapshotJson) {
        return;
      }
      _lastSnapshotJson = json;

      await _channel.invokeMethod<void>(
        'saveWidgetSnapshot',
        <String, Object?>{
          'key': _snapshotPrefsKey,
          'snapshot': json,
        },
      );
    } on Object catch (e) {
      if (kDebugMode) {
        debugPrint('WidgetSnapshotService: 更新桌面小组件快照失败: $e');
      }
    }
  }

  @visibleForTesting
  static Map<String, Object?> debugBuildSnapshot({
    required List<Note> notes,
    required bool isLocalMode,
    required bool isLoggedIn,
    required bool isSyncing,
    int reviewRefreshIntervalMinutes = 60,
    int reviewRangeDays = 0,
    String? syncMessage,
  }) =>
      _buildSnapshot(
        notes: notes,
        isLocalMode: isLocalMode,
        isLoggedIn: isLoggedIn,
        isSyncing: isSyncing,
        reviewRefreshIntervalMinutes: reviewRefreshIntervalMinutes,
        reviewRangeDays: reviewRangeDays,
        syncMessage: syncMessage,
      );

  static Map<String, Object?> _buildSnapshot({
    required List<Note> notes,
    required bool isLocalMode,
    required bool isLoggedIn,
    required bool isSyncing,
    required int reviewRefreshIntervalMinutes,
    required int reviewRangeDays,
    String? syncMessage,
  }) {
    final visibleNotes = notes.where(_isWidgetVisibleNote).toList()
      ..sort((a, b) => b.displayTime.compareTo(a.displayTime));

    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    final todayNotes = visibleNotes
        .where((note) => note.displayTime.isAfter(todayStart))
        .toList();
    var pendingTodos = 0;
    var todayWords = 0;

    for (final note in visibleNotes) {
      pendingTodos += TodoParser.countTodos(note.content)['pending'] ?? 0;
    }

    for (final note in todayNotes) {
      todayWords +=
          _wordCount(MemosContentHelper.previewVisibleText(note.content));
    }

    // 快速记录小部件的标签排序与编辑器「#标签」补全同源：
    // rankTagsByUsage（频次 × 新鲜度加权），用户常用标签浮到前面。
    // 早先这里只按出现次数降序，和新打笔记的建议栏顺序对不上。
    final quickTags = rankTagsByUsage(
      notes: notes.map(
        (note) => (tags: note.tags, updatedAt: note.updatedAt),
      ),
    );

    final reviewNotes = _pickReviewNotes(
      visibleNotes,
      reviewRangeDays: reviewRangeDays,
    );
    final unsyncedCount = visibleNotes.where((note) => !note.isSynced).length;

    // 统计小组件（周/月）要的是「每天各记了几条」。按 displayTime 的字段值
    // 取日期，和首页热力图、时间标签同一口径——不 toLocal。
    final dayCounts = <String, int>{};
    for (final note in visibleNotes) {
      final time = note.displayTime;
      final key = _dayKey(DateTime(time.year, time.month, time.day));
      dayCounts[key] = (dayCounts[key] ?? 0) + 1;
    }

    // 一周按周一起算，todayIndex 让原生那边给今天描个边。
    final weekStart =
        todayStart.subtract(Duration(days: todayStart.weekday - 1));
    final weekDays = List<int>.generate(
      7,
      (index) => dayCounts[_dayKey(weekStart.add(Duration(days: index)))] ?? 0,
    );
    // 月份格子墙要按周对齐，所以带上这个月 1 号是周几（1=周一…7=周日）。
    final monthStart = DateTime(now.year, now.month);
    final monthLength = DateTime(now.year, now.month + 1, 0).day;
    final monthDays = List<int>.generate(
      monthLength,
      (index) =>
          dayCounts[_dayKey(DateTime(now.year, now.month, index + 1))] ?? 0,
    );
    final pinnedNote = _firstPinnedNote(visibleNotes);

    return <String, Object?>{
      'schemaVersion': 2,
      'generatedAt': now.toIso8601String(),
      'today': <String, Object?>{
        'notes': todayNotes.length,
        'words': todayWords,
        'tags': todayNotes.expand((note) => note.tags).toSet().length,
        'pendingTodos': pendingTodos,
      },
      'sync': <String, Object?>{
        'mode': isLocalMode
            ? 'local'
            : isLoggedIn
                ? 'memos'
                : 'local',
        'status': isSyncing ? 'syncing' : 'idle',
        'message': syncMessage,
        'unsyncedCount': unsyncedCount,
      },
      'quickTags': quickTags.take(5).toList(),
      'reviewConfig': <String, Object?>{
        'refreshIntervalMinutes': reviewRefreshIntervalMinutes.clamp(15, 1440),
        'rangeDays': reviewRangeDays < 0 ? 0 : reviewRangeDays,
      },
      'reviewNotes': reviewNotes.map(_noteSnapshot).toList(),
      'stats': <String, Object?>{
        'week': <String, Object?>{
          'days': weekDays,
          'total': weekDays.fold<int>(0, (sum, count) => sum + count),
          'todayIndex': todayStart.weekday - 1,
        },
        'month': <String, Object?>{
          'days': monthDays,
          'total': monthDays.fold<int>(0, (sum, count) => sum + count),
          // 月格子墙是顺序铺的，今天的格子就是「几号 - 1」，原生那边直接描边。
          'todayIndex': now.day - 1,
          'firstWeekday': monthStart.weekday,
        },
      },
      'pinnedNote': pinnedNote == null ? null : _noteSnapshot(pinnedNote),
      'privacyMode': false,
    };
  }

  static List<Note> _pickReviewNotes(
    List<Note> notes, {
    required int reviewRangeDays,
  }) {
    return RandomReviewSelectorService.selectWidgetCandidates(
      notes: notes,
      reviewDays: reviewRangeDays == 0
          ? RandomReviewSelectorService.allDays
          : reviewRangeDays,
      random: Random(),
    );
  }

  static Note? _firstPinnedNote(List<Note> notes) {
    for (final note in notes) {
      if (note.isPinned) {
        return note;
      }
    }
    return null;
  }

  /// 统计格子的分组键（yyyy-MM-dd）。
  static String _dayKey(DateTime day) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${day.year}-${two(day.month)}-${two(day.day)}';
  }

  static bool _isWidgetVisibleNote(Note note) {
    final status = note.rowStatus.trim().toUpperCase();
    return status.isEmpty ||
        status == 'NORMAL' ||
        status == 'ROW_STATUS_UNSPECIFIED' ||
        status == 'STATE_UNSPECIFIED';
  }

  static Map<String, Object?> _noteSnapshot(Note note) {
    final visibleText =
        MemosContentHelper.previewVisibleText(note.content).trim();
    final preview = visibleText.isNotEmpty
        ? _trimPreview(visibleText, 120)
        : _attachmentPreview(note);
    return <String, Object?>{
      'id': note.id,
      'preview': preview,
      // 4×4 大尺寸（置顶 / 回顾）用更长的一段，120 字在 4×4 里只够铺两行。
      'previewLong':
          visibleText.isNotEmpty ? _trimPreview(visibleText, 400) : preview,
      'tags': note.tags.take(3).toList(),
      'createdAt': note.createdAt.toIso8601String(),
      // 桌面小部件直接展示这个本地时间文案。格式化放在 Dart 侧做：
      // 原生只裁剪 ISO 字符串，一旦序列化成 UTC 就会显示错时区。
      'createdAtLabel': formatWidgetTime(note.createdAt),
      // 回顾小组件顶部的「时间语境」标签（今天 / 昨天 / 去年今日…）。
      // 说清「多久以前」比裸时间戳更能唤起回忆，对应 flomo 桌面组件的
      // 「去年今日」那一层标注。
      'ageLabel': formatReviewAgeLabel(note.createdAt),
      'updatedAt': note.updatedAt.toIso8601String(),
      'displayTime': note.displayTime.toIso8601String(),
    };
  }

  static String _attachmentPreview(Note note) {
    if (MemosContentHelper.extractNoteImagePaths(note).isNotEmpty) {
      return '这是一条含图片的笔记';
    }
    if (note.resourceList.isNotEmpty) {
      return '这是一条含附件的笔记';
    }
    return _trimPreview(note.content.trim(), 120);
  }

  static int _wordCount(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return 0;
    }
    final cjkCount = RegExp('[\u4e00-\u9fff]').allMatches(trimmed).length;
    final latinCount = RegExp('[A-Za-z0-9]+').allMatches(trimmed).length;
    return cjkCount + latinCount;
  }

  /// 小部件展示用的本地时间文案（yyyy-MM-dd HH:mm）。
  static String formatWidgetTime(DateTime time) {
    // 按字段值直接格式化，不 toLocal —— Memos 的 createdAt 是「本地挂钟时间
    // 被标成 UTC」，字段值等于发布者的本地时间，再转一次时区只会多 8 小时。
    // 口径与首页卡片、详情页的 formatNoteTimestamp 保持一致。
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}';
  }

  static String _trimPreview(String text, int maxLength) {
    final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.length <= maxLength) {
      return normalized;
    }
    return '${normalized.substring(0, maxLength).trimRight()}...';
  }

  /// 回顾小组件顶部的「时间语境」标签。
  ///
  /// 回顾类组件最关键的一层信息不是精确时间，而是「这条来自多久以前」：
  /// 今天 / 昨天 / 3 天前 / 上周 / 去年今日 / 2 年前的今天 / 3 个月前 / 2025 年 6 月。
  /// 周年是最有触动的一类，单独给说法。
  ///
  /// [now] 只给测试用；生产走当前时间。和 [formatWidgetTime] 一样按字段值
  /// 比较，不做时区换算。
  static String formatReviewAgeLabel(DateTime time, {DateTime? now}) {
    final current = now ?? DateTime.now();
    // 只比日期不看时分：同一天写的都算「今天」。
    final day = DateTime(time.year, time.month, time.day);
    final today = DateTime(current.year, current.month, current.day);
    final days = today.difference(day).inDays;

    if (days <= 0) {
      // 伪 UTC 的历史数据可能落在「未来」，负值一并按今天处理。
      final minutes = current.difference(time).inMinutes;
      if (minutes >= 0 && minutes < 60) {
        return '刚刚';
      }
      if (minutes >= 60 && minutes < 24 * 60) {
        return '${minutes ~/ 60} 小时前';
      }
      return '今天';
    }
    if (days == 1) {
      return '昨天';
    }
    // 周年优先于「N 天前」：去年今日 ≈ 365 天，不会被前面的分支吃掉，
    // 但这里放在日期分支之前，语义更直白。
    if (time.month == current.month && time.day == current.day) {
      final years = current.year - time.year;
      return years <= 1 ? '去年今日' : '$years 年前的今天';
    }
    if (days < 7) {
      return '$days 天前';
    }
    if (days < 14) {
      return '上周';
    }
    if (days < 30) {
      return '${days ~/ 7} 周前';
    }
    if (days < 365) {
      final months = days ~/ 30;
      return months <= 1 ? '上个月' : '$months 个月前';
    }
    final years = current.year - time.year;
    if (years <= 1) {
      return '去年';
    }
    // 跨年太久的不再说「N 年前」，直接给年月更有信息量。
    return years >= 3 ? '${time.year} 年 ${time.month} 月' : '$years 年前';
  }
}
