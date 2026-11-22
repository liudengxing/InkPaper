import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:inkpaper/utils/note_preview_builder.dart';
import 'package:inkpaper/utils/tag_utils.dart';

/// 列表卡片用的轻量 Markdown 预览。
///
/// 与 `MemosMarkdownRenderer` 的区别：这里不构建任何 Markdown widget 树，
/// 卡片预览只产出一个 [Text.rich]。加粗、斜体、行内代码、删除线、链接、
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
    this.compactBlankLines = true,
    this.parseLimit = defaultPreviewParseLimit,
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

  /// 段落之间的空行是否压缩成 8px 的紧凑行高。
  ///
  /// 卡片预览要紧凑，默认 true；详情页必须传 false——编辑页是一个普通
  /// TextField，空行占满一行行高（bodyLarge 15 × 1.6 = 24px），详情页
  /// 若压到 8px，同一条笔记在浏览态比编辑态紧一截，点进编辑像被重新
  /// 排版了一次。
  final bool compactBlankLines;

  /// 解析前的字符上限。
  ///
  /// 默认只按卡片预览的长度解析；详情页要显示全文，必须传
  /// `content.length`（否则长笔记在正文中间被无声截断，而编辑页是全文，
  /// 两处看到的内容不一样）。
  final int parseLimit;

  @override
  State<NotePreviewText> createState() => _NotePreviewTextState();
}

class _NotePreviewTextState extends State<NotePreviewText> {
  static const _backgroundParseThreshold = 12000;
  static const _paragraphSpanLimit = 256;

  final List<TapGestureRecognizer> _recognizers = <TapGestureRecognizer>[];

  NotePreview _preview = NotePreview.empty;
  Future<NotePreview>? _pendingPreview;
  String? _previewSource;
  int? _previewLimit;

  @override
  void initState() {
    super.initState();
    _ensurePreview();
  }

  @override
  void didUpdateWidget(NotePreviewText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.content != widget.content ||
        oldWidget.parseLimit != widget.parseLimit) {
      _ensurePreview();
    }
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _ensurePreview() {
    if (_previewSource == widget.content &&
        _previewLimit == widget.parseLimit) {
      return;
    }
    _previewSource = widget.content;
    _previewLimit = widget.parseLimit;
    if (widget.content.length >= _backgroundParseThreshold &&
        widget.parseLimit >= _backgroundParseThreshold) {
      _preview = NotePreview.empty;
      _pendingPreview = NotePreviewCache.resolveAsync(
        widget.content,
        parseLimit: widget.parseLimit,
      );
      return;
    }
    _pendingPreview = null;
    _preview = NotePreviewCache.resolve(
      widget.content,
      parseLimit: widget.parseLimit,
    );
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
    if (_pendingPreview case final pending?) {
      return FutureBuilder<NotePreview>(
        future: pending,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const SizedBox(
              height: 20,
              width: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            );
          }
          if (snapshot.hasError) {
            return Text(widget.content, style: widget.style);
          }
          return _renderPreview(context, snapshot.requireData);
        },
      );
    }
    return _renderPreview(context, _preview);
  }

  Widget _renderPreview(BuildContext context, NotePreview preview) {
    if (preview.isEmpty) {
      return const SizedBox.shrink();
    }

    // 每次 build 重建 recognizer：旧 TextSpan 会被新树替换，不会悬挂。
    _disposeRecognizers();

    final accent = widget.accentColor ?? Theme.of(context).colorScheme.primary;
    final spans = _buildSpans(preview, accent, Theme.of(context).brightness);

    if (widget.selectable) {
      // SelectableText 不支持 overflow，选择模式下不做省略号截断
      return SelectableText.rich(
        TextSpan(children: spans),
        maxLines: widget.maxLines,
        style: widget.style,
      );
    }

    if (!widget.compactBlankLines &&
        widget.maxLines == null &&
        spans.length > _paragraphSpanLimit) {
      return LayoutBuilder(
        builder: (context, constraints) {
          if (!constraints.hasBoundedWidth || constraints.maxWidth == 0) {
            return _richText(spans);
          }
          final paragraphs =
              _splitAtWrappedLines(spans, context, constraints.maxWidth);
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final paragraph in paragraphs) _richText(paragraph),
            ],
          );
        },
      );
    }

    return _richText(spans);
  }

  Widget _richText(List<TextSpan> spans) => Text.rich(
        TextSpan(children: spans),
        maxLines: widget.maxLines,
        overflow:
            widget.maxLines == null ? TextOverflow.clip : TextOverflow.ellipsis,
        softWrap: true,
        style: widget.style,
      );

  // 控制单个 Flutter 文本段落的样式片段数。在实际换行位置切分，
  // 即使是一整段没有显式换行的长文，也能保留原来的折行位置。
  List<List<TextSpan>> _splitAtWrappedLines(
    List<TextSpan> spans,
    BuildContext context,
    double width,
  ) {
    final defaults = DefaultTextStyle.of(context);
    var style = defaults.style.merge(widget.style);
    if (MediaQuery.boldTextOf(context)) {
      style = style.merge(const TextStyle(fontWeight: FontWeight.bold));
    }
    final painter = TextPainter(
      textAlign: defaults.textAlign ?? TextAlign.start,
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      textHeightBehavior: defaults.textHeightBehavior,
      locale: Localizations.maybeLocaleOf(context),
    );
    final paragraphs = <List<TextSpan>>[];
    var first = 0;
    var offset = 0;
    try {
      while (first < spans.length) {
        final limit = math.min(first + _paragraphSpanLimit, spans.length);
        final batch = spans.sublist(first, limit);
        if (offset > 0) {
          batch[0] = _sliceSpan(batch[0], offset, batch[0].text!.length);
        }
        if (limit == spans.length) {
          paragraphs.add(batch);
          break;
        }
        painter.text = TextSpan(style: style, children: batch);
        painter.layout(maxWidth: width);
        final length = batch.fold(0, (sum, span) => sum + span.text!.length);
        var split =
            painter.getLineBoundary(TextPosition(offset: length - 1)).start;
        if (split <= 0) {
          return [spans];
        }

        var count = 0;
        while (split >= batch[count].text!.length) {
          split -= batch[count].text!.length;
          count++;
        }
        final paragraph = batch.sublist(0, count);
        if (split > 0) {
          paragraph.add(_sliceSpan(batch[count], 0, split));
        }
        // 下个段落自行换行，末尾的显式换行在这里消耗一次。
        final tail = paragraph.last;
        if (tail.text!.endsWith('\n')) {
          paragraph[paragraph.length - 1] =
              _sliceSpan(tail, 0, tail.text!.length - 1);
        }
        paragraphs.add(paragraph);
        offset = count == 0 ? offset + split : split;
        first += count;
      }
      return paragraphs;
    } finally {
      painter.dispose();
    }
  }

  TextSpan _sliceSpan(TextSpan span, int start, int end) => TextSpan(
        text: span.text!.substring(start, end),
        style: span.style,
        recognizer: span.recognizer,
      );

  List<TextSpan> _buildSpans(
    NotePreview preview,
    Color accent,
    Brightness brightness,
  ) {
    final text = preview.text;
    final query = widget.highlightQuery?.trim() ?? '';
    final highlights = _findHighlightRanges(text, query);
    final tags = _findTagRanges(text);
    final links = preview.links;
    final ranges = preview.ranges;

    // 所有需要切断文本的边界：样式区间 + 高亮区间 + 勾选框字符 + 标签
    final cuts = <int>{0, text.length};
    for (final range in ranges) {
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
    for (final checkbox in preview.checkboxes) {
      cuts.add(checkbox.offset);
      cuts.add((checkbox.offset + 1).clamp(0, text.length));
    }
    // 段落空行的换行符单独成段，便于给它压缩行高
    for (final offset in preview.spacerOffsets) {
      cuts.add(offset.clamp(0, text.length));
      cuts.add((offset + 1).clamp(0, text.length));
    }

    final spacerOffsets = preview.spacerOffsets.toSet();

    final sorted = cuts.toList()..sort();
    final checkboxByOffset = <int, PreviewCheckbox>{
      for (final checkbox in preview.checkboxes) checkbox.offset: checkbox,
    };

    // 解析器和正则都按正文顺序产出互不重叠的区间。随着切点推进，每个区间只经过一次。
    var styleIndex = 0;
    var highlightIndex = 0;
    var tagIndex = 0;
    var linkIndex = 0;
    final spans = <TextSpan>[];
    for (var i = 0; i < sorted.length - 1; i++) {
      final start = sorted[i];
      final end = sorted[i + 1];
      if (end <= start) {
        continue;
      }

      while (styleIndex < ranges.length && ranges[styleIndex].end <= start) {
        styleIndex++;
      }
      final styles = styleIndex < ranges.length &&
              ranges[styleIndex].start <= start &&
              ranges[styleIndex].end >= end
          ? ranges[styleIndex].styles
          : const <PreviewInlineStyle>{};

      while (highlightIndex < highlights.length &&
          highlights[highlightIndex].$2 <= start) {
        highlightIndex++;
      }
      final isHighlighted = highlightIndex < highlights.length &&
          highlights[highlightIndex].$1 <= start &&
          highlights[highlightIndex].$2 >= end;

      // 落在某个 `#标签` 区间内的片段：整段着色 + 可点击跳转
      while (tagIndex < tags.length && tags[tagIndex].$2 <= start) {
        tagIndex++;
      }
      final tag = tagIndex < tags.length ? tags[tagIndex] : null;
      final tagPath = tag != null && tag.$1 <= start && tag.$2 >= end
          ? text.substring(tag.$1 + 1, tag.$2)
          : null;

      // 落在某个链接区间内的片段：可点击（外部 URL / 站内引用 ref:）
      while (linkIndex < links.length && links[linkIndex].end <= start) {
        linkIndex++;
      }
      final link = linkIndex < links.length ? links[linkIndex] : null;
      final linkHref = link != null && link.start <= start && link.end >= end
          ? link.href
          : null;

      final checkbox = checkboxByOffset[start];
      final isCheckboxSegment = checkbox != null && end == start + 1;
      // 段落空行：卡片里 4px 字号 × 2.0 行高 = 8px，让列表更紧凑；
      // 详情页不压缩，交给父样式，空行高度与编辑页输入框一致。
      final isSpacerLine = spacerOffsets.contains(start) && end == start + 1;

      final TextStyle? spanStyle;
      if (isSpacerLine) {
        spanStyle = widget.compactBlankLines
            ? const TextStyle(fontSize: 4, height: 2)
            : null;
      } else {
        spanStyle = _styleFor(
          styles,
          accent,
          brightness,
          isHighlighted,
          isTag: tagPath != null,
        );
      }

      spans.add(
        TextSpan(
          text: text.substring(start, end),
          style: spanStyle,
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
  List<(int, int)> _findTagRanges(String text) => [
        for (final tag in tagMatchesOutsideUrls(text)) (tag.start, tag.end),
      ];

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
