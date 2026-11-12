import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:inkpaper/l10n/app_localizations_simple.dart';
import 'package:inkpaper/providers/app_provider.dart';
import 'package:inkpaper/services/memos_resource_service.dart';
import 'package:inkpaper/utils/attachment_cache.dart';
import 'package:inkpaper/utils/image_cache_manager.dart';
import 'package:inkpaper/utils/image_utils.dart';
import 'package:inkpaper/utils/live_photo_utils.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

class ImageViewerScreen extends StatefulWidget {
  const ImageViewerScreen({
    required this.imagePaths,
    required this.initialIndex,
    super.key,
  });

  final List<String> imagePaths;
  final int initialIndex;

  static Future<void> open(
    BuildContext context, {
    required List<String> imagePaths,
    int initialIndex = 0,
  }) {
    if (imagePaths.isEmpty) {
      return Future.value();
    }

    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => ImageViewerScreen(
          imagePaths: imagePaths,
          initialIndex: initialIndex.clamp(0, imagePaths.length - 1),
        ),
      ),
    );
  }

  @override
  State<ImageViewerScreen> createState() => _ImageViewerScreenState();
}

/// 查看器当前在响应哪种手势。
///
/// 整个查看器只有一个缩放识别器（[_ViewerGestureRecognizer]），翻页也由它驱动，
/// 所以必须自己记住「这一次手势到底在翻页还是在缩放」。
enum _ViewerGestureMode {
  /// 什么都不做（单图，且未放大）。
  none,

  /// 单指横拖翻页。
  page,

  /// 双指缩放，或已放大后单指平移。
  zoom,
}

class _ImageViewerScreenState extends State<ImageViewerScreen> {
  /// 查看器解码宽度硬上限。
  ///
  /// 之前是按原图解码（4000×3000 的图约 48MB 纹理），进出查看器都要申请/释放
  /// 这么大的纹理，退出转场必掉帧；按屏幕宽 ×2（2560）解码仍然要近 20MB/张，
  /// 翻页时前后几张同时存在很容易把内存顶满。手机屏 1080~1440 像素宽，
  /// 放大到 1.5 倍屏幕宽（封顶 1600）已经能看清细节，纹理体积只有原来的 1/3。
  static const int _maxViewerDecodeWidth = 1600;

  /// 双击 / 捏合允许的最大放大倍数。
  static const double _maxPhotoScale = 5;

  /// 松手时判定翻页的两个门槛：拖过屏宽的 [_pageDistanceFraction]，
  /// 或者甩动速度超过 [_pageVelocityThreshold] px/s。
  static const double _pageDistanceFraction = 0.22;
  static const double _pageVelocityThreshold = 520;

  late final PageController _pageController;
  late int _currentIndex;
  Timer? _precacheTimer;

  /// 当前页的变换矩阵。
  ///
  /// `Matrix4.identity()` 就代表「按原始比例完整显示并居中」，图片本身由
  /// `Center` 布局摆好，矩阵只负责缩放与平移 —— 所以复位就是回到 identity，
  /// 不需要再算一个居中用的平移量。
  final TransformationController _transformationController =
      TransformationController();

  /// 当前页的视口尺寸与图片显示尺寸（由 [_PhotoPage] 布局时回报）。
  Size? _viewportSize;
  Size? _displaySize;

  _ViewerGestureMode _mode = _ViewerGestureMode.none;
  double _gestureStartScale = 1;
  Offset? _gestureStartFocal;
  Offset? _gestureFocalScene;
  double? _pagesAtGestureStart;
  int _lastPointerCount = 0;
  Offset? _doubleTapPosition;

  String get _currentImagePath => widget.imagePaths[_currentIndex];

  double get _currentScale => _transformationController.value
      .getMaxScaleOnAxis()
      .clamp(1.0, _maxPhotoScale);

  /// 查看器实际使用的解码宽度（屏幕宽 ×1.5，封顶 [_maxViewerDecodeWidth]）。
  static int viewerDecodeWidth(BuildContext context) {
    final media = MediaQuery.of(context);
    final screenPixels = (media.size.width * media.devicePixelRatio).round();
    final target = (screenPixels * 1.5).round();
    return target > _maxViewerDecodeWidth ? _maxViewerDecodeWidth : target;
  }

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex.clamp(0, widget.imagePaths.length - 1);
    _pageController = PageController(initialPage: _currentIndex);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _precacheAround(_currentIndex);
      }
    });
  }

  @override
  void dispose() {
    _precacheTimer?.cancel();
    _pageController.dispose();
    _transformationController.dispose();
    super.dispose();
  }

  /// 构建查看器用的 ImageProvider。
  ///
  /// [maxWidth] 非空时按该像素宽解码（用于先出缩略图），为空则是原图。
  static ImageProvider getImageProvider(
    String uriString,
    BuildContext context, {
    int? maxWidth,
  }) {
    try {
      // 已缓存到本地的服务端附件：看原图也走本地文件
      final cachedAttachment = AttachmentCache.instance.fileFor(uriString);
      if (cachedAttachment != null) {
        final fileImage = FileImage(cachedAttachment);
        if (maxWidth == null) {
          return fileImage;
        }
        return ResizeImage(
          fileImage,
          width: maxWidth,
        );
      }

      if (uriString.startsWith('http://') || uriString.startsWith('https://')) {
        return CachedNetworkImageProvider(
          uriString,
          cacheManager: ImageCacheManager.authImageCache,
          maxWidth: maxWidth,
        );
      }

      if (_isServerResourcePath(uriString)) {
        final appProvider = Provider.of<AppProvider>(context, listen: false);
        final token = appProvider.user?.token;
        final fullUrl = _buildFullResourceUrl(appProvider, uriString);
        if (fullUrl == null) {
          return const AssetImage('assets/images/logo.png');
        }

        return CachedNetworkImageProvider(
          fullUrl,
          headers: token != null ? {'Authorization': 'Bearer $token'} : null,
          cacheManager: ImageCacheManager.authImageCache,
          maxWidth: maxWidth,
        );
      }

      if (uriString.startsWith('file://')) {
        final fileImage = FileImage(
          File(uriString.replaceFirst('file://', '')),
        );
        if (maxWidth == null) {
          return fileImage;
        }
        return ResizeImage(
          fileImage,
          width: maxWidth,
        );
      }

      if (uriString.startsWith('resource:')) {
        return AssetImage(uriString.replaceFirst('resource:', ''));
      }

      return const AssetImage('assets/images/logo.png');
    } on Object catch (e) {
      if (kDebugMode) {
        debugPrint('ImageViewer: provider error: $e');
      }
      return const AssetImage('assets/images/logo.png');
    }
  }

  static bool _isServerResourcePath(String path) =>
      MemosResourceService.isServerResourcePath(path);

  static String? _buildFullResourceUrl(AppProvider appProvider, String path) {
    if (appProvider.resourceService != null) {
      return appProvider.resourceService!.buildImageUrl(path);
    }

    final baseUrl = appProvider.appConfig.lastServerUrl ??
        appProvider.user?.serverUrl ??
        appProvider.appConfig.memosApiUrl ??
        '';
    return baseUrl.isEmpty ? null : '$baseUrl$path';
  }

  String _getFullImageUrl(BuildContext context) {
    // 保存图片时优先用本地缓存，离线也能保存
    final cachedAttachment =
        AttachmentCache.instance.pathFor(_currentImagePath);
    if (cachedAttachment != null) {
      return 'file://$cachedAttachment';
    }

    if (_currentImagePath.startsWith('http://') ||
        _currentImagePath.startsWith('https://')) {
      return _currentImagePath;
    }

    if (_isServerResourcePath(_currentImagePath)) {
      final appProvider = Provider.of<AppProvider>(context, listen: false);
      return _buildFullResourceUrl(appProvider, _currentImagePath) ??
          _currentImagePath;
    }

    return _currentImagePath;
  }

  Map<String, String>? _getHeaders(BuildContext context) {
    if (!_isServerResourcePath(_currentImagePath)) {
      return null;
    }

    final appProvider = Provider.of<AppProvider>(context, listen: false);
    final token = appProvider.user?.token;
    return token != null ? {'Authorization': 'Bearer $token'} : null;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          backgroundColor: Colors.black.withValues(alpha: 0.34),
          elevation: 0,
          iconTheme: const IconThemeData(color: Colors.white),
          title: Text(
            widget.imagePaths.length > 1
                ? '${_currentIndex + 1}/${widget.imagePaths.length}'
                : (AppLocalizationsSimple.of(context)?.viewOriginalImage ??
                    '查看原图'),
            style: const TextStyle(color: Colors.white, fontSize: 16),
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.download, color: Colors.white),
              tooltip: AppLocalizationsSimple.of(context)?.saveImage ?? '保存图片',
              onPressed: () async {
                await ImageUtils.saveImageToGallery(
                  context,
                  _getFullImageUrl(context),
                  headers: _getHeaders(context),
                );
              },
            ),
          ],
        ),
        // 键盘 / 鼠标滚轮缩放：只有 PointerSignal，不参与手势竞技场
        body: Listener(
          onPointerSignal: _handlePointerSignal,
          // 查看器里所有触摸手势都归这一个识别器管：翻页、缩放、平移。
          // PageView 的 physics 恒为 NeverScrollable，它不再注册拖动识别器，
          // 也就不会和缩放手势抢 —— 这是这次改造的核心。
          child: RawGestureDetector(
            behavior: HitTestBehavior.opaque,
            gestures: <Type, GestureRecognizerFactory>{
              TapGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
                TapGestureRecognizer.new,
                (recognizer) => recognizer.onTap = _handleCloseTap,
              ),
              DoubleTapGestureRecognizer: GestureRecognizerFactoryWithHandlers<
                  DoubleTapGestureRecognizer>(
                DoubleTapGestureRecognizer.new,
                (recognizer) => recognizer
                  ..onDoubleTapDown = _handleDoubleTapDown
                  ..onDoubleTap = _handleDoubleTap,
              ),
              _ViewerGestureRecognizer: GestureRecognizerFactoryWithHandlers<
                  _ViewerGestureRecognizer>(
                _ViewerGestureRecognizer.new,
                (recognizer) => recognizer
                  ..onStart = _handleScaleStart
                  ..onUpdate = _handleScaleUpdate
                  ..onEnd = _handleScaleEnd,
              ),
            },
            child: PageView.builder(
              controller: _pageController,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: widget.imagePaths.length,
              onPageChanged: _handlePageChanged,
              itemBuilder: (context, index) => _PhotoPage(
                key: ValueKey(widget.imagePaths[index]),
                imagePath: widget.imagePaths[index],
                matrix:
                    index == _currentIndex ? _transformationController : null,
                onLayout: index == _currentIndex ? _handleCurrentLayout : null,
              ),
            ),
          ),
        ),
      );

  void _handleCloseTap() {
    Navigator.of(context).maybePop();
  }

  void _handleDoubleTapDown(TapDownDetails details) {
    _doubleTapPosition = details.localPosition;
  }

  void _handleDoubleTap() {
    _toggleZoom(focalPoint: _doubleTapPosition);
  }

  void _handlePageChanged(int index) {
    // 换页后新的一页要从「完整显示」开始，否则会带着上一张的缩放和偏移。
    _transformationController.value = Matrix4.identity();
    setState(() {
      _currentIndex = index;
    });
    _precacheAround(index);
  }

  /// 当前页布局回报。只在排版阶段被调用，不能 setState。
  void _handleCurrentLayout(Size viewportSize, Size displaySize) {
    final changed =
        _viewportSize != viewportSize || _displaySize != displaySize;
    _viewportSize = viewportSize;
    _displaySize = displaySize;
    if (!changed) {
      return;
    }
    // 旋转屏幕 / 分屏改变尺寸后把图片拉回可视范围；手势进行中不打断。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _mode == _ViewerGestureMode.zoom) {
        return;
      }
      _settlePhotoTransform();
    });
  }

  // ---------------------------------------------------------------------------
  // 手势
  // ---------------------------------------------------------------------------

  void _handleScaleStart(ScaleStartDetails details) {
    _gestureStartScale = _currentScale;
    _gestureStartFocal = details.localFocalPoint;
    _gestureFocalScene =
        _transformationController.toScene(details.localFocalPoint);
    _pagesAtGestureStart =
        _pageController.hasClients ? _pageController.page : null;
    _lastPointerCount = details.pointerCount;

    if (details.pointerCount >= 2 || _gestureStartScale > 1.01) {
      _mode = _ViewerGestureMode.zoom;
      return;
    }
    // 单图没什么可翻的，单指拖动直接不响应，省得图片被拖着晃。
    _mode = widget.imagePaths.length > 1
        ? _ViewerGestureMode.page
        : _ViewerGestureMode.none;
  }

  void _handleScaleUpdate(ScaleUpdateDetails details) {
    final pointerCountChanged = details.pointerCount != _lastPointerCount;
    _lastPointerCount = details.pointerCount;

    // 先横拖了一段再补上第二根手指：把页面归位并转成缩放。
    // 否则会带着半页偏移去缩放，看着像整块画面在漂。
    if (details.pointerCount >= 2 && _mode != _ViewerGestureMode.zoom) {
      _snapToCurrentPage();
      _mode = _ViewerGestureMode.zoom;
      _gestureStartScale = _currentScale;
      _gestureFocalScene =
          _transformationController.toScene(details.localFocalPoint);
      return;
    }

    // 手指数变化（最常见的是捏合后抬起一根手指、接着单指平移）时，
    // ScaleGestureRecognizer 会把 span 重新锚定、scale 归 1。
    // 我们也必须跟着重锚，否则 nextScale 会按「起始倍数 1」算，图片瞬间弹回原大小。
    if (pointerCountChanged) {
      _gestureStartScale = _currentScale;
      _gestureFocalScene =
          _transformationController.toScene(details.localFocalPoint);
    }

    switch (_mode) {
      case _ViewerGestureMode.zoom:
        _applyZoom(details);
      case _ViewerGestureMode.page:
        _applyPageDrag(details);
      case _ViewerGestureMode.none:
        break;
    }
  }

  void _handleScaleEnd(ScaleEndDetails details) {
    switch (_mode) {
      case _ViewerGestureMode.page:
        _settlePageDrag(details);
      case _ViewerGestureMode.zoom:
        _settlePhotoTransform();
      case _ViewerGestureMode.none:
        break;
    }
    _mode = _ViewerGestureMode.none;
    _gestureStartFocal = null;
    _gestureFocalScene = null;
    _pagesAtGestureStart = null;
  }

  /// 缩放：全程锚定手势起点，双指外扩时手指底下的像素不会滑走。
  /// 单指平移复用同一套公式 —— 此时 scale 恒为 1，公式退化成纯平移。
  void _applyZoom(ScaleUpdateDetails details) {
    final focalScene = _gestureFocalScene;
    if (focalScene == null) {
      return;
    }
    final nextScale =
        (_gestureStartScale * details.scale).clamp(1.0, _maxPhotoScale);
    final focal = details.localFocalPoint;
    _transformationController.value = Matrix4.identity()
      ..translateByDouble(
        focal.dx - focalScene.dx * nextScale,
        focal.dy - focalScene.dy * nextScale,
        0,
        1,
      )
      ..scaleByDouble(nextScale, nextScale, 1, 1);
  }

  /// 单指横拖翻页：直接把 PageView 拖到对应位置，跟手 1:1。
  void _applyPageDrag(ScaleUpdateDetails details) {
    final startFocal = _gestureStartFocal;
    final startPages = _pagesAtGestureStart;
    if (startFocal == null || startPages == null) {
      return;
    }
    if (!_pageController.hasClients) {
      return;
    }

    final position = _pageController.position;
    final width = position.viewportDimension;
    if (width <= 0) {
      return;
    }

    final delta = details.localFocalPoint.dx - startFocal.dx;
    final targetPage = (startPages - delta / width).clamp(
      0.0,
      (widget.imagePaths.length - 1).toDouble(),
    );
    position.jumpTo(
      (targetPage * width).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      ),
    );
  }

  /// 松手结算：拖得够远或甩得够快就翻到相邻页，否则弹回原页。
  void _settlePageDrag(ScaleEndDetails details) {
    final startPages = _pagesAtGestureStart;
    if (startPages == null || !_pageController.hasClients) {
      return;
    }

    final page = _pageController.page ?? startPages;
    final delta = page - startPages;
    final velocity = details.velocity.pixelsPerSecond.dx;

    var direction = 0;
    if (delta.abs() > _pageDistanceFraction) {
      direction = delta > 0 ? 1 : -1;
    } else if (velocity.abs() > _pageVelocityThreshold) {
      // 手指往左甩（dx < 0）表示要看下一张
      direction = velocity < 0 ? 1 : -1;
    }

    final target = (startPages.round() + direction).clamp(
      0,
      widget.imagePaths.length - 1,
    );
    _animateToPage(target);
  }

  void _animateToPage(int index) {
    if (!_pageController.hasClients) {
      return;
    }
    unawaited(
      _pageController.animateToPage(
        index,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  /// 把手势进行到一半的页面拉回当前页（转成缩放前调用）。
  void _snapToCurrentPage() {
    if (!_pageController.hasClients) {
      return;
    }
    final position = _pageController.position;
    final target = (_currentIndex * position.viewportDimension).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if ((position.pixels - target).abs() > 0.5) {
      position.jumpTo(target);
    }
  }

  /// 鼠标滚轮缩放。
  void _handlePointerSignal(PointerSignalEvent event) {
    final viewport = _viewportSize;
    final display = _displaySize;
    if (event is! PointerScrollEvent || viewport == null || display == null) {
      return;
    }

    final matrix = _transformationController.value;
    final current = matrix.getMaxScaleOnAxis().clamp(1.0, _maxPhotoScale);
    // 与 InteractiveViewer 的 scaleFactor = 200 保持同一手感
    final next = (current * math.exp(-event.scrollDelta.dy / 200)).clamp(
      1.0,
      _maxPhotoScale,
    );
    if ((next - current).abs() < 1e-4) {
      return;
    }

    final focal = event.localPosition;
    final focalScene = _transformationController.toScene(focal);
    _transformationController.value = Matrix4.identity()
      ..translateByDouble(
        focal.dx - focalScene.dx * next,
        focal.dy - focalScene.dy * next,
        0,
        1,
      )
      ..scaleByDouble(next, next, 1, 1);
    _settlePhotoTransform();
  }

  // ---------------------------------------------------------------------------
  // 缩放矩阵运算
  // ---------------------------------------------------------------------------

  void _toggleZoom({Offset? focalPoint}) {
    final viewport = _viewportSize;
    final display = _displaySize;
    if (viewport == null || display == null) {
      return;
    }

    if (_currentScale > 1.01) {
      _transformationController.value = Matrix4.identity();
      return;
    }

    final size = MediaQuery.sizeOf(context);
    final baseZoom = size.shortestSide < 600 ? 2.4 : 2.0;
    final coverZoom = math.max(
      viewport.width / display.width,
      viewport.height / display.height,
    );
    final zoom = math.min(math.max(baseZoom, coverZoom), _maxPhotoScale);
    final focal = _effectiveZoomFocal(
      focalPoint,
      viewportSize: viewport,
      displaySize: display,
    );
    final scenePoint = _transformationController.toScene(focal);

    _transformationController.value = Matrix4.identity()
      ..translateByDouble(
        focal.dx - scenePoint.dx * zoom,
        focal.dy - scenePoint.dy * zoom,
        0,
        1,
      )
      ..scaleByDouble(zoom, zoom, 1, 1);
    _clampPhotoTransform();
  }

  /// 图片在视口里的位置（缩放倍数为 1 时）。
  Rect _containedImageRect(Size viewportSize, Size displaySize) =>
      Rect.fromLTWH(
        (viewportSize.width - displaySize.width) / 2,
        (viewportSize.height - displaySize.height) / 2,
        displaySize.width,
        displaySize.height,
      );

  Offset _effectiveZoomFocal(
    Offset? focalPoint, {
    required Size viewportSize,
    required Size displaySize,
  }) {
    final viewportCenter =
        Offset(viewportSize.width / 2, viewportSize.height / 2);
    if (focalPoint == null) {
      return viewportCenter;
    }

    final imageRect = _containedImageRect(viewportSize, displaySize);
    return imageRect.contains(focalPoint) ? focalPoint : viewportCenter;
  }

  /// 松手后收敛：没放大就复位，放大了就把图片拉回可视范围。
  void _settlePhotoTransform() {
    if (_currentScale <= 1.01) {
      _transformationController.value = Matrix4.identity();
      return;
    }
    _clampPhotoTransform();
  }

  void _clampPhotoTransform() {
    final viewport = _viewportSize;
    final display = _displaySize;
    if (viewport == null || display == null) {
      return;
    }

    final rect = _containedImageRect(viewport, display);
    final matrix = _transformationController.value;
    final scale = matrix.getMaxScaleOnAxis().clamp(1.0, _maxPhotoScale);
    final translation = matrix.getTranslation();

    final nextX = _clampAxis(
      translation.x,
      scaledStart: rect.left * scale,
      scaledExtent: rect.width * scale,
      viewportExtent: viewport.width,
    );
    final nextY = _clampAxis(
      translation.y,
      scaledStart: rect.top * scale,
      scaledExtent: rect.height * scale,
      viewportExtent: viewport.height,
    );

    _transformationController.value = Matrix4.identity()
      ..translateByDouble(nextX, nextY, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);
  }

  /// 把平移量夹到「图片不出视口」的范围；图片比视口小时居中。
  ///
  /// [scaledStart] 是图片左/上边在缩放后的坐标（图片已经按居中排好版），
  /// [scaledExtent] 是缩放后的宽/高。
  double _clampAxis(
    double translatedValue, {
    required double scaledStart,
    required double scaledExtent,
    required double viewportExtent,
  }) {
    if (scaledExtent <= viewportExtent) {
      return (viewportExtent - scaledExtent) / 2 - scaledStart;
    }

    return translatedValue.clamp(
      viewportExtent - scaledStart - scaledExtent,
      -scaledStart,
    );
  }

  /// 预取相邻的一张（没有下一张时退回上一张）。
  ///
  /// 两点收敛：一是只取一张，二是等翻页/进入动画结束再解码。之前的实现会同时
  /// 预取左右两张超大图，解码线程与转场动画抢同一段时间线，于是"打开查看器"
  /// 和"左右滑动"都会卡一下。
  void _precacheAround(int index) {
    _precacheTimer?.cancel();
    _precacheTimer = Timer(const Duration(milliseconds: 180), () {
      if (!mounted) {
        return;
      }
      final nextIndex =
          index + 1 < widget.imagePaths.length ? index + 1 : index - 1;
      if (nextIndex < 0 || nextIndex == index) {
        return;
      }
      unawaited(
        precacheImage(
          getImageProvider(
            widget.imagePaths[nextIndex],
            context,
            maxWidth: viewerDecodeWidth(context),
          ),
          context,
        ).catchError((Object _) {
          // 预取失败不影响当前图片展示
        }),
      );
    });
  }
}

/// 按原始比例把 [source] 装进 [bounds]。
Size _containSize(Size source, Size bounds) {
  if (source.width <= 0 || source.height <= 0) {
    return bounds;
  }

  final scale = math.min(
    bounds.width / source.width,
    bounds.height / source.height,
  );
  return Size(source.width * scale, source.height * scale);
}

class _PhotoPage extends StatefulWidget {
  const _PhotoPage({
    required this.imagePath,
    super.key,
    this.matrix,
    this.onLayout,
  });

  final String imagePath;

  /// 当前页才会拿到缩放矩阵，相邻页传 null（永远按完整显示渲染）。
  final TransformationController? matrix;

  /// 布局回报：视口尺寸、图片显示尺寸。只在当前页回调。
  final void Function(Size viewportSize, Size displaySize)? onLayout;

  @override
  State<_PhotoPage> createState() => _PhotoPageState();
}

class _PhotoPageState extends State<_PhotoPage> {
  ImageProvider? _imageProvider;
  ImageStream? _imageStream;
  ImageStreamListener? _imageStreamListener;
  // 缩略图：原图解码期间先顶上，避免打开查看器时黑屏等半天
  ImageProvider? _previewProvider;
  ImageStream? _previewStream;
  ImageStreamListener? _previewListener;
  Size? _previewSize;
  Size? _imageSize;
  Object? _imageError;
  String? _resolvedPath;

  // Live 图（Motion Photo）：图片旁边存了一份内嵌视频，点角标播放
  VideoPlayerController? _liveController;
  bool _hasLiveVideo = false;
  bool _livePlaying = false;
  bool _liveLoading = false;
  bool _liveFailed = false;

  @override
  void initState() {
    super.initState();
    _hasLiveVideo = LivePhotoUtils.hasLiveVideo(widget.imagePath);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 依赖变化（系统栏、转场里的 MediaQuery 抖动）不该重新解码一次大图。
    if (_resolvedPath == widget.imagePath) {
      return;
    }
    _resolveImage();
  }

  @override
  void didUpdateWidget(covariant _PhotoPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imagePath != widget.imagePath) {
      _resolveImage();
      _disposeLiveController();
      _hasLiveVideo = LivePhotoUtils.hasLiveVideo(widget.imagePath);
      _liveFailed = false;
    }
  }

  void _disposeLiveController() {
    final controller = _liveController;
    _liveController = null;
    _livePlaying = false;
    _liveLoading = false;
    if (controller != null) {
      unawaited(controller.dispose());
    }
  }

  /// 点击 LIVE 角标：首次点击才创建播放器，避免打开查看器就解码视频。
  Future<void> _toggleLive() async {
    if (_livePlaying) {
      await _liveController?.pause();
      if (mounted) {
        setState(() => _livePlaying = false);
      }
      return;
    }
    if (_liveFailed) {
      return;
    }

    var controller = _liveController;
    if (controller == null) {
      setState(() => _liveLoading = true);
      final created = VideoPlayerController.file(
        File(LivePhotoUtils.videoPathFor(widget.imagePath)),
      );
      try {
        await created.initialize();
        await created.setLooping(true);
        _liveController = created;
        controller = created;
      } on Object catch (e) {
        debugPrint('LivePhoto: 视频初始化失败: $e');
        unawaited(created.dispose());
        if (mounted) {
          setState(() {
            _liveFailed = true;
            _liveLoading = false;
          });
        }
        return;
      }
    }

    try {
      await controller.seekTo(Duration.zero);
      await controller.play();
    } on Object catch (e) {
      debugPrint('LivePhoto: 播放失败: $e');
      if (mounted) {
        setState(() {
          _liveFailed = true;
          _liveLoading = false;
        });
      }
      return;
    }
    if (mounted) {
      setState(() {
        _livePlaying = true;
        _liveLoading = false;
      });
    }
  }

  Widget _buildLiveBadge() {
    if (!_hasLiveVideo) {
      return const SizedBox.shrink();
    }
    final topInset = MediaQuery.paddingOf(context).top + 12;
    return Positioned(
      left: 12,
      top: topInset,
      child: GestureDetector(
        onTap: _toggleLive,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white.withValues(alpha: 0.25)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_liveLoading)
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.6,
                    color: Colors.white,
                  ),
                )
              else
                Icon(
                  Icons.motion_photos_on_rounded,
                  size: 14,
                  color: _liveFailed ? Colors.grey : Colors.white,
                ),
              const SizedBox(width: 4),
              Text(
                'LIVE',
                style: TextStyle(
                  color: _liveFailed ? Colors.grey : Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.6,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLiveOverlay() {
    final controller = _liveController;
    if (!_livePlaying ||
        controller == null ||
        !controller.value.isInitialized) {
      return const SizedBox.shrink();
    }
    final aspectRatio = controller.value.aspectRatio <= 0
        ? 3 / 4
        : controller.value.aspectRatio;
    return Positioned.fill(
      child: GestureDetector(
        onTap: () {
          unawaited(controller.pause());
          setState(() => _livePlaying = false);
        },
        child: ColoredBox(
          color: Colors.black,
          child: Center(
            child: AspectRatio(
              aspectRatio: aspectRatio,
              child: VideoPlayer(controller),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    if (_imageStream != null && _imageStreamListener != null) {
      _imageStream!.removeListener(_imageStreamListener!);
    }
    // 查看器的高清图解码尺寸与列表/详情不同，对其它页面没有复用价值；
    // 退出时主动 evict，别让几十 MB 的纹理把详情页缩略图挤出缓存。
    final provider = _imageProvider;
    if (provider != null) {
      unawaited(provider.evict());
    }
    _detachPreview();
    _disposeLiveController();
    super.dispose();
  }

  void _resolveImage() {
    _detachPreview();
    _resolvedPath = widget.imagePath;

    final provider = _ImageViewerScreenState.getImageProvider(
      widget.imagePath,
      context,
      maxWidth: _ImageViewerScreenState.viewerDecodeWidth(context),
    );
    final stream = provider.resolve(createLocalImageConfiguration(context));

    if (_imageStream != null && _imageStreamListener != null) {
      _imageStream?.removeListener(_imageStreamListener!);
    }

    _imageProvider = provider;
    _imageSize = null;
    _previewSize = null;
    _imageError = null;

    // 缩略图先上：磁盘缓存命中时几十毫秒就能出图，
    // 原图解码完会由 _imageSize 到达时的 setState 自动替换。
    _resolvePreview();

    _imageStreamListener = ImageStreamListener(
      (imageInfo, _) {
        if (!mounted) {
          return;
        }
        setState(() {
          _imageSize = Size(
            imageInfo.image.width.toDouble(),
            imageInfo.image.height.toDouble(),
          );
          _imageError = null;
        });
      },
      onError: (error, stackTrace) {
        if (kDebugMode) {
          debugPrint('Full screen image error: $error');
        }
        if (!mounted) {
          return;
        }
        setState(() {
          _imageError = error;
        });
      },
    );

    _imageStream = stream;
    stream.addListener(_imageStreamListener!);
  }

  /// 解析 480px 缩略图，只用于原图就绪前的临时展示。
  void _resolvePreview() {
    try {
      final provider = _ImageViewerScreenState.getImageProvider(
        widget.imagePath,
        context,
        maxWidth: 480,
      );
      _previewProvider = provider;
      final stream = provider.resolve(createLocalImageConfiguration(context));
      final listener = ImageStreamListener(
        (imageInfo, _) {
          if (!mounted || _imageSize != null) {
            return;
          }
          setState(() {
            _previewSize = Size(
              imageInfo.image.width.toDouble(),
              imageInfo.image.height.toDouble(),
            );
          });
        },
        onError: (error, stackTrace) {
          // 缩略图失败就安静地等原图，不额外弹错误
        },
      );
      stream.addListener(listener);
      _previewStream = stream;
      _previewListener = listener;
    } on Object catch (e) {
      if (kDebugMode) {
        debugPrint('ImageViewer: preview resolve failed: $e');
      }
    }
  }

  void _detachPreview() {
    if (_previewStream != null && _previewListener != null) {
      _previewStream!.removeListener(_previewListener!);
    }
    _previewStream = null;
    _previewListener = null;
    _previewProvider = null;
  }

  @override
  Widget build(BuildContext context) => Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: Colors.black, child: _buildPhoto(context)),
          _buildLiveBadge(),
          _buildLiveOverlay(),
        ],
      );

  Widget _buildPhoto(BuildContext context) {
    if (_imageError != null) {
      return _buildImageError(
        AppLocalizationsSimple.of(context)?.imageLoadError ?? '无法加载图片',
      );
    }

    // 原图还没解码完就先画缩略图，尺寸比例相同，替换时不会跳
    final activeProvider =
        _imageSize != null ? _imageProvider : _previewProvider;
    final activeSize = _imageSize ?? _previewSize;
    if (activeProvider == null || activeSize == null) {
      return _buildImageLoading(context);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportSize = Size(constraints.maxWidth, constraints.maxHeight);
        final displaySize = _containSize(activeSize, viewportSize);
        widget.onLayout?.call(viewportSize, displaySize);

        // 图片按「完整显示并居中」排好，缩放矩阵再作用于整个视口盒子，
        // 所以 identity 矩阵就是初始状态，不用额外算居中平移。
        final content = SizedBox(
          width: viewportSize.width,
          height: viewportSize.height,
          child: Center(
            child: SizedBox(
              width: displaySize.width,
              height: displaySize.height,
              child: Image(
                image: activeProvider,
                fit: BoxFit.fill,
                // 保持默认 medium 插值：high（三次插值）在缩放拖动时非常吃 GPU
                // 缩略图 → 原图切换时保留旧帧，避免闪一下黑
                gaplessPlayback: true,
              ),
            ),
          ),
        );

        final matrix = widget.matrix;
        if (matrix == null) {
          return ClipRect(child: content);
        }

        return ClipRect(
          child: AnimatedBuilder(
            animation: matrix,
            builder: (context, inner) => Transform(
              transform: matrix.value,
              child: inner,
            ),
            child: content,
          ),
        );
      },
    );
  }

  Widget _buildImageLoading(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: Colors.white),
            const SizedBox(height: 16),
            Text(
              AppLocalizationsSimple.of(context)?.loadingHDImage ??
                  '正在加载高清原图...',
              style: const TextStyle(color: Colors.white70),
            ),
          ],
        ),
      );

  Widget _buildImageError(String message) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 60, color: Colors.red[300]),
            const SizedBox(height: 16),
            Text(
              message,
              style: const TextStyle(color: Colors.white, fontSize: 16),
            ),
          ],
        ),
      );
}

/// 查看器唯一的手势识别器：单指翻页 / 平移，双指缩放。
///
/// 之前是 PageView 自带的 `HorizontalDragGestureRecognizer`（阈值 kTouchSlop，
/// 18dp）和页面里的 `ScaleGestureRecognizer`（阈值 kScaleSlop，同样是 18dp）
/// 各自抢手势。手势竞技场的规则是「谁先 accept 谁独占整场」，而捏合的自然动作
/// 是先落一根手指、再落第二根 —— 第一根手指只要横滑 18dp，翻页就先赢了，
/// 第二根手指落下也缩放不了。两个 18dp 阈值顶着，结果就是掷硬币。
///
/// 现在翻页也归这个识别器驱动（PageView 的 physics 恒为 NeverScrollable，
/// 不注册拖动识别器），整个查看器只剩它和点击/双击竞争，冲突从机制上消失。
class _ViewerGestureRecognizer extends ScaleGestureRecognizer {
  /// 第一根手指按下的位置，用来判断单指能不能提前抢手势。
  Offset? _primaryDownPosition;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (pointerCount == 0) {
      _primaryDownPosition = event.localPosition;
    }
    super.addAllowedPointer(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    super.handleEvent(event);

    // 第二根手指一落下就抢，不再等 span 变化凑满 18dp。
    if (event is PointerDownEvent && pointerCount >= 2) {
      resolve(GestureDisposition.accepted);
      return;
    }

    // 单指：比 ScaleGestureRecognizer 默认的 36dp（pan slop）更早接管，
    // 翻页手感才跟得上手指。
    if (event is PointerMoveEvent && pointerCount == 1) {
      final downPosition = _primaryDownPosition;
      if (downPosition != null &&
          (event.localPosition - downPosition).distance > kTouchSlop) {
        resolve(GestureDisposition.accepted);
      }
    }
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _primaryDownPosition = null;
    super.didStopTrackingLastPointer(pointer);
  }
}
