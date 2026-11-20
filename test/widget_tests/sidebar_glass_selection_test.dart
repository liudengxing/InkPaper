import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:inkpaper/providers/app_provider.dart';
import 'package:inkpaper/widgets/sidebar.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 侧边栏选中态是一块很淡的品牌色底 + 同色小投影，字色就是品牌绿本身。
/// 1.1.118 之后中间试过「品牌色渐变胶囊 + 顶部白色高光」的玻璃观感，真机上
/// 偏重而且和白色抽屉不搭，用户否掉，已经退回原样。别再往选中态加渐变。
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

const _selectedRow = ValueKey('sidebarSelectedRow');
const _mediaToggle = ValueKey('sidebarMediaFilterToggle');

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('SBG-01 只有选中项带底色，且是淡品牌色 + 同色投影', (tester) async {
    await tester.pumpWidget(_wrap('/'));
    // 级联入场动画最长 300 + index * 50ms，等它跑完
    await tester.pump(const Duration(milliseconds: 1200));

    expect(find.text('全部笔记'), findsOneWidget);
    expect(find.byKey(_selectedRow), findsOneWidget);
    expect(
      find.ancestor(
        of: find.text('全部笔记'),
        matching: find.byKey(_selectedRow),
      ),
      findsOneWidget,
    );

    // 未选中项不应该连带铺底色
    expect(
      find.ancestor(of: find.text('随机回顾'), matching: find.byKey(_selectedRow)),
      findsNothing,
    );

    final row = tester.widget<Container>(find.byKey(_selectedRow));
    final decoration = row.decoration! as BoxDecoration;
    // 实色淡品牌色，不是渐变
    expect(decoration.gradient, isNull);
    expect(decoration.color, isNotNull);
    expect(decoration.color!.a, lessThan(0.2));
    expect(decoration.borderRadius, isNotNull);
    expect(decoration.boxShadow, isNotEmpty);

    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('SBG-02 切到随机回顾后底色跟着选中项走', (tester) async {
    await tester.pumpWidget(_wrap('/random-review'));
    await tester.pump(const Duration(milliseconds: 1200));

    expect(
      find.ancestor(
        of: find.text('随机回顾'),
        matching: find.byKey(_selectedRow),
      ),
      findsOneWidget,
    );
    expect(
      find.ancestor(of: find.text('全部笔记'), matching: find.byKey(_selectedRow)),
      findsNothing,
    );
    expect(find.byKey(_selectedRow), findsOneWidget);

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
