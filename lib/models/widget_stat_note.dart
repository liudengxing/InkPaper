import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:inkpaper/models/note_model.dart';

/// 桌面小组件统计口径的「一行笔记」。
///
/// 快照一次要过整库（千条量级），但真正会被渲染的只有回顾候选（≤8 条）和
/// 置顶那一条。以前这条路径走 `Note.fromMap`，每行构造 **3 个本地 DateTime**
/// ——`DateTime(y, m, d, …)` 每次都要向系统查一次时区偏移，本机实测约 45µs，
/// 1500 行光这一项就是 200ms 级；而统计真正需要的「哪一天」「谁更新得更晚」
/// 用排好序的 ISO 字符串比较就够了。
///
/// 所以这里只保留 ISO 字符串，`createdAt` / `displayTime` 是惰性解析的——
/// 只有真要格式化「2026-11-23 19:50」或算「几天前」时才付那次时区查询
/// （`updatedAt` 连渲染都不需要，全程留在字符串形态）。字符串一律按挂钟时间比较（不做 `toLocal`），与全应用的显示口径
/// 一致。
class WidgetStatNote {
  WidgetStatNote({
    required this.id,
    required this.content,
    required this.createdAtIso,
    required String updatedAtIso,
    String? displayTimeIso,
    List<String>? tags,
    this.isSynced = false,
    this.isPinned = false,
    this.rowStatus = 'NORMAL',
    List<Map<String, dynamic>>? resourceList,
  })  : updatedAtIso = _clampIso(createdAtIso, updatedAtIso),
        // 与 `Note` 一致：显式给了 displayTime 就照用（哪怕早于创建时间，
        // 那是「手动改过时间」的笔记），只有缺省时才回落到更新时间的钳制值。
        displayTimeIso = (displayTimeIso == null || displayTimeIso.isEmpty)
            ? _clampIso(createdAtIso, updatedAtIso)
            : displayTimeIso,
        tags = tags ?? <String>[],
        resourceList = resourceList ?? <Map<String, dynamic>>[];

  /// 从数据库行构造，不做任何时间解析。
  ///
  /// 只用于 `viewActiveNotes` 的窄列（含 resourceList，不含 relations）。
  factory WidgetStatNote.fromRow(Map<String, Object?> row) {
    var resourceList = <Map<String, dynamic>>[];
    final resourceListJson = row['resourceList'] as String?;
    if (resourceListJson != null && resourceListJson.isNotEmpty) {
      try {
        resourceList = List<Map<String, dynamic>>.from(
          json.decode(resourceListJson) as List<dynamic>,
        );
      } on Object catch (_) {
        // 坏掉的附件 JSON 不该让整个快照构建失败，按「没有附件」处理。
      }
    }
    final tagsJson = row['tags'] as String?;
    return WidgetStatNote(
      id: row['id'] as String? ?? '',
      content: row['content'] as String? ?? '',
      createdAtIso: row['createdAt'] as String? ?? '',
      updatedAtIso: row['updatedAt'] as String? ?? '',
      displayTimeIso: row['displayTime'] as String?,
      tags: (tagsJson != null && tagsJson.isNotEmpty)
          ? tagsJson.split(',')
          : null,
      isSynced: row['is_synced'] == 1,
      isPinned: row['isPinned'] == 1,
      rowStatus: row['rowStatus'] as String? ?? 'NORMAL',
      resourceList: resourceList,
    );
  }

  /// 从已经解析好的 [Note] 转过来（内存兜底路径）。
  ///
  /// `toIso8601String` 不查时区，只是格式化，所以这里没有解析开销。
  factory WidgetStatNote.fromNote(Note note) => WidgetStatNote(
        id: note.id,
        content: note.content,
        createdAtIso: note.createdAt.toIso8601String(),
        updatedAtIso: note.updatedAt.toIso8601String(),
        displayTimeIso: note.displayTime.toIso8601String(),
        tags: note.tags,
        isSynced: note.isSynced,
        isPinned: note.isPinned,
        rowStatus: note.rowStatus,
        resourceList: note.resourceList,
      );

  final String id;
  final String content;
  final String createdAtIso;
  final String updatedAtIso;
  final String displayTimeIso;
  final List<String> tags;
  final bool isSynced;
  final bool isPinned;
  final String rowStatus;
  final List<Map<String, dynamic>> resourceList;

  /// 仅测试用：惰性解析真正发生的次数。
  ///
  /// 「统计不构造 DateTime」这件事本身没法直接断言，但可以断言「整库构建下来
  /// 只解析了个位数」——老实现是每行 3 次（1500 行 = 4500 次）。
  @visibleForTesting
  static int debugLazyParseCount = 0;

  DateTime? _createdAt;
  DateTime? _displayTime;

  DateTime get createdAt {
    final cached = _createdAt;
    if (cached != null) {
      return cached;
    }
    debugLazyParseCount++;
    return _createdAt = DateTime.parse(createdAtIso);
  }

  DateTime get displayTime {
    final cached = _displayTime;
    if (cached != null) {
      return cached;
    }
    debugLazyParseCount++;
    return _displayTime = DateTime.parse(displayTimeIso);
  }

  /// 统计格子用的日期键（yyyy-MM-dd）。
  ///
  /// ISO 8601 的前 10 位就是挂钟日期，和 `DateTime(y, m, d)` 取字段值等价，
  /// 但不用构造 DateTime。
  String get displayDayKey => _dayKeyOf(displayTimeIso);

  /// 排序键。同一格式的 ISO 串按字典序排就是按时间排；这里只用于
  /// 「回顾候选的池子顺序」和「多条置顶取哪一条」，同一秒内的先后不影响结果。
  String get displaySortKey => displayTimeIso;

  static String _dayKeyOf(String iso) =>
      iso.length >= 10 ? iso.substring(0, 10) : iso;

  /// 与 `Note._clampUpdatedAt` 同义：早于创建时间的更新/显示时间压回创建时间。
  static String _clampIso(String createdAtIso, String value) =>
      value.compareTo(createdAtIso) < 0 ? createdAtIso : value;
}
