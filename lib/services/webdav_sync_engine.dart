import 'dart:async';
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
import 'package:inkpaper/utils/media_paths.dart';
import 'package:inkpaper/utils/memos_content_helper.dart';
import 'package:inkpaper/utils/note_dedupe.dart';
import 'package:inkpaper/utils/thumb_cache.dart';
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
    this.videoUploaded = 0,
    this.videoSkipped = 0,
    this.videoRestored = 0,
    this.resourceRestored = 0,
    this.videoDeferred = 0,
  });
  final int uploaded; // 上传数量
  final int resourceUploaded; // 图片等资源上传数量
  final int resourceSkipped; // 远端已存在、本次跳过的资源数量

  /// 其中属于视频的部分（已包含在 [resourceUploaded] / [resourceSkipped] 里）。
  final int videoUploaded;
  final int videoSkipped;

  /// 本次恢复落地的视频数。
  final int videoRestored;

  /// 本次恢复落地的附件总数（图片 + 视频）。
  final int resourceRestored;

  /// 用户选择「不恢复视频」而跳过的视频数。
  final int videoDeferred;

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
    int? videoUploaded,
    int? videoSkipped,
    int? videoRestored,
    int? resourceRestored,
    int? videoDeferred,
  }) =>
      SyncStats(
        uploaded: uploaded ?? this.uploaded,
        resourceUploaded: resourceUploaded ?? this.resourceUploaded,
        resourceSkipped: resourceSkipped ?? this.resourceSkipped,
        resourcesUnavailable: resourcesUnavailable ?? this.resourcesUnavailable,
        downloaded: downloaded ?? this.downloaded,
        deleted: deleted ?? this.deleted,
        conflicts: conflicts ?? this.conflicts,
        errors: errors ?? this.errors,
        errorSamples: errorSamples ?? this.errorSamples,
        videoUploaded: videoUploaded ?? this.videoUploaded,
        videoSkipped: videoSkipped ?? this.videoSkipped,
        videoRestored: videoRestored ?? this.videoRestored,
        resourceRestored: resourceRestored ?? this.resourceRestored,
        videoDeferred: videoDeferred ?? this.videoDeferred,
      );

  @override
  String toString() =>
      'SyncStats(上传: $uploaded, 资源上传: $resourceUploaded, 资源跳过: $resourceSkipped, '
      '视频上传: $videoUploaded, 视频跳过: $videoSkipped, 下载: $downloaded, '
      '删除: $deleted, 冲突: $conflicts, 错误: $errors)';
}

class _WebDavResourceRecord {
  const _WebDavResourceRecord({
    required this.originalPath,
    required this.webdavPath,
    required this.filename,
    required this.source,
    this.isVideo = false,
    this.sizeBytes = 0,
  });

  factory _WebDavResourceRecord.fromJson(Map<String, dynamic> json) =>
      _WebDavResourceRecord(
        originalPath: json['originalPath']?.toString() ?? '',
        webdavPath: json['webdavPath']?.toString() ?? '',
        filename: json['filename']?.toString() ?? '',
        source: json['source']?.toString() ?? 'unknown',
        // 旧备份没有这两个字段：isVideo 留 false，靠路径/文件名二次判定兜底，
        // sizeBytes 为 0 时界面不展示体积。
        isVideo: json['isVideo'] as bool? ?? false,
        sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
      );

  final String originalPath;
  final String webdavPath;
  final String filename;
  final String source;

  /// 是否视频。旧备份没有该字段，判定时还要回退到扩展名。
  final bool isVideo;

  /// 文件字节数；0 表示旧备份未记录。
  final int sizeBytes;

  Map<String, dynamic> toJson() => {
        'originalPath': originalPath,
        'webdavPath': webdavPath,
        'filename': filename,
        'source': source,
        'isVideo': isVideo,
        'sizeBytes': sizeBytes,
      };

  bool get isValid => originalPath.isNotEmpty && webdavPath.isNotEmpty;

  /// 是否是视频资源：新记录看标记，旧记录按扩展名兜底。
  bool get videoLike => MediaPaths.isVideoAttachment(
        path: originalPath,
        filename: filename,
        markedVideo: isVideo,
      );
}

/// 一次备份里资源的来源与体积。
class _LocalMediaFile {
  const _LocalMediaFile(this.file, {this.temporary = false});

  final File file;

  /// 是否本次为上传临时落盘、用完要删。
  final bool temporary;
}

/// 正文里的一条媒体引用（图片或视频）。
class _MarkdownMedia {
  const _MarkdownMedia({required this.path, required this.isVideo});

  final String path;
  final bool isVideo;
}

/// 收集流式哈希的结果。
///
/// `sha1.startChunkedConversion` 需要一个 `Sink<Digest>` 接住最终摘要，
/// crypto 包自带的 `AccumulatorSink` 在 package:convert 里，为二十行代码
/// 新增一个直接依赖不划算。
class _DigestCollector implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) {
    value = data;
  }

  @override
  void close() {}
}

/// 资源同步的计数器，避免在 `_syncResources` 里堆十几个局部变量。
class _ResourceSyncCounters {
  int uploaded = 0;
  int skipped = 0;
  int unavailable = 0;
  int errors = 0;
  int videoUploaded = 0;
  int videoSkipped = 0;
  final List<String> errorSamples = <String>[];

  void recordUpload({required bool isVideo}) {
    uploaded++;
    if (isVideo) {
      videoUploaded++;
    }
  }

  void recordSkip({required bool isVideo}) {
    skipped++;
    if (isVideo) {
      videoSkipped++;
    }
  }

  void recordUnavailable({
    required String path,
    required bool fromServer,
    required bool isVideo,
  }) {
    unavailable++;
    if (unavailable <= 3) {
      debugPrint(
        fromServer
            ? 'WebDAV 备份：本地无副本且服务器取回失败，跳过 $path'
            : 'WebDAV 备份：本地无副本且未配置服务器，跳过 $path',
      );
    }
    if (isVideo) {
      debugPrint('WebDAV 备份：视频未备份 $path');
    }
  }

  void recordError(String message) {
    errors++;
    if (errorSamples.length < 5) {
      errorSamples.add(message);
    }
    debugPrint('WebDAV 备份：$message');
  }
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

  /// 同步图片与视频资源，返回可恢复的资源清单。
  ///
  /// 视频和图片走同一条内容寻址通道：本地有副本就流式算 sha1，远端同名即
  /// 同内容 → 本次直接跳过。因此「超过 Memos 32MB 上限、传不上服务器」的
  /// 视频照样能进 WebDAV 备份，第二次备份也不会重传。
  Future<List<_WebDavResourceRecord>> _syncResources(List<Note> notes) async {
    final config = _webdavService.config;
    if (config == null) {
      return const [];
    }
    if (!config.backupImages) {
      return const [];
    }

    final resourcesPath = '${config.fullSyncPath}resources/';
    final counters = _ResourceSyncCounters();
    final manifest = <String, _WebDavResourceRecord>{};

    // 每次备份重新扫描本地图片目录，避免用到过期的文件索引
    _localImageNameIndex = null;
    _digestCache.clear();

    // 先把远端 resources/ 目录列一次，后续靠内存集合判断「是否已备份过」。
    // 逐个调 exists() 会让每张图都 readDir 一次父目录，几十张图就能把备份
    // 卡住好几分钟（坚果云这类服务单次目录请求很慢）。
    final existingResourceNames = await _listResourceNames(resourcesPath);

    // 服务端资源路径（`/o/r/<uid>`）没有扩展名，靠 resourceList 里的真实
    // 文件名把扩展名补齐：否则同一段 mov 视频会因正文通道猜成 mp4 而存成两份。
    final resourceFileNames = _resourceFileNameIndex(notes);

    for (final note in notes) {
      for (final resource in note.resourceList) {
        final resourcePath = _resourcePathFromResource(resource);
        if (resourcePath == null || resourcePath.isEmpty) {
          continue;
        }
        final record = await _backupMedia(
          originalPath: resourcePath,
          filename: resource['filename']?.toString(),
          isVideo: MemosContentHelper.isVideoResource(resource) ||
              MediaPaths.isVideoPath(resourcePath),
          source: 'resourceList',
          resourcesPath: resourcesPath,
          existingNames: existingResourceNames,
          counters: counters,
        );
        if (record != null) {
          manifest.putIfAbsent(resourcePath, () => record);
        }
      }

      for (final media in _extractMarkdownMedia(note.content)) {
        final record = await _backupMedia(
          originalPath: media.path,
          filename: resourceFileNames[media.path],
          isVideo: media.isVideo,
          source: 'markdown',
          resourcesPath: resourcesPath,
          existingNames: existingResourceNames,
          counters: counters,
        );
        if (record != null) {
          manifest.putIfAbsent(media.path, () => record);
        }
      }
    }

    // 更新统计
    _stats = _stats.copyWith(
      resourceUploaded: _stats.resourceUploaded + counters.uploaded,
      resourceSkipped: _stats.resourceSkipped + counters.skipped,
      resourcesUnavailable: _stats.resourcesUnavailable + counters.unavailable,
      errors: _stats.errors + counters.errors,
      errorSamples: [..._stats.errorSamples, ...counters.errorSamples],
      videoUploaded: _stats.videoUploaded + counters.videoUploaded,
      videoSkipped: _stats.videoSkipped + counters.videoSkipped,
    );

    return manifest.values.where((record) => record.isValid).toList();
  }

  /// 备份单个媒体（图片或视频）并返回它在恢复清单里的记录。
  ///
  /// 全程按「文件」处理而不是「字节」：视频几百 MB，整块读进内存会直接把
  /// App 撑崩。内容寻址名也用流式 sha1 计算，和 [contentAddressedAttachmentName]
  /// 产出的名字一致，所以图片与视频在远端是同一个命名空间、同一套去重。
  Future<_WebDavResourceRecord?> _backupMedia({
    required String originalPath,
    required String? filename,
    required bool isVideo,
    required String source,
    required String resourcesPath,
    required Set<String> existingNames,
    required _ResourceSyncCounters counters,
  }) async {
    _LocalMediaFile? local;
    try {
      local = await _materializeMedia(originalPath, isVideo: isVideo);
      if (local == null) {
        counters.recordUnavailable(
          path: originalPath,
          fromServer: _memosResourceUrl(originalPath) != null ||
              originalPath.startsWith('http'),
          isVideo: isVideo,
        );
        return null;
      }

      final size = await local.file.length();
      final extension = _mediaExtension(
        filename: filename,
        path: originalPath,
        isVideo: isVideo,
      );
      final digest = await _sha1OfFile(local.file);
      final remoteName = contentAddressedAttachmentNameFromDigest(
        digest,
        extension,
      );
      final remotePath = '$resourcesPath$remoteName';
      final record = _WebDavResourceRecord(
        originalPath: originalPath,
        webdavPath: remotePath,
        filename: filename?.isNotEmpty ?? false ? filename! : remoteName,
        source: source,
        isVideo: isVideo,
        sizeBytes: size,
      );

      // 内容寻址后，远端同名即同内容，已经备份过就跳过（增量就靠这一步）
      if (existingNames.contains(remoteName)) {
        counters.recordSkip(isVideo: isVideo);
        return record;
      }

      await _webdavService.uploadFileFromPath(remotePath, local.file.path);
      existingNames.add(remoteName);
      counters.recordUpload(isVideo: isVideo);
      return record;
    } on Object catch (e) {
      counters.recordError(
        '${isVideo ? '视频' : '图片'}上传失败 $originalPath: $e',
      );
      return null;
    } finally {
      // 只为这一趟上传临时落盘的文件，结束就删，不占用户空间
      final temporary = local;
      if (temporary != null && temporary.temporary) {
        try {
          if (await temporary.file.exists()) {
            await temporary.file.delete();
          }
        } on Object {
          // 删不掉不影响备份结果，临时目录本身也会被系统回收
        }
      }
    }
  }

  /// 拿到媒体的本地文件：本地已有副本直接用，服务端/外链才下载。
  Future<_LocalMediaFile?> _materializeMedia(
    String path, {
    required bool isVideo,
  }) async {
    final existing = await _existingLocalMediaFile(path);
    if (existing != null) {
      return _LocalMediaFile(existing);
    }

    final serverUrl = _memosResourceUrl(path);
    final isHttp = path.startsWith('http://') || path.startsWith('https://');
    if (serverUrl == null && !isHttp) {
      return null;
    }
    final url = serverUrl ?? path;

    if (serverUrl != null) {
      // 服务端附件：直接落到附件缓存（`images/memos_*`），一次下载同时完成
      // 「备份源」和「离线副本」两件事，之后离线看图不必再跑一趟服务器。
      final appDir = await getApplicationDocumentsDirectory();
      final imagesDir = Directory('${appDir.path}/images');
      if (!await imagesDir.exists()) {
        await imagesDir.create(recursive: true);
      }
      final cacheFile = File(
        '${imagesDir.path}/${localFileNameForAttachment(path)}',
      );
      if (await cacheFile.exists() && await cacheFile.length() > 0) {
        return _LocalMediaFile(cacheFile);
      }
      if (!await _downloadUrlToFile(url, cacheFile, authorized: true)) {
        return null;
      }
      AttachmentCache.instance.invalidate();
      _localImageNameIndex = null;
      if (!isVideo) {
        unawaited(ThumbCache.instance.ensure(cacheFile.path));
      }
      return _LocalMediaFile(cacheFile);
    }

    // 第三方图片/视频：只为一趟上传临时落盘，结束就删
    final tempDir = await getTemporaryDirectory();
    final extension = _mediaExtension(
      filename: null,
      path: path,
      isVideo: isVideo,
    );
    final tempFile = File(
      '${tempDir.path}/webdav_media_'
      '${DateTime.now().microsecondsSinceEpoch}.$extension',
    );
    if (!await _downloadUrlToFile(url, tempFile)) {
      return null;
    }
    return _LocalMediaFile(tempFile, temporary: true);
  }

  /// 本机已有的副本（不触发网络）。
  Future<File?> _existingLocalMediaFile(String path) async {
    if (path.startsWith('file://')) {
      final file = File(path.replaceFirst('file://', ''));
      return await file.exists() ? file : null;
    }

    if (_isAppRelativeImagePath(path)) {
      final appDir = await getApplicationDocumentsDirectory();
      final file = File('${appDir.path}/$path');
      return await file.exists() ? file : null;
    }

    // 服务端附件先查本地离线副本（数据维护里缓存过、或上次恢复落地过）。
    // 没登录服务器 / 服务器不可达时，这是把图带进备份的唯一来源；漏掉这一步
    // 会导致备份静默丢图，换设备恢复后图片全裂。
    if (isRemoteAttachmentPath(path) || _isMemosResourcePath(path)) {
      await AttachmentCache.instance.prepare();
      final cached = AttachmentCache.instance.fileFor(path);
      if (cached != null && await cached.exists()) {
        return cached;
      }
      return _localMediaFileByFileName(path);
    }

    return null;
  }

  /// 流式计算文件的 sha1，用于内容寻址命名。
  ///
  /// 同一次备份里同一个文件可能被 resourceList 与正文两条通道各引用一次，
  /// 视频几百 MB，重复读盘算哈希太贵——按「路径 + 大小 + 修改时间」缓存。
  Future<Digest> _sha1OfFile(File file) async {
    final stat = await file.stat();
    final key =
        '${file.path}|${stat.size}|${stat.modified.millisecondsSinceEpoch}';
    final cached = _digestCache[key];
    if (cached != null) {
      return cached;
    }

    final sink = _DigestCollector();
    final input = sha1.startChunkedConversion(sink);
    await for (final chunk in file.openRead()) {
      input.add(chunk);
    }
    input.close();
    final digest = sink.value;
    if (digest == null) {
      throw StateError('计算文件摘要失败: ${file.path}');
    }
    _digestCache[key] = digest;
    return digest;
  }

  /// 本次备份已算过的文件摘要，[SyncStats] 一轮结束即失效。
  final Map<String, Digest> _digestCache = <String, Digest>{};

  /// 从文件名 / 路径推断扩展名；都没有时按媒体类型兜底。
  ///
  /// 服务端资源路径（`/o/r/<uid>`）是没有扩展名的，视频必须兜成 mp4，
  /// 否则恢复出来的文件叫 `.jpg`，播放器直接认不出来。
  String _mediaExtension({
    required String? filename,
    required String path,
    required bool isVideo,
  }) {
    final fromName = filename == null || filename.isEmpty
        ? null
        : _extensionOrNull(filename);
    if (fromName != null) {
      return fromName;
    }
    final fromPath = _extensionOrNull(path);
    if (fromPath != null) {
      return fromPath;
    }
    return isVideo ? 'mp4' : 'jpg';
  }

  /// `resourceList` 的「资源路径 → 真实文件名」索引，用于补齐扩展名。
  Map<String, String> _resourceFileNameIndex(List<Note> notes) {
    final index = <String, String>{};
    for (final note in notes) {
      for (final resource in note.resourceList) {
        final filename = resource['filename']?.toString();
        if (filename == null || filename.isEmpty) {
          continue;
        }
        for (final candidate in _resourcePathCandidates(resource)) {
          index.putIfAbsent(candidate, () => filename);
        }
      }
    }
    return index;
  }

  /// 把 URL 流式写入本地文件，返回是否成功。
  ///
  /// 整块 `http.get` 会把视频整个放进内存；这里按流写盘，几百 MB 也只是
  /// 分块缓冲。超时只卡「等响应头」这一段：大文件传输本来就慢，用整体
  /// 超时会稳定误杀下载。
  Future<bool> _downloadUrlToFile(
    String url,
    File target, {
    bool authorized = false,
  }) async {
    final client = http.Client();
    IOSink? sink;
    try {
      final request = http.Request('GET', Uri.parse(url));
      final token = _memosToken;
      if (authorized && token != null && token.isNotEmpty) {
        request.headers['Authorization'] = 'Bearer $token';
      }
      final response =
          await client.send(request).timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        debugPrint('WebDAV 备份：下载返回 ${response.statusCode} $url');
        return false;
      }
      await target.parent.create(recursive: true);
      sink = target.openWrite();
      // 整体不设上限（大视频就是慢），但「连续 60 秒一个字节都没来」直接
      // 判定链路已死：否则网络假死时整个备份会永远挂在这里。
      await sink.addStream(
        response.stream.timeout(const Duration(seconds: 60)),
      );
      await sink.flush();
      await sink.close();
      sink = null;
      return true;
    } on Object catch (e) {
      debugPrint('WebDAV 备份：下载失败 $url [$e]');
      // 半截文件不能留着当缓存，否则之后会命中一个坏文件
      try {
        if (await target.exists()) {
          await target.delete();
        }
      } on Object {
        // 删不掉就算了，下次下载会覆盖
      }
      return false;
    } finally {
      try {
        await sink?.close();
      } on Object {
        // 已经关闭或写入失败，忽略
      }
      client.close();
    }
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

  /// 正文里的媒体引用：图片和视频共用 `![alt](path)`，靠 alt/扩展名分流。
  Iterable<_MarkdownMedia> _extractMarkdownMedia(String content) sync* {
    for (final match
        in MemosContentHelper.markdownMediaRegex.allMatches(content)) {
      final path = match.group(2)?.trim() ?? '';
      if (path.isEmpty) {
        continue;
      }
      yield _MarkdownMedia(
        path: path,
        isVideo: MediaPaths.isVideoMarkdown(
          path: path,
          alt: match.group(1) ?? '',
        ),
      );
    }
  }

  /// 本机 images/ 目录的「文件名 → 绝对路径」索引，只在首次用到时构建。
  Map<String, String>? _localImageNameIndex;

  /// 按文件名在本机 images/ 目录里找同一个文件。
  ///
  /// 附件缓存按「整条路径的 sha1」命名，同一张图在正文（`/file/attachments/...`）
  /// 和资源列表 externalLink 里可能形态不同，算出的缓存名对不上——只按路径查
  /// 会误判成「本机没有」，然后去网络重新下载，慢网下直接超时失败。
  /// 同一附件的文件名是稳定的，这里按文件名兜一次底。
  Future<File?> _localMediaFileByFileName(String remotePath) async {
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
    final file = File(path);
    return await file.exists() ? file : null;
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

  /// 路径上的扩展名；取不到返回 null。
  ///
  /// 只认 2~5 位纯字母数字：服务端 uid 里偶尔带点（`abc.def123`），
  /// 不能把后半截当扩展名。
  String? _extensionOrNull(String path) {
    final cleanPath = path.split('?').first.split('#').first;
    final name = cleanPath.split('/').last;
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot >= name.length - 1) {
      return null;
    }
    final ext = _sanitizeFileComponent(name.substring(dot + 1)).toLowerCase();
    if (!RegExp(r'^[a-z0-9]{2,5}$').hasMatch(ext)) {
      return null;
    }
    return ext;
  }

  String _sanitizeFileComponent(String value) {
    final safe = value.replaceAll(RegExp('[^a-zA-Z0-9._-]'), '_');
    return safe.isEmpty ? 'image' : safe;
  }

  String? _resourcePathFromResource(Map<String, dynamic> resource) {
    // 视频不再跳过：以前这里直接 return null，备份里没有视频副本，换机
    // 恢复后视频全丢且界面没有任何提示。现在与图片走同一条内容寻址通道。
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

  Future<
      ({
        Map<String, String> pathMap,
        int videoRestored,
        int resourceRestored,
      })> _restoreResources(
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
    var videoRestored = 0;
    var resourceRestored = 0;

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
          // 服务端视频不落离线副本：正文里仍是 `/o/r/<uid>`，播放直接流式
          // 拉服务器；落一份几十 MB 的副本既不会被播放器用到，又白占空间。
          // 真正需要经 WebDAV 恢复的是「传不上服务器」的本地视频（下面这支）。
          if (record.videoLike) {
            continue;
          }
          // 服务器上的图/视频：正文保持 `/file/attachments/...` 不变，只把二进制
          // 落到附件缓存目录（`images/memos_*`）。渲染时 AttachmentCache 优先
          // 读本地副本，服务器不可达也能看图；正文与服务端保持一致，
          // 多设备同步不会互相污染。
          final cacheFile = File(
            '${imagesDir.path}/${localFileNameForAttachment(record.originalPath)}',
          );
          if (!await cacheFile.exists()) {
            // 流式落盘：视频几十上百 MB，整块 read 会直接吃光内存
            await _webdavService.downloadFileToPath(
              record.webdavPath,
              cacheFile.path,
            );
            unawaited(ThumbCache.instance.ensure(cacheFile.path));
          }
          resourceRestored++;
          if (record.videoLike) {
            videoRestored++;
          }
        } else {
          final localName = _restoredLocalFileName(record, i);
          final localFile = File('${imagesDir.path}/$localName');
          await _webdavService.downloadFileToPath(
            record.webdavPath,
            localFile.path,
          );
          // 视频也在这里生首帧：落地后信息流/详情页直接有封面
          unawaited(ThumbCache.instance.ensure(localFile.path));
          restoredPathMap[record.originalPath] = 'file://${localFile.path}';
          resourceRestored++;
          if (record.videoLike) {
            videoRestored++;
          }
        }
      } on Object catch (e) {
        errorCount++;
        debugPrint('WebDAV 恢复：附件失败 ${record.originalPath} [$e]');
      }

      onProgress?.call(
        manifest.isEmpty ? 1 : (i + 1) / manifest.length,
        '恢复附件 ${i + 1}/${manifest.length}',
      );
    }

    if (errorCount > 0) {
      _stats = _stats.copyWith(errors: _stats.errors + errorCount);
    }
    return (
      pathMap: restoredPathMap,
      videoRestored: videoRestored,
      resourceRestored: resourceRestored,
    );
  }

  String _restoredLocalFileName(_WebDavResourceRecord record, int index) {
    final sourceName =
        record.filename.isNotEmpty ? record.filename : record.webdavPath;
    final ext = _mediaExtension(
      filename: record.filename,
      path: record.webdavPath,
      isVideo: record.videoLike,
    );
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
  ///
  /// [includeVideos] 为 false 时不恢复视频：视频动辄几十上百 MB，换机时
  /// 先把笔记和图片拉回来、视频按需再说，是很实际的用法。跳过的视频不改写
  /// 正文，数量记在 [SyncStats.videoDeferred] 里给用户一个明确交代。
  Future<SyncStats> restore({
    void Function(double progress, String message)? onProgress,
    bool includeVideos = true,
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
        // 用户选择不恢复视频时，把视频记录整体滤掉：不下载、不改写正文，
        // 只在统计里报个数。
        final restoreManifest = includeVideos
            ? resourceManifest
            : resourceManifest.where((record) => !record.videoLike).toList();
        final deferredVideos = resourceManifest.length - restoreManifest.length;
        if (deferredVideos > 0) {
          _stats = _stats.copyWith(videoDeferred: deferredVideos);
        }

        final message = includeVideos ? '恢复图片与视频...' : '恢复图片资源...';
        _syncMessage = message;
        onProgress?.call(0.55, message);
        if (restoreManifest.isNotEmpty) {
          final restored = await _restoreResources(
            restoreManifest,
            onProgress: (progress, progressMessage) {
              onProgress?.call(0.55 + progress * 0.2, progressMessage);
            },
          );
          _stats = _stats.copyWith(
            videoRestored: restored.videoRestored,
            resourceRestored: restored.resourceRestored,
          );
          if (restored.pathMap.isNotEmpty) {
            remoteNotes = remoteNotes
                .map((note) => _rewriteNoteImagePaths(note, restored.pathMap))
                .toList();
          }
        }
        if (deferredVideos > 0) {
          _syncMessage = '已跳过 $deferredVideos 个视频';
        }
      } else if (remoteNotes.any(_hasServerBackedImageRef)) {
        // 备份里没有图片资源：旧备份、或备份时既没本地缓存也没登录服务器。
        // 正文里的服务端路径在本机无副本，未登录时这些图必然裂。必须明说，
        // 否则用户只会看到「恢复完成」和一堆裂图。
        _syncMessage = '备份中不含附件资源，图片和视频可能无法显示';
        onProgress?.call(0.55, '备份中不含附件资源，图片和视频可能无法显示');
      }

      // 3. 覆盖前保存本地应急备份，避免误操作造成不可恢复的数据损失。
      onProgress?.call(0.73, '保存本地应急备份...');
      await _uploadRestoreSafetyBackup();

      // 4. 合并远程笔记到本地（75% ~ 100%）
      //
      // 按 id 合并而不是整库替换：本地独有的笔记保留，两边都有的取较新版本。
      // 整库替换会把「备份之后在本地新建/编辑的笔记」直接抹掉。
      _syncMessage = '合并云备份笔记...';
      onProgress?.call(0.75, '写入本地数据库...');
      final (inserted, updated, keptLocal) =
          await _databaseService.mergeNotes(remoteNotes);
      // 附件缓存刚被写入/替换，让渲染层的查表重新落盘一次
      AttachmentCache.instance.invalidate();
      _stats = _stats.copyWith(downloaded: inserted + updated);
      onProgress?.call(
        1,
        '合并完成：新增 $inserted · 更新 $updated · 本地保留 $keptLocal',
      );

      _status = SyncStatus.success;
      _syncMessage = '合并完成：新增 $inserted 条 · 更新 $updated 条 · 本地保留 $keptLocal 条';
      onProgress?.call(1, '合并完成');

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
