import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/utils/notes_context_builder.dart';

void main() {
  group('NotesContextBuilder.extractQueryTerms', () {
    test('把中文问题切成 2-gram 并过滤无区分度的词', () {
      final terms = NotesContextBuilder.extractQueryTerms('我这周主要在关注什么？');
      expect(terms, isNot(contains('什么')));
      expect(terms, isNot(contains('这周')));
      expect(terms, contains('关注'));
    });

    test('保留英文与数字关键词', () {
      final terms = NotesContextBuilder.extractQueryTerms('flutter 布局 3.0 的问题');
      expect(terms, contains('flutter'));
      expect(terms, contains('3.0'));
    });

    test('只有虚词时返回空，让调用方回退到按时间取', () {
      expect(NotesContextBuilder.extractQueryTerms('最近怎么样？'), isEmpty);
    });
  });

  group('NotesContextBuilder.buildForQuestion', () {
    test('很久以前的相关笔记能被检索出来，不被最近笔记挤掉', () {
      final notes = <Note>[
        _note(
          id: 'old',
          content: '今天跑了人生第一个半程马拉松，2 小时 05 分，最后 3 公里抽筋。',
          createdAt: DateTime(2024, 3, 10),
        ),
        // 一堆无关的近况，把预算和时间窗口都占满
        for (var i = 0; i < 60; i++)
          _note(
            id: 'recent$i',
            content: '日常记录 $i：处理邮件、开会、整理周报。',
            createdAt: DateTime.now().subtract(Duration(days: i % 20)),
          ),
      ];

      final context = NotesContextBuilder.buildForQuestion(
        notes,
        '我跑马拉松那次成绩怎么样？',
        maxNotes: 20,
        maxCharacters: 4000,
      );

      expect(context.relevantCount, greaterThan(0));
      expect(context.text, contains('马拉松'));
      // 相关笔记单独成区块，且排在最近笔记之前
      expect(
        context.text.indexOf('【与问题相关的笔记】'),
        lessThan(context.text.indexOf('【最近的笔记】')),
      );
    });

    test('标签命中优先于正文里偶然提一句', () {
      final notes = <Note>[
        _note(
          id: 'tagged',
          content: '今天练了背，划船 4 组。',
          tags: const ['运动记录'],
          createdAt: DateTime.now().subtract(const Duration(days: 40)),
        ),
        _note(
          id: 'mention',
          content: '和朋友聊天，他说最近运动记录都断了，我笑笑没接话。',
          createdAt: DateTime.now().subtract(const Duration(days: 1)),
        ),
      ];

      final context = NotesContextBuilder.buildForQuestion(
        notes,
        '运动记录里我练了哪些动作？',
      );

      final taggedIndex = context.text.indexOf('划船 4 组');
      final mentionIndex = context.text.indexOf('我笑笑没接话');
      expect(taggedIndex, isNonNegative);
      expect(
        taggedIndex < mentionIndex || mentionIndex == -1,
        isTrue,
        reason: '带运动记录标签的笔记应排在仅正文提及的笔记之前',
      );
    });

    test('问题没有可用关键词时退化为按时间取最近笔记', () {
      final notes = <Note>[
        _note(
          id: 'a',
          content: '今天写了点东西。',
          createdAt: DateTime.now(),
        ),
      ];

      final context = NotesContextBuilder.buildForQuestion(notes, '嗯？');
      expect(context.noteCount, 1);
      expect(context.relevantCount, 0);
      expect(context.text, isNot(contains('【与问题相关的笔记】')));
    });
  });

  group('NotesContextBuilder.stripMedia', () {
    test('剔除图片与附件链接，保留正文', () {
      final plain = NotesContextBuilder.stripMedia(
        '今天爬山 ![图片](file:///a.jpg) 很爽\n[录音](file:///a.m4a)\n',
      );
      expect(plain, isNot(contains('jpg')));
      expect(plain, isNot(contains('m4a')));
      expect(plain, contains('今天爬山'));
    });
  });
}

Note _note({
  required String id,
  required String content,
  DateTime? createdAt,
  List<String>? tags,
}) {
  final time = createdAt ?? DateTime.now();
  return Note(
    id: id,
    content: content,
    createdAt: time,
    updatedAt: time,
    tags: tags ?? const [],
  );
}
