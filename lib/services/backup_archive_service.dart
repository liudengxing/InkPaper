import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:inkpaper/models/note_model.dart';
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
  });

  final Uint8List bytes;
  final BackupContentFormat format;
  final int noteCount;

  /// 真正塞进包里的图片数量。
  final int imageCount;

  /// 正文引用了、但本地找不到文件的图片数量。
  final int missingImageCount;
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
  });

  final BackupContentFormat format;
  final List<BackupArchiveEntry> entries;

  /// 从包里还原到本地的图片数量。
  final int restoredImageCount;
}

/// 把笔记打包成「正文 + 图片」的 ZIP，以及把 ZIP 解回可导入的正文。
///
/// 之所以所有格式统一走 ZIP：JSON / TXT 这类纯文本格式本身没法携带二进制图片，
/// 之前只有 Markdown 分支会把图片写进包，其余格式的「包含图片」开关等于摆设。
class BackupArchiveService {
  BackupArchiveService({Future<Directory> Function()? imagesDirectoryProvider})
      : _imagesDirectoryProvider =
            imagesDirectoryProvider ?? _defaultImagesDirectory;

  /// 图片落地目录（导出时找图、导入时存图都用它）。
  final Future<Directory> Function() _imagesDirectoryProvider;

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

  // ---------------------------------------------------------------------------
  // 导出
  // ---------------------------------------------------------------------------

  /// 生成备份 ZIP。
  ///
  /// [markdownExporter] 由调用方注入（复用数据库层的 Markdown 序列化），
  /// 不传时退化成带 Front Matter 的简单实现。
  Future<BackupArchiveBuildResult> buildArchive({
    required List<Note> notes,
    required BackupContentFormat format,
    required bool includeImages,
    String Function(Note note)? markdownExporter,
    DateTime? now,
  }) async {
    final exportedAt = now ?? DateTime.now();
    final archive = Archive();
    final resources = <Map<String, String>>[];
    final archivedByOriginal = <String, String>{};
    // 只统计正文里真正引用到的图片，resourceList 里只是附件元数据，
    // 找不到也不影响阅读，不拿它去打扰用户
    final missingPaths = <String>{};

    if (includeImages) {
      for (var i = 0; i < notes.length; i++) {
        final note = notes[i];
        final referenced = contentImagePaths(note);
        final candidates = <String>[
          ...referenced,
          ...extractImagePaths(note)
              .where((path) => !referenced.contains(path)),
        ];
        for (final originalPath in candidates) {
          // 同一张图被多条笔记引用时只打一份
          if (archivedByOriginal.containsKey(originalPath)) {
            continue;
          }
          final file = await _resolveImageFile(originalPath);
          if (file == null) {
            if (referenced.contains(originalPath)) {
              missingPaths.add(originalPath);
            }
            continue;
          }
          final bytes = await file.readAsBytes();
          if (bytes.isEmpty) {
            if (referenced.contains(originalPath)) {
              missingPaths.add(originalPath);
            }
            continue;
          }
          final ext = extensionOf(file.path);
          final archivePath =
              '$resourceDirName/note_${i + 1}_${resources.length + 1}.$ext';
          archive.addFile(ArchiveFile(archivePath, bytes.length, bytes));
          resources.add({
            'noteId': note.id,
            'originalPath': originalPath,
            'archivePath': archivePath,
          });
          archivedByOriginal[originalPath] = archivePath;
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
        _addTextFile(archive, 'notes.json', payload);

      case BackupContentFormat.markdown:
        final exporter = markdownExporter ?? _defaultMarkdownExport;
        for (var i = 0; i < notes.length; i++) {
          _addTextFile(archive, 'note_${i + 1}.md', exporter(notes[i]));
        }

      case BackupContentFormat.txt:
        _addTextFile(archive, 'notes.txt', _buildTxt(notes));

      case BackupContentFormat.html:
        _addTextFile(
          archive,
          'notes.html',
          _buildHtml(notes, archivedByOriginal, exportedAt),
        );
    }

    if (resources.isNotEmpty) {
      _addTextFile(
        archive,
        resourceManifestName,
        jsonEncode({'version': '1.0', 'resources': resources}),
      );
    }

    _addTextFile(
      archive,
      manifestName,
      jsonEncode({
        'version': archiveVersion,
        'format': format.label,
        'exportedAt': exportedAt.toIso8601String(),
        'noteCount': notes.length,
        'includeImages': includeImages,
        'imageCount': resources.length,
        'missingImageCount': missingPaths.length,
        'generator': 'InkPaper',
      }),
    );

    final encoded = ZipEncoder().encode(archive);
    if (encoded == null) {
      throw Exception('压缩备份失败');
    }

    return BackupArchiveBuildResult(
      bytes: Uint8List.fromList(encoded),
      format: format,
      noteCount: notes.length,
      imageCount: resources.length,
      missingImageCount: missingPaths.length,
    );
  }

  void _addTextFile(Archive archive, String name, String content) {
    final bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
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
      ..writeln('<title>InkPaper-墨鸣笔记备份</title>')
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
      ..writeln('.tags { color: #007bff; }')
      ..writeln(
        '.missing-image { color: #b26a00; background: #fff4e5;'
        ' padding: 2px 6px; border-radius: 4px; font-size: 0.9em; }',
      )
      ..writeln('</style>')
      ..writeln('</head><body>')
      ..writeln('<h1>InkPaper-墨鸣笔记备份</h1>')
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
        return '<img src="$archivePath" alt="$alt">';
      }
      return '<span class="missing-image">[图片未随备份打包：$originalPath]</span>';
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

    final restoredPaths = await _restoreResources(files);

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
      throw Exception('压缩包里没有找到 ${format.label} 格式的笔记内容');
    }

    return DecodedBackupArchive(
      format: format,
      entries: entries,
      restoredImageCount: restoredPaths.length,
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
  Future<Map<String, String>> _restoreResources(
    Map<String, ArchiveFile> files,
  ) async {
    final restored = <String, String>{};
    final manifest = files[resourceManifestName];
    if (manifest == null) {
      return restored;
    }

    final Map<String, dynamic> decoded;
    try {
      final raw = jsonDecode(
        utf8.decode(manifest.content as List<int>, allowMalformed: true),
      );
      if (raw is! Map<String, dynamic> || raw['resources'] is! List) {
        return restored;
      }
      decoded = raw;
    } on Object {
      return restored;
    }

    final imagesDir = await _imagesDirectoryProvider();
    if (!await imagesDir.exists()) {
      await imagesDir.create(recursive: true);
    }

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

      final ext = extensionOf(archivePath);
      final safeName = 'backup_${DateTime.now().millisecondsSinceEpoch}_'
          '${restored.length}.$ext';
      final localFile =
          File('${imagesDir.path}${Platform.pathSeparator}$safeName');
      await localFile.writeAsBytes(
        archivedFile.content as List<int>,
        flush: true,
      );
      // 还原出来的图也要进缩略图缓存，否则恢复后第一次浏览信息流全是原图解码
      unawaited(ThumbCache.instance.ensure(localFile.path));
      restored[originalPath] = 'file://${localFile.path}';
    }

    return restored;
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

  /// 正文 Markdown 语法里直接引用到的图片路径。
  List<String> contentImagePaths(Note note) {
    final paths = <String>[];
    final imageRegex = RegExp(r'!\[[^\]]*\]\(([^)\s]+)');
    for (final match in imageRegex.allMatches(note.content)) {
      final value = match.group(1)?.trim();
      if (value != null && value.isNotEmpty && !paths.contains(value)) {
        paths.add(value);
      }
    }
    return paths;
  }

  /// 从正文的 Markdown 图片语法和 resourceList 里收集所有图片引用。
  List<String> extractImagePaths(Note note) {
    final paths = <String>[...contentImagePaths(note)];

    void add(String? path) {
      final value = path?.trim();
      if (value == null || value.isEmpty || paths.contains(value)) {
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

  /// 把各种写法的图片引用落到真实文件上。
  ///
  /// 顺序：`file://` → 绝对路径 → 相对路径（按应用图片目录拼），
  /// `content://`、`http(s)://` 这类拿不到字节的直接跳过。
  Future<File?> _resolveImageFile(String path) async {
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
