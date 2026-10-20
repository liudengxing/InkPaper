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

    test('块之间最多一个换行，不产生大段空白', () {
      final preview = buildNotePreview('第一段\n\n\n\n第二段');

      expect(preview.text.contains('\n\n'), isFalse);
      expect(preview.text, contains('第一段'));
      expect(preview.text, contains('第二段'));
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
  });
}
