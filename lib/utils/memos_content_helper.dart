// ignore_for_file: avoid_classes_with_only_static_members

import 'package:flutter/foundation.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/services/memos_resource_service.dart';
import 'package:inkpaper/utils/media_paths.dart';
import 'package:inkpaper/utils/memos_markdown_converter.dart';
import 'package:markdown/markdown.dart' as md;

abstract final class MemosContentHelper {
  static final RegExp markdownImageRegex = RegExp(r'!\[[^\]]*\]\(([^)]+)\)');

  /// 带 alt 的媒体正则：group(1)=alt、group(2)=路径。
  ///
  /// 上传到服务端后路径会变成没有扩展名的 `/o/r/<uid>`，只看后缀分不出
  /// 图片还是视频，得靠 alt 约定（`![视频](…)`）兜住。
  static final RegExp markdownMediaRegex = RegExp(r'!\[([^\]]*)\]\(([^)]+)\)');

  static List<String> extractMarkdownImagePaths(String content) =>
      markdownMediaRegex
          .allMatches(content)
          .where(
            (match) => !MediaPaths.isVideoMarkdown(
              path: match.group(2) ?? '',
              alt: match.group(1) ?? '',
            ),
          )
          .map((match) => match.group(2) ?? '')
          .where((path) => path.isNotEmpty)
          .toList();

  static List<String> extractMarkdownVideoPaths(String content) =>
      markdownMediaRegex
          .allMatches(content)
          .where(
            (match) => MediaPaths.isVideoMarkdown(
              path: match.group(2) ?? '',
              alt: match.group(1) ?? '',
            ),
          )
          .map((match) => match.group(2) ?? '')
          .where((path) => path.isNotEmpty)
          .toList();

  static String removeMarkdownImages(String content) {
    var result = content;
    for (final match in markdownImageRegex.allMatches(content)) {
      result = result.replaceAll(match.group(0) ?? '', '');
    }
    return result;
  }

  /// 仅测试用：完整 Markdown 解析被调用的次数。
  ///
  /// 小组件挑回顾候选时只需要判断「有没有可见文字」，若实现对全库每条都
  /// 跑一次解析，千条级的库一次构建就是几百毫秒。这里把「只解析抽到的那
  /// 几条」变成可断言的指标，而不是靠耗时。
  @visibleForTesting
  static int debugPreviewParseCount = 0;

  static String previewVisibleText(String content) {
    debugPreviewParseCount++;
    final withoutImages = removeMarkdownImages(content);
    if (withoutImages.trim().isEmpty) {
      return '';
    }

    final converted = MemosMarkdownConverter().convert(
      _normalizeInlineHtmlForPreview(withoutImages),
    );
    final document = md.Document(extensionSet: md.ExtensionSet.gitHubFlavored);
    final nodes = document.parse(converted);

    return nodes
        .map(_visibleTextFromNode)
        .where((text) => text.trim().isNotEmpty)
        .join('\n')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trimRight();
  }

  /// 用已渲染的预览正文判断是否需要展开，尾部标签不计入行数。
  static String previewTextForExpansion(String renderedText) {
    final lines = renderedText.split('\n');

    while (lines.isNotEmpty && lines.last.trim().isEmpty) {
      lines.removeLast();
    }

    while (lines.isNotEmpty && _isTrailingMetadataLine(lines.last)) {
      lines.removeLast();
      while (lines.isNotEmpty && lines.last.trim().isEmpty) {
        lines.removeLast();
      }
    }

    return lines.join('\n').trimRight();
  }

  static String _visibleTextFromNode(md.Node node) {
    if (node is md.Text) {
      return node.text;
    }
    if (node is! md.Element) {
      return node.textContent;
    }

    switch (node.tag) {
      case 'img':
      case 'hr':
        return '';
      case 'br':
        return '\n';
      case 'li':
        return node.children?.map(_visibleTextFromNode).join() ?? '';
      default:
        return node.children?.map(_visibleTextFromNode).join() ??
            node.textContent;
    }
  }

  static bool _isTrailingMetadataLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) {
      return true;
    }

    return trimmed.startsWith('#');
  }

  static String _normalizeInlineHtmlForPreview(String content) =>
      content.replaceAllMapped(
        RegExp(r'<[uU]\b[^>]*>([\s\S]*?)<\/[uU]>'),
        (match) => match.group(1) ?? '',
      );

  static List<String> extractResourceImagePaths(
    List<Map<String, dynamic>> resources,
  ) =>
      _resourcePaths(resources, video: false);

  static List<String> extractResourceVideoPaths(
    List<Map<String, dynamic>> resources,
  ) =>
      _resourcePaths(resources, video: true);

  static List<String> _resourcePaths(
    List<Map<String, dynamic>> resources, {
    required bool video,
  }) {
    final paths = <String>[];

    for (final resource in resources) {
      if (isVideoResource(resource) != video) {
        continue;
      }
      final path = resourcePathOf(resource);
      if (path != null) {
        paths.add(path);
      }
    }

    return paths;
  }

  /// 一条资源在正文与九宫格里该用的路径；拼不出来时返回 null。
  ///
  /// 抽出来是因为 [extractNoteMediaPaths] 要按视频/图片分流但**只遍历一遍**
  /// resourceList，路径拼装规则不能在两处各写一份。
  static String? resourcePathOf(Map<String, dynamic> resource) {
    final externalLink = resource['externalLink']?.toString();
    if (externalLink != null && externalLink.isNotEmpty) {
      return externalLink;
    }

    final name = resource['name']?.toString();
    final filename = resource['filename']?.toString();
    if (name != null && name.startsWith('attachments/')) {
      return filename != null && filename.isNotEmpty
          ? '/file/$name/$filename'
          : name;
    }

    final uid = resource['uid']?.toString() ?? name?.split('/').last;
    if (uid == null || uid.isEmpty) {
      return null;
    }

    return '/o/r/$uid';
  }

  static bool isMemosResourcePath(String path) =>
      MemosResourceService.isServerResourcePath(path);

  static List<String> extractNoteImagePaths(Note note) =>
      extractNoteMediaPaths(note).images;

  /// 笔记里的视频路径：resourceList 里的视频 + 正文里写成视频的 markdown。
  static List<String> extractNoteVideoPaths(Note note) =>
      extractNoteMediaPaths(note).videos;

  /// 仅测试用：正文媒体正则的扫描次数。
  ///
  /// 卡片和详情页都要同时拿到图片与视频，若实现让两边各自扫一遍正文，
  /// 滚动时每次 build 就是两趟正则（长笔记正文几千字）。这条计数把
  /// 「一次扫描」变成可断言的事实，而不是靠耗时观察。
  @visibleForTesting
  static int debugMarkdownMediaScanCount = 0;

  /// 一次扫出图片与视频，顺序与去重口径同原来分开取的两个方法。
  ///
  /// resourceList 只遍历一遍、正文只跑一遍正则；图片与视频各自去重
  /// （同一路径若既是图片资源、又在正文里按视频写法出现，两边都保留，
  /// 这与卡片「图片/视频互斥」的判定无关，是两套独立的分类依据）。
  static NoteMediaPaths extractNoteMediaPaths(Note note) {
    debugMarkdownMediaScanCount++;
    final images = <String>[];
    final videos = <String>[];
    final seenImages = <String>{};
    final seenVideos = <String>{};

    void add(List<String> target, Set<String> seen, String path) {
      if (path.isEmpty || !seen.add(path)) {
        return;
      }
      target.add(path);
    }

    for (final resource in note.resourceList) {
      final path = resourcePathOf(resource);
      if (path == null) {
        continue;
      }
      if (isVideoResource(resource)) {
        add(videos, seenVideos, path);
      } else {
        add(images, seenImages, path);
      }
    }

    for (final match in markdownMediaRegex.allMatches(note.content)) {
      final path = match.group(2) ?? '';
      if (MediaPaths.isVideoMarkdown(
        path: path,
        alt: match.group(1) ?? '',
      )) {
        add(videos, seenVideos, path);
      } else {
        add(images, seenImages, path);
      }
    }

    return NoteMediaPaths(images: images, videos: videos);
  }

  static String contentWithResourceImages(Note note) {
    final imagePaths = extractResourceImagePaths(note.resourceList);
    if (imagePaths.isEmpty) {
      return note.content;
    }

    final existingPaths = extractMarkdownImagePaths(note.content).toSet();
    final missingPaths = imagePaths
        .where((path) => path.isNotEmpty && !existingPaths.contains(path))
        .toList();
    if (missingPaths.isEmpty) {
      return note.content;
    }

    final buffer = StringBuffer(note.content.trimRight());
    if (buffer.isNotEmpty) {
      buffer.write('\n\n');
    }
    for (final path in missingPaths) {
      buffer.writeln('![]($path)');
    }
    return buffer.toString().trimRight();
  }

  /// resourceList 里的一条资源是不是视频。
  ///
  /// 服务端的 `type` 字段（`video/mp4`）最可靠；拿不到时按文件名扩展名判，
  /// 与正文通道共用 [MediaPaths] 那一套，避免两边对 3gp/mkv 的认识不一致。
  static bool isVideoResource(Map<String, dynamic> resource) {
    final type = resource['type'] as String?;
    if (type != null && type.toLowerCase().startsWith('video')) {
      return true;
    }
    final filename = resource['filename']?.toString() ?? '';
    return MediaPaths.isVideoPath(filename);
  }
}

/// 一条笔记的媒体路径，图片与视频各一份。
///
/// 由 [MemosContentHelper.extractNoteMediaPaths] 一次扫描产出：卡片九宫格、
/// 详情页和媒体筛选都要同时知道两者，分两次取等于把正文正则扫两遍。
@immutable
class NoteMediaPaths {
  const NoteMediaPaths({required this.images, required this.videos});

  static const NoteMediaPaths empty = NoteMediaPaths(
    images: <String>[],
    videos: <String>[],
  );

  final List<String> images;
  final List<String> videos;

  bool get isEmpty => images.isEmpty && videos.isEmpty;

  bool get isNotEmpty => !isEmpty;
}
