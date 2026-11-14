// ============================================================
// 第三档测试 · 图片查看器手势仲裁
//
// 历史：
// - 最初用 InteractiveViewer，单帧位移超过 kPanSlop（36dp）时缩放识别器抢走手势，
//   快滑翻不了页。
// - 1.1.78 改成自管 `_PhotoScaleGestureRecognizer`，单指未放大时让位给 PageView，
//   但 PageView 的拖动（18dp）和缩放的 kScaleSlop（18dp）仍在同一个竞技场里抢，
//   捏合时第一根手指先横滑 18dp 就判成翻页。
// - 1.1.82 起查看器只有一个识别器 `_ViewerGestureRecognizer`：翻页也由它驱动
//   （PageView physics 恒为 NeverScrollable），双指落下即抢手势，仲裁冲突消失。
// ============================================================

import 'dart:math' as math;

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

/// 查看器里只有当前页挂缩放矩阵，相邻页不挂 Transform。
double _photoScale(WidgetTester tester) => tester
    .widgetList<Transform>(
      find.descendant(
        of: find.byType(ImageViewerScreen),
        matching: find.byType(Transform),
      ),
    )
    .map((transform) => transform.transform.getMaxScaleOnAxis())
    .fold<double>(1, math.max);

/// 分步拖动并带上时间戳，否则速度恒为 0、翻页会卡在阈值上。
Future<void> _steppedDrag(
  WidgetTester tester,
  Offset from,
  double dx, {
  int steps = 10,
  int intervalMs = 16,
}) async {
  var tick = 0;
  final gesture = await tester.startGesture(from);
  for (var i = 1; i <= steps; i++) {
    await gesture.moveTo(
      from + Offset(dx * i / steps, 0),
      timeStamp: Duration(milliseconds: tick += intervalMs),
    );
    await tester.pump(Duration(milliseconds: intervalMs));
  }
  await gesture.up(timeStamp: Duration(milliseconds: tick += intervalMs));
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

  testWidgets('IVG-05 放大后界内平移不翻页', (tester) async {
    await _pumpViewer(tester);
    await _pinchOut(tester);

    // 小幅横滑，图片还在平移空间内：只平移，不翻页。
    await _steppedDrag(tester, const Offset(700, 300), -60);

    expect(find.text('2/3'), findsOneWidget);
    expect(_photoScale(tester), greaterThan(1.2));
  });

  testWidgets('IVG-10 放大后拖到边缘继续拖，翻到下一张', (tester) async {
    await _pumpViewer(tester);
    await _pinchOut(tester);

    // pinch 结束后图片被收敛到一侧边缘，先拖完剩余平移空间，
    // 越过边缘的量再接给翻页 —— 拖动量要盖过两段之和。
    await _steppedDrag(tester, const Offset(700, 300), -1200, steps: 16);

    expect(find.text('3/3'), findsOneWidget);
    // 翻页后新页从「完整显示」开始。
    expect(_photoScale(tester), lessThan(1.05));
  });

  testWidgets('IVG-11 放大态边缘拖一点点就松手，弹回原页且保持放大', (tester) async {
    await _pumpViewer(tester);
    await _pinchOut(tester);

    // 慢速小幅拖动：距离与速度都不够，页面弹回，图片保持放大。
    await _steppedDrag(
      tester,
      const Offset(700, 300),
      -90,
      steps: 12,
      intervalMs: 40,
    );

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

  testWidgets('IVG-07 先横拖一点再补第二根手指 → 改成缩放，不翻页', (tester) async {
    await _pumpViewer(tester);
    expect(find.text('2/3'), findsOneWidget);

    var tick = 0;
    // 第一根手指先横滑 40dp（越过 18dp 的接管阈值，按老实现这里已经被判成翻页）
    final left = await tester.startGesture(const Offset(400, 300));
    for (var i = 1; i <= 4; i++) {
      await left.moveTo(
        const Offset(400, 300) + Offset(-10.0 * i, 0),
        timeStamp: Duration(milliseconds: tick += 16),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    // 补上第二根手指
    final right = await tester.startGesture(const Offset(500, 300));
    await tester.pump();

    for (var i = 1; i <= 10; i++) {
      await left.moveTo(
        Offset(360 - i * 8.0, 300),
        timeStamp: Duration(milliseconds: tick += 16),
      );
      await right.moveTo(
        Offset(500 + i * 8.0, 300),
        timeStamp: Duration(milliseconds: tick += 16),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    await left.up(timeStamp: Duration(milliseconds: tick += 16));
    await right.up(timeStamp: Duration(milliseconds: tick += 16));
    await tester.pumpAndSettle();

    expect(_photoScale(tester), greaterThan(1.2));
    expect(find.text('2/3'), findsOneWidget);
  });

  testWidgets('IVG-08 慢慢拖一点点就松手，弹回原页', (tester) async {
    await _pumpViewer(tester);

    // 60dp ≈ 屏宽的 7.5%，速度只有 125dp/s —— 两个门槛都没过
    await _steppedDrag(
      tester,
      const Offset(400, 300),
      -60,
      steps: 12,
      intervalMs: 40,
    );

    expect(find.text('2/3'), findsOneWidget);
  });

  testWidgets('IVG-09 捏合后抬起一根手指继续拖，倍数不弹回 1', (tester) async {
    await _pumpViewer(tester);

    var tick = 0;
    final left = await tester.startGesture(const Offset(300, 300));
    final right = await tester.startGesture(const Offset(420, 300));
    await tester.pump();
    for (var i = 1; i <= 12; i++) {
      await left.moveTo(
        Offset(300 - i * 8.0, 300),
        timeStamp: Duration(milliseconds: tick += 16),
      );
      await right.moveTo(
        Offset(420 + i * 8.0, 300),
        timeStamp: Duration(milliseconds: tick += 16),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(_photoScale(tester), greaterThan(1.2));

    // 抬起右指，左指继续横向平移
    await right.up(timeStamp: Duration(milliseconds: tick += 16));
    await tester.pump(const Duration(milliseconds: 16));
    for (var i = 1; i <= 6; i++) {
      await left.moveTo(
        Offset(204 + i * 6.0, 300),
        timeStamp: Duration(milliseconds: tick += 16),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(_photoScale(tester), greaterThan(1.2));

    await left.up(timeStamp: Duration(milliseconds: tick += 16));
    await tester.pumpAndSettle();

    expect(_photoScale(tester), greaterThan(1.2));
    expect(find.text('2/3'), findsOneWidget);
  });
}
