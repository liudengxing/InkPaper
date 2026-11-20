import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:inkpaper/providers/app_provider.dart';
import 'package:inkpaper/widgets/sidebar.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 侧边栏选中态是手搓的玻璃胶囊（品牌色渐变 + 顶部高光 + 描边），不走
/// liquid_glass_renderer —— 那套采样的是图层背后的像素，抽屉里背后是半透明
/// 遮罩，真机上只会得到发灰的板子。整抽屉毛玻璃的尝试也已回退。观感仍然只能
/// 在真机上看，这里验结构。
Widget _wrap(String location) => ChangeNotifierProvider(
      create: (_) => AppProvider(),
      child: MaterialApp.router(
        routerConfig: GoRouter(
          initialLocation: location,
          routes: [
            GoRoute(
              path: '/',
              builder: (context, state) => const Sidebar(),
            ),
            GoRoute(
              path: '/random-review',
              builder: (context, state) => const Sidebar(),
            ),
          ],
        ),
      ),
    );

const _capsule = ValueKey('sidebarSelectedCapsule');
const _mediaToggle = ValueKey('sidebarMediaFilterToggle');

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('SBG-01 只有选中项带胶囊，且胶囊是渐变底', (tester) async {
    await tester.pumpWidget(_wrap('/'));
    // 级联入场动画最长 300 + index * 50ms，等它跑完
    await tester.pump(const Duration(milliseconds: 1200));

    expect(find.text('全部笔记'), findsOneWidget);
    expect(find.byKey(_capsule), findsOneWidget);
    expect(
      find.ancestor(of: find.text('全部笔记'), matching: find.byKey(_capsule)),
      findsOneWidget,
    );

    // 未选中项不应该连带铺胶囊
    expect(
      find.ancestor(of: find.text('随机回顾'), matching: find.byKey(_capsule)),
      findsNothing,
    );

    final capsule = tester.widget<DecoratedBox>(find.byKey(_capsule));
    final decoration = capsule.decoration as BoxDecoration;
    expect(decoration.gradient, isA<LinearGradient>());
    expect(decoration.borderRadius, isNotNull);

    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('SBG-02 切到随机回顾后胶囊跟着选中项走', (tester) async {
    await tester.pumpWidget(_wrap('/random-review'));
    await tester.pump(const Duration(milliseconds: 1200));

    expect(
      find.ancestor(of: find.text('随机回顾'), matching: find.byKey(_capsule)),
      findsOneWidget,
    );
    expect(
      find.ancestor(of: find.text('全部笔记'), matching: find.byKey(_capsule)),
      findsNothing,
    );
    expect(find.byKey(_capsule), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('SBG-03 菜单文案「周期回顾」', (tester) async {
    await tester.pumpWidget(_wrap('/'));
    await tester.pump(const Duration(milliseconds: 1200));

    expect(find.text('周期回顾'), findsOneWidget);
    expect(find.text('回顾'), findsNothing);

    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('SBG-04「有图片 / 有视频」默认收在「全部笔记」下面', (tester) async {
    await tester.pumpWidget(_wrap('/'));
    await tester.pump(const Duration(milliseconds: 1200));

    // 顶层不再平铺这两个筛选项
    expect(find.text('有图片'), findsNothing);
    expect(find.text('有视频'), findsNothing);
    expect(find.byKey(_mediaToggle), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('SBG-05 点箭头展开出两个筛选，再点收起', (tester) async {
    await tester.pumpWidget(_wrap('/'));
    await tester.pump(const Duration(milliseconds: 1200));

    await tester.tap(find.byKey(_mediaToggle));
    await tester.pumpAndSettle();

    expect(find.text('有图片'), findsOneWidget);
    expect(find.text('有视频'), findsOneWidget);

    await tester.tap(find.byKey(_mediaToggle));
    await tester.pumpAndSettle();

    expect(find.text('有图片'), findsNothing);
    expect(find.text('有视频'), findsNothing);

    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('SBG-06「全部标签」与上方菜单项左对齐', (tester) async {
    await tester.pumpWidget(_wrap('/'));
    // 必须等入场动画播完：SlideTransition 会把整行水平位移 -0.3 屏宽，
    // 动画没结束时测出来的左边缘是负值，会误判成布局错位。
    await tester.pumpAndSettle();

    final tags = find.text('全部标签');
    final review = find.text('周期回顾');
    expect(tags, findsOneWidget);
    expect(review, findsOneWidget);

    // 「全部标签」是单独实现的可展开项，早先自己写了一套 16/16/8 的参数，
    // 图标列比普通菜单项右移 8dp、圆角还只有一半。现在两边共用一个常量，
    // 这条测试就是防止有人再给某一行单独调参。
    expect(
      tester.getTopLeft(tags).dx,
      moreOrLessEquals(tester.getTopLeft(review).dx, epsilon: 0.5),
      reason: '两行文字的左边缘必须落在同一条竖线上',
    );

    await tester.pump(const Duration(seconds: 3));
  });
}
