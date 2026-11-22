import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:inkpaper/providers/app_provider.dart';
import 'package:inkpaper/widgets/sidebar.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 侧边栏里除了「全部笔记」，进去的都是二级页。
///
/// 早先统一用 `go()` 做平级切换，GoRouter 会把栈替换成只剩目标页 —— 于是
/// 系统返回键没有可退的路由，直接把 App 退到后台。用户从「周期回顾 / AI
/// 洞察」按返回，期望是回笔记列表。现在从首页出发用 `push()`，栈里始终留着
/// `/`；已经在二级页之间横跳则用 `replace()`，免得越叠越深要按好几次返回。
///
/// 注意别用 `router.routerDelegate.currentConfiguration.uri` 做断言：`push()`
/// 是命令式的，不经过 RouteInformationProvider，那个 uri 会一直停在旧值，
/// 明明已经 push 成功（`canPop()` 为 true）却测出「没跳转」。这里改成看顶层
/// 页面自己的 key —— Navigator 会把被盖住的 route 置为 offstage，`find`
/// 默认跳过 offstage，所以只会命中当前这一页。
Widget _wrap(GoRouter router) => ChangeNotifierProvider(
      create: (_) => AppProvider(),
      child: MaterialApp.router(routerConfig: router),
    );

GoRouter _buildRouter(String initialLocation) => GoRouter(
      initialLocation: initialLocation,
      routes: [
        for (final path in const [
          '/',
          '/random-review',
          '/random-walk',
          '/periodic-review',
          '/ai-insight',
          '/settings',
        ])
          GoRoute(
            path: path,
            // isDrawer: false —— 测试里 Sidebar 是整页，不是抽屉，避开
            // 「先 pop 关抽屉」那一步，只验导航栈语义。
            builder: (context, state) => Sidebar(
              key: ValueKey('page:$path'),
              isDrawer: false,
            ),
          ),
      ],
    );

/// 当前可见（非 offstage）的是哪一页。
void _expectVisiblePage(String path) {
  expect(
    find.byKey(ValueKey('page:$path')),
    findsOneWidget,
    reason: '当前应该停在 $path',
  );
  for (final other in const [
    '/',
    '/random-review',
    '/random-walk',
    '/periodic-review',
    '/ai-insight',
    '/settings',
  ]) {
    if (other == path) {
      continue;
    }
    expect(
      find.byKey(ValueKey('page:$other')),
      findsNothing,
      reason: '$other 不应该还在前台',
    );
  }
}

/// 默认测试视口只有 800×600，侧栏下半截（设置）落在屏幕外，
/// `tap` 打不中也不会报错 —— 只会静默「点了没反应」。放大到手机比例。
void _useTallScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// 侧栏点击后有 50ms（桌面）/ 120ms（抽屉）延迟才真正切路由。
Future<void> _tapMenu(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('随机漫步是独立侧栏入口，系统返回回到首页', (tester) async {
    _useTallScreen(tester);
    final router = _buildRouter('/');
    await tester.pumpWidget(_wrap(router));
    await tester.pumpAndSettle();

    await _tapMenu(tester, '随机漫步');
    _expectVisiblePage('/random-walk');
    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.pumpAndSettle();
    _expectVisiblePage('/');
  });

  testWidgets('SBG-07 进「周期回顾」后按返回，回「全部笔记」而不是退出 App', (
    tester,
  ) async {
    _useTallScreen(tester);
    final router = _buildRouter('/');
    await tester.pumpWidget(_wrap(router));
    await tester.pumpAndSettle();

    await _tapMenu(tester, '周期回顾');
    _expectVisiblePage('/periodic-review');
    expect(
      router.canPop(),
      isTrue,
      reason: '栈里必须留着首页，否则返回键退出 App',
    );

    // 模拟 Android 返回键：false 就代表「系统该退到桌面了」
    final handled = await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(handled, isTrue, reason: '返回事件要由 App 自己处理掉');
    _expectVisiblePage('/');

    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('SBG-08 二级页之间横跳不叠栈，一次返回就回首页', (tester) async {
    _useTallScreen(tester);
    final router = _buildRouter('/');
    await tester.pumpWidget(_wrap(router));
    await tester.pumpAndSettle();

    await _tapMenu(tester, '周期回顾');
    _expectVisiblePage('/periodic-review');

    await _tapMenu(tester, 'AI 洞察');
    _expectVisiblePage('/ai-insight');

    final handled = await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(handled, isTrue);
    _expectVisiblePage('/');

    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('SBG-09 从二级页点「全部笔记」，栈清成只剩首页', (tester) async {
    _useTallScreen(tester);
    final router = _buildRouter('/');
    await tester.pumpWidget(_wrap(router));
    await tester.pumpAndSettle();

    await _tapMenu(tester, '随机回顾');
    _expectVisiblePage('/random-review');

    await _tapMenu(tester, '全部笔记');
    _expectVisiblePage('/');
    expect(
      router.canPop(),
      isFalse,
      reason: '回首页要 go，不能把二级页留在栈底',
    );

    await tester.pump(const Duration(seconds: 3));
  });
}
