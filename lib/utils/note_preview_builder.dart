import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:inkpaper/utils/memos_markdown_converter.dart';
import 'package:markdown/markdown.dart' as md;

/// 卡片预览支持的轻量行内样式。
///
/// 只保留 6 行缩略预览里肉眼可辨识的部分：加粗、斜体、等宽、删除线、
/// 链接、引用。块级结构（多级列表缩进、表格边框、代码高亮）在预览里
/// 没有可读性价值，一律拍平。
enum PreviewInlineStyle { bold, italic, code, strike, link, quote, underline }

/// 一段连续文本上叠加的样式区间，半开区间 [start, end)。
class PreviewRange {
  const PreviewRange(this.start, this.end, this.styles);

  final int start;
  final int end;
  final Set<PreviewInlineStyle> styles;
}

/// 正文里出现的一个待办勾选框，用于把点击绑回笔记的原始行。
class PreviewCheckbox {
  const PreviewCheckbox({
    required this.index,
    required this.offset,
    required this.checked,
  });

  /// 在笔记里的出现顺序，与 `TodoParser.parseTodos` 的索引一致。
  final int index;

  /// 勾选字符在 [NotePreview.text] 中的位置。
  final int offset;

  final bool checked;
}

/// 预览文本里的一处链接，半开区间 [start, end)。
///
/// [href] 可能是外部 URL，也可能是站内引用的 `ref:<encodedId>`
/// （预处理阶段已把 `[[id]]` 转成 markdown 链接，见 [_prepare]）。
class PreviewLink {
  const PreviewLink(this.start, this.end, this.href);

  final int start;
  final int end;
  final String href;
}

/// Markdown 降维后的预览文档：一段纯文本 + 若干样式区间。
///
/// 渲染侧只需要一个 `Text.rich`，不需要构建 widget 树。
class NotePreview {
  const NotePreview({
    required this.text,
    required this.ranges,
    required this.checkboxes,
    this.links = const <PreviewLink>[],
    this.spacerOffsets = const <int>[],
  });

  static const NotePreview empty = NotePreview(
    text: '',
    ranges: <PreviewRange>[],
    checkboxes: <PreviewCheckbox>[],
  );

  final String text;
  final List<PreviewRange> ranges;
  final List<PreviewCheckbox> checkboxes;

  /// 链接区间（外部 URL 与站内引用 `ref:`）。
  final List<PreviewLink> links;

  /// 段落空行里第二个换行符的位置。
  ///
  /// 卡片只用一个 `Text.rich`，渲染侧给这些换行符单独设置更小的行高，
  /// 让段落间距贴近详情页 `MarkdownBody` 的 blockSpacing。
  final List<int> spacerOffsets;

  bool get isEmpty => text.trim().isEmpty;
}

/// 解析前的字符上限默认值。列表卡片最多展开几行，一两百字就够，
/// 2400 是给「展开卡片」留的余量。
///
/// 详情页要显示全文，必须显式传更大的值（`NotePreviewText.parseLimit`），
/// 否则长笔记会在正文中间被无声截断。
const int defaultPreviewParseLimit = 2400;

// 正则与 InlineSyntax 都是「编译一次、反复使用」的东西，放在函数里等于每次
// 缓存未命中都重新编译一遍模式。
final RegExp _todoPattern = RegExp(
  r'^([ \t]*[-*+][ \t]+)\[([ xX])\][ \t]?',
  multiLine: true,
);
final RegExp _imagePattern = RegExp(r'!\[[^\]]*\]\([^)]*\)');
final RegExp _fencePattern = RegExp(r'^[ \t]*```[^\n]*$', multiLine: true);
final RegExp _referencePattern = RegExp(r'\[\[([^\]]+)\]\]');
final RegExp _referenceTextPattern = RegExp(r'\?text=([^&]*)');
final RegExp _markdownEscapePattern = RegExp(r'[*_\[\]]');
final RegExp _leadingSpacePattern = RegExp(r'^[ \t]+');
final RegExp _whitespaceRunPattern = RegExp(r'\s+');
final md.InlineSyntax _underlineSyntax = _UnderlineSyntax();

/// 把一条笔记的原始 Markdown 降维成 [NotePreview]。
///
/// 纯计算、无 IO，可以安全地在 isolate 里批量预跑。
NotePreview buildNotePreview(
  String content, {
  int parseLimit = defaultPreviewParseLimit,
}) {
  if (content.isEmpty) {
    return NotePreview.empty;
  }

  // 紧贴正文的减号串会被解析成 setext 标题下划线，预览里表现为整段变粗。
  // 和详情页用同一套降级规则，避免同一条笔记两处观感不一致。
  final source = MemosMarkdownConverter.demoteSetextHeadingUnderlines(
    _safePrefix(content, parseLimit),
  );

  final nodes = md.Document(
    extensionSet: md.ExtensionSet.gitHubFlavored,
    blockSyntaxes: [_SourceOrderedListSyntax()],
    inlineSyntaxes: <md.InlineSyntax>[_underlineSyntax],
    encodeHtml: false,
  ).parse(_prepare(source));

  final walker = _PreviewWalker()..walkBlocks(nodes);
  return NotePreview(
    text: walker.text,
    ranges: walker.ranges,
    checkboxes: walker.checkboxes,
    links: walker.links,
    spacerOffsets: walker.spacerOffsets,
  );
}

const _sourceListMarker = 'data-inkpaper-marker';

/// Markdown 的 AST 只记录有序列表的起始数字。解析后从本块已消费的
/// 原文行补齐每一项的标记，保留 Markdown 原本的分组和层级。
class _SourceOrderedListSyntax extends md.OrderedListWithCheckboxSyntax {
  final _lineIndexes = Expando<Map<md.Line, int>>();

  @override
  bool canParse(md.BlockParser parser) =>
      pattern.firstMatch(parser.current.content)?[1] != null;

  @override
  md.Node parse(md.BlockParser parser) {
    final lines = parser.lines;
    final indexes = _lineIndexes[parser] ??= {
      for (var i = 0; i < lines.length; i++) lines[i]: i,
    };
    final start = indexes[parser.current]!;
    final list = super.parse(parser) as md.Element;
    final end = parser.isDone ? lines.length : indexes[parser.current]!;
    final markers = <String>[];
    var itemIndent = 0;
    for (var i = start; i < end; i++) {
      final line = lines[i];
      final match = pattern.firstMatch(line.content);
      final digits = match?[1];
      if (digits == null) {
        continue;
      }
      final leading = line.content.indexOf(digits);
      final tabRemainder = line.tabRemaining ?? 0;
      if (i != start && leading + tabRemainder >= itemIndent) {
        continue;
      }

      final markerEnd = leading + digits.length + 1;
      markers.add(line.content.substring(leading, markerEnd));
      final contentLength = match![2]?.length ?? 0;
      final spacing = line.content.length - markerEnd - contentLength;
      // 与 ListSyntax 使用同一缩进口径。超出四空格的内缩是项目内容。
      itemIndent = markerEnd + 1;
      if (contentLength > 0 && spacing <= 4) {
        itemIndent += spacing - 1 + tabRemainder;
      }
    }
    final items = list.children!.whereType<md.Element>().toList();
    if (items.length == markers.length) {
      for (var i = 0; i < items.length; i++) {
        items[i].attributes[_sourceListMarker] = markers[i];
      }
    }
    return list;
  }
}

/// `<u>下划线</u>` 的轻量解析，与详情页 `UnderlineSyntax` 行为保持一致。
class _UnderlineSyntax extends md.InlineSyntax {
  _UnderlineSyntax()
      : super(r'<[uU]\b[^>]*>([\s\S]*?)</[uU]>', startCharacter: 60);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element.text('u', match.group(1) ?? ''));
    return true;
  }
}

/// 按 UTF-16 长度截断，但不切断代理对（emoji 等）。
String _safePrefix(String value, int limit) =>
    value.substring(0, _safePrefixLength(value, limit));

/// 截断长度，避免把代理对（emoji 等）切成半个字符。
int _safePrefixLength(String value, int limit) {
  if (value.length <= limit) {
    return value.length;
  }
  var end = limit;
  final code = value.codeUnitAt(end - 1);
  if (code >= 0xD800 && code <= 0xDBFF) {
    end -= 1;
  }
  return end;
}

/// 解析前的字符级预处理：抽掉图片、把待办标记换成勾选字符。
///
/// 图片由卡片单独用网格渲染，正文里再留一份 `![]()` 只会变成噪声；
/// 待办用字符而非 `WidgetSpan`，避免打断文本布局。
String _prepare(String source) {
  var text = source;

  // 待办列表标记 -> 勾选字符
  text = text.replaceAllMapped(
    _todoPattern,
    (match) =>
        '${match.group(1)}${match.group(2)!.toLowerCase() == 'x' ? '☑' : '☐'} ',
  );

  // 图片整段移除（卡片会用独立网格展示）
  text = text.replaceAll(_imagePattern, '');

  // 围栏标记行去掉，保留内部文本
  text = text.replaceAll(_fencePattern, '');

  // 站内引用 [[id]] / [[id?text=xxx]]：预览不查标题表（那是 O(n) 查找，
  // 详情页仍会解析成真实标题），只保留自定义文字或一个可读占位。
  // 转成 `ref:` 协议的 markdown 链接，与详情页 SimpleMemoContent 同一约定，
  // 解析后进 walker 的链接区间，渲染侧才知道哪里可以点。
  text = text.replaceAllMapped(_referencePattern, (match) {
    final raw = match.group(1)!;
    final custom = _referenceTextPattern.firstMatch(raw);
    if (custom != null) {
      var decoded = custom.group(1)!;
      if (decoded.contains('%')) {
        try {
          decoded = Uri.decodeComponent(decoded);
        } on Object {
          // 非法百分号编码，按原文展示
        }
      }
      final cleaned = decoded.replaceAll(_markdownEscapePattern, '').trim();
      if (cleaned.isNotEmpty) {
        return _referenceMarkdownLink(raw, cleaned);
      }
    }
    return _referenceMarkdownLink(raw, '↗ 引用笔记');
  });

  return text;
}

/// 把一条站内引用转成 `ref:` 协议的 markdown 链接。
String _referenceMarkdownLink(String rawReference, String label) {
  final id = rawReference.split('?').first.trim();
  final encodedId = Uri.encodeComponent(id);
  return '[$label](ref:$encodedId "note")';
}

class _PreviewWalker {
  final StringBuffer _buffer = StringBuffer();
  final List<PreviewRange> _ranges = <PreviewRange>[];
  final List<PreviewCheckbox> _checkboxes = <PreviewCheckbox>[];
  final List<PreviewLink> _links = <PreviewLink>[];
  final List<int> _spacerOffsets = <int>[];

  int _length = 0;
  String _tail = '';
  int _checkboxIndex = 0;
  bool _pendingBreak = false;
  bool _pendingGap = false;

  String get text => _buffer.toString();

  List<PreviewRange> get ranges => _ranges;

  List<PreviewCheckbox> get checkboxes => _checkboxes;

  List<PreviewLink> get links => _links;

  List<int> get spacerOffsets => _spacerOffsets;

  void walkBlocks(List<md.Node> nodes) {
    for (final node in nodes) {
      _walk(node, const <PreviewInlineStyle>{});
    }
  }

  void _walk(md.Node node, Set<PreviewInlineStyle> styles) {
    if (node is md.Text) {
      _append(node.text, styles);
      return;
    }

    if (node is! md.Element) {
      return;
    }

    final children = node.children;

    switch (node.tag) {
      case 'p':
      case 'div':
        _gap();
        _walkChildren(children, styles);
        _gap();
      case 'br':
        _writeRaw('\n', styles);
      case 'h1':
      case 'h2':
      case 'h3':
      case 'h4':
      case 'h5':
      case 'h6':
        // 预览里标题只加粗、不改字号：混字号会让行高不一致，视觉更差。
        _gap();
        _walkChildren(children, _plus(styles, PreviewInlineStyle.bold));
        _gap();
      case 'blockquote':
        _gap();
        _walkChildren(children, _plus(styles, PreviewInlineStyle.quote));
        _gap();
      case 'strong':
        _walkChildren(children, _plus(styles, PreviewInlineStyle.bold));
      case 'em':
        _walkChildren(children, _plus(styles, PreviewInlineStyle.italic));
      case 'del':
        _walkChildren(children, _plus(styles, PreviewInlineStyle.strike));
      case 'u':
        _walkChildren(children, _plus(styles, PreviewInlineStyle.underline));
      case 'a':
        // 链接：记录区间供渲染侧绑定点击；站内引用也是 'a'（href=ref:...）
        {
          final linkStart = _length;
          _walkChildren(children, _plus(styles, PreviewInlineStyle.link));
          final linkEnd = _length;
          final href = node.attributes['href'];
          if (href != null &&
              href.isNotEmpty &&
              linkEnd > linkStart &&
              linkEnd <= _length) {
            _links.add(PreviewLink(linkStart, linkEnd, href));
          }
        }
      case 'code':
        // 行内代码：等宽 + 主色文字，不加底色盒子（底色会盖住行距）。
        _walkChildren(children, _plus(styles, PreviewInlineStyle.code));
      case 'pre':
        _gap();
        _walkCodeBlock(node, styles);
        _gap();
      case 'ul':
      case 'ol':
        _walkList(node, styles, 0);
        _gap();
      case 'li':
        // 正常路径由 _walkList 展开；这里兜底处理游离的 li。
        _break();
        _walkChildren(children, styles);
        _break();
      case 'hr':
        _gap();
        _append('—', styles);
        _gap();
      case 'img':
        // 已在预处理阶段移除，兜底跳过。
        break;
      case 'table':
        _gap();
        _walkTable(node, styles);
        _gap();
      case 'thead':
      case 'tbody':
      case 'tfoot':
      case 'tr':
        _walkChildren(children, styles);
      case 'td':
      case 'th':
        _walkChildren(children, styles);
        _append('  ', styles);
      default:
        _walkChildren(children, styles);
    }
  }

  void _walkChildren(List<md.Node>? children, Set<PreviewInlineStyle> styles) {
    if (children == null) {
      return;
    }
    for (final child in children) {
      _walk(child, styles);
    }
  }

  void _walkCodeBlock(md.Element node, Set<PreviewInlineStyle> styles) {
    final raw = node.textContent.replaceAll(_whitespaceRunPattern, ' ').trim();
    if (raw.isEmpty) {
      return;
    }
    final snippet = raw.length > 90 ? '${_safePrefix(raw, 90)}…' : raw;
    _append(snippet, _plus(styles, PreviewInlineStyle.code));
  }

  void _walkTable(md.Element node, Set<PreviewInlineStyle> styles) {
    final rows = <String>[];
    for (final row in node.children ?? const <md.Node>[]) {
      if (row is! md.Element) {
        continue;
      }
      final cells = <String>[];
      for (final cell in row.children ?? const <md.Node>[]) {
        final value = cell is md.Element ? cell.textContent.trim() : '';
        if (value.isNotEmpty) {
          cells.add(value);
        }
      }
      if (cells.isNotEmpty) {
        rows.add(cells.join(' | '));
      }
    }
    if (rows.isEmpty) {
      return;
    }
    _append(rows.take(2).join('  '), styles);
  }

  /// 展开一层列表。`depth` 只影响行首缩进，嵌套列表靠它对齐编辑页的原文。
  ///
  /// 符号必须补：编辑页里就是 `- 项` / `1. 项`，详情页若只换行不写符号，
  /// 多行列表会糊成一段散句，和编辑页看到的完全是两回事。
  void _walkList(md.Element node, Set<PreviewInlineStyle> styles, int depth) {
    final ordered = node.tag == 'ol';
    final start =
        ordered ? int.tryParse(node.attributes['start'] ?? '') ?? 1 : 1;
    final indent = '  ' * depth;
    var index = start;

    for (final child in node.children ?? const <md.Node>[]) {
      if (child is! md.Element || child.tag != 'li') {
        continue;
      }
      _break();
      // 待办项本身就有勾选框，再补一个 `-` 会变成「- ☐ 任务」
      final isTodo = child.textContent.trimLeft().startsWith('☐') ||
          child.textContent.trimLeft().startsWith('☑');
      final marker = ordered
          ? '${child.attributes[_sourceListMarker] ?? '$index.'} '
          : (isTodo ? '' : '- ');
      if (marker.isEmpty) {
        _flushPendingBreak();
        if (indent.isNotEmpty) {
          _writeRaw(indent, const <PreviewInlineStyle>{});
        }
      } else {
        _append(marker, const <PreviewInlineStyle>{}, indent: indent);
      }
      index++;
      _walkListItem(child.children, styles, depth);
      _break();
    }
  }

  /// 列表项内部：段落不再制造块间距（否则每项之间都会空一行），
  /// 嵌套列表按层级继续展开。
  void _walkListItem(
    List<md.Node>? children,
    Set<PreviewInlineStyle> styles,
    int depth,
  ) {
    var paragraphs = 0;
    for (final child in children ?? const <md.Node>[]) {
      if (child is! md.Element) {
        _walk(child, styles);
        continue;
      }
      switch (child.tag) {
        case 'p':
        case 'div':
          // 项内第二段起换个行：不分段会粘成一整句
          if (paragraphs > 0) {
            _break();
          }
          paragraphs++;
          _walkChildren(child.children, styles);
        case 'ul':
        case 'ol':
          _walkList(child, styles, depth + 1);
        default:
          _walk(child, styles);
      }
    }
  }

  /// 需要换行但不额外留白的边界（例如列表项之间）。
  ///
  /// 迟到写入：只有后面真的还有内容时才落一个换行，避免预览尾部挂着空行。
  void _break() {
    if (_length == 0) {
      return;
    }
    _pendingBreak = true;
  }

  /// 段落级块之间的分隔：换行后多落一个空行。
  ///
  /// 详情页的 `MarkdownBody` 会给每个块加 blockSpacing，卡片只有一个
  /// `Text.rich`，只能靠空行制造同样的段落间距；渲染侧会给这个空行
  /// 单独压缩行高，避免占掉整整一行。
  void _gap() {
    if (_length == 0) {
      return;
    }
    _pendingBreak = true;
    _pendingGap = true;
  }

  void _writeRaw(String value, Set<PreviewInlineStyle> styles) {
    final start = _length;
    _buffer.write(value);
    _length += value.length;
    _tail = value[value.length - 1];
    if (styles.isNotEmpty && value.trim().isNotEmpty) {
      _ranges.add(PreviewRange(start, _length, styles));
    }
  }

  /// 落地挂起的换行（以及段落空行）。
  ///
  /// 抽出来是为了让「没有前缀的列表项」（待办）也能在同一套时机换行，
  /// 而不必为了触发换行写一个占位字符。
  void _flushPendingBreak() {
    if (!_pendingBreak) {
      return;
    }
    _pendingBreak = false;
    final gap = _pendingGap;
    _pendingGap = false;
    if (_length > 0 && _tail != '\n') {
      _writeRaw('\n', const <PreviewInlineStyle>{});
      if (gap) {
        _spacerOffsets.add(_length);
        _writeRaw('\n', const <PreviewInlineStyle>{});
      }
    }
  }

  void _append(
    String value,
    Set<PreviewInlineStyle> styles, {
    String indent = '',
  }) {
    if (value.isEmpty) {
      return;
    }

    var content = value;
    if (_pendingBreak) {
      _flushPendingBreak();
      // 行首缩进在预览里没有意义
      content = content.replaceFirst(_leadingSpacePattern, '');
    } else if (_length == 0 || _tail == '\n') {
      content = content.replaceFirst(_leadingSpacePattern, '');
    }

    if (content.isEmpty) {
      return;
    }

    // 缩进在剥完行首空白之后补，否则会被当成行首空白一起吃掉
    if (indent.isNotEmpty) {
      _writeRaw(indent, const <PreviewInlineStyle>{});
    }

    final start = _length;
    _buffer.write(content);
    _length += content.length;
    _tail = content[content.length - 1];

    if (styles.isNotEmpty) {
      _ranges.add(PreviewRange(start, _length, styles));
    }

    // 勾选字符：记录真实偏移与出现顺序，供点击回写
    for (var i = 0; i < content.length; i++) {
      final char = content[i];
      if (char != '☑' && char != '☐') {
        continue;
      }
      _checkboxes.add(
        PreviewCheckbox(
          index: _checkboxIndex++,
          offset: start + i,
          checked: char == '☑',
        ),
      );
    }
  }

  Set<PreviewInlineStyle> _plus(
    Set<PreviewInlineStyle> base,
    PreviewInlineStyle style,
  ) =>
      base.isEmpty
          ? <PreviewInlineStyle>{style}
          : <PreviewInlineStyle>{...base, style};
}

/// 缓存里的一条预览，连同它的估算占用与所属预算桶。
class _PreviewEntry {
  const _PreviewEntry({
    required this.preview,
    required this.cost,
    required this.isLong,
  });

  final NotePreview preview;

  /// 估算占用：预览文本按字符计，样式区间、链接、勾选框按固定权重折算。
  final int cost;

  /// 全文预览（详情页、历史版本）走单独的条数与预算，不和卡片预览抢位置。
  final bool isLong;
}

/// 预览结果 LRU 缓存。
///
/// 必须放在卡片之外：`NoteCard` 滚出屏幕就会销毁，缓存留在 State 里等于没缓存。
///
/// 键里不再放整篇正文：卡片销毁后缓存还会替几百条笔记长期持有原文，一条几万字
/// 的长笔记就是几十万字符。预览只取决于前 `parseLimit` 个字符（`buildNotePreview`
/// 第一步就是截前缀），所以用这段前缀的指纹定位——前缀一样必然得到一样的预览，
/// 前缀一变键就变。没有笔记 ID 的调用方（详情页、历史版本）也就不必单独留一套键。
class NotePreviewCache {
  NotePreviewCache._();

  /// 条目数上限：普通短笔记按预算能塞下远不止 400 条，得有条数兜底。
  static const int _maxEntries = 400;

  /// 预览文本与样式区间的估算字符预算。400 条 2400 字的长卡片约 96 万字符，
  /// 会被这套预算裁到两百条上下。
  static const int _maxChars = 600000;

  /// 全文预览（详情页）单独限条数：一条几万字，不能按 400 条算内存。
  static const int _maxLongEntries = 4;
  static const int _maxLongChars = 1200000;

  static final LinkedHashMap<String, _PreviewEntry> _entries =
      LinkedHashMap<String, _PreviewEntry>();

  static int _chars = 0;
  static int _longChars = 0;

  static int _hits = 0;
  static int _misses = 0;

  /// 命中率，便于在性能面板里观察缓存是否有效。
  static double get hitRate {
    final hits = _hits;
    final total = hits + _misses;
    return total == 0 ? 0 : hits / total;
  }

  /// 当前驻留条目数。
  @visibleForTesting
  static int get entryCount => _entries.length;

  /// 当前驻留条目的估算字符占用，便于核对预算是否生效。
  @visibleForTesting
  static int get residentChars => _chars + _longChars;

  /// 当前驻留键。键里不应出现正文，用于核对缓存没有替笔记长期持有原文。
  @visibleForTesting
  static List<String> get debugKeys => _entries.keys.toList();

  static NotePreview resolve(
    String content, {
    int parseLimit = defaultPreviewParseLimit,
  }) {
    final key = _key(content, parseLimit);
    return _read(key) ??
        _store(
          key,
          buildNotePreview(content, parseLimit: parseLimit),
          isLong: parseLimit != defaultPreviewParseLimit,
        );
  }

  /// 详情页的长文解析放到后台，复用同一份全文缓存。
  static Future<NotePreview> resolveAsync(
    String content, {
    required int parseLimit,
  }) async {
    final key = _key(content, parseLimit);
    final cached = _read(key);
    if (cached != null) {
      return cached;
    }
    final preview = await compute(_parsePreview, (content, parseLimit));
    return _store(
      key,
      preview,
      isLong: parseLimit != defaultPreviewParseLimit,
    );
  }

  /// 缓存键：解析上限 + 解析范围内正文的指纹。
  ///
  /// 两路独立的 32 位滚动哈希并行推进（FNV-1a 与 djb2 变体），合起来 64 位，
  /// 两路同时碰撞才会误命中；400 条规模下概率低到可以当作不存在。这样键只有
  /// 几十字节，且随正文变化而变，不必为失效额外维护版本号——`Note.updatedAt`
  /// 也不适合当版本号，Memos 的伪 UTC 会让 `createdAt` 落在未来，
  /// `_clampUpdatedAt` 把编辑时间压回 `createdAt`，正文改了而 `updatedAt` 不变。
  static String _key(String content, int parseLimit) {
    final end = _safePrefixLength(content, parseLimit);
    var fnv = 0x811c9dc5;
    var djb = 0x050c5d1f;
    for (var i = 0; i < end; i++) {
      final unit = content.codeUnitAt(i);
      fnv = ((fnv ^ unit) * 0x01000193) & 0xffffffff;
      djb = ((djb * 31) + unit) & 0xffffffff;
    }
    return '$parseLimit\u0000$end\u0000'
        '${fnv.toRadixString(16)}-${djb.toRadixString(16)}';
  }

  static NotePreview? _read(String key) {
    final cached = _entries.remove(key);
    if (cached != null) {
      _hits++;
      _entries[key] = cached; // 重新插入队尾，维持 LRU 顺序
      return cached.preview;
    }

    _misses++;
    return null;
  }

  static NotePreview _store(
    String key,
    NotePreview preview, {
    required bool isLong,
  }) {
    _remove(key); // 同键覆盖时先把旧账减掉，避免预算被重复计
    final entry = _PreviewEntry(
      preview: preview,
      cost: _costOf(preview),
      isLong: isLong,
    );
    _entries[key] = entry;
    if (isLong) {
      _longChars += entry.cost;
    } else {
      _chars += entry.cost;
    }
    _trim(keep: key);
    return preview;
  }

  static void _remove(String key) {
    final old = _entries.remove(key);
    if (old == null) {
      return;
    }
    if (old.isLong) {
      _longChars -= old.cost;
    } else {
      _chars -= old.cost;
    }
  }

  /// 从最久未使用的一端淘汰，直到条数和两套预算都满足。
  ///
  /// 只淘汰「超了的那一桶」：全文预览超标时不该顺手把卡片预览挤掉。刚写入的
  /// [keep] 不参与淘汰——单条就超预算时宁可短暂超一点，也不能存了又删。
  static void _trim({required String keep}) {
    var longCount = _entries.values.where((entry) => entry.isLong).length;
    while (true) {
      final longExcess =
          longCount > _maxLongEntries || _longChars > _maxLongChars;
      final shortExcess =
          _entries.length - longCount > _maxEntries || _chars > _maxChars;
      if (!longExcess && !shortExcess) {
        return;
      }
      final victim = _oldestKey(long: longExcess, keep: keep);
      if (victim == null) {
        return;
      }
      if (_entries[victim]!.isLong) {
        longCount--;
      }
      _remove(victim);
    }
  }

  static String? _oldestKey({required bool long, required String keep}) {
    for (final key in _entries.keys) {
      if (key == keep) {
        continue;
      }
      if (_entries[key]!.isLong == long) {
        return key;
      }
    }
    return null;
  }

  /// 一条预览的估算占用。区间和链接各带一个 Set / 字符串引用，按权重折算成字符。
  static int _costOf(NotePreview preview) =>
      preview.text.length +
      preview.ranges.length * 24 +
      preview.links.length * 12 +
      preview.checkboxes.length * 12 +
      preview.spacerOffsets.length * 2;

  static void clear() {
    _entries.clear();
    _chars = 0;
    _longChars = 0;
    _hits = 0;
    _misses = 0;
  }
}

NotePreview _parsePreview((String, int) request) =>
    buildNotePreview(request.$1, parseLimit: request.$2);
