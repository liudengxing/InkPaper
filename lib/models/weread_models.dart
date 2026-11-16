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

  /// 1 = 读完，0 = 在读。
  final int markedStatus;

  /// 最近一条笔记的排序值（时间戳），翻页游标与增量判断都用它。
  final int sort;

  /// 统计口径的总笔记数：想法 + 划线 + 书签。
  int get totalNotes => reviewCount + highlightCount + bookmarkCount;

  bool get isFinished => markedStatus == 1;
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

/// 一轮同步的统计结果。
class WeReadSyncResult {
  const WeReadSyncResult({
    this.imported = 0,
    this.booksFetched = 0,
    this.booksSkipped = 0,
    this.booksTotal = 0,
    this.skippedDuplicates = 0,
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

  /// 单本失败的书名与原因，不阻断整轮同步。
  final List<String> failures;

  bool get isEmpty => imported == 0 && skippedDuplicates == 0;

  String get summary {
    if (imported > 0) {
      return '新增 $imported 条笔记';
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
