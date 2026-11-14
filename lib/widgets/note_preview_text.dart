import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:inkpaper/utils/note_preview_builder.dart';
import 'package:inkpaper/utils/tag_utils.dart';

/// 列表卡片用的轻量 Markdown 预览。
///
/// 与 `MemosMarkdownRenderer` 的区别：这里不构建任何 Markdown widget 树，
/// 整段正文只产出一个 [Text.rich]。加粗、斜体、行内代码、删除线、链接、
/// 引用、待办勾选框都保留，块级结构被拍平成纯文本。
///
/// 详情页也用这个组件了（样式一致性优先）：传 [onLinkTap] 后外部链接
/// 与站内引用（`ref:` 协议）可点击；[selectable] 开启后用 SelectableText
/// 保留长按选择能力。
class NotePreviewText extends StatefulWidget {
  const NotePreviewText({
    required this.content,
    required this.style,
    this.maxLines,
    this.highlightQuery,
    this.onCheckboxTap,
    this.onTagTap,
    this.onLinkTap,
    this.accentColor,
    this.selectable = false,
    super.key,
  });

  final String content;

  /// 基础文本样式，行高应在这里指定。
  final TextStyle style;

  /// 为空表示不截断（展开状态）。
  final int? maxLines;

  /// 搜索高亮词。
  final String? highlightQuery;

  /// 点击待办勾选框时回调，参数与 `TodoParser.parseTodos` 的索引一致。
  final ValueChanged<int>? onCheckboxTap;

  /// 点击正文里的 `#标签` 时回调，参数是不带 `#` 的标签路径。
  final ValueChanged<String>? onTagTap;

  /// 点击链接时回调，参数是原始 href：外部 URL 或站内引用的 `ref:<id>`。
  final ValueChanged<String>? onLinkTap;

  /// 链接、行内代码的强调色。
  final Color? accentColor;

  /// 用 SelectableText 渲染，保留长按选择/复制能力。
  final bool selectable;

  @override
  State<NotePreviewText> createState() => _NotePreviewTextState();
}

class _NotePreviewTextState extends State<NotePreviewText> {
  final List<TapGestureRecognizer> _recognizers = <TapGestureRecognizer>[];

  NotePreview _preview = NotePreview.empty;
  String? _previewSource;

  @override
  void initState() {
    super.initState();
    _ensurePreview();
  }

  @override
  void didUpdateWidget(NotePreviewText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.content != widget.content) {
      _ensurePreview();
    }
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _ensurePreview() {
    if (_previewSource == widget.content) {
      return;
    }
    _previewSource = widget.content;
    _preview = NotePreviewCache.resolve(widget.content);
  }

  void _disposeRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  @override
  Widget build(BuildContext context) {
    _ensurePreview();

    if (_preview.isEmpty) {
      return const SizedBox.shrink();
    }

    // 每次 build 重建 recognizer：旧 TextSpan 会被新树替换，不会悬挂。
    _disposeRecognizers();

    final accent = widget.accentColor ?? Theme.of(context).colorScheme.primary;
    final spans = _buildSpans(accent, Theme.of(context).brightness);

    if (widget.selectable) {
      // SelectableText 不支持 overflow，选择模式下不做省略号截断
      return SelectableText.rich(
        TextSpan(children: spans),
        maxLines: widget.maxLines,
        style: widget.style,
      );
    }

    return Text.rich(
      TextSpan(children: spans),
      maxLines: widget.maxLines,
      overflow:
          widget.maxLines == null ? TextOverflow.clip : TextOverflow.ellipsis,
      softWrap: true,
      style: widget.style,
    );
  }

  List<InlineSpan> _buildSpans(Color accent, Brightness brightness) {
    final text = _preview.text;
    final query = widget.highlightQuery?.trim() ?? '';
    final highlights = _findHighlightRanges(text, query);
    final tags = _findTagRanges(text);
    final links = _preview.links;

    // 所有需要切断文本的边界：样式区间 + 高亮区间 + 勾选框字符 + 标签
    final cuts = <int>{0, text.length};
    for (final range in _preview.ranges) {
      cuts.add(range.start.clamp(0, text.length));
      cuts.add(range.end.clamp(0, text.length));
    }
    for (final range in highlights) {
      cuts.add(range.$1);
      cuts.add(range.$2);
    }
    for (final range in tags) {
      cuts.add(range.$1);
      cuts.add(range.$2);
    }
    for (final link in links) {
      cuts.add(link.start.clamp(0, text.length));
      cuts.add(link.end.clamp(0, text.length));
    }
    for (final checkbox in _preview.checkboxes) {
      cuts.add(checkbox.offset);
      cuts.add((checkbox.offset + 1).clamp(0, text.length));
    }
    // 段落空行的换行符单独成段，便于给它压缩行高
    for (final offset in _preview.spacerOffsets) {
      cuts.add(offset.clamp(0, text.length));
      cuts.add((offset + 1).clamp(0, text.length));
    }

    final spacerOffsets = _preview.spacerOffsets.toSet();

    final sorted = cuts.toList()..sort();
    final checkboxByOffset = <int, PreviewCheckbox>{
      for (final checkbox in _preview.checkboxes) checkbox.offset: checkbox,
    };

    final spans = <InlineSpan>[];
    for (var i = 0; i < sorted.length - 1; i++) {
      final start = sorted[i];
      final end = sorted[i + 1];
      if (end <= start) {
        continue;
      }

      final styles = <PreviewInlineStyle>{};
      for (final range in _preview.ranges) {
        if (range.start <= start && range.end >= end) {
          styles.addAll(range.styles);
        }
      }

      final isHighlighted = highlights.any(
        (range) => range.$1 <= start && range.$2 >= end,
      );

      // 落在某个 `#标签` 区间内的片段：整段着色 + 可点击跳转
      String? tagPath;
      for (final tag in tags) {
        if (tag.$1 <= start && tag.$2 >= end) {
          tagPath = text.substring(tag.$1, tag.$2).substring(1);
          break;
        }
      }

      // 落在某个链接区间内的片段：可点击（外部 URL / 站内引用 ref:）
      String? linkHref;
      for (final link in links) {
        if (link.start <= start && link.end >= end) {
          linkHref = link.href;
          break;
        }
      }

      final checkbox = checkboxByOffset[start];
      final isCheckboxSegment = checkbox != null && end == start + 1;
      // 段落空行：4px 字号 × 2.0 行高 = 8px，与详情页 blockSpacing 对齐
      final isSpacerLine = spacerOffsets.contains(start) && end == start + 1;

      spans.add(
        TextSpan(
          text: text.substring(start, end),
          style: isSpacerLine
              ? const TextStyle(fontSize: 4, height: 2)
              : _styleFor(
                  styles,
                  accent,
                  brightness,
                  isHighlighted,
                  isTag: tagPath != null,
                ),
          recognizer: isCheckboxSegment && widget.onCheckboxTap != null
              ? _recognizerFor(checkbox.index)
              : (tagPath != null && widget.onTagTap != null)
                  ? _tagRecognizerFor(tagPath)
                  : (linkHref != null && widget.onLinkTap != null)
                      ? _linkRecognizerFor(linkHref)
                      : null,
        ),
      );
    }

    return spans;
  }

  TapGestureRecognizer _recognizerFor(int index) {
    final recognizer = TapGestureRecognizer()
      ..onTap = () => widget.onCheckboxTap?.call(index);
    _recognizers.add(recognizer);
    return recognizer;
  }

  TapGestureRecognizer _tagRecognizerFor(String tagPath) {
    final recognizer = TapGestureRecognizer()
      ..onTap = () => widget.onTagTap?.call(tagPath);
    _recognizers.add(recognizer);
    return recognizer;
  }

  TapGestureRecognizer _linkRecognizerFor(String href) {
    final recognizer = TapGestureRecognizer()
      ..onTap = () => widget.onLinkTap?.call(href);
    _recognizers.add(recognizer);
    return recognizer;
  }

  /// 找出预览文本里所有 `#标签` 的区间（含 `#`），排除 URL 里的 `#`。
  List<(int, int)> _findTagRanges(String text) {
    if (!text.contains('#')) {
      return const <(int, int)>[];
    }
    final hasUrl = text.contains(RegExp('[a-zA-Z]+://'));
    final ranges = <(int, int)>[];
    for (final match in getTagRegex().allMatches(text)) {
      final name = match.group(1);
      if (name == null || name.isEmpty) {
        continue;
      }
      if (hasUrl && isTagInUrl(text, match.start, match.end)) {
        continue;
      }
      ranges.add((match.start, match.end));
    }
    return ranges;
  }

  TextStyle _styleFor(
    Set<PreviewInlineStyle> styles,
    Color accent,
    Brightness brightness,
    bool highlighted, {
    bool isTag = false,
  }) {
    var style = const TextStyle();

    if (styles.contains(PreviewInlineStyle.bold)) {
      style = style.copyWith(fontWeight: FontWeight.w600);
    }
    if (styles.contains(PreviewInlineStyle.italic)) {
      style = style.copyWith(fontStyle: FontStyle.italic);
    }
    if (styles.contains(PreviewInlineStyle.strike)) {
      style = style.copyWith(decoration: TextDecoration.lineThrough);
    }
    if (styles.contains(PreviewInlineStyle.underline)) {
      style = style.copyWith(decoration: TextDecoration.underline);
    }
    if (styles.contains(PreviewInlineStyle.code)) {
      style = style.copyWith(
        fontFamily: 'monospace',
        fontFamilyFallback: const <String>['Roboto Mono', 'Courier'],
        color: accent,
      );
    }
    if (styles.contains(PreviewInlineStyle.link)) {
      style = style.copyWith(
        color: accent,
        decoration: TextDecoration.underline,
        decorationColor: accent.withValues(alpha: 0.5),
      );
    }
    if (styles.contains(PreviewInlineStyle.quote)) {
      style = style.copyWith(
        color: brightness == Brightness.dark
            ? Colors.grey.shade500
            : Colors.grey.shade600,
      );
    }
    if (isTag) {
      // 正文里的 #标签 用强调色 + 稍重的字重，提示"这里可以点"
      style = style.copyWith(
        color: accent,
        fontWeight: FontWeight.w500,
      );
    }
    if (highlighted) {
      style = style.copyWith(
        backgroundColor: const Color(0xFFFFE082).withValues(alpha: 0.65),
      );
    }

    return style;
  }

  /// 大小写不敏感地找出所有高亮区间。
  List<(int, int)> _findHighlightRanges(String text, String query) {
    if (query.isEmpty) {
      return const <(int, int)>[];
    }
    final haystack = text.toLowerCase();
    final needle = query.toLowerCase();
    final ranges = <(int, int)>[];

    var from = 0;
    while (true) {
      final at = haystack.indexOf(needle, from);
      if (at < 0) {
        break;
      }
      ranges.add((at, at + needle.length));
      from = at + needle.length;
      if (ranges.length >= 32) {
        break;
      }
    }
    return ranges;
  }
}
