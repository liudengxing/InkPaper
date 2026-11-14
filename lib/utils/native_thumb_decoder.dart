import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// HEIC/HEIF 缩略图的原生解码通道。
///
/// `package:image` 里没有 HEVC 解码器（`formats.dart` 只注册 jpeg/png/gif/
/// webp/tiff/psd/exr/tga/bmp），所以 HEIC 在 Dart 侧无论怎么调都是 null。
/// Android 从 API 28 起平台自带 HEIF 解码，交给原生 `ImageDecoder` 比在
/// Dart 里硬啃快两个数量级，而且它会自动应用 EXIF 方向、处理色彩空间 ——
/// 自己用 `BitmapFactory` 的话，iPhone 竖拍的照片会横着进缩略图。
///
/// 只能从主 isolate 调用：`compute` 起的后台 isolate 没有 binaryMessenger，
/// MethodChannel 在那边直接不可用。调用方（`ThumbCache.ensure`）本来就在
/// 主 isolate 上跑，天然满足。
const MethodChannel _channel = MethodChannel('com.didichou.inkpaper/thumbnail');

/// 原生解码并压成目标宽度的 JPEG 字节。
///
/// 返回 null 表示这个平台/版本解不了（桌面端、Android 8.1 及以下、文件损坏），
/// 调用方按「没有缩略图」处理并退回原图 —— 与没有这条通道时的行为一致，
/// 所以是纯增量能力，不存在回退风险。
Future<Uint8List?> decodeNativeThumbnail(String path, int width) async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
    return null;
  }
  try {
    return await _channel.invokeMethod<Uint8List>('decodeThumbnail', {
      'path': path,
      'width': width,
    });
  } on MissingPluginException {
    // 宿主还没带上新通道（热重载、旧版安装包），当作不支持。
    return null;
  } on PlatformException catch (e) {
    debugPrint('原生缩略图解码失败 $path: ${e.message}');
    return null;
  }
}
