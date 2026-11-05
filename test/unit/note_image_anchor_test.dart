// ============================================================
// L2 测试 · NoteImageAnchor（utils/note_image_anchor.dart）
//
// 这套偏移换算原先埋在 note_editor.dart 的 State 里，一行测试都没有。
// 抽成纯函数后在这里把边界情况钉住，改编辑器排版逻辑时才有回归网。
// ============================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/utils/note_image_anchor.dart';

/// markdown 长度 7：`![x](p)`
const String _md = '![x](p)';

void main() {
  group('TextDiff.from + transformOffset', () {
    test('IA-01 文本没变时任何偏移都不动', () {
      final diff = TextDiff.from('hello', 'hello');
      expect(diff.transformOffset(0), 0);
      expect(diff.transformOffset(3), 3);
      expect(diff.transformOffset(5), 5);
    });

    test('IA-02 在中间插入：之前的偏移不动，之后的整体右移', () {
      // "abc" → "abXYc"，在 index 2 插入 2 个字符
      final diff = TextDiff.from('abc', 'abXYc');
      expect(diff.start, 2);
      expect(diff.transformOffset(1), 1);
      expect(diff.transformOffset(2), 2);
      // 原 index 3（'c'）在新文本里是 index 5
      expect(diff.transformOffset(3), 5);
    });

    test('IA-03 删除：之后的偏移整体左移', () {
      // "abcdef" → "abef"，删掉 index 2..4
      final diff = TextDiff.from('abcdef', 'abef');
      expect(diff.transformOffset(4), 2);
      expect(diff.transformOffset(6), 4);
    });

    test('IA-04 落在被替换区间内部的偏移，收到新区间末尾', () {
      // "abcde" → "aXYe"：区间 [1,4) 被 [1,3) 替换
      final diff = TextDiff.from('abcde', 'aXYe');
      expect(diff.start, 1);
      expect(diff.oldEnd, 4);
      expect(diff.newEnd, 3);
      // 区间中间（2、3）都被收到 3
      expect(diff.transformOffset(2), 3);
      expect(diff.transformOffset(3), 3);
    });
  });

  group('shiftImageOffsets', () {
    test('IA-05 文本没变时返回同一实例，避免无谓复制', () {
      final offsets = <int?>[1, 2];
      final result = shiftImageOffsets(
        offsets: offsets,
        previousText: 'abc',
        currentText: 'abc',
      );
      expect(identical(result, offsets), isTrue);
    });

    test('IA-06 null 项（已移除的图）原样保留', () {
      final result = shiftImageOffsets(
        offsets: <int?>[1, null, 3],
        previousText: 'abc',
        currentText: 'abXc',
      );
      expect(result[1], isNull);
      // 在 index 2 插入一个字符，原 3 变成 4
      expect(result[2], 4);
    });

    test('IA-07 在锚点之前插入文本，锚点右移', () {
      final result = shiftImageOffsets(
        offsets: <int?>[4],
        previousText: 'abcdef',
        currentText: 'abcXdef',
      );
      expect(result[0], 5);
    });

    test('IA-08 在锚点之后插入文本，锚点不动', () {
      final result = shiftImageOffsets(
        offsets: <int?>[1],
        previousText: 'abcdef',
        currentText: 'abcdefX',
      );
      expect(result[0], 1);
    });

    test('IA-09 空列表直接返回', () {
      final result = shiftImageOffsets(
        offsets: const <int?>[],
        previousText: 'abc',
        currentText: 'abcdef',
      );
      expect(result, isEmpty);
    });
  });

  group('splitRangeByImages', () {
    const anchorAt2 = NoteImageAnchor(offset: 2, markdown: _md, order: 0);

    test('IA-10 没有图片时不切段，原样返回', () {
      final segments = splitRangeByImages(
        rangeStart: 1,
        rangeEnd: 4,
        images: const [],
      );
      expect(segments, hasLength(1));
      expect(segments.single.start, 1);
      expect(segments.single.end, 4);
    });

    test('IA-11 空区间不产出任何段', () {
      final segments = splitRangeByImages(
        rangeStart: 3,
        rangeEnd: 3,
        images: const [anchorAt2],
      );
      expect(segments, isEmpty);
    });

    test('IA-12 区间整体在图片之前，不平移', () {
      // "ABCD"，图在 2；区间 [0,2) 不含图片
      final segments = splitRangeByImages(
        rangeStart: 0,
        rangeEnd: 2,
        images: const [anchorAt2],
      );
      expect(segments, hasLength(1));
      expect(segments.single.start, 0);
      expect(segments.single.end, 2);
    });

    test('IA-13 区间整体在图片之后，整体右移 markdown 长度', () {
      final segments = splitRangeByImages(
        rangeStart: 3,
        rangeEnd: 4,
        images: const [anchorAt2],
      );
      expect(segments, hasLength(1));
      expect(segments.single.start, 3 + _md.length);
      expect(segments.single.end, 4 + _md.length);
    });

    test('IA-14 区间横跨图片时断成两段，图片本身不被样式覆盖', () {
      // 文本 "ABCD"，图插在 2 → 最终 "AB![x](p)CD"
      final segments = splitRangeByImages(
        rangeStart: 0,
        rangeEnd: 4,
        images: const [anchorAt2],
      );
      expect(segments, hasLength(2));

      // 前半段："AB"
      expect(segments[0].start, 0);
      expect(segments[0].end, 2);
      // 后半段："CD" 落在 9..11
      expect(segments[1].start, 2 + _md.length);
      expect(segments[1].end, 4 + _md.length);

      // 关键断言：图片 markdown 占据的 [2, 9) 没有被任何段覆盖
      for (final segment in segments) {
        final overlapsImage =
            segment.start < 2 + _md.length && segment.end > 2;
        expect(overlapsImage, isFalse, reason: '样式区间不能覆盖图片 markdown');
      }
    });

    test('IA-15 图片正好在区间起点或终点时不切开（开区间判断）', () {
      // 图在 2，区间 [2,4)：图片不在 (2,4) 内部 → 一段，且段首把图片长度算进去
      final segments = splitRangeByImages(
        rangeStart: 2,
        rangeEnd: 4,
        images: const [anchorAt2],
      );
      expect(segments, hasLength(1));
      expect(segments.single.start, 2 + _md.length);
      expect(segments.single.end, 4 + _md.length);
    });

    test('IA-16 多张图按偏移递增切段', () {
      const images = [
        NoteImageAnchor(offset: 2, markdown: '![]()', order: 1),
        NoteImageAnchor(offset: 5, markdown: '![]()', order: 0),
      ];
      // 区间 [0,8)，两张图都在内部 → 3 段
      final segments = splitRangeByImages(
        rangeStart: 0,
        rangeEnd: 8,
        images: images,
      );
      expect(segments, hasLength(3));
      // 段首递增
      expect(segments[0].start, lessThan(segments[1].start));
      expect(segments[1].start, lessThan(segments[2].start));
    });

    test('IA-17 乱序传入的图片会先按偏移排序', () {
      const images = [
        NoteImageAnchor(offset: 5, markdown: '![]()', order: 0),
        NoteImageAnchor(offset: 2, markdown: '![]()', order: 1),
      ];
      final segments = splitRangeByImages(
        rangeStart: 0,
        rangeEnd: 8,
        images: images,
      );
      expect(segments, hasLength(3));
      expect(segments[0].end, 2);
    });
  });
}
