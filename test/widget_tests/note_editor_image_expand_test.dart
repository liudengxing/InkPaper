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

void main() {
  late File image;

  setUpAll(() {
    image = File('${Directory.systemTemp.path}/inkpaper_expand_test.png')
      ..writeAsBytesSync(base64Decode(_tinyPngBase64));
  });

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  /// 展开/收起九宫格时，两个不变量必须成立：
  ///   1. 正文输入框自身高度不变 —— 空间是图片区长高让出来的，不是从文字区抢的
  ///   2. 正文底边到图片区顶边的间距不变 —— 两者没有被互相拉扯
  ///
  /// 整个卡片会随九宫格一起整体上移（卡片顶部贴屏幕底、内容贴底排布），那是正常
  /// 位移不算抖动；抖动是这些量在若干帧里反复变化。
  ///
  /// 改之前：卡片高度瞬变 +142，图片区用 200ms 才长上去，中间帧里文字区被反复
  /// 挤压；同时九宫格在 110px 的窗口里逐帧拉高，图片被切成一条再慢慢露出来。
  Future<void> expectNoJitter(WidgetTester tester) async {
    final textField = find.byWidgetPredicate(
      (widget) => widget is TextField && widget.autofocus,
    );
    expect(textField, findsOneWidget);
    final imageSection = find.byKey(
      const ValueKey('note-editor-image-section'),
    );

    final baseText = tester.getRect(textField);
    final baseImage = tester.getRect(imageSection);
    final baseGap = baseImage.top - baseText.bottom;

    void assertStable(String stage) {
      final text = tester.getRect(textField);
      final image = tester.getRect(imageSection);
      final gap = image.top - text.bottom;
      expect(
        (text.height - baseText.height).abs(),
        lessThan(1.0),
        reason: '$stage：正文输入框自身高度变了',
      );
      expect(
        (gap - baseGap).abs(),
        lessThan(1.0),
        reason: '$stage：正文与图片区间距变了（互相拉扯）',
      );
    }

    await tester.tap(find.byIcon(Icons.grid_view_rounded));
    await tester.pump();

    // 220ms 的展开动画：全程逐帧采样，高度必须单调长高（不能先跳到位再变一次），
    // 同时正文的高度与间距每一帧都不能动
    final expandHeights = <double>[];
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 30));
      // 交叉淡化期间两张图同时在，任何一帧都不能出现空的图片区
      expect(find.byType(Image), findsWidgets);
      assertStable('展开第 $i 帧');
      final h = tester.getRect(imageSection).height;
      if (expandHeights.isNotEmpty) {
        expect(
          h,
          greaterThanOrEqualTo(expandHeights.last - 0.01),
          reason: '展开第 $i 帧：图片区高度回退了（说明有两段动画）',
        );
      }
      expandHeights.add(h);
    }
    await tester.pumpAndSettle();
    assertStable('展开完成');
    expect(
      expandHeights.last,
      greaterThan(baseImage.height + 100),
      reason: '展开后图片区必须长高到接近九宫格',
    );

    // 收起同样不该抖
    await tester.tap(find.byIcon(Icons.expand_more_rounded));
    await tester.pump();
    final collapseHeights = <double>[];
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 30));
      expect(find.byType(Image), findsWidgets);
      assertStable('收起第 $i 帧');
      final h = tester.getRect(imageSection).height;
      if (collapseHeights.isNotEmpty) {
        expect(
          h,
          lessThanOrEqualTo(collapseHeights.last + 0.01),
          reason: '收起第 $i 帧：图片区高度反弹了（说明有两段动画）',
        );
      }
      collapseHeights.add(h);
    }
    await tester.pumpAndSettle();
    assertStable('收起完成');
    expect(
      tester.getRect(imageSection).height,
      lessThan(baseImage.height + 1),
      reason: '收起后图片区必须回到原高度',
    );
  }

  testWidgets('展开/收起九宫格时正文区不抖动', (tester) async {
    await tester.pumpWidget(_app('一张图\n![图](${image.path})\n'));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byType(NoteEditor), findsOneWidget);
    expect(find.byType(Image), findsWidgets);

    await expectNoJitter(tester);
  });

  testWidgets('三张图时同样不抖动', (tester) async {
    final content = List.generate(
      3,
      (i) => '![图$i](${image.path})',
    ).join('\n');
    await tester.pumpWidget(_app('$content\n'));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await expectNoJitter(tester);
  });
}
