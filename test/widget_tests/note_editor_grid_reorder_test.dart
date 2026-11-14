import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/providers/app_provider.dart';
import 'package:inkpaper/utils/image_decode_width.dart';
import 'package:inkpaper/widgets/note_editor.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 编辑器的图片区是九宫格，原来用 `DragTarget` 做「放下才交换」，拖的过程中没有
/// 任何反馈，只有松手瞬间位置突变。这里锁定改后的行为：拖动时被越过的格子实时
/// 让开，松手才落定顺序。
///
/// 另外盯住图片解码尺寸——九宫格同时挂九张图，按原图尺寸解码会直接把中端机拖垮。

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

/// 造 n 张图的正文。图片文件刻意不存在，走 errorBuilder 的灰块，尺寸照样由
/// 格子决定，够用来测拖动。
String _imageMarkdown(int n) => List.generate(
      n,
      (i) => '![img$i](file:///tmp/inkpaper-grid-none-$i.jpg)',
    ).join('\n');

List<Key?> _slideKeys(WidgetTester tester) => tester
    .widgetList<AnimatedSlide>(find.byType(AnimatedSlide))
    .map((widget) => widget.key)
    .toList();

Future<void> _openGridEditor(WidgetTester tester, int imageCount) async {
  await tester.pumpWidget(_app(_imageMarkdown(imageCount)));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('长按拖动时被越过的格子实时让位，松手后顺序落定', (tester) async {
    await _openGridEditor(tester, 3);

    final tiles = find.byType(LongPressDraggable<int>);
    expect(tiles, findsNWidgets(3));

    final before = _slideKeys(tester);
    final start = tester.getCenter(tiles.at(0));
    final target = tester.getCenter(tiles.at(2));

    final gesture = await tester.startGesture(start);
    // 过掉长按判定窗口，拖动才开始
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveTo(target);
    await tester.pump(const Duration(milliseconds: 200));

    final displaced = tester
        .widgetList<AnimatedSlide>(find.byType(AnimatedSlide))
        .where((widget) => widget.offset != Offset.zero)
        .length;
    expect(displaced, 2, reason: '第 0 张拖到第 2 格，中间两格应当实时让开');

    await gesture.up();
    await tester.pumpAndSettle();

    final after = _slideKeys(tester);
    expect(after[0], before[1], reason: '第 2 张顶上第一格');
    expect(after[1], before[2], reason: '第 3 张顶上第二格');
    expect(after[2], before[0], reason: '被拖的那张落到最后');

    expect(
      tester
          .widgetList<AnimatedSlide>(find.byType(AnimatedSlide))
          .every((widget) => widget.offset == Offset.zero),
      isTrue,
      reason: '松手后位移归零，位置由重排后的布局决定',
    );
  });

  testWidgets('拖到原位松手不改变顺序', (tester) async {
    await _openGridEditor(tester, 3);

    final tiles = find.byType(LongPressDraggable<int>);
    final before = _slideKeys(tester);
    final start = tester.getCenter(tiles.at(1));

    final gesture = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveTo(start + const Offset(4, 4));
    await tester.pump(const Duration(milliseconds: 200));

    expect(
      tester
          .widgetList<AnimatedSlide>(find.byType(AnimatedSlide))
          .every((widget) => widget.offset == Offset.zero),
      isTrue,
      reason: '没越过别的格子就不该有让位',
    );

    await gesture.up();
    await tester.pumpAndSettle();

    expect(_slideKeys(tester), before);
  });

  testWidgets('九宫格图片按缩略档位解码，不按原图尺寸', (tester) async {
    await _openGridEditor(tester, 3);

    final resizeProviders = tester
        .widgetList<Image>(find.byType(Image))
        .map((widget) => widget.image)
        .whereType<ResizeImage>()
        .toList();

    expect(resizeProviders, isNotEmpty, reason: '九宫格图片应当走 ResizeImage');
    expect(
      resizeProviders
          .every((provider) => provider.width == kGridTileDecodeWidth),
      isTrue,
      reason: '一张 4000x3000 的照片全尺寸解码是 45.8MB 位图，九张就是 412MB；'
          '同时必须与列表/详情共用同一档位，否则进编辑器会重新解码一份',
    );
  });
}
