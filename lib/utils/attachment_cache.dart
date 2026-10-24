import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:inkpaper/utils/attachment_maintenance.dart';
import 'package:path_provider/path_provider.dart';

/// 服务端附件的本地只读缓存索引。
///
/// 正文里始终保留服务端路径（`/file/attachments/...`），渲染时按同一套
/// sha1 命名规则（[localFileNameForAttachment]）去 `<documents>/images/`
/// 找本地副本：有本地文件就读本地，没有才走网络。
///
/// 这样正文与服务器保持一致，同步不会把本地路径覆盖回去，多端也安全。
class AttachmentCache {
  AttachmentCache._();

  static final AttachmentCache instance = AttachmentCache._();

  String? _imagesDirPath;
  Future<void>? _prepareFuture;

  /// 远程路径 → 本地绝对路径；空字符串表示「查过了，本机没有副本」。
  ///
  /// 结果会被记住，避免列表滚动时反复做文件 IO；下载/清理之后再
  /// 调 [invalidate] 让下一次查询重新落盘。
  final Map<String, String> _resolved = <String, String>{};

  /// 预热缓存目录。可重复调用，失败时下次会重试。
  Future<void> prepare() async {
    if (_imagesDirPath != null) {
      return;
    }
    final pending = _prepareFuture;
    if (pending != null) {
      await pending;
      return;
    }

    final future = _loadImagesDir();
    _prepareFuture = future;
    await future;
    if (_imagesDirPath == null) {
      // 目录拿不到（如插件未初始化）时允许下次重试。
      _prepareFuture = null;
    }
  }

  Future<void> _loadImagesDir() async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      _imagesDirPath = '${appDir.path}/images';
    } on Object catch (e) {
      debugPrint('附件缓存目录不可用: $e');
    }
  }

  /// 同步查询远程附件的本地副本；没有预热或不认识这个路径时返回 null。
  File? fileFor(String remotePath) {
    final dir = _imagesDirPath;
    if (dir == null || remotePath.isEmpty) {
      return null;
    }
    if (!isRemoteAttachmentPath(remotePath)) {
      return null;
    }

    final resolved = _resolved[remotePath];
    if (resolved != null) {
      return resolved.isEmpty ? null : File(resolved);
    }

    final path = '$dir/${localFileNameForAttachment(remotePath)}';
    final exists = File(path).existsSync();
    _resolved[remotePath] = exists ? path : '';
    return exists ? File(path) : null;
  }

  /// 本机缓存的绝对路径，找不到返回 null（[fileFor] 的字符串版本）。
  String? pathFor(String remotePath) => fileFor(remotePath)?.path;

  /// 缓存内容发生变化（下载完成 / 清理孤儿）后调用。
  void invalidate() => _resolved.clear();

  /// 仅测试用：直接指定 images 目录，跳过 path_provider。
  @visibleForTesting
  void debugSetImagesDir(String? path) {
    _imagesDirPath = path;
    _prepareFuture = null;
    _resolved.clear();
  }
}
