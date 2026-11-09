import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:inkpaper/providers/app_provider.dart';
import 'package:inkpaper/screens/image_viewer_screen.dart';
import 'package:inkpaper/services/memos_resource_service.dart';
import 'package:inkpaper/utils/attachment_cache.dart';
import 'package:inkpaper/utils/image_cache_manager.dart';
import 'package:inkpaper/utils/image_decode_width.dart';
import 'package:provider/provider.dart';

/// 笔记图片九宫格。
///
/// flomo 的做法：图片不再一张张插在正文里，而是统一按 3 列方块排在正文下方，
/// 点开才进全屏查看器。首页卡片和详情页共用同一套视觉。
class NoteImageGrid extends StatefulWidget {
  const NoteImageGrid({
    required this.imagePaths,
    super.key,
    this.serverUrl,
    this.crossAxisCount = 3,
    this.spacing = 6,
    this.borderRadius = 8,
    this.onLongPress,
  });

  final List<String> imagePaths;
  final String? serverUrl;
  final int crossAxisCount;
  final double spacing;
  final double borderRadius;

  /// 长按回调（详情页用来弹保存菜单）；为空时长按不响应。
  final void Function(String path)? onLongPress;

  @override
  State<NoteImageGrid> createState() => _NoteImageGridState();

  /// 点击卡片进详情前预取图片（实现见 State，与网格渲染共用同一套解码宽度）。
  static void precacheNoteImages(
    BuildContext context,
    List<String> imagePaths, {
    String? serverUrl,
  }) =>
      _NoteImageGridState.precacheNoteImages(
        context,
        imagePaths,
        serverUrl: serverUrl,
      );
}

class _NoteImageGridState extends State<NoteImageGrid> {
  /// 首帧只铺静态占位，等路由转场走完再挂真正的 Image。
  ///
  /// 多图笔记进详情时，N 张图原本会在同一帧一起发起解码；大图解码与转场动画
  /// 抢同一条时间线，表现就是"点开多图笔记必卡一下"。延后一小段后，正文先上屏，
  /// 解码落在之后的帧里，转场不再掉帧。
  static const Duration _decodeDelay = Duration(milliseconds: 90);

  Timer? _decodeTimer;
  bool _imagesReady = false;

  List<String> get imagePaths => widget.imagePaths;
  String? get serverUrl => widget.serverUrl;
  int get crossAxisCount => widget.crossAxisCount;
  double get spacing => widget.spacing;
  double get borderRadius => widget.borderRadius;
  void Function(String path)? get onLongPress => widget.onLongPress;

  @override
  void initState() {
    super.initState();
    _decodeTimer = Timer(_decodeDelay, () {
      if (mounted) {
        setState(() => _imagesReady = true);
      }
    });
  }

  @override
  void dispose() {
    _decodeTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (imagePaths.isEmpty) {
      return const SizedBox.shrink();
    }

    // flomo 式自适应：1 张铺满，2~3 张一行，4 张以上九宫格
    if (imagePaths.length == 1) {
      return _buildSingle(context);
    }
    if (imagePaths.length <= 3) {
      return _buildRow(context);
    }
    return _buildGrid(context);
  }

  Widget _buildSingle(BuildContext context) {
    // 单图铺满宽度、不裁切：按原比例自适应高度
    return LayoutBuilder(
      builder: (context, constraints) {
        final decodeWidth = bucketedDecodeWidth(
          constraints.maxWidth,
          MediaQuery.devicePixelRatioOf(context),
        );

        return ClipRRect(
          borderRadius: BorderRadius.circular(borderRadius),
          child: GestureDetector(
            onTap: () => ImageViewerScreen.open(
              context,
              imagePaths: imagePaths,
            ),
            onLongPress: onLongPress == null
                ? null
                : () => onLongPress!(imagePaths.first),
            child: _buildImage(
              context,
              imagePaths.first,
              decodeWidth,
              fit: BoxFit.contain,
              placeholderHeight: 220,
            ),
          ),
        );
      },
    );
  }

  Widget _buildRow(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final count = imagePaths.length;
        final tileWidth =
            (constraints.maxWidth - spacing * (count - 1)) / count;
        final decodeWidth = gridTileDecodeWidth(
          tileWidth,
          MediaQuery.devicePixelRatioOf(context),
        );

        return Row(
          children: [
            for (var i = 0; i < count; i++) ...[
              if (i > 0) SizedBox(width: spacing),
              Expanded(
                child: AspectRatio(
                  aspectRatio: 1,
                  child: _buildTile(context, imagePaths[i], i, decodeWidth),
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _buildGrid(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = crossAxisCount;
        final tileWidth =
            (constraints.maxWidth - spacing * (columns - 1)) / columns;
        // 按格子实际像素解码（并收敛到固定档位），避免整页原图像素解码把内存顶满；
        // 档位与首页卡片共用，进详情时能直接命中列表已解好的那份缓存
        final decodeWidth = gridTileDecodeWidth(
          tileWidth,
          MediaQuery.devicePixelRatioOf(context),
        );

        // 手动分行：GridView(shrinkWrap) 在 SingleChildScrollView 里会多跑一次
        // 布局，图片一多就明显；这里直接拼 Column/Row，只布局一遍。
        final rows = <Widget>[];
        for (var start = 0; start < imagePaths.length; start += columns) {
          if (start > 0) {
            rows.add(SizedBox(height: spacing));
          }
          final children = <Widget>[];
          for (var offset = 0; offset < columns; offset++) {
            final index = start + offset;
            if (offset > 0) {
              children.add(SizedBox(width: spacing));
            }
            children.add(
              Expanded(
                child: index < imagePaths.length
                    ? AspectRatio(
                        aspectRatio: 1,
                        child: _buildTile(
                          context,
                          imagePaths[index],
                          index,
                          decodeWidth,
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            );
          }
          rows.add(Row(children: children));
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: rows,
        );
      },
    );
  }

  Widget _buildTile(
    BuildContext context,
    String path,
    int index,
    int decodeWidth,
  ) =>
      // 每张图独立成层：解码完成后的淡入、长按水波纹都不会连带整页重绘
      RepaintBoundary(
        child: GestureDetector(
          onTap: () => ImageViewerScreen.open(
            context,
            imagePaths: imagePaths,
            initialIndex: index,
          ),
          onLongPress: onLongPress == null ? null : () => onLongPress!(path),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(borderRadius),
            child: _buildImage(context, path, decodeWidth),
          ),
        ),
      );

  Widget _buildImage(
    BuildContext context,
    String path,
    int decodeWidth, {
    BoxFit fit = BoxFit.cover,
    double placeholderHeight = 0,
  }) {
    // 延后解码期间先用同尺寸占位，避免首帧一次性解码整页大图
    if (!_imagesReady) {
      return _placeholder(context, height: placeholderHeight);
    }

    // 数据维护缓存过的服务端附件：直接读本地副本
    final cachedAttachment = AttachmentCache.instance.fileFor(path);
    if (cachedAttachment != null) {
      return Image.file(
        cachedAttachment,
        fit: fit,
        cacheWidth: decodeWidth,
        gaplessPlayback: true,
        // 缩略图不需要高质量重采样，low 档解码上屏更快
        filterQuality: FilterQuality.low,
        errorBuilder: (context, error, stackTrace) => _broken(context),
      );
    }

    if (path.startsWith('file://')) {
      return Image.file(
        File(path.replaceFirst('file://', '')),
        fit: fit,
        cacheWidth: decodeWidth,
        gaplessPlayback: true,
        filterQuality: FilterQuality.low,
        errorBuilder: (context, error, stackTrace) => _broken(context),
      );
    }

    final appProvider = Provider.of<AppProvider>(context, listen: false);

    if (path.startsWith('http://') || path.startsWith('https://')) {
      return CachedNetworkImage(
        imageUrl: path,
        cacheManager: ImageCacheManager.authImageCache,
        fit: fit,
        memCacheWidth: decodeWidth,
        fadeInDuration: const Duration(milliseconds: 150),
        placeholder: (context, url) =>
            _placeholder(context, height: placeholderHeight),
        errorWidget: (context, url, error) => _broken(context),
      );
    }

    if (MemosResourceService.isServerResourcePath(path)) {
      final service = appProvider.resourceService;
      final baseUrl = serverUrl ??
          appProvider.appConfig.memosApiUrl ??
          appProvider.appConfig.lastServerUrl ??
          '';
      final fullUrl = service != null
          ? service.buildImageUrl(path)
          : (baseUrl.isEmpty ? path : '$baseUrl$path');
      final token = appProvider.user?.token;

      return CachedNetworkImage(
        imageUrl: fullUrl,
        cacheManager: ImageCacheManager.authImageCache,
        httpHeaders: token != null ? {'Authorization': 'Bearer $token'} : null,
        fit: fit,
        memCacheWidth: decodeWidth,
        fadeInDuration: const Duration(milliseconds: 150),
        placeholder: (context, url) =>
            _placeholder(context, height: placeholderHeight),
        errorWidget: (context, url, error) => _broken(context),
      );
    }

    return _broken(context);
  }

  /// 静态占位块（不要放转圈动画）：N 张图同时加载时，N 个逐帧动画会让整页
  /// 每帧重绘，转场和首屏都会明显掉帧。
  Widget _placeholder(BuildContext context, {double height = 0}) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    return Container(
      height: height > 0 ? height : null,
      color: isDarkMode ? Colors.grey[800] : Colors.grey[200],
    );
  }

  Widget _broken(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    return Container(
      color: isDarkMode ? Colors.grey[800] : Colors.grey[200],
      child: Icon(
        Icons.broken_image_outlined,
        size: 22,
        color: Colors.grey[500],
      ),
    );
  }

  /// 详情页内容区宽度估算。
  ///
  /// 详情页里网格的可用宽度 = 卡片上限（桌面 900）减去容器 16×2、内层 16×2
  /// 和 Card 默认 margin 4×2。预取必须按这个宽度算解码尺寸，跟渲染对不上
  /// 就会解出两份缓存，等于白解一次还更慢。
  static double _estimateDetailContentWidth(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final isDesktop = !kIsWeb && (Platform.isMacOS || Platform.isWindows);
    final maxWidth = isDesktop && screenWidth > 900 ? 900.0 : screenWidth;
    final contentWidth = maxWidth - 72;
    return contentWidth < 160 ? 160 : contentWidth;
  }

  /// 点击卡片时预取详情页要显示的图片。
  ///
  /// 把解码（本地大图）和缓存读取（远程图）挤进路由转场的时间里，等详情页
  /// 首帧渲染时 ImageCache 已经有现成的帧。失败静默忽略，真正的加载有
  /// errorBuilder 兜底。
  ///
  /// 只预取首屏能看到的前几张：九张图一起解码会在转场期间跑满解码线程，
  /// 抢 CPU 的结果是转场掉帧、详情首帧反而更晚；其余图片详情页自己按需加载。
  static const int _maxPrecacheCount = 3;

  static void precacheNoteImages(
    BuildContext context,
    List<String> imagePaths, {
    String? serverUrl,
  }) {
    if (imagePaths.isEmpty) {
      return;
    }

    final dpr = MediaQuery.devicePixelRatioOf(context);
    final contentWidth = _estimateDetailContentWidth(context);
    final count = imagePaths.length;

    // 与 _buildSingle / _buildRow / _buildGrid 用同一套宽度规则
    final int decodeWidth;
    if (count == 1) {
      decodeWidth = bucketedDecodeWidth(contentWidth, dpr);
    } else {
      final columns = count <= 3 ? count : 3;
      final tileWidth = (contentWidth - 6.0 * (columns - 1)) / columns;
      decodeWidth = gridTileDecodeWidth(tileWidth, dpr);
    }

    for (final path in imagePaths.take(_maxPrecacheCount)) {
      final provider = _providerFor(
        context,
        path,
        decodeWidth,
        serverUrl: serverUrl,
      );
      if (provider == null) {
        continue;
      }
      unawaited(
        precacheImage(provider, context).catchError((Object _) {
          // 预取失败不影响正常展示
        }),
      );
    }
  }

  /// 构造与网格渲染完全一致的 [ImageProvider]，保证 ImageCache key 命中。
  static ImageProvider? _providerFor(
    BuildContext context,
    String path,
    int decodeWidth, {
    String? serverUrl,
  }) {
    final cachedAttachment = AttachmentCache.instance.fileFor(path);
    if (cachedAttachment != null) {
      return ResizeImage.resizeIfNeeded(
        decodeWidth,
        null,
        FileImage(cachedAttachment),
      );
    }

    if (path.startsWith('file://')) {
      return ResizeImage.resizeIfNeeded(
        decodeWidth,
        null,
        FileImage(File(path.replaceFirst('file://', ''))),
      );
    }

    final appProvider = Provider.of<AppProvider>(context, listen: false);

    if (path.startsWith('http://') || path.startsWith('https://')) {
      return ResizeImage.resizeIfNeeded(
        decodeWidth,
        null,
        CachedNetworkImageProvider(
          path,
          cacheManager: ImageCacheManager.authImageCache,
        ),
      );
    }

    if (MemosResourceService.isServerResourcePath(path)) {
      final service = appProvider.resourceService;
      final baseUrl = serverUrl ??
          appProvider.appConfig.memosApiUrl ??
          appProvider.appConfig.lastServerUrl ??
          '';
      final fullUrl = service != null
          ? service.buildImageUrl(path)
          : (baseUrl.isEmpty ? path : '$baseUrl$path');
      final token = appProvider.user?.token;

      return ResizeImage.resizeIfNeeded(
        decodeWidth,
        null,
        CachedNetworkImageProvider(
          fullUrl,
          cacheManager: ImageCacheManager.authImageCache,
          headers: token != null ? {'Authorization': 'Bearer $token'} : null,
        ),
      );
    }

    return null;
  }
}
