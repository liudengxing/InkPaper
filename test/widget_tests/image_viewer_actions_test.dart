// 大图查看器的操作入口：参考微信看图，把分享/保存挪到右下角浮动，
// 顶部只留关闭按钮和页码，不再压一整条 AppBar。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/screens/image_viewer_screen.dart';

const List<String> _multiple = <String>[
  'resource:assets/images/logo.png',
  'resource:assets/images/logo.png',
  'resource:assets/images/logo.png',
];

Future<void> _pump(
  WidgetTester tester,
  List<String> paths, {
  Key? key,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      key: key,
      home: ImageViewerScreen(imagePaths: paths, initialIndex: 0),
    ),
  );
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 120));
  });
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('IVA-01 分享与保存按钮停在右下角，顶部不再有 AppBar', (tester) async {
    await _pump(tester, _multiple);

    final screen = tester.getSize(find.byType(Scaffold).first);
    final share = tester.getRect(find.byIcon(Icons.north_east_rounded));
    final save = tester.getRect(find.byIcon(Icons.download_rounded));

    // 都在右半屏、靠下
    expect(share.center.dx, greaterThan(screen.width / 2));
    expect(share.center.dy, greaterThan(screen.height * 0.8));
    // 分享在左、保存在右
    expect(save.center.dx, greaterThan(share.center.dx));
    // 保存按钮贴右下，右边距不超过一个按钮宽
    expect(screen.width - save.right, lessThan(32));
    expect(screen.height - save.bottom, lessThan(80));

    expect(find.byType(AppBar), findsNothing);
  });

  testWidgets('IVA-02 关闭按钮在左上，页码只对多图出现', (tester) async {
    await _pump(tester, _multiple);

    final close = tester.getRect(find.byIcon(Icons.close_rounded));
    expect(close.center.dx, lessThan(60));
    expect(close.center.dy, lessThan(120));
    expect(find.text('1/3'), findsOneWidget);
  });

  testWidgets('IVA-03 单图不显示页码', (tester) async {
    await _pump(
      tester,
      const <String>['resource:assets/images/logo.png'],
      key: const ValueKey<String>('single'),
    );

    expect(find.byIcon(Icons.close_rounded), findsOneWidget);
    expect(find.text('1/1'), findsNothing);
  });
}
