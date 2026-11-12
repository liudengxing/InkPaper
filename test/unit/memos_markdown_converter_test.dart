import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/utils/memos_markdown_converter.dart';

void main() {
  group('MemosMarkdownConverter', () {
    test('normalizes loose strong delimiters for display', () {
      final converter = MemosMarkdownConverter();

      expect(
        converter.convert('**GTA5 Mods **'),
        '**GTA5 Mods** ',
      );
    });

    test('does not normalize loose strong delimiters inside code fences', () {
      final converter = MemosMarkdownConverter();

      const content = '''
```dart
final value = "**GTA5 Mods **";
```
''';

      expect(converter.convert(content), content);
    });

    test('keeps bare urls unchanged for display rendering', () {
      final converter = MemosMarkdownConverter();

      expect(
        converter.convert('网站\nhttps://gpt-agent.cc/v1'),
        '网站\nhttps://gpt-agent.cc/v1',
      );
    });

    test('preserves inline bare url position', () {
      final converter = MemosMarkdownConverter();

      expect(
        converter.convert('模型地址：claude-sonnet-4-6 https://gpt-agent.cc/v1'),
        '模型地址：claude-sonnet-4-6 https://gpt-agent.cc/v1',
      );
    });

    test('does not convert existing markdown links or code spans', () {
      final converter = MemosMarkdownConverter();

      expect(
        converter.convert('[官网](https://gpt-agent.cc/v1)'),
        '[官网](https://gpt-agent.cc/v1)',
      );
      expect(
        converter.convert('`https://gpt-agent.cc/v1`'),
        '`https://gpt-agent.cc/v1`',
      );
    });

    test('does not convert bare urls inside code fences', () {
      final converter = MemosMarkdownConverter();

      const content = '''
```
https://gpt-agent.cc/v1
```
''';

      expect(converter.convert(content), content);
    });

    test('converts tags to same-text markdown links outside urls and code', () {
      final converter = MemosMarkdownConverter();

      expect(
        converter.convert('#AI https://example.com/#section `#code`'),
        '[#AI](#AI) https://example.com/#section `#code`',
      );
    });

    group('setext 下划线降级为分隔线', () {
      final converter = MemosMarkdownConverter();

      test('正文下面紧跟减号串时补空行，避免整段变成 h2', () {
        expect(
          converter.convert('❶文字段落。\n-----------\n【我做的】：内容'),
          '❶文字段落。\n\n-----------\n【我做的】：内容',
        );
      });

      test('`- - -` 这种带空格的分隔线同样处理', () {
        expect(
          converter.convert('文字\n- - -\n内容'),
          '文字\n\n- - -\n内容',
        );
      });

      test('已经有空行的分隔线保持原样', () {
        const content = '文字\n\n---\n\n内容';
        expect(converter.convert(content), content);
      });

      test('减号与文字同处一行时不动', () {
        const content = '文字-----------文字';
        expect(converter.convert(content), content);
      });

      test('两个减号不动，避免影响嵌套列表', () {
        const content = '文字\n--\n内容';
        expect(converter.convert(content), content);
      });

      test('代码围栏内的减号不动', () {
        const content = '''
```dart
文字
---
```
''';
        expect(converter.convert(content), content);
      });

      test('文件开头的属性区（frontmatter）不受影响', () {
        expect(
          converter.convert('---\ntitle: x\n---\n正文\n---\n'),
          '---\ntitle: x\n---\n正文\n\n---\n',
        );
      });
    });
  });
}
