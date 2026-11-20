import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:inkpaper/providers/app_provider.dart';
import 'package:inkpaper/widgets/sidebar.dart';
import 'package:liquid_glass_renderer/liquid_glass_renderer.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 侧边栏选中态是玻璃胶囊：`flutter test` 里是 FakeGlass，只能验结构，
/// 观感（倒角折射、glint、品牌色深浅）必须在真机上看。
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

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('SBG-01 选中项包在玻璃里，未选中项没有', (tester) async {
    await tester.pumpWidget(_wrap('/'));
    // 级联入场动画最长 300 + index * 50ms，等它跑完
    await tester.pump(const Duration(milliseconds: 1200));

    expect(find.text('全部笔记'), findsOneWidget);
    final selected = find.ancestor(
      of: find.text('全部笔记'),
      matching: find.byType(LiquidGlass),
    );
    expect(selected, findsOneWidget);

    // 未选中项不应该连带铺玻璃：侧边栏铺满 7 颗玻璃会直接掉帧
    final unselected = find.ancestor(
      of: find.text('随机回顾'),
      matching: find.byType(LiquidGlass),
    );
    expect(unselected, findsNothing);

    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('SBG-02 切到随机回顾后玻璃跟着选中项走', (tester) async {
    await tester.pumpWidget(_wrap('/random-review'));
    await tester.pump(const Duration(milliseconds: 1200));

    expect(
      find.ancestor(
        of: find.text('随机回顾'),
        matching: find.byType(LiquidGlass),
      ),
      findsOneWidget,
    );
    expect(
      find.ancestor(
        of: find.text('全部笔记'),
        matching: find.byType(LiquidGlass),
      ),
      findsNothing,
    );
    // 整棵树只有一颗玻璃，别让层级叠加
    expect(find.byType(LiquidGlass), findsOneWidget);

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
