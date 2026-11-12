// ============================================================
// 第三档测试 · 图片查看器手势仲裁
// 覆盖「单指翻页」与「双指缩放」谁该赢的那条边界：
// 改前 InteractiveViewer 的 ScaleGestureRecognizer 会在单帧位移超过
// kPanSlop（36dp）时抢走手势，快速滑动翻不了页；改成自管
// _PhotoScaleGestureRecognizer 后单指横滑全部让给 PageView。
// ============================================================

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/screens/image_viewer_screen.dart';

const List<String> _paths = <String>[
  'resource:assets/images/logo.png',
  'resource:assets/images/logo.png',
  'resource:assets/images/logo.png',
];

/// 等图片解码完成 —— 图片没了定位尺寸，手势层根本不会构建。
Future<void> _pumpViewer(WidgetTester tester, {int initialIndex = 1}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: ImageViewerScreen(imagePaths: _paths, initialIndex: initialIndex),
    ),
  );
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 120));
  });
  await tester.pumpAndSettle();
}

/// 查看器里唯一那层缩放用的 Transform（OverflowBox 里面）。
Transform _photoTransform(WidgetTester tester) => tester.widget<Transform>(
      find
          .descendant(
            of: find.byType(ImageViewerScreen),
            matching: find.descendant(
              of: find.byType(OverflowBox),
              matching: find.byType(Transform),
            ),
          )
          .first,
    );

double _photoScale(WidgetTester tester) =>
    _photoTransform(tester).transform.getMaxScaleOnAxis();

/// 分步拖动并带上时间戳，否则速度恒为 0、翻页会卡在 50% 阈值上。
Future<void> _steppedDrag(
  WidgetTester tester,
  Offset from,
  double dx, {
  int steps = 10,
}) async {
  var tick = 0;
  final gesture = await tester.startGesture(from);
  for (var i = 1; i <= steps; i++) {
    await gesture.moveTo(
      from + Offset(dx * i / steps, 0),
      timeStamp: Duration(milliseconds: tick += 16),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
  await gesture.up(timeStamp: Duration(milliseconds: tick += 16));
  await tester.pumpAndSettle();
}

Future<void> _pinchOut(WidgetTester tester) async {
  var tick = 0;
  final left = await tester.startGesture(const Offset(300, 300));
  final right = await tester.startGesture(const Offset(420, 300));
  await tester.pump();
  for (var i = 1; i <= 12; i++) {
    await left.moveTo(
      Offset(300 - i * 8, 300),
      timeStamp: Duration(milliseconds: tick += 16),
    );
    await right.moveTo(
      Offset(420 + i * 8, 300),
      timeStamp: Duration(milliseconds: tick += 16),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
  await left.up(timeStamp: Duration(milliseconds: tick += 16));
  await right.up(timeStamp: Duration(milliseconds: tick += 16));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('IVG-01 单指慢滑（单帧 20dp）能翻页', (tester) async {
    await _pumpViewer(tester);

    expect(find.text('2/3'), findsOneWidget);

    await _steppedDrag(tester, const Offset(700, 300), -480, steps: 24);

    expect(find.text('3/3'), findsOneWidget);
  });

  testWidgets('IVG-02 单指快滑（单帧 60dp）也能翻页', (tester) async {
    await _pumpViewer(tester);

    expect(find.text('2/3'), findsOneWidget);

    await _steppedDrag(tester, const Offset(700, 300), -480, steps: 8);

    expect(find.text('3/3'), findsOneWidget);
  });

  testWidgets('IVG-03 单指超快滑（单帧 240dp）依然能翻页', (tester) async {
    await _pumpViewer(tester);

    expect(find.text('2/3'), findsOneWidget);

    await _steppedDrag(tester, const Offset(700, 300), -480, steps: 2);

    expect(find.text('3/3'), findsOneWidget);
  });

  testWidgets('IVG-04 双指捏合放大，且不误翻页', (tester) async {
    await _pumpViewer(tester);

    await _pinchOut(tester);

    expect(_photoScale(tester), greaterThan(1.2));
    expect(find.text('2/3'), findsOneWidget);
  });

  testWidgets('IVG-05 放大后单指横滑只平移，不翻页', (tester) async {
    await _pumpViewer(tester);
    await _pinchOut(tester);

    await _steppedDrag(tester, const Offset(700, 300), -480);

    expect(find.text('2/3'), findsOneWidget);
    expect(_photoScale(tester), greaterThan(1.2));
  });

  testWidgets('IVG-06 桌面端滚轮可以放大', (tester) async {
    await _pumpViewer(tester);
    final mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(const Offset(400, 300)));
    await tester.pump();

    await tester.sendEventToBinding(mouse.scroll(const Offset(0, -300)));
    await tester.pumpAndSettle();

    expect(_photoScale(tester), greaterThan(1.0));
    expect(find.text('2/3'), findsOneWidget);
  });
}
