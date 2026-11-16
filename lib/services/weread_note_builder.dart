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

  /// 笔记 id 前缀，便于识别来源与批量清理。
  static const String bookmarkIdPrefix = 'local_wr_bm_';
  static const String reviewIdPrefix = 'local_wr_rv_';

  static String bookmarkNoteId(String bookmarkId) =>
      '$bookmarkIdPrefix$bookmarkId';

  static String reviewNoteId(String reviewId) => '$reviewIdPrefix$reviewId';

  /// 判断一个笔记 id 是不是微信读书同步生成的。
  static bool isWeReadNoteId(String noteId) =>
      noteId.startsWith(bookmarkIdPrefix) || noteId.startsWith(reviewIdPrefix);

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
    );
  }

  Note _buildNote({
    required String id,
    required String body,
    required DateTime time,
    required WeReadNotebook notebook,
  }) {
    // 注意必须写成 ${...}：`$_tags(notebook)` 只会插值出函数本身，
    // 后面的 `(notebook)` 会变成字面量挂在正文末尾。
    final content = '$body\n\n${_tags(notebook)}';
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

  String _tags(WeReadNotebook notebook) {
    final book = bookTag(notebook.title);
    return book.isEmpty ? '#$sourceTag' : '#$sourceTag #$book';
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
