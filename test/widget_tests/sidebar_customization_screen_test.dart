import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/providers/app_provider.dart';
import 'package:inkpaper/screens/sidebar_customization_screen.dart';
import 'package:provider/provider.dart';

Widget _wrap(Widget child) => ChangeNotifierProvider(
      create: (_) => AppProvider(),
      child: MaterialApp(home: child),
    );

void main() {
  group('SidebarCustomizationScreen（A-11 sliver 化回归）', () {
    testWidgets('SB-01 页面渲染为 CustomScrollView，菜单项列表用 SliverReorderableList',
        (tester) async {
      await tester.pumpWidget(_wrap(const SidebarCustomizationScreen()));
      await tester.pump();

      expect(find.byType(SidebarCustomizationScreen), findsOneWidget);
      expect(find.byType(CustomScrollView), findsWidgets);
      // A-11：菜单项排序列表必须是 sliver 版，不再是嵌套 ReorderableListView
      expect(find.byType(SliverReorderableList), findsOneWidget);
      expect(find.byType(ReorderableListView), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('SB-02 分组标题与开关项正常布局，滚动到底部不抛异常', (tester) async {
      await tester.pumpWidget(_wrap(const SidebarCustomizationScreen()));
      await tester.pump();

      // 分组标题（sliver 版与 _buildSection 共用 _buildSectionHeader）
      expect(find.text('菜单项'), findsOneWidget);
      expect(find.byType(Switch), findsWidgets);

      await tester.drag(
        find.byType(CustomScrollView).first,
        const Offset(0, -800),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets('SB-03 切换「显示活动记录」开关不抛异常且保持渲染', (tester) async {
      await tester.pumpWidget(_wrap(const SidebarCustomizationScreen()));
      await tester.pump();

      final firstSwitch = find.byType(Switch).first;
      await tester.tap(firstSwitch, warnIfMissed: false);
      await tester.pump();

      expect(find.byType(SidebarCustomizationScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('SB-04 拖动手柄可重排菜单项并亮出「保存」', (tester) async {
      await tester.pumpWidget(_wrap(const SidebarCustomizationScreen()));
      await tester.pump();

      final handle = find.byIcon(Icons.drag_handle_rounded).first;
      final beforeY = tester.getTopLeft(find.text('随机回顾')).dy;

      // ReorderableDragStartListener 按下即开始拖动，需跨过一行高度才会换位
      await tester.timedDrag(
        handle,
        const Offset(0, 180),
        const Duration(milliseconds: 600),
      );
      await tester.pumpAndSettle();

      final afterY = tester.getTopLeft(find.text('随机回顾')).dy;
      expect(afterY, greaterThan(beforeY));
      // 顺序变化必须进入「有未保存改动」状态
      expect(find.text('保存'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
