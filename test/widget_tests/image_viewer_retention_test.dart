// ============================================================
// 第三档测试 · 图片查看器的高清图保留窗口
//
// 历史：
// - 原来每页 `_PhotoPage.dispose` 自己 evict 高清图：翻走的瞬间就清掉，
//   回看同一张要重新解码（12MP 原图 150~300ms）；而 `_precacheAround` 预取
//   的那张从未显示过，页面不会替它收尾，退出查看器后它还留在全局缓存里。
// - 现在由查看器按「当前页左右各一张」的窗口统一记账：窗口内的留在缓存里，
//   窗口外的立刻 evict，整个查看器退出时全部清掉。
//
// 判定方式：`ImageCache.containsKey(key)` —— 键还在缓存里就说明 `resolve`
// 会直接命中，不会重新解码。
// ============================================================

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:inkpaper/screens/image_viewer_screen.dart';
import 'package:path/path.dart' as p;

/// 测试里的查看器解码宽度（屏幕 800×600、dpr 3 → 3600 封顶到 1600）。
const int _decodeWidth = 1600;

/// 让真实 IO / 解码推进，同时把假时钟往前拨，等 180ms 的预取定时器触发。
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump(const Duration(milliseconds: 60));
  }
}

/// 分步拖动并带上时间戳，否则速度恒为 0、翻页会卡在阈值上。
Future<void> _steppedDrag(
  WidgetTester tester,
  double dx, {
  int steps = 10,
  int intervalMs = 16,
}) async {
  const from = Offset(300, 300);
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
  await _settle(tester);
}

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('viewer-retention');
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  });

  tearDown(() {
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });

  /// 造 [count] 张纯色 PNG，返回各自的查看器缓存键。
  Future<List<Object>> makeKeys(WidgetTester tester, int count) async {
    final keys = <Object>[];
    for (var i = 0; i < count; i++) {
      final image = img.Image(width: 1200, height: 900);
      img.fill(image, color: img.ColorRgb8(20 + i * 40, 60, 90));
      final file = File(p.join(dir.path, 'p$i.png'))
        ..writeAsBytesSync(img.encodePng(image));
      final provider = ResizeImage(FileImage(file), width: _decodeWidth);
      keys.add(await provider.obtainKey(ImageConfiguration.empty));
    }
    return keys;
  }

  Future<void> pumpViewer(
    WidgetTester tester,
    int count, {
    int initialIndex = 0,
  }) async {
    tester.view.physicalSize = const Size(2400, 1800);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: ImageViewerScreen(
          imagePaths: [
            for (var i = 0; i < count; i++)
              'file://${p.join(dir.path, 'p$i.png')}',
          ],
          initialIndex: initialIndex,
        ),
      ),
    );
    await _settle(tester);
  }

  bool cached(Object key) =>
      PaintingBinding.instance.imageCache.containsKey(key);

  List<bool> snapshot(List<Object> keys) => keys.map(cached).toList();

  testWidgets('IVR-01 打开后当前页与下一张已解码', (tester) async {
    final keys = await makeKeys(tester, 3);
    await pumpViewer(tester, 3);

    expect(
      cached(keys[0]),
      isTrue,
      reason: '当前页的解码键要和保留窗口算的是同一个（同一路径同一宽度）',
    );
    expect(cached(keys[1]), isTrue, reason: '打开后预取下一张');
    expect(cached(keys[2]), isFalse, reason: '预取只取一张');
  });

  testWidgets('IVR-02 翻页不清理刚离开的那张（回看不重解码）', (tester) async {
    final keys = await makeKeys(tester, 3);
    await pumpViewer(tester, 3);

    await _steppedDrag(tester, -400);

    expect(
      snapshot(keys),
      <bool>[true, true, true],
      reason: '翻到第 2 张时，第 1 张（窗口左邻）必须还在缓存里，'
          '否则回看要重新解码；第 3 张由预取补上',
    );
  });

  testWidgets('IVR-03 连续翻图只留窗口内的三张', (tester) async {
    final keys = await makeKeys(tester, 5);
    await pumpViewer(tester, 5);

    await _steppedDrag(tester, -400); // → 1
    await _steppedDrag(tester, -400); // → 2

    expect(
      snapshot(keys),
      <bool>[false, true, true, true, false],
      reason: '窗口挪到 {1,2,3}：第 0 张出窗口必须释放，第 4 张不该提前解码',
    );

    await _steppedDrag(tester, -400); // → 3
    expect(
      snapshot(keys),
      <bool>[false, false, true, true, true],
      reason: '继续翻只换掉窗口最左那张，缓存里始终最多三张高清图',
    );
  });

  testWidgets('IVR-04 回看相邻页命中缓存', (tester) async {
    final keys = await makeKeys(tester, 4);
    await pumpViewer(tester, 4, initialIndex: 1);

    await _steppedDrag(tester, -400); // 1 → 2
    await _steppedDrag(tester, 400); // 2 → 1

    expect(
      cached(keys[1]),
      isTrue,
      reason: '回看的那张全程没离开窗口，一次都不用重新解码',
    );
    expect(
      snapshot(keys),
      <bool>[true, true, true, false],
      reason: '回到 1 号后窗口是 {0,1,2}，3 号（预取过）该被释放',
    );
  });

  testWidgets('IVR-05 退出查看器后高清图全部释放', (tester) async {
    final keys = await makeKeys(tester, 3);
    await pumpViewer(tester, 3);
    await _steppedDrag(tester, -400); // → 1，2 号被预取进缓存

    expect(cached(keys[2]), isTrue, reason: '前置条件：2 号已预取');

    await tester.pumpWidget(const SizedBox.shrink());
    await _settle(tester);

    expect(
      snapshot(keys),
      <bool>[false, false, false],
      reason: '连预取但从未显示的那张也要清 —— 它没有页面替它收尾',
    );
  });
}
