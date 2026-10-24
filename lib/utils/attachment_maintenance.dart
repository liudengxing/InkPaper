import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:inkpaper/models/note_model.dart';

/// Markdown 图片引用：`![alt](path)`。
final RegExp _markdownImagePattern = RegExp(r'!\[[^\]]*\]\(([^)]+)\)');

/// App 私有目录下的相对图片前缀（`<documents>/images/xxx.jpg`）。
const String localImagePrefix = 'images/';

/// 提取正文里的全部图片引用路径，去重并保持出现顺序。
List<String> extractImageRefs(String content) {
  final refs = <String>[];
  for (final match in _markdownImagePattern.allMatches(content)) {
    final path = match.group(1)?.trim();
    if (path != null && path.isNotEmpty && !refs.contains(path)) {
      refs.add(path);
    }
  }
  return refs;
}

/// 是否是「需要服务器才能取到」的附件路径。
bool isRemoteAttachmentPath(String path) =>
    path.startsWith('/file/') ||
    path.startsWith('/api/v1/attachments/') ||
    path.startsWith('/api/v1/resource/') ||
    path.startsWith('/o/r/') ||
    path.startsWith('/resource/') ||
    path.startsWith('attachments/');

/// 远程附件路径 → 本地文件名。
///
/// 带短哈希，避免不同附件目录下同名文件（Memos 的 `image_<时间戳>.jpg`
/// 很可能重名）被覆盖。
String localFileNameForAttachment(String remotePath) {
  final clean = remotePath.split('?').first.split('#').first;
  final name = clean.split('/').last;
  final dot = name.lastIndexOf('.');
  final rawBase = dot > 0 ? name.substring(0, dot) : name;
  final ext = dot > 0 && dot < name.length - 1
      ? name.substring(dot + 1).toLowerCase()
      : 'jpg';
  var base = rawBase.replaceAll(RegExp('[^a-zA-Z0-9._-]'), '_');
  if (base.isEmpty) {
    base = 'image';
  }
  final digest =
      sha1.convert(utf8.encode(remotePath)).toString().substring(0, 8);
  return 'memos_${base}_$digest.$ext';
}

/// 笔记正文与资源列表里引用到的本地图片文件名集合。
///
/// 认 `images/x.jpg` 这种相对路径、`file:///.../x.jpg` 绝对路径，以及
/// 服务端附件路径（按 [localFileNameForAttachment] 换算成本地文件名），
/// 清理孤儿附件时这些都算「在用」。
Set<String> referencedLocalImageFiles(Iterable<Note> notes) {
  final names = <String>{};

  void addPath(String? raw) {
    if (raw == null) {
      return;
    }
    final path = raw.trim();
    if (path.isEmpty) {
      return;
    }
    if (isRemoteAttachmentPath(path)) {
      names.add(localFileNameForAttachment(path));
    } else if (path.startsWith(localImagePrefix)) {
      final rest = path.substring(localImagePrefix.length);
      final name = rest.split('/').first;
      if (name.isNotEmpty) {
        names.add(name);
      }
    } else if (path.startsWith('file://')) {
      final segments = Uri.tryParse(path)?.pathSegments ?? const <String>[];
      if (segments.isNotEmpty) {
        names.add(segments.last);
      }
    }
  }

  for (final note in notes) {
    for (final ref in extractImageRefs(note.content)) {
      addPath(ref);
    }
    for (final resource in note.resourceList) {
      addPath(resource['externalLink']?.toString());
    }
  }
  return names;
}
