import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:path_provider/path_provider.dart';

/// 首页首屏快照。
///
/// 冷启动时本地库还没读完，首页会先渲染空列表（历史上会闪出「欢迎笔记」）。
/// 这里把上次的首屏笔记落成一份独立 JSON，`main()` 在 runApp 之前读出来塞进
/// `AppProvider`，首帧直接画用户自己的笔记；真实数据一到就整体替换。
///
/// 只做展示预填，不参与任何业务判断：
/// - 真实加载失败也不会用快照兜底业务逻辑（避免读到已删除/过期状态）；
/// - 文件独立存放，不塞进 SharedPreferences（后者启动时全量解析，
///   变大后会拖慢所有配置读取）。
class FeedSnapshotService {
  FeedSnapshotService._();

  static final FeedSnapshotService instance = FeedSnapshotService._();

  /// 只缓存首屏能看到的条数，多了没意义还会拖慢启动。
  static const int maxNotes = 20;

  static const String _fileName = 'home_feed_snapshot.json';

  Future<File?> _file() async {
    try {
      final dir = await getApplicationSupportDirectory();
      return File('${dir.path}${Platform.pathSeparator}$_fileName');
    } on Object catch (e) {
      debugPrint('FeedSnapshotService: 定位快照文件失败: $e');
      return null;
    }
  }

  /// 读取上次的首屏快照；没有或损坏时返回空列表。
  Future<List<Note>> load() async {
    try {
      final file = await _file();
      if (file == null || !await file.exists()) {
        return const <Note>[];
      }
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) {
        return const <Note>[];
      }
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return const <Note>[];
      }
      final notes = <Note>[];
      for (final item in decoded) {
        if (item is! Map) {
          continue;
        }
        try {
          notes.add(Note.fromMap(Map<String, dynamic>.from(item)));
        } on Object {
          // 单条损坏就跳过，别让整份快照作废
        }
      }
      return notes;
    } on Object catch (e) {
      debugPrint('FeedSnapshotService: 读取快照失败: $e');
      return const <Note>[];
    }
  }

  /// 覆盖写入首屏快照；传入空列表等价于删除快照。
  Future<void> save(List<Note> notes) async {
    try {
      final file = await _file();
      if (file == null) {
        return;
      }
      if (notes.isEmpty) {
        if (await file.exists()) {
          await file.delete();
        }
        return;
      }
      final payload = notes
          .take(maxNotes)
          .map((note) => note.toMap())
          .toList(growable: false);
      await file.writeAsString(jsonEncode(payload), flush: true);
    } on Object catch (e) {
      // 快照只是加速首帧，写失败不影响任何功能
      debugPrint('FeedSnapshotService: 写入快照失败: $e');
    }
  }
}
