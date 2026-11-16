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

    // 区高必须落在整行边界上：给半行的话第二行只露一条上沿，看着像图片没加载完。
    final tile = tester.getRect(find.byType(AnimatedSlide).first).height;
    const headerAndTop = 22.0 + 4.0 + 16.0;
    const spacing = 8.0;
    final visibleRows = (capped - headerAndTop + spacing) / (tile + spacing);
    expect(
      visibleRows,
      closeTo(visibleRows.roundToDouble(), 0.01),
      reason: '图片区高度 $capped 不是整数行（一行 $tile），会露出半行残图',
    );

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

  testWidgets('键盘弹起/收起时图片区逐帧收缩，不与卡片位移脱节', (tester) async {
    usePhoneCanvas(tester);
    await openEditor(tester, 5);

    final expanded = tester.getRect(imageSection).height;

    /// 逐帧采样图片区高度：相邻两帧的变化幅度必须小，且方向单调。
    /// 瞬变时会出现一帧掉掉整段高度，视觉上就是「跳一下再拉伸」。
    Future<List<double>> sample(String stage) async {
      final samples = <double>[];
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        samples.add(tester.getRect(imageSection).height);
      }
      for (var i = 1; i < samples.length; i++) {
        expect(
          (samples[i] - samples[i - 1]).abs(),
          lessThan(60),
          reason: '$stage 第 $i 帧高度跳了 '
              '${(samples[i] - samples[i - 1]).toStringAsFixed(1)}px',
        );
      }
      return samples;
    }

    // 键盘弹起：图片区应当一帧一帧地缩短，不是一步到位
    tester.view.viewInsets = const FakeViewPadding(bottom: 900);
    // 不先 pump 一次：那样第一帧的跳变会被采样漏掉，测试永远是绿的
    final shrinking = await sample('键盘弹起');
    await tester.pumpAndSettle();

    expect(
      shrinking.last,
      lessThan(shrinking.first - 60),
      reason: '键盘占掉屏幕后图片区必须让位',
    );
    for (var i = 1; i < shrinking.length; i++) {
      expect(
        shrinking[i],
        lessThanOrEqualTo(shrinking[i - 1] + 0.01),
        reason: '键盘弹起时图片区高度不允许回弹（说明有两段动画）',
      );
    }

    // 键盘收起：反向同理
    tester.view.viewInsets = FakeViewPadding.zero;
    final growing = await sample('键盘收起');
    await tester.pumpAndSettle();

    for (var i = 1; i < growing.length; i++) {
      expect(
        growing[i],
        greaterThanOrEqualTo(growing[i - 1] - 0.01),
        reason: '键盘收起时图片区高度不允许回退',
      );
    }
    expect(
      tester.getRect(imageSection).height,
      closeTo(expanded, 1.0),
      reason: '键盘收起后要回到原来的行数高度',
    );
  });

  Widget fsApp(String content) => ChangeNotifierProvider(
        create: (_) => AppProvider(),
        child: MaterialApp(
          home: NoteEditor(
            fullScreen: true,
            initialContent: content,
            onSave: (_) async {},
          ),
        ),
      );

  Future<void> openFullscreenEditor(WidgetTester tester, int imageCount) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.pumpWidget(fsApp(_imageMarkdown(image, imageCount)));
    await tester.pumpAndSettle();
    expect(find.byType(NoteEditor), findsOneWidget);
    // 全屏编辑器打开后有个 180ms 聚焦定时器，推掉避免 pending timer
    await tester.pump(const Duration(seconds: 1));
  }

  /// 全屏编辑专属（注意：底部卡片那几条测试锁的是旧行为，勿混改）。
  group('全屏编辑图片区两态', () {
    testWidgets('FSG-01 图片区默认只露一行九宫格，正文不被挤', (tester) async {
      usePhoneCanvas(tester);
      await openFullscreenEditor(tester, 7);

      final section = tester.getRect(imageSection);
      final tile = tester.getRect(find.byType(AnimatedSlide).first).height;
      expect(
        section.height,
        closeTo(22.0 + 4.0 + tile + 16.0, 1.0),
        reason: '默认只露一行：标题行 22 + 上内距 4 + 一格 + 底部留白 16',
      );
      // 正文始终可见：图片区顶边距顶栏要留出一大截（文字区高度）
      expect(
        section.top - 50,
        greaterThan(100),
        reason: '图片区只占一行，中间的文字区应该还有几百 px',
      );
      expect(find.text('7 张图片 · 长按拖动排序 · 上滑展开'), findsOneWidget);
    });

    testWidgets('FSG-02 上滑展开看全部，下滑收起回一行', (tester) async {
      usePhoneCanvas(tester);
      await openFullscreenEditor(tester, 7);

      final collapsed = tester.getRect(imageSection).height;
      await tester.fling(imageSection, const Offset(0, -300), 1000);
      await tester.pumpAndSettle();

      final expanded = tester.getRect(imageSection).height;
      expect(
        expanded,
        greaterThan(collapsed + 100),
        reason: '展开后至少多露一整行',
      );
      expect(
        tester.getRect(imageSection).top - 50,
        greaterThan(100),
        reason: '展开后正文的最低保留高度仍在',
      );
      expect(find.text('7 张图片 · 长按拖动排序 · 下滑收起'), findsOneWidget);

      // 展开后格子自己吃纵向滚动，收起手势从标题行走
      await tester.fling(
        find.text('7 张图片 · 长按拖动排序 · 下滑收起'),
        const Offset(0, 300),
        1000,
      );
      await tester.pumpAndSettle();
      expect(tester.getRect(imageSection).height, closeTo(collapsed, 1.0));
    });

    testWidgets('FSG-03 每格右上角有删除按钮，点击移除图片', (tester) async {
      usePhoneCanvas(tester);
      // 4 张 = 2 行：收起时只渲染第一行的 3 个删除钮
      await openFullscreenEditor(tester, 4);

      final deleteInGrid = find.descendant(
        of: imageSection,
        matching: find.byIcon(Icons.close),
      );
      expect(deleteInGrid, findsNWidgets(3));

      await tester.tap(deleteInGrid.first);
      await tester.pumpAndSettle();

      // 剩 3 张只有一行，不再可展开，提示回到普通文案
      expect(find.text('3 张图片 · 长按拖动排序'), findsOneWidget);
      expect(
        find.descendant(of: imageSection, matching: find.byIcon(Icons.close)),
        findsNWidgets(3),
      );
    });
  });
}
