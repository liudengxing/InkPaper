import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/services/random_walk_index.dart';
import 'package:inkpaper/widgets/random_walk_canvas.dart';

void main() {
  testWidgets('expands a branch and keeps existing nodes in place on return',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 640);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final date = DateTime(2024);
    var focus = 'start';
    var expanded = false;
    var request = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => RandomWalkCanvas(
              notes: [
                (id: 'start', preview: 'Starting note', createdAt: date),
                (id: 'branch', preview: 'First branch', createdAt: date),
                if (expanded)
                  (id: 'next', preview: 'Next step', createdAt: date),
              ],
              edges: [
                ('start', 'branch', WalkRelation.tag, 'writing'),
                if (expanded) ('branch', 'next', WalkRelation.reference, ''),
                if (expanded) ('next', 'start', WalkRelation.backlink, ''),
              ],
              path: focus == 'start' ? ['start'] : ['start', focus],
              focus: focus,
              centerRequest: request,
              onSelect: (id) => setState(() {
                focus = id;
                request++;
                expanded = true;
              }),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final start = find.text('Starting note');
    final branch = find.text('First branch');
    final originalPosition = tester.getCenter(branch);
    expect(find.text('Shared tag #writing'), findsOneWidget);

    await tester.tap(branch);
    await tester.pumpAndSettle();
    expect(find.text('Next step'), findsOneWidget);
    expect(find.text('Starting note'), findsOneWidget);

    await tester.tap(start);
    await tester.pumpAndSettle();
    expect(tester.getCenter(branch), originalPosition);

    final viewer =
        tester.widget<InteractiveViewer>(find.byType(InteractiveViewer));
    final camera = viewer.transformationController!;
    final initialScale = camera.value.getMaxScaleOnAxis();
    final left = await tester.startGesture(const Offset(125, 300));
    final right = await tester.startGesture(const Offset(235, 300));
    await left.moveTo(const Offset(80, 300));
    await right.moveTo(const Offset(280, 300));
    await left.up();
    await right.up();
    await tester.pumpAndSettle();
    expect(camera.value.getMaxScaleOnAxis(), greaterThan(initialScale));
    expect(tester.takeException(), isNull);
  });
}
