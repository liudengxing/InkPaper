// 微信读书 Agent 网关的数据模型。
//
// 字段含义以官方 skill 文档（notes.md / shelf.md）为准，解析时全部做宽松
// 兼容：网关回包会被裁剪字段、数字有时是 int 有时是字符串，缺字段一律按
// 默认值兜底，绝不让单条脏数据把整轮同步打断。

/// 一个「有笔记的书」概览（`/user/notebooks` 的一项）。
class WeReadNotebook {
  const WeReadNotebook({
    required this.bookId,
    required this.title,
    required this.author,
    this.cover,
    this.highlightCount = 0,
    this.reviewCount = 0,
    this.bookmarkCount = 0,
    this.readingProgress = 0,
    this.markedStatus = 0,
    this.sort = 0,
  });

  factory WeReadNotebook.fromJson(Map<String, dynamic> json) {
    // `book` 是嵌套的书籍信息对象；个别回包里书名字段会平铺在顶层。
    final book = json['book'] is Map
        ? Map<String, dynamic>.from(json['book'] as Map)
        : const <String, dynamic>{};
    return WeReadNotebook(
      bookId: _asString(json['bookId'] ?? book['bookId']),
      title: _asString(book['title'] ?? json['title']),
      author: _asString(book['author'] ?? json['author']),
      cover: _asString(book['cover'] ?? json['cover']).isEmpty
          ? null
          : _asString(book['cover'] ?? json['cover']),
      // ⚠️ `noteCount` 是**划线条数**，不是总笔记数；总量要自己加三项。
      highlightCount: _asInt(json['noteCount']),
      reviewCount: _asInt(json['reviewCount']),
      bookmarkCount: _asInt(json['bookmarkCount']),
      readingProgress: _asDouble(json['readingProgress']),
      markedStatus: _asInt(json['markedStatus']),
      sort: _asInt(json['sort']),
    );
  }

  final String bookId;
  final String title;
  final String author;
  final String? cover;

  /// 划线（高亮原文）条数。
  final int highlightCount;

  /// 想法/点评条数（已含划线想法、章节想法、整本书评）。
  final int reviewCount;

  /// 书签条数。当前接口只给数量，导不出内容。
  final int bookmarkCount;

  final double readingProgress;

  /// 阅读状态。**官方文档写的「1=读完, 0=在读」与实测不符**：实测取值为
  /// 1/2/3/4，其中 4 才是读完（progress 99~100、`/book/getprogress` 有
  /// finishTime），1/2/3 都能见到进度只有 30~60 的书。所以这里只把它当
  /// 「粗筛线索」，最终是否读完一律以 `finishTime > 0` 为准。
  final int markedStatus;

  /// 最近一条笔记的排序值（时间戳），翻页游标与增量判断都用它。
  final int sort;

  /// 统计口径的总笔记数：想法 + 划线 + 书签。
  int get totalNotes => reviewCount + highlightCount + bookmarkCount;

  /// 粗判「可能读完了」：markedStatus 为 4，或进度已经顶到 99% 以上。
  ///
  /// 只是用来决定「哪些书值得再调一次进度接口」，不是最终结论 ——
  /// 微信读书的进度会停在 99 不走到 100，也有进度 0 却标记读完（听书或
  /// 快速翻完）的情况，所以两条件任一满足都进候选。
  bool get maybeFinished => markedStatus == 4 || readingProgress >= 99;
}

/// 单本书的阅读进度（`/book/getprogress`）。
///
/// 这是判断「是否读完」与拿「读完时间 / 阅读天数」的唯一可靠来源：
/// 书架只能给 `finishReading` 布尔量，笔记本列表的 `markedStatus` 含义
/// 与文档不符，只有这里会给出 `finishTime` 这个确切的时间戳。
class WeReadBookProgress {
  const WeReadBookProgress({
    required this.bookId,
    this.finishTime = 0,
    this.startReadingTime = 0,
    this.readingTime = 0,
    this.ttsTime = 0,
    this.progress = 0,
    this.chapterIdx = 0,
  });

  factory WeReadBookProgress.fromJson(Map<String, dynamic> json) {
    // 真实结构是 `{"bookId": "...", "book": {...}}`；个别回包会把字段平铺。
    final book = json['book'] is Map
        ? Map<String, dynamic>.from(json['book'] as Map)
        : json;
    return WeReadBookProgress(
      bookId: _asString(json['bookId'] ?? book['bookId']),
      finishTime: _asInt(book['finishTime']),
      startReadingTime: _asInt(book['startReadingTime']),
      readingTime: _asInt(book['readingTime']),
      ttsTime: _asInt(book['ttsTime']),
      progress: _asDouble(book['progress']),
      chapterIdx: _asInt(book['chapterIdx']),
    );
  }

  final String bookId;

  /// 读完时间（Unix 秒）。0 表示没读完 —— 这是「读完」的唯一判据。
  final int finishTime;

  /// 第一次打开这本书的时间（Unix 秒）。
  final int startReadingTime;

  /// 累计阅读时长（秒）。
  final int readingTime;

  /// 其中听书时长（秒）。
  final int ttsTime;

  /// 阅读进度百分比。
  final double progress;

  final int chapterIdx;

  bool get isFinished => finishTime > 0;
}

/// 书架条目（`/shelf/sync`），只为补「没有划线但已读完」的书。
class WeReadShelfBook {
  const WeReadShelfBook({
    required this.bookId,
    required this.title,
    required this.author,
    this.cover,
    this.isFinished = false,
    this.readUpdateTime = 0,
  });

  factory WeReadShelfBook.fromJson(Map<String, dynamic> json) =>
      WeReadShelfBook(
        bookId: _asString(json['bookId']),
        title: _asString(json['title']),
        author: _asString(json['author']),
        cover:
            _asString(json['cover']).isEmpty ? null : _asString(json['cover']),
        // `finishReading: 1` 才是读完；`finish` 是「这本书完结出版」的
        // 意思（连载书也会是 1），不能拿来判断用户读没读完。
        isFinished: _asInt(json['finishReading']) == 1,
        readUpdateTime: _asInt(json['readUpdateTime']),
      );

  final String bookId;
  final String title;
  final String author;
  final String? cover;
  final bool isFinished;
  final int readUpdateTime;
}

/// 一条划线（高亮原文）。
class WeReadHighlight {
  const WeReadHighlight({
    required this.bookmarkId,
    required this.bookId,
    required this.chapterUid,
    required this.text,
    required this.createTime,
    this.range,
  });

  factory WeReadHighlight.fromJson(Map<String, dynamic> json) =>
      WeReadHighlight(
        bookmarkId: _asString(json['bookmarkId']),
        bookId: _asString(json['bookId']),
        chapterUid: _asInt(json['chapterUid']),
        text: _asString(json['markText']),
        createTime: _asInt(json['createTime']),
        range:
            _asString(json['range']).isEmpty ? null : _asString(json['range']),
      );

  final String bookmarkId;
  final String bookId;
  final int chapterUid;
  final String text;

  /// Unix 秒。0 表示服务端没给。
  final int createTime;

  /// 划线位置范围（如 `"2959-3007"`），用于和想法配对。
  final String? range;
}

/// 一条个人想法/点评（`/review/list/mine` 的一项）。
class WeReadReview {
  const WeReadReview({
    required this.reviewId,
    required this.content,
    required this.createTime,
    this.abstractText,
    this.range,
    this.chapterUid,
    this.chapterName,
    this.star = -1,
    this.isFinish = false,
  });

  factory WeReadReview.fromJson(Map<String, dynamic> json) {
    // 真实结构是 `reviews[].review.{...}`，reviewId 可能在外层也可能在内层。
    final review = json['review'] is Map
        ? Map<String, dynamic>.from(json['review'] as Map)
        : json;
    return WeReadReview(
      reviewId: _asString(
        review['reviewId'] ?? json['reviewId'] ?? review['reviewID'],
      ),
      content: _asString(review['content']),
      createTime: _asInt(review['createTime']),
      abstractText: _asString(review['abstract']).isEmpty
          ? null
          : _asString(review['abstract']),
      range: _asString(review['range']).isEmpty
          ? null
          : _asString(review['range']),
      chapterUid:
          review['chapterUid'] == null ? null : _asInt(review['chapterUid']),
      chapterName: _asString(review['chapterName']).isEmpty
          ? null
          : _asString(review['chapterName']),
      star: review['star'] == null ? -1 : _asInt(review['star']),
      isFinish: _asInt(review['isFinish']) == 1,
    );
  }

  final String reviewId;
  final String content;
  final int createTime;

  /// 想法所针对的划线原文。整本书评 / 章节点评通常为空。
  final String? abstractText;

  /// 划线位置范围，和 [WeReadHighlight.range] 配对后可挂到对应划线上。
  final String? range;

  final int? chapterUid;
  final String? chapterName;

  /// 0~5 星，-1 = 未评分。
  final int star;

  final bool isFinish;

  /// 是否针对某段划线发表（有 range + 原文）。
  bool get isInline => range != null && range!.isNotEmpty;
}

/// 章节信息，用来把划线定位到「第几章 章节名」。
class WeReadChapter {
  const WeReadChapter({
    required this.chapterUid,
    required this.chapterIdx,
    required this.title,
  });

  factory WeReadChapter.fromJson(Map<String, dynamic> json) => WeReadChapter(
        chapterUid: _asInt(json['chapterUid']),
        chapterIdx: _asInt(json['chapterIdx']),
        title: _asString(json['title']),
      );

  final int chapterUid;
  final int chapterIdx;
  final String title;
}

/// 单本书的完整笔记内容（划线 + 想法 + 章节）。
class WeReadBookNotes {
  const WeReadBookNotes({
    required this.bookId,
    required this.highlights,
    required this.reviews,
    required this.chapters,
  });

  final String bookId;
  final List<WeReadHighlight> highlights;
  final List<WeReadReview> reviews;
  final List<WeReadChapter> chapters;

  /// chapterUid → 章节标题。
  Map<int, String> get chapterTitles => {
        for (final chapter in chapters)
          if (chapter.title.isNotEmpty) chapter.chapterUid: chapter.title,
      };

  bool get isEmpty => highlights.isEmpty && reviews.isEmpty;
}

/// 一个统计周期里读得最多的一本书/一张专辑（`/readdata/detail` 的
/// `readLongest` 一项）。电子书取 `book`，有声内容取 `albumInfo`。
class WeReadPeriodBook {
  const WeReadPeriodBook({
    required this.title,
    this.author = '',
    this.readTime = 0,
  });

  factory WeReadPeriodBook.fromJson(Map<String, dynamic> json) {
    final rawBook = json['book'];
    final rawAlbum = json['albumInfo'];
    final book = rawBook is Map ? Map<String, dynamic>.from(rawBook) : null;
    final album = rawAlbum is Map ? Map<String, dynamic>.from(rawAlbum) : null;
    // 电子书书名在 book.title，有声内容在 albumInfo.name。
    final title = (book == null ? '' : _asString(book['title'])).trim();
    final albumName = (album == null ? '' : _asString(album['name'])).trim();
    final author = (book == null ? '' : _asString(book['author'])).trim();
    final albumAuthor =
        (album == null ? '' : _asString(album['author'])).trim();
    return WeReadPeriodBook(
      title: title.isNotEmpty ? title : albumName,
      author: author.isNotEmpty ? author : albumAuthor,
      readTime: _asInt(json['readTime']),
    );
  }

  final String title;
  final String author;

  /// 该周期内在本书上的阅读/收听时长（秒）。
  final int readTime;
}

/// 一个自然周期（周/月）的阅读统计，来自 `/readdata/detail`。
///
/// 注意：[totalReadTime] 的单位是**秒**，不是分钟；[readDays] 是「单日
/// 阅读满 1 分钟」才算一天的有效阅读天数，不是自然日。
class WeReadPeriodStats {
  const WeReadPeriodStats({
    required this.start,
    required this.end,
    required this.totalReadTime,
    required this.readDays,
    this.books = const [],
    this.stats = const {},
  });

  factory WeReadPeriodStats.fromJson(
    Map<String, dynamic> json, {
    required DateTime start,
    required DateTime end,
  }) {
    final books = <WeReadPeriodBook>[];
    final rawBooks = json['readLongest'];
    if (rawBooks is List) {
      for (final raw in rawBooks) {
        if (raw is! Map) {
          continue;
        }
        final book = WeReadPeriodBook.fromJson(Map<String, dynamic>.from(raw));
        if (book.title.isEmpty) {
          continue;
        }
        books.add(book);
      }
    }
    books.sort((a, b) => b.readTime.compareTo(a.readTime));

    // readStat 形如 [{stat: '读过', counts: '12本'}, …]，直接收成「名称 → 文案」。
    final stats = <String, String>{};
    final rawStats = json['readStat'];
    if (rawStats is List) {
      for (final raw in rawStats) {
        if (raw is! Map) {
          continue;
        }
        final name = _asString(raw['stat']).trim();
        final counts = _asString(raw['counts']).trim();
        if (name.isNotEmpty && counts.isNotEmpty) {
          stats[name] = counts;
        }
      }
    }

    return WeReadPeriodStats(
      start: start,
      end: end,
      totalReadTime: _asInt(json['totalReadTime']),
      readDays: _asInt(json['readDays']),
      books: books,
      stats: stats,
    );
  }

  /// 周期起点（含）。
  final DateTime start;

  /// 周期终点（不含）。
  final DateTime end;

  /// 周期内阅读 + 收听总时长（秒）。
  final int totalReadTime;

  /// 有效阅读天数（单日满 1 分钟）。
  final int readDays;

  /// 读得最多的书/有声内容，按时长降序。
  final List<WeReadPeriodBook> books;

  /// 阅读统计摘要，如 `{读过: 12本, 读完: 2本, 笔记: 30条}`。
  final Map<String, String> stats;

  /// 时长为 0 就是这一期没读过，不生成回顾笔记。
  bool get isEmpty => totalReadTime <= 0;
}

/// 一轮同步的统计结果。
class WeReadSyncResult {
  const WeReadSyncResult({
    this.imported = 0,
    this.booksFetched = 0,
    this.booksSkipped = 0,
    this.booksTotal = 0,
    this.skippedDuplicates = 0,
    this.finishedCandidates = 0,
    this.finishedImported = 0,
    this.periodImported = 0,
    this.failures = const [],
  });

  /// 新增入库的笔记条数。
  final int imported;

  /// 真正请求了明细接口的书数。
  final int booksFetched;

  /// 因「笔记总数与上次一致」被跳过的书数。
  final int booksSkipped;

  /// 服务端报告的「有笔记的书」总数。
  final int booksTotal;

  /// 命中去重（之前已经导入过）的条数。
  final int skippedDuplicates;

  /// 这一轮查过进度的「可能读完」的书数（已排除建过档案的）。
  final int finishedCandidates;

  /// 新增的读完档案笔记数。
  final int finishedImported;

  /// 新增的阅读周报/月报条数。
  final int periodImported;

  /// 单本失败的书名与原因，不阻断整轮同步。
  final List<String> failures;

  bool get isEmpty => imported == 0 && skippedDuplicates == 0;

  String get summary {
    final hints = <String>[
      if (finishedImported > 0) '$finishedImported 本读完档案',
      if (periodImported > 0) '$periodImported 条阅读回顾',
    ];
    final extraHint = hints.isEmpty ? '' : '、${hints.join('、')}';
    if (imported > 0) {
      return '新增 $imported 条笔记$extraHint';
    }
    if (hints.isNotEmpty) {
      return '新增 ${hints.join('、')}';
    }
    if (skippedDuplicates > 0) {
      return '已是最新，$skippedDuplicates 条已导入过';
    }
    return '没有新笔记';
  }
}

String _asString(Object? value) {
  if (value == null) {
    return '';
  }
  return value.toString();
}

int _asInt(Object? value) {
  if (value == null) {
    return 0;
  }
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.round();
  }
  return int.tryParse(value.toString().trim()) ??
      double.tryParse(value.toString().trim())?.round() ??
      0;
}

double _asDouble(Object? value) {
  if (value == null) {
    return 0;
  }
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse(value.toString().trim()) ?? 0;
}
