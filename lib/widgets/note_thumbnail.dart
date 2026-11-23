import 'dart:io';

import 'package:flutter/material.dart';
import 'package:inkpaper/utils/attachment_cache.dart';
import 'package:inkpaper/utils/thumb_cache.dart';

/// 卡片、详情和编辑器统一选择本机原图与磁盘缩略图。
class NoteThumbnail extends StatefulWidget {
  const NoteThumbnail({
    required this.source,
    required this.width,
    required this.placeholder,
    required this.errorBuilder,
    this.fit = BoxFit.cover,
    this.cachedThumbnail,
    super.key,
  });

  final File source;
  final int width;
  final Widget placeholder;
  final ImageErrorWidgetBuilder errorBuilder;
  final BoxFit fit;
  final File? cachedThumbnail;

  static File? localSource(String path) => path.startsWith('file://')
      ? File(path.substring('file://'.length))
      : AttachmentCache.instance.fileFor(path);

  static File? peek(File? source, int width) => source == null
      ? null
      : ThumbCache.instance.lookup(
          source.path,
          width: width,
          generateOnMiss: false,
        );

  @override
  State<NoteThumbnail> createState() => _NoteThumbnailState();
}

class _NoteThumbnailState extends State<NoteThumbnail> {
  File? _cached;
  Future<File?>? _loading;

  @override
  void initState() {
    super.initState();
    _selectSource();
  }

  @override
  void didUpdateWidget(covariant NoteThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.source.path != oldWidget.source.path ||
        widget.width != oldWidget.width ||
        widget.cachedThumbnail?.path != oldWidget.cachedThumbnail?.path) {
      _selectSource();
    }
  }

  void _selectSource() {
    _cached = widget.cachedThumbnail ??
        NoteThumbnail.peek(widget.source, widget.width);
    final cache = ThumbCache.instance;
    _loading = _cached == null && cache.isReady
        ? cache.ensure(widget.source.path, width: widget.width)
        : null;
  }

  Widget _image(File? thumbnail) => Image.file(
        thumbnail ?? widget.source,
        key: ValueKey((thumbnail ?? widget.source).path),
        cacheWidth: thumbnail == null ? widget.width : null,
        fit: widget.fit,
        gaplessPlayback: true,
        filterQuality: FilterQuality.low,
        errorBuilder: thumbnail == null
            ? widget.errorBuilder
            : (context, error, stackTrace) => _image(null),
      );

  @override
  Widget build(BuildContext context) {
    final loading = _loading;
    if (loading == null) {
      return _image(_cached);
    }
    return FutureBuilder<File?>(
      future: loading,
      builder: (context, snapshot) =>
          snapshot.connectionState == ConnectionState.done
              ? _image(snapshot.data)
              : widget.placeholder,
    );
  }
}
