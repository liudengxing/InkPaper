import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/utils/snackbar_utils.dart';
import 'package:liquid_glass_renderer/liquid_glass_renderer.dart';

void main() {
  Future<void> pumpHost(
    WidgetTester tester, {
    required VoidCallback onUndo,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => SnackBarUtils.showAction(
                  context,
                  '笔记已删除',
                  icon: Icons.delete_outline_rounded,
                  actionLabel: '撤销',
                  onAction: onUndo,
                ),
                child: const Text('删除'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('GA-01 删除提示渲染成玻璃胶囊，撤销可点', (tester) async {
    var undone = false;
    await pumpHost(tester, onUndo: () => undone = true);

    await tester.tap(find.text('删除'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('笔记已删除'), findsOneWidget);
    expect(find.text('撤销'), findsOneWidget);
    // 玻璃材质真的在场，退化成纯色底就算回归
    expect(find.byType(LiquidGlassLayer), findsOneWidget);
    expect(find.byType(LiquidGlass), findsOneWidget);
    // 不再用 SnackBar 自带的 action 槽
    expect(find.byType(SnackBarAction), findsNothing);

    await tester.tap(find.text('撤销'));
    await tester.pump();
    expect(undone, isTrue);

    // 退场玻璃动画 → SnackBar 隐藏动画 → 推掉自动隐藏计时器
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('笔记已删除'), findsNothing);

    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('GA-02 提示底色透明，不盖住玻璃下面的内容', (tester) async {
    await pumpHost(tester, onUndo: () {});

    await tester.tap(find.text('删除'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final snackBar = tester.widget<SnackBar>(find.byType(SnackBar));
    expect(snackBar.backgroundColor, Colors.transparent);
    expect(snackBar.elevation, 0);
    expect(snackBar.padding, EdgeInsets.zero);

    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('GA-03 入场动画：玻璃参数与位移随时间渐入', (tester) async {
    await pumpHost(tester, onUndo: () {});

    await tester.tap(find.text('删除'));
    await tester.pump();
    // 动画刚起步：折射/着色还接近零，胶囊还沉在下方
    var layer = tester.widget<LiquidGlassLayer>(find.byType(LiquidGlassLayer));
    expect(layer.settings.tintAmount, lessThan(0.2));
    final toast = find.ancestor(
      of: find.text('笔记已删除'),
      matching: find.byType(Transform),
    );
    expect(
      tester.widget<Transform>(toast.first).transform,
      isNot(equals(Matrix4.identity())),
    );

    // 动画播完：玻璃参数到位，胶囊停在最终位置
    await tester.pump(const Duration(milliseconds: 400));
    layer = tester.widget<LiquidGlassLayer>(find.byType(LiquidGlassLayer));
    expect(layer.settings.tintAmount, closeTo(0.35, 0.001));
    expect(find.text('笔记已删除'), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
  });
}
