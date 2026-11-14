import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:inkpaper/utils/image_decode_width.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 本地图片的缩略图持久化缓存。
///
/// 笔记图片是原字节落盘的（`documents/images`，一张手机照片 3~5MB、
/// 4000×3000），而网格与编辑器只要 [kGridTileDecodeWidth] 那么宽。每渲染一次
/// 都要把整张 12MP 图解码出来再缩小，实测单张 150~250ms；`ImageCache` 只在
/// 进程内有效，App 一被杀就全没了，冷启动、首次进详情都要重付这笔钱。
///
/// 这里把「解码 + 缩放」的结果存成小文件（480 宽 JPEG 约 30~50KB），渲染时
/// 同步查表直接读，跨进程依然命中。相比原图是 1/100 的体积、1/20 的解码量。
///
/// 放在 `cacheDir` 而不是 `documents/images` 的理由：
/// 1. `backup_archive_service` 会把整个 `images/` 打进备份 ZIP，缩略图混进去
///    等于给备份包凭空加几百 MB；
/// 2. 缩略图是派生数据、原图在就能重建，系统低存储时清掉也无所谓。
class ThumbCache {
  ThumbCache._();

  static final ThumbCache instance = ThumbCache._();

  /// 与列表卡片、详情九宫格、编辑器共用同一档位，命中同一份文件。
  static const int defaultWidth = kGridTileDecodeWidth;

  /// 单图满宽卡片与查看器预览用的档位。
  ///
  /// 只留两档是有意的：档位越多，同一张图在磁盘上存的份数越多，而不同布局
  /// 之间的差别肉眼分不出来。网格用 [defaultWidth]，其余都走 [largeWidth]。
  static const int largeWidth = 1080;

  /// 把任意期望宽度收敛到两档之一。
  static int bucketWidth(int width) =>
      width <= defaultWidth ? defaultWidth : largeWidth;

  static const String _dirName = 'thumbs';

  /// 82 是肉眼几乎无损的档位，再高只是让文件变大。
  static const int _jpegQuality = 82;

  /// 动图缩略图会变成静图、HEIC 解码器不支持，这些直接回退原图。
  static const Set<String> _skipExtensions = <String>{
    '.gif',
    '.heic',
    '.heif',
    '.mp4',
    '.mov',
    '.m4v',
  };

  /// 已生成的缩略图文件名。渲染发生在 build 里，不能做异步 IO，
  /// 所以启动时扫一遍目录把名字读进内存，`lookup` 只查这个 Set。
  final Set<String> _known = <String>{};

  /// 正在生成的，避免同一张图被列表里多个格子同时触发编码。
  final Set<String> _inflight = <String>{};

  /// 已经尝试生成失败的（HEIC 之类）。留着它，免得列表每次 build 都为一个
  /// 永远生成不出来的图重新起一次异步任务。
  final Set<String> _giveUp = <String>{};

  /// 未命中时是否顺手触发后台生成。
  ///
  /// 生产环境开着：用户这次看到的是原图，下次进来就是缩略图。单测里关掉，
  /// 否则 fire-and-forget 的写入会和断言、tearDown 抢时序。
  bool _autoGenerateOnMiss = true;

  /// 编码器。生产环境走 `compute` 丢到后台 isolate；单测里换成同步实现，
  /// 否则 flutter_test 的 fake async 会把 isolate 的 Future 晾在半空。
  ThumbEncoder _encoder = _computeEncode;

  String? _dirPath;
  String? _imagesDirPath;
  Future<void>? _prepareFuture;

  bool get isReady => _dirPath != null;

  /// 缩略图目录路径，`main()` 里预热后才有值。
  String? get directoryPath => _dirPath;

  /// 扫目录建索引。`main()` 里 `await` 一次，之后所有查询都是同步的。
  Future<void> prepare({String? overrideDir, String? overrideImagesDir}) async {
    if (_dirPath != null && overrideDir == null) {
      return;
    }
    final pending = _prepareFuture;
    if (pending != null) {
      return pending;
    }
    final future = _prepare(
      overrideDir: overrideDir,
      overrideImagesDir: overrideImagesDir,
    );
    _prepareFuture = future;
    try {
      await future;
    } finally {
      _prepareFuture = null;
    }
  }

  Future<void> _prepare({
    String? overrideDir,
    String? overrideImagesDir,
  }) async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      _imagesDirPath = overrideImagesDir ?? '${docs.path}/images';
      final dirPath =
          overrideDir ?? '${(await getTemporaryDirectory()).path}/$_dirName';
      final dir = Directory(dirPath);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      _dirPath = dirPath;
      _known.clear();
      _giveUp.clear();
      await for (final entity in dir.list()) {
        if (entity is File) {
          _known.add(p.basename(entity.path));
        }
      }
    } on Object catch (e) {
      // 建不了缓存目录就退化成「永远不命中」，渲染会走原图，不该影响启动。
      debugPrint('ThumbCache 初始化失败: $e');
      _dirPath = null;
    }
  }

  /// 同步查缩略图。命中返回文件，否则返回 null（调用方回退原图）。
  ///
  /// 未命中时顺手触发一次后台生成：用户这次看的是原图，下次进来就是缩略图。
  File? lookup(String sourcePath, {int width = defaultWidth}) {
    final dirPath = _dirPath;
    if (dirPath == null) {
      return null;
    }
    final abs = _resolve(sourcePath);
    if (abs == null) {
      return null;
    }
    final name = fileNameFor(abs, width: width);
    if (name == null) {
      return null;
    }
    if (_known.contains(name)) {
      final file = File(p.join(dirPath, name));
      // 系统低存储、用户点「清理缓存」都会把 cacheDir 清空，而索引还在内存里。
      // 这里一次 stat 就能发现，顺手把条目踢掉、退回原图并触发重建；
      // stat 在页缓存里是微秒级，比让 Image.file 渲染成破图划算得多。
      if (file.existsSync()) {
        return file;
      }
      _known.remove(name);
    }
    if (_autoGenerateOnMiss &&
        !_inflight.contains(name) &&
        !_giveUp.contains(name)) {
      unawaited(ensure(sourcePath, width: width));
    }
    return null;
  }

  /// 生成缩略图（幂等）。已存在时直接返回，不重复编码。
  Future<File?> ensure(String sourcePath, {int width = defaultWidth}) async {
    if (_dirPath == null) {
      await prepare();
    }
    final dirPath = _dirPath;
    if (dirPath == null) {
      return null;
    }
    final abs = _resolve(sourcePath);
    if (abs == null) {
      return null;
    }
    final name = fileNameFor(abs, width: width);
    if (name == null) {
      return null;
    }
    final target = File(p.join(dirPath, name));
    if (_known.contains(name)) {
      return target;
    }
    final source = File(abs);
    if (!await source.exists()) {
      return null;
    }
    if (_inflight.contains(name)) {
      return null;
    }
    final bucket = bucketWidth(width);
    _inflight.add(name);
    try {
      final bytes = await source.readAsBytes();
      final encoded = await _encoder(bytes, bucket, _wantsLossless(abs));
      if (encoded == null || encoded.isEmpty) {
        _giveUp.add(name);
        return null;
      }
      await target.writeAsBytes(encoded, flush: true);
      _known.add(name);
      _giveUp.remove(name);
      return target;
    } on Object catch (e) {
      debugPrint('ThumbCache 生成失败 $abs: $e');
      _giveUp.add(name);
      return null;
    } finally {
      _inflight.remove(name);
    }
  }

  /// 后台补齐存量图。
  ///
  /// 图片进入系统的入口不止编辑器插入（还有 Flomo 导入、Memos 附件同步、
  /// WebDAV 同步），挨个挂钩子必然漏，所以以「扫目录补齐」兜底。
  ///
  /// [budget] 是时间上限：只跑这么久就停，剩下的下次启动接着补，不能为了
  /// 预热拖慢前台的滑动。
  Future<int> backfill({
    Duration budget = const Duration(seconds: 8),
    int width = defaultWidth,
  }) async {
    if (_dirPath == null) {
      await prepare();
    }
    final imagesDirPath = _imagesDirPath;
    if (_dirPath == null || imagesDirPath == null) {
      return 0;
    }
    final imagesDir = Directory(imagesDirPath);
    if (!await imagesDir.exists()) {
      return 0;
    }
    final candidates = <File>[];
    await for (final entity in imagesDir.list()) {
      if (entity is! File) {
        continue;
      }
      final name = fileNameFor(entity.path, width: width);
      if (name == null || _known.contains(name)) {
        continue;
      }
      candidates.add(entity);
    }
    if (candidates.isEmpty) {
      return 0;
    }
    // 最近改过的笔记更容易被打开，优先处理它们。
    candidates.sort((a, b) {
      final aTime = a.statSync().modified;
      final bTime = b.statSync().modified;
      return bTime.compareTo(aTime);
    });

    var done = 0;
    final startedAt = DateTime.now();
    for (final file in candidates) {
      if (DateTime.now().difference(startedAt) > budget) {
        break;
      }
      final result = await ensure(file.path, width: width);
      if (result != null) {
        done++;
      }
      // 编码在 compute 里跑，但读文件与写文件仍在主 isolate 的事件循环上，
      // 让出一帧给 UI，避免启动后第一屏滑动发涩。
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    if (done > 0) {
      debugPrint('ThumbCache: 补齐 $done 张缩略图');
    }
    return done;
  }

  /// 清空全部缩略图（设置里「清理缓存」用，删完会按需重建）。
  Future<void> clear() async {
    final dirPath = _dirPath;
    if (dirPath == null) {
      return;
    }
    try {
      final dir = Directory(dirPath);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
      await dir.create(recursive: true);
    } on Object catch (e) {
      debugPrint('ThumbCache 清空失败: $e');
    } finally {
      _known.clear();
      _giveUp.clear();
    }
  }

  /// 缩略图文件名。源文件名本身带毫秒时间戳（编辑器插入时生成），插入后
  /// 也不会被改写，所以不需要额外的失效校验；调用方只要保证传入的是同一个
  /// 源路径即可。
  ///
  /// 返回 null 表示这种格式不做缩略图。
  @visibleForTesting
  String? fileNameFor(String absolutePath, {int width = defaultWidth}) {
    final ext = p.extension(absolutePath).toLowerCase();
    if (_skipExtensions.contains(ext)) {
      return null;
    }
    final stem = p.basenameWithoutExtension(absolutePath);
    if (stem.isEmpty) {
      return null;
    }
    // JPEG 丢透明通道，带 alpha 的图（截图、贴纸）压成 JPEG 会变黑底，
    // 这类输出 PNG，代价是文件大一些但颜色正确。
    final outExt = _wantsLossless(absolutePath) ? 'png' : 'jpg';
    return '${stem}_${bucketWidth(width)}.$outExt';
  }

  bool _wantsLossless(String absolutePath) {
    final ext = p.extension(absolutePath).toLowerCase();
    return ext == '.png' || ext == '.webp';
  }

  /// 把 `file://` 与正文里的相对路径（`images/xxx.jpg`）都归一成绝对路径。
  String? _resolve(String sourcePath) {
    var path = sourcePath.trim();
    if (path.isEmpty) {
      return null;
    }
    if (path.startsWith('file://')) {
      path = path.substring('file://'.length);
    }
    if (path.startsWith('http://') || path.startsWith('https://')) {
      return null;
    }
    if (p.isAbsolute(path)) {
      return p.normalize(path);
    }
    final imagesDirPath = _imagesDirPath;
    if (imagesDirPath == null || !path.startsWith('images/')) {
      return null;
    }
    // 正文里写的是 `images/xxx.jpg`，相对的是 documents 目录。
    return p.normalize(p.join(p.dirname(imagesDirPath), path));
  }

  /// 仅测试用：直接注入索引与目录，跳过 path_provider。
  @visibleForTesting
  void debugSeed({
    required String dirPath,
    String? imagesDirPath,
    Iterable<String> known = const <String>[],
  }) {
    _dirPath = dirPath;
    _imagesDirPath = imagesDirPath;
    _known
      ..clear()
      ..addAll(known);
    _giveUp.clear();
    _prepareFuture = null;
  }

  /// 仅测试用：换成同步编码器，避开 isolate。
  @visibleForTesting
  void debugSetEncoder(ThumbEncoder encoder) {
    _encoder = encoder;
  }

  /// 仅测试用：关掉 lookup 未命中时的后台生成。
  @visibleForTesting
  void debugSetAutoGenerateOnMiss(bool enabled) {
    _autoGenerateOnMiss = enabled;
  }

  /// 仅测试用：直接跑一遍编码，用于断言输出尺寸。
  @visibleForTesting
  static Uint8List? debugEncode(
    Uint8List bytes,
    int width, {
    bool lossless = false,
  }) {
    return _encodeThumbTask(
      _ThumbTask(bytes: bytes, width: width, lossless: lossless),
    );
  }
}

/// 把原图字节压成缩略图字节。返回 null 表示这个格式解不了（比如 HEIC）。
typedef ThumbEncoder = Future<Uint8List?> Function(
  Uint8List bytes,
  int width,
  bool lossless,
);

Future<Uint8List?> _computeEncode(
  Uint8List bytes,
  int width,
  bool lossless,
) {
  return compute(
    _encodeThumbTask,
    _ThumbTask(bytes: bytes, width: width, lossless: lossless),
  );
}

@immutable
class _ThumbTask {
  const _ThumbTask({
    required this.bytes,
    required this.width,
    required this.lossless,
  });

  final Uint8List bytes;
  final int width;
  final bool lossless;
}

/// 顶层函数：`compute` 只能调顶层/静态方法，且参数要能跨 isolate 传递。
Uint8List? _encodeThumbTask(_ThumbTask task) {
  final decoded = img.decodeImage(task.bytes);
  if (decoded == null) {
    // HEIC 之类解不了的格式，交给原图路径处理。
    return null;
  }
  // 已经比目标窄的图不用放大，放大只会变糊且更占空间。
  final resized = decoded.width <= task.width
      ? decoded
      : img.copyResize(
          decoded,
          width: task.width,
          interpolation: img.Interpolation.average,
        );
  if (task.lossless) {
    return Uint8List.fromList(img.encodePng(resized));
  }
  return Uint8List.fromList(
    img.encodeJpg(resized, quality: ThumbCache._jpegQuality),
  );
}
