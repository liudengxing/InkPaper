import 'dart:io';

import 'package:flutter/material.dart';
import 'package:inkpaper/screens/video_player_screen.dart';
import 'package:inkpaper/utils/attachment_cache.dart';
import 'package:inkpaper/utils/thumb_cache.dart';

/// 笔记里的视频卡片：封面（首帧缩略图）+ 播放角标，点开全屏播放。
///
/// 信息流、详情页、编辑器三处共用。封面走 [ThumbCache] 里视频首帧那份
/// 文件，和图片缩略图共用同一套命中逻辑，所以列表滚动时不会现解原视频。
class NoteVideoCard extends StatelessWidget {
  const NoteVideoCard({
    required this.videoPath,
    super.key,
    this.height = 200,
    this.borderRadius = 12,
    this.label,
    this.onRemove,
  });

  final String videoPath;
  final double height;
  final double borderRadius;

  /// 底部左侧的说明文字（编辑器里显示体积或「仅本机」）。
  final String? label;

  /// 传了就显示右上角删除按钮。
  final VoidCallback? onRemove;

  /// 找这段视频的首帧缩略图。本地视频直接查；服务端资源先落到离线副本再查。
  static File? coverFileFor(String path) {
    final plain =
        path.startsWith('file://') ? path.replaceFirst('file://', '') : path;
    final direct = ThumbCache.instance.lookup(plain);
    if (direct != null) {
      return direct;
    }
    final cached = AttachmentCache.instance.pathFor(path);
    if (cached == null) {
      return null;
    }
    return ThumbCache.instance.lookup(cached);
  }

  @override
  Widget build(BuildContext context) {
    final cover = coverFileFor(videoPath);

    return SizedBox(
      height: height,
      width: double.infinity,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (cover != null)
              Image.file(
                cover,
                fit: BoxFit.cover,
                gaplessPlayback: true,
              )
            else
              const ColoredBox(color: Color(0xFF1C1C1E)),
            // 封面还没生成时给个提示，避免用户对着一块黑看
            if (cover == null)
              const Center(
                child: Icon(
                  Icons.videocam_outlined,
                  color: Colors.white24,
                  size: 36,
                ),
              ),
            Center(
              child: Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.46),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.72),
                  ),
                ),
                child: const Icon(
                  Icons.play_arrow_rounded,
                  color: Colors.white,
                  size: 30,
                ),
              ),
            ),
            if (label != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: IgnorePointer(
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(10, 18, 10, 8),
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Color(0xB3000000)],
                      ),
                    ),
                    child: Text(
                      label!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ),
            Positioned.fill(
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () => VideoPlayerScreen.open(
                    context,
                    path: videoPath,
                  ),
                ),
              ),
            ),
            if (onRemove != null)
              Positioned(
                top: 6,
                right: 6,
                child: Material(
                  color: Colors.black.withValues(alpha: 0.52),
                  shape: const CircleBorder(),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: onRemove,
                    child: const SizedBox(
                      width: 30,
                      height: 30,
                      child: Icon(
                        Icons.close_rounded,
                        color: Colors.white,
                        size: 18,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
