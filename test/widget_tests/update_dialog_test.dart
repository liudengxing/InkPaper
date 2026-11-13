// ============================================================
// 第三档测试 · 更新弹窗 Widget
// 只覆盖「提示态」的渲染与文案：下载/安装依赖系统通道，留给真机验证
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/services/update_check_service.dart';
import 'package:inkpaper/widgets/update_dialog.dart';

const String _apkName = 'InkPaper-v1.1.77-android.apk';
const String _giteeApk =
    'https://gitee.com/liudengxing233/ink-paper/releases/download/v1.1.77/$_apkName';
const String _githubApk =
    'https://github.com/liudengxing/InkPaper/releases/download/v1.1.77/$_apkName';

UpdateCheckResult _result({
  String current = '1.1.76',
  String latest = '1.1.77',
  String notes = '### 新增\n- 开屏检查更新',
  int? size = 52428800,
  bool withApk = true,
  String source = 'gitee',
}) {
  final isGitee = source == 'gitee';
  return UpdateCheckResult(
    currentVersion: current,
    latestVersion: latest,
    releasePageUrl: Uri.parse(
      'https://gitee.com/liudengxing233/ink-paper/releases/tag/v$latest',
    ),
    releaseName: 'InkPaper v$latest',
    releaseNotes: notes,
    apkDownloadUrl:
        withApk ? Uri.parse(isGitee ? _giteeApk : _githubApk) : null,
    apkSizeBytes: size,
    sourceId: source,
    sourceLabel: isGitee ? 'Gitee 镜像（国内加速）' : 'GitHub',
  );
}

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

FontWeight? _weightOf(WidgetTester tester, String text) =>
    tester.widget<Text>(find.text(text)).style?.fontWeight;

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

    testWidgets('UD-02 展示安装包大小，下载源放到下方选择', (tester) async {
      await _open(tester, _result());

      expect(find.textContaining('安装包 50.0 MB'), findsOneWidget);
      expect(find.text('下载源'), findsOneWidget);
      expect(find.text('国内镜像'), findsOneWidget);
      expect(find.text('GitHub'), findsOneWidget);
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

  group('更新弹窗 — 更新说明渲染', () {
    testWidgets('UD-07 按 Markdown 渲染，不再露出 ### 与 - 标记', (tester) async {
      await _open(
        tester,
        _result(notes: '### 修复\n\n- 下载完不弹安装包\n- 空白处双击不出工具栏'),
      );

      expect(find.textContaining('###'), findsNothing);
      expect(find.textContaining('修复'), findsWidgets);
      expect(find.textContaining('下载完不弹安装包'), findsOneWidget);
      expect(find.textContaining('- 空白处双击不出工具栏'), findsNothing);
    });

    testWidgets('UD-08 裁掉发布说明末尾的下载区块', (tester) async {
      await _open(
        tester,
        _result(
          notes: '### 修复\n\n- 改了下载退路\n\n---\n\n'
              '### 下载\n\n| 源 | 地址 |\n| --- | --- |\n'
              '| 国内 | [Gitee 发行版](https://gitee.com/x) |',
        ),
      );

      expect(find.textContaining('改了下载退路'), findsOneWidget);
      expect(find.textContaining('Gitee 发行版'), findsNothing);
      expect(find.textContaining('| 国内 |'), findsNothing);
    });
  });

  group('更新弹窗 — 下载源', () {
    testWidgets('UD-09 默认选中带绿标的国内镜像', (tester) async {
      await _open(tester, _result());

      expect(_weightOf(tester, '国内镜像'), FontWeight.w600);
      expect(_weightOf(tester, 'GitHub'), FontWeight.w400);

      // 绿标是一个 6x6 的绿点
      final dots = find.byWidgetPredicate((widget) {
        if (widget is! Container) {
          return false;
        }
        final decoration = widget.decoration;
        if (decoration is! BoxDecoration) {
          return false;
        }
        return decoration.shape == BoxShape.circle &&
            decoration.color == const Color(0xFF2EA043);
      });
      expect(dots, findsOneWidget);
    });

    testWidgets('UD-10 点 GitHub 把选中态切过去', (tester) async {
      await _open(tester, _result());

      await tester.tap(find.text('GitHub'));
      await tester.pumpAndSettle();

      expect(_weightOf(tester, 'GitHub'), FontWeight.w600);
      expect(_weightOf(tester, '国内镜像'), FontWeight.w400);
    });

    testWidgets('UD-11 只有 GitHub 直链时只显示 GitHub，且仍是「立即更新」', (tester) async {
      await _open(tester, _result(source: 'github'));

      expect(find.text('国内镜像'), findsNothing);
      expect(find.text('GitHub'), findsOneWidget);
      expect(_weightOf(tester, 'GitHub'), FontWeight.w600);
      expect(find.text('立即更新'), findsOneWidget);
    });
  });
}
