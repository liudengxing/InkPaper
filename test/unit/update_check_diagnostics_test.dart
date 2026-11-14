import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/services/update_check_diagnostics.dart';
import 'package:inkpaper/services/update_check_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

UpdateCheckResult _result({
  String current = '1.1.86',
  String latest = '1.1.87',
  String sourceLabel = 'Gitee 镜像（国内加速）',
}) {
  return UpdateCheckResult(
    currentVersion: current,
    latestVersion: latest,
    releasePageUrl: Uri.parse('https://example.com/releases/tag/v$latest'),
    sourceLabel: sourceLabel,
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('UpdateCheckDiagnostics 记录与读取', () {
    test('DIAG-01 全新安装没有记录', () async {
      final snapshot = await UpdateCheckDiagnostics.load();
      expect(snapshot.hasRecord, isFalse);
      expect(snapshot.describe(currentVersion: '1.1.86'), '暂无检查记录');
    });

    test('DIAG-02 成功检查写入时间、版本、数据源，并能还原', () async {
      await UpdateCheckDiagnostics.recordSuccess(_result(), auto: true);

      final snapshot = await UpdateCheckDiagnostics.load();
      expect(snapshot.hasRecord, isTrue);
      expect(snapshot.failed, isFalse);
      expect(snapshot.latestVersion, '1.1.87');
      expect(snapshot.sourceLabel, 'Gitee 镜像（国内加速）');
      expect(snapshot.auto, isTrue);
      expect(snapshot.lastCheckAt, isNotNull);

      final text = snapshot.describe(currentVersion: '1.1.86');
      expect(text, contains('v1.1.87'));
      expect(text, contains('Gitee'));
      expect(text, contains('有新版本'));
      expect(text, contains('自动'));
    });

    test('DIAG-03 版本没变时描述为已是最新', () async {
      await UpdateCheckDiagnostics.recordSuccess(
        _result(latest: '1.1.86'),
        auto: true,
      );
      final snapshot = await UpdateCheckDiagnostics.load();
      expect(
        snapshot.describe(currentVersion: '1.1.86'),
        contains('已是最新'),
      );
    });

    test('DIAG-04 手动检查标记为手动', () async {
      await UpdateCheckDiagnostics.recordSuccess(_result(), auto: false);
      final snapshot = await UpdateCheckDiagnostics.load();
      expect(snapshot.auto, isFalse);
      expect(snapshot.describe(currentVersion: '1.1.86'), contains('手动'));
    });

    test('DIAG-16 记下检查时的应用版本，升级后可判断', () async {
      await UpdateCheckDiagnostics.recordSuccess(_result(), auto: true);
      final before = await UpdateCheckDiagnostics.load();
      expect(before.lastCheckVersion, '1.1.86');

      await UpdateCheckDiagnostics.recordFailure(
        '请求超时',
        auto: true,
        currentVersion: '1.1.87',
      );
      final after = await UpdateCheckDiagnostics.load();
      expect(after.lastCheckVersion, '1.1.87');
    });

    test('DIAG-05 失败后记录原因，且清掉上一轮的版本号', () async {
      await UpdateCheckDiagnostics.recordSuccess(_result(), auto: true);
      await UpdateCheckDiagnostics.recordFailure(
        '请求超时，请稍后重试',
        auto: true,
        currentVersion: '1.1.86',
      );

      final snapshot = await UpdateCheckDiagnostics.load();
      expect(snapshot.failed, isTrue);
      expect(snapshot.lastCheckAt, isNotNull);
      expect(snapshot.latestVersion, isNull);

      final text = snapshot.describe(currentVersion: '1.1.86');
      expect(text, contains('失败'));
      expect(text, contains('请求超时'));
      // 上一轮查到的 1.1.87 不能再出现，否则用户会以为这次也查到了
      expect(text, isNot(contains('v1.1.87')));
    });

    test('DIAG-06 成功会清掉上一轮的失败原因', () async {
      await UpdateCheckDiagnostics.recordFailure(
        '网络请求失败',
        auto: true,
        currentVersion: '1.1.86',
      );
      await UpdateCheckDiagnostics.recordSuccess(_result(), auto: true);

      final snapshot = await UpdateCheckDiagnostics.load();
      expect(snapshot.failed, isFalse);
      expect(
        snapshot.describe(currentVersion: '1.1.86'),
        isNot(contains('失败')),
      );
    });

    test('DIAG-07 失败也写时间戳，节流才生效', () async {
      await UpdateCheckDiagnostics.recordFailure(
        '请求超时',
        auto: true,
        currentVersion: '1.1.86',
      );
      final snapshot = await UpdateCheckDiagnostics.load();
      expect(snapshot.lastCheckAt, isNotNull);
    });

    test('DIAG-08 只有旧版本留下的时间戳时如实说明', () async {
      // 1.1.86 及更早只写过 update_last_check_at，升级后第一次打开就是这个状态
      SharedPreferences.setMockInitialValues({
        UpdateCheckDiagnostics.lastCheckAtKey:
            DateTime(2026, 11, 14, 15, 30).millisecondsSinceEpoch,
      });
      final snapshot = await UpdateCheckDiagnostics.load();
      expect(snapshot.hasRecord, isTrue);
      expect(snapshot.describe(currentVersion: '1.1.86'), contains('未记录结果'));
    });

    test('DIAG-09 过长的错误信息会截断', () {
      final snapshot = UpdateCheckDiagnostics(
        lastCheckAt: DateTime(2026, 11, 14, 15, 30),
        errorMessage: 'x'.padRight(200, 'x'),
      );
      final text = snapshot.describe(currentVersion: '1.1.86');
      expect(text.length, lessThan(120));
      expect(text, endsWith('…'));
    });
  });

  group('UpdateCheckDiagnostics 稍后再说', () {
    test('DIAG-10 记录后可读出提示，清除后消失', () async {
      await UpdateCheckDiagnostics.recordSkipped('1.1.87');
      var snapshot = await UpdateCheckDiagnostics.load();
      expect(snapshot.skippedVersion, '1.1.87');
      expect(snapshot.skippedHint, contains('1.1.87'));

      await UpdateCheckDiagnostics.clearSkipped();
      snapshot = await UpdateCheckDiagnostics.load();
      expect(snapshot.skippedVersion, isNull);
      expect(snapshot.skippedHint, isNull);
    });

    test('DIAG-11 空字符串当作没有跳过记录', () async {
      SharedPreferences.setMockInitialValues({
        UpdateCheckDiagnostics.skippedVersionKey: '',
      });
      final snapshot = await UpdateCheckDiagnostics.load();
      expect(snapshot.skippedVersion, isNull);
      expect(snapshot.skippedHint, isNull);
    });
  });

  group('UpdateCheckDiagnostics.formatTime', () {
    test('DIAG-12 当天只显示时分', () {
      expect(
        UpdateCheckDiagnostics.formatTime(
          DateTime(2026, 11, 14, 9, 5),
          now: DateTime(2026, 11, 14, 16),
        ),
        '09:05',
      );
    });

    test('DIAG-13 今年但非当天补上月日', () {
      expect(
        UpdateCheckDiagnostics.formatTime(
          DateTime(2026, 11, 13, 9, 5),
          now: DateTime(2026, 11, 14, 16),
        ),
        '11-13 09:05',
      );
    });

    test('DIAG-14 跨年补上年份', () {
      expect(
        UpdateCheckDiagnostics.formatTime(
          DateTime(2025, 12, 31, 23, 59),
          now: DateTime(2026, 1, 1, 0, 30),
        ),
        '2025-12-31 23:59',
      );
    });
  });

  group('UpdateCheckDiagnostics.shortSource', () {
    test('DIAG-15 完整展示名压成简称', () {
      expect(
        UpdateCheckDiagnostics.shortSource('Gitee 镜像（国内加速）'),
        'Gitee',
      );
      expect(UpdateCheckDiagnostics.shortSource('GitHub'), 'GitHub');
      expect(UpdateCheckDiagnostics.shortSource(''), isNull);
      expect(UpdateCheckDiagnostics.shortSource(null), isNull);
      expect(UpdateCheckDiagnostics.shortSource('自建源'), '自建源');
    });
  });
}
