import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/services/backup_archive_service.dart';
import 'package:inkpaper/utils/live_photo_utils.dart';

/// 1×1 透明 PNG，够当作真实的图片字节用
final Uint8List _tinyPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmM'
  'IQAAAABJRU5ErkJggg==',
);

/// 造一张「Container 目录」格式的动图（小米相机 MVIMG 就是这套）。
///
/// 目录里不写偏移量，只写片段自己的字节数，片段紧贴在文件末尾。
Uint8List _containerMotionPhoto({int videoLength = 4096}) {
  final xmp = '<x:xmpmeta><rdf:Description GCamera:MotionPhoto="1">'
      '<Container:Directory><rdf:Seq>'
      '<rdf:li><Container:Item Item:Mime="image/jpeg" '
      'Item:Semantic="Primary"/></rdf:li>'
      '<rdf:li><Container:Item Item:Mime="video/mp4" '
      'Item:Semantic="MotionPhoto" Item:Length="$videoLength" '
      'Item:Padding="0"/></rdf:li>'
      '</rdf:Seq></Container:Directory></rdf:Description></x:xmpmeta>';
  final video = Uint8List(videoLength);
  video[3] = 24;
  video.setRange(4, 8, 'ftyp'.codeUnits);
  for (var i = 8; i < videoLength; i++) {
    video[i] = i & 0xFF;
  }
  return Uint8List.fromList([
    0xFF,
    0xD8,
    ...xmp.codeUnits,
    ...List<int>.filled(2048, 0),
    ...video,
  ]);
}

Note _note({
  required String id,
  required String content,
  List<Map<String, dynamic>> resourceList = const [],
}) =>
    Note(
      id: id,
      content: content,
      createdAt: DateTime(2026, 11, 10),
      updatedAt: DateTime(2026, 11, 10),
      resourceList: resourceList,
    );

void main() {
  late Directory imagesDir;
  late BackupArchiveService service;

  setUp(() async {
    imagesDir = await Directory.systemTemp.createTemp('inkpaper_backup_test');
    service = BackupArchiveService(
      imagesDirectoryProvider: () async => imagesDir,
      // 单测里没有 path_provider 通道，落盘位置直接给系统临时目录
      tempDirectoryProvider: () async => Directory.systemTemp,
    );
  });

  tearDown(() async {
    if (await imagesDir.exists()) {
      await imagesDir.delete(recursive: true);
    }
  });

  Future<File> writeImage(String name) async {
    final file = File('${imagesDir.path}${Platform.pathSeparator}$name');
    await file.writeAsBytes(_tinyPng, flush: true);
    return file;
  }

  /// 造一段「视频」：内容不重要，体积和扩展名才是被测对象。
  Future<File> writeVideo(String name, {int size = 2048}) async {
    final file = File('${imagesDir.path}${Platform.pathSeparator}$name');
    await file.writeAsBytes(Uint8List(size), flush: true);
    return file;
  }

  group('导出打包', () {
    test('JSON 导出会把图片一起塞进 zip，并在导入时还原路径', () async {
      final image = await writeImage('photo.png');
      final note = _note(
        id: 'note-1',
        content: '看图 ![猫](${image.path}) 完',
      );

      final built = await service.buildArchive(
        notes: [note],
        format: BackupContentFormat.json,
        includeImages: true,
      );

      expect(built.imageCount, 1);
      expect(built.missingImageCount, 0);
      expect(built.noteCount, 1);

      // 包里应该有正文、图片、两份清单
      final decoded = await service.decodeArchive(built.bytes);
      expect(decoded.format, BackupContentFormat.json);
      expect(decoded.restoredImageCount, 1);
      expect(decoded.entries, hasLength(1));
      expect(decoded.entries.first.name, 'notes.json');

      // 正文里的旧路径已被换成本地还原出来的图片
      final body = decoded.entries.first.content;
      final json = jsonDecode(body) as Map<String, dynamic>;
      final notes = json['notes'] as List<dynamic>;
      expect(notes, hasLength(1));
      final restored =
          (notes.first as Map<String, dynamic>)['content'] as String;
      expect(restored, isNot(contains(image.path)));
      final restoredPath =
          RegExp(r'file://([^)\s]+)').firstMatch(restored)?.group(1);
      expect(restoredPath, isNotNull);
      expect(File(restoredPath!).existsSync(), isTrue);
    });

    test('Markdown 导出每篇一个 md，图片随包走', () async {
      final image = await writeImage('a.jpg');
      final notes = [
        _note(id: 'n1', content: '一 ![x](${image.path})'),
        _note(id: 'n2', content: '二'),
      ];

      final built = await service.buildArchive(
        notes: notes,
        format: BackupContentFormat.markdown,
        includeImages: true,
        markdownExporter: (note) => '---\nid: ${note.id}\n---\n${note.content}',
      );
      expect(built.imageCount, 1);

      final decoded = await service.decodeArchive(built.bytes);
      expect(decoded.format, BackupContentFormat.markdown);
      expect(
        decoded.entries.map((entry) => entry.name),
        containsAll(<String>['note_1.md', 'note_2.md']),
      );
      expect(decoded.entries.first.content.contains('file://'), isTrue);
    });

    test('TXT 导出保留可回导的分隔格式，并同样打图', () async {
      final image = await writeImage('b.png');
      final built = await service.buildArchive(
        notes: [
          _note(id: 'txt-1', content: '正文 ![y](${image.path})'),
        ],
        format: BackupContentFormat.txt,
        includeImages: true,
      );

      final decoded = await service.decodeArchive(built.bytes);
      expect(decoded.format, BackupContentFormat.txt);
      expect(decoded.entries.single.name, 'notes.txt');
      expect(decoded.entries.single.content, contains('--- 笔记 txt-1 ---'));
      expect(decoded.restoredImageCount, 1);
    });

    test('HTML 导出把图片换成包内相对路径', () async {
      final image = await writeImage('c.png');
      final built = await service.buildArchive(
        notes: [_note(id: 'h1', content: '标题\n![图](${image.path})')],
        format: BackupContentFormat.html,
        includeImages: true,
      );

      final decoded = await service.decodeArchive(built.bytes);
      expect(decoded.format, BackupContentFormat.html);
      final html = decoded.entries.single.content;
      expect(html, contains('<img src="resources/'));
      expect(html.contains('<script'), isFalse);
    });

    test('图片本地不存在时只计数，不影响正文导出', () async {
      final built = await service.buildArchive(
        notes: [
          _note(id: 'm1', content: '![失效](/file/attachments/missing.png)'),
        ],
        format: BackupContentFormat.json,
        includeImages: true,
      );

      expect(built.imageCount, 0);
      expect(built.missingImageCount, 1);
      expect(built.bytes, isNotEmpty);
    });

    test('只统计正文引用的缺失图片，resourceList 找不到不算缺', () async {
      final built = await service.buildArchive(
        notes: [
          _note(
            id: 'm2',
            content: '正文引用 ![失效](/file/attachments/missing.png)',
            resourceList: const [
              {
                'filename': 'not-here.png',
                'path': '/file/attachments/other.png',
              },
            ],
          ),
        ],
        format: BackupContentFormat.json,
        includeImages: true,
      );

      expect(built.missingImageCount, 1);
    });

    test('关掉「包含图片」就不打包任何图片', () async {
      final image = await writeImage('d.png');
      final built = await service.buildArchive(
        notes: [_note(id: 'n1', content: '![x](${image.path})')],
        format: BackupContentFormat.json,
        includeImages: false,
      );

      expect(built.imageCount, 0);
      final decoded = await service.decodeArchive(built.bytes);
      expect(decoded.restoredImageCount, 0);
      // 原路径保留，重新登录服务器后仍能按需下载
      expect(decoded.entries.first.content, contains('d.png'));
      expect(decoded.entries.first.content, isNot(contains('file://')));
    });

    test('resourceList 里的相对文件名也能按图片目录找到', () async {
      await writeImage('relative.png');
      final built = await service.buildArchive(
        notes: [
          _note(
            id: 'r1',
            content: '无正文引用',
            resourceList: const [
              {'filename': 'relative.png', 'path': '/file/attachments/x.png'},
            ],
          ),
        ],
        format: BackupContentFormat.json,
        includeImages: true,
      );

      expect(built.imageCount, 1);
    });
  });

  group('视频备份', () {
    test('视频随包打包，不混进图片统计，导入时还原到本地', () async {
      final video = await writeVideo('video_1.mp4');
      final built = await service.buildArchive(
        notes: [_note(id: 'v1', content: '录屏 ![视频](${video.path})')],
        format: BackupContentFormat.json,
        includeImages: true,
        includeVideos: true,
      );

      expect(built.videoCount, 1);
      expect(built.imageCount, 0);
      expect(built.missingVideoCount, 0);

      final decoded = await service.decodeArchive(built.bytes);
      expect(decoded.restoredVideoCount, 1);
      expect(decoded.restoredImageCount, 0);

      // 正文里的旧路径换成本地还原出来的文件，且文件真的落盘
      final json =
          jsonDecode(decoded.entries.first.content) as Map<String, dynamic>;
      final content = ((json['notes'] as List).first
          as Map<String, dynamic>)['content'] as String;
      expect(content, isNot(contains(video.path)));
      final restoredPath =
          RegExp(r'file://([^)\s]+)').firstMatch(content)?.group(1);
      expect(restoredPath, isNotNull);
      expect(File(restoredPath!).existsSync(), isTrue);
      expect(restoredPath, endsWith('.mp4'));
    });

    test('关掉「包含视频」就不打包视频，正文保留原路径', () async {
      final video = await writeVideo('video_2.mp4');
      final built = await service.buildArchive(
        notes: [_note(id: 'v2', content: '![视频](${video.path})')],
        format: BackupContentFormat.json,
        includeImages: true,
      );

      expect(built.videoCount, 0);
      final decoded = await service.decodeArchive(built.bytes);
      expect(decoded.restoredVideoCount, 0);
      expect(decoded.entries.first.content, contains('video_2.mp4'));
    });

    test('只开视频、关掉图片时视频照样进包', () async {
      final video = await writeVideo('video_3.mov');
      final built = await service.buildArchive(
        notes: [_note(id: 'v3', content: '![视频](${video.path})')],
        format: BackupContentFormat.json,
        includeImages: false,
        includeVideos: true,
      );

      expect(built.videoCount, 1);
      expect(built.imageCount, 0);
      expect(built.missingImageCount, 0);
    });

    test('「包含图片」不会顺手把视频当图片打包', () async {
      final video = await writeVideo('video_4.mp4');
      final built = await service.buildArchive(
        notes: [_note(id: 'v4', content: '![视频](${video.path})')],
        format: BackupContentFormat.json,
        includeImages: true,
      );

      expect(built.imageCount, 0);
      expect(built.missingImageCount, 0);
    });

    test('服务端无扩展名的视频靠 alt 判定，不算缺图片', () async {
      final built = await service.buildArchive(
        notes: [
          _note(
            id: 'v5',
            content: '![视频](/o/r/abc123)',
            resourceList: const [
              {'path': '/o/r/abc123', 'alt': '视频', 'filename': 'clip.mov'},
            ],
          ),
        ],
        format: BackupContentFormat.json,
        includeImages: true,
        includeVideos: true,
      );

      expect(built.imageCount, 0);
      expect(built.missingImageCount, 0);
      expect(built.missingVideoCount, 1);
    });

    test('超过单段体积上限的视频跳过并计数', () async {
      final tight = BackupArchiveService(
        imagesDirectoryProvider: () async => imagesDir,
        tempDirectoryProvider: () async => Directory.systemTemp,
        maxSingleVideoBytes: 1024,
      );
      final video = await writeVideo('big.mp4', size: 4096);
      final built = await tight.buildArchive(
        notes: [_note(id: 'v6', content: '![视频](${video.path})')],
        format: BackupContentFormat.json,
        includeImages: false,
        includeVideos: true,
      );

      expect(built.videoCount, 0);
      expect(built.skippedVideoCount, 1);
      // 跳过不等于丢失：正文原样保留，重新登录或走 WebDAV 还能补回来
      expect(built.missingVideoCount, 0);
    });

    test('Live 图的动态片段跟着静图进包，还原时按同名落盘', () async {
      // Live 图的正文里只有一张静图，动图片段是旁边的 `<图>.live.mp4`。
      // 只按正文引用打包会把片段漏掉，恢复出来的「动图」就成了静态图。
      final image = await writeImage('live_1.jpg');
      final sidecar = File(LivePhotoUtils.videoPathFor(image.path));
      await sidecar.writeAsBytes(Uint8List(4096), flush: true);

      final built = await service.buildArchive(
        notes: [_note(id: 'lv1', content: '动图 ![图片](${image.path})')],
        format: BackupContentFormat.json,
        // 故意不开「包含视频」：动图片段是图片的一部分，不是正文视频
        includeImages: true,
      );

      expect(built.imageCount, 1);
      expect(built.videoCount, 1, reason: '动图片段按视频计数');

      final decoded = await service.decodeArchive(built.bytes);
      final json =
          jsonDecode(decoded.entries.first.content) as Map<String, dynamic>;
      final content = ((json['notes'] as List).first
          as Map<String, dynamic>)['content'] as String;
      final restoredImage =
          RegExp(r'file://([^)\s]+)').firstMatch(content)?.group(1);
      expect(restoredImage, isNotNull);
      // 角标只看这个：还原后的图片旁边必须有同名片段
      expect(LivePhotoUtils.hasLiveVideo(restoredImage!), isTrue);
      expect(
        File(LivePhotoUtils.videoPathFor(restoredImage)).lengthSync(),
        4096,
      );
    });

    test('没抽过侧车的动图，备份时从图片字节里切出片段', () async {
      // 小米相机的 MVIMG 是「Container 目录」格式，片段就嵌在 JPEG 里，
      // 播放过之前不会有 `<图>.live.mp4`。只按侧车打包会把动图退化成静态图。
      const videoLength = 8192;
      final image = File('${imagesDir.path}${Platform.pathSeparator}mv2.jpg');
      await image.writeAsBytes(
        _containerMotionPhoto(videoLength: videoLength),
        flush: true,
      );
      expect(LivePhotoUtils.hasLiveVideo(image.path), isFalse);

      final built = await service.buildArchive(
        notes: [_note(id: 'lv2', content: '动图 ![图片](${image.path})')],
        format: BackupContentFormat.json,
        includeImages: true,
      );

      expect(built.imageCount, 1);
      expect(built.videoCount, 1, reason: '内嵌片段按视频计数');

      final decoded = await service.decodeArchive(built.bytes);
      final json =
          jsonDecode(decoded.entries.first.content) as Map<String, dynamic>;
      final content = ((json['notes'] as List).first
          as Map<String, dynamic>)['content'] as String;
      final restoredImage =
          RegExp(r'file://([^)\s]+)').firstMatch(content)?.group(1);
      expect(restoredImage, isNotNull);
      expect(LivePhotoUtils.hasLiveVideo(restoredImage!), isTrue);
      expect(
        File(LivePhotoUtils.videoPathFor(restoredImage)).lengthSync(),
        videoLength,
      );
    });

    test('HTML 导出把视频渲染成 video 标签', () async {
      final video = await writeVideo('video_7.mp4');
      final built = await service.buildArchive(
        notes: [_note(id: 'v7', content: '录屏\n![视频](${video.path})')],
        format: BackupContentFormat.html,
        includeImages: true,
        includeVideos: true,
      );

      final html =
          (await service.decodeArchive(built.bytes)).entries.single.content;
      expect(html, contains('<video'));
      expect(html, contains('resources/video_'));
    });
  });

  group('流式打包', () {
    test('视频按 STORE 流式写入，图片与正文仍压缩', () async {
      await writeImage('photo.png');
      final video = await writeVideo('clip.mp4', size: 4096);
      final built = await service.buildArchive(
        notes: [
          _note(
            id: 'n1',
            content: '![](photo.png)\n![视频](${video.path})\n${'正文' * 400}',
          ),
        ],
        format: BackupContentFormat.json,
        includeImages: true,
        includeVideos: true,
      );

      final archive = ZipDecoder().decodeBytes(built.bytes);
      final videoEntry = archive.files.firstWhere(
        (file) => file.name.startsWith('resources/video_'),
      );
      expect(
        videoEntry.compress,
        isFalse,
        reason: 'deflate 分支会先把整个条目读成 Uint8List 再压，'
            '150MB 的视频等于把省下的内存又拿回来',
      );
      expect(videoEntry.size, video.lengthSync());

      final imageEntry = archive.files.firstWhere(
        (file) => file.name.startsWith('resources/note_'),
      );
      expect(
        imageEntry.compress,
        isTrue,
        reason: '图片要整张读出来切动图片段，压缩不会再额外占一份整图',
      );

      final text = archive.files.firstWhere(
        (file) => file.name == 'notes.json',
      );
      expect(text.compress, isTrue, reason: '正文只有几百 KB，压缩更划算');
      expect(text.rawContent!.length, lessThan(text.size));
    });

    test('跨多个 1MB 块的大视频按原样还原', () async {
      // 6MB 视频：流式写出每次只取 1MB，跨块边界不能截断或错位
      final video = await writeVideo('big.mp4', size: 6 * 1024 * 1024);
      final original = await video.readAsBytes();
      final built = await service.buildArchive(
        notes: [_note(id: 'v1', content: '![视频](${video.path})')],
        format: BackupContentFormat.json,
        includeImages: false,
        includeVideos: true,
      );

      final decoded = await service.decodeArchive(built.bytes);
      final restored = RegExp(
        r'file://([^)\s]+)',
      ).firstMatch(decoded.entries.single.content)?.group(1);
      expect(decoded.restoredVideoCount, 1);
      expect(restored, isNotNull);
      expect(
        await File(restored!).readAsBytes(),
        orderedEquals(original),
        reason: '分块读写必须逐字节一致',
      );
    });

    test('老版本整包压缩出来的媒体条目仍能还原', () async {
      // 旧备份把图片也 deflate 了；现在的写入端改成 STORE，但读端必须两种都认。
      final imageBytes = await writeImage('legacy.png').then(
        (file) => file.readAsBytes(),
      );
      final notesJson = jsonEncode({
        'version': '1.0',
        'notes': [
          {'content': '![](legacy.png)'},
        ],
      });
      final resourcesJson = jsonEncode({
        'version': '1.0',
        'resources': [
          {
            'originalPath': 'legacy.png',
            'archivePath': 'resources/note_1_1.png',
          },
        ],
      });
      final archive = Archive()
        ..addFile(
          ArchiveFile(
            'resources/note_1_1.png',
            imageBytes.length,
            imageBytes,
          ),
        )
        ..addFile(
          ArchiveFile(
            'notes.json',
            utf8.encode(notesJson).length,
            utf8.encode(notesJson),
          ),
        )
        ..addFile(
          ArchiveFile(
            'resource_manifest.json',
            utf8.encode(resourcesJson).length,
            utf8.encode(resourcesJson),
          ),
        );
      final legacy = Uint8List.fromList(ZipEncoder().encode(archive)!);

      final decoded = await service.decodeArchive(legacy);
      expect(decoded.restoredImageCount, 1);
      expect(decoded.entries.single.content, contains('file://'));
    });

    test('中途失败删掉半成品，重试能成功', () async {
      await writeImage('a.png');
      await writeImage('b.png');
      final note = _note(id: 'n1', content: '![](a.png)\n![](b.png)');
      final outDir = await Directory.systemTemp.createTemp('backup_out');
      addTearDown(() => outDir.delete(recursive: true));
      final target = File('${outDir.path}/backup.zip');

      // 第二次去取图片目录时抛错：此时第一条媒体已经写进 zip
      var calls = 0;
      final flaky = BackupArchiveService(
        tempDirectoryProvider: () async => Directory.systemTemp,
        imagesDirectoryProvider: () async {
          calls++;
          if (calls >= 2) {
            throw const FileSystemException('模拟取图片目录失败');
          }
          return imagesDir;
        },
      );

      await expectLater(
        flaky.buildArchiveToFile(
          target: target,
          notes: [note],
          format: BackupContentFormat.json,
          includeImages: true,
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        target.existsSync(),
        isFalse,
        reason: '写了一半的 zip 不能留给用户，否则会被当成有效备份',
      );

      final retried = await service.buildArchiveToFile(
        target: target,
        notes: [note],
        format: BackupContentFormat.json,
        includeImages: true,
      );
      expect(retried.imageCount, 2);
      expect(target.existsSync(), isTrue);
    });
  });

  group('解包兼容', () {
    test('没有 backup_manifest 的旧包按扩展名识别为 Markdown', () async {
      final bytes = _makeZip({
        'note_1.md': '---\nid: legacy\n---\n旧格式',
        'resource_manifest.json': jsonEncode({
          'version': '1.0',
          'resources': <Map<String, String>>[],
        }),
      });

      final decoded = await service.decodeArchive(bytes);
      expect(decoded.format, BackupContentFormat.markdown);
      expect(decoded.entries.first.name, 'note_1.md');
      expect(decoded.entries.first.content, contains('旧格式'));
    });

    test('包里没有任何正文时报错', () async {
      final bytes = _makeZip({
        'backup_manifest.json': jsonEncode({
          'version': '2.0',
          'format': 'JSON',
        }),
      });

      await expectLater(
        service.decodeArchive(bytes),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('导入回滚', () {
    /// 造一个「一条 JSON 笔记 + 一张图」的包，解包后会往图片目录写一份副本。
    Future<Uint8List> imagePackage() async {
      final image = await writeImage('rollback_src.png');
      final built = await service.buildArchive(
        notes: [_note(id: 'rb', content: '看图 ![猫](${image.path}) 完')],
        format: BackupContentFormat.json,
        includeImages: true,
      );
      return built.bytes;
    }

    List<File> backupCopies() => imagesDir
        .listSync()
        .whereType<File>()
        .where(
          (file) =>
              file.uri.pathSegments.last.startsWith('backup_image_') ||
              file.uri.pathSegments.last.startsWith('backup_video_'),
        )
        .toList();

    test('解包会记下本次新建的文件，回滚只删这些', () async {
      final bytes = await imagePackage();
      // 导入前就在目录里的文件：回滚必须一个都不碰
      final existing = await writeImage('user_photo_before.png');

      final decoded = await service.decodeArchive(bytes);
      expect(decoded.restoredLocalPaths, hasLength(1));
      final restoredPath = decoded.restoredLocalPaths.single;
      expect(File(restoredPath).existsSync(), isTrue);

      // 正文确实指向这份副本（Windows 上 JSON 里的反斜杠是转义过的）
      final json =
          jsonDecode(decoded.entries.single.content) as Map<String, dynamic>;
      final content = ((json['notes'] as List).first
          as Map<String, dynamic>)['content'] as String;
      final referenced =
          RegExp(r'file://([^)\s]+)').firstMatch(content)?.group(1);
      expect(referenced, isNotNull);
      expect(referenced!.replaceAll(r'\\', r'\'), restoredPath);

      expect(await service.discardRestoredResources(decoded), 1);
      expect(File(restoredPath).existsSync(), isFalse);
      expect(existing.existsSync(), isTrue, reason: '导入前就在目录里的文件不能碰');
    });

    test('包里没有正文时，已还原的资源跟着回滚', () async {
      final bytes = _makeZipBytes({
        'backup_manifest.json': utf8.encode(
          jsonEncode({'version': '2.0', 'format': 'JSON'}),
        ),
        'resource_manifest.json': utf8.encode(
          jsonEncode({
            'version': '2.0',
            'resources': [
              {
                'originalPath': 'file:///old/photo.png',
                'archivePath': 'resources/photo.png',
              },
            ],
          }),
        ),
        'resources/photo.png': _tinyPng,
      });
      final existing = await writeImage('keep_me.png');

      await expectLater(
        service.decodeArchive(bytes),
        throwsA(isA<Exception>()),
      );

      expect(
        backupCopies(),
        isEmpty,
        reason: '没有笔记会引用它们，留在图片目录里就是孤儿文件',
      );
      expect(existing.existsSync(), isTrue);
    });

    test('同一毫秒里重复解包不会覆盖上次还原的图', () async {
      // 文件名原来用「毫秒时间戳 + 本次序号」，连导两次很容易撞名，
      // 第二次会把第一次的图直接覆盖掉，第一条笔记就指向了别的内容。
      final fixedClock = BackupArchiveService(
        imagesDirectoryProvider: () async => imagesDir,
        tempDirectoryProvider: () async => Directory.systemTemp,
        now: () => DateTime(2026, 11, 24, 12),
      );
      final bytes = await imagePackage();

      final first = await fixedClock.decodeArchive(bytes);
      final second = await fixedClock.decodeArchive(bytes);

      expect(
        second.restoredLocalPaths.single,
        isNot(first.restoredLocalPaths.single),
      );
      expect(
        File(first.restoredLocalPaths.single).existsSync(),
        isTrue,
        reason: '第二次解包不能盖掉第一次还原的图',
      );
    });

    test('导入 0 条整批清理，之前成功导入的图不受影响', () async {
      final bytes = await imagePackage();

      final first = await service.decodeArchive(bytes);
      expect(await service.finalizeRestore(first, importedCount: 1), 0);
      expect(File(first.restoredLocalPaths.single).existsSync(), isTrue);

      final second = await service.decodeArchive(bytes);
      expect(await service.finalizeRestore(second, importedCount: 0), 1);
      expect(File(second.restoredLocalPaths.single).existsSync(), isFalse);
      expect(
        File(first.restoredLocalPaths.single).existsSync(),
        isTrue,
        reason: '第一次的图还被笔记引用，只能删本次新增的',
      );
    });

    test('中断留下的文件不参与下一次回滚', () async {
      final bytes = await imagePackage();
      // 模拟进程被杀：解包写完资源，既没提交也没回滚
      final interrupted = await service.decodeArchive(bytes);
      final retried = await service.decodeArchive(bytes);

      expect(await service.discardRestoredResources(retried), 1);
      expect(File(retried.restoredLocalPaths.single).existsSync(), isFalse);
      expect(
        File(interrupted.restoredLocalPaths.single).existsSync(),
        isTrue,
        reason: '回滚只按本次清单删，不能越界清上次中断的残留',
      );
    });

    test('Live 图的动图片段也在回滚清单里', () async {
      final image = await writeImage('live_rb.jpg');
      await File(LivePhotoUtils.videoPathFor(image.path))
          .writeAsBytes(Uint8List(2048), flush: true);
      final built = await service.buildArchive(
        notes: [_note(id: 'lvr', content: '动图 ![图片](${image.path})')],
        format: BackupContentFormat.json,
        includeImages: true,
      );

      final decoded = await service.decodeArchive(built.bytes);
      expect(decoded.restoredLocalPaths, hasLength(2));
      final restoredImage = decoded.restoredLocalPaths
          .firstWhere((path) => !path.endsWith('.mp4'));
      final sidecar = LivePhotoUtils.videoPathFor(restoredImage);
      expect(decoded.restoredLocalPaths, contains(sidecar));
      expect(File(sidecar).existsSync(), isTrue);

      expect(await service.discardRestoredResources(decoded), 2);
      expect(File(restoredImage).existsSync(), isFalse);
      expect(File(sidecar).existsSync(), isFalse);
    });

    /// 造一个「一条 JSON 笔记 + 两张图」的包：解包会写两份资源副本。
    Future<Uint8List> twoImagePackage() async {
      final first = await writeImage('rb_a.png');
      final second = await writeImage('rb_b.png');
      final built = await service.buildArchive(
        notes: [
          _note(
            id: 'rb2',
            content: '两张图 ![一](${first.path}) 和 ![二](${second.path}) 结束',
          ),
        ],
        format: BackupContentFormat.json,
        includeImages: true,
      );
      return built.bytes;
    }

    /// 固定时钟的 service：还原文件名可预测，才能用同名目录占位制造写失败。
    BackupArchiveService fixedClockService({
      Future<void> Function()? beforeDecodeEntries,
      Future<void> Function(File file, List<int> bytes)? resourceWriter,
    }) {
      final clock = DateTime(2026, 11, 24, 12);
      return BackupArchiveService(
        imagesDirectoryProvider: () async => imagesDir,
        tempDirectoryProvider: () async => Directory.systemTemp,
        now: () => clock,
        beforeDecodeEntries: beforeDecodeEntries,
        resourceWriter: resourceWriter,
      );
    }

    test('第一个附件写成功、第二个写失败时，已落盘那个也一起回滚', () async {
      final fixedClock = fixedClockService();
      final bytes = await twoImagePackage();
      // 导入前就在目录里的文件：回滚必须一个都不碰、内容也不能变
      final existing = await writeImage('user_photo_before.png');

      // 用同名目录占住第二个还原文件名：分配器查的是 File.exists()
      // （目录算“不存在”），真正落盘时才抛 PathAccessException，
      // 等价于磁盘写失败。
      final stamp = DateTime(2026, 11, 24, 12).millisecondsSinceEpoch;
      final blocker = Directory(
        '${imagesDir.path}${Platform.pathSeparator}backup_image_${stamp}_1.png',
      );
      await blocker.create(recursive: true);

      await expectLater(
        fixedClock.decodeArchive(bytes),
        throwsA(isA<FileSystemException>()),
      );

      expect(
        backupCopies(),
        isEmpty,
        reason: '第一个附件已经写进磁盘，失败时必须跟着回滚，不能留成孤儿文件',
      );
      expect(existing.existsSync(), isTrue, reason: '导入前的文件不能删');
      expect(existing.readAsBytesSync(), _tinyPng, reason: '导入前的文件内容不能改');
      expect(blocker.existsSync(), isTrue, reason: '占位目录不是本批新建的文件');
    });

    test('附件写完后正文读取失败，本批文件同样回滚', () async {
      final bytes = await imagePackage();
      final existing = await writeImage('user_photo_keep.png');
      final failing = fixedClockService(
        beforeDecodeEntries: () async => throw StateError('正文读取失败'),
      );

      final decode = failing.decodeArchive(bytes);
      await expectLater(decode, throwsA(isA<StateError>()));

      expect(backupCopies(), isEmpty, reason: '附件已落盘，正文读取失败后不能留残留');
      expect(existing.existsSync(), isTrue);
      expect(existing.readAsBytesSync(), _tinyPng);
    });

    test('失败后重试能重新还原，磁盘上只多出重试那一批文件', () async {
      final fixedClock = fixedClockService();
      final bytes = await twoImagePackage();
      final existing = await writeImage('user_photo_before.png');
      final stamp = DateTime(2026, 11, 24, 12).millisecondsSinceEpoch;
      final blocker = Directory(
        '${imagesDir.path}${Platform.pathSeparator}backup_image_${stamp}_1.png',
      );
      await blocker.create(recursive: true);

      await expectLater(
        fixedClock.decodeArchive(bytes),
        throwsA(isA<FileSystemException>()),
      );
      expect(backupCopies(), isEmpty);

      // 磁盘问题修掉后重试：应该完整还原两份，且不复活失败那批的残留
      await blocker.delete();
      final retried = await fixedClock.decodeArchive(bytes);
      expect(retried.restoredLocalPaths, hasLength(2));
      for (final path in retried.restoredLocalPaths) {
        expect(File(path).existsSync(), isTrue);
      }
      expect(
        backupCopies(),
        hasLength(2),
        reason: '失败那批已经回滚，目录里只剩重试新建的两份',
      );
      expect(existing.existsSync(), isTrue);
    });

    test('附件写到一半就失败时，磁盘上的半成品也一起回滚', () async {
      final bytes = await twoImagePackage();
      // 导入前就在目录里的文件：回滚必须一个都不碰、内容也不能变
      final existing = await writeImage('user_photo_before.png');
      final stamp = DateTime(2026, 11, 24, 12).millisecondsSinceEpoch;
      final partialPath =
          '${imagesDir.path}${Platform.pathSeparator}backup_image_${stamp}_1.png';

      // 真机上是写到一半被打断（进程被杀 / 存储耗尽）：目标路径上已经有几个
      // 字节，但 writeAsBytes 抛错时这个路径还没进本批清单。
      final failing = fixedClockService(
        resourceWriter: (file, content) async {
          if (file.path != partialPath) {
            await file.writeAsBytes(content, flush: true);
            return;
          }
          await file.writeAsBytes(content.take(4).toList(), flush: true);
          throw FileSystemException('模拟写入中断', partialPath);
        },
      );

      await expectLater(
        failing.decodeArchive(bytes),
        throwsA(
          isA<FileSystemException>().having(
            (e) => e.message,
            'message',
            '模拟写入中断',
          ),
        ),
      );

      expect(backupCopies(), isEmpty, reason: '写完的那个和半成品都不能留在磁盘上');
      expect(File(partialPath).existsSync(), isFalse, reason: '半成品也要回滚');
      expect(existing.existsSync(), isTrue, reason: '导入前的文件不能删');
      expect(existing.readAsBytesSync(), _tinyPng, reason: '导入前的文件内容不能改');
    });

    test('静图名空闲、配套视频名被占用时，还原不能用会撞车的那对名字', () async {
      final image = await writeImage('live_rb.jpg');
      await File(LivePhotoUtils.videoPathFor(image.path))
          .writeAsBytes(Uint8List(2048), flush: true);
      final built = await service.buildArchive(
        notes: [_note(id: 'lvc', content: '动图 ![图片](${image.path})')],
        format: BackupContentFormat.json,
        includeImages: true,
      );

      final stamp = DateTime(2026, 11, 24, 12).millisecondsSinceEpoch;
      // 导入前就有的视频，名字正好压在第一个候选静图的侧车路径上。以前这里
      // 会被还原过程覆盖、正文处理失败后又被当成"本批新建"删掉。
      final occupied = File(
        '${imagesDir.path}${Platform.pathSeparator}backup_image_$stamp.live.mp4',
      );
      final originalBytes = List<int>.generate(64, (i) => i + 1);
      await occupied.writeAsBytes(originalBytes, flush: true);

      final failing = fixedClockService(
        beforeDecodeEntries: () async => throw StateError('正文读取失败'),
      );
      final decode = failing.decodeArchive(built.bytes);
      await expectLater(decode, throwsA(isA<StateError>()));

      expect(occupied.existsSync(), isTrue, reason: '导入前的视频不能被删');
      expect(
        occupied.readAsBytesSync(),
        originalBytes,
        reason: '导入前的视频内容也不能被覆盖',
      );
      expect(
        backupCopies().where((file) => file.path != occupied.path),
        isEmpty,
        reason: '本批还原的静图和侧车都要回滚',
      );

      // 正常恢复要仍然成对：静图与 `<静图>.live.mp4` 一起落在本地
      final decoded = await fixedClockService().decodeArchive(built.bytes);
      final restoredImage = decoded.restoredLocalPaths.firstWhere(
        (path) => !path.endsWith('.mp4'),
      );
      final sidecar = LivePhotoUtils.videoPathFor(restoredImage);
      expect(decoded.restoredLocalPaths, contains(sidecar));
      expect(File(restoredImage).existsSync(), isTrue);
      expect(File(sidecar).existsSync(), isTrue);
      expect(
        occupied.readAsBytesSync(),
        originalBytes,
        reason: '绕开撞车名字之后，已有视频依旧原样',
      );
    });
  });
}

/// 手工拼一个最小 zip，用来模拟老版本或异常备份包
Uint8List _makeZip(Map<String, String> files) => _makeZipBytes({
      for (final entry in files.entries) entry.key: utf8.encode(entry.value),
    });

/// 同上，但条目内容可以是任意字节（资源文件测试要用）。
Uint8List _makeZipBytes(Map<String, List<int>> files) {
  final archive = Archive();
  files.forEach((name, bytes) {
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}
