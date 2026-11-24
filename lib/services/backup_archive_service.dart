import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/utils/live_photo_utils.dart';
import 'package:inkpaper/utils/media_paths.dart';
import 'package:inkpaper/utils/thumb_cache.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';

/// 备份包内部的内容格式。
///
/// 无论选哪种格式，导出的都是同一个 ZIP 容器，区别只在正文以什么文件存：
/// - [json] → `notes.json`
/// - [markdown] → `note_1.md`、`note_2.md` …
/// - [txt] → `notes.txt`
/// - [html] → `notes.html`（只读，不可再导入）
enum BackupContentFormat {
  json('JSON'),
  markdown('Markdown'),
  txt('TXT'),
  html('HTML');

  const BackupContentFormat(this.label);

  /// 对外展示 / 历史记录里用的名字。
  final String label;

  static BackupContentFormat? fromLabel(String? value) {
    if (value == null) {
      return null;
    }
    final normalized = value.trim().toLowerCase();
    if (normalized.isEmpty) {
      return null;
    }
    for (final format in BackupContentFormat.values) {
      if (format.label.toLowerCase() == normalized ||
          format.name == normalized) {
        return format;
      }
    }
    return null;
  }
}

/// 打包结果。
class BackupArchiveBuildResult {
  const BackupArchiveBuildResult({
    required this.bytes,
    required this.format,
    required this.noteCount,
    required this.imageCount,
    required this.missingImageCount,
    this.videoCount = 0,
    this.missingVideoCount = 0,
    this.skippedVideoCount = 0,
  });

  final Uint8List bytes;
  final BackupContentFormat format;
  final int noteCount;

  /// 真正塞进包里的图片数量。
  final int imageCount;

  /// 正文引用了、但本地找不到文件的图片数量。
  final int missingImageCount;

  /// 真正塞进包里的视频数量。
  final int videoCount;

  /// 正文引用了、但本地找不到文件的视频数量。
  final int missingVideoCount;

  /// 因为体积超过上限而没打包的视频数量。
  final int skippedVideoCount;
}

/// 落盘版打包结果：字节在 [file] 里，计数与 [BackupArchiveBuildResult] 一致。
///
/// 只有能给「文件路径」的调用方（分享、复制到应用目录）才用得上它；
/// 需要整包字节的入口走 [BackupArchiveService.buildArchive]。
class BackupArchiveFileResult {
  const BackupArchiveFileResult({
    required this.file,
    required this.format,
    required this.noteCount,
    required this.imageCount,
    required this.missingImageCount,
    this.videoCount = 0,
    this.missingVideoCount = 0,
    this.skippedVideoCount = 0,
  });

  final File file;
  final BackupContentFormat format;
  final int noteCount;
  final int imageCount;
  final int missingImageCount;
  final int videoCount;
  final int missingVideoCount;
  final int skippedVideoCount;
}

/// 解包后的一份正文文件（图片路径已重写成本地可读路径）。
class BackupArchiveEntry {
  const BackupArchiveEntry({required this.name, required this.content});

  final String name;
  final String content;
}

/// 解包结果。
class DecodedBackupArchive {
  const DecodedBackupArchive({
    required this.format,
    required this.entries,
    required this.restoredImageCount,
    this.restoredVideoCount = 0,
    this.restoredLocalPaths = const [],
  });

  final BackupContentFormat format;
  final List<BackupArchiveEntry> entries;

  /// 从包里还原到本地的图片数量。
  final int restoredImageCount;

  /// 从包里还原到本地的视频数量。
  final int restoredVideoCount;

  /// 本次解包新写进本机磁盘的资源文件（绝对路径，不带 `file://`）。
  ///
  /// 导入失败或一条笔记都没落库时按这份清单回滚，因此写入时必须保证
  /// 「清单里的都是本次新建的文件」——文件名在落盘前先做过查重。
  final List<String> restoredLocalPaths;
}

/// 把笔记打包成「正文 + 图片」的 ZIP，以及把 ZIP 解回可导入的正文。
///
/// 之所以所有格式统一走 ZIP：JSON / TXT 这类纯文本格式本身没法携带二进制图片，
/// 之前只有 Markdown 分支会把图片写进包，其余格式的「包含图片」开关等于摆设。
class BackupArchiveService {
  BackupArchiveService({
    Future<Directory> Function()? imagesDirectoryProvider,
    Future<Directory> Function()? tempDirectoryProvider,
    DateTime Function()? now,
    int? maxSingleVideoBytes,
    int? maxVideosTotalBytes,
  })  : _imagesDirectoryProvider =
            imagesDirectoryProvider ?? _defaultImagesDirectory,
        _tempDirectoryProvider = tempDirectoryProvider ?? getTemporaryDirectory,
        _now = now ?? DateTime.now,
        _maxSingleVideoBytes =
            maxSingleVideoBytes ?? defaultMaxSingleVideoBytes,
        _maxVideosTotalBytes =
            maxVideosTotalBytes ?? defaultMaxVideosTotalBytes;

  /// 图片落地目录（导出时找图、导入时存图都用它）。
  final Future<Directory> Function() _imagesDirectoryProvider;

  /// 时间源。还原文件名用它拼时间戳，测试可以固定住验证同毫秒行为。
  final DateTime Function() _now;

  /// 打包时暂存 zip 的基准目录。
  ///
  /// 用 `getTemporaryDirectory()` 而不是 `Directory.systemTemp`：后者在授权
  /// 范围外（见 `apk_install_service` 的同类注释），写进去的文件再想分享出去
  /// 会被 FileProvider 拒掉。
  final Future<Directory> Function() _tempDirectoryProvider;

  static Future<Directory> _defaultImagesDirectory() async {
    final docs = await getApplicationDocumentsDirectory();
    return Directory('${docs.path}/images');
  }

  static const String archiveVersion = '2.0';
  static const String manifestName = 'backup_manifest.json';
  static const String resourceManifestName = 'resource_manifest.json';
  static const String resourceDirName = 'resources';

  static const Set<String> _reservedNames = {
    manifestName,
    resourceManifestName,
  };

  /// 单段视频进本地备份包的上限。
  ///
  /// ZIP 是在内存里整块编码的（`ZipEncoder().encode`），视频本身又压不动，
  /// 不设限等于拿低端机的堆在赌。超过上限的视频跳过并计数，
  /// 用户改用 WebDAV 备份即可（那条链路是按文件流式上传的）。
  static const int defaultMaxSingleVideoBytes = 150 * 1024 * 1024;

  /// 一次备份里所有视频的合计上限。
  static const int defaultMaxVideosTotalBytes = 200 * 1024 * 1024;

  final int _maxSingleVideoBytes;
  final int _maxVideosTotalBytes;

  // ---------------------------------------------------------------------------
  // 导出
  // ---------------------------------------------------------------------------

  /// 生成备份 ZIP。
  ///
  /// [markdownExporter] 由调用方注入（复用数据库层的 Markdown 序列化），
  /// 不传时退化成带 Front Matter 的简单实现。
  ///
  /// 打包本身全程落盘（见 [buildArchiveToFile]），只有最后要交给系统选择器或
  /// 加密时才把整包读成字节 —— 那一次副本无法避免，但组装阶段的中间数组
  /// 已经省掉了。
  Future<BackupArchiveBuildResult> buildArchive({
    required List<Note> notes,
    required BackupContentFormat format,
    required bool includeImages,
    bool includeVideos = false,
    String Function(Note note)? markdownExporter,
    DateTime? now,
  }) async {
    final baseDir = await _tempDirectoryProvider();
    final tempDir = await baseDir.createTemp('inkpaper_backup_');
    final target = File('${tempDir.path}/backup.zip');
    try {
      final packed = await buildArchiveToFile(
        target: target,
        notes: notes,
        format: format,
        includeImages: includeImages,
        includeVideos: includeVideos,
        markdownExporter: markdownExporter,
        now: now,
      );
      return BackupArchiveBuildResult(
        bytes: await target.readAsBytes(),
        format: packed.format,
        noteCount: packed.noteCount,
        imageCount: packed.imageCount,
        missingImageCount: packed.missingImageCount,
        videoCount: packed.videoCount,
        missingVideoCount: packed.missingVideoCount,
        skippedVideoCount: packed.skippedVideoCount,
      );
    } finally {
      // 失败时临时目录里会留一个写了一半的 zip，按「本次新增」清掉。
      await _deleteQuietly(tempDir);
    }
  }

  /// 生成备份 ZIP 并直接写到 [target]。
  ///
  /// 和 `ZipEncoder().encode(archive)` 的关键差别是**不把整包攒在内存里**：
  /// 视频条目按 1MB 块从源文件流进 zip 的输出流，峰值只跟单块缓冲有关，
  /// 不再随附件总量线性上涨。图片仍读成字节再压缩 —— 动图的片段要从字节里
  /// 切，本来就得整张读出来，而单张图片的额外拷贝只在处理它自己那一瞬间存在。
  ///
  /// 视频必须走 STORE（不压缩）：`ZipEncoder` 的压缩分支会先把整个条目读成
  /// 一个 `Uint8List` 再压，正好把刚省下的内存又拿回来；150MB 的视频在那条
  /// 路上要两份 150MB。视频本来就压不动，存原样体积几乎不变。
  Future<BackupArchiveFileResult> buildArchiveToFile({
    required File target,
    required List<Note> notes,
    required BackupContentFormat format,
    required bool includeImages,
    bool includeVideos = false,
    String Function(Note note)? markdownExporter,
    DateTime? now,
  }) async {
    final exportedAt = now ?? DateTime.now();
    final encoder = ZipFileEncoder();
    encoder.create(target.path);
    try {
      final resources = <Map<String, dynamic>>[];
      final archivedByOriginal = <String, String>{};
      // 只统计正文里真正引用到的图片，resourceList 里只是附件元数据，
      // 找不到也不影响阅读，不拿它去打扰用户
      final missingPaths = <String>{};
      final missingVideoPaths = <String>{};
      final skippedVideoPaths = <String>{};
      var videoCount = 0;
      var videoBytesTotal = 0;

      Future<void> archiveMedia({
        required int noteIndex,
        required Note note,
        required String originalPath,
        required bool isVideo,
        required bool referencedInBody,
        String? liveOf,
      }) async {
        // 同一份媒体被多条笔记引用时只打一份
        if (archivedByOriginal.containsKey(originalPath)) {
          return;
        }
        final file = await _resolveMediaFile(originalPath);
        if (file == null) {
          if (referencedInBody) {
            (isVideo ? missingVideoPaths : missingPaths).add(originalPath);
          }
          return;
        }
        final size = file.lengthSync();
        if (size == 0) {
          if (referencedInBody) {
            (isVideo ? missingVideoPaths : missingPaths).add(originalPath);
          }
          return;
        }
        if (isVideo) {
          if (size > _maxSingleVideoBytes ||
              videoBytesTotal + size > _maxVideosTotalBytes) {
            // 单包体积上限：视频进包后不压缩，而最终交付（系统选择器 / 加密）
            // 还是要一份整包字节，不设限等于拿低端机的堆在赌。跳过并计数，
            // 交给界面提示用户改用 WebDAV 备份。
            skippedVideoPaths.add(originalPath);
            return;
          }
          videoBytesTotal += size;
        }
        final ext = extensionOf(file.path);
        final prefix = isVideo ? 'video' : 'note';
        final archivePath =
            '$resourceDirName/${prefix}_${noteIndex + 1}_${resources.length + 1}.$ext';

        // 视频只按块过一遍，不进堆；图片要读出来，动图的片段还得从字节里切。
        Uint8List? bytes;
        if (isVideo) {
          _addFileEntry(encoder, file, archivePath);
        } else {
          bytes = await file.readAsBytes();
          encoder.addArchiveFile(ArchiveFile(archivePath, bytes.length, bytes));
        }
        resources.add({
          'noteId': note.id,
          'originalPath': originalPath,
          'archivePath': archivePath,
          if (isVideo) 'isVideo': true,
          if (isVideo) 'sizeBytes': size,
          // Live 图的动态片段：还原时要贴着同名静图落盘（`<图>.live.mp4`），
          // 否则动图会退化成静态图。
          if (liveOf != null) 'liveOf': liveOf,
        });
        archivedByOriginal[originalPath] = archivePath;
        if (isVideo) {
          videoCount++;
        }

        // 动图没播放过时旁边还没有 `<图>.live.mp4`（播放才会抽出片段），
        // 但片段就嵌在刚读到的字节里。直接切出来当 sidecar 落包，
        // 否则备份出来的动图会退化成静态图。
        if (!isVideo && !LivePhotoUtils.hasLiveVideo(originalPath)) {
          final liveBytes =
              LivePhotoUtils.extractMotionPhoto(bytes!)?.videoBytes;
          if (liveBytes != null &&
              liveBytes.isNotEmpty &&
              liveBytes.length <= _maxSingleVideoBytes &&
              videoBytesTotal + liveBytes.length <= _maxVideosTotalBytes) {
            videoBytesTotal += liveBytes.length;
            final liveArchivePath = '$resourceDirName/'
                'video_${noteIndex + 1}_${resources.length + 1}.mp4';
            encoder.addArchiveFile(
              ArchiveFile(liveArchivePath, liveBytes.length, liveBytes),
            );
            final livePath = LivePhotoUtils.videoPathFor(originalPath);
            resources.add({
              'noteId': note.id,
              'originalPath': livePath,
              'archivePath': liveArchivePath,
              'isVideo': true,
              'sizeBytes': liveBytes.length,
              'liveOf': originalPath,
            });
            archivedByOriginal[livePath] = liveArchivePath;
            videoCount++;
          }
        }
      }

      if (includeImages || includeVideos) {
        for (var i = 0; i < notes.length; i++) {
          final note = notes[i];
          final refs = contentMediaRefs(note);
          final bodyImages =
              refs.where((ref) => !ref.isVideo).map((ref) => ref.path).toList();
          final bodyVideos =
              refs.where((ref) => ref.isVideo).map((ref) => ref.path).toList();

          if (includeImages) {
            final candidates = <String>[
              ...bodyImages,
              ...extractImagePaths(note).where((p) => !bodyImages.contains(p)),
            ];
            for (final originalPath in candidates) {
              await archiveMedia(
                noteIndex: i,
                note: note,
                originalPath: originalPath,
                isVideo: false,
                referencedInBody: bodyImages.contains(originalPath),
              );
              // Live 图的动态片段不写在正文里（正文只有一张静图），但少了它
              // 动图就退化成静态图。所以只要打了这张图，就顺手把旁边的
              // `<图>.live.mp4` 一起收进包，并记下它属于哪张图。
              if (LivePhotoUtils.hasLiveVideo(originalPath)) {
                await archiveMedia(
                  noteIndex: i,
                  note: note,
                  originalPath: LivePhotoUtils.videoPathFor(originalPath),
                  isVideo: true,
                  referencedInBody: false,
                  liveOf: originalPath,
                );
              }
            }
          }

          if (includeVideos) {
            final candidates = <String>[
              ...bodyVideos,
              ...extractVideoPaths(note).where((p) => !bodyVideos.contains(p)),
            ];
            for (final originalPath in candidates) {
              await archiveMedia(
                noteIndex: i,
                note: note,
                originalPath: originalPath,
                isVideo: true,
                referencedInBody: bodyVideos.contains(originalPath),
              );
            }
          }
        }
      }

      // 正文文件
      switch (format) {
        case BackupContentFormat.json:
          final payload = jsonEncode({
            'version': '1.0',
            'exportTime': exportedAt.toIso8601String(),
            'notes': notes.map((note) => note.toJson()).toList(),
          });
          _addTextFile(encoder, 'notes.json', payload);

        case BackupContentFormat.markdown:
          final exporter = markdownExporter ?? _defaultMarkdownExport;
          for (var i = 0; i < notes.length; i++) {
            _addTextFile(encoder, 'note_${i + 1}.md', exporter(notes[i]));
          }

        case BackupContentFormat.txt:
          _addTextFile(encoder, 'notes.txt', _buildTxt(notes));

        case BackupContentFormat.html:
          _addTextFile(
            encoder,
            'notes.html',
            _buildHtml(notes, archivedByOriginal, exportedAt),
          );
      }

      if (resources.isNotEmpty) {
        _addTextFile(
          encoder,
          resourceManifestName,
          jsonEncode({'version': '1.0', 'resources': resources}),
        );
      }

      _addTextFile(
        encoder,
        manifestName,
        jsonEncode({
          'version': archiveVersion,
          'format': format.label,
          'exportedAt': exportedAt.toIso8601String(),
          'noteCount': notes.length,
          'includeImages': includeImages,
          'includeVideos': includeVideos,
          'imageCount': resources.length - videoCount,
          'videoCount': videoCount,
          'missingImageCount': missingPaths.length,
          'missingVideoCount': missingVideoPaths.length,
          'skippedVideoCount': skippedVideoPaths.length,
          'generator': 'InkPaper',
        }),
      );

      await encoder.close();

      return BackupArchiveFileResult(
        file: target,
        format: format,
        noteCount: notes.length,
        imageCount: resources.length - videoCount,
        missingImageCount: missingPaths.length,
        videoCount: videoCount,
        missingVideoCount: missingVideoPaths.length,
        skippedVideoCount: skippedVideoPaths.length,
      );
    } on Object {
      // 半成品不留：先收尾把文件句柄放掉（Windows 上不关删不掉），再删掉
      // 写了一半的 zip，最后把原始异常抛出去。
      try {
        await encoder.close();
      } on Object {
        // 流已经写坏时收尾本身也会抛，这里不再追究。
      }
      await _deleteQuietly(target);
      rethrow;
    }
  }

  /// 把一个媒体文件按块写进 zip（STORE，不压缩）。
  ///
  /// 不用 `ZipFileEncoder.addFile` 的压缩分支：那条路会先把整个条目读成一个
  /// `Uint8List` 再 deflate，150MB 的视频等于把刚省下的内存又拿回来。STORE
  /// 分支直接从 [InputFileStream] 按 1MB 块写到输出流，峰值与文件大小无关。
  void _addFileEntry(ZipFileEncoder encoder, File file, String name) {
    final entry = ArchiveFile.stream(
      name,
      file.lengthSync(),
      InputFileStream(file.path),
    )
      ..compress = false
      ..lastModTime = file.lastModifiedSync().millisecondsSinceEpoch ~/ 1000;
    // addArchiveFile 写完条目会自己关掉输入流，这里不要再 close 一次。
    encoder.addArchiveFile(entry);
  }

  /// 清理打包留下的临时文件/目录。
  ///
  /// 删不掉只是留垃圾，不该把「备份其实成功了」判成失败，所以吞掉异常。
  static Future<void> _deleteQuietly(FileSystemEntity entity) async {
    try {
      if (await entity.exists()) {
        await entity.delete(recursive: true);
      }
    } on Object {
      // 见上
    }
  }

  void _addTextFile(ZipFileEncoder encoder, String name, String content) {
    final bytes = utf8.encode(content);
    encoder.addArchiveFile(ArchiveFile(name, bytes.length, bytes));
  }

  String _defaultMarkdownExport(Note note) {
    final metadata = <String, dynamic>{
      'InkPaperNote': true,
      'id': note.id,
      'createdAt': note.createdAt.toIso8601String(),
      'updatedAt': note.updatedAt.toIso8601String(),
      'displayTime': note.displayTime.toIso8601String(),
      'tags': note.tags,
      'creator': note.creator,
    };
    final buffer = StringBuffer('---\n');
    metadata.forEach((key, value) {
      buffer.writeln('$key: ${jsonEncode(value)}');
    });
    buffer.writeln('---');
    buffer.write(note.content);
    return buffer.toString();
  }

  String _buildTxt(List<Note> notes) {
    final formatter = DateFormat('yyyy-MM-dd HH:mm:ss');
    final buffer = StringBuffer();
    for (final note in notes) {
      buffer.writeln('--- 笔记 ${note.id} ---');
      buffer.writeln('创建时间: ${formatter.format(note.createdAt)}');
      buffer.writeln('更新时间: ${formatter.format(note.updatedAt)}');
      buffer.writeln('标签: ${note.tags.join(', ')}');
      buffer.writeln('内容:');
      buffer.writeln(note.content);
      buffer.writeln('\n--------------------\n');
    }
    return buffer.toString();
  }

  String _buildHtml(
    List<Note> notes,
    Map<String, String> archivedByOriginal,
    DateTime exportedAt,
  ) {
    final formatter = DateFormat('yyyy-MM-dd HH:mm:ss');
    final buffer = StringBuffer()
      ..writeln('<!DOCTYPE html>')
      ..writeln('<html lang="zh"><head>')
      ..writeln('<meta charset="UTF-8">')
      ..writeln('<title>InkPaper 备份</title>')
      ..writeln('<style>')
      ..writeln(
        'body { font-family: -apple-system, "PingFang SC", Arial, sans-serif;'
        ' max-width: 800px; margin: 0 auto; padding: 24px; line-height: 1.7; }',
      )
      ..writeln(
        '.note { border: 1px solid #e0e0e0; padding: 16px;'
        ' margin-bottom: 20px; border-radius: 8px; }',
      )
      ..writeln(
        '.note-meta { color: #666; font-size: 0.9em; margin-bottom: 10px; }',
      )
      ..writeln(
        '.note-content { white-space: pre-wrap; word-break: break-word; }',
      )
      ..writeln('.note-content img { max-width: 100%; border-radius: 6px; }')
      ..writeln(
        '.note-content video { max-width: 100%; border-radius: 6px; }',
      )
      ..writeln('.tags { color: #007bff; }')
      ..writeln(
        '.missing-image { color: #b26a00; background: #fff4e5;'
        ' padding: 2px 6px; border-radius: 4px; font-size: 0.9em; }',
      )
      ..writeln('</style>')
      ..writeln('</head><body>')
      ..writeln('<h1>InkPaper 备份</h1>')
      ..writeln('<p>导出时间: ${formatter.format(exportedAt)}</p>')
      ..writeln('<p>笔记总数: ${notes.length}</p>');

    for (final note in notes) {
      buffer.writeln('<div class="note">');
      buffer.writeln('<div class="note-meta">');
      buffer.writeln('创建时间: ${formatter.format(note.createdAt)}<br>');
      buffer.writeln('更新时间: ${formatter.format(note.updatedAt)}<br>');
      if (note.tags.isNotEmpty) {
        buffer.writeln(
          '标签: <span class="tags">'
          '${note.tags.map((tag) => _escapeHtml('#$tag')).join(' ')}</span>',
        );
      }
      buffer.writeln('</div>');
      buffer.writeln('<div class="note-content">');
      buffer.writeln(_renderHtmlContent(note.content, archivedByOriginal));
      buffer.writeln('</div>');
      buffer.writeln('</div>');
    }

    buffer.writeln('</body></html>');
    return buffer.toString();
  }

  /// 把 Markdown 正文转成可读 HTML：先整体转义，再把图片语法换成 `<img>`。
  ///
  /// HTML 备份是「只读导出」，图片用包内相对路径（`resources/xxx.jpg`），
  /// 解压后双击 html 就能直接看到图。找不到本地文件的图片降级成占位文字，
  /// 不会留下一个打不开的空图。
  String _renderHtmlContent(String markdown, Map<String, String> archived) {
    final imageRegex = RegExp(r'!\[([^\]]*)\]\(([^)\s]+)');
    return _escapeHtml(markdown).replaceAllMapped(imageRegex, (match) {
      final alt = match.group(1) ?? '';
      final originalPath = match.group(2) ?? '';
      final archivePath = archived[originalPath];
      if (archivePath != null) {
        // 视频和图片共用一套 Markdown 语法，HTML 里得渲染成 <video>
        if (MediaPaths.isVideoPath(archivePath)) {
          return '<video controls preload="metadata" src="$archivePath">'
              '不支持内嵌播放，可直接打开 $archivePath</video>';
        }
        return '<img src="$archivePath" alt="$alt">';
      }
      final label = MediaPaths.isVideoPath(originalPath) ? '视频' : '图片';
      return '<span class="missing-image">[$label未随备份打包：$originalPath]</span>';
    });
  }

  String _escapeHtml(String input) => input
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  // ---------------------------------------------------------------------------
  // 导入
  // ---------------------------------------------------------------------------

  /// 解开备份 ZIP：还原图片到本地、重写正文里的图片路径，按内容格式返回文件。
  Future<DecodedBackupArchive> decodeArchive(Uint8List bytes) async {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } on Object catch (e) {
      throw Exception('无法解析备份压缩包：$e');
    }

    final files = <String, ArchiveFile>{
      for (final file in archive.files)
        if (file.isFile) file.name: file,
    };

    final format = _detectFormat(files);
    if (format == null) {
      throw Exception('压缩包里没有找到可导入的笔记内容');
    }

    final restoredResources = await _restoreResources(files);
    final restoredPaths = restoredResources.paths;

    final entries = <BackupArchiveEntry>[];
    for (final name in files.keys) {
      if (_reservedNames.contains(name)) {
        continue;
      }
      if (!_matchesFormat(name.toLowerCase(), format)) {
        continue;
      }
      final raw = utf8.decode(
        files[name]!.content as List<int>,
        allowMalformed: true,
      );
      entries.add(
        BackupArchiveEntry(
          name: name,
          content: _rewriteImagePaths(
            raw,
            restoredPaths,
            jsonEncoded: format == BackupContentFormat.json,
          ),
        ),
      );
    }

    if (entries.isEmpty) {
      // 资源已经落盘但没有任何笔记会引用它们：先回滚再报错，
      // 否则这条失败路径会在图片目录里留下一批孤儿文件。
      await _discardPaths(restoredResources.createdPaths);
      throw Exception('压缩包里没有找到 ${format.label} 格式的笔记内容');
    }

    return DecodedBackupArchive(
      format: format,
      entries: entries,
      restoredImageCount: restoredPaths.length - restoredResources.videoCount,
      restoredVideoCount: restoredResources.videoCount,
      restoredLocalPaths: restoredResources.createdPaths,
    );
  }

  BackupContentFormat? _detectFormat(Map<String, ArchiveFile> files) {
    final manifest = files[manifestName];
    if (manifest != null) {
      try {
        final decoded = jsonDecode(
          utf8.decode(manifest.content as List<int>, allowMalformed: true),
        );
        if (decoded is Map) {
          final declared = BackupContentFormat.fromLabel(
            decoded['format']?.toString(),
          );
          if (declared != null) {
            return declared;
          }
        }
      } on Object {
        // manifest 损坏时退回按扩展名推断
      }
    }

    final names = files.keys
        .where((name) => !_reservedNames.contains(name))
        .map((name) => name.toLowerCase())
        .toList();
    if (names.any((name) => name.endsWith('.json'))) {
      return BackupContentFormat.json;
    }
    if (names.any(
      (name) => name.endsWith('.md') || name.endsWith('.markdown'),
    )) {
      return BackupContentFormat.markdown;
    }
    if (names.any((name) => name.endsWith('.txt'))) {
      return BackupContentFormat.txt;
    }
    if (names.any((name) => name.endsWith('.html') || name.endsWith('.htm'))) {
      return BackupContentFormat.html;
    }
    return null;
  }

  bool _matchesFormat(String lowerName, BackupContentFormat format) {
    switch (format) {
      case BackupContentFormat.json:
        return lowerName.endsWith('.json');
      case BackupContentFormat.markdown:
        return lowerName.endsWith('.md') || lowerName.endsWith('.markdown');
      case BackupContentFormat.txt:
        return lowerName.endsWith('.txt');
      case BackupContentFormat.html:
        return lowerName.endsWith('.html') || lowerName.endsWith('.htm');
    }
  }

  /// 把 `resources/*` 写进应用图片目录，返回「原始路径 → file:// 本地路径」。
  ///
  /// 同时返回本次真正新建的文件清单（`createdPaths`），供导入失败时回滚。
  Future<
      ({
        Map<String, String> paths,
        int videoCount,
        List<String> createdPaths,
      })> _restoreResources(
    Map<String, ArchiveFile> files,
  ) async {
    final restored = <String, String>{};
    final createdPaths = <String>[];
    var videoCount = 0;
    final manifest = files[resourceManifestName];
    if (manifest == null) {
      return (
        paths: restored,
        videoCount: videoCount,
        createdPaths: createdPaths
      );
    }

    final Map<String, dynamic> decoded;
    try {
      final raw = jsonDecode(
        utf8.decode(manifest.content as List<int>, allowMalformed: true),
      );
      if (raw is! Map<String, dynamic> || raw['resources'] is! List) {
        return (
          paths: restored,
          videoCount: videoCount,
          createdPaths: createdPaths,
        );
      }
      decoded = raw;
    } on Object {
      return (
        paths: restored,
        videoCount: videoCount,
        createdPaths: createdPaths
      );
    }

    final imagesDir = await _imagesDirectoryProvider();
    if (!await imagesDir.exists()) {
      await imagesDir.create(recursive: true);
    }

    // Live 图的动态片段要贴在还原后的静图旁边（`<图>.live.mp4`），
    // 所以分两趟：先落静图与普通视频，再回头补侧车片段。
    final liveSidecars =
        <({String originalPath, ArchiveFile file, String liveOf})>[];

    for (final item in decoded['resources'] as List<dynamic>) {
      if (item is! Map) {
        continue;
      }
      final originalPath = item['originalPath']?.toString();
      final archivePath = item['archivePath']?.toString();
      if (originalPath == null ||
          originalPath.isEmpty ||
          archivePath == null ||
          archivePath.isEmpty) {
        continue;
      }
      final archivedFile = files[archivePath];
      if (archivedFile == null) {
        continue;
      }

      final liveOf = item['liveOf']?.toString();
      if (liveOf != null && liveOf.isNotEmpty) {
        liveSidecars.add(
          (originalPath: originalPath, file: archivedFile, liveOf: liveOf),
        );
        continue;
      }

      final ext = extensionOf(archivePath);
      final isVideo =
          item['isVideo'] == true || MediaPaths.isVideoPath(archivePath);
      final localFile = await _allocateRestoredFile(
        imagesDir,
        isVideo ? 'video' : 'image',
        ext,
      );
      // 写失败会直接抛出，文件不会进回滚清单（宁可漏删也不能删错）
      await localFile.writeAsBytes(
        archivedFile.content as List<int>,
        flush: true,
      );
      createdPaths.add(localFile.path);
      // 还原出来的图/视频也要进缩略图缓存，否则恢复后第一次浏览信息流
      // 全是原图解码（视频还会白等首帧）
      unawaited(ThumbCache.instance.ensure(localFile.path));
      restored[originalPath] = 'file://${localFile.path}';
      if (isVideo) {
        videoCount++;
      }
    }

    for (final sidecar in liveSidecars) {
      final imagePath = restored[sidecar.liveOf];
      if (imagePath == null) {
        // 静图没还原出来，孤立的动图片段没有意义
        continue;
      }
      final localImage = imagePath.replaceFirst('file://', '');
      final target = LivePhotoUtils.videoPathFor(localImage);
      try {
        await File(target).writeAsBytes(
          sidecar.file.content as List<int>,
          flush: true,
        );
        createdPaths.add(target);
        restored[sidecar.originalPath] = 'file://$target';
        videoCount++;
      } on Object {
        // 单个片段写失败不该让整包恢复失败
      }
    }

    return (
      paths: restored,
      videoCount: videoCount,
      createdPaths: createdPaths,
    );
  }

  /// 给还原出来的资源分配一个**当前不存在**的文件名。
  ///
  /// 以前用「毫秒时间戳 + 本次已还原数量」拼名字：同一个包连导两次，时间戳
  /// 可能落在同一毫秒、序号又都从 0 开始，第二次会直接覆盖第一次还原的图，
  /// 第一次的笔记就指向了别的内容。查重后还有个好处——回滚删掉的一定是本
  /// 次新建的文件，不会误伤用户原有数据。
  Future<File> _allocateRestoredFile(
    Directory dir,
    String kind,
    String ext,
  ) async {
    final stamp = _now().millisecondsSinceEpoch;
    for (var attempt = 0; attempt < 1000; attempt++) {
      final suffix = attempt == 0 ? '' : '_$attempt';
      final file = File(
        '${dir.path}${Platform.pathSeparator}'
        'backup_${kind}_$stamp$suffix.$ext',
      );
      if (!await file.exists()) {
        return file;
      }
    }
    throw Exception('无法为还原的资源分配文件名');
  }

  /// 删掉某个解包批次新建的资源文件，返回真正删掉的数量。
  ///
  /// 只删 [DecodedBackupArchive.restoredLocalPaths] 里列出的文件，图片目录里
  /// 的其它内容一律不碰；单个删除失败只记日志，不覆盖调用方的原始异常。
  Future<int> discardRestoredResources(DecodedBackupArchive decoded) =>
      _discardPaths(decoded.restoredLocalPaths);

  /// 导入收尾：真落了笔记就保留本次还原的资源，一条都没进来就整批清掉。
  ///
  /// 「导入 0 条」既可能是格式不认，也可能是全部因已存在而跳过——两种情况
  /// 下本次新写的媒体副本都没有任何笔记引用，留着只会变成孤儿文件。
  /// 返回清理掉的文件数量（保留资源时为 0）。
  Future<int> finalizeRestore(
    DecodedBackupArchive decoded, {
    required int importedCount,
  }) {
    if (importedCount > 0) {
      return Future<int>.value(0);
    }
    return _discardPaths(decoded.restoredLocalPaths);
  }

  Future<int> _discardPaths(List<String> paths) async {
    var removed = 0;
    for (final path in paths) {
      try {
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
          removed++;
        }
      } on Object catch (e) {
        debugPrint('清理还原资源失败: $path $e');
      }
    }
    return removed;
  }

  /// 把正文里的旧图片路径替换成本地还原后的路径。
  ///
  /// [jsonEncoded] 为 true 时路径在正文里是 JSON 转义过的（Windows 反斜杠会变成
  /// `\\\\`），必须连同转义一起替换，否则 JSON 备份在 Windows 上还原不出图片。
  String _rewriteImagePaths(
    String content,
    Map<String, String> restored, {
    bool jsonEncoded = false,
  }) {
    if (restored.isEmpty) {
      return content;
    }
    var result = content;
    // 长路径优先，避免 /file/a 把 /file/a.png 的前缀吃掉
    final keys = restored.keys.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    for (final key in keys) {
      final from = jsonEncoded ? _jsonEscapePath(key) : key;
      final to = jsonEncoded ? _jsonEscapePath(restored[key]!) : restored[key]!;
      result = result.replaceAll(from, to);
    }
    return result;
  }

  String _jsonEscapePath(String value) => value.replaceAll(r'\', r'\\');

  // ---------------------------------------------------------------------------
  // 图片解析
  // ---------------------------------------------------------------------------

  /// 正文 Markdown 语法里出现的所有媒体引用（图片 + 视频）。
  ///
  /// 视频和图片用的是同一套 `![alt](path)` 语法，必须靠 alt 约定与扩展名
  /// 分流：否则「包含图片」会把视频也当图片塞进包里，统计和提示全错。
  List<({String path, bool isVideo})> contentMediaRefs(Note note) {
    final refs = <({String path, bool isVideo})>[];
    final imageRegex = RegExp(r'!\[([^\]]*)\]\(([^)\s]+)');
    for (final match in imageRegex.allMatches(note.content)) {
      final path = match.group(2)?.trim() ?? '';
      if (path.isEmpty || refs.any((ref) => ref.path == path)) {
        continue;
      }
      final isVideo = MediaPaths.isVideoMarkdown(
        path: path,
        alt: match.group(1) ?? '',
      );
      refs.add((path: path, isVideo: isVideo));
    }
    return refs;
  }

  /// 正文 Markdown 语法里直接引用到的图片路径。
  List<String> contentImagePaths(Note note) => contentMediaRefs(note)
      .where((ref) => !ref.isVideo)
      .map((ref) => ref.path)
      .toList();

  /// 正文 Markdown 语法里直接引用到的视频路径。
  List<String> contentVideoPaths(Note note) => contentMediaRefs(note)
      .where((ref) => ref.isVideo)
      .map((ref) => ref.path)
      .toList();

  /// 从正文的 Markdown 图片语法和 resourceList 里收集所有图片引用。
  List<String> extractImagePaths(Note note) {
    final paths = <String>[...contentImagePaths(note)];

    void add(String? path) {
      final value = path?.trim();
      if (value == null || value.isEmpty || paths.contains(value)) {
        return;
      }
      // 视频有自己的分支，混进图片统计会让「图片 N 张」多算
      if (MediaPaths.isVideoPath(value)) {
        return;
      }
      paths.add(value);
    }

    for (final resource in note.resourceList) {
      add(resource['localPath']?.toString());
      add(resource['path']?.toString());
      add(resource['filename']?.toString());
    }

    return paths;
  }

  /// 从正文的 Markdown 语法和 resourceList 里收集所有视频引用。
  ///
  /// 服务端资源路径（`/o/r/<uid>`）没有扩展名，只能靠 resourceList 的
  /// `alt` 是不是「视频」来判，否则这类视频永远进不了备份。
  List<String> extractVideoPaths(Note note) {
    final paths = <String>[...contentVideoPaths(note)];

    void add(String? path, {String alt = ''}) {
      final value = path?.trim();
      if (value == null || value.isEmpty || paths.contains(value)) {
        return;
      }
      if (!MediaPaths.isVideoMarkdown(path: value, alt: alt)) {
        return;
      }
      paths.add(value);
    }

    for (final resource in note.resourceList) {
      final alt = resource['alt']?.toString() ?? '';
      add(resource['localPath']?.toString(), alt: alt);
      add(resource['path']?.toString(), alt: alt);
      add(resource['filename']?.toString());
    }

    return paths;
  }

  /// 把各种写法的图片 / 视频引用落到真实文件上。
  ///
  /// 顺序：`file://` → 绝对路径 → 相对路径（按应用图片目录拼），
  /// `content://`、`http(s)://` 这类拿不到字节的直接跳过。
  Future<File?> _resolveMediaFile(String path) async {
    Future<File?> exists(String candidate) async {
      if (candidate.isEmpty) {
        return null;
      }
      final file = File(candidate);
      return await file.exists() ? file : null;
    }

    if (path.startsWith('file://')) {
      return exists(Uri.tryParse(path)?.toFilePath() ?? '');
    }
    if (path.startsWith('content://') ||
        path.startsWith('http://') ||
        path.startsWith('https://')) {
      return null;
    }
    final isAbsolute =
        path.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);
    final direct = await exists(path);
    if (direct != null) {
      return direct;
    }
    if (isAbsolute) {
      return null;
    }

    // 相对文件名：先在应用图片目录里找，再尝试上层的 app_flutter 目录
    final imagesDir = await _imagesDirectoryProvider();
    final fromImages = await exists(
      '${imagesDir.path}${Platform.pathSeparator}$path',
    );
    if (fromImages != null) {
      return fromImages;
    }
    final parent = imagesDir.parent.path;
    return exists('$parent${Platform.pathSeparator}$path');
  }

  /// 取扩展名，找不到时给 `bin`。
  String extensionOf(String path) {
    final filename = path.split(Platform.pathSeparator).last.split('/').last;
    final dot = filename.lastIndexOf('.');
    if (dot == -1 || dot == filename.length - 1) {
      return 'bin';
    }
    return filename.substring(dot + 1).toLowerCase();
  }
}
