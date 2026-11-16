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
}
