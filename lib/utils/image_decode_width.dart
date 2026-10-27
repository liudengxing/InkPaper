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
