import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/services/intelligent_related_notes_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 🧠 用户行为学习服务
///
/// 功能：
/// 1. 记录点击行为
/// 2. 分析用户偏好（标签、关系类型、主题）
/// 3. 提供个性化权重调整
class UserBehaviorService {
  static const String _clickHistoryKey = 'user_click_history';
  static const String _preferenceKey = 'user_preferences';
  static const int _maxHistorySize = 200; // 保留最近200次浏览

  /// 浏览不足这个秒数视为误触，不记录（避免拉低平均时长）。
  static const int _minMeaningfulViewSeconds = 3;

  /// 点击记录与详情页回填的配对窗口：点开相关笔记后 60 秒内关掉详情页，
  /// 浏览时长就回填到那条点击记录上，而不是另开一条。
  static const int _viewBackfillWindowMs = 60 * 1000;

  /// 📊 记录一次浏览（点开笔记）
  ///
  /// [source] 记录入口：related_sheet（相关笔记面板）/ card（首页与列表卡片）/
  /// detail（详情页直接打开）。点击时还不知道浏览时长，先落一条 0 时长记录，
  /// 详情页关闭后由 [completeView] 回填。
  Future<void> recordClick({
    required String noteId,
    required List<String> noteTags,
    RelationType? relationType, // 从哪种关系类型点击的（仅相关笔记面板有）
    String source = 'unknown',
    int viewDurationSeconds = 0,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // 读取历史记录
      final historyJson = prefs.getString(_clickHistoryKey);
      final history = historyJson != null
          ? List<Map<String, dynamic>>.from(json.decode(historyJson))
          : <Map<String, dynamic>>[];

      // 添加新记录
      history.insert(0, {
        'noteId': noteId,
        'tags': noteTags,
        'relationType': relationType?.name,
        'source': source,
        'viewDuration': viewDurationSeconds,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });

      // 只保留最近N条
      if (history.length > _maxHistorySize) {
        history.removeRange(_maxHistorySize, history.length);
      }

      // 保存
      await prefs.setString(_clickHistoryKey, json.encode(history));

      // 更新偏好分析
      await _updatePreferences(history);

      debugPrint('📊 记录浏览：noteId=$noteId, 来源=$source');
    } on Object catch (e) {
      debugPrint('⚠️ 记录浏览失败: $e');
    }
  }

  /// 🕐 详情页关闭时回填真实浏览时长
  ///
  /// - 配对窗口内有同笔记、时长为 0 的记录（相关笔记面板/卡片刚点的）
  ///   → 就地回填，同一次浏览只算一条；
  /// - 没有待回填的 → 插入一条新记录（通知点击、深链等直开详情的情况）。
  /// 浏览不足 [_minMeaningfulViewSeconds] 秒视为误触，直接丢弃。
  Future<void> completeView({
    required String noteId,
    required List<String> noteTags,
    required int viewDurationSeconds,
    String source = 'detail',
  }) async {
    if (viewDurationSeconds < _minMeaningfulViewSeconds) {
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final historyJson = prefs.getString(_clickHistoryKey);
      final history = historyJson != null
          ? List<Map<String, dynamic>>.from(json.decode(historyJson))
          : <Map<String, dynamic>>[];

      final cutoff =
          DateTime.now().millisecondsSinceEpoch - _viewBackfillWindowMs;
      for (final record in history) {
        final isSameNote = record['noteId'] == noteId;
        final isUntimed = (record['viewDuration'] as int? ?? 0) == 0;
        final isRecent = (record['timestamp'] as int? ?? 0) >= cutoff;
        if (isSameNote && isUntimed && isRecent) {
          record['viewDuration'] = viewDurationSeconds;
          await prefs.setString(_clickHistoryKey, json.encode(history));
          await _updatePreferences(history);
          debugPrint('🕐 回填浏览时长：noteId=$noteId, $viewDurationSeconds秒');
          return;
        }
      }

      // 没有配对记录，作为一次独立浏览落库
      await recordClick(
        noteId: noteId,
        noteTags: noteTags,
        source: source,
        viewDurationSeconds: viewDurationSeconds,
      );
    } on Object catch (e) {
      debugPrint('⚠️ 回填浏览时长失败: $e');
    }
  }

  /// 🔍 分析并更新用户偏好
  Future<void> _updatePreferences(List<Map<String, dynamic>> history) async {
    try {
      if (history.isEmpty) {
        return;
      }

      // 1. 统计标签偏好
      final tagFrequency = <String, int>{};
      for (final record in history) {
        final tags = List<String>.from(record['tags'] ?? []);
        for (final tag in tags) {
          tagFrequency[tag] = (tagFrequency[tag] ?? 0) + 1;
        }
      }

      // 2. 统计关系类型偏好
      final relationTypeFrequency = <String, int>{};
      for (final record in history) {
        final relationType = record['relationType'] as String?;
        if (relationType != null) {
          relationTypeFrequency[relationType] =
              (relationTypeFrequency[relationType] ?? 0) + 1;
        }
      }

      // 3. 计算平均浏览时长：只统计有时长的记录（刚点开还没关的记录时长为 0，
      //    混进来会把平均值无限拉低，这也是早期「平均时长恒 0」的根因之一）
      final timedViews = history
          .map((record) => record['viewDuration'] as int? ?? 0)
          .where((seconds) => seconds > 0)
          .toList();
      final avgViewDuration = timedViews.isEmpty
          ? 0.0
          : timedViews.fold<int>(0, (sum, seconds) => sum + seconds) /
              timedViews.length;

      // 4. 找出Top标签（最喜欢的）
      final topTags = tagFrequency.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      final favoriteTagsMap = Map.fromEntries(
        topTags.take(20).map((e) => MapEntry(e.key, e.value)),
      );

      // 5. 找出最喜欢的关系类型
      final topRelationTypes = relationTypeFrequency.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      final favoriteRelationTypesMap = Map.fromEntries(topRelationTypes);

      // 保存偏好
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _preferenceKey,
        json.encode({
          'favoriteTags': favoriteTagsMap,
          'favoriteRelationTypes': favoriteRelationTypesMap,
          'avgViewDuration': avgViewDuration,
          'totalClicks': history.length,
          'lastUpdated': DateTime.now().millisecondsSinceEpoch,
        }),
      );

      debugPrint('🧠 偏好已更新：'
          'Top标签=${favoriteTagsMap.keys.take(3).join(", ")}, '
          'Top关系=${favoriteRelationTypesMap.keys.take(2).join(", ")}');
    } on Object catch (e) {
      debugPrint('⚠️ 更新偏好失败: $e');
    }
  }

  /// 🎯 获取用户偏好
  Future<UserPreference> getUserPreference() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final preferenceJson = prefs.getString(_preferenceKey);

      if (preferenceJson == null) {
        return UserPreference.empty();
      }

      final data = json.decode(preferenceJson) as Map<String, dynamic>;

      return UserPreference(
        favoriteTags: Map<String, int>.from(data['favoriteTags'] ?? {}),
        favoriteRelationTypes: Map<String, int>.from(
          data['favoriteRelationTypes'] ?? {},
        ),
        avgViewDuration: (data['avgViewDuration'] as num?)?.toDouble() ?? 0,
        totalClicks: data['totalClicks'] as int? ?? 0,
      );
    } on Object catch (e) {
      debugPrint('⚠️ 读取偏好失败: $e');
      return UserPreference.empty();
    }
  }

  /// 🎨 为笔记计算个性化权重加成
  double calculatePersonalizedBoost({
    required Note note,
    required RelationType relationType,
    required UserPreference preference,
  }) {
    if (preference.totalClicks < 5) {
      return 0; // 数据太少，不调整
    }

    var boost = 0.0;

    // 1. 标签匹配加成（最高 +30%）——用笔记自带的结构化标签，
    //    不再从正文里猜（正文里的 # 标签可能不全也不准）
    final noteTags = note.tags.toSet();
    var tagBoost = 0.0;
    for (final tag in noteTags) {
      final frequency = preference.favoriteTags[tag] ?? 0;
      if (frequency > 0) {
        // 频率越高，加成越大
        tagBoost += (frequency / preference.totalClicks) * 0.5;
      }
    }
    boost += tagBoost.clamp(0.0, 0.3); // 最多加30%

    // 2. 关系类型匹配加成（最高 +20%）
    final relationFrequency =
        preference.favoriteRelationTypes[relationType.name] ?? 0;
    if (relationFrequency > 0) {
      final relationBoost = (relationFrequency / preference.totalClicks) * 0.4;
      boost += relationBoost.clamp(0.0, 0.2); // 最多加20%
    }

    return boost; // 总加成：0-50%
  }

  /// 📈 获取浏览历史（用于可视化）
  Future<List<ClickRecord>> getClickHistory({int limit = 50}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final historyJson = prefs.getString(_clickHistoryKey);

      if (historyJson == null) {
        return [];
      }

      final history = List<Map<String, dynamic>>.from(json.decode(historyJson));

      return history
          .take(limit)
          .map(
            (record) => ClickRecord(
              noteId: record['noteId'] as String,
              tags: List<String>.from(record['tags'] ?? []),
              relationType: record['relationType'] as String?,
              source: record['source'] as String? ?? 'unknown',
              viewDuration: record['viewDuration'] as int? ?? 0,
              timestamp: DateTime.fromMillisecondsSinceEpoch(
                record['timestamp'] as int,
              ),
            ),
          )
          .toList();
    } on Object catch (e) {
      debugPrint('⚠️ 读取历史失败: $e');
      return [];
    }
  }

  /// 🗑️ 清除所有数据
  Future<void> clearAllData() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_clickHistoryKey);
      await prefs.remove(_preferenceKey);
      debugPrint('🗑️ 用户行为数据已清除');
    } on Object catch (e) {
      debugPrint('⚠️ 清除数据失败: $e');
    }
  }
}

/// 👤 用户偏好模型
class UserPreference {
  const UserPreference({
    required this.favoriteTags,
    required this.favoriteRelationTypes,
    required this.avgViewDuration,
    required this.totalClicks,
  });

  factory UserPreference.empty() => const UserPreference(
        favoriteTags: {},
        favoriteRelationTypes: {},
        avgViewDuration: 0,
        totalClicks: 0,
      );

  final Map<String, int> favoriteTags; // 标签 -> 点击次数
  final Map<String, int> favoriteRelationTypes; // 关系类型 -> 点击次数
  final double avgViewDuration; // 平均浏览时长（秒）
  final int totalClicks; // 总点击次数

  /// 获取Top N 标签
  List<String> getTopTags(int n) {
    final sorted = favoriteTags.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted.take(n).map((e) => e.key).toList();
  }

  /// 获取Top N 关系类型
  List<String> getTopRelationTypes(int n) {
    final sorted = favoriteRelationTypes.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted.take(n).map((e) => e.key).toList();
  }

  /// 是否有足够数据进行个性化
  bool get hasEnoughData => totalClicks >= 5;
}

/// 📊 浏览记录模型
class ClickRecord {
  const ClickRecord({
    required this.noteId,
    required this.tags,
    required this.relationType,
    required this.source,
    required this.viewDuration,
    required this.timestamp,
  });

  final String noteId;
  final List<String> tags;
  final String? relationType;

  /// 浏览入口：related_sheet / card / detail / unknown
  final String source;
  final int viewDuration;
  final DateTime timestamp;
}
