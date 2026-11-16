import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/providers/app_provider.dart';
import 'package:inkpaper/widgets/note_editor.dart';
import 'package:inkpaper/widgets/note_editor_page.dart';
import 'package:inkpaper/widgets/note_preview_text.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 编辑已有笔记走全屏（`fullScreen: true`），新建走底部卡片。
///
/// 两条路径共用同一个 [NoteEditor]，所以这里锁的是「同一份编辑器在不同容器里
/// 该有什么、不该有什么」——拖动条、发送按钮属于卡片；取消/完成属于全屏。
/// 一旦哪天有人「顺手」把全屏改成另一套按钮，这些断言会先响。

Widget _host({required bool fullScreen}) => ChangeNotifierProvider(
      create: (_) => AppProvider(),
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => NoteEditor(
                      initialContent: '第一行笔记',
                      fullScreen: fullScreen,
                      onSave: (_) async {},
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

Future<void> _open(WidgetTester tester, {required bool fullScreen}) async {
  await tester.pumpWidget(_host(fullScreen: fullScreen));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('编辑器两种容器', () {
    testWidgets('FS-01 全屏模式是取消/完成，没有卡片的发送按钮', (tester) async {
      await _open(tester, fullScreen: true);

      expect(find.text('取消'), findsOneWidget);
      expect(find.text('完成'), findsOneWidget);
      expect(find.text('编辑笔记'), findsOneWidget);
      // 发送按钮是卡片专属：全屏的保存入口是右上「完成」，底部不该再来一个
      expect(find.byIcon(Icons.send), findsNothing);
    });

    testWidgets('FS-02 卡片模式仍是发送按钮，没有完成', (tester) async {
      await _open(tester, fullScreen: false);

      expect(find.byIcon(Icons.send), findsOneWidget);
      expect(find.text('完成'), findsNothing);
      expect(find.text('编辑笔记'), findsNothing);
    });

    testWidgets('FS-03 全屏点完成会保存并退出编辑态', (tester) async {
      var saved = '';
      await tester.pumpWidget(
        ChangeNotifierProvider(
          create: (_) => AppProvider(),
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => Center(
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(context).push<void>(
                      MaterialPageRoute<void>(
                        builder: (_) => NoteEditor(
                          initialContent: '第一行笔记',
                          fullScreen: true,
                          onSave: (content) async => saved = content,
                        ),
                      ),
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();

      expect(saved, '第一行笔记');
      // 编辑器 pop 掉了，回到宿主页面
      expect(find.text('open'), findsOneWidget);
      expect(find.text('完成'), findsNothing);
    });

    testWidgets('FS-05 详情页正文那套组合：单击能被外层接住', (tester) async {
      // 详情页正文刻意不用 SelectableText / SelectionArea —— 实测两者都会把
      // 单击吞进选区逻辑，正文就点不进编辑态。这里锁住「Text.rich + 外层
      // GestureDetector」这个组合，防止哪天有人顺手把可选中加回来
      var tapped = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () => tapped = true,
              child: const NotePreviewText(
                content: '正文内容',
                style: TextStyle(fontSize: 16),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byType(NotePreviewText));
      await tester.pumpAndSettle();

      expect(tapped, isTrue);
    });

    testWidgets('FS-04 NoteEditorPage 打开的就是全屏编辑器', (tester) async {
      await tester.pumpWidget(
        ChangeNotifierProvider(
          create: (_) => AppProvider(),
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => Center(
                  child: ElevatedButton(
                    onPressed: () => NoteEditorPage.open(
                      context,
                      noteId: 'note-1',
                      initialContent: '第一行笔记',
                      onSave: (_) async {},
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('完成'), findsOneWidget);
      expect(find.byIcon(Icons.send), findsNothing);
    });

    testWidgets('FS-06 全屏头部落在状态栏下方，底部让开手势条', (tester) async {
      tester.view.physicalSize = const Size(1233, 2742);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      // 真机（Xiaomi 14）上状态栏约 48、手势条约 24。之前全屏容器直接从
      // 屏幕顶边画，「取消 / 完成」整个压在时间与信号图标上，点不到。
      await tester.pumpWidget(
        ChangeNotifierProvider(
          create: (_) => AppProvider(),
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                padding: const EdgeInsets.only(top: 48, bottom: 24),
              ),
              child: child!,
            ),
            home: NoteEditor(
              initialContent: '第一行笔记',
              fullScreen: true,
              onSave: (_) async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final cancelTop = tester.getTopLeft(find.text('取消')).dy;
      expect(cancelTop, greaterThanOrEqualTo(48), reason: '取消按钮被状态栏盖住了');

      final doneBottom = tester.getBottomLeft(find.text('完成')).dy;
      expect(doneBottom, greaterThan(48));

      // 底部工具栏（# 按钮所在行）不能压进手势条
      final hashtagBottom = tester.getBottomLeft(find.text('#')).dy;
      expect(
        hashtagBottom,
        lessThanOrEqualTo(2742 / 3 - 24 + 0.5),
        reason: '底部工具栏压进了手势条',
      );

      // 编辑器打开后有个 180ms 的聚焦定时器，推掉它再结束，
      // 否则测试会因为 pending timer 报失败
      await tester.pump(const Duration(seconds: 1));
    });
  });
}
