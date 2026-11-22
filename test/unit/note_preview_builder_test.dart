import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/utils/note_preview_builder.dart';

void main() {
  group('buildNotePreview', () {
    test('剥掉加粗标记但保留样式区间', () {
      final preview = buildNotePreview('这是**重点**内容');

      expect(preview.text, '这是重点内容');
      expect(preview.ranges, hasLength(1));
      expect(preview.ranges.single.styles, contains(PreviewInlineStyle.bold));
      expect(preview.ranges.single.start, 2);
      expect(preview.ranges.single.end, 4);
    });

    test('标题只加粗，不保留 # 标记', () {
      final preview = buildNotePreview('# 周会纪要\n正文');

      expect(preview.text.contains('#'), isFalse);
      expect(preview.text, contains('周会纪要'));
      expect(
        preview.ranges.any(
          (range) => range.styles.contains(PreviewInlineStyle.bold),
        ),
        isTrue,
      );
    });

    test('行内代码与删除线各自产生区间', () {
      final preview = buildNotePreview('跑 `flutter test` 再 ~~删掉~~');

      expect(preview.text, contains('flutter test'));
      expect(preview.text.contains('`'), isFalse);
      expect(
        preview.ranges.any(
          (range) => range.styles.contains(PreviewInlineStyle.code),
        ),
        isTrue,
      );
      expect(
        preview.ranges.any(
          (range) => range.styles.contains(PreviewInlineStyle.strike),
        ),
        isTrue,
      );
    });

    test('图片从正文移除并保留图片数量语义', () {
      final preview = buildNotePreview('看图\n![封面](https://a.com/1.png)\n结束');

      expect(preview.text.contains('!['), isFalse);
      expect(preview.text, contains('看图'));
      expect(preview.text, contains('结束'));
    });

    test('待办转成勾选字符并记录偏移与顺序', () {
      final preview = buildNotePreview('- [ ] 买牛奶\n- [x] 交房租');

      expect(preview.text, contains('☐'));
      expect(preview.text, contains('☑'));
      expect(preview.checkboxes, hasLength(2));
      expect(preview.checkboxes[0].checked, isFalse);
      expect(preview.checkboxes[1].checked, isTrue);
      expect(preview.text[preview.checkboxes[0].offset], '☐');
      expect(preview.text[preview.checkboxes[1].offset], '☑');
    });

    test('站内引用降级为可读占位或自定义文本', () {
      final withAlias = buildNotePreview('参考 [[abc?text=读书笔记]] 这页');
      expect(withAlias.text, contains('读书笔记'));
      expect(withAlias.text.contains('[['), isFalse);

      final bare = buildNotePreview('参考 [[abc123]]');
      expect(bare.text, contains('引用笔记'));
    });

    test('段落之间保留一个空行作为段间距', () {
      final preview = buildNotePreview('第一段\n\n\n\n第二段');

      expect(preview.text, '第一段\n\n第二段');
      expect(preview.spacerOffsets, hasLength(1));
      expect(preview.text[preview.spacerOffsets.single], '\n');
    });

    test('列表项之间只换行，不插入段间距空行', () {
      final preview = buildNotePreview('- 第一项\n- 第二项');

      expect(preview.text, '- 第一项\n- 第二项');
      expect(preview.text.contains('\n\n'), isFalse);
      expect(preview.spacerOffsets, isEmpty);
    });

    test('无序列表补回减号，与编辑页原文一致', () {
      final preview = buildNotePreview('- 苹果\n- 香蕉');

      expect(preview.text, '- 苹果\n- 香蕉');
    });

    test('有序列表补回序号，并尊重起始编号', () {
      expect(
        buildNotePreview('1. 第一\n2. 第二').text,
        '1. 第一\n2. 第二',
      );
      expect(
        buildNotePreview('3. 第三\n4. 第四').text,
        '3. 第三\n4. 第四',
      );
    });

    test('嵌套列表按层级缩进两格', () {
      final preview = buildNotePreview('- 香蕉\n  - 富士\n  - 香蕉品种');

      expect(preview.text, '- 香蕉\n  - 富士\n  - 香蕉品种');
      expect(preview.text.contains('\n\n'), isFalse);
    });

    test('待办项不再重复补减号', () {
      final preview = buildNotePreview('- [ ] 买牛奶\n- [x] 交房租');

      expect(preview.text, '☐ 买牛奶\n☑ 交房租');
      expect(preview.text.contains('- ☐'), isFalse);
      expect(preview.checkboxes, hasLength(2));
    });

    test('空内容返回空预览', () {
      expect(buildNotePreview('').isEmpty, isTrue);
      expect(buildNotePreview('   ').isEmpty, isTrue);
    });
  });

  group('NotePreviewCache', () {
    test('相同内容只解析一次', () {
      NotePreviewCache.clear();
      final first = NotePreviewCache.resolve('缓存**测试**');
      final second = NotePreviewCache.resolve('缓存**测试**');

      expect(identical(first, second), isTrue);
      expect(NotePreviewCache.hitRate, greaterThan(0));
    });

    test('不同内容互不干扰', () {
      NotePreviewCache.clear();
      final a = NotePreviewCache.resolve('**粗**');
      final b = NotePreviewCache.resolve('*斜*');

      expect(a.text, '粗');
      expect(b.text, '斜');
    });

    test('同一内容不同解析上限各缓存一份，长文本不被短预览顶掉', () {
      NotePreviewCache.clear();
      final long = '很长的正文。' * 600;

      final card = NotePreviewCache.resolve(long);
      final detail = NotePreviewCache.resolve(
        long,
        parseLimit: long.length,
      );

      expect(card.text.length, lessThanOrEqualTo(defaultPreviewParseLimit));
      expect(detail.text, long);
      expect(identical(card, detail), isFalse);
      // 再取短预览仍是短的那份，说明两个 key 没有互相覆盖
      expect(NotePreviewCache.resolve(long).text, card.text);
    });
  });
}
