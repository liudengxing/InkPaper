import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/providers/app_provider.dart';
import 'package:inkpaper/utils/note_preview_builder.dart';
import 'package:inkpaper/widgets/note_card.dart';
import 'package:inkpaper/widgets/note_preview_text.dart';
import 'package:provider/provider.dart';

Widget _wrap(Widget child) => ChangeNotifierProvider(
      create: (_) => AppProvider(),
      child: MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 390, child: child),
        ),
      ),
    );

String _renderedText(WidgetTester tester) => tester
    .widgetList<RichText>(find.byType(RichText))
    .map((widget) => widget.text.toPlainText())
    .join('\n');

void main() {
  setUp(NotePreviewCache.clear);
  tearDown(NotePreviewCache.clear);

  testWidgets('PCW-01 同一 updatedAt 改写正文后卡片显示新内容', (tester) async {
    final date = DateTime(2026, 11, 20, 9);
    // 关键点：两次的 updatedAt 完全相同。缓存键若拿 updatedAt 当版本号，
    // 这里会命中旧预览，卡片停在「第一版正文」。
    Note note(String content) => Note(
          id: 'edit-in-place',
          content: content,
          createdAt: date,
          updatedAt: date,
        );

    Widget card(String content) => _wrap(
          NoteCard(
            note: note(content),
            onEdit: () {},
            onDelete: () {},
            onPin: () {},
          ),
        );

    await tester.pumpWidget(card('第一版正文'));
    await tester.pumpAndSettle();
    expect(_renderedText(tester), contains('第一版正文'));

    await tester.pumpWidget(card('第二版正文'));
    await tester.pumpAndSettle();
    expect(_renderedText(tester), contains('第二版正文'));
    expect(_renderedText(tester), isNot(contains('第一版正文')));
  });

  testWidgets('PCW-02 命中缓存的预览仍然高亮搜索词', (tester) async {
    const content = '今天在河边散步，顺便记一下**散步**的路线。';
    // 先填满缓存，确保组件拿到的是缓存的同一份预览
    final cached = NotePreviewCache.resolve(content);
    expect(identical(NotePreviewCache.resolve(content), cached), isTrue);

    await tester.pumpWidget(
      _wrap(
        const NotePreviewText(
          content: content,
          style: TextStyle(fontSize: 15, height: 1.6),
          highlightQuery: '散步',
        ),
      ),
    );
    await tester.pumpAndSettle();

    final highlighted = tester
        .widgetList<RichText>(find.byType(RichText))
        .map((widget) => widget.text)
        .expand(_flattenSpans)
        .where(
          (span) =>
              span.toPlainText().contains('散步') &&
              span.style?.backgroundColor != null,
        );

    expect(highlighted, isNotEmpty);
  });

  testWidgets('PCW-03 展开态沿用同一份预览，不重复解析', (tester) async {
    final content = List.generate(10, (index) => '第 $index 段').join('\n\n');

    await tester.pumpWidget(
      _wrap(
        NotePreviewText(
          content: content,
          style: const TextStyle(fontSize: 15, height: 1.6),
          maxLines: 3,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(NotePreviewCache.entryCount, 1);

    // 展开只改 maxLines，parseLimit 不变，缓存里仍是同一条
    await tester.pumpWidget(
      _wrap(
        NotePreviewText(
          content: content,
          style: const TextStyle(fontSize: 15, height: 1.6),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(NotePreviewCache.entryCount, 1);
    expect(_renderedText(tester), contains('第 9 段'));
  });

  testWidgets('切换行数复用富文本，待办回调仍跟随当前组件', (tester) async {
    final calls = <String>[];
    Widget preview({int? lines, String? highlight, String? callback}) => _wrap(
          NotePreviewText(
            content: '- [ ] 检查待办\n\n第二段 #工作',
            style: const TextStyle(fontSize: 15),
            maxLines: lines,
            highlightQuery: highlight,
            onCheckboxTap: callback == null
                ? null
                : (index) => calls.add('$callback$index'),
          ),
        );

    TextSpan span() => tester
        .widgetList<Text>(
          find.descendant(
            of: find.byType(NotePreviewText),
            matching: find.byType(Text),
          ),
        )
        .single
        .textSpan! as TextSpan;

    await tester.pumpWidget(preview(lines: 1, callback: '旧'));
    final original = span();
    await tester.pumpWidget(preview(callback: '展开'));
    expect(span(), same(original));
    await tester.pumpWidget(preview(lines: 1, callback: '收起'));
    expect(span(), same(original));
    final checkbox = _flattenSpans(span()).singleWhere(
      (piece) => piece.recognizer is TapGestureRecognizer,
    );
    (checkbox.recognizer! as TapGestureRecognizer).onTap!();
    expect(calls, ['收起0']);

    await tester.pumpWidget(preview(lines: 1, highlight: '第二段'));
    expect(span(), isNot(same(original)));
    expect(
      _flattenSpans(span()).any((piece) => piece.recognizer != null),
      isFalse,
    );
    expect(
      _flattenSpans(span())
          .any((piece) => piece.style?.backgroundColor != null),
      isTrue,
    );
  });
}

Iterable<TextSpan> _flattenSpans(InlineSpan span) sync* {
  if (span is TextSpan) {
    yield span;
    for (final child in span.children ?? const <InlineSpan>[]) {
      yield* _flattenSpans(child);
    }
  }
}
