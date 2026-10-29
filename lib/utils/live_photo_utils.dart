import 'dart:io';
import 'dart:typed_data';

/// 从 Motion Photo（动图 / Live 图）里解析出来的动态片段。
class MotionPhotoData {
  const MotionPhotoData({
    required this.videoBytes,
    required this.imageLength,
    this.presentationTimestampUs,
  });

  /// 内嵌的 MP4 数据。
  final Uint8List videoBytes;

  /// 去掉动态片段后的静态图长度（用于只保存静态图，减小体积）。
  final int imageLength;

  final int? presentationTimestampUs;
}

/// Live 图（安卓的 Motion Photo / 动态照片）解析工具。
///
/// 各家实现的差异很大，这里只覆盖最常见的两种：
/// 1. Google 经典格式：JPEG 尾部追加 MP4，XMP 里用 `GCamera:MicroVideoOffset`
///    记录视频相对文件末尾的字节数；
/// 2. 新版 `Container` 格式：XMP 里用 `Container:Item` + `Item:Length` 描述，
///    但没有可靠的偏移量，退化成"从文件尾部向前找 ftyp box"。
///
/// 解析失败一律返回 null（按普通静态图处理），不影响正常保存。
class LivePhotoUtils {
  LivePhotoUtils._();

  /// 保存在图片旁边的动态片段后缀：`image_123.jpg` → `image_123.mp4`。
  static const String videoSuffix = 'live';

  /// 一张图片对应的动图文件路径（约定式，无需改数据模型）。
  static String videoPathFor(String imagePath) {
    final normalized = imagePath.replaceFirst('file://', '');
    final dot = normalized.lastIndexOf('.');
    final separator = normalized.lastIndexOf(RegExp(r'[/\\]'));
    if (dot <= separator) {
      return '$normalized.$videoSuffix.mp4';
    }
    return '${normalized.substring(0, dot)}.$videoSuffix.mp4';
  }

  /// 判断某个图片是否有配套的动图片段。
  static bool hasLiveVideo(String imagePath) {
    if (!imagePath.startsWith('file://')) {
      return false;
    }
    try {
      return File(videoPathFor(imagePath)).existsSync();
    } on Object {
      return false;
    }
  }

  /// 从 JPEG 字节里提取动态片段；不是动态照片时返回 null。
  static MotionPhotoData? extractMotionPhoto(Uint8List bytes) {
    if (bytes.length < 4096 || !_isJpeg(bytes)) {
      return null;
    }

    final headerLength = bytes.length < 262144 ? bytes.length : 262144;
    final header = _latin1(bytes, 0, headerLength);

    // 先按 XMP 里的经典偏移量切
    final offset = _matchInt(header, RegExp(r'MicroVideoOffset="(\d+)"'));
    final timestamp = _matchInt(
      header,
      RegExp(r'MicroVideoPresentationTimestampUs="(\d+)"'),
    );

    if (offset != null) {
      final start = bytes.length - offset;
      final data = _sliceVideo(bytes, start, timestamp);
      if (data != null) {
        return data;
      }
    }

    // 新版 Container 格式（无 MicroVideoOffset）：从尾部找 ftyp box
    if (header.contains('MotionPhoto') || header.contains('Container:Item')) {
      final start = _findLastFtyp(bytes);
      if (start != null) {
        return _sliceVideo(bytes, start, timestamp);
      }
    }

    return null;
  }

  static MotionPhotoData? _sliceVideo(
    Uint8List bytes,
    int start,
    int? timestamp,
  ) {
    if (start <= 0 || start >= bytes.length) {
      return null;
    }
    // MP4 的第一个 box 是 `ftyp`：前 4 字节是 box size
    if (start + 8 > bytes.length) {
      return null;
    }
    if (_latin1(bytes, start + 4, start + 8) != 'ftyp') {
      return null;
    }
    final videoLength = bytes.length - start;
    // 几百字节的"视频"没有意义，基本是解析错了
    if (videoLength < 4096) {
      return null;
    }
    return MotionPhotoData(
      videoBytes: Uint8List.sublistView(bytes, start),
      imageLength: start,
      presentationTimestampUs: timestamp,
    );
  }

  /// 从文件尾部向前搜索 `ftyp`，返回 box 起点（size 字段所在位置）。
  static int? _findLastFtyp(Uint8List bytes) {
    final searchStart = bytes.length > 1048576 ? bytes.length - 1048576 : 0;
    for (var i = bytes.length - 8; i >= searchStart; i--) {
      if (bytes[i] == 0x66 &&
          bytes[i + 1] == 0x74 &&
          bytes[i + 2] == 0x79 &&
          bytes[i + 3] == 0x70) {
        final start = i - 4;
        if (start > 0) {
          return start;
        }
      }
    }
    return null;
  }

  static int? _matchInt(String text, RegExp pattern) {
    final match = pattern.firstMatch(text);
    if (match == null) {
      return null;
    }
    return int.tryParse(match.group(1) ?? '');
  }

  static bool _isJpeg(Uint8List bytes) =>
      bytes.length > 2 && bytes[0] == 0xFF && bytes[1] == 0xD8;

  /// Latin-1 视图：JPEG 头里都是 ASCII，直接按字节读比 utf8 更安全。
  static String _latin1(Uint8List bytes, int start, int end) {
    final safeStart = start.clamp(0, bytes.length);
    final safeEnd = end.clamp(safeStart, bytes.length);
    return String.fromCharCodes(bytes, safeStart, safeEnd);
  }
}
