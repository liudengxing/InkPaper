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
    // 本进程内已经失败过的（HEIC 之类）不再重试：补齐循环会反复扫到同一批
    // 文件，没有这道闸门就会一直啃它们，永远追不平。
    if (_giveUp.contains(name)) {
      return null;
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
    var slot = false;
    try {
      await _acquireEncodeSlot(lowPriority: lowPriority);
      slot = true;
      // 排队期间别的调用方可能已经把它生成好了，省掉一次重复解码
      if (_known.contains(name)) {
        return target;
      }
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
      if (slot) {
        _releaseEncodeSlot();
      }
      _inflight.remove(name);
    }
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
    var total = 0;
    while (!_backfillStopped) {
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
        if (_backfillStopped || _backfillPaused) {
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
    final imagesDir = Directory(imagesDirPath);
    if (!await imagesDir.exists()) {
      return const <File>[];
    }
    final candidates = <File>[];
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
      candidates.add(entity);
    }
    candidates.sort((a, b) {
      final aTime = a.statSync().modified;
      final bTime = b.statSync().modified;
      return bTime.compareTo(aTime);
    });
    return candidates;
  }

  /// 清空全部缩略图（设置里「清理缓存」用，删完会按需重建）。
  Future<void> clear() async {
    // 正在补齐的话先停下来：否则删完立刻又被补回来，用户点了「清理缓存」
    // 却看不到空间释放。下次启动会重新开始补齐。
    stopBackfill();
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

/// 编码名额的排队凭证。
class _EncodeSlot {
  _EncodeSlot({required this.lowPriority});

  /// 后台补齐提交的任务只能排低优先级，前台渲染触发的任务会插到它前面。
  final bool lowPriority;
  final Completer<void> completer = Completer<void>();
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
