import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/utils/attachment_cache.dart';
import 'package:inkpaper/utils/attachment_maintenance.dart';

void main() {
  late Directory tempDir;
  final cache = AttachmentCache.instance;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('inkpaper_attachment_');
    cache.debugSetImagesDir(tempDir.path);
  });

  tearDown(() async {
    cache.debugSetImagesDir(null);
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('本地有同名 sha1 文件时命中缓存', () async {
    const remote = '/file/attachments/AAA111/image_1.jpg';
    final file = File('${tempDir.path}/${localFileNameForAttachment(remote)}');
    await file.writeAsBytes([1, 2, 3]);

    expect(cache.fileFor(remote)?.path, file.path);
    expect(cache.pathFor(remote), file.path);
  });

  test('本机没有副本时返回 null，下载后重新查盘命中', () async {
    const remote = '/file/attachments/BBB222/image_2.png';
    expect(cache.fileFor(remote), isNull);

    final file = File('${tempDir.path}/${localFileNameForAttachment(remote)}');
    await file.writeAsBytes([4, 5, 6]);

    // 命中结果被记忆，必须 invalidate 后才会重新查盘
    expect(cache.fileFor(remote), isNull);
    cache.invalidate();
    expect(cache.fileFor(remote)?.path, file.path);
  });

  test('非服务端路径不参与附件缓存', () async {
    const local = 'images/a.jpg';
    await File('${tempDir.path}/a.jpg').writeAsBytes([7]);

    expect(cache.fileFor(local), isNull);
    expect(cache.fileFor('https://example.com/a.jpg'), isNull);
  });
}
