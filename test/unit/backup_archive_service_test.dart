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
}

/// 手工拼一个最小 zip，用来模拟老版本或异常备份包
Uint8List _makeZip(Map<String, String> files) {
  final archive = Archive();
  files.forEach((name, content) {
    final bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}
