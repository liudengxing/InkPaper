import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:inkpaper/utils/image_decode_width.dart';
import 'package:inkpaper/utils/thumb_cache.dart';
import 'package:path/path.dart' as p;

/// 造一张纯色图，尺寸与真实照片一样是宽大于高。
Uint8List _makeImage(int width, int height) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(36, 71, 61));
  return Uint8List.fromList(img.encodePng(image));
}

void main() {
  late Directory root;
  late String imagesDir;
  late String thumbsDir;

  setUp(() {
    root = Directory.systemTemp.createTempSync('inkpaper_thumb_test');
    imagesDir = p.join(root.path, 'images');
    thumbsDir = p.join(root.path, 'thumbs');
    Directory(imagesDir).createSync(recursive: true);
    Directory(thumbsDir).createSync(recursive: true);
    ThumbCache.instance.debugSeed(
      dirPath: thumbsDir,
      imagesDirPath: imagesDir,
    );
    // 测试里同步编码，不走 isolate
    ThumbCache.instance.debugSetEncoder(
      (bytes, width, lossless) async =>
          ThumbCache.debugEncode(bytes, width, lossless: lossless),
    );
    // lookup 未命中时的后台生成会污染断言与 tearDown，这里关掉
    ThumbCache.instance.debugSetAutoGenerateOnMiss(false);
  });

  tearDown(() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  group('ThumbCache 命名', () {
    test('TC-01 JPEG 源输出同名 jpg 缩略图', () {
      final name = ThumbCache.instance.fileNameFor('/a/images/image_1.jpg');
      expect(name, 'image_1_${ThumbCache.defaultWidth}.jpg');
    });

    test('TC-02 PNG 源保留 png，避免透明区域压成黑底', () {
      final name = ThumbCache.instance.fileNameFor('/a/images/shot.png');
      expect(name, 'shot_${ThumbCache.defaultWidth}.png');
    });

    test('TC-03 动图与 HEIC 不做缩略图', () {
      for (final ext in ['.gif', '.heic', '.heif', '.mp4']) {
        expect(
          ThumbCache.instance.fileNameFor('/a/images/x$ext'),
          isNull,
          reason: '$ext 应该回退原图',
        );
      }
    });

    test('TC-04 档位收敛到 480 / 1080 两档', () {
      expect(ThumbCache.bucketWidth(160), ThumbCache.defaultWidth);
      expect(ThumbCache.bucketWidth(480), ThumbCache.defaultWidth);
      expect(ThumbCache.bucketWidth(481), ThumbCache.largeWidth);
      expect(ThumbCache.bucketWidth(720), ThumbCache.largeWidth);
      expect(ThumbCache.bucketWidth(4000), ThumbCache.largeWidth);
    });

    test('TC-05 网格档与 image_decode_width 的常量保持一致', () {
      expect(ThumbCache.defaultWidth, kGridTileDecodeWidth);
      expect(ThumbCache.largeWidth, greaterThan(ThumbCache.defaultWidth));
    });
  });

  group('ThumbCache 命中与生成', () {
    test('TC-06 没有缩略图时 lookup 返回 null', () {
      final source = p.join(imagesDir, 'image_100.jpg');
      File(source).writeAsBytesSync(_makeImage(1200, 900));
      expect(ThumbCache.instance.lookup(source), isNull);
    });

    test('TC-07 ensure 生成 480 宽缩略图，可被正常解码', () async {
      final source = p.join(imagesDir, 'image_101.jpg');
      File(source).writeAsBytesSync(_makeImage(1600, 1200));

      final thumb = await ThumbCache.instance.ensure(source);
      expect(thumb, isNotNull);
      expect(thumb!.existsSync(), isTrue);

      final decoded = img.decodeImage(thumb.readAsBytesSync());
      expect(decoded, isNotNull);
      expect(decoded!.width, ThumbCache.defaultWidth);
      // 保持原图宽高比
      expect(decoded.height, closeTo(360, 2));
    });

    test('TC-08 生成后 lookup 同步命中同一个文件', () async {
      final source = p.join(imagesDir, 'image_102.jpg');
      File(source).writeAsBytesSync(_makeImage(1600, 1200));
      final thumb = await ThumbCache.instance.ensure(source);

      final hit = ThumbCache.instance.lookup(source);
      expect(hit, isNotNull);
      expect(hit!.path, thumb!.path);
    });

    test('TC-09 ensure 幂等，不会重复编码', () async {
      var encodes = 0;
      ThumbCache.instance.debugSetEncoder((bytes, width, lossless) async {
        encodes++;
        return ThumbCache.debugEncode(bytes, width, lossless: lossless);
      });
      final source = p.join(imagesDir, 'image_103.jpg');
      File(source).writeAsBytesSync(_makeImage(1200, 900));

      await ThumbCache.instance.ensure(source);
      await ThumbCache.instance.ensure(source);

      expect(encodes, 1);
    });

    test('TC-10 比目标窄的图不放大', () async {
      final source = p.join(imagesDir, 'image_104.jpg');
      File(source).writeAsBytesSync(_makeImage(300, 200));

      final thumb = await ThumbCache.instance.ensure(source);
      final decoded = img.decodeImage(thumb!.readAsBytesSync())!;
      expect(decoded.width, 300);
    });

    test('TC-11 源文件不存在时返回 null，不写空壳文件', () async {
      final source = p.join(imagesDir, 'image_missing.jpg');
      final thumb = await ThumbCache.instance.ensure(source);
      expect(thumb, isNull);
      expect(Directory(thumbsDir).listSync(), isEmpty);
    });

    test('TC-12 正文里的 images/x.jpg 相对路径能解析到 documents', () async {
      final source = p.join(imagesDir, 'image_105.jpg');
      File(source).writeAsBytesSync(_makeImage(900, 675));
      await ThumbCache.instance.ensure(source);

      final hit = ThumbCache.instance.lookup('images/image_105.jpg');
      expect(hit, isNotNull);
      expect(hit!.parent.path, thumbsDir);
    });

    test('TC-13 file:// 前缀与裸绝对路径命中同一份缩略图', () async {
      final source = p.join(imagesDir, 'image_106.jpg');
      File(source).writeAsBytesSync(_makeImage(900, 675));
      await ThumbCache.instance.ensure(source);

      expect(
        ThumbCache.instance.lookup('file://$source')!.path,
        ThumbCache.instance.lookup(source)!.path,
      );
    });
  });

  group('ThumbCache 补齐与清理', () {
    test('TC-14 backfill 补齐目录里所有缺失的缩略图', () async {
      for (var i = 0; i < 3; i++) {
        File(p.join(imagesDir, 'image_20$i.jpg'))
            .writeAsBytesSync(_makeImage(1200, 900));
      }
      // 已经有一张的缩略图，backfill 不该重复生成
      final existing = p.join(imagesDir, 'image_300.jpg');
      File(existing).writeAsBytesSync(_makeImage(1200, 900));
      await ThumbCache.instance.ensure(existing);

      final done = await ThumbCache.instance.backfill();
      expect(done, 3);

      final count = Directory(thumbsDir)
          .listSync()
          .whereType<File>()
          .where((f) => p.extension(f.path) == '.jpg')
          .length;
      expect(count, 4);
    });

    test('TC-15 backfill 不动目录外的东西，动图也不会生成', () async {
      File(p.join(imagesDir, 'anim.gif')).writeAsBytesSync(_makeImage(120, 90));
      final done = await ThumbCache.instance.backfill();
      expect(done, 0);
      expect(Directory(thumbsDir).listSync(), isEmpty);
    });

    test('TC-16 clear 后回到未命中状态，可重新生成', () async {
      final source = p.join(imagesDir, 'image_400.jpg');
      File(source).writeAsBytesSync(_makeImage(1200, 900));
      await ThumbCache.instance.ensure(source);
      expect(ThumbCache.instance.lookup(source), isNotNull);

      await ThumbCache.instance.clear();
      expect(ThumbCache.instance.lookup(source), isNull);

      await ThumbCache.instance.ensure(source);
      expect(ThumbCache.instance.lookup(source), isNotNull);
    });
  });
}
