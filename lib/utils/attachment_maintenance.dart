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

/// 是否是「服务器上的图」——相对路径（`/file/...`）或指向服务器的绝对 URL。
///
/// 这类引用必须留在正文里：一旦被改写成 `file://...` 本地路径，正文就和
/// 服务端不一致了，下一次同步会把本地路径推回服务器，多端全变裂图。
/// 离线显示靠附件缓存（`AttachmentCache`）解决，而不是改正文。
bool isServerBackedImagePath(String path) {
  if (isRemoteAttachmentPath(path)) {
    return true;
  }
  final lower = path.toLowerCase();
  if (lower.startsWith('http://') || lower.startsWith('https://')) {
    return lower.contains('/file/attachments/') ||
        lower.contains('/api/v1/attachments/') ||
        lower.contains('/file/resource/');
  }
  return false;
}

/// 从 WebDAV 恢复某条图片引用时的处理方式。
enum RestoreAttachmentAction {
  /// 第三方外链：正文原样保留，不下载、不落地。
  skipExternal,

  /// 本服务器附件（`/file/attachments/...` 等）：正文原样保留，只把二进制
  /// 写进附件缓存，离线时由 AttachmentCache 命中。
  cacheServerCopy,

  /// 真正的本地图片：落地成本地文件并把正文改成本地路径。
  materialize,
}

/// 判断某条图片引用在「从 WebDAV 恢复」时该怎么处理。
///
/// 只有 [RestoreAttachmentAction.materialize] 允许改写笔记正文；服务端附件和
/// 外链一律保持原样。否则 A 机备份里的本地路径会被写进 B 机正文，B 机再备份
/// 回去又变成 B 的路径，多设备来回互传后正文互相污染、图片全裂。
RestoreAttachmentAction restoreActionFor(String originalPath) {
  final path = originalPath.trim();
  if (isServerBackedImagePath(path)) {
    return RestoreAttachmentAction.cacheServerCopy;
  }
  if (path.startsWith('http://') || path.startsWith('https://')) {
    return RestoreAttachmentAction.skipExternal;
  }
  return RestoreAttachmentAction.materialize;
}

/// 按恢复结果改写正文里的 Markdown 图片引用。
///
/// 只替换 [restoreActionFor] 判定为 [RestoreAttachmentAction.materialize]
/// 的路径，服务端附件与外链保持原样。
String rewriteMarkdownImagePaths(
  String content,
  Map<String, String> restoredPathMap,
) {
  var result = content;
  restoredPathMap.forEach((originalPath, localPath) {
    if (restoreActionFor(originalPath) != RestoreAttachmentAction.materialize) {
      return;
    }
    result = result.replaceAll(']($originalPath)', ']($localPath)');
  });
  return result;
}

/// 远程附件路径 → 本地文件名。
///
/// 带短哈希，避免不同附件目录下同名文件（Memos 的 `image_<时间戳>.jpg`
/// 很可能重名）被覆盖。
String localFileNameForAttachment(String remotePath) {
  final clean = remotePath.split('?').first.split('#').first;
  final name = clean.split('/').last;
  final parts = _attachmentNameParts(name);
  final digest =
      sha1.convert(utf8.encode(remotePath)).toString().substring(0, 8);
  return 'memos_${parts.$1}_$digest.${parts.$2}';
}

/// 附件文件名 → 可比较的归一化键（抹掉 `memos_` 前缀与短哈希、统一小写扩展名）。
///
/// 缓存文件名 `memos_image_123_ab12cd34.jpg` 与远端引用名 `image_123.jpg`
/// 归一化后都是 `image_123.jpg`，因此能互相匹配；扩展名大小写（`IMAGE_1.JPG`
/// 与 `IMAGE_1.jpg`）也视为同一张图。主干大小写保持敏感，避免 `a.jpg` 与
/// `A.jpg` 在大小写敏感的文件系统上互相顶替。
///
/// 与 [localFileNameForAttachment] 互逆：对任意远端路径 `p`，恒有
/// `canonicalAttachmentKey(localFileNameForAttachment(p)) ==
/// canonicalAttachmentKey(p.split('/').last)`。
String canonicalAttachmentKey(String fileName) {
  var name = fileName;
  final match = RegExp(r'^memos_(.+)_([0-9a-f]{8})\.([A-Za-z0-9]+)$')
      .firstMatch(name);
  if (match != null) {
    name = '${match.group(1)}.${match.group(3)}';
  }
  final parts = _attachmentNameParts(name);
  return '${parts.$1}.${parts.$2}';
}

/// 去掉非法字符的 (文件名主干, 小写扩展名)。
(String, String) _attachmentNameParts(String name) {
  final dot = name.lastIndexOf('.');
  final rawBase = dot > 0 ? name.substring(0, dot) : name;
  final ext =
      dot > 0 && dot < name.length - 1 ? name.substring(dot + 1).toLowerCase() : 'jpg';
  var base = rawBase.replaceAll(RegExp('[^a-zA-Z0-9._-]'), '_');
  if (base.isEmpty) {
    base = 'image';
  }
  return (base, ext);
}

/// 内容寻址的附件文件名：`<sha1>.<ext>`。
///
/// 同一份二进制无论来自 `resourceList` 还是正文 Markdown、附件 uid 怎么变，
/// 算出的名字都相同，因此 WebDAV 上不会存出重复副本；反过来，
/// 远端「同名即同内容」，`exists` 判断就等价于「这份内容已经备份过」。
String contentAddressedAttachmentName(List<int> bytes, String extension) {
  final digest = sha1.convert(bytes).toString();
  var ext = extension
      .replaceAll(RegExp('[^a-zA-Z0-9]'), '')
      .toLowerCase();
  if (ext.isEmpty) {
    ext = 'bin';
  }
  return '$digest.$ext';
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
      // Memos 的「附件」形态：图片挂在 resourceList 上、正文不写 ![]()，
      // 以前这里只认 externalLink，导致这类附件在清理孤儿时被整批误删。
      final name = resource['name']?.toString() ?? '';
      final filename = resource['filename']?.toString() ?? '';
      if (name.isNotEmpty && filename.isNotEmpty) {
        final uid = name.replaceFirst(RegExp('^attachments/'), '');
        if (uid.isNotEmpty) {
          addPath('/file/attachments/$uid/$filename');
        }
      }
    }
  }
  return names;
}
