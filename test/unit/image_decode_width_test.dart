import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/utils/image_decode_width.dart';

void main() {
  group('bucketedDecodeWidth — 解码宽度分桶', () {
    test('IDW-01 逻辑宽度为 0 时退回最小档', () {
      expect(bucketedDecodeWidth(0, 3), 160);
    });

    test('IDW-02 负数宽度退回最小档', () {
      expect(bucketedDecodeWidth(-100, 3), 160);
    });

    test('IDW-03 NaN 宽度退回最小档', () {
      expect(bucketedDecodeWidth(double.nan, 3), 160);
    });

    test('IDW-04 三列缩略图宽度收敛到 320 档', () {
      // 详情页九宫格约 110dp × 2.5 = 275px
      expect(bucketedDecodeWidth(110, 2.5), 320);
    });

    test('IDW-05 列表卡片与详情九宫格命中同一档位', () {
      final listWidth = bucketedDecodeWidth(112, 2.5);
      final detailWidth = bucketedDecodeWidth(128, 2.5);
      expect(listWidth, detailWidth);
    });

    test('IDW-06 单图铺满宽度不超过 1080', () {
      expect(bucketedDecodeWidth(440, 3), kMaxThumbDecodeWidth);
    });

    test('IDW-07 极小宽度不被截断到 0', () {
      expect(bucketedDecodeWidth(10, 1), 160);
    });

    test('IDW-08 maxWidth 生效', () {
      expect(bucketedDecodeWidth(1000, 3, maxWidth: 720), 720);
    });

    test('IDW-09 结果始终是固定档位之一', () {
      const buckets = <int>{160, 240, 320, 480, 720, 1080};
      for (var width = 1.0; width <= 600; width += 17) {
        expect(buckets.contains(bucketedDecodeWidth(width, 2)), isTrue);
      }
    });
  });

  group('bucketPixelWidth — 已乘过像素密度的分桶', () {
    test('IDW-10 275px 归入 320 档', () {
      expect(bucketPixelWidth(275), 320);
    });

    test('IDW-11 超过上限时按上限返回', () {
      expect(bucketPixelWidth(4000), kMaxThumbDecodeWidth);
    });

    test('IDW-12 与 bucketedDecodeWidth 结果一致', () {
      expect(bucketPixelWidth(275), bucketedDecodeWidth(110, 2.5));
    });

    test('IDW-13 非正数退回最小档', () {
      expect(bucketPixelWidth(0), 160);
      expect(bucketPixelWidth(-5), 160);
    });
  });

  group('gridTileDecodeWidth — 网格缩略图统一档位', () {
    test('IDW-14 首页卡片与编辑器图格命中同一档位', () {
      // 首页卡片每格约 105dp、编辑器图片条约 110dp，dpr 3
      expect(gridTileDecodeWidth(105, 3), kGridTileDecodeWidth);
      expect(gridTileDecodeWidth(110, 3), kGridTileDecodeWidth);
    });

    test('IDW-15 大格子升到 720 档', () {
      expect(gridTileDecodeWidth(300, 3), 720);
    });

    test('IDW-16 宽度非法时退回最小档', () {
      expect(gridTileDecodeWidth(0, 3), 320);
      expect(gridTileDecodeWidth(double.nan, 3), 320);
    });
  });
}
