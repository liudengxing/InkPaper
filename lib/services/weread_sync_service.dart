import 'dart:async';
import 'dart:convert';

import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/models/weread_models.dart';
import 'package:inkpaper/services/database_service.dart';
import 'package:inkpaper/services/preferences_service.dart';
import 'package:inkpaper/services/weread_api_service.dart';
import 'package:inkpaper/services/weread_note_builder.dart';
import 'package:inkpaper/utils/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 同步阶段。UI 用它区分「正在拉划线」和「正在整理读完档案」。
enum WeReadSyncPhase {
  /// 拉每本书的划线与想法。
  notes,

  /// 逐本查阅读进度，给读完的书建档案笔记。
  finished,

  /// 拉上一周 / 上个月的阅读统计，生成回顾笔记。
  periodReview,
}

/// 同步进度（界面用它画「正在拉取《xxx》3/12」）。
class WeReadSyncProgress {
  const WeReadSyncProgress({
    required this.booksDone,
    required this.booksTotal,
    this.currentBookTitle,
    this.phase = WeReadSyncPhase.notes,
  });

  final int booksDone;
  final int booksTotal;
  final String? currentBookTitle;
  final WeReadSyncPhase phase;

  double get ratio => booksTotal <= 0 ? 0 : booksDone / booksTotal;
}

/// 单本书的同步水位，用于增量。
///
/// `sort` 是服务端「最近一条笔记时间」，`total` 是统计口径的总笔记数。两者
/// 都没变就说明这本书在微信读书侧没有任何增删，整本跳过 —— 这是省请求的主
/// 要手段：有笔记的书动辄几十本，每本两个接口，全量拉一遍很慢。
class _BookWatermark {
  const _BookWatermark({
    required this.sort,
    required this.total,
    required this.syncedAt,
  });

  factory _BookWatermark.fromJson(Map<String, dynamic> json) => _BookWatermark(
        sort: _asInt(json['sort']),
        total: _asInt(json['total']),
        syncedAt: _asInt(json['at']),
      );

  final int sort;
  final int total;
  final int syncedAt;

  Map<String, dynamic> toJson() =>
      {'sort': sort, 'total': total, 'at': syncedAt};

  bool matches(WeReadNotebook notebook) =>
      sort == notebook.sort && total == notebook.totalNotes;
}

/// 宽松取整数：网关回包里同一字段可能给 int、num 或字符串。
int _asInt(Object? value) {
  if (value == null) {
    return 0;
  }
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.round();
  }
  return int.tryParse(value.toString().trim()) ?? 0;
}

/// 读完档案的候选书。
class _FinishedCandidate {
  const _FinishedCandidate({
    required this.bookId,
    required this.title,
    required this.author,
    this.cover,
    this.highlightCount = 0,
    this.reviewCount = 0,
    this.version = 0,
  });

  final String bookId;
  final String title;
  final String author;
  final String? cover;
  final int highlightCount;
  final int reviewCount;

  /// 元信息版本（笔记本用 sort，书架用 readUpdateTime）。用它判断
  /// 「查过且确认没读完」的书要不要重新查。
  final int version;
}

/// 读完档案一轮的结果。
class _FinishedOutcome {
  const _FinishedOutcome({
    required this.notes,
    required this.probed,
    required this.missed,
  });

  final List<Note> notes;

  /// 真正查了阅读进度的书数。
  final int probed;

  /// 「查过但服务端没有 finishTime」的书 → 版本号，下一轮同版本不再查。
  final Map<String, int> missed;
}

/// 一轮「阅读回顾」的结果：待写入的笔记 + 推进后的水位。
class _PeriodOutcome {
  const _PeriodOutcome({required this.notes, this.week, this.month});

  final List<Note> notes;

  /// 已处理到的最新周（`YYYY-MM-DD`，周一），null 表示还没处理过。
  final String? week;

  /// 已处理到的最新月（`YYYY-MM`），null 表示还没处理过。
  final String? month;
}

/// 微信读书 → InkPaper 的笔记同步。
///
/// 幂等靠两条：① 笔记 id 由 bookmarkId / reviewId 确定性生成；② 写库前用
/// 一次 IN 查询把「库里已经存在」的 id 全剔掉（**含软删行**，所以用户删掉的
/// 笔记不会被下一次同步复活）。因此即使同步水位被清空、或用户手动重跑，
/// 也不会产生重复笔记。
class WeReadSyncService {
  WeReadSyncService({
    WeReadApiService? api,
    DatabaseService? database,
    PreferencesService? preferences,
    this.builder = const WeReadNoteBuilder(),
  })  : _api = api ?? WeReadApiService(),
        _database = database ?? DatabaseService(),
        _preferences = preferences ?? PreferencesService();

  /// 自动同步的最小间隔。开屏检查、退到后台再回来都很频繁，6 小时足够。
  static const Duration autoSyncInterval = Duration(hours: 6);

  static const String _prefKeyState = 'weread_sync_state';
  static const String _prefKeyAutoSync = 'weread_auto_sync';
  static const String _prefKeyLastImported = 'weread_last_imported';
  static const String _prefKeyLastFinished = 'weread_last_finished';
  static const String _prefKeyFinished = 'weread_sync_finished';
  static const String _prefKeyPeriodReview = 'weread_period_review';

  final WeReadApiService _api;
  final DatabaseService _database;
  final PreferencesService _preferences;
  final WeReadNoteBuilder builder;

  final Logger _logger = const Logger('WeReadSync');

  bool _running = false;

  bool get isRunning => _running;

  /// 是否开启「开 App 时自动同步」，默认开启。
  Future<bool> isAutoSyncEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_prefKeyAutoSync) ?? true;
  }

  Future<void> setAutoSyncEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefKeyAutoSync, enabled);
  }

  /// 是否同步「读完档案」（一本书一条，记录读完时间与阅读天数），默认开启。
  Future<bool> isFinishedSyncEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_prefKeyFinished) ?? true;
  }

  Future<void> setFinishedSyncEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefKeyFinished, enabled);
  }

  /// 是否同步「每周 / 每月阅读回顾」（一周、一月各一条），默认开启。
  Future<bool> isPeriodReviewEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_prefKeyPeriodReview) ?? true;
  }

  Future<void> setPeriodReviewEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefKeyPeriodReview, enabled);
  }

  Future<String?> getApiKey() => _preferences.getWeReadApiKey();

  Future<void> saveApiKey(String apiKey) =>
      _preferences.saveWeReadApiKey(apiKey);

  /// 上次成功同步的时间，null 表示从没同步过。
  Future<DateTime?> lastSyncAt() async {
    final state = await _readState();
    final raw = _asInt(state['lastSyncAt']);
    if (raw <= 0) {
      return null;
    }
    return DateTime.fromMillisecondsSinceEpoch(raw);
  }

  /// 上次同步新增了多少条。
  Future<int> lastImportedCount() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_prefKeyLastImported) ?? 0;
  }

  /// 上次同步新增了多少本读完档案。
  Future<int> lastFinishedCount() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_prefKeyLastFinished) ?? 0;
  }

  /// 已记录的「有笔记的书」数量，用于界面展示覆盖范围。
  Future<int> trackedBookCount() async {
    final state = await _readState();
    final books = state['books'];
    return books is Map ? books.length : 0;
  }

  /// 距上次同步是否已经超过 [autoSyncInterval]。
  Future<bool> isAutoSyncDue() async {
    final last = await lastSyncAt();
    if (last == null) {
      return true;
    }
    return DateTime.now().difference(last) >= autoSyncInterval;
  }

  /// 清空同步水位与统计（不会删除已导入的笔记）。下次同步会重新全量比对。
  Future<void> resetSyncState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefKeyState);
    await prefs.remove(_prefKeyLastImported);
    await prefs.remove(_prefKeyLastFinished);
  }

  /// 校验 API Key：能拉到笔记本列表即有效。返回「有笔记的书」数量。
  Future<int> verifyApiKey(String apiKey) async {
    final api = WeReadApiService(apiKey: apiKey.trim());
    try {
      final notebooks = await api.fetchNotebooks(pageSize: 50, maxPages: 1);
      return notebooks.length;
    } finally {
      api.dispose();
    }
  }

  /// 跑一轮同步。
  ///
  /// [persist] 负责真正落库（走 AppProvider 才能同步刷新内存列表与总数），
  /// 服务只决定「哪些笔记要写」。这样服务可以脱离 Flutter 依赖做单元测试。
  Future<WeReadSyncResult> sync({
    required Future<void> Function(List<Note> notes) persist,
    void Function(WeReadSyncProgress progress)? onProgress,
  }) async {
    if (_running) {
      throw const WeReadApiException('同步正在进行中');
    }

    final apiKey = (await getApiKey())?.trim() ?? '';
    if (apiKey.isEmpty) {
      throw const WeReadApiException('还没有填写微信读书 API Key');
    }

    _running = true;
    final state = await _readState();
    final watermarks = _readWatermarks(state);
    final finishedMiss = _readFinishedMiss(state);
    final previousPeriods = _readPeriods(state);
    final now = DateTime.now();

    _api.apiKey = apiKey;

    try {
      final notebooks = await _api.fetchNotebooks();

      final candidates = <Note>[];
      final failures = <String>[];
      var booksFetched = 0;
      var booksSkipped = 0;

      for (var index = 0; index < notebooks.length; index++) {
        final notebook = notebooks[index];
        final previous = watermarks[notebook.bookId];

        onProgress?.call(
          WeReadSyncProgress(
            booksDone: index,
            booksTotal: notebooks.length,
            currentBookTitle: notebook.title,
          ),
        );

        if (previous != null && previous.matches(notebook)) {
          booksSkipped++;
          continue;
        }

        try {
          final notes = await _buildNotesFor(notebook);
          candidates.addAll(notes);
          booksFetched++;
          // 只有成功拉到明细才推进水位，失败的书下一轮会重试。
          watermarks[notebook.bookId] = _BookWatermark(
            sort: notebook.sort,
            total: notebook.totalNotes,
            syncedAt: now.millisecondsSinceEpoch,
          );
        } on WeReadUpgradeRequiredException {
          rethrow;
        } on Object catch (error) {
          final title =
              notebook.title.isEmpty ? notebook.bookId : notebook.title;
          failures.add('《$title》$error');
          _logger.warning('单本同步失败', data: {'book': title, 'error': '$error'});
        }
      }

      onProgress?.call(
        WeReadSyncProgress(
          booksDone: notebooks.length,
          booksTotal: notebooks.length,
        ),
      );

      // 第二阶段：读完档案。失败不影响划线结果，所以整体包一层。
      var finishedProbed = 0;
      var finishedMissed = <String, int>{};
      if (await isFinishedSyncEnabled()) {
        final outcome = await _syncFinishedBooks(
          notebooks: notebooks,
          previousMiss: finishedMiss,
          onProgress: onProgress,
          failures: failures,
        );
        candidates.addAll(outcome.notes);
        finishedProbed = outcome.probed;
        // 本轮查过但没读完的覆盖旧记录；本轮没查的保留旧记录（下次元信息
        // 变了自然会重新进候选）。
        finishedMissed = {...finishedMiss, ...outcome.missed};
      }

      // 第三阶段：每周 / 每月阅读回顾。统计接口失败只影响这一条，不回滚前面。
      var periods = previousPeriods;
      if (await isPeriodReviewEnabled()) {
        final outcome = await _syncPeriodReports(
          previous: previousPeriods,
          failures: failures,
          onProgress: onProgress,
        );
        candidates.addAll(outcome.notes);
        periods = {
          ...previousPeriods,
          if (outcome.week != null) 'week': outcome.week!,
          if (outcome.month != null) 'month': outcome.month!,
        };
      }

      final fresh = await _filterUnimported(candidates);
      final skippedDuplicates = candidates.length - fresh.length;
      if (fresh.isNotEmpty) {
        await persist(fresh);
      }

      await _saveState(
        watermarks: watermarks,
        finishedMiss: finishedMissed,
        periods: periods,
        lastSyncAt: now,
      );
      final finishedImported = fresh
          .where(
            (note) => note.id.startsWith(WeReadNoteBuilder.finishedIdPrefix),
          )
          .length;
      final periodImported = fresh
          .where(
            (note) =>
                note.id.startsWith(WeReadNoteBuilder.weeklyIdPrefix) ||
                note.id.startsWith(WeReadNoteBuilder.monthlyIdPrefix),
          )
          .length;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_prefKeyLastImported, fresh.length);
      await prefs.setInt(_prefKeyLastFinished, finishedImported);

      final result = WeReadSyncResult(
        imported: fresh.length,
        booksFetched: booksFetched,
        booksSkipped: booksSkipped,
        booksTotal: notebooks.length,
        skippedDuplicates: skippedDuplicates,
        finishedCandidates: finishedProbed,
        finishedImported: finishedImported,
        periodImported: periodImported,
        failures: failures,
      );
      _logger.info(
        '同步完成',
        data: {
          'imported': result.imported,
          'fetched': booksFetched,
          'skipped': booksSkipped,
          'finishedProbed': finishedProbed,
          'finishedImported': result.finishedImported,
          'periodImported': periodImported,
          'failures': failures.length,
        },
      );
      return result;
    } finally {
      _running = false;
    }
  }

  /// 开屏自动同步：开关关闭、还没配 Key、没到间隔都直接跳过。
  ///
  /// 任何异常都吞掉并记日志 —— 开屏路径不允许因为一个实验功能把用户体验带崩。
  Future<WeReadSyncResult?> autoSyncIfDue({
    required Future<void> Function(List<Note> notes) persist,
  }) async {
    try {
      if (!await isAutoSyncEnabled()) {
        return null;
      }
      final apiKey = await getApiKey();
      if (apiKey == null || apiKey.trim().isEmpty) {
        return null;
      }
      if (!await isAutoSyncDue()) {
        return null;
      }
      if (_running) {
        return null;
      }
      return await sync(persist: persist);
    } on Object catch (error) {
      _logger.warning('开屏自动同步跳过', data: {'error': '$error'});
      return null;
    }
  }

  /// 每周 / 每月阅读回顾：拉上一个已结束的自然周与自然月的统计，各建一条笔记。
  ///
  /// 触发时机不绑死「周一 0 点」，而是「这个周期结束后第一次同步」——用户
  /// 周一没开 App，周三打开照样补上上周的回顾。断档多期时最多回溯 6 周 /
  /// 3 个月，更早的不再补，避免一次同步打十几个统计请求。
  ///
  /// 阅读时长为 0 的周期不建笔记，但水位照常前进，下次不再重复查。
  Future<_PeriodOutcome> _syncPeriodReports({
    required Map<String, String> previous,
    required List<String> failures,
    void Function(WeReadSyncProgress progress)? onProgress,
  }) async {
    final now = DateTime.now();
    final weekStarts = _pendingPeriods(
      latest: _startOfWeek(now).subtract(const Duration(days: 7)),
      lastProcessed: _parseDayKey(previous['week']),
      next: (start) => DateTime(start.year, start.month, start.day + 7),
      maxBacklog: 6,
    );
    final monthStarts = _pendingPeriods(
      latest: DateTime(now.year, now.month - 1),
      lastProcessed: _parseMonthKey(previous['month']),
      next: (start) => DateTime(start.year, start.month + 1),
      maxBacklog: 3,
    );
    if (weekStarts.isEmpty && monthStarts.isEmpty) {
      return _PeriodOutcome(
        notes: const [],
        week: previous['week'],
        month: previous['month'],
      );
    }

    final existing = await existingNoteIds({
      for (final start in weekStarts) WeReadNoteBuilder.weeklyNoteId(start),
      for (final start in monthStarts) WeReadNoteBuilder.monthlyNoteId(start),
    });

    onProgress?.call(
      const WeReadSyncProgress(
        booksDone: 0,
        booksTotal: 0,
        phase: WeReadSyncPhase.periodReview,
      ),
    );

    final notes = <Note>[];
    var weekMark = previous['week'];
    var monthMark = previous['month'];

    for (final start in weekStarts) {
      if (!existing.contains(WeReadNoteBuilder.weeklyNoteId(start))) {
        try {
          final stats = await _api.fetchPeriodStats(
            mode: 'weekly',
            baseTime: start,
          );
          final note = builder.buildPeriodNote(weekly: true, stats: stats);
          if (note != null) {
            notes.add(note);
          }
        } on WeReadUpgradeRequiredException {
          rethrow;
        } on Object catch (error) {
          failures.add('阅读周报 $error');
          _logger.warning(
            '周报拉取失败',
            data: {'period': _dayKey(start), 'error': '$error'},
          );
          break;
        }
      }
      weekMark = _dayKey(start);
    }

    for (final start in monthStarts) {
      if (!existing.contains(WeReadNoteBuilder.monthlyNoteId(start))) {
        try {
          final stats = await _api.fetchPeriodStats(
            mode: 'monthly',
            baseTime: start,
          );
          final note = builder.buildPeriodNote(weekly: false, stats: stats);
          if (note != null) {
            notes.add(note);
          }
        } on WeReadUpgradeRequiredException {
          rethrow;
        } on Object catch (error) {
          failures.add('阅读月报 $error');
          _logger.warning(
            '月报拉取失败',
            data: {'period': _monthKey(start), 'error': '$error'},
          );
          break;
        }
      }
      monthMark = _monthKey(start);
    }

    _logger.info(
      '阅读回顾完成',
      data: {
        'weeks': weekStarts.length,
        'months': monthStarts.length,
        'notes': notes.length,
      },
    );
    return _PeriodOutcome(notes: notes, week: weekMark, month: monthMark);
  }

  /// 本周周一 00:00（本地时区）。服务端的 weekly 也按周一归一分桶。
  static DateTime _startOfWeek(DateTime time) {
    final day = DateTime(time.year, time.month, time.day);
    return day.subtract(Duration(days: day.weekday - 1));
  }

  /// 从上次处理到的周期往后数，返回还没处理的周期（升序）。
  ///
  /// 没有水位记录时只取最近一期——新装/重置的用户不该一次性收到半年的回顾。
  static List<DateTime> _pendingPeriods({
    required DateTime latest,
    required DateTime? lastProcessed,
    required DateTime Function(DateTime start) next,
    required int maxBacklog,
  }) {
    if (lastProcessed == null) {
      return [latest];
    }
    if (!lastProcessed.isBefore(latest)) {
      return const [];
    }
    final pending = <DateTime>[];
    var cursor = next(lastProcessed);
    while (!cursor.isAfter(latest) && pending.length < 400) {
      pending.add(cursor);
      cursor = next(cursor);
    }
    if (pending.length <= maxBacklog) {
      return pending;
    }
    return pending.sublist(pending.length - maxBacklog);
  }

  static String _dayKey(DateTime time) =>
      '${time.year}-${_two(time.month)}-${_two(time.day)}';

  static String _monthKey(DateTime time) => '${time.year}-${_two(time.month)}';

  static DateTime? _parseDayKey(String? raw) {
    final parts = (raw ?? '').split('-');
    if (parts.length != 3) {
      return null;
    }
    final year = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    final day = int.tryParse(parts[2]);
    if (year == null || month == null || day == null) {
      return null;
    }
    return DateTime(year, month, day);
  }

  static DateTime? _parseMonthKey(String? raw) {
    final parts = (raw ?? '').split('-');
    if (parts.length != 2) {
      return null;
    }
    final year = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    if (year == null || month == null) {
      return null;
    }
    return DateTime(year, month);
  }

  static String _two(int value) => value.toString().padLeft(2, '0');

  /// 读完档案阶段：候选 → 去重 → 逐本查进度 → 建笔记。
  ///
  /// 候选只挑「可能读完」的书（`markedStatus=4` 或进度顶到 99），再并上书架里
  /// `finishReading=1` 的 —— 后者补的是「一本书没划线但确实读完了」的情况。
  /// 最终是否读完只看 `/book/getprogress` 的 `finishTime`，那是唯一可靠字段。
  Future<_FinishedOutcome> _syncFinishedBooks({
    required List<WeReadNotebook> notebooks,
    required Map<String, int> previousMiss,
    required List<String> failures,
    void Function(WeReadSyncProgress progress)? onProgress,
  }) async {
    final candidates = <String, _FinishedCandidate>{};
    for (final notebook in notebooks) {
      if (!notebook.maybeFinished || notebook.bookId.isEmpty) {
        continue;
      }
      candidates[notebook.bookId] = _FinishedCandidate(
        bookId: notebook.bookId,
        title: notebook.title,
        author: notebook.author,
        cover: notebook.cover,
        highlightCount: notebook.highlightCount,
        reviewCount: notebook.reviewCount,
        version: notebook.sort,
      );
    }

    try {
      final shelf = await _api.fetchShelfBooks();
      for (final book in shelf) {
        if (!book.isFinished || candidates.containsKey(book.bookId)) {
          continue;
        }
        candidates[book.bookId] = _FinishedCandidate(
          bookId: book.bookId,
          title: book.title,
          author: book.author,
          cover: book.cover,
          version: book.readUpdateTime,
        );
      }
    } on WeReadUpgradeRequiredException {
      rethrow;
    } on Object catch (error) {
      // 书架拉不到不影响有笔记的书，只是可能漏掉没划线的读完书。
      _logger.warning('书架拉取失败', data: {'error': '$error'});
    }

    if (candidates.isEmpty) {
      return const _FinishedOutcome(notes: [], probed: 0, missed: {});
    }

    final existing = await existingNoteIds(
      candidates.keys.map(WeReadNoteBuilder.finishedNoteId).toSet(),
    );
    final pending = candidates.values.where((candidate) {
      if (existing
          .contains(WeReadNoteBuilder.finishedNoteId(candidate.bookId))) {
        return false;
      }
      final missedVersion = previousMiss[candidate.bookId];
      return missedVersion == null || missedVersion != candidate.version;
    }).toList();

    final notes = <Note>[];
    final missed = <String, int>{};

    for (var index = 0; index < pending.length; index++) {
      final candidate = pending[index];
      onProgress?.call(
        WeReadSyncProgress(
          booksDone: index,
          booksTotal: pending.length,
          currentBookTitle: candidate.title,
          phase: WeReadSyncPhase.finished,
        ),
      );

      try {
        final progress = await _api.fetchProgress(candidate.bookId);
        if (progress == null || !progress.isFinished) {
          // 记下「查过但这本没读完」，元信息不变就不再浪费请求。
          missed[candidate.bookId] = candidate.version;
          continue;
        }
        final note = builder.buildFinishedNote(
          bookId: candidate.bookId,
          title: candidate.title,
          author: candidate.author,
          coverUrl: candidate.cover,
          progress: progress,
          highlightCount: candidate.highlightCount,
          reviewCount: candidate.reviewCount,
        );
        if (note != null) {
          notes.add(note);
        }
      } on WeReadUpgradeRequiredException {
        rethrow;
      } on Object catch (error) {
        final title =
            candidate.title.isEmpty ? candidate.bookId : candidate.title;
        failures.add('《$title》读完档案：$error');
        _logger.warning('读完档案失败', data: {'book': title, 'error': '$error'});
      }
    }

    onProgress?.call(
      WeReadSyncProgress(
        booksDone: pending.length,
        booksTotal: pending.length,
        phase: WeReadSyncPhase.finished,
      ),
    );

    return _FinishedOutcome(
      notes: notes,
      probed: pending.length,
      missed: missed,
    );
  }

  /// 把一本书的划线 + 想法组装成待写入的笔记。
  Future<List<Note>> _buildNotesFor(WeReadNotebook notebook) async {
    final detail = await _api.fetchBookNotes(notebook.bookId);
    if (detail.isEmpty) {
      return const [];
    }

    final chapterTitles = detail.chapterTitles;
    final notes = <Note>[];

    // 想法按「章节 + 位置范围」归到划线上。range 是同一条原文的稳定标识，
    // 比正文匹配可靠（同一段原文可能被划两次，正文完全一样）。
    final reviewsByAnchor = <String, List<WeReadReview>>{};
    for (final review in detail.reviews) {
      if (!review.isInline) {
        continue;
      }
      reviewsByAnchor
          .putIfAbsent(_anchor(review.chapterUid, review.range), () => [])
          .add(review);
    }

    final matchedReviewIds = <String>{};
    for (final highlight in detail.highlights) {
      final key = _anchor(highlight.chapterUid, highlight.range);
      final inline = reviewsByAnchor[key] ?? const <WeReadReview>[];
      for (final review in inline) {
        matchedReviewIds.add(review.reviewId);
      }
      final note = builder.buildHighlightNote(
        notebook: notebook,
        highlight: highlight,
        chapterTitle: chapterTitles[highlight.chapterUid],
        inlineReviews: inline,
      );
      if (note != null) {
        notes.add(note);
      }
    }

    // 没有对应划线的想法（整本书评、章节点评、独立想法）单独成条。
    for (final review in detail.reviews) {
      if (matchedReviewIds.contains(review.reviewId)) {
        continue;
      }
      final note = builder.buildReviewNote(
        notebook: notebook,
        review: review,
        chapterTitle: review.chapterUid == null
            ? review.chapterName
            : chapterTitles[review.chapterUid!] ?? review.chapterName,
      );
      if (note != null) {
        notes.add(note);
      }
    }

    return notes;
  }

  static String _anchor(int? chapterUid, String? range) =>
      '${chapterUid ?? 0}|${range ?? ''}';

  /// 剔掉库里已存在的 id。**不过滤软删行**：用户删掉的笔记不能被同步复活。
  Future<List<Note>> _filterUnimported(List<Note> notes) async {
    if (notes.isEmpty) {
      return const [];
    }
    final existing = await existingNoteIds(
      notes.map((note) => note.id).toSet(),
    );
    if (existing.isEmpty) {
      return notes;
    }
    return notes.where((note) => !existing.contains(note.id)).toList();
  }

  /// 去重查询的接缝。生产走 [DatabaseService.getExistingNoteIds]，
  /// 单测里覆写成内存实现，避免为一条 SQL 拉起整个 sqflite。
  Future<Set<String>> existingNoteIds(Set<String> ids) =>
      _database.getExistingNoteIds(ids);

  Future<Map<String, dynamic>> _readState() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefKeyState);
    if (raw == null || raw.isEmpty) {
      return <String, dynamic>{};
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } on FormatException {
      // 状态坏了就当没同步过，下一轮全量比对（DB 去重兜底，不会重复入库）
    }
    return <String, dynamic>{};
  }

  Map<String, _BookWatermark> _readWatermarks(Map<String, dynamic> state) {
    final raw = state['books'];
    if (raw is! Map) {
      return {};
    }
    final result = <String, _BookWatermark>{};
    raw.forEach((key, value) {
      if (value is Map) {
        result[key.toString()] = _BookWatermark.fromJson(
          Map<String, dynamic>.from(value),
        );
      }
    });
    return result;
  }

  /// 「查过阅读进度但没读完」的书 → 当时的元信息版本号。
  Map<String, int> _readFinishedMiss(Map<String, dynamic> state) {
    final raw = state['finishedMiss'];
    if (raw is! Map) {
      return {};
    }
    final result = <String, int>{};
    raw.forEach((key, value) {
      // 版本号允许为 0（个别书的 sort / readUpdateTime 就是 0），
      // 「map 里有没有这个 key」本身才是「查过没」的判据。
      result[key.toString()] = _asInt(value);
    });
    return result;
  }

  /// 已处理到的周 / 月水位：`{week: '2026-11-10', month: '2026-10'}`。
  Map<String, String> _readPeriods(Map<String, dynamic> state) {
    final raw = state['periods'];
    if (raw is! Map) {
      return {};
    }
    final result = <String, String>{};
    raw.forEach((key, value) {
      final text = value?.toString().trim() ?? '';
      if (text.isNotEmpty) {
        result[key.toString()] = text;
      }
    });
    return result;
  }

  Future<void> _saveState({
    required Map<String, _BookWatermark> watermarks,
    required Map<String, int> finishedMiss,
    required Map<String, String> periods,
    required DateTime lastSyncAt,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final payload = <String, dynamic>{
      'v': 3,
      'lastSyncAt': lastSyncAt.millisecondsSinceEpoch,
      'books': {
        for (final entry in watermarks.entries) entry.key: entry.value.toJson(),
      },
      'finishedMiss': finishedMiss,
      'periods': periods,
    };
    await prefs.setString(_prefKeyState, jsonEncode(payload));
  }
}
