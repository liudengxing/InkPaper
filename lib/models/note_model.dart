import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:inkpaper/models/annotation_model.dart';

class Note {
  // 提醒时间

  Note({
    required this.id,
    required this.content,
    required this.createdAt,
    required DateTime updatedAt,
    DateTime? displayTime,
    List<String>? tags,
    String? creator,
    this.isSynced = false,
    this.isPinned = false,
    this.visibility = 'PRIVATE',
    this.rowStatus = 'NORMAL',
    List<Map<String, dynamic>>? resourceList,
    List<Map<String, dynamic>>? relations,
    List<Annotation>? annotations,
    this.reminderTime,
    this.lastSyncTime,
    this.deletedAt,
    this.remoteId,
  })  : updatedAt = _clampUpdatedAt(createdAt, updatedAt),
        displayTime = displayTime ?? _clampUpdatedAt(createdAt, updatedAt),
        tags = tags ?? [],
        creator = creator ?? 'local',
        resourceList = resourceList ?? [],
        relations = relations ?? [],
        annotations = annotations ?? [];

  factory Note.fromMap(Map<String, dynamic> map) {
    // if (kDebugMode) debugPrint('Note.fromMap: 数据库数据: ${map.toString()}');

    // 处理resourceList
    var resourceList = <Map<String, dynamic>>[];
    final resourceListJson = map['resourceList'] as String?;
    if (resourceListJson != null && resourceListJson.isNotEmpty) {
      // if (kDebugMode) debugPrint('Note.fromMap: resourceList原始数据: ${map['resourceList']}');
      try {
        final decoded = json.decode(resourceListJson);
        resourceList = List<Map<String, dynamic>>.from(decoded);
        // if (kDebugMode) debugPrint('Note.fromMap: resourceList解析成功，长度: ${resourceList.length}');
      } on Object catch (e) {
        if (kDebugMode) {
          debugPrint('Note.fromMap: 解析resourceList失败: $e');
        }
      }
    } else {
      // if (kDebugMode) debugPrint('Note.fromMap: resourceList为空或null');
    }

    // 处理relations
    var relations = <Map<String, dynamic>>[];
    final relationsJson = map['relations'] as String?;
    if (relationsJson != null && relationsJson.isNotEmpty) {
      try {
        final decoded = json.decode(relationsJson);
        relations = List<Map<String, dynamic>>.from(decoded);
      } on Object catch (e) {
        if (kDebugMode) {
          debugPrint('Note.fromMap: 解析relations失败: $e');
        }
      }
    }

    // 处理annotations（批注）
    var annotations = <Annotation>[];
    final annotationsJson = map['annotations'] as String?;
    if (annotationsJson != null && annotationsJson.isNotEmpty) {
      annotations = AnnotationList.fromJsonString(annotationsJson);
    }

    final note = Note(
      id: map['id'],
      content: map['content'],
      createdAt: DateTime.parse(map['createdAt']),
      updatedAt: DateTime.parse(map['updatedAt']),
      displayTime: map['displayTime'] != null
          ? DateTime.parse(map['displayTime'])
          : null,
      tags: (map['tags'] as String?)?.isNotEmpty ?? false
          ? (map['tags'] as String).split(',')
          : null,
      creator: map['creator'],
      isSynced: map['is_synced'] == 1,
      isPinned: map['isPinned'] == 1,
      visibility: map['visibility'] ?? 'PRIVATE',
      rowStatus: map['rowStatus'] ?? 'NORMAL',
      resourceList: resourceList,
      relations: relations,
      annotations: annotations,
      reminderTime: map['reminder_time'] != null
          ? DateTime.parse(map['reminder_time'])
          : null,
      lastSyncTime: map['last_sync_time'] != null
          ? DateTime.parse(map['last_sync_time'])
          : null,
      deletedAt: map['deleted_at'] != null
          ? DateTime.tryParse(map['deleted_at'].toString())
          : null,
      remoteId: map['remote_id'] as String?,
    );

    // if (kDebugMode) debugPrint('Note.fromMap: 创建的Note resourceList长度: ${note.resourceList.length}');
    return note;
  }

  factory Note.fromJson(Map<String, dynamic> json) {
    // ── ID ────────────────────────────────────────────────────────────────
    // v0.21.0: int/string 'id' field
    // v0.22.0+: string 'name' field like "memos/123"
    final rawId = json['id'] ?? json['name'] ?? '';
    final id = rawId.toString().contains('/')
        ? rawId.toString().split('/').last
        : rawId.toString();

    // ── Timestamps ────────────────────────────────────────────────────────
    // v0.21.0: 'createdTs'/'updatedTs' – Unix seconds (int)
    // v0.22.0+: 'createTime'/'updateTime' – ISO-8601 string
    final createdAt = _parseCreatedAt(json);
    final updatedAt = _parseUpdatedAt(json) ?? createdAt;

    // ── Display time ──────────────────────────────────────────────────────
    final displayTime = _parseTimestamp(json['displayTime']);

    // ── Resources / Attachments ───────────────────────────────────────────
    // v0.21.0: 'resourceList'
    // v0.22.0–v0.26.x: 'resources'
    // v0.27.0+: 'attachments'  (resource_service → attachment_service rename)
    final rawResources =
        json['attachments'] ?? json['resourceList'] ?? json['resources'];
    final resourceList = _parseMapList(rawResources);

    // ── Relations ─────────────────────────────────────────────────────────
    // v0.21.0: 'relationList'   v0.22.0+: 'relations'
    final rawRelations = json['relationList'] ?? json['relations'];
    final relations = _parseMapList(rawRelations);

    // ── Row status / State ────────────────────────────────────────────────
    // v0.21.0–v0.26.x: 'rowStatus' (ROW_STATUS_UNSPECIFIED / NORMAL / ARCHIVED)
    // v0.27.0+: 'state' (STATE_UNSPECIFIED / NORMAL / ARCHIVED)
    // Both use the same string values NORMAL / ARCHIVED, so we just unify them.
    final rowStatus =
        json['rowStatus']?.toString() ?? json['state']?.toString() ?? 'NORMAL';

    // ── Visibility ────────────────────────────────────────────────────────
    // Both old and new API use enum string names: PRIVATE / PROTECTED / PUBLIC
    final visibility = json['visibility']?.toString() ?? 'PRIVATE';

    // ── Tags ──────────────────────────────────────────────────────────────
    // v0.22.0+: 'tags' is List<String>; v0.21.0: absent (extracted from content)
    final tags = _parseTags(json['tags']);

    // ── Creator ───────────────────────────────────────────────────────────
    // v0.21.0: 'creatorId' (int) or 'creator' (string username)
    // v0.22.0+: 'creator' = "users/{id}"
    final creator =
        json['creatorId']?.toString() ?? json['creator']?.toString();
    final isSynced = _parseBool(json['isSynced'] ?? json['is_synced']) ?? true;
    final annotations = _parseAnnotations(json['annotations']);

    return Note(
      id: id,
      content: json['content']?.toString() ?? '',
      createdAt: createdAt,
      updatedAt: updatedAt,
      displayTime: displayTime,
      tags: tags.isNotEmpty
          ? tags
          : Note.extractTagsFromContent(json['content']?.toString() ?? ''),
      creator: creator,
      isSynced: isSynced,
      isPinned:
          _parseBool(json['pinned'] ?? json['isPinned'] ?? json['is_pinned']) ??
              false,
      visibility: visibility,
      rowStatus: rowStatus,
      resourceList: resourceList,
      relations: relations,
      annotations: annotations,
      reminderTime:
          _parseTimestamp(json['reminderTime'] ?? json['reminder_time']),
      lastSyncTime:
          _parseTimestamp(json['lastSyncTime'] ?? json['last_sync_time']),
      deletedAt: _parseTimestamp(json['deletedAt'] ?? json['deleted_at']),
      // 服务端 uid 与本地 uuid 分开存：从备份 JSON 读回来时用这里的 remoteId，
      // 直接解析 Memos 响应时 `id` 就是 uid，由同步逻辑负责降级（见 AppProvider）
      remoteId:
          json['remoteId']?.toString() ?? json['remote_id']?.toString(),
    );
  }
  final String id;
  final String content;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime displayTime;
  final List<String> tags;
  final String creator;
  bool isSynced;
  final bool isPinned;
  final String visibility;
  final String rowStatus; // 行状态：NORMAL, ARCHIVED
  final List<Map<String, dynamic>> resourceList; // 添加资源列表
  final List<Map<String, dynamic>> relations; // 添加关系列表
  final List<Annotation> annotations; // 批注列表
  final DateTime? reminderTime;
  final DateTime? lastSyncTime; // WebDAV同步时间戳
  final DateTime? deletedAt; // 软删时间（仅「最近删除」使用）

  /// 服务端（Memos）给这条笔记分配的 uid。
  ///
  /// 与 [id]（本地 uuid，永不变）分开存：同一台设备上既跑 Memos 同步又跑
  /// WebDAV 备份时，[id] 不会因为服务端重新签发 uid 而变化，合并匹配才稳定。
  /// 未同步到服务端的本地笔记为 null。
  final String? remoteId;

  /// 把 `updatedAt` 钳到不早于 `createdAt`。
  ///
  /// 服务端与导入的备份偶尔会带出「更新于创建之前」的时间戳（典型是时区
  /// 错位整整一天，如 createdAt=2026-08-21T21:08:43、updatedAt=2026-08-20T21:08:00）。
  /// 时间线不允许倒流：卡片按 updatedAt 排序/展示时会跳到列表错误的位置，
  /// 这里统一钳到创建时间，读到坏数据也不会再显示成负数时差。
  static DateTime _clampUpdatedAt(DateTime createdAt, DateTime updatedAt) =>
      updatedAt.isBefore(createdAt) ? createdAt : updatedAt;

  static DateTime _parseCreatedAt(Map<String, dynamic> json) {
    final parsed = _parseTimestamp(
      json['createTime'] ??
          json['createdAt'] ??
          json['createdTime'] ??
          json['created_at'] ??
          json['create_time'] ??
          json['createdTs'] ??
          json['created_ts'],
    );
    if (parsed != null) {
      return parsed;
    }

    final updated = _parseUpdatedAt(json);
    if (updated != null) {
      return updated;
    }

    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  static DateTime? _parseUpdatedAt(Map<String, dynamic> json) =>
      _parseTimestamp(
        json['updateTime'] ??
            json['updatedAt'] ??
            json['updatedTime'] ??
            json['updated_at'] ??
            json['update_time'] ??
            json['updatedTs'] ??
            json['updated_ts'],
      );

  static DateTime? _parseTimestamp(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is DateTime) {
      return value;
    }
    if (value is int) {
      final milliseconds = value.abs() < 100000000000 ? value * 1000 : value;
      return DateTime.fromMillisecondsSinceEpoch(milliseconds);
    }
    if (value is double) {
      return _parseTimestamp(value.round());
    }

    final raw = value.toString().trim();
    if (raw.isEmpty) {
      return null;
    }
    final numeric = int.tryParse(raw);
    if (numeric != null) {
      return _parseTimestamp(numeric);
    }
    return DateTime.tryParse(raw);
  }

  static bool? _parseBool(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is bool) {
      return value;
    }
    if (value is num) {
      return value != 0;
    }

    final normalized = value.toString().trim().toLowerCase();
    if (normalized == 'true' || normalized == '1') {
      return true;
    }
    if (normalized == 'false' || normalized == '0') {
      return false;
    }
    return null;
  }

  static List<String> _parseTags(Object? rawTags) {
    if (rawTags == null) {
      return const [];
    }
    if (rawTags is List) {
      return rawTags.map((tag) => tag.toString()).toList();
    }
    if (rawTags is String) {
      final value = rawTags.trim();
      if (value.isEmpty) {
        return const [];
      }
      if (value.startsWith('[')) {
        try {
          final decoded = jsonDecode(value);
          if (decoded is List) {
            return decoded.map((tag) => tag.toString()).toList();
          }
        } on Object catch (e) {
          if (kDebugMode) {
            debugPrint('Note.fromJson: 解析tags失败: $e');
          }
        }
      }
      return value
          .split(',')
          .map((tag) => tag.trim())
          .where((tag) => tag.isNotEmpty)
          .toList();
    }
    return const [];
  }

  static List<Map<String, dynamic>> _parseMapList(Object? rawList) {
    if (rawList == null) {
      return const [];
    }
    if (rawList is String) {
      final value = rawList.trim();
      if (value.isEmpty) {
        return const [];
      }
      try {
        return _parseMapList(jsonDecode(value));
      } on Object catch (e) {
        if (kDebugMode) {
          debugPrint('Note.fromJson: 解析列表字段失败: $e');
        }
        return const [];
      }
    }
    if (rawList is List) {
      return rawList.whereType<Map>().map(Map<String, dynamic>.from).toList();
    }
    return const [];
  }

  static List<Annotation> _parseAnnotations(Object? rawAnnotations) {
    if (rawAnnotations == null) {
      return const [];
    }
    if (rawAnnotations is String) {
      return AnnotationList.fromJsonString(rawAnnotations);
    }
    if (rawAnnotations is List) {
      try {
        return rawAnnotations
            .whereType<Map>()
            .map((item) => Annotation.fromMap(Map<String, dynamic>.from(item)))
            .toList();
      } on Object catch (e) {
        if (kDebugMode) {
          debugPrint('Note.fromJson: 解析annotations失败: $e');
        }
      }
    }
    return const [];
  }

  Note copyWith({
    String? id,
    String? content,
    DateTime? createdAt,
    DateTime? updatedAt,
    DateTime? displayTime,
    List<String>? tags,
    String? creator,
    bool? isSynced,
    bool? isPinned,
    String? visibility,
    String? rowStatus,
    List<Map<String, dynamic>>? resourceList,
    List<Map<String, dynamic>>? relations,
    List<Annotation>? annotations,
    DateTime? reminderTime,
    bool clearReminderTime = false,
    DateTime? lastSyncTime,
    bool clearLastSyncTime = false,
    String? remoteId,
    bool clearRemoteId = false,
  }) =>
      Note(
        id: id ?? this.id,
        content: content ?? this.content,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        displayTime: displayTime ?? this.displayTime,
        tags: tags ?? this.tags,
        creator: creator ?? this.creator,
        isSynced: isSynced ?? this.isSynced,
        isPinned: isPinned ?? this.isPinned,
        visibility: visibility ?? this.visibility,
        rowStatus: rowStatus ?? this.rowStatus,
        resourceList: resourceList ?? this.resourceList,
        relations: relations ?? this.relations,
        annotations: annotations ?? this.annotations,
        reminderTime:
            clearReminderTime ? null : (reminderTime ?? this.reminderTime),
        lastSyncTime:
            clearLastSyncTime ? null : (lastSyncTime ?? this.lastSyncTime),
        remoteId: clearRemoteId ? null : (remoteId ?? this.remoteId),
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'content': content,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'displayTime': displayTime.toIso8601String(),
        'tags': tags.join(','),
        'creator': creator,
        'is_synced': isSynced ? 1 : 0,
        'isPinned': isPinned ? 1 : 0,
        'visibility': visibility,
        'rowStatus': rowStatus,
        'resourceList': json.encode(resourceList), // 将resourceList序列化为JSON字符串
        'relations': json.encode(relations), // 将relations序列化为JSON字符串
        'annotations':
            AnnotationList.toJsonString(annotations), // 将批注序列化为JSON字符串
        'reminder_time': reminderTime?.toIso8601String(),
        'last_sync_time': lastSyncTime?.toIso8601String(),
        'remote_id': remoteId,
      };

  Map<String, dynamic> toJson() => {
        'id': id,
        'content': content,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'createdTs': createdAt.millisecondsSinceEpoch ~/
            1000, // 🔧 转换为秒级时间戳，与 Memos API 一致
        'updatedTs': updatedAt.millisecondsSinceEpoch ~/ 1000, // 🔧 转换为秒级时间戳
        'displayTime': displayTime.toIso8601String(),
        'tags': tags,
        'creator': creator,
        'isSynced': isSynced,
        'pinned': isPinned,
        'visibility': visibility,
        'rowStatus': rowStatus,
        'resourceList': resourceList, // ✅ 包含图片/资源
        'relationList': relations, // ✅ 包含关系
        'annotations':
            annotations.map((annotation) => annotation.toJson()).toList(),
        'reminderTime': reminderTime?.toIso8601String(), // ✅ 包含提醒时间
        'lastSyncTime': lastSyncTime?.toIso8601String(), // ✅ 包含同步时间
        // 软删时间。备份默认不含回收站（导出走 active_notes 视图），这里补上
        // 是为了将来若要连回收站一起备份，恢复后 GC 仍能按原时间清理。
        'deletedAt': deletedAt?.toIso8601String(),
        // 服务端 uid 随备份走，恢复/多设备合并时优先按它认领同一条笔记
        'remoteId': remoteId,
      };

  /// 本地 id 前缀。本地新建但尚未同步到服务端的笔记使用 `local_<毫秒>_<序号>`。
  static const String localIdPrefix = 'local_';

  /// 是否是尚未同步到服务端的本地笔记。
  ///
  /// 只认 [localIdPrefix]：服务端 id 可能是数字，也可能是含 `-` 的 UUID，
  /// 用 `id.contains('-')` 判断会把服务端笔记误判成本地笔记，
  /// 导致更新/删除被静默跳过。
  static bool isLocalId(String id) => id.startsWith(localIdPrefix);

  // 从笔记内容中提取标签（改进版，排除URL中的#）
  static List<String> extractTagsFromContent(String content) {
    // 使用统一的标签提取逻辑
    return _extractTagsImproved(content);
  }

  // 改进的标签提取逻辑（参考Obsidian/Notion/Logseq）
  static List<String> _extractTagsImproved(String content) {
    // 🎯 改进的标签识别规则：
    // - 排除URL中的#
    // - 前缀要求：#前面不能是字母、数字、下划线、冒号、斜杠
    // - 排除连续##（Markdown标题）
    final tagRegex = RegExp(
      r'(?<![\w:/])(?!##)#([^\s\[\],，、;；:：！!？?\n#]+)',
      unicode: true,
    );

    final tags = <String>[];
    final lines = content.split('\n');

    for (final line in lines) {
      // 如果这行包含URL，需要排除URL中的#
      if (line.contains(RegExp('[a-zA-Z]+://'))) {
        // 找出所有URL的位置范围
        final urlRegex = RegExp(r'[a-zA-Z]+://[^\s\)]+');
        final urlMatches = urlRegex.allMatches(line).toList();
        final urlRanges = urlMatches.map((m) => [m.start, m.end]).toList();

        // 找出所有标签，但排除在URL范围内的
        final tagMatches = tagRegex.allMatches(line);
        for (final match in tagMatches) {
          var inUrl = false;
          for (final range in urlRanges) {
            if (match.start >= range[0] && match.end <= range[1]) {
              inUrl = true;
              break;
            }
          }
          if (!inUrl) {
            tags.add(match.group(1)!);
          }
        }
      } else {
        // 没有URL的行，直接提取所有标签
        tags.addAll(
          tagRegex.allMatches(line).map((match) => match.group(1)!),
        );
      }
    }

    return tags;
  }

  // 判断可见性
  bool get isPrivate => visibility == 'PRIVATE';
  bool get isProtected => visibility == 'PROTECTED';
  bool get isPublic => visibility == 'PUBLIC';
  bool get isArchived => rowStatus == 'ARCHIVED';
  bool get isNormal => rowStatus == 'NORMAL';
  bool get isDeleted => rowStatus == 'DELETED';
}
