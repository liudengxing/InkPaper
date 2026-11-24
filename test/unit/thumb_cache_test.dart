import 'dart:async';
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

/// 造一张纯色 JPEG，模拟原生通道产出的字节。
Uint8List _makeJpeg(int width, int height) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(36, 71, 61));
  return Uint8List.fromList(img.encodeJpg(image));
}

/// 造一个两帧 GIF：首帧红、次帧蓝，用来验证缩略图只取首帧。
Uint8List _makeAnimatedGif() {
  final first = img.Image(width: 60, height: 40, numChannels: 4);
  img.fill(first, color: img.ColorRgba8(200, 30, 30, 255));
  final second = img.Image(width: 60, height: 40, numChannels: 4);
  img.fill(second, color: img.ColorRgba8(30, 30, 200, 255));
  first.addFrame(second);
  return Uint8List.fromList(img.encodeGif(first));
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
    // 平台通道在测试环境不存在，默认给一个「解不出来」的实现，
    // 需要验证 HEIC 的用例再各自注入假解码器
    ThumbCache.instance.debugSetNativeDecoder((path, width) async => null);
  });

  tearDown(() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  test('并发请求共用同一档缩略图，等待者都得到结果', () async {
    final cache = ThumbCache.instance;
    final input = File(p.join(imagesDir, 'shared.jpg'))..writeAsBytesSync([1]);
    final started = Completer<void>();
    final release = Completer<void>();
    var decodes = 0;
    cache.debugSetEncoder((bytes, width, lossless) async {
      decodes++;
      started.complete();
      await release.future;
      return Uint8List.fromList([1, 2, 3]);
    });

    final first = cache.ensure(input.path, width: 720);
    await started.future;
    final second = cache.ensure(input.path, width: 1080);
    final observer = cache.pending(input.path, width: 1080);
    expect(observer, isNotNull);
    expect(cache.pending(input.path), isNull);
    release.complete();

    final files = await Future.wait([first, second, observer!]);
    expect(files.map((file) => file?.path).toSet(), hasLength(1));
    expect(await files.first!.exists(), isTrue);
    expect(decodes, 1);
  });

  test('后台整理清过期孤儿和超额旧小图，保留对应原图', () async {
    final cache = ThumbCache.instance;
    final old = File(p.join(imagesDir, 'old.jpg'))..writeAsBytesSync([1]);
    final recent = File(p.join(imagesDir, 'recent.jpg'))..writeAsBytesSync([2]);
    final cutoff = DateTime.now().subtract(const Duration(days: 8));
    final oldName = cache.fileNameFor(old.path)!;
    final recentName = cache.fileNameFor(recent.path)!;
    const orphanName = 'orphan_480.jpg';
    for (final name in [oldName, recentName, orphanName]) {
      final file = File(p.join(thumbsDir, name));
      await file.writeAsBytes(List.filled(6, 1));
      if (name != recentName) {
        await file.setLastModified(cutoff);
      }
    }
    cache.debugSeed(
      dirPath: thumbsDir,
      imagesDirPath: imagesDir,
      known: [oldName, recentName, orphanName],
      diskLimit: 6,
    );

    await cache.startBackfill();

    expect(cache.lookup(recent.path), isNotNull);
    expect(cache.lookup(old.path), isNull);
    expect(await File(p.join(thumbsDir, orphanName)).exists(), isFalse);
    expect(await old.exists(), isTrue);
    expect(await recent.exists(), isTrue);
  });

  test('清理等正在生成的任务退出，小图不会在清理后重新落盘', () async {
    final cache = ThumbCache.instance;
    final input = File(p.join(imagesDir, 'clearing.jpg'))
      ..writeAsBytesSync([1]);
    final started = Completer<void>();
    final release = Completer<void>();
    cache.debugSetEncoder((bytes, width, lossless) async {
      started.complete();
      await release.future;
      return Uint8List.fromList([1, 2, 3]);
    });

    final encoding = cache.ensure(input.path);
    await started.future;
    final clearing = cache.clear();
    release.complete();
    expect(await encoding, isNull);
    await clearing;
    expect(await Directory(thumbsDir).list().isEmpty, isTrue);
    expect(await input.exists(), isTrue);
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

    test('TC-03 视频与动图、HEIC 都会生成缩略图', () {
      // 视频首帧交给原生 MediaMetadataRetriever，输出 JPEG
      for (final ext in ['.mp4', '.mov', '.m4v', '.webm', '.mkv']) {
        expect(
          ThumbCache.instance.fileNameFor('/a/images/x$ext'),
          'x_${ThumbCache.defaultWidth}.jpg',
          reason: '$ext 应该有首帧封面',
        );
      }
      // GIF 取首帧、HEIC 走原生解码：都必须有名字，否则根本进不了补齐队列
      expect(
        ThumbCache.instance.fileNameFor('/a/images/x.gif'),
        'x_${ThumbCache.defaultWidth}.png',
        reason: '动图首帧常带透明，要输出 PNG',
      );
      for (final ext in ['.heic', '.heif']) {
        expect(
          ThumbCache.instance.fileNameFor('/a/images/x$ext'),
          'x_${ThumbCache.defaultWidth}.jpg',
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

    test('TC-15 动图也补出首帧缩略图，输出单帧 PNG', () async {
      File(p.join(imagesDir, 'anim.gif')).writeAsBytesSync(_makeAnimatedGif());
      final done = await ThumbCache.instance.backfill();
      expect(done, 1);
      final files = Directory(thumbsDir).listSync().whereType<File>().toList();
      expect(files.length, 1);
      expect(p.extension(files.first.path), '.png');
      final decoded = img.decodePng(files.first.readAsBytesSync());
      expect(decoded, isNotNull);
      expect(decoded!.numFrames, 1, reason: '缩略图只该保留首帧');
    });

    test('TC-20 HEIC 交给原生解码，不走 Dart 编码器', () async {
      // 目录里放的是假 HEIC：Dart 侧根本解不出来，能出图就说明走了原生通道
      final path = p.join(imagesDir, 'shot.HEIC');
      File(path).writeAsBytesSync(Uint8List.fromList(<int>[0, 1, 2, 3]));
      var calledPath = '';
      ThumbCache.instance.debugSetNativeDecoder((filePath, width) async {
        calledPath = filePath;
        expect(width, ThumbCache.defaultWidth);
        return _makeJpeg(width, 360);
      });

      final thumb = await ThumbCache.instance.ensure(path);
      expect(calledPath, path);
      expect(thumb, isNotNull);
      expect(p.basename(thumb!.path), 'shot_${ThumbCache.defaultWidth}.jpg');
      expect(thumb.lengthSync(), greaterThan(0));
    });

    test('TC-21 原生解码失败就退回原图，且本进程不再重试', () async {
      final path = p.join(imagesDir, 'broken.heic');
      File(path).writeAsBytesSync(Uint8List.fromList(<int>[9, 9, 9]));
      var calls = 0;
      ThumbCache.instance.debugSetNativeDecoder((filePath, width) async {
        calls++;
        return null;
      });

      expect(await ThumbCache.instance.ensure(path), isNull);
      expect(await ThumbCache.instance.ensure(path), isNull);
      expect(calls, 1, reason: '失败过的要进 _giveUp，补齐不能反复啃它');
    });

    test('TC-18 startBackfill 一直补到追平，重复调用复用同一个 Future', () async {
      for (var i = 0; i < 6; i++) {
        File(p.join(imagesDir, 'image_5$i.jpg'))
            .writeAsBytesSync(_makeImage(1200, 900));
      }
      // 解不出来的文件混在里面：补齐循环不能在它身上空转
      File(p.join(imagesDir, 'broken.jpg')).writeAsBytesSync(
        Uint8List.fromList(<int>[1, 2, 3, 4]),
      );

      final first = ThumbCache.instance.startBackfill();
      expect(ThumbCache.instance.startBackfill(), same(first));
      await first;
      // whenComplete 里清状态，让出一拍再断言
      await Future<void>.delayed(Duration.zero);

      expect(ThumbCache.instance.backfilledCount, 6);
      expect(ThumbCache.instance.isBackfilling, isFalse);
      final count = Directory(thumbsDir)
          .listSync()
          .whereType<File>()
          .where((f) => p.extension(f.path) == '.jpg')
          .length;
      expect(count, 6);
    });

    test('TC-19 pauseBackfill 停下，resumeBackfill 接着补到追平', () async {
      for (var i = 0; i < 8; i++) {
        File(p.join(imagesDir, 'image_6$i.jpg'))
            .writeAsBytesSync(_makeImage(1200, 900));
      }
      final future = ThumbCache.instance.startBackfill();
      ThumbCache.instance.pauseBackfill();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // 让路节奏（张间 60ms）保证 200ms 内补不完 8 张
      int thumbs() => Directory(thumbsDir)
          .listSync()
          .whereType<File>()
          .where((f) => p.extension(f.path) == '.jpg')
          .length;
      expect(thumbs(), lessThan(8));

      ThumbCache.instance.resumeBackfill();
      await future;
      expect(thumbs(), 8);
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

    test('TC-17 解不出来的文件只试一次，不会每次 build 都重来', () async {
      var encodes = 0;
      ThumbCache.instance.debugSetEncoder((bytes, width, lossless) async {
        encodes++;
        return ThumbCache.debugEncode(bytes, width, lossless: lossless);
      });
      final source = p.join(imagesDir, 'broken.jpg');
      // 不是合法图像，image 包解码会返回 null
      File(source).writeAsBytesSync(Uint8List.fromList(<int>[1, 2, 3, 4, 5]));

      expect(await ThumbCache.instance.ensure(source), isNull);
      expect(encodes, 1);

      // 打开「未命中就生成」后，同一张图不该再被尝试第二次
      ThumbCache.instance.debugSetAutoGenerateOnMiss(true);
      expect(ThumbCache.instance.lookup(source), isNull);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(encodes, 1);
    });
  });

  group('ThumbCache 索引扫描不挡首帧', () {
    test('TC-22 prepare 只等到目录可用，扫描在后台完成', () async {
      final cache = ThumbCache.instance;
      final source = File(p.join(imagesDir, 'image_700.jpg'))
        ..writeAsBytesSync(_makeImage(1200, 900));
      final name = cache.fileNameFor(source.path)!;
      final thumb = File(p.join(thumbsDir, name))
        ..writeAsBytesSync(_makeImage(480, 360));

      // 清掉 setUp 的索引，走真实的 prepare：目录已存在，扫描要另起
      cache.debugSeed(
        dirPath: thumbsDir,
        imagesDirPath: imagesDir,
        indexScanned: false,
      );

      await cache.prepare(overrideDir: thumbsDir, overrideImagesDir: imagesDir);
      expect(
        cache.debugIndexStarted,
        isTrue,
        reason: '扫描由 prepare 发起，只是不等它',
      );
      expect(
        cache.debugIndexComplete,
        isFalse,
        reason: 'prepare 不该等目录扫描，否则首帧继续被它拖住',
      );
      expect(cache.knownCount, 0);

      // 扫描窗口内首帧卡片照样命中已有缩略图
      final hitsBefore = cache.lookupHits;
      expect(cache.lookup(source.path)?.path, thumb.path);
      expect(cache.lookupHits, hitsBefore + 1);

      await cache.indexReady;
      expect(cache.debugIndexComplete, isTrue);
      expect(cache.knownCount, 1);
    });

    test('TC-23 兜底命中会补进索引，未命中的名字不入索引', () async {
      final cache = ThumbCache.instance;
      final cached = File(p.join(imagesDir, 'image_710.jpg'))
        ..writeAsBytesSync(_makeImage(1200, 900));
      final missing = File(p.join(imagesDir, 'image_711.jpg'))
        ..writeAsBytesSync(_makeImage(1200, 900));
      final name = cache.fileNameFor(cached.path)!;
      File(p.join(thumbsDir, name)).writeAsBytesSync(_makeImage(480, 360));
      cache.debugSeed(
        dirPath: thumbsDir,
        imagesDirPath: imagesDir,
        indexScanned: false,
      );

      expect(cache.lookup(cached.path), isNotNull);
      expect(cache.knownCount, 1, reason: '兜底命中的条目要收进索引');
      // 再查一次走的是索引快速路径，仍然命中
      expect(cache.lookup(cached.path), isNotNull);

      final missesBefore = cache.lookupMisses;
      expect(cache.lookup(missing.path), isNull);
      expect(cache.knownCount, 1, reason: '没有文件的名字不能进索引');
      expect(cache.lookupMisses, missesBefore + 1);
    });

    test('TC-24 扫描未完成时 ensure 复用盘上缩略图，不重新解码', () async {
      var encodes = 0;
      ThumbCache.instance.debugSetEncoder((bytes, width, lossless) async {
        encodes++;
        return ThumbCache.debugEncode(bytes, width, lossless: lossless);
      });
      final source = File(p.join(imagesDir, 'image_720.jpg'))
        ..writeAsBytesSync(_makeImage(1600, 1200));
      final name = ThumbCache.instance.fileNameFor(source.path)!;
      final thumb = File(p.join(thumbsDir, name))
        ..writeAsBytesSync(_makeImage(480, 360));
      ThumbCache.instance.debugSeed(
        dirPath: thumbsDir,
        imagesDirPath: imagesDir,
        indexScanned: false,
      );

      final result = await ThumbCache.instance.ensure(source.path);
      expect(result?.path, thumb.path);
      expect(encodes, 0, reason: '盘上已有的缩略图不能被重新编码一遍');
      expect(ThumbCache.instance.knownCount, 1);
    });

    test('TC-25 索引扫描完成后不再对未知名字做 stat 兜底', () {
      final cache = ThumbCache.instance;
      final source = File(p.join(imagesDir, 'image_730.jpg'))
        ..writeAsBytesSync(_makeImage(1200, 900));
      final name = cache.fileNameFor(source.path)!;
      File(p.join(thumbsDir, name)).writeAsBytesSync(_makeImage(480, 360));
      // 索引标记为已完成但没有收录这个名字：以索引为准，退回原图
      cache.debugSeed(dirPath: thumbsDir, imagesDirPath: imagesDir);

      final missesBefore = cache.lookupMisses;
      expect(cache.lookup(source.path), isNull);
      expect(cache.lookupMisses, missesBefore + 1);
    });

    test('TC-26 prepare 后立刻补齐，不重复编码已有缩略图', () async {
      final cache = ThumbCache.instance;
      var encodes = 0;
      cache.debugSetEncoder((bytes, width, lossless) async {
        encodes++;
        return ThumbCache.debugEncode(bytes, width, lossless: lossless);
      });
      final cached = File(p.join(imagesDir, 'image_740.jpg'))
        ..writeAsBytesSync(_makeImage(1200, 900));
      final name = cache.fileNameFor(cached.path)!;
      File(p.join(thumbsDir, name)).writeAsBytesSync(_makeImage(480, 360));
      File(p.join(imagesDir, 'image_741.jpg'))
          .writeAsBytesSync(_makeImage(1200, 900));
      cache.debugSeed(
        dirPath: thumbsDir,
        imagesDirPath: imagesDir,
        indexScanned: false,
      );

      await cache.prepare(overrideDir: thumbsDir, overrideImagesDir: imagesDir);
      await cache.startBackfill();

      expect(encodes, 1, reason: '补齐只该生成缺的那张');
      final files = Directory(thumbsDir).listSync().whereType<File>();
      expect(files, hasLength(2));
    });

    test('TC-27 扫描半途失败：流程收尾但索引不完整，盘上缩略图照样命中', () async {
      final cache = ThumbCache.instance;
      final reached = File(p.join(imagesDir, 'image_750.jpg'))
        ..writeAsBytesSync(_makeImage(1200, 900));
      final missed = File(p.join(imagesDir, 'image_751.jpg'))
        ..writeAsBytesSync(_makeImage(1200, 900));
      final reachedName = cache.fileNameFor(reached.path)!;
      final missedName = cache.fileNameFor(missed.path)!;
      final reachedThumb = File(p.join(thumbsDir, reachedName))
        ..writeAsBytesSync(_makeImage(480, 360));
      final missedThumb = File(p.join(thumbsDir, missedName))
        ..writeAsBytesSync(_makeImage(480, 360));

      cache.debugSeed(
        dirPath: thumbsDir,
        imagesDirPath: imagesDir,
        indexScanned: false,
      );
      // 真实文件系统造不出「扫到一半 IO 失败」：交出一条就抛。
      cache.debugSetDiskLister((dirPath, onName) async {
        onName(reachedName);
        throw const FileSystemException('模拟目录扫描中断', 'thumbs');
      });

      await cache.prepare(overrideDir: thumbsDir, overrideImagesDir: imagesDir);
      expect(cache.debugIndexStarted, isTrue, reason: '扫描由 prepare 发起');
      expect(
        cache.debugIndexComplete,
        isFalse,
        reason: 'prepare 不等扫描，回来时扫描还没收尾',
      );
      await cache.indexReady;

      expect(cache.debugIndexSettled, isTrue, reason: '失败也要收尾，否则补齐永远在等');
      expect(
        cache.debugIndexComplete,
        isFalse,
        reason: '没扫到的部分是「不知道」而不是「不存在」，不能当完整索引',
      );
      expect(cache.knownCount, 1, reason: '已经扫到的条目仍然有效');

      // 关键：没扫到的那张不能判未命中退回原图 —— 一次 stat 兜底就能命中。
      expect(cache.lookup(missed.path)?.path, missedThumb.path);
      expect(cache.knownCount, 2, reason: '兜底命中要补进索引');
      expect(cache.lookup(reached.path)?.path, reachedThumb.path);
    });

    test('TC-28 扫描失败后不把已有缩略图排进补齐队列', () async {
      final cache = ThumbCache.instance;
      var encodes = 0;
      cache.debugSetEncoder((bytes, width, lossless) async {
        encodes++;
        return ThumbCache.debugEncode(bytes, width, lossless: lossless);
      });
      final existing = File(p.join(imagesDir, 'image_760.jpg'))
        ..writeAsBytesSync(_makeImage(1200, 900));
      final pending = File(p.join(imagesDir, 'image_761.jpg'))
        ..writeAsBytesSync(_makeImage(1200, 900));
      final existingName = cache.fileNameFor(existing.path)!;
      File(p.join(thumbsDir, existingName))
          .writeAsBytesSync(_makeImage(480, 360));

      cache.debugSeed(
        dirPath: thumbsDir,
        imagesDirPath: imagesDir,
        indexScanned: false,
      );
      cache.debugSetDiskLister((dirPath, onName) async {
        // 扫到一张就断：`_known` 非空但不可信，正是要区分的那种状态。
        onName(existingName);
        throw const FileSystemException('模拟目录扫描中断', 'thumbs');
      });

      await cache.prepare(overrideDir: thumbsDir, overrideImagesDir: imagesDir);
      await cache.indexReady;
      await cache.startBackfill();

      expect(
        encodes,
        0,
        reason: '索引只是部分已知时没有算缺什么的依据，这一轮补齐该直接跳过',
      );
      expect(cache.knownCount, 1, reason: '`_known` 里已扫到的条目不被补齐清掉');
      // 兜底仍然成立：盘上已有的那份命中，缺的那张按需生成
      expect(
        cache.lookup(existing.path),
        isNotNull,
        reason: '索引不完整时 lookup 的 stat 兜底要命中已缓存的缩略图',
      );
      expect(await cache.ensure(pending.path), isNotNull);
      expect(encodes, 1, reason: '缺的那张照常按需编码，只是不由补齐批量排');
    });

    test('TC-29 clear 之后索引回到可信完整', () async {
      final cache = ThumbCache.instance;
      final source = File(p.join(imagesDir, 'image_770.jpg'))
        ..writeAsBytesSync(_makeImage(1200, 900));
      final name = cache.fileNameFor(source.path)!;
      File(p.join(thumbsDir, name)).writeAsBytesSync(_makeImage(480, 360));

      cache.debugSeed(
        dirPath: thumbsDir,
        imagesDirPath: imagesDir,
        indexScanned: false,
      );
      cache.debugSetDiskLister((dirPath, onName) async {
        throw const FileSystemException('模拟目录扫描中断', 'thumbs');
      });

      await cache.prepare(overrideDir: thumbsDir, overrideImagesDir: imagesDir);
      await cache.indexReady;
      expect(cache.debugIndexComplete, isFalse);

      await cache.clear();
      expect(cache.debugIndexSettled, isTrue);
      expect(
        cache.debugIndexComplete,
        isTrue,
        reason: '目录已清空重建，空索引就是完整索引，不该继续每张 stat',
      );
      expect(cache.lookup(source.path), isNull);
    });
  });
}
