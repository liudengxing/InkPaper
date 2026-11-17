// ============================================================
// 微信读书笔记生成 · 内容格式与幂等 id
// ============================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/models/weread_models.dart';
import 'package:inkpaper/services/weread_note_builder.dart';

const _notebook = WeReadNotebook(
  bookId: '3300001',
  title: '深度工作',
  author: '[美] 卡尔·纽波特',
);

WeReadHighlight _highlight({
  String bookmarkId = 'bm-1',
  int chapterUid = 11,
  String text = '专注力是稀缺资源。',
  int createTime = 1735689600, // 2025-01-01 08:00 +08:00
  String? range = '100-120',
}) =>
    WeReadHighlight(
      bookmarkId: bookmarkId,
      bookId: _notebook.bookId,
      chapterUid: chapterUid,
      text: text,
      createTime: createTime,
      range: range,
    );

WeReadReview _review({
  String reviewId = 'rv-1',
  String content = '确实，注意力需要训练。',
  int createTime = 1735689700,
  String? abstractText,
  String? range,
  int? chapterUid,
  String? chapterName,
  int star = -1,
}) =>
    WeReadReview(
      reviewId: reviewId,
      content: content,
      createTime: createTime,
      abstractText: abstractText,
      range: range,
      chapterUid: chapterUid,
      chapterName: chapterName,
      star: star,
    );

void main() {
  const builder = WeReadNoteBuilder();

  group('WB 划线 → 笔记', () {
    test('WB-01 正文是引用块 + 页脚 + 标签', () {
      final note = builder.buildHighlightNote(
        notebook: _notebook,
        highlight: _highlight(),
        chapterTitle: '第 1 章 专注的价值',
      );

      expect(note, isNotNull);
      expect(note!.content, contains('> 专注力是稀缺资源。'));
      expect(note.content, contains('—— 《深度工作》 [美] 卡尔·纽波特 · 第 1 章'));
      expect(note.content, endsWith('#微信读书 #深度工作'));
    });

    test('WB-02 多行划线每行都带引用符', () {
      final note = builder.buildHighlightNote(
        notebook: _notebook,
        highlight: _highlight(text: '第一行\n\n第二行'),
      );

      expect(note!.content, contains('> 第一行'));
      expect(note.content, contains('> 第二行'));
      // 连续空行被压掉，中间的空行也变成纯引用符，不留裸空行
      expect(note.content, isNot(contains('> 第一行\n\n> 第二行')));
    });

    test('WB-03 挂在划线上的想法按时间顺序追加', () {
      final note = builder.buildHighlightNote(
        notebook: _notebook,
        highlight: _highlight(),
        inlineReviews: [
          _review(reviewId: 'rv-late', content: '后写的想法', createTime: 200),
          _review(reviewId: 'rv-early', content: '先写的想法', createTime: 100),
        ],
      );

      final content = note!.content;
      expect(content.indexOf('先写的想法'), greaterThan(0));
      expect(
        content.indexOf('先写的想法'),
        lessThan(content.indexOf('后写的想法')),
      );
    });

    test('WB-04 空划线不生成笔记', () {
      expect(
        builder.buildHighlightNote(
          notebook: _notebook,
          highlight: _highlight(text: '   \n  '),
        ),
        isNull,
      );
    });

    test('WB-05 三行以上连续空行压成一行', () {
      final note = builder.buildHighlightNote(
        notebook: _notebook,
        highlight: _highlight(text: '甲\n\n\n\n乙'),
      );

      expect(note!.content, isNot(contains('\n\n\n')));
      expect(note.content, contains('甲'));
      expect(note.content, contains('乙'));
    });
  });

  group('WB 想法 → 笔记', () {
    test('WB-06 有原文的想法先引原文', () {
      final note = builder.buildReviewNote(
        notebook: _notebook,
        review: _review(abstractText: '原文片段', content: '我的想法'),
      );

      expect(note!.content, contains('> 原文片段'));
      expect(note.content, contains('我的想法'));
    });

    test('WB-07 书评带评分行', () {
      final note = builder.buildReviewNote(
        notebook: _notebook,
        review: _review(content: '整本书读完的感觉', star: 4),
      );

      expect(note!.content, contains('评分 4/5'));
    });

    test('WB-08 空想法不生成笔记', () {
      expect(
        builder.buildReviewNote(
          notebook: _notebook,
          review: _review(content: '  '),
        ),
        isNull,
      );
    });
  });

  group('WB 标签清洗', () {
    test('WB-09 去掉空格与常见标点', () {
      expect(WeReadNoteBuilder.bookTag('《深度 工作》'), '深度工作');
      expect(
        WeReadNoteBuilder.bookTag('Sapiens:A Brief History'),
        'SapiensABriefHistory',
      );
      expect(WeReadNoteBuilder.bookTag('《人类简史》（精装）'), '人类简史精装');
    });

    test('WB-10 纯符号书名清空后只留来源标签', () {
      final note = builder.buildHighlightNote(
        notebook: const WeReadNotebook(bookId: '1', title: '《》', author: ''),
        highlight: _highlight(),
      );

      expect(note!.content, endsWith('#微信读书'));
      expect(note.content, isNot(contains('#微信读书 #')));
    });

    test('WB-11 超长书名截断到 24 字', () {
      final long = '书' * 40;
      expect(WeReadNoteBuilder.bookTag(long).length, 24);
    });

    test('WB-12 标签能被子标签提取器识别', () {
      final note = builder.buildHighlightNote(
        notebook: _notebook,
        highlight: _highlight(),
      );

      expect(note!.tags, contains('微信读书'));
      expect(note.tags, contains('深度工作'));
    });
  });

  group('WB 幂等与时间', () {
    test('WB-13 笔记 id 由划线/想法 id 确定性生成', () {
      final first = builder.buildHighlightNote(
        notebook: _notebook,
        highlight: _highlight(bookmarkId: 'abc'),
      );
      final second = builder.buildHighlightNote(
        notebook: _notebook,
        highlight: _highlight(bookmarkId: 'abc', text: '内容变了'),
      );

      expect(first!.id, 'local_wr_bm_abc');
      expect(second!.id, first.id);
      expect(WeReadNoteBuilder.isWeReadNoteId(first.id), isTrue);
    });

    test('WB-14 createTime 转成本地时间，字段值即挂钟时间', () {
      final note = builder.buildHighlightNote(
        notebook: _notebook,
        highlight: _highlight(),
      );

      final expected = DateTime.fromMillisecondsSinceEpoch(1735689600 * 1000);
      expect(note!.createdAt, expected);
      expect(note.createdAt.isUtc, isFalse);
      expect(note.updatedAt, note.createdAt);
    });

    test('WB-15 缺时间时退到 fallbackTime', () {
      final fallback = DateTime(2026, 3, 4, 5, 6);
      final note = builder.buildHighlightNote(
        notebook: _notebook,
        highlight: _highlight(createTime: 0),
        fallbackTime: fallback,
      );

      expect(note!.createdAt, fallback);
    });
  });

  group('WF 读完档案', () {
    int ts(DateTime time) => time.millisecondsSinceEpoch ~/ 1000;

    WeReadBookProgress progressOf({
      int finishTime = 0,
      int startReadingTime = 0,
      int readingTime = 0,
      double percent = 99,
    }) =>
        WeReadBookProgress(
          bookId: '3300001',
          finishTime: finishTime,
          startReadingTime: startReadingTime,
          readingTime: readingTime,
          progress: percent,
        );

    final started = DateTime(2026, 10, 18, 21, 38);
    final finished = DateTime(2026, 10, 27, 21, 38);

    test('WF-01 正文含封面、读完时间、阅读天数、累计时长与标签', () {
      final note = builder.buildFinishedNote(
        bookId: '3300001',
        title: '深度工作',
        author: '卡尔·纽波特',
        coverUrl: 'https://cdn.weread.qq.com/cover.jpg',
        progress: progressOf(
          finishTime: ts(finished),
          startReadingTime: ts(started),
          readingTime: 5601,
        ),
        highlightCount: 3,
        reviewCount: 2,
      );

      expect(note!.id, 'local_wr_fin_3300001');
      expect(WeReadNoteBuilder.isWeReadNoteId(note.id), isTrue);
      expect(
        note.content,
        startsWith('![](https://cdn.weread.qq.com/cover.jpg)'),
      );
      expect(note.content, contains('读完了《深度工作》 · 卡尔·纽波特'));
      expect(note.content, contains('- 读完时间：2026-10-27 21:38'));
      expect(note.content, contains('- 阅读天数：10 天'));
      expect(note.content, contains('2026-10-18 ~ 2026-10-27'));
      expect(note.content, contains('- 累计阅读：1 小时 33 分钟'));
      expect(note.content, contains('- 阅读进度：99%'));
      expect(note.content, contains('- 划线 3 条 · 想法 2 条'));
      expect(note.tags, containsAll(<String>['微信读书', '读完', '深度工作']));
      // 笔记时间落在读完那一刻，首页排序才落在读完那天。
      expect(note.createdAt, finished);
    });

    test('WF-02 没有 finishTime 就不是读完，不生成档案', () {
      final note = builder.buildFinishedNote(
        bookId: '3300001',
        title: '深度工作',
        author: '卡尔·纽波特',
        progress: progressOf(startReadingTime: ts(started)),
      );

      expect(note, isNull);
    });

    test('WF-03 同一天读完算 1 天，不是 0 天', () {
      final note = builder.buildFinishedNote(
        bookId: '3300001',
        title: '深度工作',
        author: '',
        progress: progressOf(
          finishTime: ts(finished),
          startReadingTime: ts(finished.subtract(const Duration(hours: 3))),
          readingTime: 1800,
        ),
      );

      expect(note!.content, contains('- 阅读天数：1 天'));
      expect(note.content, contains('- 累计阅读：30 分钟'));
    });

    test('WF-04 没有开始时间时按 1 天算，且不写起止区间', () {
      final note = builder.buildFinishedNote(
        bookId: '3300001',
        title: '深度工作',
        author: '',
        progress: progressOf(finishTime: ts(finished)),
      );

      expect(note!.content, contains('- 阅读天数：1 天'));
      expect(note.content, isNot(contains('~')));
    });

    test('WF-05 没有封面 / 作者时不留空壳标记', () {
      final note = builder.buildFinishedNote(
        bookId: '3300001',
        title: '深度工作',
        author: '',
        progress: progressOf(finishTime: ts(finished)),
      );

      expect(note!.content, isNot(contains('![](')));
      // 标题行不含作者分隔符（页脚里的「 · 阅读档案」不算）
      expect(note.content, contains('读完了《深度工作》\n'));
    });

    test('WF-06 一本书记完档案后 id 稳定，重复跑命中去重', () {
      final first = builder.buildFinishedNote(
        bookId: '3300001',
        title: '深度工作',
        author: '卡尔·纽波特',
        progress: progressOf(finishTime: ts(finished)),
      );
      final second = builder.buildFinishedNote(
        bookId: '3300001',
        title: '深度工作（新版）',
        author: '卡尔·纽波特',
        progress: progressOf(finishTime: ts(finished)),
      );

      expect(second!.id, first!.id);
    });

    test('WF-07 阅读时长格式化', () {
      expect(WeReadNoteBuilder.formatReadingDuration(0), '');
      expect(WeReadNoteBuilder.formatReadingDuration(30), '不到 1 分钟');
      expect(WeReadNoteBuilder.formatReadingDuration(300), '5 分钟');
      expect(WeReadNoteBuilder.formatReadingDuration(3600), '1 小时');
      expect(WeReadNoteBuilder.formatReadingDuration(3660), '1 小时 1 分钟');
      expect(WeReadNoteBuilder.formatReadingDuration(7260), '2 小时 1 分钟');
    });
  });

  group('WP 阅读回顾', () {
    WeReadPeriodStats statsOf({
      required DateTime start,
      required DateTime end,
      int totalReadTime = 7560,
      int readDays = 4,
    }) =>
        WeReadPeriodStats(
          start: start,
          end: end,
          totalReadTime: totalReadTime,
          readDays: readDays,
          books: const [
            WeReadPeriodBook(title: '长安的荔枝', author: '马伯庸', readTime: 4800),
            WeReadPeriodBook(title: '深度工作', author: '纽波特', readTime: 2400),
          ],
          stats: const {'读过': '2本', '读完': '1本', '笔记': '12条'},
        );

    test('WP-01 周报：标题带区间、排行与标签', () {
      final note = builder.buildPeriodNote(
        weekly: true,
        stats: statsOf(
          start: DateTime(2026, 11, 9),
          end: DateTime(2026, 11, 16),
        ),
      );

      expect(note!.id, 'local_wr_week_20261109');
      expect(note.content, contains('11-09 ~ 11-15 的阅读回顾'));
      expect(note.content, contains('阅读时长：2 小时 6 分钟'));
      expect(note.content, contains('有效阅读：4 天'));
      expect(note.content, contains('读过 2本 · 读完 1本 · 笔记 12条'));
      expect(note.content, contains('- 《长安的荔枝》（马伯庸） 1 小时 20 分钟'));
      expect(note.content, contains('#周报'));
      expect(note.tags, contains('周报'));
      // 时间落在周期最后一刻，首页排序会排在那周之后。
      expect(note.createdAt, DateTime(2026, 11, 15, 23, 59, 59));
    });

    test('WP-02 月报：标题带年月，标签是月报', () {
      final note = builder.buildPeriodNote(
        weekly: false,
        stats: statsOf(
          start: DateTime(2026, 10),
          end: DateTime(2026, 11),
        ),
      );

      expect(note!.id, 'local_wr_month_202610');
      expect(note.content, contains('2026 年 10 月阅读回顾'));
      expect(note.content, contains('#月报'));
      expect(note.tags, contains('月报'));
    });

    test('WP-03 阅读时长为 0 不生成笔记', () {
      final note = builder.buildPeriodNote(
        weekly: true,
        stats: statsOf(
          start: DateTime(2026, 11, 9),
          end: DateTime(2026, 11, 16),
          totalReadTime: 0,
        ),
      );

      expect(note, isNull);
    });

    test('WP-04 同一周期重复生成 id 稳定', () {
      final first = builder.buildPeriodNote(
        weekly: true,
        stats: statsOf(
          start: DateTime(2026, 11, 9),
          end: DateTime(2026, 11, 16),
        ),
      );
      final second = builder.buildPeriodNote(
        weekly: true,
        stats: statsOf(
          start: DateTime(2026, 11, 9),
          end: DateTime(2026, 11, 16),
          totalReadTime: 600,
        ),
      );

      expect(second!.id, first!.id);
    });
  });
}
