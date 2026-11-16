import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/providers/app_provider.dart';
import 'package:inkpaper/widgets/note_editor.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 编辑器保存出口会把正文尾部空白砍掉：尾部空行没有任何语义，留着会让
/// 再次打开时看到光标下方一大片空行，复制出去也带着。
Widget _app({
  required void Function(String content) onSave,
  String? initialContent,
}) =>
    ChangeNotifierProvider(
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
                    onSave: onSave,
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

  testWidgets('ED-01 新建时输入的尾部空行不会存进笔记', (tester) async {
    String? saved;
    await tester.pumpWidget(
      _app(onSave: (content) => saved = content),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '第一行\n\n第二行\n\n\n');
    await tester.pump();

    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    expect(saved, '第一行\n\n第二行');
  });

  testWidgets('ED-02 已有内容的尾部空行在保存时被清掉', (tester) async {
    String? saved;
    await tester.pumpWidget(
      _app(
        initialContent: '已有内容\n\n\n',
        onSave: (content) => saved = content,
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    expect(saved, '已有内容');
  });
}
