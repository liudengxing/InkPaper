/// 分享来源包名 → 来源标签（写进正文的 `#xxx`）。
///
/// 原生侧（`MainActivity.resolveShareSource`）把包名归一成下面这几个 key，
/// 认不出来的一律原样传包名，这里查不到就不打标签——宁可少标，也不要给用户
/// 留下一堆 `#com.miui.filemanager` 这种垃圾标签。
const Map<String, String> _shareSourceTags = <String, String>{
  'wechat': '微信',
  'weread': '微信读书',
};

String? sharedPayloadToContent(Object? payload) {
  final content = _sharedPayloadToRawContent(payload);
  if (content == null || content.trim().isEmpty) {
    return null;
  }
  return _tagWithShareSource(content, payload);
}

/// 把载荷里的 `source` 还原成可打标签的中文名，认不出来返回 null。
String? sharedPayloadSourceTag(Object? payload) {
  if (payload is! Map) {
    return null;
  }
  final source = payload['source']?.toString().trim().toLowerCase();
  if (source == null || source.isEmpty) {
    return null;
  }
  return _shareSourceTags[source];
}

String _tagWithShareSource(String content, Object? payload) {
  final tag = sharedPayloadSourceTag(payload);
  if (tag == null) {
    return content;
  }
  // 正文里已经带了同一个标签就不重复加：同一条内容被分享两次时不该叠出
  // `#微信 #微信`。`(?!\S)` 保证 `#微信` 不会误匹配到 `#微信读书`。
  if (RegExp('#$tag(?!\\S)').hasMatch(content)) {
    return content;
  }
  return '#$tag $content';
}

String? _sharedPayloadToRawContent(Object? payload) {
  if (payload is String) {
    return payload;
  }
  if (payload is! Map) {
    return null;
  }

  final type = payload['type']?.toString();
  switch (type) {
    case 'text':
      return payload['content']?.toString();
    case 'image':
      final path = payload['path']?.toString();
      if (path == null || path.isEmpty) {
        return null;
      }
      return '来自分享的图片:\n\n![图片](file://$path)';
    case 'images':
      final paths = (payload['paths'] as List?)
              ?.map((path) => path?.toString() ?? '')
              .where((path) => path.isNotEmpty)
              .toList() ??
          const [];
      if (paths.isEmpty) {
        return null;
      }
      final buffer = StringBuffer('来自分享的图片 (${paths.length}张):\n\n');
      for (final path in paths) {
        buffer.writeln('![图片](file://$path)\n');
      }
      return buffer.toString();
    case 'file':
      final path = payload['path']?.toString();
      if (path == null || path.isEmpty) {
        return null;
      }
      final fileName = path.split('/').last;
      return '分享的文件:\n\n📎 $fileName\n\n路径: $path';
  }
  return null;
}
