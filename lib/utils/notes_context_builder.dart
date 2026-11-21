import 'dart:math' as math;

import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/utils/memos_content_helper.dart';
import 'package:intl/intl.dart';

/// 编号 → 笔记的对照表。
///
/// 洞察正文里的 `[12]` 指的就是这里的第 12 条（[index] 从 1 开始）。要让角标
/// 点得开，必须原样带回「模型这一次实际看到的那批笔记」，而不是调用方传进
/// 来的原始列表——中间隔着排序、跨时间抽样和空内容剔除，拿原列表的下标去
/// 对编号一定会错位。
class InsightSource {
  const InsightSource({
    required this.index,
    required this.noteId,
    required this.createdAt,
    required this.tags,
    required this.text,
    this.imagePaths = const <String>[],
    this.truncated = false,
  });

  /// 编号，1 = 最近一条。
  final int index;

  final String noteId;
  final DateTime createdAt;
  final List<String> tags;

  /// 与喂给模型的一致：已剔除图片与附件，超长的已截断。
  final String text;

  /// 这条在原笔记里更长，[text] 是当时喂给模型的截断版。
  final bool truncated;

  /// 原笔记里的图片。喂给模型时已经剥掉了，这里只留给角标弹层展示：
  /// 一条只有文字和一条带照片的记录，读起来的分量完全不同。
  final List<String> imagePaths;
}

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
    this.earliest,
    this.latest,
    this.sources = const <InsightSource>[],
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

  /// 纳入笔记的最早 / 最晚时间。
  ///
  /// 洞察报告的开篇要交代「这批笔记跨了多久」，模型自己从 200 行日期里
  /// 数不可靠，直接把跨度算好告诉它。
  final DateTime? earliest;
  final DateTime? latest;

  /// 按编号顺序排列的来源笔记，[sources] 的下标 0 就是编号 1。
  final List<InsightSource> sources;

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
/// - 条数与单条长度都不设上限，唯一的闸门是正文总字数预算；
/// - 每行带日期和标签，方便模型引用来源。
class NotesContextBuilder {
  NotesContextBuilder._();

  /// 约 2 万 token 的正文预算：这是唯一的上限。
  ///
  /// 不再限制条数和单条长度——条数上限在写得久的人身上等于「只看最近几个
  /// 月」，单条截断又会把一篇长文裁成半截，两头都在损害「他这些年怎么过的」
  /// 这个判断。装不下时整条放弃（不做半条截断），继续看后面还能塞进去的。
  static const int defaultMaxCharacters = 28000;

  /// 检索最多塞多少条相关笔记，剩下的预算留给最近笔记。
  static const int defaultMaxRelevant = 80;

  /// 每条的编号 / 日期 / 标签 / 换行的固定开销，估算预算是否够用。
  static const int _lineOverhead = 24;

  /// 粗估这批笔记能不能全部装进预算。装得下就不必分层打乱时间顺序。
  static bool _exceedsBudget(List<_Entry> entries, int maxCharacters) {
    var total = 0;
    for (final entry in entries) {
      total += entry.text.length + _lineOverhead;
      if (total > maxCharacters) {
        return true;
      }
    }
    return false;
  }

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

  /// [maxNotes] / [perNoteLimit] 传 null 表示不限制；只有 [maxCharacters]
  /// 是硬闸门。留成可空而不是改死，是因为问答那一路仍然需要收窄。
  static NotesContext build(
    List<Note> notes, {
    int maxCharacters = defaultMaxCharacters,
    int? maxNotes,
    int? perNoteLimit,
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

  /// 洞察专用：预算装不下时按「年-季度」分桶轮转，不是只取最近 N 条。
  ///
  /// 只按时间倒序往预算里塞，在写了两三年的人身上等于「只取最近几个月」，
  /// 模型自然写不出跨年的变化（flomo 的洞察报告正是靠时间跨度撑起开篇）。
  /// 所以一旦估算装不下，就按季度分桶、每轮每桶各取一条：近期桶条目多、
  /// 会多走几轮，天然偏向最近，但早年也一定在场。
  static NotesContext buildForInsight(
    List<Note> notes, {
    int maxCharacters = defaultMaxCharacters,
    int? maxNotes,
    int? perNoteLimit,
  }) {
    final entries = _prepare(notes);
    // 全都能装进预算就按原样给，不必为了分层打乱时间顺序
    if (maxNotes != null && entries.length <= maxNotes ||
        !_exceedsBudget(entries, maxCharacters)) {
      return _render(
        relevant: const <_Entry>[],
        fill: entries,
        totalCandidates: entries.length,
        maxCharacters: maxCharacters,
        maxNotes: maxNotes,
        perNoteLimit: perNoteLimit,
      );
    }

    // entries 已按时间倒序，桶的插入顺序就是由近到远。
    final buckets = <String, List<_Entry>>{};
    for (final entry in entries) {
      final key = '${entry.time.year}-Q${((entry.time.month - 1) ~/ 3) + 1}';
      (buckets[key] ??= <_Entry>[]).add(entry);
    }

    final ordered = <_Entry>[];
    final cursors = <String, int>{
      for (final key in buckets.keys) key: 0,
    };
    // 条数不设上限时，分层的唯一目的就是「谁先拿到预算」，所以攒够估算
    // 长度就停手——库里有几千条时不必把整库排一遍。
    var gathered = 0;
    round:
    while (true) {
      var progressed = false;
      for (final key in buckets.keys) {
        final bucket = buckets[key]!;
        final index = cursors[key]!;
        if (index >= bucket.length) {
          continue;
        }
        final entry = bucket[index];
        ordered.add(entry);
        cursors[key] = index + 1;
        progressed = true;
        gathered += entry.text.length + _lineOverhead;
        if (maxNotes != null && ordered.length >= maxNotes) {
          break round;
        }
        if (gathered >= maxCharacters) {
          break round;
        }
      }
      if (!progressed) {
        break;
      }
    }

    // 编号必须仍然是「1 = 最近」，否则 [序号] 和「编号 1 权重最高」全乱。
    ordered.sort((a, b) => b.time.compareTo(a.time));

    return _render(
      relevant: const <_Entry>[],
      fill: ordered,
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
    int? maxNotes,
    int maxRelevant = defaultMaxRelevant,
    int? perNoteLimit,
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
          imagePaths: MemosContentHelper.extractNoteImagePaths(note),
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
    int? maxNotes,
    int? perNoteLimit,
    List<String> queryTerms = const <String>[],
  }) {
    final buffer = StringBuffer();
    var used = 0;
    var count = 0;
    final taken = <String>{};
    final sources = <InsightSource>[];
    DateTime? earliest;
    DateTime? latest;

    void appendEntry(_Entry entry) {
      if ((maxNotes != null && count >= maxNotes) || used >= maxCharacters) {
        return;
      }
      // 单条不再截断；唯一例外是这一条本身就比整个预算还长——不收的话
      // 上下文直接溢出，一条都放不进去。硬闸门仍是 maxCharacters。
      final hardLimit = perNoteLimit ?? maxCharacters;
      var body = entry.text;
      var truncated = false;
      if (body.length > hardLimit) {
        body = '${body.substring(0, hardLimit)}…';
        truncated = true;
      }
      final tags = entry.tags.isEmpty
          ? ''
          : ' ${entry.tags.take(4).map((tag) => '#$tag').join(' ')}';
      final line = '${count + 1}. [${_formatDate(entry.time)}]$tags\n$body\n';
      // 预算见底就整条放弃，不做半条截断——半句话比没有更容易误导模型。
      // 第一条破例放进来自保，避免预算极小的时候一条都取不到。
      if (count > 0 && used + line.length > maxCharacters) {
        return;
      }
      buffer.write(line);
      used += line.length;
      sources.add(
        InsightSource(
          index: count + 1,
          noteId: entry.id,
          createdAt: entry.time,
          tags: entry.tags,
          text: body,
          imagePaths: entry.imagePaths,
          truncated: truncated,
        ),
      );
      count++;
      taken.add(entry.id);
      if (earliest == null || entry.time.isBefore(earliest!)) {
        earliest = entry.time;
      }
      if (latest == null || entry.time.isAfter(latest!)) {
        latest = entry.time;
      }
    }

    if (relevant.isNotEmpty) {
      buffer.writeln('【与问题相关的笔记】（按相关度排序）');
      for (final entry in relevant) {
        appendEntry(entry);
      }
    }

    final remaining = fill.where((entry) => !taken.contains(entry.id));
    if (relevant.isNotEmpty && used < maxCharacters) {
      buffer.writeln('【最近的笔记】');
    }
    for (final entry in remaining) {
      if (used >= maxCharacters) {
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
      earliest: earliest,
      latest: latest,
      sources: sources,
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
    this.imagePaths = const <String>[],
  }) : lower = text.toLowerCase();

  final String id;
  final DateTime time;
  final List<String> tags;
  final String text;
  final List<String> imagePaths;
  final String lower;
}

class _ScoredEntry {
  _ScoredEntry(this.entry, this.score);

  final _Entry entry;
  final double score;
}
