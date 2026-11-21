import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/models/weread_models.dart';

/// 把微信读书的划线/想法翻译成 InkPaper 笔记。
///
/// 一条划线一条笔记、一条独立想法一条笔记：粒度细才有随机回顾和按标签过滤
/// 的价值，长文合并只适合「一本书一篇」的阅读场景。
///
/// 笔记 id 是**确定性**的（`local_wr_bm_<bookmarkId>` / `local_wr_rv_<reviewId>`），
/// 不生成随机 uuid —— 重复同步时同一个划线自然落到同一个 id 上，写库走
/// upsert 不会产生副本；同时 `local_` 前缀让 Memos 同步把它当成本地待上传
/// 笔记正常处理。
class WeReadNoteBuilder {
  const WeReadNoteBuilder();

  /// 每条导入笔记都带的标签，用户按它一筛就是全部阅读笔记。
  static const String sourceTag = '微信读书';

  /// 内容类型标签：划线 / 想法 / 点评。
  ///
  /// 判断依据是同步接口本身的结构：划线来自 `/book/bookmarklist`；
  /// `/review/list/mine` 里有 `abstract`（原文）的是针对原文的想法，
  /// 没有原文的整本书评 / 章节点评算点评。挂在划线下的想法会连同
  /// `#划线` 一起带上 `#想法`，不另起一条笔记。
  static const String highlightTag = '划线';
  static const String thoughtTag = '想法';
  static const String reviewTag = '点评';

  /// 笔记 id 前缀，便于识别来源与批量清理。
  static const String bookmarkIdPrefix = 'local_wr_bm_';
  static const String reviewIdPrefix = 'local_wr_rv_';

  /// 「读完档案」笔记的 id 前缀。
  static const String finishedIdPrefix = 'local_wr_fin_';

  /// 「周报 / 月报」笔记的 id 前缀：一个自然周期只生成一条。
  static const String weeklyIdPrefix = 'local_wr_week_';
  static const String monthlyIdPrefix = 'local_wr_month_';

  static String bookmarkNoteId(String bookmarkId) =>
      '$bookmarkIdPrefix$bookmarkId';

  static String reviewNoteId(String reviewId) => '$reviewIdPrefix$reviewId';

  /// 一本书的读完档案笔记 id。一本书只会有一条，重复同步靠它去重。
  static String finishedNoteId(String bookId) => '$finishedIdPrefix$bookId';

  /// 某一自然周的周报笔记 id，如 `local_wr_week_20261110`。
  static String weeklyNoteId(DateTime weekStart) =>
      '$weeklyIdPrefix${weekStart.year}'
      '${_two(weekStart.month)}${_two(weekStart.day)}';

  /// 某一自然月的月报笔记 id，如 `local_wr_month_202610`。
  static String monthlyNoteId(DateTime monthStart) =>
      '$monthlyIdPrefix${monthStart.year}${_two(monthStart.month)}';

  /// 判断一个笔记 id 是不是微信读书同步生成的。
  static bool isWeReadNoteId(String noteId) =>
      noteId.startsWith(bookmarkIdPrefix) ||
      noteId.startsWith(reviewIdPrefix) ||
      noteId.startsWith(finishedIdPrefix) ||
      noteId.startsWith(weeklyIdPrefix) ||
      noteId.startsWith(monthlyIdPrefix);

  /// 「读完档案」→ 笔记。
  ///
  /// 一本书一条，封面图放最前（卡片会把正文里的图片当封面渲染），后面是
  /// 读完时间、阅读天数、累计时长这些「读完那一刻才知道」的信息。划线笔记
  /// 按条铺开，这些书级别的信息没地方放，所以单独成条，靠书名标签和划线
  /// 笔记关联起来。
  ///
  /// id 由 bookId 确定性生成：一本书只有一条档案，下次同步直接命中去重。
  Note? buildFinishedNote({
    required String bookId,
    required String title,
    required String author,
    required WeReadBookProgress progress,
    String? coverUrl,
    int highlightCount = 0,
    int reviewCount = 0,
    DateTime? fallbackTime,
  }) {
    if (bookId.trim().isEmpty || !progress.isFinished) {
      return null;
    }

    final finishedAt = _timeOf(progress.finishTime, fallbackTime);
    final startedAt = progress.startReadingTime > 0
        ? _timeOf(progress.startReadingTime, null)
        : null;

    final cover = (coverUrl ?? '').trim();
    final parts = <String>[
      if (cover.isNotEmpty) '![]($cover)',
      _finishedHeadline(title, author),
      _finishedBullets(
        finishedAt: finishedAt,
        startedAt: startedAt,
        progress: progress,
        highlightCount: highlightCount,
        reviewCount: reviewCount,
      ),
      '—— 微信读书 · 阅读档案',
    ];

    final tags = <String>['#$sourceTag', '#$finishedTag'];
    final bookTagValue = bookTag(title);
    if (bookTagValue.isNotEmpty) {
      tags.add('#$bookTagValue');
    }

    final content = '${parts.join('\n\n')}\n\n${tags.join(' ')}';
    return Note(
      id: finishedNoteId(bookId.trim()),
      content: content,
      tags: Note.extractTagsFromContent(content),
      // 笔记时间落在「读完那一刻」，首页按时间排序时就排在读完那天。
      createdAt: finishedAt,
      updatedAt: finishedAt,
    );
  }

  /// 读完那一刻的标签，和书名标签一起用可以只看读完的书。
  static const String finishedTag = '读完';

  /// 周报 / 月报的标签，点标签就能连着看每一期的阅读回顾。
  static const String weeklyTag = '周报';
  static const String monthlyTag = '月报';

  /// 周报 / 月报 → 笔记。
  ///
  /// 阅读时长为 0 的周期直接返回 null：用户那一周根本没打开书，生成一条
  /// 「读了 0 分钟」的空笔记只是噪音。id 由周期起点确定性生成，同一期重复
  /// 同步天然命中去重。
  Note? buildPeriodNote({
    required bool weekly,
    required WeReadPeriodStats stats,
  }) {
    if (stats.isEmpty) {
      return null;
    }

    final endDay = stats.end.subtract(const Duration(days: 1));
    final headline = weekly
        ? '${_formatMonthDay(stats.start)} ~ ${_formatMonthDay(endDay)} 的阅读回顾'
        : '${stats.start.year} 年 ${stats.start.month} 月阅读回顾';

    final parts = <String>[headline, _periodBullets(stats)];
    if (stats.books.isNotEmpty) {
      final top = stats.books.take(5).map((book) {
        final duration = formatReadingDuration(book.readTime);
        final title = book.title.trim();
        final author = book.author.trim();
        final name = author.isEmpty ? '《$title》' : '《$title》（$author）';
        return duration.isEmpty ? '- $name' : '- $name $duration';
      }).join('\n');
      parts.add('**读得最多**\n$top');
    }
    parts.add(weekly ? '—— 微信读书 · 每周回顾' : '—— 微信读书 · 每月回顾');

    final tag = weekly ? weeklyTag : monthlyTag;
    final content = '${parts.join('\n\n')}\n\n#$sourceTag #$tag';
    final id = weekly ? weeklyNoteId(stats.start) : monthlyNoteId(stats.start);
    // 笔记时间落在周期最后一刻：首页按时间排序时，回顾正好排在那一周/月之后。
    final time = stats.end.subtract(const Duration(seconds: 1));
    return Note(
      id: id,
      content: content,
      tags: Note.extractTagsFromContent(content),
      createdAt: time,
      updatedAt: time,
    );
  }

  /// 回顾笔记的统计条目：时长、有效阅读天数、读过/读完/笔记数。
  ///
  /// `/readdata/detail` 的 `readStat` 文案本身就是「12本」「30条」，直接
  /// 用它的写法，不要自己再拼单位。`阅读` 也是天数（和 readDays 重复），略过。
  String _periodBullets(WeReadPeriodStats stats) {
    final lines = <String>[
      '- 阅读时长：${formatReadingDuration(stats.totalReadTime)}',
    ];
    if (stats.readDays > 0) {
      lines.add('- 有效阅读：${stats.readDays} 天');
    }
    final counts = <String>[
      if (stats.stats['读过'] != null) '读过 ${stats.stats['读过']}',
      if (stats.stats['读完'] != null) '读完 ${stats.stats['读完']}',
      if (stats.stats['笔记'] != null) '笔记 ${stats.stats['笔记']}',
    ];
    if (counts.isNotEmpty) {
      lines.add('- ${counts.join(' · ')}');
    }
    return lines.join('\n');
  }

  /// `MM-DD`，回顾标题里用，跨年也不会产生歧义（标题带年份的是月报）。
  static String _formatMonthDay(DateTime time) =>
      '${_two(time.month)}-${_two(time.day)}';

  String _finishedHeadline(String title, String author) {
    final cleanTitle = title.trim();
    final cleanAuthor = author.trim();
    final buffer = StringBuffer('读完了');
    if (cleanTitle.isNotEmpty) {
      buffer.write('《$cleanTitle》');
    }
    if (cleanAuthor.isNotEmpty) {
      buffer.write(' · $cleanAuthor');
    }
    return buffer.toString();
  }

  /// 读完档案的正文条目。
  ///
  /// 「阅读天数」按**开始阅读 → 读完**的自然日跨度算（含首尾）：接口没有
  /// 「这本书实际读了几天」，只有全局的 readDays，硬凑会张冠李戴。跨了
  /// 半年的书这里就是 180 天，所以起止日期一并写出来，避免读成「真读了
  /// 180 天」。
  String _finishedBullets({
    required DateTime finishedAt,
    required DateTime? startedAt,
    required WeReadBookProgress progress,
    required int highlightCount,
    required int reviewCount,
  }) {
    final lines = <String>[
      '- 读完时间：${_formatDateTime(finishedAt)}',
    ];

    final days = _readingDays(startedAt, finishedAt);
    if (startedAt != null) {
      lines.add(
        '- 阅读天数：$days 天（${_formatDate(startedAt)} ~ '
        '${_formatDate(finishedAt)}）',
      );
    } else {
      lines.add('- 阅读天数：$days 天');
    }

    final duration = formatReadingDuration(progress.readingTime);
    if (duration.isNotEmpty) {
      lines.add('- 累计阅读：$duration');
    }

    final percent = progress.progress.round().clamp(0, 100);
    if (percent > 0) {
      lines.add('- 阅读进度：$percent%');
    }

    if (highlightCount > 0 || reviewCount > 0) {
      final counts = <String>[
        if (highlightCount > 0) '划线 $highlightCount 条',
        if (reviewCount > 0) '想法 $reviewCount 条',
      ];
      lines.add('- ${counts.join(' · ')}');
    }

    return lines.join('\n');
  }

  /// 开始 → 读完的自然日跨度（含首尾），最少 1 天。
  ///
  /// 用「日期」而不是「小时数」算：同一天读完的书是 1 天，不是 0 天。
  static int _readingDays(DateTime? startedAt, DateTime finishedAt) {
    if (startedAt == null) {
      return 1;
    }
    final start = DateTime(startedAt.year, startedAt.month, startedAt.day);
    final end = DateTime(finishedAt.year, finishedAt.month, finishedAt.day);
    final diff = end.difference(start).inDays + 1;
    return diff < 1 ? 1 : diff;
  }

  /// 阅读时长的可读写法，秒 → 「X 小时 Y 分钟」。0 表示没有数据。
  static String formatReadingDuration(int seconds) {
    if (seconds <= 0) {
      return '';
    }
    if (seconds < 60) {
      return '不到 1 分钟';
    }
    final totalMinutes = seconds ~/ 60;
    final hours = totalMinutes ~/ 60;
    final minutes = totalMinutes % 60;
    if (hours <= 0) {
      return '$minutes 分钟';
    }
    return minutes == 0 ? '$hours 小时' : '$hours 小时 $minutes 分钟';
  }

  static String _formatDate(DateTime time) =>
      '${time.year}-${_two(time.month)}-${_two(time.day)}';

  static String _formatDateTime(DateTime time) =>
      '${_formatDate(time)} ${_two(time.hour)}:${_two(time.minute)}';

  static String _two(int value) => value.toString().padLeft(2, '0');

  /// 划线 → 笔记。挂在这条划线上的想法按时间顺序追加。
  Note? buildHighlightNote({
    required WeReadNotebook notebook,
    required WeReadHighlight highlight,
    String? chapterTitle,
    List<WeReadReview> inlineReviews = const [],
    DateTime? fallbackTime,
  }) {
    final quote = _normalize(highlight.text);
    if (quote.isEmpty) {
      return null;
    }

    final parts = <String>[_quoteBlock(quote)];
    final sortedReviews = [...inlineReviews]
      ..sort((a, b) => a.createTime.compareTo(b.createTime));
    for (final review in sortedReviews) {
      final thought = _normalize(review.content);
      if (thought.isNotEmpty) {
        parts.add(thought);
      }
    }
    parts.add(_footer(notebook, chapterTitle));

    return _buildNote(
      id: bookmarkNoteId(highlight.bookmarkId),
      body: parts.join('\n\n'),
      time: _timeOf(highlight.createTime, fallbackTime),
      notebook: notebook,
      typeTags: <String>[
        highlightTag,
        if (sortedReviews
            .any((review) => _normalize(review.content).isNotEmpty))
          thoughtTag,
      ],
    );
  }

  /// 独立想法/点评 → 笔记（没有对应划线的整本书评、章节点评、短想法）。
  Note? buildReviewNote({
    required WeReadNotebook notebook,
    required WeReadReview review,
    String? chapterTitle,
    DateTime? fallbackTime,
  }) {
    final thought = _normalize(review.content);
    if (thought.isEmpty) {
      return null;
    }

    final parts = <String>[];
    final quoted = _normalize(review.abstractText ?? '');
    if (quoted.isNotEmpty) {
      parts.add(_quoteBlock(quoted));
    }
    parts.add(thought);

    if (review.star >= 0 && review.star <= 5) {
      parts.add('评分 ${review.star}/5');
    }
    parts.add(_footer(notebook, chapterTitle ?? review.chapterName));

    return _buildNote(
      id: reviewNoteId(review.reviewId),
      body: parts.join('\n\n'),
      time: _timeOf(review.createTime, fallbackTime),
      notebook: notebook,
      typeTags: <String>[
        if (quoted.isEmpty) reviewTag else thoughtTag,
      ],
    );
  }

  Note _buildNote({
    required String id,
    required String body,
    required DateTime time,
    required WeReadNotebook notebook,
    required List<String> typeTags,
  }) {
    // 注意必须写成 ${...}：`$_tags(notebook)` 只会插值出函数本身，
    // 后面的 `(notebook)` 会变成字面量挂在正文末尾。
    final content = '$body\n\n${_tags(notebook, typeTags: typeTags)}';
    return Note(
      id: id,
      content: content,
      tags: Note.extractTagsFromContent(content),
      createdAt: time,
      updatedAt: time,
    );
  }

  /// 书名 → 可用标签。标签正则不允许空白和常见标点，这里先清干净；
  /// 清完为空（纯符号书名）就只留来源标签。
  static String bookTag(String title) {
    final cleaned = title
        .replaceAll(
          RegExp(r'[#\s《》〈〉\[\]【】()（）{},，、;；:：!！?？·—…/\\|]'),
          '',
        )
        .replaceAll(RegExp(r'["\u2018\u2019\u201C\u201D]'), '')
        .trim();
    if (cleaned.isEmpty) {
      return '';
    }
    return cleaned.length > 24 ? cleaned.substring(0, 24) : cleaned;
  }

  String _tags(WeReadNotebook notebook, {required List<String> typeTags}) {
    final book = bookTag(notebook.title);
    final tags = <String>[
      '#$sourceTag',
      if (book.isNotEmpty) '#$book',
      ...typeTags.map((tag) => '#$tag'),
    ];
    return tags.join(' ');
  }

  String _footer(WeReadNotebook notebook, String? chapterTitle) {
    final title = notebook.title.trim();
    final author = notebook.author.trim();
    final chapter = (chapterTitle ?? '').trim();

    final buffer = StringBuffer('—— ');
    buffer.write(title.isEmpty ? '微信读书' : '《$title》');
    if (author.isNotEmpty) {
      buffer.write(' $author');
    }
    if (chapter.isNotEmpty) {
      buffer.write(' · $chapter');
    }
    return buffer.toString();
  }

  /// 引用块：多行划线每行都要带 `>`，否则渲染出来只有第一行是引用。
  String _quoteBlock(String text) => text
      .split('\n')
      .map((line) => line.trim().isEmpty ? '>' : '> $line')
      .join('\n');

  /// 去掉首尾空白，并把三行以上的连续空行压成一行 —— 微信读书的划线常带
  /// 排版换行，原样搬过来会让笔记里到处都是空行。
  String _normalize(String raw) =>
      raw.replaceAll('\r\n', '\n').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();

  /// Unix 秒 → 本地 DateTime。
  ///
  /// 刻意不用 `isUtc: true` + `toLocal()`：本项目全链路按「字段值即挂钟
  /// 时间」格式化（见 note_timestamp_format.dart），这里直接构造本地时间，
  /// 字段值就是用户所在时区的正确时刻。服务端没给时间时退到 [fallbackTime]。
  DateTime _timeOf(int unixSeconds, DateTime? fallbackTime) {
    if (unixSeconds <= 0) {
      return fallbackTime ?? DateTime.now();
    }
    return DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000);
  }
}
