import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:inkpaper/models/app_config_model.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/services/deepseek_api_service.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 回顾周期。
///
/// 用"最近 7 天 / 最近 30 天"的滚动窗口，而不是自然周 / 自然月：
/// 站内「本周 / 本月」的既有语义就是滚动窗口（见通知分组），自然周会让
/// 周一凌晨的笔记突然"掉出本周"，用户很难理解。
enum ReviewPeriod { week, month }

/// 一个自然周或自然月的区间（左闭右开）。
class ReviewRange {
  const ReviewRange({required this.start, required this.end});

  /// [offset] 为周期偏移：0 是本期，-1 是紧邻的上一期（用于环比）。
  ///
  /// 本期窗口是「含今天的最近 7 / 30 天」，上一期紧贴在它前面，互不重叠。
  factory ReviewRange.of(
    ReviewPeriod period, {
    DateTime? now,
    int offset = 0,
  }) {
    final today = now ?? DateTime.now();
    final days = period == ReviewPeriod.week ? 7 : 30;
    // 明天 0 点作为右边界，保证"今天"整天都算进来
    final todayEnd = DateTime(today.year, today.month, today.day + 1);
    final end = DateTime(
      todayEnd.year,
      todayEnd.month,
      todayEnd.day + offset * days,
    );
    final start = DateTime(end.year, end.month, end.day - days);
    return ReviewRange(start: start, end: end);
  }

  final DateTime start;

  /// 不含当天（周回顾到今天 24:00，月回顾到次月 1 日 0 点）。
  final DateTime end;

  bool contains(DateTime time) => !time.isBefore(start) && time.isBefore(end);

  int get days => end.difference(start).inDays;

  /// 形如 `10.20 - 10.26` 的展示文案。
  String get shortLabel {
    final formatter = DateFormat('MM.dd');
    final lastDay = end.subtract(const Duration(days: 1));
    return '${formatter.format(start)} - ${formatter.format(lastDay)}';
  }
}

/// 某个周期内的笔记统计。
class ReviewStats {
  const ReviewStats({
    required this.noteCount,
    required this.activeDays,
    required this.charCount,
    required this.tagCounts,
    required this.previousNoteCount,
    required this.previousActiveDays,
  });

  final int noteCount;
  final int activeDays;
  final int charCount;

  /// 展开后的标签计数（按次数降序，已裁剪到前若干个）。
  final List<MapEntry<String, int>> tagCounts;

  final int previousNoteCount;
  final int previousActiveDays;

  bool get isEmpty => noteCount == 0;

  int get noteDelta => noteCount - previousNoteCount;

  int get activeDayDelta => activeDays - previousActiveDays;
}

/// 生成结果。
class PeriodicReviewResult {
  const PeriodicReviewResult({
    required this.range,
    required this.stats,
    required this.content,
    required this.usedRemote,
    this.remoteError,
    this.fromCache = false,
  });

  final ReviewRange range;
  final ReviewStats stats;
  final String content;

  /// 内容是否来自远程 AI（false 表示只有本地统计）。
  final bool usedRemote;

  /// 远程调用失败原因（此时 content 是本地降级统计）。
  final String? remoteError;

  final bool fromCache;
}

/// 周回顾 / 月回顾：统计 + AI 总结。
///
/// 设计要点：
/// - 只用「本期笔记片段 + 标签统计」喂给模型，不塞全库，控制 token；
/// - 没配 AI 时降级成本地统计摘要，功能不至于完全不可用；
/// - 结果按周期缓存，当前周期的笔记条数变了才失效。
class PeriodicReviewService {
  static const String _cachePrefix = 'periodic_review_v1_';

  /// 送给模型的笔记条数上限与单条截断长度。
  static const int _maxPromptNotes = 40;
  static const int _maxNoteChars = 180;

  /// 统计时展示的标签数量上限。
  static const int _maxTags = 12;

  Future<PeriodicReviewResult> generate({
    required AppConfig config,
    required List<Note> allNotes,
    required ReviewPeriod period,
    bool forceRefresh = false,
  }) async {
    final range = ReviewRange.of(period);
    final previousRange = ReviewRange.of(period, offset: -1);
    final periodNotes = _notesIn(allNotes, range);
    final previousNotes = _notesIn(allNotes, previousRange);
    final stats = _buildStats(periodNotes, previousNotes);

    if (stats.isEmpty) {
      return PeriodicReviewResult(
        range: range,
        stats: stats,
        content: '',
        usedRemote: false,
      );
    }

    // 提示词变了也要让旧结果失效，否则用户改完 Prompt 仍看到老总结
    final cacheKey = _cacheKeyFor(period, range, _promptSignature(period, config));

    if (!forceRefresh) {
      final cached = await _readCache(cacheKey, stats.noteCount);
      if (cached != null) {
        return PeriodicReviewResult(
          range: range,
          stats: stats,
          content: cached.$1,
          usedRemote: cached.$2,
          fromCache: true,
        );
      }
    }

    final fallback = _buildLocalSummary(period, range, stats);
    final canUseAi = config.aiEnabled &&
        (config.aiApiUrl?.trim().isNotEmpty ?? false) &&
        (config.aiApiKey?.trim().isNotEmpty ?? false);

    if (!canUseAi) {
      return PeriodicReviewResult(
        range: range,
        stats: stats,
        content: fallback,
        usedRemote: false,
      );
    }

    try {
      final service = DeepSeekApiService(
        apiUrl: config.aiApiUrl!.trim(),
        apiKey: config.aiApiKey!.trim(),
        model: config.aiModel,
      );
      final messages = <Map<String, String>>[
        DeepSeekApiService.buildSystemMessage(_systemPrompt(period, config)),
        DeepSeekApiService.buildUserMessage(
          _userPrompt(period, range, stats, periodNotes),
        ),
      ];
      final (content, error) = await service.chat(
        messages: messages,
        temperature: 0.6,
        maxTokens: 900,
      );

      if (content == null || content.trim().isEmpty) {
        return PeriodicReviewResult(
          range: range,
          stats: stats,
          content: fallback,
          usedRemote: false,
          remoteError: error ?? 'AI 返回内容为空',
        );
      }

      final cleaned = _cleanMarkdown(content);
      await _writeCache(cacheKey, cleaned, stats.noteCount);
      return PeriodicReviewResult(
        range: range,
        stats: stats,
        content: cleaned,
        usedRemote: true,
      );
    } on Object catch (e) {
      debugPrint('PeriodicReview: AI 生成失败: $e');
      return PeriodicReviewResult(
        range: range,
        stats: stats,
        content: fallback,
        usedRemote: false,
        remoteError: e.toString(),
      );
    }
  }

  /// 清掉本期缓存，强制下次重新生成。
  ///
  /// 缓存键里带了提示词指纹，所以按前缀删，避免漏掉换过提示词的那几份。
  Future<void> invalidate(ReviewPeriod period, {DateTime? now}) async {
    final prefs = await SharedPreferences.getInstance();
    final prefix = '$_cachePrefix${period.name}_';
    final stamp = _stampOf(ReviewRange.of(period, now: now).start);
    final keys = prefs.getKeys().where((key) => key.startsWith('$prefix$stamp'));
    for (final key in keys.toList()) {
      await prefs.remove(key);
    }
  }

  List<Note> _notesIn(List<Note> notes, ReviewRange range) {
    final result = notes
        .where(
          (note) =>
              note.content.trim().isNotEmpty &&
              range.contains(note.displayTime),
        )
        .toList()
      ..sort((a, b) => a.displayTime.compareTo(b.displayTime));
    return result;
  }

  ReviewStats _buildStats(List<Note> periodNotes, List<Note> previousNotes) {
    final counts = <String, int>{};
    var charCount = 0;
    final activeDayKeys = <String>{};
    final previousDayKeys = <String>{};

    for (final note in periodNotes) {
      charCount += note.content.trim().length;
      activeDayKeys.add(_dayKey(note.displayTime));
      for (final tag in note.tags) {
        final normalized = tag.trim();
        if (normalized.isEmpty) {
          continue;
        }
        counts[normalized] = (counts[normalized] ?? 0) + 1;
      }
    }

    for (final note in previousNotes) {
      previousDayKeys.add(_dayKey(note.displayTime));
    }

    final sortedTags = counts.entries.toList()
      ..sort((a, b) {
        final byCount = b.value.compareTo(a.value);
        return byCount != 0 ? byCount : a.key.compareTo(b.key);
      });

    return ReviewStats(
      noteCount: periodNotes.length,
      activeDays: activeDayKeys.length,
      charCount: charCount,
      tagCounts: sortedTags.take(_maxTags).toList(growable: false),
      previousNoteCount: previousNotes.length,
      previousActiveDays: previousDayKeys.length,
    );
  }

  String _dayKey(DateTime time) =>
      '${time.year}-${time.month.toString().padLeft(2, '0')}-'
      '${time.day.toString().padLeft(2, '0')}';

  /// 没配 AI（或调用失败）时的降级内容：只做统计，不做创造性总结。
  String _buildLocalSummary(
    ReviewPeriod period,
    ReviewRange range,
    ReviewStats stats,
  ) {
    final unit = period == ReviewPeriod.week ? '最近 7 天' : '最近 30 天';
    final buffer = StringBuffer()
      ..writeln('$unit（${range.shortLabel}）共记录 ${stats.noteCount} 条，'
          '活跃 ${stats.activeDays} 天，约 ${stats.charCount} 字。');

    if (stats.tagCounts.isNotEmpty) {
      final tagText = stats.tagCounts
          .take(6)
          .map((entry) => '#${entry.key} ×${entry.value}')
          .join('、');
      buffer.writeln('关注点：$tagText。');
    }

    final delta = stats.noteDelta;
    if (stats.previousNoteCount > 0) {
      final compare = delta > 0
          ? '比上一周期多 $delta 条'
          : delta < 0
              ? '比上一周期少 ${-delta} 条'
              : '与上一周期条数持平';
      buffer.writeln('$compare，活跃天数 ${stats.activeDays} 天。');
    }

    buffer.writeln('（未启用 AI 总结，以上为本地统计。配置 AI 后可生成文字回顾。）');
    return buffer.toString().trim();
  }

  String _systemPrompt(ReviewPeriod period, AppConfig config) {
    final custom = _customPrompt(config);
    if (custom != null) {
      // 自定义提示词只负责"写成什么样"，输出格式的硬性要求仍由这里兜住，
      // 否则用户随手写的 Prompt 很容易让模型输出 Markdown 或寒暄。
      return '$custom\n\n'
          '额外硬性要求：只用中文，纯文本分段，不要 Markdown 标题、列表符号或代码块；'
          '只基于给出的笔记内容，不要编造笔记里没有的事实；'
          '直接输出回顾正文，不要"好的""以下是"之类的开场白。';
    }

    final unit = period == ReviewPeriod.week ? '7 天' : '30 天';
    return '''
你是一位懂知识管理的写作教练，擅长从零散笔记里看出一个人的思考轨迹。

用户会给你他在最近$unit里的一部分笔记片段、标签统计和环比数据。请写一份「回顾」。

写作要求：
1. 只用中文，纯文本分段，不要 Markdown 标题、列表符号、表格或代码块；
2. 内容依次包含：这段时间的主题脉络（2-3 句）；从标签和内容里浮现的关注点（2-4 个，自然叙述而不是罗列）；一条值得继续深挖的线索（1-2 句）；一句温和的提醒或提问（1 句）；
3. 必须基于给出的笔记内容，不要编造笔记里没有的事实；信息不足时宁可写得简洁；
4. 语气克制、具体，不要空泛鼓励，不要"首先/其次/最后"的模板腔；
5. 全文 220~320 字，直接输出回顾正文，不要"好的""以下是"之类的开场白。
''';
  }

  String _userPrompt(
    ReviewPeriod period,
    ReviewRange range,
    ReviewStats stats,
    List<Note> periodNotes,
  ) {
    final unit = period == ReviewPeriod.week ? '最近 7 天' : '最近 30 天';
    final buffer = StringBuffer()
      ..writeln('周期：${range.start.year}年${range.shortLabel}（$unit，共 ${range.days} 天）')
      ..writeln('笔记 ${stats.noteCount} 条，活跃 ${stats.activeDays} 天，'
          '约 ${stats.charCount} 字。')
      ..writeln('环比：上一周期 ${stats.previousNoteCount} 条 / '
          '活跃 ${stats.previousActiveDays} 天，本期 ${stats.noteDelta >= 0 ? '+' : ''}${stats.noteDelta} 条。');

    if (stats.tagCounts.isNotEmpty) {
      final tagText = stats.tagCounts
          .map((entry) => '#${entry.key}(${entry.value})')
          .join('、');
      buffer.writeln('标签统计：$tagText');
    }

    buffer.writeln('\n笔记片段：');
    final shown = periodNotes.length > _maxPromptNotes
        ? periodNotes.sublist(periodNotes.length - _maxPromptNotes)
        : periodNotes;
    for (var i = 0; i < shown.length; i++) {
      final note = shown[i];
      final text = note.content.trim().replaceAll(RegExp(r'\s+'), ' ');
      final truncated = text.length > _maxNoteChars
          ? '${text.substring(0, _maxNoteChars)}…'
          : text;
      final date = DateFormat('MM-dd').format(note.displayTime);
      buffer.writeln('${i + 1}. [$date] $truncated');
    }

    return buffer.toString().trim();
  }

  /// 模型偶尔还是会带 Markdown 标记，这里做一次轻量清理。
  String _cleanMarkdown(String text) {
    var result = text.trim();
    result = result.replaceAll(RegExp(r'^```[a-zA-Z]*\n?', multiLine: true), '');
    result = result.replaceAll(RegExp(r'\n?```$'), '');
    result = result.replaceAll(RegExp(r'^#{1,6}\s*', multiLine: true), '');
    result = result.replaceAll(RegExp(r'\*\*(.+?)\*\*'), r'$1');
    result = result.replaceAll(RegExp(r'^\s*[-*]\s+', multiLine: true), '');
    return result.trim();
  }

  /// 用户在设置里配置的回顾提示词（未启用自定义或留空时为 null）。
  String? _customPrompt(AppConfig config) {
    if (!config.useCustomPrompt) {
      return null;
    }
    final prompt = config.customPeriodicReviewPrompt?.trim();
    if (prompt == null || prompt.isEmpty) {
      return null;
    }
    return prompt;
  }

  /// 提示词指纹：进缓存键，保证改完 Prompt 立刻重新生成。
  String _promptSignature(ReviewPeriod period, AppConfig config) {
    final custom = _customPrompt(config);
    return (custom ?? 'default_${period.name}').hashCode.toRadixString(16);
  }

  String _stampOf(DateTime start) => '${start.year}'
      '${start.month.toString().padLeft(2, '0')}'
      '${start.day.toString().padLeft(2, '0')}';

  String _cacheKeyFor(
    ReviewPeriod period,
    ReviewRange range,
    String signature,
  ) =>
      '$_cachePrefix${period.name}_${_stampOf(range.start)}_$signature';

  Future<(String, bool)?> _readCache(String key, int noteCount) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(key);
      if (raw == null) {
        return null;
      }
      final data = jsonDecode(raw) as Map<String, dynamic>;
      // 当前周期可能还在继续写，笔记条数变了就重算
      if ((data['noteCount'] as num?)?.toInt() != noteCount) {
        return null;
      }
      final content = data['content'] as String?;
      if (content == null || content.trim().isEmpty) {
        return null;
      }
      return (content, data['usedRemote'] == true);
    } on Object {
      return null;
    }
  }

  Future<void> _writeCache(String key, String content, int noteCount) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        key,
        jsonEncode({
          'content': content,
          'usedRemote': true,
          'noteCount': noteCount,
          'savedAt': DateTime.now().millisecondsSinceEpoch,
        }),
      );
    } on Object catch (e) {
      debugPrint('PeriodicReview: 缓存写入失败: $e');
    }
  }
}
