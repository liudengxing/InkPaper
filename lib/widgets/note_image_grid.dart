import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:inkpaper/providers/app_provider.dart';
import 'package:inkpaper/services/memos_resource_service.dart';
import 'package:inkpaper/utils/attachment_cache.dart';
import 'package:inkpaper/utils/image_cache_manager.dart';
import 'package:inkpaper/widgets/image_viewer_screen.dart';
import 'package:provider/provider.dart';

/// 笔记图片九宫格。
///
/// flomo 的做法：图片不再一张张插在正文里，而是统一按 3 列方块排在正文下方，
/// 点开才进全屏查看器。首页卡片和详情页共用同一套视觉。
class NoteImageGrid extends StatelessWidget {
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
  Widget build(BuildContext context) {
    if (imagePaths.isEmpty) {
      return const SizedBox.shrink();
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final tileWidth =
            (constraints.maxWidth - spacing * (crossAxisCount - 1)) /
                crossAxisCount;
        // 按格子实际像素解码，避免整页原图像素解码把内存顶满
        final decodeWidth =
            (tileWidth * MediaQuery.devicePixelRatioOf(context)).round();

        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          itemCount: imagePaths.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            crossAxisSpacing: spacing,
            mainAxisSpacing: spacing,
          ),
          itemBuilder: (context, index) => _buildTile(
            context,
            imagePaths[index],
            index,
            decodeWidth,
          ),
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
      GestureDetector(
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
      );

  Widget _buildImage(BuildContext context, String path, int decodeWidth) {
    // 数据维护缓存过的服务端附件：直接读本地副本
    final cachedAttachment = AttachmentCache.instance.fileFor(path);
    if (cachedAttachment != null) {
      return Image.file(
        cachedAttachment,
        fit: BoxFit.cover,
        cacheWidth: decodeWidth,
        errorBuilder: (context, error, stackTrace) => _broken(context),
      );
    }

    if (path.startsWith('file://')) {
      return Image.file(
        File(path.replaceFirst('file://', '')),
        fit: BoxFit.cover,
        cacheWidth: decodeWidth,
        errorBuilder: (context, error, stackTrace) => _broken(context),
      );
    }

    final appProvider = Provider.of<AppProvider>(context, listen: false);

    if (path.startsWith('http://') || path.startsWith('https://')) {
      return CachedNetworkImage(
        imageUrl: path,
        cacheManager: ImageCacheManager.authImageCache,
        fit: BoxFit.cover,
        memCacheWidth: decodeWidth,
        fadeInDuration: const Duration(milliseconds: 150),
        placeholder: (context, url) => _placeholder(context),
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
        fit: BoxFit.cover,
        memCacheWidth: decodeWidth,
        fadeInDuration: const Duration(milliseconds: 150),
        placeholder: (context, url) => _placeholder(context),
        errorWidget: (context, url, error) => _broken(context),
      );
    }

    return _broken(context);
  }

  Widget _placeholder(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    return Container(
      color: isDarkMode ? Colors.grey[800] : Colors.grey[200],
      child: const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
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
}
