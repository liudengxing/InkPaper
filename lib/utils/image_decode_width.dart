import 'dart:math' as math;

/// 缩略图解码宽度分桶。
///
/// 列表与详情页对同一张图的显示宽度并不相同，如果各自按实际像素宽度解码，
/// `ImageCache` 会认为是两个不同的 key，于是每次进出详情都要把同一张图再解
/// 一遍。这里把宽度收敛到固定档位，跨页面、跨布局都能命中同一份缓存。
///
/// 档位按常见移动端像素密度取值，向上取整；超出上限时按上限解码，缩略图
/// 不需要无限大。
const List<int> _widthBuckets = <int>[160, 240, 320, 480, 720, 1080];

/// 默认上限：1080 宽足以覆盖手机全宽显示，再大只是白烧内存。
const int kMaxThumbDecodeWidth = 1080;

/// 把「逻辑宽度 × 像素密度」收敛成缓存友好的解码宽度。
///
/// [logicalWidth] 是控件在屏幕上的逻辑宽度（dp），[devicePixelRatio] 一般取
/// `MediaQuery.devicePixelRatioOf(context)`。
int bucketedDecodeWidth(
  double logicalWidth,
  double devicePixelRatio, {
  int minWidth = 160,
  int maxWidth = kMaxThumbDecodeWidth,
}) {
  final raw = logicalWidth * devicePixelRatio;
  if (!raw.isFinite || raw <= 0) {
    return minWidth;
  }
  return bucketPixelWidth(
    raw.round(),
    minWidth: minWidth,
    maxWidth: maxWidth,
  );
}

/// 网格缩略图的统一解码宽度档位（[gridTileDecodeWidth] 的常规输出）。
///
/// 编辑器里的图片条/九宫格直接引用这个常量，别另写一个数字：两边一旦不同，
/// `ImageCache` 会认为是两张图，从列表进入编辑器时同一批图要重新解码一遍
/// （1.1.86 实测：5 张图的笔记首次双击进编辑页卡 1 秒，缓存条目 +5）。
const int kGridTileDecodeWidth = 480;

/// 网格缩略图（一行 2~3 张、九宫格）的统一解码宽度。
///
/// 列表卡片每格约 105~110dp、详情页九宫格约 100~110dp，若按精确像素分桶会分别
/// 落到 320 / 480 这两个相邻档位，`ImageCache` 认为它们是两张不同的图，于是每次
/// 进出详情都要把同一批图重新解码一遍。这里把网格缩略图收敛到 480 / 720 两个粗档，
/// 让列表与详情共用同一份解码结果。
int gridTileDecodeWidth(
  double logicalWidth,
  double devicePixelRatio, {
  int minWidth = 320,
  int maxWidth = 720,
}) {
  final raw = logicalWidth * devicePixelRatio;
  if (!raw.isFinite || raw <= 0) {
    return minWidth;
  }
  return (raw <= kGridTileDecodeWidth ? kGridTileDecodeWidth : 720).clamp(
    minWidth,
    maxWidth,
  );
}

/// 直接对已有的像素宽度做分桶（调用方已乘过像素密度时使用）。
int bucketPixelWidth(
  int pixelWidth, {
  int minWidth = 160,
  int maxWidth = kMaxThumbDecodeWidth,
}) {
  if (pixelWidth <= 0) {
    return minWidth;
  }
  for (final bucket in _widthBuckets) {
    if (pixelWidth <= bucket) {
      return bucket.clamp(minWidth, maxWidth);
    }
  }
  return math.max(minWidth, maxWidth);
}
