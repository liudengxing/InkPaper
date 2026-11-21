import 'package:flutter/material.dart';
import 'package:inkpaper/utils/note_timestamp_format.dart';
import 'package:inkpaper/widgets/note_image_grid.dart';

/// 点洞察正文里的 `[12]` 时弹出的「这一条是哪条笔记」。
///
/// flomo 的点开是当场验证，不是跳转：用户要在这半屏里读完原文，再决定这
/// 句判断站不站得住。所以这里只读不跳，正文可选中复制。
///
/// [text] 为 null 表示原笔记已经被删掉了——历史回看里很常见（报告存下来了，
/// 笔记没了），这时候要明说，不能让用户以为是加载失败。
Future<void> showInsightSourceSheet(
  BuildContext context, {
  required int index,
  required DateTime time,
  List<String> tags = const <String>[],
  String? text,
  bool truncated = false,
  List<String> imagePaths = const <String>[],
  String? serverUrl,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) {
      final theme = Theme.of(sheetContext);
      final colorScheme = theme.colorScheme;
      final muted = colorScheme.onSurfaceVariant;
      final content = text?.trim() ?? '';
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(sheetContext).size.height * 0.68,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Text(
                      '第 $index 条',
                      style: theme.textTheme.labelLarge?.copyWith(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: colorScheme.primary.withValues(alpha: 0.9),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      formatNoteTimestamp(time),
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: 11.5,
                        color: muted.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ),
                if (tags.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      for (final tag in tags.take(6))
                        Text(
                          '#$tag',
                          style: theme.textTheme.labelSmall?.copyWith(
                            fontSize: 11.5,
                            color: muted.withValues(alpha: 0.85),
                          ),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 14),
                if (content.isEmpty)
                  Text(
                    '这条原笔记已经不在了，只剩洞察报告里的这段引用。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 13,
                      height: 1.7,
                      color: muted.withValues(alpha: 0.8),
                    ),
                  )
                else ...[
                  SelectableText(
                    content,
                    style: (theme.textTheme.bodyMedium ?? const TextStyle())
                        .copyWith(
                      fontSize: 14.5,
                      height: 1.8,
                      color: colorScheme.onSurface.withValues(alpha: 0.92),
                    ),
                  ),
                  if (truncated) ...[
                    const SizedBox(height: 12),
                    Text(
                      '原文更长，这里只是当时喂给模型的那一段。',
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: 11,
                        color: muted.withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ],
                // 图片不喂给模型，但读原文时它在场：一条带照片的记录
                // 和一条纯文字，分量完全不同。
                if (imagePaths.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  NoteImageGrid(
                    imagePaths: imagePaths,
                    serverUrl: serverUrl,
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    },
  );
}
