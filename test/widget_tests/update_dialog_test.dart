// ============================================================
// 第三档测试 · 更新弹窗 Widget
// 只覆盖「提示态」的渲染与文案：下载/安装依赖系统通道，留给真机验证
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/services/update_check_service.dart';
import 'package:inkpaper/widgets/update_dialog.dart';

UpdateCheckResult _result({
  String current = '1.1.76',
  String latest = '1.1.77',
  String notes = '### 新增\n- 开屏检查更新',
  int? size = 52428800,
  bool withApk = true,
}) =>
    UpdateCheckResult(
      currentVersion: current,
      latestVersion: latest,
      releasePageUrl: Uri.parse(
        'https://gitee.com/liudengxing233/ink-paper/releases/tag/v$latest',
      ),
      releaseName: 'InkPaper v$latest',
      releaseNotes: notes,
      apkDownloadUrl: withApk
          ? Uri.parse(
              'https://gitee.com/liudengxing233/ink-paper/releases/download/'
              'v$latest/InkPaper-v$latest-android.apk',
            )
          : null,
      apkSizeBytes: size,
      sourceId: 'gitee',
      sourceLabel: 'Gitee 镜像（国内加速）',
    );

Future<void> _open(
  WidgetTester tester,
  UpdateCheckResult result, {
  VoidCallback? onPostpone,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showUpdateDialog(
              context,
              result,
              onPostpone: onPostpone,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  group('更新弹窗 — 提示态', () {
    testWidgets('UD-01 展示新版本号与当前版本', (tester) async {
      await _open(tester, _result());

      expect(find.text('发现新版本 v1.1.77'), findsOneWidget);
      expect(
        find.textContaining('当前 v1.1.76'),
        findsOneWidget,
      );
    });

    testWidgets('UD-02 一并展示安装包大小与下载源', (tester) async {
      await _open(tester, _result());

      expect(find.textContaining('安装包 50.0 MB'), findsOneWidget);
      expect(find.textContaining('Gitee 镜像'), findsOneWidget);
    });

    testWidgets('UD-03 展示更新内容', (tester) async {
      await _open(tester, _result(notes: '修好了下载完不弹安装'));

      expect(find.text('更新内容'), findsOneWidget);
      expect(find.textContaining('修好了下载完不弹安装'), findsOneWidget);
    });

    testWidgets('UD-04 没有更新说明时不渲染空区块', (tester) async {
      await _open(tester, _result(notes: ''));

      expect(find.text('更新内容'), findsNothing);
    });

    testWidgets('UD-05 没有 APK 直链时主按钮退化成「前往发布页」', (tester) async {
      await _open(tester, _result(withApk: false));

      expect(find.text('前往发布页'), findsOneWidget);
      expect(find.text('立即更新'), findsNothing);
    });

    testWidgets('UD-06 点「稍后再说」会通知调用方并关闭弹窗', (tester) async {
      var postponed = 0;
      await _open(tester, _result(), onPostpone: () => postponed++);

      await tester.tap(find.text('稍后再说'));
      await tester.pumpAndSettle();

      expect(postponed, 1);
      expect(find.text('发现新版本 v1.1.77'), findsNothing);
    });
  });
}
