import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/widgets/note_action_card.dart';
import 'package:inkpaper/widgets/note_actions_ui.dart';

/// 删除确认从 AlertDialog 换成了三点菜单同款卡片：这个测试钉住形态和返回值，
/// 免得以后又被改回一个矮胖的对话框。
void main() {
  testWidgets('删除确认走卡片，点「删除」返回 true', (tester) async {
    bool? result;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async {
                  result = await NoteActionsUi.showDeleteConfirmDialog(context);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byType(NoteActionCard), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('删除笔记'), findsOneWidget);
    // 说明里要交代清楚「进回收站、可恢复」，用户怕的是不可逆
    expect(find.textContaining('30 天内'), findsOneWidget);

    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });

  testWidgets('删除确认点「取消」返回 false', (tester) async {
    bool? result;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async {
                  result = await NoteActionsUi.showDeleteConfirmDialog(context);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(result, isFalse);
  });
}
