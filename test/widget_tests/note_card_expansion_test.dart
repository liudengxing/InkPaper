import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/providers/app_provider.dart';
import 'package:inkpaper/widgets/note_card.dart';
import 'package:inkpaper/widgets/note_preview_text.dart';
import 'package:provider/provider.dart';

Widget _wrap(Widget child) => ChangeNotifierProvider(
      create: (_) => AppProvider(),
      child: MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 390,
            child: child,
          ),
        ),
      ),
    );

void main() {
  group('NoteCard expansion', () {
    testWidgets(
      'hides full text control for short rendered text with long link source',
      (tester) async {
        final longUrl = 'https://example.com/${List.filled(120, 'a').join()}';
        final note = Note(
          id: 'short-link',
          content: '''
一个苹果端TG的第三方软件，TF测试名额获取
https://testflight.apple.com/join/e1v9O7jC
[Message link]($longUrl)
''',
          createdAt: DateTime(2026, 12, 12, 16, 18),
          updatedAt: DateTime(2026, 12, 12, 16, 18),
          resourceList: [
            {'uid': 'res-1', 'type': 'image/png', 'filename': 'cover.png'},
          ],
        );

        await tester.pumpWidget(
          _wrap(
            NoteCard(
              note: note,
              onEdit: () {},
              onDelete: () {},
              onPin: () {},
            ),
          ),
        );
        await tester.pumpAndSettle();

        final renderedText = tester
            .widgetList<RichText>(find.byType(RichText))
            .map((widget) => widget.text.toPlainText())
            .join('\n');

        expect(renderedText, contains('Message link'));
        expect(find.text('展开'), findsNothing);
      },
    );

    testWidgets(
      'hides full text control when only trailing metadata exceeds line limit',
      (tester) async {
        final note = Note(
          id: 'quote-metadata',
          content: '''
> 成长的代价就是失去原有的样子，不管你现在混成什么样子，都要觉得自己前途无量，没人扶的时候，自己要站稳，路是走出来的，越低谷的时候越要撑起自己，要赢得起，也要输得起，一直在学走路，总有一天会站起来，成长会把你们带动下一个旅程。

#微信读书 #权力巅峰 1+2全本 苹果导入番茄看（1）
''',
          createdAt: DateTime(2026, 12, 10, 20, 52),
          updatedAt: DateTime(2026, 12, 10, 20, 52),
        );

        await tester.pumpWidget(
          _wrap(
            NoteCard(
              note: note,
              onEdit: () {},
              onDelete: () {},
              onPin: () {},
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('展开'), findsNothing);
      },
    );

    testWidgets('renders text when the note only contains underline markup',
        (tester) async {
      final note = Note(
        id: 'underline-only',
        content: '<u>主页下划线文字不能消失</u>',
        createdAt: DateTime(2026, 12, 10, 20, 52),
        updatedAt: DateTime(2026, 12, 10, 20, 52),
      );

      await tester.pumpWidget(
        _wrap(
          NoteCard(
            note: note,
            onEdit: () {},
            onDelete: () {},
            onPin: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      final renderedText = tester
          .widgetList<RichText>(find.byType(RichText))
          .map((widget) => widget.text.toPlainText())
          .join('\n');

      expect(renderedText, contains('主页下划线文字不能消失'));

      // 根 TextSpan 的 plainText 也等于整段文本，因此按「文本 + 下划线」组合定位，
      // 而不是假设只有一个同名 span。
      final underlineSpans = tester
          .widgetList<RichText>(find.byType(RichText))
          .map((widget) => widget.text)
          .expand(_flattenSpans)
          .where(
            (span) =>
                span.toPlainText() == '主页下划线文字不能消失' &&
                span.style?.decoration == TextDecoration.underline,
          );
      expect(underlineSpans, isNotEmpty);
    });
    testWidgets('expands and collapses the rendered body', (tester) async {
      final date = DateTime(2026);
      final note = Note(
        id: 'long-text',
        content: List.generate(7, (index) => '正文第 $index 段').join('\n\n'),
        createdAt: date,
        updatedAt: date,
      );
      await tester.pumpWidget(
        _wrap(
          NoteCard(note: note, onEdit: () {}, onDelete: () {}, onPin: () {}),
        ),
      );
      NotePreviewText preview() => tester.widget(find.byType(NotePreviewText));

      expect(preview().maxLines, 6);
      await tester.tap(find.text('展开'));
      await tester.pump(const Duration(milliseconds: 350));
      expect(preview().maxLines, isNull);
      await tester.tap(find.text('收起'));
      await tester.pump(const Duration(milliseconds: 350));
      expect(preview().maxLines, 6);
    });
  });

  testWidgets('uncached images share a frame budget across cards',
      (tester) async {
    final directory = Directory.systemTemp.createTempSync('inkpaper-card-test');
    addTearDown(() {
      for (final file in directory.listSync()) {
        file.deleteSync();
      }
      directory.deleteSync();
    });
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
    );
    final cards = List.generate(2, (cardIndex) {
      final content = List.generate(2, (imageIndex) {
        final image = File('${directory.path}/$cardIndex-$imageIndex.png')
          ..writeAsBytesSync(png);
        return '![image](file://${image.path.replaceAll(r'\', '/')})';
      }).join('\n');
      return NoteCard(
        note: Note(
          id: 'card-$cardIndex',
          content: content,
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        ),
        onEdit: () {},
        onDelete: () {},
        onPin: () {},
      );
    });

    await tester.pumpWidget(_wrap(ListView(children: cards)));
    expect(find.byType(Image), findsNothing);
    await tester.pump();
    expect(find.byType(Image), findsNWidgets(2));
    await tester.pump();
    expect(find.byType(Image), findsNWidgets(4));
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
