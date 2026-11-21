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
          content: '今天写了点东西，记一笔今天的想法。',
          createdAt: DateTime.now(),
        ),
      ];

      final context = NotesContextBuilder.buildForQuestion(notes, '嗯？');
      expect(context.noteCount, 1);
      expect(context.relevantCount, 0);
      expect(context.text, isNot(contains('【与问题相关的笔记】')));
    });
  });

  group('NotesContextBuilder.buildForInsight', () {
    test('笔记远多于上限时，早年记录仍然进得了上下文', () {
      // 2022 年的两条 + 最近三年各几百条：只取「最近 N 条」的话早年必被挤掉。
      final notes = <Note>[
        _note(
          id: 'old-2022',
          content: '2022 年在杭州租的第一间房子，阳台朝北，冬天很冷。',
          createdAt: DateTime(2022, 5),
        ),
        _note(
          id: 'old-2022-b',
          content: '2022 年冬天开始每天走一万步，坚持了四十天。',
          createdAt: DateTime(2022, 12, 20),
        ),
        for (var i = 0; i < 300; i++)
          _note(
            id: 'recent$i',
            content: '近期记录 $i：开会、写周报、改 bug。',
            createdAt: DateTime(2026).subtract(Duration(days: i % 300)),
          ),
      ];

      final context = NotesContextBuilder.buildForInsight(
        notes,
        maxNotes: 30,
        maxCharacters: 8000,
      );

      expect(context.noteCount, 30);
      expect(context.text, contains('阳台朝北'));
      // 编号仍然是「1 = 最近」，分层取样不能把时间顺序打乱
      expect(context.earliest, isNotNull);
      expect(context.latest, isNotNull);
      expect(context.latest!.isAfter(context.earliest!), isTrue);
    });

    test('条数没超上限时原样全给，不做分层', () {
      final notes = <Note>[
        for (var i = 0; i < 5; i++)
          _note(
            id: 'n$i',
            content: '第 $i 条记录，写了一句不长不短的想法。',
            createdAt: DateTime(2025, 1, 1 + i),
          ),
      ];

      final context = NotesContextBuilder.buildForInsight(notes, maxNotes: 30);

      expect(context.noteCount, 5);
      expect(context.truncated, isFalse);
    });

    test('条数上限 100：库里有 260 条也只抽 100 条', () {
      final notes = <Note>[
        for (var i = 0; i < 260; i++)
          _note(
            id: 'n$i',
            content: '第 $i 条记录，写了一句不长不短的想法。',
            createdAt: DateTime(2024).add(Duration(days: i)),
          ),
      ];

      final context = NotesContextBuilder.buildForInsight(notes);

      expect(context.noteCount, 100);
      expect(context.truncated, isTrue);
    });

    test('单条截断 400 字，来源标记 truncated', () {
      final longText = '这是一段很长的反思。' * 80;
      final context = NotesContextBuilder.buildForInsight([
        _note(
          id: 'long',
          content: longText,
          createdAt: DateTime(2025, 6),
        ),
      ]);

      expect(context.text, isNot(contains(longText)));
      expect(context.text, contains('…'));
      expect(context.sources.single.truncated, isTrue);
      expect(context.sources.single.text.length, lessThanOrEqualTo(401));
    });

    test('字数预算仍是硬闸门：见底后整条放弃，不放半截', () {
      final notes = <Note>[
        for (var i = 0; i < 20; i++)
          _note(
            id: 'n$i',
            content: '第 $i 条，${'内容' * 30}',
            createdAt: DateTime(2025, 1, 1 + i),
          ),
      ];

      final context = NotesContextBuilder.buildForInsight(
        notes,
        maxCharacters: 400,
      );

      expect(context.noteCount, lessThan(20));
      expect(context.truncated, isTrue);
    });

    test('短于 10 字的笔记不参与抽样', () {
      final context = NotesContextBuilder.buildForInsight([
        _note(id: 'tiny', content: '嗯', createdAt: DateTime(2026)),
        _note(id: 'emoji', content: '🙂🙂', createdAt: DateTime(2026, 1, 2)),
        _note(
          id: 'ok',
          content: '这是一条字数够用的笔记。',
          createdAt: DateTime(2026, 1, 3),
        ),
      ]);

      expect(context.noteCount, 1);
      expect(context.sources.single.noteId, 'ok');
    });

    test('时间权重：近期笔记抽得更多，但早年季度仍有代表', () {
      final now = DateTime.now();
      final notes = <Note>[
        // 今年两个季度各 10 条
        for (var i = 0; i < 10; i++)
          _note(
            id: 'recent-q1-$i',
            content: '今年上半年第 $i 条记录，写了点关于当下的想法。',
            createdAt: DateTime(now.year, 3, 1 + i),
          ),
        for (var i = 0; i < 10; i++)
          _note(
            id: 'recent-q3-$i',
            content: '今年下半年第 $i 条记录，写了点关于当下的想法。',
            createdAt: DateTime(now.year, 9, 1 + i),
          ),
        // 四年前一个季度 10 条
        for (var i = 0; i < 10; i++)
          _note(
            id: 'old-$i',
            content: '四年前第 $i 条记录，写了点关于过去的想法。',
            createdAt: DateTime(now.year - 4, 6, 1 + i),
          ),
      ];

      final context = NotesContextBuilder.buildForInsight(
        notes,
        maxNotes: 21,
      );

      final recent =
          context.sources.where((s) => s.noteId.startsWith('recent')).length;
      final old =
          context.sources.where((s) => s.noteId.startsWith('old')).length;
      expect(recent, greaterThan(old), reason: '近桶每轮取 3 条，应多于早桶的 1 条');
      expect(old, greaterThan(0), reason: '早年季度每轮保底 1 条，不能被挤掉');
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

  group('InsightSource 图片', () {
    test('喂给模型的正文剥掉图片，但来源里留着图片路径', () {
      final context = NotesContextBuilder.buildForInsight([
        _note(
          id: 'with-image',
          content: '今天爬山，山顶风很大\n\n![](file:///cache/a.jpg)',
          createdAt: DateTime(2026, 1, 2),
        ),
      ]);

      // 模型不该看到 file:// 这种本地路径
      expect(context.text, isNot(contains('file://')));
      expect(context.text, isNot(contains('![')));
      expect(context.text, contains('今天爬山'));

      // 角标弹层要能把它画出来
      expect(context.sources, hasLength(1));
      expect(
        context.sources.single.imagePaths,
        contains('file:///cache/a.jpg'),
      );
    });

    test('纯图片笔记不进上下文，也不会出现在来源里', () {
      final context = NotesContextBuilder.buildForInsight([
        _note(
          id: 'image-only',
          content: '![](file:///cache/b.jpg)',
          createdAt: DateTime(2026, 1, 3),
        ),
        _note(
          id: 'text',
          content: '只有这一条有文字内容，其余都是图片。',
          createdAt: DateTime(2026, 1, 4),
        ),
      ]);

      expect(context.sources, hasLength(1));
      expect(context.sources.single.noteId, 'text');
    });
  });

  group('NotesContextBuilder.buildForInsight 默认排除标签', () {
    test('阅读同步与周报不进洞察，正文里的标签同样认', () {
      final context = NotesContextBuilder.buildForInsight([
        _note(
          id: 'normal',
          content: '今天想明白一件事：先把注意力收回来，别急着做决定。',
          createdAt: DateTime(2026, 1, 8),
        ),
        _note(
          id: 'wr',
          content: '这是一段划线摘录 #微信读书',
          createdAt: DateTime(2026, 1, 7),
        ),
        _note(
          id: 'read',
          content: '这是一条阅读记录摘录',
          tags: const <String>['阅读记录'],
          createdAt: DateTime(2026, 1, 6),
        ),
        _note(
          id: 'finished',
          content: '这本书终于读完了，记一笔档案',
          tags: const <String>['读完'],
          createdAt: DateTime(2026, 1, 5),
        ),
        _note(
          id: 'weekly',
          content: '这一周的阅读时长统计',
          tags: const <String>['周报'],
          createdAt: DateTime(2026, 1, 4),
        ),
      ]);

      expect(context.noteCount, 1);
      expect(context.sources.single.noteId, 'normal');
      expect(context.text, isNot(contains('微信读书')));
      expect(context.text, isNot(contains('阅读记录')));
    });

    test('传空集合可以关掉默认排除', () {
      final context = NotesContextBuilder.buildForInsight(
        [
          _note(
            id: 'normal',
            content: '今天想明白一件事：先把注意力收回来，别急着做决定。',
            createdAt: DateTime(2026, 1, 8),
          ),
          _note(
            id: 'wr',
            content: '这是一段划线摘录 #微信读书',
            createdAt: DateTime(2026, 1, 7),
          ),
        ],
        excludedTags: const <String>{},
      );

      expect(context.noteCount, 2);
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
