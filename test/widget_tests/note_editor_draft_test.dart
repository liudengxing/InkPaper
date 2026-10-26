import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/providers/app_provider.dart';
import 'package:inkpaper/services/draft_service.dart';
import 'package:inkpaper/widgets/note_editor.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _app({String? initialContent, String? noteId}) => ChangeNotifierProvider(
      create: (_) => AppProvider(),
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => showGeneralDialog<void>(
                  context: context,
                  barrierDismissible: true,
                  barrierLabel: 'note-composer',
                  barrierColor: Colors.transparent,
                  pageBuilder: (_, __, ___) => NoteEditor(
                    initialContent: initialContent,
                    currentNoteId: noteId,
                    onSave: (_) async {},
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('点上方空白区域关闭新建笔记时，输入内容落到草稿', (tester) async {
    await tester.pumpWidget(_app());
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(NoteEditor), findsOneWidget);

    const text = '这是一段会被保存到草稿的内容';
    await tester.enterText(find.byType(TextField).first, text);
    await tester.pump();

    // 点卡片上方的空白区域
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();

    expect(find.byType(NoteEditor), findsNothing);

    final draft = await DraftService().load(DraftService.newNoteDraftId);
    expect(draft, isNotNull);
    expect(draft!.content, contains(text));
  });

  testWidgets('编辑已有笔记点空白关闭，草稿按笔记 id 保留', (tester) async {
    await tester.pumpWidget(
      _app(initialContent: '原始内容', noteId: 'note-1'),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '原始内容\n追加的一段');
    await tester.pump();

    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();

    expect(find.byType(NoteEditor), findsNothing);

    final draft = await DraftService().load('note-1');
    expect(draft, isNotNull);
    expect(draft!.content, contains('追加的一段'));
  });
}
