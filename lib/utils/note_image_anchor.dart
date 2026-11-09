/// 编辑器里「图片锚点」的纯计算。
///
/// 编辑区显示的是**去掉图片 markdown 之后**的纯文本，图片以卡片形式插在
/// 视觉位置 [NoteImageAnchor.offset] 处；提交时要把两者拼回一份完整
/// markdown，样式区间也要跟着平移。
///
/// 这套偏移换算原先埋在 `note_editor.dart` 的 `State` 里（`_rangesWithImages`
/// / `_shiftRangeSegment` / `_insertedLengthBefore*` / `_syncImageAnchorsForTextChange`），
/// 逻辑全是纯算术却一行测试都没有——因为 State 里没法测。抽出来以后由
/// `test/unit/note_image_anchor_test.dart` 覆盖。
library;

/// 一张图片在纯文本里的锚点。
class NoteImageAnchor {
  const NoteImageAnchor({
    required this.offset,
    required this.markdown,
    required this.order,
  });

  /// 在「用户看到的文本」里的字符偏移。
  final int offset;

  /// 渲染时插回该位置的那段 markdown，例如 `![](path)`。
  final String markdown;

  /// 图片在列表中的原始顺序，用于同偏移时的稳定排序。
  final int order;

  /// 插入这张图会让它之后的字符右移多少。
  int get insertedLength => markdown.length;
}

/// 两次文本之间的最小差异区间。
///
/// `[start, oldEnd)` 是旧文本里被替换掉的部分，`[start, newEnd)` 是新文本里
/// 替换后的部分。两者的差值就是长度变化。
class TextDiff {
  const TextDiff({
    required this.start,
    required this.oldEnd,
    required this.newEnd,
  });

  final int start;
  final int oldEnd;
  final int newEnd;

  /// 把旧文本里的偏移换算到新文本。
  ///
  /// 差异区间之前的字符原位不动；之后的整体平移长度差；
  /// 落在被替换区间中间的，收到新区间的末尾。
  int transformOffset(int offset) {
    if (offset <= start) {
      return offset;
    }
    if (offset >= oldEnd) {
      return offset + (newEnd - oldEnd);
    }
    return newEnd;
  }

  /// 取公共前后缀，剩下的就是差异区间。
  static TextDiff from(String oldText, String newText) {
    var start = 0;
    while (start < oldText.length &&
        start < newText.length &&
        oldText[start] == newText[start]) {
      start++;
    }

    var oldEnd = oldText.length;
    var newEnd = newText.length;
    while (oldEnd > start &&
        newEnd > start &&
        oldText[oldEnd - 1] == newText[newEnd - 1]) {
      oldEnd--;
      newEnd--;
    }

    return TextDiff(start: start, oldEnd: oldEnd, newEnd: newEnd);
  }
}

/// 文本变更后平移所有图片锚点。`null` 项代表该图已被移除，原样保留。
///
/// 文本没变时直接返回原列表，避免无谓地复制。
List<int?> shiftImageOffsets({
  required List<int?> offsets,
  required String previousText,
  required String currentText,
}) {
  if (currentText == previousText || offsets.isEmpty) {
    return offsets;
  }

  final diff = TextDiff.from(previousText, currentText);
  return [
    for (final offset in offsets)
      if (offset == null) null else diff.transformOffset(offset),
  ];
}

/// 把一个样式区间按落在其中的图片切成若干段，并给出每段在**最终 markdown**
/// 里的位置。
///
/// 为什么要切：图片的 markdown 在视觉文本里不占字符，区间若横跨一张图，
/// 直接平移到最终文本会把图片也套上样式（比如整段加粗把 `![]()` 也包进去）。
/// 所以要在图片位置断开，图片本身不受样式影响。
///
/// 返回的是纯索引，调用方自己套回 `MemoStyleRange` 之类的类型。
List<({int start, int end})> splitRangeByImages({
  required int rangeStart,
  required int rangeEnd,
  required List<NoteImageAnchor> images,
}) {
  if (images.isEmpty) {
    return [(start: rangeStart, end: rangeEnd)];
  }
  // 空区间不产出任何段（与原实现一致）。
  if (rangeEnd <= rangeStart) {
    return const [];
  }

  final innerImages = images
      .where((image) => image.offset > rangeStart && image.offset < rangeEnd)
      .toList()
    ..sort((a, b) => a.offset.compareTo(b.offset));

  final segments = <({int start, int end})>[];
  var segmentStart = rangeStart;

  for (final image in innerImages) {
    if (segmentStart < image.offset) {
      segments.add(
        _shiftSegment(
          start: segmentStart,
          end: image.offset,
          images: images,
        ),
      );
    }
    segmentStart = image.offset;
  }

  if (segmentStart < rangeEnd) {
    segments
        .add(_shiftSegment(start: segmentStart, end: rangeEnd, images: images));
  }
  return segments;
}

({int start, int end}) _shiftSegment({
  required int start,
  required int end,
  required List<NoteImageAnchor> images,
}) =>
    (
      start: start + _insertedLengthBeforeOrAt(start, images),
      end: end + _insertedLengthBefore(end, images),
    );

/// 偏移 [offset] 之前（不含）有多少 markdown 被插入。
int _insertedLengthBefore(int offset, List<NoteImageAnchor> images) {
  var inserted = 0;
  for (final image in images) {
    if (image.offset < offset) {
      inserted += image.insertedLength;
    }
  }
  return inserted;
}

/// 偏移 [offset] 之前或正好在这个位置（含）有多少 markdown 被插入。
///
/// 段首用「含」，是为了让紧贴图片后面开始的那一段把图片长度算进去；
/// 段尾用「不含」，避免区间末尾的图片被算两次。
int _insertedLengthBeforeOrAt(int offset, List<NoteImageAnchor> images) {
  var inserted = 0;
  for (final image in images) {
    if (image.offset <= offset) {
      inserted += image.insertedLength;
    }
  }
  return inserted;
}
