import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/providers/app_provider.dart';
import 'package:inkpaper/widgets/note_editor.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 1×1 透明 PNG：够让 Image 真正解码成功，不会走 errorBuilder 干扰布局测量。
const String _tinyPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

Widget _app(String content) => ChangeNotifierProvider(
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
                    initialContent: content,
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

/// 造 [count] 张图的正文。刻意挤在同一行：正文行数会改变输入框自适应高度，
/// 拆成多行就分不清「文字框变了」是图片挤的，还是行数多出来的。
String _imageMarkdown(File image, int count) =>
    '${List.generate(count, (i) => '![图$i](${image.path})').join(' ')}\n';

void main() {
  late File image;

  setUpAll(() {
    image = File('${Directory.systemTemp.path}/inkpaper_image_grid_test.png')
      ..writeAsBytesSync(base64Decode(_tinyPngBase64));
  });

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  /// 编辑器高度按屏幕算；默认测试画布 800×600 是横屏比例，图片区会被可用高度
  /// 一路钳住，量不出「行数越多越高」。换成常见手机比例（411×914 逻辑像素）。
  void usePhoneCanvas(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
  }

  Future<void> openEditor(WidgetTester tester, int imageCount) async {
    // 同一个 tester 里换场景时，先卸载整棵树：只替换 MaterialApp 会复用 Navigator，
    // 上一个编辑器还盖在按钮上面，点 open 会命中对话框。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();

    await tester.pumpWidget(_app(_imageMarkdown(image, imageCount)));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(NoteEditor), findsOneWidget);
  }

  final imageSection = find.byKey(const ValueKey('note-editor-image-section'));

  Finder textField() => find.byWidgetPredicate(
        (widget) => widget is TextField && widget.autofocus,
      );

  testWidgets('图片区默认就是九宫格，不再有单行横滑与展开按钮', (tester) async {
    usePhoneCanvas(tester);
    await openEditor(tester, 1);

    // 单行横滑那套（ReorderableListView + 右上角九宫格按钮 + 收起按钮）应当整体消失
    expect(find.byType(ReorderableListView), findsNothing);
    expect(find.byIcon(Icons.grid_view_rounded), findsNothing);
    expect(find.byIcon(Icons.expand_more_rounded), findsNothing);

    // 每一格都是长按可拖动的九宫格单元
    expect(find.byType(LongPressDraggable<int>), findsOneWidget);
    expect(find.text('1 张图片 · 长按拖动排序'), findsOneWidget);
  });

  testWidgets('图片区高度随行数增长，正文区不跟着缩水', (tester) async {
    usePhoneCanvas(tester);

    final heights = <double>[];
    double? textHeight;

    // 1 张 → 1 行，4 张 → 2 行，7 张 → 3 行
    for (final count in [1, 4, 7]) {
      await openEditor(tester, count);
      final text = tester.getRect(textField());
      final section = tester.getRect(imageSection);
      textHeight ??= text.height;
      expect(
        text.height,
        closeTo(textHeight, 0.5),
        reason: '图片区是卡片长高让出来的空间，不能从正文区抢（$count 张图）：'
            '文字 $textHeight → ${text.height}，图片区 ${section.height}',
      );
      heights.add(section.height);
    }

    expect(
      heights[1],
      greaterThan(heights[0] + 100),
      reason: '两行九宫格必须比一行高出一整行',
    );
    expect(
      heights[2],
      greaterThan(heights[1] + 100),
      reason: '三行九宫格必须比两行高出一整行',
    );
  });

  testWidgets('行数超过屏幕可用高度后区高封顶，改为内部滚动', (tester) async {
    usePhoneCanvas(tester);

    // 10 张 = 4 行、16 张 = 6 行：都超过卡片能长的高度，区高应当停在同一个值
    await openEditor(tester, 10);
    final capped = tester.getRect(imageSection).height;
    await openEditor(tester, 16);
    final taller = tester.getRect(imageSection).height;

    expect(
      taller,
      closeTo(capped, 1.0),
      reason: '卡片高度被屏幕钳住后图片区不再长高，多出来的行交给内部滚动',
    );

    final grid = find.byType(GridView);
    expect(grid, findsOneWidget);
    final controller = tester.widget<GridView>(grid).controller;
    expect(controller, isNotNull);

    await tester.drag(grid, const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(
      controller!.offset,
      greaterThan(0),
      reason: '被裁掉的行必须能滚出来，否则最后几张图永远看不到',
    );
  });
}
