import 'dart:math' as math;

import 'package:inkpaper/models/note_model.dart';
import 'package:intl/intl.dart';

/// 打包好的笔记上下文。
class NotesContext {
  const NotesContext({
    required this.text,
    required this.noteCount,
    required this.totalCandidates,
    required this.characters,
    required this.truncated,
    this.relevantCount = 0,
    this.queryTerms = const <String>[],
  });

  /// 拼给模型的文本。
  final String text;

  /// 实际纳入的条数。
  final int noteCount;

  /// 有内容的笔记总数（用于告诉用户"共多少条，装了前多少条"）。
  final int totalCandidates;

  final int characters;

  /// 是否因为预算被截断。
  final bool truncated;

  /// 其中按问题检索出来的相关笔记条数。
  final int relevantCount;

  /// 本次识别出的检索词（调试 / 展示用）。
  final List<String> queryTerms;

  bool get hasRetrieval => relevantCount > 0;
}

/// 把全库笔记压成一段可以塞进 prompt 的上下文。
///
/// 两种取法：
/// - [build]：只按时间取最近的笔记（没有问题、或问题没有可用关键词时兜底）；
/// - [buildForQuestion]：先按问题检索相关笔记，再用最近的笔记把预算填满。
///
/// 设计取舍：
/// - 只保留纯文字（图片 / 音频等 markdown 全部剔除），用户明确说不要图片；
/// - 单条截断，避免一条超长日记吃掉整个预算；
/// - 每行带日期和标签，方便模型引用来源。
class NotesContextBuilder {
  NotesContextBuilder._();

  /// 约 2 万 token 的正文预算：再大就会拖慢首字并抬高成本，
  /// 所以超出的部分用"只带了最近 N 条"的方式明确告知用户。
  static const int defaultMaxCharacters = 28000;
  static const int defaultMaxNotes = 200;

  /// 检索最多塞多少条相关笔记，剩下的预算留给最近笔记。
  static const int defaultMaxRelevant = 80;

  /// 单条笔记最多保留的字符数。
  static const int perNoteLimit = 400;

  /// 虚字：切词前先剔掉，避免"我这周主要在关注什么"切出"注什""么样"这类噪声。
  static const Set<String> _stopChars = <String>{
    '的',
    '了',
    '是',
    '我',
    '你',
    '他',
    '她',
    '它',
    '们',
    '在',
    '有',
    '和',
    '与',
    '吗',
    '呢',
    '啊',
    '呀',
    '吧',
    '这',
    '那',
    '就',
    '都',
    '要',
    '会',
    '能',
    '去',
    '来',
    '个',
    '些',
    '把',
    '被',
    '给',
    '对',
    '也',
    '还',
    '又',
    '很',
    '太',
    '最',
    '不',
    '没',
    '怎',
    '么',
    '样',
    '什',
    '如',
    '何',
    '哪',
    '为',
    '请',
    '帮',
    '下',
    '过',
    '着',
    '地',
    '得',
    '之',
    '其',
    '或',
    '但',
    '让',
  };

  /// 问题里这些 2-gram 没有区分度，参与检索只会把噪声带进来。
  static const Set<String> _stopWords = <String>{
    '什么',
    '哪些',
    '哪个',
    '怎么',
    '怎样',
    '如何',
    '最近',
    '这周',
    '本周',
    '上周',
    '本月',
    '上个',
    '今天',
    '记录',
    '笔记',
    '请问',
    '帮我',
    '一下',
    '关于',
    '主要',
    '总结',
    '看看',
    '可以',
    '是否',
    '一共',
    '多少',
    '几条',
    '几次',
    '相关',
    '内容',
    '情况',
    '然后',
    '还有',
    '以及',
    '或者',
    '但是',
    '因为',
    '所以',
    '如果',
  };

  static NotesContext build(
    List<Note> notes, {
    int maxCharacters = defaultMaxCharacters,
    int maxNotes = defaultMaxNotes,
    int perNoteLimit = NotesContextBuilder.perNoteLimit,
  }) {
    final entries = _prepare(notes);
    return _render(
      relevant: const <_Entry>[],
      fill: entries,
      totalCandidates: entries.length,
      maxCharacters: maxCharacters,
      maxNotes: maxNotes,
      perNoteLimit: perNoteLimit,
    );
  }

  /// 按问题检索相关笔记，再用最近的笔记填充预算。
  ///
  /// 检索是纯本地的轻量 BM25 思路：把问题切成中文 2-gram / 英文词，
  /// 用 IDF 压掉"记录""最近"这类高频词，再叠加标签命中和时间新鲜度。
  /// 好处是不用额外依赖、几百毫秒内出结果，也方便单测。
  static NotesContext buildForQuestion(
    List<Note> notes,
    String question, {
    int maxCharacters = defaultMaxCharacters,
    int maxNotes = defaultMaxNotes,
    int maxRelevant = defaultMaxRelevant,
    int perNoteLimit = NotesContextBuilder.perNoteLimit,
  }) {
    final entries = _prepare(notes);
    final terms = extractQueryTerms(question);

    if (terms.isEmpty || entries.isEmpty) {
      return build(
        notes,
        maxCharacters: maxCharacters,
        maxNotes: maxNotes,
        perNoteLimit: perNoteLimit,
      );
    }

    final total = entries.length;
    final docFreq = <String, int>{};
    for (final term in terms) {
      var freq = 0;
      for (final entry in entries) {
        if (entry.lower.contains(term)) {
          freq++;
        }
      }
      docFreq[term] = freq;
    }

    final scored = <_ScoredEntry>[];
    for (final entry in entries) {
      var score = 0.0;
      for (final term in terms) {
        final hits = _countOccurrences(entry.lower, term);
        if (hits == 0) {
          continue;
        }
        final df = docFreq[term] ?? 0;
        final idf = math.log(1 + total / (1 + df));
        // 命中次数收益递减，避免长日记靠"重复同一个词"霸榜
        score += idf * (1 + (math.min(hits, 3) - 1) * 0.4);
      }
      // 标签命中是很强的信号（#运动记录 vs 正文里偶尔提到"运动"）：
      // 必须放在"正文零命中就跳过"之前，否则短笔记只有标签、正文没提关键词时
      // 会被直接丢掉。
      for (final tag in entry.tags) {
        final lowerTag = tag.toLowerCase();
        final hit = terms.any(
          (term) => lowerTag.contains(term) || term.contains(lowerTag),
        );
        if (hit) {
          score += 5.0;
          break;
        }
      }

      if (score <= 0) {
        continue;
      }

      score *= _recencyBoost(entry.time);
      scored.add(_ScoredEntry(entry, score));
    }

    if (scored.isEmpty) {
      return build(
        notes,
        maxCharacters: maxCharacters,
        maxNotes: maxNotes,
        perNoteLimit: perNoteLimit,
      );
    }

    scored.sort((a, b) => b.score.compareTo(a.score));
    final bestScore = scored.first.score;
    final relevant = <_Entry>[];
    for (final item in scored) {
      if (relevant.length >= maxRelevant) {
        break;
      }
      // 相对阈值：与最佳命中差太远的条目多半是巧合匹配
      if (item.score < bestScore * 0.18) {
        break;
      }
      relevant.add(item.entry);
    }

    return _render(
      relevant: relevant,
      fill: entries,
      totalCandidates: entries.length,
      maxCharacters: maxCharacters,
      maxNotes: maxNotes,
      perNoteLimit: perNoteLimit,
      queryTerms: terms,
    );
  }

  /// 把问题拆成可检索的词：中文 2-gram + 英文/数字词，去掉无区分度的。
  static List<String> extractQueryTerms(String question) {
    final terms = <String>{};
    final text = question.toLowerCase();

    for (final match in RegExp(r'[\u4e00-\u9fa5]+').allMatches(text)) {
      final segment = match.group(0) ?? '';
      if (segment.length < 2) {
        continue;
      }
      // 先剔掉虚字，剩下的才是"实词片段"
      final cleaned =
          segment.split('').where((char) => !_stopChars.contains(char)).join();
      if (cleaned.length < 2) {
        continue;
      }
      for (var i = 0; i + 2 <= cleaned.length; i++) {
        final gram = cleaned.substring(i, i + 2);
        if (!_stopWords.contains(gram)) {
          terms.add(gram);
        }
      }
    }

    // flutter / 3.0 / marathon 这类整词，保留小数点和连字符
    for (final match in RegExp(r'[a-z][a-z0-9\-_]{1,}|[0-9]+(?:\.[0-9]+)*')
        .allMatches(text)) {
      terms.add(match.group(0)!);
    }

    terms.removeWhere(_stopWords.contains);
    return terms.toList(growable: false);
  }

  /// 去掉图片、音频、附件这类非文字内容，只留下正文。
  static String stripMedia(String content) {
    var text = content;
    // ![alt](url)
    text = text.replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), ' ');
    // [文字](file://… / content://… / blob:…) —— 附件链接没有阅读价值
    text = text.replaceAll(
      RegExp(r'\[[^\]]*\]\((?:file|content|blob):[^)]*\)'),
      ' ',
    );
    // 裸附件地址
    text = text.replaceAll(
      RegExp(r'(?:file|content)://\S+'),
      ' ',
    );
    // 分隔线 / 多余空行
    text = text.replaceAll(RegExp(r'^\s*[-*_]{3,}\s*$', multiLine: true), '');
    text = text.replaceAll(RegExp(r'[ \t]+'), ' ');
    text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return text.trim();
  }

  static List<_Entry> _prepare(List<Note> notes) {
    final entries = <_Entry>[];
    for (final note in notes) {
      final plain = stripMedia(note.content);
      if (plain.isEmpty) {
        continue;
      }
      entries.add(
        _Entry(
          id: note.id,
          time: note.displayTime,
          tags: note.tags,
          text: plain,
        ),
      );
    }
    entries.sort((a, b) => b.time.compareTo(a.time));
    return entries;
  }

  static NotesContext _render({
    required List<_Entry> relevant,
    required List<_Entry> fill,
    required int totalCandidates,
    required int maxCharacters,
    required int maxNotes,
    required int perNoteLimit,
    List<String> queryTerms = const <String>[],
  }) {
    final buffer = StringBuffer();
    var used = 0;
    var count = 0;
    final taken = <String>{};

    void appendEntry(_Entry entry) {
      if (count >= maxNotes || used >= maxCharacters) {
        return;
      }
      final body = entry.text.length > perNoteLimit
          ? '${entry.text.substring(0, perNoteLimit)}…'
          : entry.text;
      final tags = entry.tags.isEmpty
          ? ''
          : ' ${entry.tags.take(4).map((tag) => '#$tag').join(' ')}';
      final line = '${count + 1}. [${_formatDate(entry.time)}]$tags\n$body\n';
      buffer.write(line);
      used += line.length;
      count++;
      taken.add(entry.id);
    }

    if (relevant.isNotEmpty) {
      buffer.writeln('【与问题相关的笔记】（按相关度排序）');
      for (final entry in relevant) {
        appendEntry(entry);
      }
    }

    final remaining = fill.where((entry) => !taken.contains(entry.id));
    if (relevant.isNotEmpty && used < maxCharacters && count < maxNotes) {
      buffer.writeln('【最近的笔记】');
    }
    for (final entry in remaining) {
      if (count >= maxNotes || used >= maxCharacters) {
        break;
      }
      appendEntry(entry);
    }

    return NotesContext(
      text: buffer.toString().trim(),
      noteCount: count,
      totalCandidates: totalCandidates,
      characters: used,
      truncated: count < totalCandidates,
      relevantCount: relevant.length,
      queryTerms: queryTerms,
    );
  }

  static int _countOccurrences(String haystack, String needle) {
    if (needle.isEmpty) {
      return 0;
    }
    var count = 0;
    var index = haystack.indexOf(needle);
    while (index != -1) {
      count++;
      if (count >= 5) {
        return count;
      }
      index = haystack.indexOf(needle, index + needle.length);
    }
    return count;
  }

  static double _recencyBoost(DateTime time) {
    final days = DateTime.now().difference(time).inDays;
    if (days <= 7) {
      return 1.25;
    }
    if (days <= 30) {
      return 1.1;
    }
    return 1.0;
  }

  static String _formatDate(DateTime time) {
    final now = DateTime.now();
    final pattern = time.year == now.year ? 'MM-dd' : 'yyyy-MM-dd';
    return DateFormat(pattern).format(time);
  }
}

class _Entry {
  _Entry({
    required this.id,
    required this.time,
    required this.tags,
    required this.text,
  }) : lower = text.toLowerCase();

  final String id;
  final DateTime time;
  final List<String> tags;
  final String text;
  final String lower;
}

class _ScoredEntry {
  _ScoredEntry(this.entry, this.score);

  final _Entry entry;
  final double score;
}
