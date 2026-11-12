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

class _ImageViewerScreenState extends State<ImageViewerScreen> {
  /// 查看器解码宽度硬上限。
  ///
  /// 之前是按原图解码（4000×3000 的图约 48MB 纹理），进出查看器都要申请/释放
  /// 这么大的纹理，退出转场必掉帧；按屏幕宽 ×2（2560）解码仍然要近 20MB/张，
  /// 翻页时前后几张同时存在很容易把内存顶满。手机屏 1080~1440 像素宽，
  /// 放大到 1.5 倍屏幕宽（封顶 1600）已经能看清细节，纹理体积只有原来的 1/3。
  static const int _maxViewerDecodeWidth = 1600;

  late final PageController _pageController;
  late int _currentIndex;
  bool _currentPageZoomed = false;
  Timer? _precacheTimer;

  String get _currentImagePath => widget.imagePaths[_currentIndex];

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
        body: PageView.builder(
          controller: _pageController,
          physics: _currentPageZoomed
              ? const NeverScrollableScrollPhysics()
              : const PageScrollPhysics(),
          itemCount: widget.imagePaths.length,
          onPageChanged: (index) => setState(() {
            _currentIndex = index;
            _currentPageZoomed = false;
            _precacheAround(index);
          }),
          itemBuilder: (context, index) => _ZoomablePhotoPage(
            key: ValueKey(widget.imagePaths[index]),
            imagePath: widget.imagePaths[index],
            onZoomChanged: index == _currentIndex
                ? (isZoomed) {
                    if (_currentPageZoomed == isZoomed) {
                      return;
                    }
                    setState(() => _currentPageZoomed = isZoomed);
                  }
                : null,
          ),
        ),
      );

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

class _ZoomablePhotoPage extends StatefulWidget {
  const _ZoomablePhotoPage({
    required this.imagePath,
    super.key,
    this.onZoomChanged,
  });

  final String imagePath;
  final ValueChanged<bool>? onZoomChanged;

  @override
  State<_ZoomablePhotoPage> createState() => _ZoomablePhotoPageState();
}

class _ZoomablePhotoPageState extends State<_ZoomablePhotoPage> {
  final TransformationController _transformationController =
      TransformationController();
  Offset? _doubleTapPosition;
  ImageProvider? _imageProvider;
  ImageStream? _imageStream;
  ImageStreamListener? _imageStreamListener;
  // 缩略图：原图解码期间先顶上，避免打开查看器时黑屏等半天
  ImageProvider? _previewProvider;
  ImageStream? _previewStream;
  ImageStreamListener? _previewListener;
  Size? _previewSize;
  Size? _viewportSize;
  Size? _displaySize;
  Size? _imageSize;
  Object? _imageError;
  bool _isZoomed = false;
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
    // 依赖变化（系统栏、转场里的 MediaQuery 抖动）不该重新解码一次大图，
    // 也不该把用户已经缩放好的位置重置掉。
    if (_resolvedPath == widget.imagePath) {
      return;
    }
    _resolveImage();
  }

  @override
  void didUpdateWidget(covariant _ZoomablePhotoPage oldWidget) {
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
    _transformationController.dispose();
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
    _viewportSize = null;
    _displaySize = null;
    _imageSize = null;
    _previewSize = null;
    _imageError = null;
    _transformationController.value = Matrix4.identity();
    _isZoomed = false;
    widget.onZoomChanged?.call(false);

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

  /// 解析 240px 缩略图，只用于原图就绪前的临时展示。
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
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              Navigator.of(context).maybePop();
            },
            onDoubleTapDown: (details) {
              _doubleTapPosition = details.localPosition;
            },
            onDoubleTap: () =>
                _toggleZoom(context, focalPoint: _doubleTapPosition),
            child: ColoredBox(
              color: Colors.black,
              child: SafeArea(
                top: false,
                bottom: false,
                child: _buildZoomableImage(context),
              ),
            ),
          ),
          _buildLiveBadge(),
          _buildLiveOverlay(),
        ],
      );

  void _toggleZoom(BuildContext context, {Offset? focalPoint}) {
    if (_viewportSize == null || _displaySize == null) {
      return;
    }

    if (_isZoomed) {
      _resetToContained();
      setState(() {
        _isZoomed = false;
      });
      widget.onZoomChanged?.call(false);
      return;
    }

    final size = MediaQuery.sizeOf(context);
    final baseZoom = size.shortestSide < 600 ? 2.4 : 2.0;
    final coverZoom = math.max(
      _viewportSize!.width / _displaySize!.width,
      _viewportSize!.height / _displaySize!.height,
    );
    final zoom = math.min(math.max(baseZoom, coverZoom), 5.0);
    final focal = _effectiveZoomFocal(
      focalPoint,
      viewportSize: _viewportSize!,
      displaySize: _displaySize!,
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
    setState(() {
      _isZoomed = true;
    });
    widget.onZoomChanged?.call(true);
  }

  /// 双击 / 捏合允许的最大放大倍数。
  static const double _maxPhotoScale = 5;

  /// 手势起点：焦点落在图片坐标系里的位置，以及当时的缩放倍数。
  ///
  /// 缩放全程锚定这个点，双指外扩时手指底下的像素不会滑走。
  Offset? _gestureFocalScene;
  double _gestureStartScale = 1;

  void _handleScaleStart(ScaleStartDetails details) {
    _gestureStartScale = _transformationController.value
        .getMaxScaleOnAxis()
        .clamp(1.0, _maxPhotoScale);
    _gestureFocalScene = _transformationController.toScene(
      details.localFocalPoint,
    );
  }

  /// 单指拖拽复用同一套公式：单指时 scale 恒为 1，公式退化成纯平移。
  void _handleScaleUpdate(ScaleUpdateDetails details) {
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
    _updateZoomState();
  }

  void _handleScaleEnd(ScaleEndDetails details) {
    _gestureFocalScene = null;
    _settlePhotoTransform();
  }

  /// 桌面端滚轮缩放 —— 原本由 InteractiveViewer 自带，换成自管手势后要补回来。
  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent ||
        _viewportSize == null ||
        _displaySize == null) {
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
    _updateZoomState();
    _settlePhotoTransform();
  }

  Widget _buildZoomableImage(BuildContext context) {
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
        final screenSize = Size(constraints.maxWidth, constraints.maxHeight);
        final displaySize = _containSize(activeSize, screenSize);
        _syncPhotoLayout(screenSize, displaySize);

        // 这里不用 InteractiveViewer，改用自带的 ScaleGestureRecognizer，
        // 原因见 [_PhotoScaleGestureRecognizer] 的注释。
        return Listener(
          onPointerSignal: _handlePointerSignal,
          child: RawGestureDetector(
            behavior: HitTestBehavior.opaque,
            gestures: <Type, GestureRecognizerFactory>{
              _PhotoScaleGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<
                      _PhotoScaleGestureRecognizer>(
                () => _PhotoScaleGestureRecognizer(
                  allowAccept: (recognizer) =>
                      recognizer.pointerCount >= 2 ||
                      _transformationController.value.getMaxScaleOnAxis() >
                          1.01,
                ),
                (recognizer) => recognizer
                  ..onStart = _handleScaleStart
                  ..onUpdate = _handleScaleUpdate
                  ..onEnd = _handleScaleEnd,
              ),
            },
            child: ClipRect(
              // 相当于 InteractiveViewer 的 constrained: false：
              // 让图片按自身尺寸排版，再由 Transform 定位到屏幕中央。
              child: OverflowBox(
                alignment: Alignment.topLeft,
                minWidth: 0,
                maxWidth: double.infinity,
                minHeight: 0,
                maxHeight: double.infinity,
                child: AnimatedBuilder(
                  animation: _transformationController,
                  builder: (context, child) => Transform(
                    transform: _transformationController.value,
                    child: child,
                  ),
                  child: SizedBox(
                    width: displaySize.width,
                    height: displaySize.height,
                    child: Image(
                      image: activeProvider,
                      fit: BoxFit.contain,
                      // 保持默认 medium 插值：high（三次插值）在缩放拖动时非常吃 GPU
                      // 缩略图 → 原图切换时保留旧帧，避免闪一下黑
                      gaplessPlayback: true,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

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

  void _syncPhotoLayout(Size viewportSize, Size displaySize) {
    final layoutChanged =
        _viewportSize != viewportSize || _displaySize != displaySize;
    _viewportSize = viewportSize;
    _displaySize = displaySize;

    if (!layoutChanged || _isZoomed) {
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _isZoomed ||
          _viewportSize != viewportSize ||
          _displaySize != displaySize) {
        return;
      }
      _resetToContained();
    });
  }

  Matrix4 _containedMatrix(Size viewportSize, Size displaySize) {
    final imageRect = _containedImageRect(viewportSize, displaySize);
    return Matrix4.identity()
      ..translateByDouble(imageRect.left, imageRect.top, 0, 1);
  }

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

  void _resetToContained() {
    if (_viewportSize == null || _displaySize == null) {
      _transformationController.value = Matrix4.identity();
      return;
    }
    _transformationController.value =
        _containedMatrix(_viewportSize!, _displaySize!);
  }

  void _clampPhotoTransform() {
    if (_viewportSize == null || _displaySize == null) {
      return;
    }

    final matrix = _transformationController.value;
    final scale = matrix.getMaxScaleOnAxis().clamp(1.0, 5.0);
    final scaledWidth = _displaySize!.width * scale;
    final scaledHeight = _displaySize!.height * scale;
    final translation = matrix.getTranslation();

    final nextX = _clampAxis(
      translation.x,
      viewportExtent: _viewportSize!.width,
      contentExtent: scaledWidth,
    );
    final nextY = _clampAxis(
      translation.y,
      viewportExtent: _viewportSize!.height,
      contentExtent: scaledHeight,
    );

    _transformationController.value = Matrix4.identity()
      ..translateByDouble(nextX, nextY, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);
  }

  double _clampAxis(
    double value, {
    required double viewportExtent,
    required double contentExtent,
  }) {
    if (contentExtent <= viewportExtent) {
      return (viewportExtent - contentExtent) / 2;
    }

    return value.clamp(viewportExtent - contentExtent, 0.0);
  }

  void _updateZoomState() {
    final zoomed = _transformationController.value.getMaxScaleOnAxis() > 1.01;
    if (zoomed != _isZoomed && mounted) {
      setState(() => _isZoomed = zoomed);
      widget.onZoomChanged?.call(zoomed);
    }
  }

  void _settlePhotoTransform() {
    if (_transformationController.value.getMaxScaleOnAxis() <= 1.01) {
      _resetToContained();
      if (_isZoomed && mounted) {
        setState(() => _isZoomed = false);
        widget.onZoomChanged?.call(false);
      }
    } else {
      _clampPhotoTransform();
    }
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

/// 只在「双指」或「已经放大」时才参与手势仲裁的缩放识别器。
///
/// [ScaleGestureRecognizer] 默认单指平移超过 kPanSlop（36dp）就抢手势，而外层
/// 翻页用的 HorizontalDragGestureRecognizer 阈值只有 kTouchSlop（18dp）。阈值上
/// 翻页本该赢，但这个识别器在 Scrollable 内部、指针事件派发更早，所以只要单帧
/// 位移超过 36dp（快速滑动时很常见），它就先一步 accept，翻页被直接拒掉 ——
/// 表现成「慢滑能翻页，使劲快滑反而滑不动」。
///
/// 这里把「单指且未放大」时的 accepted 请求吞掉，让 PageView 稳定拿到单指横滑；
/// 双指捏合或已经放大后照常抢占。
///
/// 探针实测（PageView 包 InteractiveViewer vs 本实现，单指横滑 480dp）：
/// - 改前：单帧位移 8~36dp 能翻页，38dp 起翻页失灵；
/// - 改后：单帧位移 8~240dp 全部正常翻页。
class _PhotoScaleGestureRecognizer extends ScaleGestureRecognizer {
  _PhotoScaleGestureRecognizer({required this.allowAccept});

  /// 返回 true 才允许本识别器赢下手势。
  final bool Function(_PhotoScaleGestureRecognizer recognizer) allowAccept;

  @override
  void resolve(GestureDisposition disposition) {
    if (disposition == GestureDisposition.accepted && !allowAccept(this)) {
      return;
    }
    super.resolve(disposition);
  }
}
