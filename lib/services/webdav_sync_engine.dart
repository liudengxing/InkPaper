import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/services/database_service.dart';
import 'package:inkpaper/services/webdav_service.dart';
import 'package:inkpaper/utils/attachment_cache.dart';
import 'package:inkpaper/utils/attachment_maintenance.dart';
import 'package:inkpaper/utils/note_dedupe.dart';
import 'package:path_provider/path_provider.dart';

/// 同步状态
enum SyncStatus {
  idle, // 空闲
  syncing, // 同步中
  success, // 成功
  failed, // 失败
}

/// 同步统计信息
class SyncStats {
  // 错误数量

  const SyncStats({
    this.uploaded = 0,
    this.resourceUploaded = 0,
    this.resourceSkipped = 0,
    this.resourcesUnavailable = 0,
    this.downloaded = 0,
    this.deleted = 0,
    this.conflicts = 0,
    this.errors = 0,
    this.errorSamples = const [],
  });
  final int uploaded; // 上传数量
  final int resourceUploaded; // 图片等资源上传数量
  final int resourceSkipped; // 远端已存在、本次跳过的资源数量

  /// 本地没有副本、也没有可用的服务器来源，本次无法备份的附件数。
  ///
  /// 与 [errors] 区分：这是「本来就没下载过、服务器又没配置/不可达」，
  /// 不是上传失败。把它们混进错误数会让每次备份都显示「部分完成 + 错误 46」。
  final int resourcesUnavailable;
  final int downloaded; // 下载数量
  final int deleted; // 删除数量
  final int conflicts; // 冲突数量
  final int errors;

  /// 前若干条失败明细（资源路径 + 原因），用于在界面直接展示定位。
  final List<String> errorSamples;

  SyncStats copyWith({
    int? uploaded,
    int? resourceUploaded,
    int? resourceSkipped,
    int? resourcesUnavailable,
    int? downloaded,
    int? deleted,
    int? conflicts,
    int? errors,
    List<String>? errorSamples,
  }) =>
      SyncStats(
        uploaded: uploaded ?? this.uploaded,
        resourceUploaded: resourceUploaded ?? this.resourceUploaded,
        resourceSkipped: resourceSkipped ?? this.resourceSkipped,
        resourcesUnavailable:
            resourcesUnavailable ?? this.resourcesUnavailable,
        downloaded: downloaded ?? this.downloaded,
        deleted: deleted ?? this.deleted,
        conflicts: conflicts ?? this.conflicts,
        errors: errors ?? this.errors,
        errorSamples: errorSamples ?? this.errorSamples,
      );

  @override
  String toString() =>
      'SyncStats(上传: $uploaded, 资源上传: $resourceUploaded, 资源跳过: $resourceSkipped, 下载: $downloaded, 删除: $deleted, 冲突: $conflicts, 错误: $errors)';
}

class _WebDavResourceRecord {
  const _WebDavResourceRecord({
    required this.originalPath,
    required this.webdavPath,
    required this.filename,
    required this.source,
  });

  factory _WebDavResourceRecord.fromJson(Map<String, dynamic> json) =>
      _WebDavResourceRecord(
        originalPath: json['originalPath']?.toString() ?? '',
        webdavPath: json['webdavPath']?.toString() ?? '',
        filename: json['filename']?.toString() ?? '',
        source: json['source']?.toString() ?? 'unknown',
      );

  final String originalPath;
  final String webdavPath;
  final String filename;
  final String source;

  Map<String, dynamic> toJson() => {
        'originalPath': originalPath,
        'webdavPath': webdavPath,
        'filename': filename,
        'source': source,
      };

  bool get isValid => originalPath.isNotEmpty && webdavPath.isNotEmpty;
}

/// WebDAV 同步引擎
///
/// 使用单个 notes.json 文件同步所有笔记（类似导入导出格式）
class WebDavSyncEngine {
  WebDavSyncEngine(
    this._webdavService,
    this._databaseService, {
    String? memosBaseUrl,
    String? memosToken,
  })  : _memosBaseUrl = memosBaseUrl,
        _memosToken = memosToken;
  final WebDavService _webdavService;
  final DatabaseService _databaseService;

  /// Memos 服务器地址与 token，用于把服务端附件取回来一起备份。
  ///
  /// 不能只在构造时快照：登录发生在 WebDAV 引擎初始化之后是常态
  /// （启动顺序是 appConfig → loadWebDavConfig → loadUser），快照到空值
  /// 就会一直「未缓存 N」，直到重启 App 才可能恢复。备份/恢复前刷新一次。
  String? _memosBaseUrl;
  String? _memosToken;

  /// 刷新 Memos 凭据（登录、切换服务器后调用）。
  void updateMemosCredentials({String? baseUrl, String? token}) {
    if (baseUrl != null && baseUrl.isNotEmpty) {
      _memosBaseUrl = baseUrl.endsWith('/')
          ? baseUrl.substring(0, baseUrl.length - 1)
          : baseUrl;
    }
    if (token != null && token.isNotEmpty) {
      _memosToken = token;
    }
  }

  SyncStatus _status = SyncStatus.idle;
  SyncStats _stats = const SyncStats();
  String _syncMessage = '';

  /// 当前同步状态
  SyncStatus get status => _status;

  /// 当前同步统计
  SyncStats get stats => _stats;

  /// 同步消息
  String get syncMessage => _syncMessage;

  /// 初始化同步环境
  Future<void> initialize() async {
    try {
      final config = _webdavService.config;
      if (config == null) {
        throw Exception('WebDAV 配置未设置');
      }

      // 创建必要的文件夹结构
      final basePath = config.fullSyncPath;
      await _webdavService.createFolder(basePath);

      // 创建 resources 文件夹用于存储图片
      await _webdavService.createFolder('${basePath}resources/');
    } on Object {
      rethrow;
    }
  }

  /// 执行增量同步
  Future<SyncStats> sync() async {
    // 🔧 改进：检查并自动重置异常状态
    if (_status == SyncStatus.syncing) {
      throw Exception('同步正在进行中，请稍后再试');
    }

    _status = SyncStatus.syncing;
    _stats = const SyncStats();
    _syncMessage = '准备同步...';

    try {
      final config = _webdavService.config;
      if (config == null) {
        throw Exception('WebDAV 配置未设置');
      }

      final notesPath = '${config.fullSyncPath}notes.json';
      final now = DateTime.now();

      // 1. 获取本地所有笔记
      _syncMessage = '读取本地笔记...';
      final localNotes = await _databaseService.getNotes();

      // 2. 下载远程笔记数据
      _syncMessage = '下载远程备份...';
      var remoteNotes = <Note>[];

      try {
        final remoteContent = await _webdavService.downloadFile(notesPath);
        final remoteData = jsonDecode(remoteContent) as Map<String, dynamic>;
        if (remoteData['notes'] is List) {
          remoteNotes = (remoteData['notes'] as List<dynamic>)
              .map((json) => Note.fromJson(json as Map<String, dynamic>))
              .toList();
        }
      } on Object {
        // 远程文件不存在，首次同步
      }

      // 3. 🚀 增量同步：只处理有变化的笔记
      _syncMessage = '增量合并笔记...';
      final mergedNotes = await _mergeNotesIncremental(
        localNotes,
        remoteNotes,
      );

      // 4. 同步图片资源
      _syncMessage = '同步图片资源...';
      final resourceManifest = await _syncResources(mergedNotes);

      // 5. 上传合并后的笔记（全量，但标记了同步时间）
      _syncMessage = '上传到云端...';
      final backupData = {
        'version': '2.0', // 增量同步版本
        'lastSync': now.toIso8601String(),
        'noteCount': mergedNotes.length,
        'notes': mergedNotes.map((note) => note.toJson()).toList(),
        'resourceManifest':
            resourceManifest.map((record) => record.toJson()).toList(),
      };

      await _webdavService.uploadFile(notesPath, jsonEncode(backupData));

      _status = SyncStatus.success;
      _syncMessage = '同步完成';

      return _stats;
    } on Object catch (e) {
      _status = SyncStatus.failed;
      _syncMessage = '同步失败: $e';

      rethrow;
    } finally {
      // 🔧 大厂标准：无论成功失败，确保状态最终回到稳定态
      // 防止异常中断导致状态卡住
      if (_status == SyncStatus.syncing) {
        _status = SyncStatus.failed;
      }
    }
  }

  /// 🚀 增量合并本地和远程笔记
  Future<List<Note>> _mergeNotesIncremental(
    List<Note> localNotes,
    List<Note> remoteNotes,
  ) async {
    final mergedMap = <String, Note>{};
    var uploaded = 0;
    var downloaded = 0;
    var conflicts = 0;
    final now = DateTime.now();

    // 远程笔记映射：本地 id 与 remoteId 两套索引。
    // 匹配优先级 = remoteId（服务端 uid，跨设备/跨通道稳定）→ id（本地 uuid）→ 内容指纹。
    final remoteNoteMap = <String, Note>{};
    final remoteByRemoteId = <String, Note>{};
    for (final note in remoteNotes) {
      remoteNoteMap[note.id] = note;
      final remoteId = note.remoteId;
      if (remoteId != null && remoteId.isNotEmpty) {
        remoteByRemoteId[remoteId] = note;
      }
    }

    // 处理本地笔记
    for (final localNote in localNotes) {
      final localRemoteId = localNote.remoteId;
      // 匹配优先级：remoteId（服务端 uid，跨设备稳定）→ id（本地 uuid）
      final remoteNote = (localRemoteId != null && localRemoteId.isNotEmpty
              ? remoteByRemoteId[localRemoteId]
              : null) ??
          remoteNoteMap[localNote.id];

      if (remoteNote == null) {
        // 本地独有的笔记
        // 检查是否需要上传（本地修改时间 > 上次同步时间）
        if (localNote.lastSyncTime == null ||
            localNote.updatedAt.isAfter(localNote.lastSyncTime!)) {
          // 需要上传
          final syncedNote = localNote.copyWith(lastSyncTime: now);
          mergedMap[localNote.id] = syncedNote;
          await _databaseService.saveNote(syncedNote);
          uploaded++;
        } else {
          // 已同步过，保持不变
          mergedMap[localNote.id] = localNote;
        }
      } else {
        // 本地和远程都有的笔记，比较更新时间。
        // 以 lastSyncTime 为基准做三方判断：两边在上次同步之后都改过、且时间戳
        // 不同，说明这是一次真冲突 —— 下面无论选哪边，另一边的改动都会丢。
        final lastSync = localNote.lastSyncTime;
        final localChangedAfterSync =
            lastSync == null || localNote.updatedAt.isAfter(lastSync);
        final remoteChangedAfterSync =
            lastSync == null || remoteNote.updatedAt.isAfter(lastSync);
        if (localChangedAfterSync &&
            remoteChangedAfterSync &&
            !remoteNote.updatedAt.isAtSameMomentAs(localNote.updatedAt)) {
          conflicts++;
        }

        if (remoteNote.updatedAt.isAfter(localNote.updatedAt)) {
          // 远程更新，使用远程版本，但主键仍写回本地 id（否则库里会多出一条）
          final syncedNote = remoteNote.copyWith(
            id: localNote.id,
            remoteId: remoteNote.remoteId ?? localRemoteId ?? remoteNote.id,
            lastSyncTime: now,
          );
          mergedMap[localNote.id] = syncedNote;
          await _databaseService.saveNote(syncedNote);
          downloaded++;
        } else if (localNote.updatedAt.isAfter(remoteNote.updatedAt)) {
          // 本地更新，上传本地版本
          final syncedNote = localNote.copyWith(lastSyncTime: now);
          mergedMap[localNote.id] = syncedNote;
          await _databaseService.saveNote(syncedNote);
          uploaded++;
        } else {
          // 时间相同，标记为已同步
          final syncedNote = localNote.copyWith(lastSyncTime: now);
          mergedMap[localNote.id] = syncedNote;
          await _databaseService.saveNote(syncedNote);
        }
      }
    }

    // 处理远程独有的笔记（可能是其他设备新增的）
    //
    // 注意：远程「独有」只是 id 不在本地，不代表笔记是新的。
    // 同时开启 Memos 同步时，服务端会给同一条笔记重新签发 id（uid），
    // 云端 notes.json 里仍是上一次的本地 uuid —— 只按 id 匹配就会把同一条
    // 笔记再插一份，用户看到的就是「两份一样的笔记」。
    // 这里按「remoteId → 内容指纹」两级认领，命中就保留本地 id，
    // 只把远程的内容与本地元数据合并，不新增记录。
    final mergedByHash = groupNotesByContentHash(mergedMap.values);
    for (final remoteNote in remoteNotes) {
      // 同一条笔记可能已经被别的本地 id 认领过（remoteId 相同）
      final remoteId = remoteNote.remoteId;
      var alreadyMerged = mergedMap.containsKey(remoteNote.id);
      if (!alreadyMerged && remoteId != null && remoteId.isNotEmpty) {
        alreadyMerged =
            mergedMap.values.any((note) => note.remoteId == remoteId);
      }
      if (alreadyMerged) {
        continue;
      }

      final localTwin = findContentDuplicate(
        candidate: remoteNote,
        poolByHash: mergedByHash,
      );
      if (localTwin != null) {
        final reconciled = remoteNote.copyWith(
          id: localTwin.id,
          remoteId: remoteId ?? localTwin.remoteId,
          isPinned: localTwin.isPinned,
          annotations: localTwin.annotations,
          reminderTime: localTwin.reminderTime,
          relations: localTwin.relations.isNotEmpty
              ? localTwin.relations
              : remoteNote.relations,
          lastSyncTime: now,
        );
        mergedMap[localTwin.id] = reconciled;
        await _databaseService.saveNote(reconciled);

        // 更新索引，避免同一条被认领两次
        final bucket = mergedByHash[noteContentHash(remoteNote)];
        if (bucket != null) {
          bucket
            ..removeWhere((note) => note.id == localTwin.id)
            ..add(reconciled);
        }
        downloaded++;
        continue;
      }

      final syncedNote = remoteNote.copyWith(lastSyncTime: now);
      mergedMap[remoteNote.id] = syncedNote;
      await _databaseService.saveNote(syncedNote);
      downloaded++;
    }

    // 库内自去重：把「同内容、不同 id」的历史残留合并成一条并清掉副本。
    // 只对「内容完全一致 + 创建时间相差 ≤5 分钟」的组合生效。
    final deduped = dedupeDuplicateNotes(mergedMap.values.toList());
    for (final note in deduped.updatedNotes) {
      await _databaseService.saveNote(note);
    }
    for (final id in deduped.removedIds) {
      await _databaseService.deleteNote(id);
    }

    _stats = SyncStats(
      uploaded: uploaded,
      downloaded: downloaded,
      deleted: deduped.removedIds.length,
      conflicts: conflicts,
    );

    return deduped.notes;
  }

  /// 同步图片资源并返回可恢复的资源清单。
  Future<List<_WebDavResourceRecord>> _syncResources(List<Note> notes) async {
    final config = _webdavService.config;
    if (config == null) {
      return const [];
    }
    if (!config.backupImages) {
      return const [];
    }

    var resourceCount = 0;
    var skippedCount = 0;
    var unavailableCount = 0;
    var errorCount = 0;
    final errorSamples = <String>[];
    void recordError(String message) {
      errorCount++;
      if (errorSamples.length < 5) {
        errorSamples.add(message);
      }
      debugPrint('WebDAV 备份：$message');
    }

    // 附件本身拿不到（本机没缓存 + 没有可用的服务器来源）：不是备份失败，
    // 单独计数。否则每次备份都显示「部分完成 + 错误 46」，看起来像坏库。
    void recordUnavailable(String path, {required bool fromServer}) {
      unavailableCount++;
      if (unavailableCount <= 3) {
        debugPrint(
          fromServer
              ? 'WebDAV 备份：本地无副本且服务器取回失败，跳过 $path'
              : 'WebDAV 备份：本地无副本且未配置服务器，跳过 $path',
        );
      }
    }

    final manifest = <String, _WebDavResourceRecord>{};

    // 每次备份重新扫描本地图片目录，避免用到过期的文件索引
    _localImageNameIndex = null;

    // 先把远端 resources/ 目录列一次，后续靠内存集合判断「是否已备份过」。
    // 逐个调 exists() 会让每张图都 readDir 一次父目录，几十张图就能把备份
    // 卡住好几分钟（坚果云这类服务单次目录请求很慢）。
    final existingResourceNames = await _listResourceNames(
      '${config.fullSyncPath}resources/',
    );

    for (final note in notes) {
      if (note.resourceList.isEmpty) {
        continue;
      }

      for (final resource in note.resourceList) {
        try {
          final resourcePath = _resourcePathFromResource(resource);
          final filename = resource['filename']?.toString();
          if (resourcePath == null || resourcePath.isEmpty) {
            continue;
          }

          final canFetchFromServer = _memosResourceUrl(resourcePath) != null;
          final bytes = await _readImageBytes(resourcePath);
          if (bytes == null) {
            recordUnavailable(resourcePath, fromServer: canFetchFromServer);
            continue;
          }

          // 内容寻址命名：远端同名即同内容。同一张图不会因为附件 uid 变化，
          // 或从正文 Markdown 通道再次上传，而在服务器上存出第二份。
          final remoteName = contentAddressedAttachmentName(
            bytes,
            _extensionFromPath(filename ?? resourcePath),
          );
          final remotePath = '${config.fullSyncPath}resources/$remoteName';
          manifest[resourcePath] = _WebDavResourceRecord(
            originalPath: resourcePath,
            webdavPath: remotePath,
            filename: filename?.isNotEmpty ?? false ? filename! : remoteName,
            source: 'resourceList',
          );

          // 内容寻址后，远端同名即同内容，已经备份过就跳过
          if (existingResourceNames.contains(remoteName)) {
            skippedCount++;
            continue;
          }

          await _webdavService.uploadBinaryFile(remotePath, bytes);
          existingResourceNames.add(remoteName);
          resourceCount++;
        } on Object catch (e) {
          recordError('资源上传失败: $e');
        }
      }
    }

    for (final note in notes) {
      for (final imagePath in _extractMarkdownImagePaths(note.content)) {
        try {
          final canFetchFromServer =
              imagePath.startsWith('http') ||
              _memosResourceUrl(imagePath) != null;
          final bytes = await _readImageBytes(imagePath);
          if (bytes == null) {
            recordUnavailable(imagePath, fromServer: canFetchFromServer);
            continue;
          }

          // 与 resourceList 通道共用同一套内容寻址命名：同内容的图只存一份
          final remoteName = contentAddressedAttachmentName(
            bytes,
            _extensionFromPath(imagePath),
          );
          final remotePath = '${config.fullSyncPath}resources/$remoteName';
          manifest.putIfAbsent(
            imagePath,
            () => _WebDavResourceRecord(
              originalPath: imagePath,
              webdavPath: remotePath,
              filename: remoteName,
              source: 'markdown',
            ),
          );

          if (existingResourceNames.contains(remoteName)) {
            skippedCount++;
            continue;
          }

          await _webdavService.uploadBinaryFile(remotePath, bytes);
          existingResourceNames.add(remoteName);
          resourceCount++;
        } on Object catch (e) {
          recordError('正文图片上传失败 $imagePath: $e');
        }
      }
    }

    // 更新统计
    _stats = _stats.copyWith(
      resourceUploaded: _stats.resourceUploaded + resourceCount,
      resourceSkipped: _stats.resourceSkipped + skippedCount,
      resourcesUnavailable: _stats.resourcesUnavailable + unavailableCount,
      errors: _stats.errors + errorCount,
      errorSamples: [..._stats.errorSamples, ...errorSamples],
    );

    return manifest.values.where((record) => record.isValid).toList();
  }

  /// 列出远端资源目录里的文件名。
  ///
  /// 目录不存在（首次备份）或请求失败时返回空集合，后续上传会按需创建目录。
  Future<Set<String>> _listResourceNames(String resourcesPath) async {
    try {
      final files = await _webdavService.listFiles(resourcesPath);
      return files.map((file) => file.name).whereType<String>().toSet();
    } on Object catch (e) {
      debugPrint('WebDAV 备份：读取资源目录失败，按全新备份处理: $e');
      return <String>{};
    }
  }

  List<String> _extractMarkdownImagePaths(String content) {
    final regex = RegExp(r'!\[[^\]]*\]\(([^)]+)\)');
    return regex
        .allMatches(content)
        .map((match) => match.group(1)?.trim() ?? '')
        .where((path) => path.isNotEmpty)
        .toList();
  }

  Future<List<int>?> _readImageBytes(String imagePath) async {
    if (imagePath.startsWith('file://')) {
      final file = File(imagePath.replaceFirst('file://', ''));
      if (!await file.exists()) {
        return null;
      }
      return file.readAsBytes();
    }

    if (_isAppRelativeImagePath(imagePath)) {
      final appDir = await getApplicationDocumentsDirectory();
      final file = File('${appDir.path}/$imagePath');
      if (!await file.exists()) {
        return null;
      }
      return file.readAsBytes();
    }

    // 服务端附件先查本地离线副本（数据维护里缓存过、或上次恢复落地过）。
    // 没登录服务器 / 服务器不可达时，这是把图带进备份的唯一来源；漏掉这一步
    // 会导致备份静默丢图，换设备恢复后图片全裂。
    if (isRemoteAttachmentPath(imagePath)) {
      final cached = await _readCachedAttachment(imagePath);
      if (cached != null) {
        return cached;
      }
      // 路径形态不同导致缓存名对不上时，按文件名兜底命中同一张图
      final byName = await _readLocalImageByFileName(imagePath);
      if (byName != null) {
        return byName;
      }
    }

    if (imagePath.startsWith('http://') || imagePath.startsWith('https://')) {
      // 指向本服务器的绝对 URL 是私有附件，必须带 token，否则 401。
      return _downloadImage(
        imagePath,
        authorized: isServerBackedImagePath(imagePath),
      );
    }

    if (_isMemosResourcePath(imagePath)) {
      final fullUrl = _memosResourceUrl(imagePath);
      if (fullUrl == null) {
        return null;
      }
      final bytes = await _downloadImage(fullUrl, authorized: true);
      // 顺手落到附件缓存：下次离线备份也能直接读到，不用再跑一趟服务器。
      if (bytes != null) {
        await _cacheAttachmentBytes(imagePath, bytes);
      }
      return bytes;
    }

    return null;
  }

  Future<List<int>?> _readCachedAttachment(String remotePath) async {
    await AttachmentCache.instance.prepare();
    final cached = AttachmentCache.instance.fileFor(remotePath);
    if (cached == null) {
      return null;
    }
    try {
      return await cached.readAsBytes();
    } on Object {
      return null;
    }
  }

  /// 本机 images/ 目录的「文件名 → 绝对路径」索引，只在首次用到时构建。
  Map<String, String>? _localImageNameIndex;

  /// 按文件名在本机 images/ 目录里找同一张图。
  ///
  /// 附件缓存按「整条路径的 sha1」命名，同一张图在正文（`/file/attachments/...`）
  /// 和资源列表 externalLink 里可能形态不同，算出的缓存名对不上——只按路径查
  /// 会误判成「本机没有」，然后去网络重新下载，慢网下直接超时失败。
  /// 同一附件的文件名是稳定的，这里按文件名兜一次底。
  Future<List<int>?> _readLocalImageByFileName(String remotePath) async {
    final clean = remotePath.split('?').first.split('#').first;
    final name = clean.split('/').last;
    if (name.isEmpty) {
      return null;
    }

    var index = _localImageNameIndex;
    if (index == null) {
      index = <String, String>{};
      try {
        final appDir = await getApplicationDocumentsDirectory();
        final dir = Directory('${appDir.path}/images');
        if (await dir.exists()) {
          await for (final entity in dir.list()) {
            if (entity is File) {
              final fileName = entity.path.split('/').last;
              index.putIfAbsent(fileName, () => entity.path);
              // 缓存文件是 `memos_<原名>_<8位hash>.<ext>`，还要用归一化名建一份索引，
              // 否则远端 `image_123.jpg` 永远匹配不到本地 `memos_image_123_ab12cd34.jpg`。
              index.putIfAbsent(
                canonicalAttachmentKey(fileName),
                () => entity.path,
              );
            }
          }
        }
      } on Object catch (e) {
        debugPrint('WebDAV 备份：扫描本地图片目录失败 $e');
      }
      _localImageNameIndex = index;
    }

    // 先按原文件名命中；命不中再用归一化键（抹掉 `memos_` 前缀与短哈希）兜底，
    // 让远端 `image_123.jpg` 命中本地 `memos_image_123_ab12cd34.jpg`。
    final path = index[name] ?? index[canonicalAttachmentKey(name)];
    if (path == null) {
      return null;
    }
    try {
      return await File(path).readAsBytes();
    } on Object {
      return null;
    }
  }

  /// 把刚从服务器取回的附件写进 `<documents>/images/`，命名与渲染层一致
  /// （[localFileNameForAttachment]），这样之后的离线备份/离线看图都能命中。
  Future<void> _cacheAttachmentBytes(String remotePath, List<int> bytes) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final dir = Directory('${appDir.path}/images');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final file = File(
        '${dir.path}/${localFileNameForAttachment(remotePath)}',
      );
      if (!await file.exists()) {
        await file.writeAsBytes(bytes, flush: true);
        AttachmentCache.instance.invalidate();
        _localImageNameIndex = null;
      }
    } on Object catch (e) {
      debugPrint('WebDAV 备份：缓存附件失败 $remotePath [$e]');
    }
  }

  Future<List<int>?> _downloadImage(
    String url, {
    bool authorized = false,
  }) async {
    final headers = <String, String>{};
    final token = _memosToken;
    if (authorized && token != null && token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }
    try {
      // 单张图最长等 12 秒：服务器不可达时不能让整个备份挂死在这里。
      final response = await http
          .get(Uri.parse(url), headers: headers)
          .timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) {
        debugPrint(
          'WebDAV 备份：下载图片返回 ${response.statusCode} $url',
        );
        return null;
      }
      return response.bodyBytes;
    } on Object catch (e) {
      debugPrint('WebDAV 备份：下载图片失败 $url [$e]');
      return null;
    }
  }

  bool _isMemosResourcePath(String path) =>
      path.startsWith('/o/r/') ||
      path.startsWith('/file/') ||
      path.startsWith('attachments/') ||
      path.startsWith('/resource/') ||
      path.startsWith('/api/v1/attachments/') ||
      path.startsWith('/api/v1/resource/');

  String? _memosResourceUrl(String path) {
    final baseUrl = _memosBaseUrl;
    if (baseUrl == null || baseUrl.isEmpty) {
      return null;
    }
    if (path.startsWith('attachments/')) {
      return '$baseUrl/file/$path';
    }
    return '$baseUrl$path';
  }

  bool _isAppRelativeImagePath(String path) =>
      path.startsWith('images/') || path.startsWith('webdav_images/');

  String _extensionFromPath(String path) {
    final cleanPath = path.split('?').first.split('#').first;
    final name = cleanPath.split('/').last;
    final dot = name.lastIndexOf('.');
    if (dot >= 0 && dot < name.length - 1) {
      return _sanitizeFileComponent(name.substring(dot + 1)).toLowerCase();
    }
    return 'jpg';
  }

  String _sanitizeFileComponent(String value) {
    final safe = value.replaceAll(RegExp('[^a-zA-Z0-9._-]'), '_');
    return safe.isEmpty ? 'image' : safe;
  }

  String? _resourcePathFromResource(Map<String, dynamic> resource) {
    if (_isVideoResource(resource)) {
      return null;
    }

    final externalLink = resource['externalLink']?.toString();
    if (externalLink != null && externalLink.isNotEmpty) {
      return externalLink;
    }

    final name = resource['name']?.toString();
    final filename = resource['filename']?.toString();
    if (name != null &&
        name.startsWith('attachments/') &&
        filename != null &&
        filename.isNotEmpty) {
      return '/file/$name/$filename';
    }

    final uid = resource['uid']?.toString() ?? name?.split('/').last;
    if (uid != null && uid.isNotEmpty) {
      return '/o/r/$uid';
    }

    final id = resource['id']?.toString();
    if (id != null && id.isNotEmpty) {
      return '/o/r/$id';
    }

    return null;
  }

  List<String> _resourcePathCandidates(Map<String, dynamic> resource) {
    final candidates = <String>[];
    void add(String? value) {
      if (value != null && value.isNotEmpty && !candidates.contains(value)) {
        candidates.add(value);
      }
    }

    add(resource['externalLink']?.toString());
    final name = resource['name']?.toString();
    final filename = resource['filename']?.toString();
    if (name != null &&
        name.startsWith('attachments/') &&
        filename != null &&
        filename.isNotEmpty) {
      add('/file/$name/$filename');
      add(name);
    }

    final uid = resource['uid']?.toString() ?? name?.split('/').last;
    if (uid != null && uid.isNotEmpty) {
      add('/o/r/$uid');
    }

    final id = resource['id']?.toString();
    if (id != null && id.isNotEmpty) {
      add('/o/r/$id');
    }

    return candidates;
  }

  bool _isVideoResource(Map<String, dynamic> resource) {
    final type = resource['type']?.toString().toLowerCase();
    final filename = resource['filename']?.toString().toLowerCase();
    if (type != null && type.startsWith('video')) {
      return true;
    }
    if (filename == null) {
      return false;
    }
    return filename.endsWith('.mov') ||
        filename.endsWith('.mp4') ||
        filename.endsWith('.avi') ||
        filename.endsWith('.mkv') ||
        filename.endsWith('.webm') ||
        filename.endsWith('.flv');
  }

  List<_WebDavResourceRecord> _parseResourceManifest(rawManifest) {
    if (rawManifest is! List) {
      return const [];
    }

    return rawManifest
        .whereType<Map>()
        .map(
          (item) => _WebDavResourceRecord.fromJson(
            Map<String, dynamic>.from(item),
          ),
        )
        .where((record) => record.isValid)
        .toList();
  }

  Future<Map<String, String>> _restoreResources(
    List<_WebDavResourceRecord> manifest, {
    void Function(double progress, String message)? onProgress,
  }) async {
    final appDir = await getApplicationDocumentsDirectory();
    final imagesDir = Directory('${appDir.path}/images');
    if (!await imagesDir.exists()) {
      await imagesDir.create(recursive: true);
    }

    final restoredPathMap = <String, String>{};
    var errorCount = 0;

    for (var i = 0; i < manifest.length; i++) {
      final record = manifest[i];
      try {
        final action = restoreActionFor(record.originalPath);
        if (action == RestoreAttachmentAction.skipExternal) {
          // 外链图（非本服务器附件）保持 URL 原样，不落地成本地路径，
          // 否则正文会和其它设备不一致。
          continue;
        }
        if (action == RestoreAttachmentAction.cacheServerCopy) {
          // 服务器上的图：正文保持 `/file/attachments/...` 不变，只把二进制
          // 落到附件缓存目录（`images/memos_*`）。渲染时 AttachmentCache 优先
          // 读本地副本，服务器不可达也能看图；正文与服务端保持一致，
          // 多设备同步不会互相污染。
          final cacheFile = File(
            '${imagesDir.path}/${localFileNameForAttachment(record.originalPath)}',
          );
          if (!await cacheFile.exists()) {
            final bytes =
                await _webdavService.downloadBinaryFile(record.webdavPath);
            await cacheFile.writeAsBytes(bytes, flush: true);
          }
        } else {
          final bytes =
              await _webdavService.downloadBinaryFile(record.webdavPath);
          final localName = _restoredLocalFileName(record, i);
          final localFile = File('${imagesDir.path}/$localName');
          await localFile.writeAsBytes(bytes, flush: true);
          restoredPathMap[record.originalPath] = 'file://${localFile.path}';
        }
      } on Object {
        errorCount++;
      }

      onProgress?.call(
        manifest.isEmpty ? 1 : (i + 1) / manifest.length,
        '恢复图片 ${i + 1}/${manifest.length}',
      );
    }

    if (errorCount > 0) {
      _stats = _stats.copyWith(errors: _stats.errors + errorCount);
    }
    return restoredPathMap;
  }

  String _restoredLocalFileName(_WebDavResourceRecord record, int index) {
    final sourceName =
        record.filename.isNotEmpty ? record.filename : record.webdavPath;
    final ext = _extensionFromPath(sourceName);
    final digest = sha1
        .convert(utf8.encode('${record.originalPath}:${record.webdavPath}'))
        .toString()
        .substring(0, 12);
    final base = _sanitizeFileComponent(
      sourceName.split('/').last.split('.').first,
    );
    return 'webdav_${base}_${digest}_$index.$ext';
  }

  /// 笔记是否引用了需要服务器才能取到的附件。
  bool _hasServerBackedImageRef(Note note) {
    for (final ref in extractImageRefs(note.content)) {
      if (isServerBackedImagePath(ref)) {
        return true;
      }
    }
    for (final resource in note.resourceList) {
      final link = resource['externalLink']?.toString() ?? '';
      if (isServerBackedImagePath(link)) {
        return true;
      }
    }
    return false;
  }

  Note _rewriteNoteImagePaths(Note note, Map<String, String> restoredPathMap) {
    // 服务端图片 / 外链图永远不改成 file://：正文要和服务器一致，否则下一次
    // 同步会把本地路径推回服务端，其它设备全变裂图。判断集中在
    // `restoreActionFor`，只有真本地图才允许改写。
    final content = rewriteMarkdownImagePaths(note.content, restoredPathMap);

    var resourceChanged = false;
    final resourceList = note.resourceList.map((resource) {
      final updated = Map<String, dynamic>.from(resource);
      for (final candidate in _resourcePathCandidates(resource)) {
        if (restoreActionFor(candidate) !=
            RestoreAttachmentAction.materialize) {
          continue;
        }
        final localPath = restoredPathMap[candidate];
        if (localPath == null) {
          continue;
        }
        updated['externalLink'] = localPath;
        resourceChanged = true;
        break;
      }
      return updated;
    }).toList();

    if (content == note.content && !resourceChanged) {
      return note;
    }

    return note.copyWith(
      content: content,
      resourceList: resourceChanged ? resourceList : note.resourceList,
    );
  }

  /// 从 WebDAV 恢复（单向下载，完全覆盖本地）
  ///
  /// [onProgress] 进度回调：(progress, message) => void
  /// - progress: 0.0 ~ 1.0 的进度值
  /// - message: 当前操作描述
  Future<SyncStats> restore({
    void Function(double progress, String message)? onProgress,
  }) async {
    // 🔧 改进：检查并自动重置异常状态
    if (_status == SyncStatus.syncing) {
      throw Exception('恢复正在进行中，请稍后再试');
    }

    _status = SyncStatus.syncing;
    _stats = const SyncStats();
    _syncMessage = '准备恢复...';
    onProgress?.call(0, '准备恢复...');

    try {
      final config = _webdavService.config;
      if (config == null) {
        throw Exception('WebDAV 配置未设置');
      }

      final notesPath = '${config.fullSyncPath}notes.json';

      // 1. 下载远程笔记 (0% ~ 50%)
      _syncMessage = '下载远程备份...';
      onProgress?.call(0.1, '检查远程备份...');
      var remoteNotes = <Note>[];
      var resourceManifest = <_WebDavResourceRecord>[];
      try {
        // 先检查文件是否存在
        final exists = await _webdavService.exists(notesPath);
        if (!exists) {
          throw Exception('远程备份文件不存在，请先执行"立即备份"创建备份');
        }

        onProgress?.call(0.2, '下载备份文件...');
        final remoteContent = await _webdavService.downloadFile(notesPath);
        if (remoteContent.isEmpty) {
          throw Exception('远程备份文件为空');
        }

        try {
          onProgress?.call(0.3, '解析备份数据...');
          final remoteData = jsonDecode(remoteContent);
          if (remoteData is! Map) {
            throw Exception('备份文件格式错误：不是有效的JSON对象');
          }

          if (remoteData['notes'] is List) {
            remoteNotes = (remoteData['notes'] as List)
                .map((json) => Note.fromJson(json))
                .toList();
          } else {
            throw Exception('备份文件格式错误：缺少notes字段或格式不正确');
          }
          resourceManifest = _parseResourceManifest(
            remoteData['resourceManifest'],
          );
          onProgress?.call(0.5, '备份数据解析完成，共 ${remoteNotes.length} 条笔记');
        } on Object catch (e) {
          throw Exception('解析备份文件失败: $e');
        }
      } on Object {
        rethrow;
      }

      if (remoteNotes.isEmpty) {
        throw Exception('远程备份为空，已取消恢复，避免覆盖本地数据');
      }

      // 2. 恢复图片资源并重写路径（兼容旧备份：没有 manifest 时跳过）
      if (config.backupImages && resourceManifest.isNotEmpty) {
        _syncMessage = '恢复图片资源...';
        onProgress?.call(0.55, '恢复图片资源...');
        final restoredPathMap = await _restoreResources(
          resourceManifest,
          onProgress: (progress, message) {
            onProgress?.call(0.55 + progress * 0.2, message);
          },
        );
        if (restoredPathMap.isNotEmpty) {
          remoteNotes = remoteNotes
              .map((note) => _rewriteNoteImagePaths(note, restoredPathMap))
              .toList();
        }
      } else if (remoteNotes.any(_hasServerBackedImageRef)) {
        // 备份里没有图片资源：旧备份、或备份时既没本地缓存也没登录服务器。
        // 正文里的服务端路径在本机无副本，未登录时这些图必然裂。必须明说，
        // 否则用户只会看到「恢复完成」和一堆裂图。
        _syncMessage = '备份中不含图片资源，图片可能无法显示';
        onProgress?.call(0.55, '备份中不含图片资源，图片可能无法显示');
      }

      // 3. 覆盖前保存本地应急备份，避免误操作造成不可恢复的数据损失。
      onProgress?.call(0.73, '保存本地应急备份...');
      await _uploadRestoreSafetyBackup();

      // 4. 保存所有远程笔记到本地（覆盖）(75% ~ 100%)
      _syncMessage = '恢复笔记到本地...';
      final totalNotes = remoteNotes.length;
      onProgress?.call(0.75, '写入本地数据库...');
      await _databaseService.replaceAllNotes(remoteNotes);
      // 附件缓存刚被写入/替换，让渲染层的查表重新落盘一次
      AttachmentCache.instance.invalidate();
      onProgress?.call(1, '恢复完成，共 $totalNotes 条笔记');

      _stats = _stats.copyWith(downloaded: remoteNotes.length);

      _status = SyncStatus.success;
      _syncMessage = '恢复完成';
      onProgress?.call(1, '恢复完成');

      return _stats;
    } on Object catch (e) {
      _status = SyncStatus.failed;
      _syncMessage = '恢复失败: $e';

      rethrow;
    } finally {
      // 🔧 大厂标准：无论成功失败，确保状态最终回到稳定态
      // 防止异常中断导致状态卡住
      if (_status == SyncStatus.syncing) {
        _status = SyncStatus.failed;
      }
    }
  }

  Future<void> _uploadRestoreSafetyBackup() async {
    final config = _webdavService.config;
    if (config == null) {
      return;
    }

    final localNotes = await _databaseService.getNotes();
    if (localNotes.isEmpty) {
      return;
    }

    final emergencyPath = '${config.fullSyncPath}emergency/';
    final timestamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    final backupPath = '${emergencyPath}local-before-restore-$timestamp.json';
    final payload = {
      'version': '2.0',
      'type': 'local-before-webdav-restore',
      'createdAt': DateTime.now().toIso8601String(),
      'noteCount': localNotes.length,
      'notes': localNotes.map((note) => note.toJson()).toList(),
    };

    try {
      await _webdavService.createFolder(emergencyPath);
      await _webdavService.uploadFile(backupPath, jsonEncode(payload));
    } on Object {
      throw Exception('恢复前本地应急备份失败，已取消恢复以保护本地数据');
    }
  }

  /// 执行完整备份（单向上传）
  ///
  /// [onProgress] 进度回调：(progress, message) => void
  /// - progress: 0.0 ~ 1.0 的进度值
  /// - message: 当前操作描述
  Future<SyncStats> backup({
    void Function(double progress, String message)? onProgress,
  }) async {
    // 🔧 改进：检查并自动重置异常状态
    if (_status == SyncStatus.syncing) {
      throw Exception('备份正在进行中，请稍后再试');
    }

    _status = SyncStatus.syncing;
    _stats = const SyncStats();
    _syncMessage = '准备备份...';
    onProgress?.call(0, '准备备份...');

    try {
      final config = _webdavService.config;
      if (config == null) {
        throw Exception('WebDAV 配置未设置');
      }

      final notesPath = '${config.fullSyncPath}notes.json';

      // 1. 获取本地所有笔记 (0% ~ 20%)
      _syncMessage = '读取本地笔记...';
      onProgress?.call(0.1, '读取本地笔记...');
      final localNotes = await _databaseService.getNotes();
      onProgress?.call(0.2, '读取完成，共 ${localNotes.length} 条笔记');

      // 2. 备份图片资源 (20% ~ 60%)
      _syncMessage = '备份图片资源...';
      onProgress?.call(0.3, '开始备份图片资源...');
      final resourceManifest = await _syncResources(localNotes);
      onProgress?.call(0.6, '图片资源备份完成');

      // 3. 上传笔记数据 (60% ~ 100%)
      _syncMessage = '上传笔记数据...';
      onProgress?.call(0.7, '打包笔记数据...');
      final backupData = {
        'version': '2.0',
        'lastBackup': DateTime.now().toIso8601String(),
        'noteCount': localNotes.length,
        'notes': localNotes.map((note) => note.toJson()).toList(),
        'resourceManifest':
            resourceManifest.map((record) => record.toJson()).toList(),
      };

      onProgress?.call(0.8, '上传备份文件...');
      await _webdavService.uploadFile(notesPath, jsonEncode(backupData));

      _stats = _stats.copyWith(uploaded: _stats.uploaded + localNotes.length);

      _status = SyncStatus.success;
      _syncMessage = '备份完成';
      onProgress?.call(1, '备份完成');

      return _stats;
    } on Object catch (e) {
      _status = SyncStatus.failed;
      _syncMessage = '备份失败: $e';

      rethrow;
    } finally {
      // 🔧 大厂标准：无论成功失败，确保状态最终回到稳定态
      // 防止异常中断导致状态卡住
      if (_status == SyncStatus.syncing) {
        _status = SyncStatus.failed;
      }
    }
  }

  /// 重置同步状态
  void reset() {
    _status = SyncStatus.idle;
    _stats = const SyncStats();
    _syncMessage = '';
  }
}
