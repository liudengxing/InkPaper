import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/providers/app_provider.dart';
import 'package:inkpaper/services/random_walk_index.dart';
import 'package:inkpaper/widgets/memos_markdown_renderer.dart';
import 'package:inkpaper/widgets/random_walk_canvas.dart';
import 'package:inkpaper/widgets/random_walk_recap.dart';
import 'package:provider/provider.dart';

Note _note(String id, String content, [int day = 1]) => Note(
      id: id,
      content: content,
      createdAt: DateTime(2024, 3, day),
      updatedAt: DateTime(2024, 3, day),
    );

WalkNote _preview(Note note, [String? text]) =>
    (id: note.id, preview: text ?? note.content, createdAt: note.createdAt);

void main() {
  testWidgets(
      'follows one forward branch, reads in the card and returns to the parent',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 640);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final body = List.filled(22, 'Line to read.').join('\n\n');
    final start = _note('start', '> Opening line\n\n$body\n\nFull note ending');
    final branch = _note('branch', 'First branch');
    final other = _note('other', 'Other branch');
    final next = _note('next', 'Next step');
    const evidence = 'Writing notes in a notebook';
    var advanced = false;
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AppProvider(initialFeed: [start, branch, other, next]),
        child: MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => RandomWalkCanvas(
                notes: [
                  _preview(start, '> Opening line'),
                  _preview(branch),
                  if (advanced) _preview(next) else _preview(other),
                ],
                edges: [
                  ('start', 'branch', WalkRelation.text, evidence),
                  if (advanced)
                    ('branch', 'next', WalkRelation.reference, '')
                  else
                    ('start', 'other', WalkRelation.tag, 'writing'),
                ],
                path: advanced ? ['start', 'branch'] : ['start'],
                current: advanced ? branch : start,
                onSelect: (id) => setState(() => advanced = id != start.id),
                action: TextButton(
                  onPressed: () => setState(() => advanced = false),
                  child: const Text('Previous step'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final branchFinder = find.text('First branch');
    final previousPosition = tester.getCenter(branchFinder);
    expect(
      previousPosition.dx,
      greaterThan(tester.getCenter(find.text('Opening line')).dx),
    );
    expect(find.text('Other branch'), findsOneWidget);
    final candidateReason =
        find.text('Similar text · $evidence', findRichText: true);
    expect(candidateReason, findsOneWidget);
    expect(tester.widget<RichText>(candidateReason).maxLines, 2);

    await tester.tap(find.text('Expand'));
    await tester.pumpAndSettle();
    final original = tester
        .widget<MemosMarkdownRenderer>(find.byType(MemosMarkdownRenderer));
    expect(original.content, contains('Full note ending'));
    final scrollView = find.byType(SingleChildScrollView);
    final scrolling = tester.state<ScrollableState>(
      find.descendant(of: scrollView, matching: find.byType(Scrollable)).first,
    );
    await tester.drag(scrollView, const Offset(0, -160));
    await tester.pumpAndSettle();
    expect(scrolling.position.pixels, greaterThan(0));
    scrolling.position.jumpTo(scrolling.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(
      find.text('Full note ending', findRichText: true).hitTestable(),
      findsOneWidget,
    );
    await tester.tap(find.text('Collapse'));
    await tester.pumpAndSettle();
    expect(find.byType(MemosMarkdownRenderer), findsNothing);

    await tester.tap(branchFinder);
    await tester.pumpAndSettle();
    expect(find.text('Other branch'), findsNothing);
    final selectedReason =
        find.text('Similar text\n$evidence', findRichText: true);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('branch')),
        matching: selectedReason.hitTestable(),
      ),
      findsOneWidget,
    );
    expect(tester.widget<RichText>(selectedReason).maxLines, 4);
    expect(
      tester.getCenter(find.text('Next step')).dx,
      greaterThan(tester.getCenter(branchFinder).dx),
    );

    await tester.tap(find.text('Expand'));
    await tester.pumpAndSettle();
    expect(selectedReason.hitTestable(), findsOneWidget);

    await tester.tap(find.text('Previous step'));
    await tester.pumpAndSettle();
    expect(tester.getCenter(branchFinder), previousPosition);
    expect(find.text('Other branch'), findsOneWidget);
    expect(selectedReason, findsNothing);
    expect(candidateReason, findsOneWidget);

    final viewer =
        tester.widget<InteractiveViewer>(find.byType(InteractiveViewer));
    final camera = viewer.transformationController!;
    final beforeButton = camera.value.getMaxScaleOnAxis();
    await tester.tap(find.byTooltip('Zoom in'));
    await tester.pumpAndSettle();
    expect(camera.value.getMaxScaleOnAxis(), greaterThan(beforeButton));
    expect(tester.takeException(), isNull);
  });

  testWidgets('recap uses calendar range and largest adjacent jump',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RandomWalkRecapSheet(
            notes: [
              _note('a', 'First stop', 10),
              _note('b', 'Waypoint'),
              _note('c', 'Last stop', 5),
            ],
          ),
        ),
      ),
    );
    expect(find.text('9 days'), findsOneWidget);
    expect(find.text('Step 1'), findsOneWidget);
    expect(find.text('First stop'), findsOneWidget);
    expect(find.text('Last stop'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('25'), findsOneWidget);
  });
}
