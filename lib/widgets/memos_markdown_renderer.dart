import 'package:flutter/material.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/utils/memos_content_helper.dart';
import 'package:inkpaper/widgets/simple_memo_content.dart';

enum MemosMarkdownMode {
  cardPreview,
  detail,
  review,
  share,
}

class MemosMarkdownRenderer extends StatelessWidget {
  const MemosMarkdownRenderer({
    required this.content,
    super.key,
    this.serverUrl,
    this.onTagTap,
    this.onLinkTap,
    this.selectable = true,
    this.maxLines,
    this.note,
    this.onCheckboxTap,
    this.mode = MemosMarkdownMode.detail,
    this.highlightQuery,
    this.referenceNotes,
    this.gridImages = false,
    this.imagePaths,
  });

  MemosMarkdownRenderer.fromNote({
    required Note note,
    super.key,
    this.serverUrl,
    this.onTagTap,
    this.onLinkTap,
    this.selectable = true,
    this.maxLines,
    this.onCheckboxTap,
    this.mode = MemosMarkdownMode.detail,
    this.highlightQuery,
    this.referenceNotes,
    this.gridImages = false,
    this.imagePaths,
    bool appendResourceImages = true,
  })  : note = note,
        content = appendResourceImages
            ? MemosContentHelper.contentWithResourceImages(note)
            : note.content;

  final String content;
  final String? serverUrl;
  final Function(String)? onTagTap;
  final Function(String)? onLinkTap;
  final bool selectable;
  final int? maxLines;
  final Note? note;
  final Function(int todoIndex)? onCheckboxTap;
  final MemosMarkdownMode mode;
  final String? highlightQuery;
  final List<Note>? referenceNotes;

  /// 图片以九宫格展示在正文下方（详情页使用）。
  final bool gridImages;

  /// 外部预先算好的图片路径；为空时才内部从 note/content 提取。
  /// 详情页会把结果缓存下来，避免每次重建重跑正则。
  final List<String>? imagePaths;

  @override
  Widget build(BuildContext context) => SimpleMemoContent(
        content: content,
        serverUrl: serverUrl,
        onTagTap: onTagTap,
        onLinkTap: onLinkTap,
        selectable: selectable,
        maxLines: maxLines,
        note: note,
        onCheckboxTap: onCheckboxTap,
        highlightQuery: highlightQuery,
        referenceNotes: referenceNotes,
        compactHeadings: mode == MemosMarkdownMode.cardPreview,
        gridImages: gridImages,
        imagePaths: gridImages
            ? (imagePaths ??
                (note != null
                    ? MemosContentHelper.extractNoteImagePaths(note!)
                    : null))
            : null,
      );
}
