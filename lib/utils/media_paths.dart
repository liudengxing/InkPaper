// ignore_for_file: avoid_classes_with_only_static_members

/// 笔记媒体的类型判定。
///
/// 图片和视频共用 markdown `![](…)` 这一种写法，区别只在扩展名和 alt 文案。
/// 所有从正文 / resourceList 取媒体的地方都必须过这里分流：一旦把 mp4 当成
/// 图片交给解码器，界面上就是一张裂图，缩略图、预取、清理白名单也会跟着错。
abstract final class MediaPaths {
  /// 视频扩展名。`.3gp` 也收进来 —— 部分安卓机相册默认录这种格式。
  static const Set<String> videoExtensions = <String>{
    '.mp4',
    '.mov',
    '.m4v',
    '.avi',
    '.mkv',
    '.webm',
    '.flv',
    '.3gp',
  };

  /// 上传到 Memos 后正文里写的 alt。服务端资源路径是没有扩展名的
  /// （`/o/r/<uid>`），扩展名判不出来，只能靠这个约定兜住。
  static const String videoAlt = '视频';

  /// 单条笔记只允许一个视频，这是体积上限（Memos 服务端默认 32MB）。
  static const int maxUploadBytes = 32 * 1024 * 1024;

  static bool isVideoPath(String path) {
    final normalized = path.split('?').first.split('#').first.toLowerCase();
    for (final ext in videoExtensions) {
      if (normalized.endsWith(ext)) {
        return true;
      }
    }
    return false;
  }

  /// 正文里的媒体是不是视频：先看 alt 约定，再看扩展名。
  static bool isVideoMarkdown({
    required String path,
    required String alt,
  }) =>
      alt.trim() == videoAlt || isVideoPath(path);

  static List<String> onlyImages(Iterable<String> paths) =>
      paths.where((path) => !isVideoPath(path)).toList();

  static List<String> onlyVideos(Iterable<String> paths) =>
      paths.where(isVideoPath).toList();
}
