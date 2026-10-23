import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 一条编辑器草稿。
class NoteDraft {
  const NoteDraft({
    required this.draftId,
    required this.content,
    required this.updatedAt,
    this.noteId,
  });

  factory NoteDraft.fromJson(Map<String, dynamic> json, String draftId) {
    final noteId = json['noteId']?.toString();
    return NoteDraft(
      draftId: draftId,
      noteId: (noteId == null || noteId.isEmpty) ? null : noteId,
      content: json['content']?.toString() ?? '',
      updatedAt: DateTime.tryParse(json['updatedAt']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  /// 草稿标识：编辑已有笔记时是笔记 id，新建笔记时是 [DraftService.newNoteDraftId]。
  final String draftId;

  /// 关联的笔记 id；纯新建草稿为 null。
  final String? noteId;

  final String content;
  final DateTime updatedAt;

  bool get isNewNote => noteId == null;

  Map<String, dynamic> toJson() => {
        'noteId': noteId,
        'content': content,
        'updatedAt': updatedAt.toIso8601String(),
      };
}

/// 编辑器草稿的本地暂存。
///
/// 目的：编辑器被误关（点空白、系统返回、切后台后被回收）时，已输入内容不会丢。
/// 草稿按「一条笔记一个槽位」存（新建笔记共用 [newNoteDraftId]），
/// 默认保留 [retention]，过期自动清理，避免长期堆积。
class DraftService {
  static const String prefsKey = 'note_editor_drafts_v2';
  static const String newNoteDraftId = '__new__';

  /// 旧版本只存新建笔记的一条草稿，这里兼容读取并迁移。
  static const String legacyNewNoteKey = 'note_editor_draft';

  /// 默认保留 7 天。
  static const Duration retention = Duration(days: 7);

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  /// 暂存草稿。内容为空时等价于删除，避免留下空壳。
  Future<void> save({
    required String draftId,
    required String content,
    String? noteId,
  }) async {
    if (content.trim().isEmpty) {
      await clear(draftId);
      return;
    }
    try {
      final prefs = await _prefs;
      final all = _decode(prefs.getString(prefsKey));
      all[draftId] = NoteDraft(
        draftId: draftId,
        noteId: noteId,
        content: content,
        updatedAt: DateTime.now(),
      ).toJson();
      await prefs.setString(prefsKey, jsonEncode(all));
    } on Object catch (e) {
      debugPrint('DraftService: 保存草稿失败: $e');
    }
  }

  /// 读取指定槽位的草稿；已过期或不存在返回 null。
  Future<NoteDraft?> load(String draftId) async {
    try {
      final prefs = await _prefs;
      final all = _decode(prefs.getString(prefsKey));
      final raw = all[draftId];
      if (raw is Map) {
        final draft = NoteDraft.fromJson(Map<String, dynamic>.from(raw), draftId);
        if (_isExpired(draft)) {
          await clear(draftId);
          return null;
        }
        return draft.content.trim().isEmpty ? null : draft;
      }

      // 旧版本草稿迁移：只对新建笔记槽位生效。
      if (draftId == newNoteDraftId) {
        final legacy = prefs.getString(legacyNewNoteKey);
        if (legacy != null && legacy.trim().isNotEmpty) {
          final draft = NoteDraft(
            draftId: newNoteDraftId,
            content: legacy,
            updatedAt: DateTime.now(),
          );
          await save(
            draftId: newNoteDraftId,
            content: legacy,
          );
          await prefs.remove(legacyNewNoteKey);
          return draft;
        }
      }
      return null;
    } on Object catch (e) {
      debugPrint('DraftService: 读取草稿失败: $e');
      return null;
    }
  }

  Future<void> clear(String draftId) async {
    try {
      final prefs = await _prefs;
      final all = _decode(prefs.getString(prefsKey));
      if (all.remove(draftId) == null) {
        return;
      }
      if (all.isEmpty) {
        await prefs.remove(prefsKey);
      } else {
        await prefs.setString(prefsKey, jsonEncode(all));
      }
    } on Object catch (e) {
      debugPrint('DraftService: 清除草稿失败: $e');
    }
  }

  /// 列出所有未过期草稿，最近更新的在前。
  Future<List<NoteDraft>> list() async {
    try {
      final prefs = await _prefs;
      final all = _decode(prefs.getString(prefsKey));
      final drafts = <NoteDraft>[];
      final expired = <String>[];
      all.forEach((draftId, raw) {
        if (raw is! Map) {
          return;
        }
        final draft = NoteDraft.fromJson(Map<String, dynamic>.from(raw), draftId);
        if (_isExpired(draft) || draft.content.trim().isEmpty) {
          expired.add(draftId);
        } else {
          drafts.add(draft);
        }
      });
      for (final draftId in expired) {
        await clear(draftId);
      }
      drafts.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return drafts;
    } on Object catch (e) {
      debugPrint('DraftService: 列出草稿失败: $e');
      return const [];
    }
  }

  /// 清理过期草稿，返回清理条数。
  Future<int> pruneExpired() async {
    final before = await list();
    final prefs = await _prefs;
    final all = _decode(prefs.getString(prefsKey));
    final alive = before.map((draft) => draft.draftId).toSet();
    final removed = all.keys.where((id) => !alive.contains(id)).length;
    if (removed > 0) {
      final kept = <String, dynamic>{
        for (final entry in all.entries)
          if (alive.contains(entry.key)) entry.key: entry.value,
      };
      if (kept.isEmpty) {
        await prefs.remove(prefsKey);
      } else {
        await prefs.setString(prefsKey, jsonEncode(kept));
      }
    }
    return removed;
  }

  bool _isExpired(NoteDraft draft) =>
      DateTime.now().difference(draft.updatedAt) > retention;

  Map<String, dynamic> _decode(String? raw) {
    if (raw == null || raw.isEmpty) {
      return <String, dynamic>{};
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } on Object catch (e) {
      debugPrint('DraftService: 草稿数据损坏，已忽略: $e');
    }
    return <String, dynamic>{};
  }
}
