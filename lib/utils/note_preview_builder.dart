import 'dart:collection';

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

/// Markdown 降维后的预览文档：一段纯文本 + 若干样式区间。
///
/// 渲染侧只需要一个 `Text.rich`，不需要构建 widget 树。
class NotePreview {
  const NotePreview({
    required this.text,
    required this.ranges,
    required this.checkboxes,
  });

  static const NotePreview empty = NotePreview(
    text: '',
    ranges: <PreviewRange>[],
    checkboxes: <PreviewCheckbox>[],
  );

  final String text;
  final List<PreviewRange> ranges;
  final List<PreviewCheckbox> checkboxes;

  bool get isEmpty => text.trim().isEmpty;
}

/// 解析前的字符上限。6 行预览最多用到一两百字，留足余量即可。
const int _previewParseLimit = 2400;

// 正则与 InlineSyntax 都是「编译一次、反复使用」的东西，放在函数里等于每次
// 缓存未命中都重新编译一遍模式。
final RegExp _todoPattern = RegExp(
  r'^([ \t]*)[-*+][ \t]+\[([ xX])\][ \t]?',
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
  int parseLimit = _previewParseLimit,
}) {
  if (content.isEmpty) {
    return NotePreview.empty;
  }

  final nodes = md.Document(
    extensionSet: md.ExtensionSet.gitHubFlavored,
    inlineSyntaxes: <md.InlineSyntax>[_underlineSyntax],
    encodeHtml: false,
  ).parse(_prepare(_safePrefix(content, parseLimit)));

  final walker = _PreviewWalker()..walkBlocks(nodes);
  return NotePreview(
    text: walker.text,
    ranges: walker.ranges,
    checkboxes: walker.checkboxes,
  );
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
String _safePrefix(String value, int limit) {
  if (value.length <= limit) {
    return value;
  }
  var end = limit;
  final code = value.codeUnitAt(end - 1);
  if (code >= 0xD800 && code <= 0xDBFF) {
    end -= 1;
  }
  return value.substring(0, end);
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
        return cleaned;
      }
    }
    return '↗ 引用笔记';
  });

  return text;
}

class _PreviewWalker {
  final StringBuffer _buffer = StringBuffer();
  final List<PreviewRange> _ranges = <PreviewRange>[];
  final List<PreviewCheckbox> _checkboxes = <PreviewCheckbox>[];

  int _length = 0;
  String _tail = '';
  int _checkboxIndex = 0;
  bool _pendingBreak = false;

  String get text => _buffer.toString();

  List<PreviewRange> get ranges => _ranges;

  List<PreviewCheckbox> get checkboxes => _checkboxes;

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
        _break();
        _walkChildren(children, styles);
        _break();
      case 'br':
        _writeRaw('\n', styles);
      case 'h1':
      case 'h2':
      case 'h3':
      case 'h4':
      case 'h5':
      case 'h6':
        // 预览里标题只加粗、不改字号：混字号会让行高不一致，视觉更差。
        _break();
        _walkChildren(children, _plus(styles, PreviewInlineStyle.bold));
        _break();
      case 'blockquote':
        _break();
        _walkChildren(children, _plus(styles, PreviewInlineStyle.quote));
        _break();
      case 'strong':
        _walkChildren(children, _plus(styles, PreviewInlineStyle.bold));
      case 'em':
        _walkChildren(children, _plus(styles, PreviewInlineStyle.italic));
      case 'del':
        _walkChildren(children, _plus(styles, PreviewInlineStyle.strike));
      case 'u':
        _walkChildren(children, _plus(styles, PreviewInlineStyle.underline));
      case 'a':
        _walkChildren(children, _plus(styles, PreviewInlineStyle.link));
      case 'code':
        // 行内代码：等宽 + 主色文字，不加底色盒子（底色会盖住行距）。
        _walkChildren(children, _plus(styles, PreviewInlineStyle.code));
      case 'pre':
        _break();
        _walkCodeBlock(node, styles);
        _break();
      case 'ul':
      case 'ol':
        _walkChildren(children, styles);
        _break();
      case 'li':
        _break();
        _walkChildren(children, styles);
        _break();
      case 'hr':
        _break();
        _append('—', styles);
        _break();
      case 'img':
        // 已在预处理阶段移除，兜底跳过。
        break;
      case 'table':
        _break();
        _walkTable(node, styles);
        _break();
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

  /// 块级节点之间的换行。
  ///
  /// 迟到写入：只有后面真的还有内容时才落一个换行，避免预览尾部挂着空行。
  void _break() {
    if (_length == 0) {
      return;
    }
    _pendingBreak = true;
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

  void _append(String value, Set<PreviewInlineStyle> styles) {
    if (value.isEmpty) {
      return;
    }

    var content = value;
    if (_pendingBreak) {
      _pendingBreak = false;
      if (_length > 0 && _tail != '\n') {
        _writeRaw('\n', const <PreviewInlineStyle>{});
      }
      // 行首缩进在预览里没有意义
      content = content.replaceFirst(_leadingSpacePattern, '');
    } else if (_length == 0 || _tail == '\n') {
      content = content.replaceFirst(_leadingSpacePattern, '');
    }

    if (content.isEmpty) {
      return;
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

/// 预览结果 LRU 缓存。
///
/// 必须放在卡片之外：`NoteCard` 滚出屏幕就会销毁，缓存留在 State 里等于没缓存。
class NotePreviewCache {
  NotePreviewCache._();

  static const int _maxEntries = 400;
  static final LinkedHashMap<String, NotePreview> _entries =
      LinkedHashMap<String, NotePreview>();

  static int _hits = 0;
  static int _misses = 0;

  /// 命中率，便于在性能面板里观察缓存是否有效。
  static double get hitRate {
    final total = _hits + _misses;
    return total == 0 ? 0 : _hits / total;
  }

  static NotePreview resolve(String content) {
    final cached = _entries.remove(content);
    if (cached != null) {
      _hits++;
      _entries[content] = cached; // 重新插入队尾，维持 LRU 顺序
      return cached;
    }

    _misses++;
    final preview = buildNotePreview(content);
    _entries[content] = preview;
    if (_entries.length > _maxEntries) {
      _entries.remove(_entries.keys.first);
    }
    return preview;
  }

  static void clear() {
    _entries.clear();
    _hits = 0;
    _misses = 0;
  }
}
