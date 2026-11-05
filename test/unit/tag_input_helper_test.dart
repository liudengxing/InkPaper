// ============================================================
// L2 测试 · TagInputHelper（utils/tag_input_helper.dart）
//
// 「光标是否在 #标签里」「候选怎么排」「插入后光标在哪」原先都是
// note_editor.dart 里的内联代码，抽出来后在这里钉住边界。
// ============================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/utils/tag_input_helper.dart';

void main() {
  group('detectTagPrefix', () {
    test('TI-01 光标在 0 或文本为空时不算标签输入', () {
      expect(detectTagPrefix(text: '', cursorPosition: 0), isNull);
      expect(detectTagPrefix(text: '#abc', cursorPosition: 0), isNull);
    });

    test('TI-02 文本里没有 # 时返回 null', () {
      expect(detectTagPrefix(text: 'hello world', cursorPosition: 11), isNull);
    });

    test('TI-03 正常输入前缀', () {
      final result = detectTagPrefix(text: 'hello #ja', cursorPosition: 9);
      expect(result, isNotNull);
      expect(result!.start, 6);
      expect(result.prefix, 'ja');
    });

    test('TI-04 刚敲完 # 时前缀为空串', () {
      final result = detectTagPrefix(text: 'hello #', cursorPosition: 7);
      expect(result, isNotNull);
      expect(result!.start, 6);
      expect(result.prefix, isEmpty);
    });

    test('TI-05 行首的 # 也算', () {
      final result = detectTagPrefix(text: '#ab', cursorPosition: 3);
      expect(result, isNotNull);
      expect(result!.start, 0);
      expect(result.prefix, 'ab');
    });

    test('TI-06 中间有空格时不算（# 已被空格截断）', () {
      expect(
        detectTagPrefix(text: '#foo bar', cursorPosition: 8),
        isNull,
      );
    });

    test('TI-07 换行会截断标签', () {
      expect(
        detectTagPrefix(text: '#foo\nbar', cursorPosition: 8),
        isNull,
      );
    });

    test('TI-08 跨行时能识别后一行的 #', () {
      final result = detectTagPrefix(text: 'x\n#ab', cursorPosition: 5);
      expect(result, isNotNull);
      expect(result!.start, 2);
      expect(result.prefix, 'ab');
    });

    test('TI-09 光标越界时返回 null 而不是抛异常', () {
      expect(detectTagPrefix(text: 'abc', cursorPosition: 99), isNull);
      expect(detectTagPrefix(text: 'abc', cursorPosition: -1), isNull);
    });

    test('TI-10 只取光标之前的 # ，光标后的不算', () {
      // 光标在 # 之前
      expect(detectTagPrefix(text: 'ab#cd', cursorPosition: 2), isNull);
    });
  });

  group('rankTagSuggestions', () {
    final allTags = ['java', 'javascript', 'JavaEE', 'golang', 'python'];

    test('TI-11 前缀为空时给前 limit 个', () {
      final result = rankTagSuggestions(allTags: allTags, prefix: '');
      expect(result, hasLength(5));
      expect(result.first, 'java');
    });

    test('TI-12 完全匹配排最前，其次前缀匹配，最后包含匹配', () {
      final result = rankTagSuggestions(allTags: allTags, prefix: 'java');
      // 完全匹配 java → 前缀匹配 javascript / JavaEE（大小写不敏感）
      expect(result.first, 'java');
      expect(result.sublist(1, 3), containsAll(['javascript', 'JavaEE']));
    });

    test('TI-13 包含匹配也能命中', () {
      final result = rankTagSuggestions(allTags: allTags, prefix: 'thon');
      expect(result, contains('python'));
    });

    test('TI-14 大小写不敏感，但返回原始写法', () {
      final result = rankTagSuggestions(allTags: allTags, prefix: 'javaee');
      expect(result, contains('JavaEE'));
    });

    test('TI-15 limit 生效', () {
      final many = List.generate(30, (i) => 'tag$i');
      final result = rankTagSuggestions(
        allTags: many,
        prefix: 'tag',
        limit: 8,
      );
      expect(result, hasLength(8));
    });

    test('TI-16 没有匹配时返回空列表', () {
      final result = rankTagSuggestions(allTags: allTags, prefix: 'zzz');
      expect(result, isEmpty);
    });
  });

  group('applyTagInsertion', () {
    test('TI-17 普通插入：替换 # 到光标的内容并补空格', () {
      // "hello #ja"，光标在末尾
      final result = applyTagInsertion(
        text: 'hello #ja',
        cursorPosition: 9,
        tagStart: 6,
        tag: 'java',
      );
      expect(result.text, 'hello #java ');
      expect(result.cursor, 12);
      expect(result.text.length, result.cursor);
    });

    test('TI-18 # 前面紧邻字母时补一个空格', () {
      final result = applyTagInsertion(
        text: 'abc#ja',
        cursorPosition: 6,
        tagStart: 3,
        tag: 'java',
      );
      expect(result.text, 'abc #java ');
      expect(result.cursor, 10);
    });

    test('TI-19 # 前面是中文时也补空格', () {
      final result = applyTagInsertion(
        text: '笔记#ja',
        cursorPosition: 4,
        tagStart: 2,
        tag: 'java',
      );
      expect(result.text, startsWith('笔记 #java '));
    });

    test('TI-20 行首 # 不补空格', () {
      final result = applyTagInsertion(
        text: '#ja',
        cursorPosition: 3,
        tagStart: 0,
        tag: 'java',
      );
      expect(result.text, '#java ');
      expect(result.cursor, 6);
    });

    test('TI-21 光标后面还有内容时原样保留', () {
      final result = applyTagInsertion(
        text: 'hello #ja world',
        cursorPosition: 9,
        tagStart: 6,
        tag: 'java',
      );
      expect(result.text, 'hello #java  world');
    });

    test('TI-22 只有 # 没输前缀也能插入', () {
      final result = applyTagInsertion(
        text: '#',
        cursorPosition: 1,
        tagStart: 0,
        tag: 'java',
      );
      expect(result.text, '#java ');
    });
  });
}
