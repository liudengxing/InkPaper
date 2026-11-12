import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/providers/app_provider.dart';
import 'package:inkpaper/widgets/note_editor.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 编辑器正文输入框的高度只跟着文字走（一行就一个行高），文字下方的空白在输入框
/// 自己的矩形之外。那些空白以前没人接手势：双击没反应，只能长按文字框选才能叫出
/// 复制/粘贴工具栏。这里锁定「空白区双击也能选词 + 弹工具栏」。

Widget _app(String content) => ChangeNotifierProvider(
      create: (_) => AppProvider(),
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  backgroundColor: Colors.transparent,
                  builder: (_) =>
                      NoteEditor(initialContent: content, onSave: (_) async {}),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

final Finder _editorField = find.byWidgetPredicate(
  (widget) => widget is TextField && widget.autofocus,
);

Finder get _selectionToolbar => find.byType(AdaptiveTextSelectionToolbar);

Future<void> _openEditor(WidgetTester tester, String content) async {
  await tester.pumpWidget(_app(content));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  expect(_editorField, findsOneWidget);
}

/// 连点两下同一个位置。间隔取 80ms，落在双击窗口（40~300ms）内。
Future<void> _doubleTapAt(WidgetTester tester, Offset target) async {
  await tester.tapAt(target);
  await tester.pump(const Duration(milliseconds: 80));
  await tester.tapAt(target);
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
}

String _selectedText(WidgetTester tester) {
  final controller = tester.widget<TextField>(_editorField).controller!;
  return controller.selection.textInside(controller.text);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('正文下方空白处双击：选中最近的词并弹出工具栏', (tester) async {
    await _openEditor(tester, 'hello world foo bar');

    final fieldRect = tester.getRect(_editorField);
    // 输入框只占一行，这里点在它下面 30px 的卡片空白里
    await _doubleTapAt(
      tester,
      Offset(fieldRect.center.dx, fieldRect.bottom + 30),
    );

    expect(
      _selectedText(tester),
      'bar',
      reason: '点的是最后一行下面的空白，应当选中最近的词',
    );
    expect(_selectionToolbar, findsOneWidget, reason: '应当弹出系统选择工具栏');
  });

  testWidgets('正文上双击：行为不变，仍然选中单词', (tester) async {
    await _openEditor(tester, 'hello world foo bar');

    final editable = find.byType(EditableText);
    await _doubleTapAt(
      tester,
      tester.getTopLeft(editable) + const Offset(2, 10),
    );

    expect(_selectedText(tester), 'hello');
    expect(_selectionToolbar, findsOneWidget);
  });

  testWidgets('空笔记双击空白：只落光标，不报错也不弹工具栏', (tester) async {
    await _openEditor(tester, '');

    final fieldRect = tester.getRect(_editorField);
    await _doubleTapAt(
      tester,
      Offset(fieldRect.center.dx, fieldRect.bottom + 30),
    );

    expect(tester.takeException(), isNull);
    expect(_selectionToolbar, findsNothing);
  });
}
