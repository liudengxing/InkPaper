import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:inkpaper/l10n/app_localizations_simple.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/providers/app_provider.dart';
import 'package:inkpaper/services/memos_resource_service.dart';
import 'package:inkpaper/themes/app_theme.dart';
import 'package:inkpaper/utils/attachment_cache.dart';
import 'package:inkpaper/utils/image_cache_manager.dart';
import 'package:inkpaper/utils/image_decode_width.dart';
import 'package:inkpaper/utils/memos_content_helper.dart';
import 'package:inkpaper/utils/thumb_cache.dart';
import 'package:provider/provider.dart';

/// 「有图片」画廊：宫格浏览所有带图笔记（参考 flomo 画廊视图）。
///
/// 相册按时间排列，记录的是「拍过什么」；这里的每一张图都连着一条笔记，
/// 记录的是「当时在想什么」——点图直接进笔记详情。
class ImageGalleryScreen extends StatelessWidget {
  const ImageGalleryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final backgroundColor =
        isDarkMode ? AppTheme.darkBackgroundColor : AppTheme.backgroundColor;
    final textColor =
        isDarkMode ? AppTheme.darkTextPrimaryColor : AppTheme.textPrimaryColor;

    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(
        title: Text(
          AppLocalizationsSimple.of(context)?.imageGallery ?? '有图片',
          style: TextStyle(color: textColor, fontSize: 17),
        ),
        centerTitle: true,
        backgroundColor: backgroundColor,
        elevation: 0,
        iconTheme: IconThemeData(color: textColor),
      ),
      body: Consumer<AppProvider>(
        builder: (context, appProvider, _) {
          final tiles = _collectTiles(appProvider.notes);
          if (tiles.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.photo_library_outlined,
                    size: 56,
                    color: isDarkMode ? Colors.grey[600] : Colors.grey[400],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '还没有带图片的笔记',
                    style: TextStyle(
                      fontSize: 14,
                      color: isDarkMode ? Colors.grey[500] : Colors.grey[600],
                    ),
                  ),
                ],
              ),
            );
          }

          return GridView.builder(
            padding: const EdgeInsets.all(2),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisSpacing: 2,
              crossAxisSpacing: 2,
            ),
            itemCount: tiles.length,
            itemBuilder: (context, index) {
              final tile = tiles[index];
              return _GalleryTile(
                key: ValueKey('${tile.note.id}-${tile.imagePath}'),
                noteId: tile.note.id,
                imagePath: tile.imagePath,
                onTap: () => context.push('/note/${tile.note.id}'),
              );
            },
          );
        },
      ),
    );
  }

  /// 收集所有带图笔记的（笔记 × 图片）瓦片，按展示时间倒序。
  ///
  /// 直接解析正文 markdown 提取图片路径（与卡片九宫格同一入口），
  /// 不往数据库加图片索引。
  static List<({Note note, String imagePath})> _collectTiles(
    List<Note> notes,
  ) {
    final sorted = notes.toList()
      ..sort((a, b) => b.displayTime.compareTo(a.displayTime));
    final tiles = <({Note note, String imagePath})>[];
    for (final note in sorted) {
      for (final path in MemosContentHelper.extractNoteImagePaths(note)) {
        tiles.add((note: note, imagePath: path));
      }
    }
    return tiles;
  }
}

/// 单张画廊瓦片：缩略图渲染逻辑与卡片九宫格同源（ThumbCache 两档复用）。
class _GalleryTile extends StatelessWidget {
  const _GalleryTile({
    required this.noteId,
    required this.imagePath,
    required this.onTap,
    super.key,
  });

  final String noteId;
  final String imagePath;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    const decodeWidth = kGridTileDecodeWidth;

    return InkWell(
      onTap: onTap,
      child: _buildImage(context, imagePath, decodeWidth, isDarkMode),
    );
  }

  Widget _buildImage(
    BuildContext context,
    String path,
    int decodeWidth,
    bool isDarkMode,
  ) {
    Widget broken() => Container(
          color: isDarkMode ? Colors.grey[800] : Colors.grey[200],
          child: Icon(
            Icons.broken_image,
            color: isDarkMode ? Colors.grey[600] : Colors.grey[400],
          ),
        );

    Widget placeholder() => Container(
          color: isDarkMode ? Colors.grey[800] : Colors.grey[200],
        );

    // 数据维护里缓存过的服务端附件：直接读本地副本
    final cachedAttachment = AttachmentCache.instance.fileFor(path);
    if (cachedAttachment != null) {
      final thumb = ThumbCache.instance.lookup(
        cachedAttachment.path,
      );
      return Image.file(
        thumb ?? cachedAttachment,
        fit: BoxFit.cover,
        cacheWidth: thumb == null ? decodeWidth : null,
        gaplessPlayback: true,
        filterQuality: FilterQuality.low,
        errorBuilder: (context, error, stackTrace) => broken(),
      );
    }

    if (path.startsWith('file://')) {
      final filePath = path.replaceFirst('file://', '');
      // 未生成缩略图时挂后台补齐，下次进入直接命中
      final thumb = ThumbCache.instance.lookup(filePath);
      if (thumb == null) {
        unawaited(ThumbCache.instance.ensure(filePath));
      }
      return Image.file(
        thumb ?? File(filePath),
        key: ValueKey(thumb?.path ?? filePath),
        fit: BoxFit.cover,
        cacheWidth: thumb == null ? decodeWidth : null,
        gaplessPlayback: true,
        filterQuality: FilterQuality.low,
        errorBuilder: (context, error, stackTrace) => broken(),
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
        placeholder: (context, url) => placeholder(),
        errorWidget: (context, url, error) => broken(),
      );
    }

    if (MemosResourceService.isServerResourcePath(path)) {
      final service = appProvider.resourceService;
      final baseUrl = appProvider.appConfig.memosApiUrl ??
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
        placeholder: (context, url) => placeholder(),
        errorWidget: (context, url, error) => broken(),
      );
    }

    return broken();
  }
}
