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

    // showAction 里还有一个兜底隐藏的延时器，推掉它再结束
    await tester.pump(const Duration(seconds: 5));
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
}
