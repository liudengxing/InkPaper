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
    service =
        BackupArchiveService(imagesDirectoryProvider: () async => imagesDir);
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
