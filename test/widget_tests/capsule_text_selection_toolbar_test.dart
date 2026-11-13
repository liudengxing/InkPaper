import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/widgets/capsule_text_selection_toolbar.dart';

void main() {
  /// 测试环境默认 locale 是 en，文案按英文断言；这里只钉结构与交互。
  Future<void> pumpToolbar(
    WidgetTester tester, {
    Brightness brightness = Brightness.light,
    VoidCallback? onCopy,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: brightness),
        home: Scaffold(
          body: CapsuleTextSelectionToolbar(
            anchorAbove: const Offset(200, 400),
            anchorBelow: const Offset(200, 460),
            buttonItems: [
              ContextMenuButtonItem(
                type: ContextMenuButtonType.copy,
                onPressed: onCopy ?? () {},
              ),
              ContextMenuButtonItem(
                type: ContextMenuButtonType.selectAll,
                onPressed: () {},
              ),
            ],
          ),
        ),
      ),
    );
  }

  Finder findCapsule() => find.byWidgetPredicate(
        (widget) => widget is Material && widget.borderRadius != null,
      );

  testWidgets('CST-01 胶囊尺寸：40dp 高、全圆角', (tester) async {
    await pumpToolbar(tester);

    final capsule = findCapsule();
    expect(capsule, findsOneWidget);
    expect(tester.getSize(capsule).height, 40);
    expect(
      tester.widget<Material>(capsule).borderRadius,
      BorderRadius.circular(20),
    );
  });

  testWidgets('CST-02 按钮点击回调生效', (tester) async {
    var copyTapped = 0;
    await pumpToolbar(tester, onCopy: () => copyTapped++);

    await tester.tap(find.text('Copy'));
    expect(copyTapped, 1);

    // 全选也渲染出来了，说明多个 buttonItems 都进了同一行。
    expect(find.text('Select all'), findsOneWidget);
  });

  testWidgets('CST-03 暗色模式用白字深底', (tester) async {
    await pumpToolbar(tester, brightness: Brightness.dark);

    expect(
      tester.widget<Material>(findCapsule()).color,
      const Color(0xFF252525),
    );
    expect(
      tester.widget<Text>(find.text('Copy')).style?.color,
      Colors.white,
    );
  });
}
