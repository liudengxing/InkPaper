import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/widgets/note_preview_text.dart';

/// 详情页正文与编辑页输入框必须是同一套排版。
///
/// 编辑页正文就是一个普通 `TextField`：字号 15、行高 1.6（行高 24），
/// 段落之间的空行占满一整行。详情页如果沿用卡片预览的「压到 8px」，
/// 同一条笔记在浏览态会比编辑态紧一截，点进编辑像被重新排版了一次。
const TextStyle _bodyStyle = TextStyle(
  fontSize: 15,
  height: 1.6,
  letterSpacing: 0.15,
);

/// 单行高：15 × 1.6。
const double _lineHeight = 24;

Widget _wrap(Widget child) => MaterialApp(
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Align(alignment: Alignment.topLeft, child: child),
        ),
      ),
    );

Future<double> _heightOf(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(_wrap(child));
  await tester.pumpAndSettle();
  return tester.getSize(find.byType(NotePreviewText)).height;
}

void main() {
  testWidgets('详情页的段落空行占满一整行，与编辑页一致', (tester) async {
    const content = '第一段。\n\n第二段。';

    final detailHeight = await _heightOf(
      tester,
      const NotePreviewText(
        content: content,
        style: _bodyStyle,
        compactBlankLines: false,
      ),
    );
    // 两段文字 + 一个完整空行 = 3 行
    expect(detailHeight, _lineHeight * 3);
  });

  testWidgets('卡片预览仍然紧凑，空行压到 8px', (tester) async {
    const content = '第一段。\n\n第二段。';

    final cardHeight = await _heightOf(
      tester,
      const NotePreviewText(content: content, style: _bodyStyle),
    );
    // 两行文字 + 一个 8px 的空行
    expect(cardHeight, _lineHeight * 2 + 8);
  });

  testWidgets('详情页传全文上限时不再截断长笔记', (tester) async {
    final long = '${'很长的正文内容。' * 700}结尾标记ABC';
    await tester.pumpWidget(
      _wrap(
        NotePreviewText(
          content: long,
          style: _bodyStyle,
          compactBlankLines: false,
          parseLimit: long.length,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final rendered =
        tester.widget<Text>(find.byType(Text).first).textSpan!.toPlainText();
    expect(rendered.length, long.length);
    expect(rendered.endsWith('结尾标记ABC'), isTrue);
  });
}
