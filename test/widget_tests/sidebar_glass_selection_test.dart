import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:inkpaper/providers/app_provider.dart';
import 'package:inkpaper/widgets/sidebar.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 侧边栏选中态是抽屉毛玻璃上的一层薄色标记（实色薄底 + 描边），不再手搓
/// 渐变/高光/阴影 —— 那套是为「背后没有内容的纯色板」伪造玻璃用的，抽屉
/// 本身改成真毛玻璃之后两层质感会互相打架。观感仍只能在真机上看，这里验结构。
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

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('SBG-01 只有选中项带胶囊，且是一层薄色不是实心板', (tester) async {
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

    final container = tester.widget<Container>(find.byKey(_capsule));
    final decoration = container.decoration! as BoxDecoration;
    expect(decoration.borderRadius, isNotNull);
    // 抽屉负责毛玻璃，选中项只负责高亮：不能再退回渐变/实色，否则会把
    // 底下的模糊内容整块盖死，选中项又变成一块板。
    expect(decoration.gradient, isNull);
    expect(decoration.color, isNotNull);
    expect(
      decoration.color!.a,
      lessThan(0.3),
      reason: '选中底色必须足够薄，让抽屉自己的毛玻璃透上来',
    );
    expect(decoration.border, isNotNull);

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
}
