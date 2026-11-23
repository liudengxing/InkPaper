import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:inkpaper/utils/image_decode_width.dart';
import 'package:inkpaper/utils/native_thumb_decoder.dart';
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
  static const int _defaultDiskLimit = 128 << 20;
  int _diskLimit = _defaultDiskLimit;
  int _diskBytes = 0;
  final _diskEntries = <String, _DiskThumbnail>{};
  bool _diskIndexed = false;
  Future<void>? _maintenance;
  Future<void>? _clearing;

  /// 82 是肉眼几乎无损的档位，再高只是让文件变大。
  static const int _jpegQuality = 82;

  /// 视频首帧也做缩略图（[nativeVideoExtensions]），和 HEIC 一样交给原生。
  ///
  /// 这张表曾经装过 GIF / HEIC / 视频：151 张图只有 108 个缩略图，剩下 43 张
  /// 每次渲染都要现解原图 —— 滑到多图笔记就白一片。三者现在都能生成缩略图，
  /// 表清空后 `fileNameFor` 不再对任何格式返回 null。
  static const Set<String> _skipExtensions = <String>{};

  /// 动图只取第一帧，缩略图是静图。列表里不再动，点开大图读的仍是原图。
  static const Set<String> animatedExtensions = <String>{'.gif'};

  /// Dart 侧没有 HEVC 解码器（`package:image` 只认 jpeg/png/gif/webp/tiff/
  /// psd/exr/tga/bmp），这两种必须走 Android 原生 `ImageDecoder`。
  static const Set<String> nativeDecodeExtensions = <String>{'.heic', '.heif'};

  /// 视频：Dart 侧没有任何解码能力，首帧由原生 `MediaMetadataRetriever` 取。
  /// 与 `MediaPaths.videoExtensions` 保持一致。
  static const Set<String> nativeVideoExtensions = <String>{
    '.mp4',
    '.mov',
    '.m4v',
    '.avi',
    '.mkv',
    '.webm',
    '.flv',
    '.3gp',
  };

  /// 不做缩略图的扩展名。数据清理页用它区分「没补上」和「本来就不做」。
  static Set<String> get skippedExtensions => _skipExtensions;

  /// 已生成的缩略图文件名。渲染发生在 build 里，不能做异步 IO，
  /// 所以扫一遍目录把名字读进内存，`lookup` 只查这个 Set。
  ///
  /// 扫描不挡首帧（见 [prepare]），在它结束之前这个 Set 只含本进程新生成的
  /// 条目，`lookup` 会用一次 stat 兜底，见 [_indexComplete]。
  final Set<String> _known = <String>{};

  /// 正在生成的，避免同一张图被列表里多个格子同时触发编码。
  final _inflight = <String, Future<File?>>{};

  /// 已经尝试生成失败的（HEIC 之类）。留着它，免得列表每次 build 都为一个
  /// 永远生成不出来的图重新起一次异步任务。
  final Set<String> _giveUp = <String>{};

  /// 同时进行的编码任务上限。
  ///
  /// 一张 12MP 照片解码后约 48MB 位图，9 图笔记若同时编码，内存峰值接近
  /// 400MB —— GC 抖动会把滚动直接拖卡，`compute` 虽在别的 isolate 跑，
  /// 但内存和 CPU 是共用的。两路并行足够吃满编码吞吐，又压得住峰值。
  static const int _maxConcurrentEncodes = 2;

  int _activeEncodes = 0;
  final List<_EncodeSlot> _encodeQueue = <_EncodeSlot>[];

  /// 取一个编码名额。
  ///
  /// [lowPriority] 是后台补齐（[startBackfill]）专用的：它只会排在队尾，
  /// 已有的低优先级任务之后；前台渲染触发的 [ensure] 直接插到所有低优先级
  /// 前面。这样「用户正在看的那张图」永远不会被存量补齐挡在后面。
  Future<void> _acquireEncodeSlot({bool lowPriority = false}) async {
    // 低优先级任务不抢占空闲名额：只要队列里还有人在等，它就继续排着，
    // 否则它会在前台任务的间隙里插队占满两个名额。
    if (_activeEncodes < _maxConcurrentEncodes &&
        (!lowPriority || _encodeQueue.isEmpty)) {
      _activeEncodes++;
      return;
    }
    final waiter = _EncodeSlot(lowPriority: lowPriority);
    if (lowPriority) {
      _encodeQueue.add(waiter);
    } else {
      // 插到第一个低优先级任务之前，保证前台任务排在存量补齐前面
      final index = _encodeQueue.indexWhere((slot) => slot.lowPriority);
      if (index < 0) {
        _encodeQueue.add(waiter);
      } else {
        _encodeQueue.insert(index, waiter);
      }
    }
    await waiter.completer.future;
  }

  void _releaseEncodeSlot() {
    if (_encodeQueue.isNotEmpty) {
      // 把名额直接交给排队的下一个，_activeEncodes 保持不变
      _encodeQueue.removeAt(0).completer.complete();
      return;
    }
    if (_activeEncodes > 0) {
      _activeEncodes--;
    }
  }

  /// 存量补齐的让路节奏：每张之间歇一下，每批之间再歇长一点。
  ///
  /// 编码本身在 `compute` 的 isolate 里，但读原图、写缩略图、GC 都在主
  /// isolate。不留间隙的话补齐期间 CPU 会一直贴着 100%，前台的滚动与转场
  /// 会明显掉帧。60ms 的间隙把占用压在六七成，几百张图的补齐也就是多花
  /// 几十秒。
  static const Duration _itemGap = Duration(milliseconds: 60);
  static const Duration _batchGap = Duration(milliseconds: 240);
  static const int _batchSize = 4;

  Future<void>? _backfillFuture;
  bool _backfillPaused = false;
  bool _backfillStopped = false;
  Completer<void>? _backfillResume;
  int _backfilledCount = 0;

  /// 未命中时是否顺手触发后台生成。
  ///
  /// 生产环境开着：用户这次看到的是原图，下次进来就是缩略图。单测里关掉，
  /// 否则 fire-and-forget 的写入会和断言、tearDown 抢时序。
  bool _autoGenerateOnMiss = true;

  /// 编码器。生产环境走 `compute` 丢到后台 isolate；单测里换成同步实现，
  /// 否则 flutter_test 的 fake async 会把 isolate 的 Future 晾在半空。
  ThumbEncoder _encoder = _computeEncode;

  /// HEIC/HEIF 走这条（Dart 侧解不出来）。单测里换成假实现，避开平台通道。
  NativeThumbDecoder _nativeDecoder = decodeNativeThumbnail;

  String? _dirPath;
  String? _imagesDirPath;
  Future<void>? _prepareFuture;

  /// 目录扫描是否已经出结果。
  ///
  /// 扫描已从首帧前挪到首帧后（[prepare] 只等到目录建好就返回），在这个标志
  /// 变 true 之前 [_known] 是不完整的：`lookup` 必须对未收录的名字补一次
  /// stat，否则首屏会以为「一张缩略图都没有」而集体退回原图。
  bool _indexComplete = false;

  /// 目录扫描的 Future，给需要完整清单的后台任务（补齐、磁盘整理）等待用。
  Future<void>? _indexFuture;

  bool get isReady => _dirPath != null;

  /// 缩略图目录路径，`main()` 里预热后才有值。
  String? get directoryPath => _dirPath;

  /// 索引扫描完成（或扫描失败也照样完成）的 Future。
  ///
  /// 没有任何一次 [prepare] 时立即完成。`lookup` 不依赖它，只有「必须看到
  /// 完整清单」的后台任务才等。
  Future<void> get indexReady => _indexFuture ?? Future<void>.value();

  /// 准备目录并开始扫索引。
  ///
  /// `main()` 里 `await` 这一次，但**只等到目录可用**：`getTemporaryDirectory`
  /// 与 `create` 是毫秒级，真正慢的是把目录里几千个缩略图名字读进内存
  /// （冷缓存下更慢），那一步放到 [indexReady] 后面跑，不再挡首帧。
  ///
  /// 扫描完成前 `lookup` 用一次同步 stat 兜底，命中就顺手补进索引，所以
  /// 「首帧卡片退化成原图」这件事不会发生；代价只是这段时间里每张卡片多
  /// 一次 stat（页缓存内微秒级）。
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
      // 只在没有注入时才问平台要 documents 目录：测试注入图片目录时可以完全
      // 不碰 path_provider。
      var imagesDirPath = overrideImagesDir;
      if (imagesDirPath == null) {
        final docs = await getApplicationDocumentsDirectory();
        imagesDirPath = '${docs.path}/images';
      }
      _imagesDirPath = imagesDirPath;
      final dirPath =
          overrideDir ?? '${(await getTemporaryDirectory()).path}/$_dirName';
      final dir = Directory(dirPath);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      _dirPath = dirPath;
      _known.clear();
      _giveUp.clear();
      _startDiskIndex(dirPath);
    } on Object catch (e) {
      // 建不了缓存目录就退化成「永远不命中」，渲染会走原图，不该影响启动。
      debugPrint('ThumbCache 初始化失败: $e');
      _dirPath = null;
    }
  }

  /// 发起目录扫描，不等待结果。
  void _startDiskIndex(String dirPath) {
    _indexComplete = false;
    _indexFuture = _scanDisk(dirPath);
  }

  Future<void> _scanDisk(String dirPath) async {
    try {
      await for (final entity in Directory(dirPath).list()) {
        if (entity is File && !entity.path.endsWith('.writing')) {
          _known.add(p.basename(entity.path));
        }
      }
    } on Object catch (e) {
      // 扫不动就当没有缩略图：`lookup` 的 stat 兜底仍然能找到已有的文件，
      // 只是每张卡片都要 stat 一次。
      debugPrint('ThumbCache 目录扫描失败: $e');
    } finally {
      _indexComplete = true;
    }
  }

  /// 本次进程内的命中/未命中统计。
  ///
  /// 没有这个数就只能靠肉眼猜「到底命中没有」：卡片命中缩略图出图是毫秒级，
  /// 落到原图要 150~250ms，观感差别很大但都无法从代码读出。数据清理页把它
  /// 显示出来，一眼就能判断缩略图有没有真正被用上。
  int _lookupHits = 0;
  int _lookupMisses = 0;

  int get lookupHits => _lookupHits;

  int get lookupMisses => _lookupMisses;

  /// 已索引的缩略图数量（约等于覆盖的图片数）。
  int get knownCount => _known.length;

  /// 同步查缩略图。命中返回文件，否则返回 null（调用方回退原图）。
  ///
  /// 未命中时顺手触发一次后台生成：用户这次看的是原图，下次进来就是缩略图。
  /// [generateOnMiss] 为 false 时只检查缓存，供延迟加载的调用方先判断命中。
  File? lookup(
    String sourcePath, {
    int width = defaultWidth,
    bool generateOnMiss = true,
  }) {
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
    final indexed = _known.contains(name);
    // 扫描还没跑完时索引不完整，未收录的名字再花一次 stat 确认：
    // 命中就补进索引，之后走快速路径；真没有才按未命中处理。
    final file = File(p.join(dirPath, name));
    if (indexed || !_indexComplete) {
      // 系统低存储、用户点「清理缓存」都会把 cacheDir 清空，而索引还在内存里。
      // 这里一次 stat 就能发现，顺手把条目踢掉、退回原图并触发重建；
      // stat 在页缓存里是微秒级，比让 Image.file 渲染成破图划算得多。
      if (file.existsSync()) {
        if (!indexed) {
          _known.add(name);
        }
        _lookupHits++;
        _diskEntries[name]?.usedAt = DateTime.now();
        return file;
      }
      if (indexed) {
        _forget(name);
      }
    }
    _lookupMisses++;
    if (generateOnMiss &&
        _autoGenerateOnMiss &&
        !_inflight.containsKey(name) &&
        !_giveUp.contains(name)) {
      unawaited(ensure(sourcePath, width: width));
    }
    return null;
  }

  /// 生成缩略图（幂等）。已存在时直接返回，不重复编码。
  ///
  /// [lowPriority] 只给后台补齐用，见 [_acquireEncodeSlot]。
  Future<File?> ensure(
    String sourcePath, {
    int width = defaultWidth,
    bool lowPriority = false,
  }) async {
    if (_dirPath == null) {
      await prepare();
    }
    final dirPath = _dirPath;
    if (dirPath == null || _clearing != null) {
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
    final ext = p.extension(abs).toLowerCase();
    final target = File(p.join(dirPath, name));
    if (_known.contains(name)) {
      if (await target.exists()) {
        return target;
      }
      _forget(name);
    } else if (!_indexComplete && await target.exists()) {
      // 目录扫描还没跑完：文件可能早就在盘上（上次启动生成的），补进索引
      // 直接复用，别把这张图重新解码一遍。
      _known.add(name);
      return target;
    }
    if (_clearing != null) {
      return null;
    }
    // 本进程内已经失败过的（HEIC 之类）不再重试：补齐循环会反复扫到同一批
    // 文件，没有这道闸门就会一直啃它们，永远追不平。
    if (_giveUp.contains(name)) {
      return null;
    }
    return _inflight.putIfAbsent(name, () async {
      try {
        return await _encode(abs, ext, target, name, width, lowPriority);
      } finally {
        final _ = _inflight.remove(name);
        if (!lowPriority && _diskBytes > _diskLimit) {
          unawaited(_maintainDisk());
        }
      }
    });
  }

  Future<File?> _encode(
    String abs,
    String ext,
    File target,
    String name,
    int width,
    bool lowPriority,
  ) async {
    final bucket = bucketWidth(width);
    final staging = File('${target.path}.writing');
    var slot = false;
    try {
      final source = File(abs);
      if (!await source.exists()) {
        return null;
      }
      await _acquireEncodeSlot(lowPriority: lowPriority);
      slot = true;
      // 排队期间别的调用方可能已经把它生成好了，省掉一次重复解码
      if (_known.contains(name)) {
        return target;
      }
      final Uint8List? encoded;
      if (nativeDecodeExtensions.contains(ext) ||
          nativeVideoExtensions.contains(ext)) {
        // HEIC 与视频都按路径交给原生：HEIC 采样解码连原图字节都不用读
        // （一张 3~5MB），视频更不可能整个读进来（动辄几十 MB）。
        encoded = await _nativeDecoder(abs, bucket);
      } else {
        final bytes = await source.readAsBytes();
        encoded = await _encoder(bytes, bucket, _wantsLossless(abs));
      }
      if (encoded == null || encoded.isEmpty) {
        _giveUp.add(name);
        return null;
      }
      if (_clearing != null || encoded.length > _diskLimit) {
        return null;
      }
      await staging.writeAsBytes(encoded, flush: true);
      await staging.rename(target.path);
      _known.add(name);
      _record(name, encoded.length, DateTime.now());
      _giveUp.remove(name);
      return target;
    } on Object catch (e) {
      debugPrint('ThumbCache 生成失败 $abs: $e');
      _giveUp.add(name);
      try {
        if (await staging.exists()) {
          await staging.delete();
        }
      } on FileSystemException {
        // 缓存也可能已被系统回收。
      }
      return null;
    } finally {
      if (slot) {
        _releaseEncodeSlot();
      }
    }
  }

  /// 供查看器等只想复用现有工作、无需为预览另启一次解码的入口调用。
  Future<File?>? pending(String sourcePath, {int width = defaultWidth}) {
    final abs = _resolve(sourcePath);
    return abs == null ? null : _inflight[fileNameFor(abs, width: width)];
  }

  /// 后台补齐存量图（一次性扫完）。
  ///
  /// 图片进入系统的入口不止编辑器插入（还有 Flomo 导入、Memos 附件同步、
  /// WebDAV 同步），挨个挂钩子必然漏，所以以「扫目录补齐」兜底。
  ///
  /// 生产环境走 [startBackfill]（一直补到追平）；这里是「扫一遍就返回」的
  /// 版本，给测试与需要一次性补齐的场合用。[budget] 传了就限时。
  Future<int> backfill({
    Duration? budget,
    int width = defaultWidth,
  }) async {
    if (_dirPath == null) {
      await prepare();
    }
    if (_dirPath == null || _imagesDirPath == null) {
      return 0;
    }
    final candidates = await _pendingSources(width: width);
    if (candidates.isEmpty) {
      return 0;
    }
    var done = 0;
    final startedAt = DateTime.now();
    for (final file in candidates) {
      if (budget != null && DateTime.now().difference(startedAt) > budget) {
        break;
      }
      final result = await ensure(file.path, width: width, lowPriority: true);
      if (result != null) {
        done++;
      }
      // 编码在 compute 里跑，但读文件与写文件仍在主 isolate 的事件循环上，
      // 让出一帧给 UI，避免启动后第一屏滑动发涩。
      await Future<void>.delayed(_itemGap);
    }
    if (done > 0) {
      debugPrint('ThumbCache: 补齐 $done 张缩略图');
    }
    return done;
  }

  /// 持续补齐存量图，直到追平为止（幂等，重复调用返回同一个 Future）。
  ///
  /// 旧实现是「启动后跑 8 秒就停」，几百张老图要熬过很多次启动才轮得到；
  /// LANCZOS 那套体验等于「第一次滑动一直卡」。现在改成一直补，靠三件事
  /// 保证不打扰前台：
  ///
  /// 1. **低优先级编码槽**：前台渲染触发的 [ensure] 会插到补齐任务前面，
  ///    正在看的那张图不用排队等存量。
  /// 2. **张间让路**：每张之间歇 [_itemGap]、每 [_batchSize] 张歇
  ///    [_batchGap]，CPU 占用压在六七成，滚动不受影响。
  /// 3. **退到后台就停**：[pauseBackfill] / [resumeBackfill] 由生命周期钩子
  ///    驱动，避免锁屏后继续烘图白耗电。
  Future<void> startBackfill({int width = defaultWidth}) {
    final existing = _backfillFuture;
    if (existing != null) {
      return existing;
    }
    _backfillStopped = false;
    final future = _runBackfillLoop(width: width);
    _backfillFuture = future;
    unawaited(
      future.whenComplete(() {
        if (identical(_backfillFuture, future)) {
          _backfillFuture = null;
        }
      }),
    );
    return future;
  }

  /// 暂停补齐（App 退到后台时调用），[resumeBackfill] 之后接着补。
  void pauseBackfill() {
    _backfillPaused = true;
  }

  /// 恢复补齐。
  void resumeBackfill() {
    if (!_backfillPaused) {
      return;
    }
    _backfillPaused = false;
    _backfillResume?.complete();
    _backfillResume = null;
  }

  /// 停止本轮补齐（清理缓存时调用，避免刚删完又被补回来）。
  void stopBackfill() {
    _backfillStopped = true;
    resumeBackfill();
  }

  /// 累计补齐了多少张，调试与数据清理页展示用。
  int get backfilledCount => _backfilledCount;

  /// 本轮补齐是否还在跑。
  bool get isBackfilling => _backfillFuture != null;

  Future<void> _runBackfillLoop({required int width}) async {
    if (_dirPath == null) {
      await prepare();
    }
    if (_dirPath == null || _imagesDirPath == null) {
      return;
    }
    await _maintainDisk(removeOrphans: true);
    var total = 0;
    // 给前台请求预留空间，避免每次开屏补齐又淘汰同一批老图。
    final backfillLimit = _diskLimit * 9 ~/ 10;
    while (!_backfillStopped && _diskBytes < backfillLimit) {
      await _waitWhilePaused();
      if (_backfillStopped) {
        break;
      }
      final pending = await _pendingSources(width: width);
      if (pending.isEmpty) {
        break;
      }
      var progressed = 0;
      for (var i = 0; i < pending.length; i++) {
        if (_backfillStopped ||
            _backfillPaused ||
            _diskBytes >= backfillLimit) {
          break;
        }
        final result = await ensure(
          pending[i].path,
          width: width,
          lowPriority: true,
        );
        if (result != null) {
          progressed++;
          total++;
        }
        final endOfBatch = (i + 1) % _batchSize == 0;
        await Future<void>.delayed(endOfBatch ? _batchGap : _itemGap);
      }
      _backfilledCount += progressed;
      if (progressed > 0) {
        debugPrint('ThumbCache: 本轮补齐 $progressed 张，累计 $total 张');
      }
      if (_backfillStopped) {
        break;
      }
      if (_backfillPaused) {
        // 这一轮是被暂停打断的（一张没干），不能当成「剩下的都补不动」，
        // 否则 App 一退到后台补齐就永久停了，回来也不再继续。
        continue;
      }
      if (progressed == 0) {
        // 剩下的要么解不了、要么读失败，反正这一轮一张都没成功。
        // 继续扫下去只会原地打转（补齐期间新插入的图会走渲染触发路径）。
        break;
      }
    }
    if (total > 0) {
      debugPrint('ThumbCache: 补齐 $total 张缩略图（已追平）');
    }
    if (!_backfillStopped && _diskBytes > _diskLimit) {
      await _maintainDisk();
    }
  }

  Future<void> _waitWhilePaused() async {
    while (_backfillPaused) {
      final signal = _backfillResume ??= Completer<void>();
      await signal.future;
      _backfillResume = null;
    }
  }

  /// 扫出还没缩略图的源文件，最近改过的排在前面（更可能被打开）。
  Future<List<File>> _pendingSources({required int width}) async {
    final imagesDirPath = _imagesDirPath;
    if (imagesDirPath == null) {
      return const <File>[];
    }
    // 索引不完整时 `_known` 里没有存量缩略图，会把已经生成过的图全排进队列
    // （`ensure` 会靠 stat 兜住、不会真重编码，但白扫一遍目录）。补齐本来就是
    // 后台任务，等索引扫完再开始。
    await indexReady;
    final imagesDir = Directory(imagesDirPath);
    if (!await imagesDir.exists()) {
      return const <File>[];
    }
    final candidates = <({File file, DateTime modified})>[];
    await for (final entity in imagesDir.list()) {
      if (entity is! File) {
        continue;
      }
      final name = fileNameFor(entity.path, width: width);
      // 不支持的格式（fileNameFor 返回 null）与已知失败的不进队列，
      // 否则补齐会在同一批永远补不动的文件上空转。
      if (name == null || _known.contains(name) || _giveUp.contains(name)) {
        continue;
      }
      final stat = await entity.stat();
      if (stat.type == FileSystemEntityType.file) {
        candidates.add((file: entity, modified: stat.modified));
      }
    }
    candidates.sort((a, b) => b.modified.compareTo(a.modified));
    return candidates.map((entry) => entry.file).toList(growable: false);
  }

  void _record(String name, int bytes, DateTime usedAt) {
    _diskBytes += bytes - (_diskEntries[name]?.bytes ?? 0);
    _diskEntries[name] = _DiskThumbnail(bytes, usedAt);
  }

  void _forget(String name) {
    _known.remove(name);
    _diskBytes -= _diskEntries.remove(name)?.bytes ?? 0;
  }

  Future<void> _maintainDisk({bool removeOrphans = false}) =>
      _maintenance ??= _runDiskMaintenance(removeOrphans).whenComplete(() {
        _maintenance = null;
      });

  Future<void> _runDiskMaintenance(bool removeOrphans) async {
    final directory = _dirPath;
    if (directory == null || _clearing != null) {
      return;
    }
    try {
      // 磁盘记账（`_diskBytes`）按 `_known` 逐条 stat，索引没扫完就记不全，
      // 淘汰会算错。整理是后台任务，等扫描收尾即可。
      await indexReady;
      if (!_diskIndexed) {
        for (final name in _known.toList()) {
          if (_diskEntries.containsKey(name)) {
            continue;
          }
          final stat = await File(p.join(directory, name)).stat();
          if (_known.contains(name) && !_diskEntries.containsKey(name)) {
            if (stat.type == FileSystemEntityType.file) {
              _record(name, stat.size, stat.modified);
            } else {
              _forget(name);
            }
          }
        }
        _diskIndexed = true;
      }

      final imagesPath = _imagesDirPath;
      if (removeOrphans && imagesPath != null) {
        final images = Directory(imagesPath);
        if (await images.exists()) {
          final sourceNames = <String>{};
          await for (final entry in images.list()) {
            if (entry is File) {
              for (final width in [defaultWidth, largeWidth]) {
                final name = fileNameFor(entry.path, width: width);
                if (name != null) {
                  sourceNames.add(name);
                }
              }
            }
          }
          // 临时或外部路径的图也会生成小图，近期仍在使用的先保留。
          final cutoff = DateTime.now().subtract(const Duration(days: 7));
          for (final entry in _diskEntries.entries.toList()) {
            if (!sourceNames.contains(entry.key) &&
                entry.value.usedAt.isBefore(cutoff)) {
              await _evictDiskEntry(directory, entry.key);
            }
          }
        }
      }

      if (_diskBytes <= _diskLimit) {
        return;
      }
      final candidates = _diskEntries.entries.toList()
        ..sort((a, b) => a.value.usedAt.compareTo(b.value.usedAt));
      for (final candidate in candidates) {
        if (_diskBytes <= _diskLimit) {
          break;
        }
        await _evictDiskEntry(directory, candidate.key);
      }
    } on FileSystemException catch (error) {
      debugPrint('ThumbCache 整理失败: $error');
    }
  }

  Future<void> _evictDiskEntry(String directory, String name) async {
    if (_clearing != null ||
        _inflight.containsKey(name) ||
        !_known.contains(name)) {
      return;
    }
    final file = File(p.join(directory, name));
    try {
      await file.delete();
      _forget(name);
    } on FileSystemException {
      if (!await file.exists()) {
        _forget(name);
      }
    }
  }

  /// 附件清理已确认源文件删除后，顺手删掉两档缩略图。
  Future<void> removeForSource(String sourcePath) async {
    final abs = _resolve(sourcePath);
    final directory = _dirPath;
    if (abs == null || directory == null) {
      return;
    }
    for (final width in [defaultWidth, largeWidth]) {
      final name = fileNameFor(abs, width: width);
      if (name != null) {
        await _inflight[name];
        await _evictDiskEntry(directory, name);
      }
    }
  }

  /// 清空全部缩略图（设置里「清理缓存」用，删完会按需重建）。
  Future<void> clear() => _clearing ??= _clear().whenComplete(() {
        _clearing = null;
      });

  Future<void> _clear() async {
    // 正在补齐的话先停下来：否则删完立刻又被补回来，用户点了「清理缓存」
    // 却看不到空间释放。下次启动会重新开始补齐。
    stopBackfill();
    final dirPath = _dirPath;
    if (dirPath == null) {
      return;
    }
    await Future.wait(_inflight.values.toList());
    // 扫描可能还在读目录：先让它跑完，否则它会把刚删掉的名字又加回 `_known`。
    await indexReady;
    await _maintenance;
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
      _diskEntries.clear();
      _diskBytes = 0;
      _diskIndexed = false;
      // 目录已被清空重建，空索引就是完整索引。
      _indexComplete = true;
      _indexFuture = null;
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
    // GIF 同样走 PNG：表情包多是透明底，首帧还常只覆盖部分区域（GIF 的
    // 局部帧优化），压成 JPEG 会得到一块块黑底。
    return ext == '.png' || ext == '.webp' || ext == '.gif';
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
  ///
  /// [indexScanned] 传 false 模拟「目录扫描还没跑完」的首帧窗口。
  @visibleForTesting
  void debugSeed({
    required String dirPath,
    String? imagesDirPath,
    Iterable<String> known = const <String>[],
    int diskLimit = _defaultDiskLimit,
    bool indexScanned = true,
  }) {
    _dirPath = dirPath;
    _imagesDirPath = imagesDirPath;
    _known
      ..clear()
      ..addAll(known);
    _giveUp.clear();
    _diskLimit = diskLimit;
    _diskEntries.clear();
    _diskBytes = 0;
    _diskIndexed = false;
    _prepareFuture = null;
    _indexFuture = null;
    _indexComplete = indexScanned;
  }

  /// 仅测试用：目录扫描是否已经有结果。
  @visibleForTesting
  bool get debugIndexComplete => _indexComplete;

  /// 仅测试用：换成同步编码器，避开 isolate。
  @visibleForTesting
  void debugSetEncoder(ThumbEncoder encoder) {
    _encoder = encoder;
  }

  /// 仅测试用：换掉原生解码器。测试环境没有平台通道，默认实现会返回 null。
  @visibleForTesting
  void debugSetNativeDecoder(NativeThumbDecoder decoder) {
    _nativeDecoder = decoder;
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

/// 编码名额的排队凭证。
class _DiskThumbnail {
  _DiskThumbnail(this.bytes, this.usedAt);

  final int bytes;
  DateTime usedAt;
}

class _EncodeSlot {
  _EncodeSlot({required this.lowPriority});

  /// 后台补齐提交的任务只能排低优先级，前台渲染触发的任务会插到它前面。
  final bool lowPriority;
  final Completer<void> completer = Completer<void>();
}

/// 把原图字节压成缩略图字节。返回 null 表示这个格式解不了。
typedef ThumbEncoder = Future<Uint8List?> Function(
  Uint8List bytes,
  int width,
  bool lossless,
);

/// HEIC/HEIF 的原生解码器：给原图路径与目标宽度，返回 JPEG 字节。
///
/// 返回 null 表示这个平台解不了（桌面端、Android 8.1 及以下、文件损坏），
/// 调用方按「没有缩略图」处理并退回原图。
typedef NativeThumbDecoder = Future<Uint8List?> Function(
  String path,
  int width,
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
  // frame: 0 是必须的。GifDecoder / WebPDecoder 在 frame == null 时会把**所有
  // 帧**都解出来再合成（gif_decoder.dart:176、webp_decoder.dart:122），一个
  // 几十帧的动图等于白解几十次，比直接读原图还慢。传 0 只解首帧；JPEG/PNG
  // 的 decode 会忽略这个参数，不受影响。
  final decoded = img.decodeImage(task.bytes, frame: 0);
  if (decoded == null) {
    // HEIC 已经在 ensure 里分流到原生解码，走不到这里；剩下的都是真正的
    // 未知格式，交给原图路径处理。
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
