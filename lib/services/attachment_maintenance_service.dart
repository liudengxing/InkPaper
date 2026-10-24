import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/utils/attachment_maintenance.dart';
import 'package:path_provider/path_provider.dart';

/// 附件本地化的结果。
class AttachmentLocalizeReport {
  const AttachmentLocalizeReport({
    required this.totalRefs,
    required this.downloaded,
    required this.alreadyLocal,
    required this.failed,
    required this.notesUpdated,
  });

  /// 正文里出现的唯一远程附件路径数。
  final int totalRefs;

  /// 本次成功下载的文件数。
  final int downloaded;

  /// 之前已下载过、直接复用的文件数。
  final int alreadyLocal;

  /// 下载失败（404 / 401 / 超时）的路径。
  final List<String> failed;

  /// 正文被改写的笔记数。
  final int notesUpdated;

  bool get hasFailure => failed.isNotEmpty;
}

/// 未引用附件的扫描结果。
class OrphanAttachmentReport {
  const OrphanAttachmentReport({
    required this.fileNames,
    required this.totalBytes,
  });

  final List<String> fileNames;
  final int totalBytes;

  bool get isEmpty => fileNames.isEmpty;

  double get totalMB => totalBytes / (1024 * 1024);
}

/// 附件的本地化与清理。
///
/// 「本地化」把正文里的 `/file/attachments/<uid>/x.jpg` 这类服务端路径
/// 下载到 `<documents>/images/` 并改写为 `images/<文件名>`，这样脱离
/// Memos 服务器（退出登录、离开内网）之后图片仍然能显示。
class AttachmentMaintenanceService {
  AttachmentMaintenanceService({
    required this.baseUrl,
    this.token,
    http.Client? httpClient,
  }) : _client = httpClient ?? http.Client();

  final String baseUrl;
  final String? token;
  final http.Client _client;

  Future<Directory> _imagesDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/images');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  String _fullUrl(String remotePath) {
    final base =
        baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    if (remotePath.startsWith('attachments/')) {
      return '$base/file/$remotePath';
    }
    return '$base$remotePath';
  }

  /// 把笔记引用的服务端附件下载到本地，并改写正文与资源列表。
  Future<AttachmentLocalizeReport> localize({
    required List<Note> notes,
    required Future<void> Function(Note note) saveNote,
    void Function(int done, int total, String message)? onProgress,
  }) async {
    final dir = await _imagesDir();

    // 1. 收集全部远程引用（正文 + 资源列表）
    final remoteRefs = <String>[];
    void collect(String? path) {
      if (path == null) {
        return;
      }
      final clean = path.trim();
      if (!isRemoteAttachmentPath(clean) || remoteRefs.contains(clean)) {
        return;
      }
      remoteRefs.add(clean);
    }

    for (final note in notes) {
      for (final ref in extractImageRefs(note.content)) {
        collect(ref);
      }
      for (final resource in note.resourceList) {
        collect(resource['externalLink']?.toString());
      }
    }

    // 2. 逐个下载
    final mapping = <String, String>{};
    final failed = <String>[];
    var downloaded = 0;
    var alreadyLocal = 0;

    for (var i = 0; i < remoteRefs.length; i++) {
      final remote = remoteRefs[i];
      onProgress?.call(
        i + 1,
        remoteRefs.length,
        '下载附件 ${i + 1}/${remoteRefs.length}',
      );

      final localName = localFileNameForAttachment(remote);
      final localPath = '$localImagePrefix$localName';
      final target = File('${dir.path}/$localName');

      if (await target.exists()) {
        mapping[remote] = localPath;
        alreadyLocal++;
        continue;
      }
      final error = await _download(remote, target);
      if (error == null) {
        mapping[remote] = localPath;
        downloaded++;
      } else {
        failed.add('$remote（$error）');
        debugPrint('附件下载失败: $remote -> ${_fullUrl(remote)} [$error]');
      }
    }

    // 3. 改写笔记
    var updated = 0;
    if (mapping.isNotEmpty) {
      for (final note in notes) {
        final newContent = rewriteImageRefs(note.content, mapping);
        final newResources = _rewriteResources(note.resourceList, mapping);
        if (newContent == note.content && newResources == null) {
          continue;
        }
        final updatedNote = note.copyWith(
          content: newContent,
          resourceList: newResources ?? note.resourceList,
        );
        await saveNote(updatedNote);
        updated++;
      }
    }

    return AttachmentLocalizeReport(
      totalRefs: remoteRefs.length,
      downloaded: downloaded,
      alreadyLocal: alreadyLocal,
      failed: failed,
      notesUpdated: updated,
    );
  }

  /// 返回 null 表示成功，否则返回失败原因（HTTP 状态码 / 超时 / 网络异常）。
  Future<String?> _download(String remotePath, File target) async {
    try {
      final response = await _client
          .get(
            Uri.parse(_fullUrl(remotePath)),
            headers: token != null && token!.isNotEmpty
                ? {'Authorization': 'Bearer $token'}
                : const <String, String>{},
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        debugPrint(
          '附件下载失败(${response.statusCode}): ${_fullUrl(remotePath)}',
        );
        return 'HTTP ${response.statusCode}';
      }
      if (response.bodyBytes.isEmpty) {
        return '空响应';
      }
      await target.writeAsBytes(response.bodyBytes, flush: true);
      return null;
    } on TimeoutException {
      return '请求超时';
    } on Object catch (e) {
      debugPrint('附件下载异常: ${_fullUrl(remotePath)} - $e');
      return '网络异常';
    }
  }

  List<Map<String, dynamic>>? _rewriteResources(
    List<Map<String, dynamic>> resources,
    Map<String, String> mapping,
  ) {
    var changed = false;
    final updated = resources.map((resource) {
      final link = resource['externalLink']?.toString();
      if (link == null || !mapping.containsKey(link)) {
        return resource;
      }
      changed = true;
      return {...resource, 'externalLink': mapping[link]};
    }).toList();
    return changed ? updated : null;
  }

  /// 扫描没有被任何笔记引用的本地图片。
  Future<OrphanAttachmentReport> scanOrphans(List<Note> notes) async {
    final dir = await _imagesDir();
    final referenced = referencedLocalImageFiles(notes);
    final orphans = <String>[];
    var bytes = 0;

    await for (final entity in dir.list()) {
      if (entity is! File) {
        continue;
      }
      final name = entity.uri.pathSegments.last;
      if (referenced.contains(name)) {
        continue;
      }
      orphans.add(name);
      try {
        bytes += await entity.length();
      } on Object catch (_) {
        // 读不到大小就按 0 计，不影响清理
      }
    }

    orphans.sort();
    return OrphanAttachmentReport(fileNames: orphans, totalBytes: bytes);
  }

  /// 删除未被引用的本地图片，返回删除的文件数。
  Future<int> deleteOrphans(List<Note> notes) async {
    final dir = await _imagesDir();
    final report = await scanOrphans(notes);
    var deleted = 0;
    for (final name in report.fileNames) {
      try {
        final file = File('${dir.path}/$name');
        if (await file.exists()) {
          await file.delete();
          deleted++;
        }
      } on Object catch (e) {
        debugPrint('删除附件失败: $name - $e');
      }
    }
    return deleted;
  }
}
