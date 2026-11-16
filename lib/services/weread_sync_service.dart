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

/// 同步进度（界面用它画「正在拉取《xxx》3/12」）。
class WeReadSyncProgress {
  const WeReadSyncProgress({
    required this.booksDone,
    required this.booksTotal,
    this.currentBookTitle,
  });

  final int booksDone;
  final int booksTotal;
  final String? currentBookTitle;

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
    final now = DateTime.now();

    _api.apiKey = apiKey;

    try {
      final notebooks = await _api.fetchNotebooks();
      if (notebooks.isEmpty) {
        await _saveState(
          watermarks: watermarks,
          lastSyncAt: now,
        );
        return const WeReadSyncResult();
      }

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

      final fresh = await _filterUnimported(candidates);
      final skippedDuplicates = candidates.length - fresh.length;
      if (fresh.isNotEmpty) {
        await persist(fresh);
      }

      await _saveState(watermarks: watermarks, lastSyncAt: now);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_prefKeyLastImported, fresh.length);

      final result = WeReadSyncResult(
        imported: fresh.length,
        booksFetched: booksFetched,
        booksSkipped: booksSkipped,
        booksTotal: notebooks.length,
        skippedDuplicates: skippedDuplicates,
        failures: failures,
      );
      _logger.info(
        '同步完成',
        data: {
          'imported': result.imported,
          'fetched': booksFetched,
          'skipped': booksSkipped,
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

  Future<void> _saveState({
    required Map<String, _BookWatermark> watermarks,
    required DateTime lastSyncAt,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final payload = <String, dynamic>{
      'v': 1,
      'lastSyncAt': lastSyncAt.millisecondsSinceEpoch,
      'books': {
        for (final entry in watermarks.entries) entry.key: entry.value.toJson(),
      },
    };
    await prefs.setString(_prefKeyState, jsonEncode(payload));
  }
}
