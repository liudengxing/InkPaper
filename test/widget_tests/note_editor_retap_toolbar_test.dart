import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/providers/app_provider.dart';
import 'package:inkpaper/widgets/capsule_text_selection_toolbar.dart';
import 'package:inkpaper/widgets/note_editor.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 光标停在字中间（没有框选）时，再点同一个位置应当弹出系统工具栏。
/// Flutter 默认只有双击选词、长按拖动才会 showToolbar，单击折叠光标处只是把
/// 光标摆回原地，编辑器得自己把菜单叫出来。

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

Finder get _selectionToolbar => find.byType(CapsuleTextSelectionToolbar);

Future<void> _openEditor(WidgetTester tester, String content) async {
  await tester.pumpWidget(_app(content));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  expect(_editorField, findsOneWidget);
}

TextEditingController _controller(WidgetTester tester) =>
    tester.widget<TextField>(_editorField).controller!;

/// 单击一处并等过双击判定窗口，让 Flutter 把单击彻底落定。
Future<void> _tapAndSettle(WidgetTester tester, Offset target) async {
  await tester.tapAt(target);
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('光标停在字中间时再点同一位置：弹出工具栏', (tester) async {
    await _openEditor(tester, 'hello world');

    final editable = find.byType(EditableText);
    // 点在 "world" 的 w 附近，光标从开头挪到词首
    final target = tester.getTopLeft(editable) + const Offset(56, 10);

    await _tapAndSettle(tester, target);
    final caret = _controller(tester).selection;
    expect(caret.isCollapsed, isTrue, reason: '单击只落光标，不选中文字');
    expect(_selectionToolbar, findsNothing, reason: '第一次点击是在挪光标');

    await _tapAndSettle(tester, target);

    expect(
      _controller(tester).selection.isCollapsed,
      isTrue,
      reason: '再次点击同一位置不应改变光标',
    );
    expect(_selectionToolbar, findsOneWidget, reason: '应当弹出系统工具栏');
  });

  testWidgets('点在不同位置只是挪光标，不弹工具栏', (tester) async {
    await _openEditor(tester, 'hello world');

    final editable = find.byType(EditableText);
    final row = tester.getTopLeft(editable);

    await _tapAndSettle(tester, row + const Offset(56, 10));
    await _tapAndSettle(tester, row + const Offset(8, 10));

    expect(_selectionToolbar, findsNothing);
  });

  testWidgets('双击正文仍按原样选词，不被单击逻辑抢走', (tester) async {
    await _openEditor(tester, 'hello world');

    final editable = find.byType(EditableText);
    final target = tester.getTopLeft(editable) + const Offset(8, 10);

    await tester.tapAt(target);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(target);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    final controller = _controller(tester);
    expect(controller.selection.textInside(controller.text), 'hello');
    expect(_selectionToolbar, findsOneWidget);
  });

  testWidgets('空笔记点一下不会抛异常', (tester) async {
    await _openEditor(tester, '');

    final editable = find.byType(EditableText);
    await _tapAndSettle(
      tester,
      tester.getTopLeft(editable) + const Offset(8, 10),
    );

    expect(tester.takeException(), isNull);
  });
}
