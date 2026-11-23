import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/utils/typewriter_text.dart';
import 'package:inkpaper/widgets/insight_live_output.dart';

String _shown(TypewriterText text) =>
    List.generate(text.blockCount, text.blockAt).join();

void main() {
  test('short bursts appear gradually and the last character catches up', () {
    final text = TypewriterText()..append('今天爬山');
    expect(text.advance(), isTrue);
    expect(_shown(text), '今');
    expect(text.advance(), isTrue);
    expect(_shown(text), '今天');
    expect(text.advance(), isTrue);
    expect(text.advance(), isFalse);
    expect(text.advance(allowTail: true), isTrue);
    expect(_shown(text), '今天爬山');
  });

  test('limits each burst and retains the complete original across blocks', () {
    final output = '${'字' * 600}\n\n收尾';
    final text = TypewriterText()..append(output);
    expect(text.advance(allowTail: true), isTrue);
    expect(_shown(text), '字' * 12);
    while (text.advance(allowTail: true)) {}
    expect(text.blockCount, greaterThan(3));
    expect(_shown(text), output);
    expect(text.hasPending, isFalse);
  });

  test('joins streamed graphemes before drawing them', () {
    final text = TypewriterText()..append('👩');
    expect(text.advance(), isFalse);
    text.append('\u200d💻好');
    expect(text.advance(), isTrue);
    expect(_shown(text), '👩\u200d💻');
    text.advance(allowTail: true);
    expect(_shown(text), '👩\u200d💻好');
  });

  testWidgets('typing cursor follows the stream from reasoning to report',
      (tester) async {
    final controller = InsightLiveOutputController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: InsightLiveOutput(controller: controller)),
      ),
    );
    expect(find.text('Reading through your notes…'), findsOneWidget);

    controller.append('今天爬山', reasoning: true);
    await tester.pump(const Duration(milliseconds: 45));
    expect(find.text('Thinking…'), findsOneWidget);
    final caret = find.byKey(const ValueKey('insight-live-caret'));
    expect(caret, findsOneWidget);
    expect(
      tester.widgetList<RichText>(find.byType(RichText)).any(
            (widget) =>
                widget.text.toPlainText(includePlaceholders: false) == '今',
          ),
      isTrue,
    );

    controller.append('正式报告', reasoning: false);
    await tester.pump(const Duration(milliseconds: 90));
    expect(find.text('Writing the report…'), findsOneWidget);
    expect(find.text('Reasoning'), findsOneWidget);
    expect(find.text('Insight report'), findsOneWidget);
    expect(caret, findsOneWidget);
    controller.stop();
  });

  testWidgets('reading earlier lines pauses following until Jump to latest',
      (tester) async {
    final controller = InsightLiveOutputController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InsightLiveOutput(controller: controller),
        ),
      ),
    );
    controller.append('较长的思考内容，用来验证阅读位置。\n' * 28, reasoning: true);
    for (var frame = 0; frame < 100; frame++) {
      await tester.pump(const Duration(milliseconds: 44));
    }
    ScrollPosition position() =>
        tester.state<ScrollableState>(find.byType(Scrollable)).position;
    expect(position().extentAfter, lessThan(2));

    await tester.drag(find.byType(ListView), const Offset(0, 270));
    for (var frame = 0; frame < 10; frame++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final oldOffset = position().pixels;
    expect(position().extentAfter, greaterThan(12));
    final latest = find.text('Jump to latest');
    expect(latest, findsOneWidget);

    controller.append('接下来继续生成新的思考。\n' * 7, reasoning: true);
    for (var frame = 0; frame < 30; frame++) {
      await tester.pump(const Duration(milliseconds: 44));
    }
    expect(position().pixels, closeTo(oldOffset, 1));

    await tester.tap(latest);
    for (var frame = 0; frame < 16; frame++) {
      await tester.pump(const Duration(milliseconds: 44));
    }
    expect(position().extentAfter, lessThan(2));
    expect(latest, findsNothing);
    controller.stop();
  });
}
