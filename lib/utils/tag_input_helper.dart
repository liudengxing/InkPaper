/// 编辑器里「#标签」自动补全的纯计算。
///
/// 原先这三段逻辑（从光标反查前缀、候选排序、插入替换）都写在
/// `note_editor.dart` 的 `_detectTagInput` / `_insertTag` 里，跟 Overlay、
/// Provider、TextEditingController 缠在一起，无法单测。这里只留字符串算术，
/// 由 `test/unit/tag_input_helper_test.dart` 覆盖。
library;

/// 光标处正在输入的标签前缀。
///
/// `start` 是 `#` 在文本里的下标，`prefix` 是 `#` 之后到光标之间的内容
/// （可能为空串——用户刚敲完 `#`）。
typedef TagInputContext = ({int start, String prefix});

/// 判断光标是否正处在「#标签」输入状态。
///
/// 规则与常见编辑器一致：从光标往前找最近的 `#`，途中遇到空格或换行就说明
/// 不在标签里；光标在行首同样不算。
TagInputContext? detectTagPrefix({
  required String text,
  required int cursorPosition,
}) {
  if (cursorPosition <= 0 || cursorPosition > text.length) {
    return null;
  }

  var hashIndex = -1;
  for (var i = cursorPosition - 1; i >= 0; i--) {
    final char = text[i];
    if (char == '#') {
      hashIndex = i;
      break;
    }
    if (char == ' ' || char == '\n') {
      break;
    }
  }

  if (hashIndex == -1) {
    return null;
  }

  return (start: hashIndex, prefix: text.substring(hashIndex + 1, cursorPosition));
}

/// 按「完全匹配 → 前缀匹配 → 包含匹配」的优先级排列候选标签。
///
/// 前缀为空时给出前 [limit] 个（调用方传入的应已是排好序的全量标签）。
/// 比较时统一转小写，但返回原样式，避免标签大小写被改写。
List<String> rankTagSuggestions({
  required List<String> allTags,
  required String prefix,
  int limit = 10,
}) {
  if (prefix.isEmpty) {
    return allTags.take(limit).toList();
  }

  final lowerPrefix = prefix.toLowerCase();
  final exactMatches = <String>[];
  final prefixMatches = <String>[];
  final containsMatches = <String>[];

  for (final tag in allTags) {
    final lowerTag = tag.toLowerCase();
    if (lowerTag == lowerPrefix) {
      exactMatches.add(tag);
    } else if (lowerTag.startsWith(lowerPrefix)) {
      prefixMatches.add(tag);
    } else if (lowerTag.contains(lowerPrefix)) {
      containsMatches.add(tag);
    }
  }

  return [
    ...exactMatches,
    ...prefixMatches,
    ...containsMatches,
  ].take(limit).toList();
}

/// 把用户选中的标签写回文本，替换掉从 `#` 到光标的这一段。
///
/// 若 `#` 前面紧邻字母、数字或中文，会补一个空格，否则 `文字#tag` 会被
/// 解析成一个不存在的标签。
({String text, int cursor}) applyTagInsertion({
  required String text,
  required int cursorPosition,
  required int tagStart,
  required String tag,
}) {
  var prefix = '';
  if (tagStart > 0 && tagStart <= text.length) {
    final charBefore = text[tagStart - 1];
    if (RegExp(r'[\w\u4e00-\u9fff]').hasMatch(charBefore)) {
      prefix = ' ';
    }
  }

  final end = cursorPosition.clamp(0, text.length);
  final newText =
      '${text.substring(0, tagStart)}$prefix#$tag ${text.substring(end)}';
  // 光标落在插入内容之后：# + tag + 空格，再加上可能补的那个空格。
  final newCursor = tagStart + prefix.length + tag.length + 2;

  return (text: newText, cursor: newCursor);
}
