import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/widgets/on_this_day_card.dart';

Note _note(String id, int year, {String? content}) => Note(
      id: id,
      content: content ?? '$year 年的记录',
      createdAt: DateTime(year, 10, 27, 9, 30),
      updatedAt: DateTime(year, 10, 27, 9, 30),
    );

Widget _wrap(Widget child) => MaterialApp(
      home: Scaffold(
        body: SizedBox(width: 390, child: child),
      ),
    );

void main() {
  group('OnThisDayCard', () {
    testWidgets('OTD-01 展示「去年今日」标签与年份', (tester) async {
      await tester.pumpWidget(
        _wrap(
          OnThisDayCard(
            notes: [_note('a', 2024)],
            onClose: () {},
            onOpenNote: (_) {},
          ),
        ),
      );

      expect(find.text('去年今日'), findsOneWidget);
      expect(find.text('2024 年的今天'), findsOneWidget);
      expect(find.text('2024 年的记录'), findsOneWidget);
    });

    testWidgets('OTD-02 点关闭按钮触发 onClose', (tester) async {
      var closed = 0;
      await tester.pumpWidget(
        _wrap(
          OnThisDayCard(
            notes: [_note('a', 2024)],
            onClose: () => closed++,
            onOpenNote: (_) {},
          ),
        ),
      );

      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pump();
      expect(closed, 1);
    });

    testWidgets('OTD-03 多个年份可左右滑动切换', (tester) async {
      await tester.pumpWidget(
        _wrap(
          OnThisDayCard(
            notes: [_note('b', 2025), _note('a', 2024)],
            onClose: () {},
            onOpenNote: (_) {},
          ),
        ),
      );

      expect(find.text('1/2'), findsOneWidget);
      expect(find.text('2025 年的今天'), findsOneWidget);

      await tester.drag(find.byType(PageView), const Offset(-320, 0));
      await tester.pumpAndSettle();

      expect(find.text('2/2'), findsOneWidget);
      expect(find.text('2024 年的今天'), findsOneWidget);
    });

    testWidgets('OTD-04 点正文打开对应笔记', (tester) async {
      String? openedId;
      await tester.pumpWidget(
        _wrap(
          OnThisDayCard(
            notes: [_note('a', 2024)],
            onClose: () {},
            onOpenNote: (note) => openedId = note.id,
          ),
        ),
      );

      await tester.tap(find.text('2024 年的记录'));
      await tester.pump();
      expect(openedId, 'a');
    });

    testWidgets('OTD-05 无笔记时不渲染任何内容', (tester) async {
      await tester.pumpWidget(
        _wrap(
          OnThisDayCard(
            notes: const [],
            onClose: () {},
            onOpenNote: (_) {},
          ),
        ),
      );

      expect(find.byType(Material), findsWidgets);
      expect(find.text('去年今日'), findsNothing);
    });
  });
}
