// 标签处理工具类
// 提供统一的标签识别和提取逻辑

/// 获取改进的标签正则表达式
///
/// 规则（参考Obsidian/Notion/Logseq）：
/// - 排除URL中的#（不在://之后）
/// - 前缀要求：#前面不能是字母、数字、下划线、冒号、斜杠
/// - 排除连续##（Markdown标题）
/// - 标签内容不包含#
RegExp getTagRegex() => RegExp(
      r'(?<![\w:/])(?!##)#([^\s\[\],，、;；:：！!？?\n#]+)',
      unicode: true,
    );

final _urlRegex = RegExp(r'[a-zA-Z]+://[^\s\)]+');

/// 按原文顺序返回标签区间，正文很长时也只扫描一遍 URL。
Iterable<RegExpMatch> tagMatchesOutsideUrls(String text) sync* {
  if (!text.contains('#')) {
    return;
  }
  final urls = _urlRegex.allMatches(text).iterator;
  var hasUrl = urls.moveNext();
  for (final tag in getTagRegex().allMatches(text)) {
    while (hasUrl && urls.current.end <= tag.start) {
      hasUrl = urls.moveNext();
    }
    if (!hasUrl ||
        tag.start < urls.current.start ||
        tag.end > urls.current.end) {
      yield tag;
    }
  }
}

/// 提取内容中的所有标签（排除URL中的#）
List<String> extractTagsFromContent(String content) => [
      for (final tag in tagMatchesOutsideUrls(content)) tag.group(1)!,
    ];

/// 检查标签是否在URL中
bool isTagInUrl(String line, int tagStart, int tagEnd) {
  final urlMatches = _urlRegex.allMatches(line);

  for (final match in urlMatches) {
    if (tagStart >= match.start && tagEnd <= match.end) {
      return true;
    }
  }

  return false;
}
