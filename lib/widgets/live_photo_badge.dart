import 'package:flutter/material.dart';
import 'package:inkpaper/utils/live_photo_utils.dart';

/// Live 图（Motion Photo）角标：告诉用户这张「照片」其实会动。
///
/// 只在本地确实存在伴生片段时才展示 —— 服务端图片拿不到旁挂文件，
/// 光看正文是分不出静图和 Live 图的。
///
/// [compact] 给信息流/详情页的小缩略图用：只留图标 + LIVE 字样，
/// 内边距收到 4/2，不压住画面主体。
class LivePhotoBadge extends StatelessWidget {
  const LivePhotoBadge({super.key, this.compact = true});

  final bool compact;

  /// 一张图是否该打这个角标。
  static bool shouldShow(String imagePath) =>
      LivePhotoUtils.hasLiveVideo(imagePath);

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      // 角标是标识不是按钮，点击要穿透给下面的图片（点开查看器）
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 5 : 8,
          vertical: compact ? 2 : 4,
        ),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(compact ? 6 : 20),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.22),
            width: 0.8,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.motion_photos_on_rounded,
              size: compact ? 10 : 13,
              color: Colors.white,
            ),
            SizedBox(width: compact ? 2 : 4),
            Text(
              'LIVE',
              style: TextStyle(
                color: Colors.white,
                fontSize: compact ? 8 : 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
                height: 1.1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
