import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/services/startup_update_service.dart';

void main() {
  group('StartupUpdateService.shouldPrompt', () {
    test('远端版本更新时有新版本才提示', () {
      expect(
        StartupUpdateService.shouldPrompt(
          latestVersion: '1.1.77',
          currentVersion: '1.1.76',
        ),
        isTrue,
      );
    });

    test('版本相同时不提示', () {
      expect(
        StartupUpdateService.shouldPrompt(
          latestVersion: '1.1.76',
          currentVersion: '1.1.76',
        ),
        isFalse,
      );
    });

    test('远端版本更低时不提示（灰度回滚场景）', () {
      expect(
        StartupUpdateService.shouldPrompt(
          latestVersion: '1.1.70',
          currentVersion: '1.1.76',
        ),
        isFalse,
      );
    });

    test('用户点过「稍后再说」的同一个版本不再提示', () {
      expect(
        StartupUpdateService.shouldPrompt(
          latestVersion: '1.1.77',
          currentVersion: '1.1.76',
          skippedVersion: '1.1.77',
        ),
        isFalse,
      );
    });

    test('出现更新的版本时，之前跳过的不影响这次提示', () {
      expect(
        StartupUpdateService.shouldPrompt(
          latestVersion: '1.1.78',
          currentVersion: '1.1.76',
          skippedVersion: '1.1.77',
        ),
        isTrue,
      );
    });
  });

  group('StartupUpdateService.shouldCheckNow', () {
    final now = DateTime(2026, 11, 12, 18);

    test('节流窗口是 2 小时', () {
      // 原来是 6 小时，「上午开过 App、下午发版」要等到晚上才提示。
      expect(StartupUpdateService.minInterval, const Duration(hours: 2));
    });

    test('从未检查过就查', () {
      expect(StartupUpdateService.shouldCheckNow(now: now), isTrue);
    });

    test('刚查过不久就不再查', () {
      expect(
        StartupUpdateService.shouldCheckNow(
          now: now,
          lastCheckAt: now.subtract(const Duration(minutes: 30)),
        ),
        isFalse,
      );
    });

    test('超过节流窗口后重新检查', () {
      expect(
        StartupUpdateService.shouldCheckNow(
          now: now,
          lastCheckAt: now.subtract(
            StartupUpdateService.minInterval + const Duration(minutes: 1),
          ),
        ),
        isTrue,
      );
    });

    test('系统时间被往回调时不会卡死检查', () {
      // lastCheckAt 在未来：差值取负，按「还没到间隔」处理，最多这一轮不查。
      expect(
        StartupUpdateService.shouldCheckNow(
          now: now,
          lastCheckAt: now.add(const Duration(days: 1)),
        ),
        isFalse,
      );
    });

    test('刚升级过，节流窗口里也要查一次', () {
      // 上一版的记录挡着，就等于「刚装好却什么都看不到」
      expect(
        StartupUpdateService.shouldCheckNow(
          now: now,
          lastCheckAt: now.subtract(const Duration(minutes: 10)),
          lastCheckVersion: '1.1.86',
          currentVersion: '1.1.87',
        ),
        isTrue,
      );
    });

    test('版本没变时仍按节流窗口', () {
      expect(
        StartupUpdateService.shouldCheckNow(
          now: now,
          lastCheckAt: now.subtract(const Duration(minutes: 10)),
          lastCheckVersion: '1.1.87',
          currentVersion: '1.1.87',
        ),
        isFalse,
      );
    });

    test('版本号没拿到时不触发「刚升级」分支', () {
      // AppInfoService 未初始化时会返回 0.0.0，不能让节流失效变成每次冷启动都查
      expect(
        StartupUpdateService.shouldCheckNow(
          now: now,
          lastCheckAt: now.subtract(const Duration(minutes: 10)),
          lastCheckVersion: '1.1.86',
          currentVersion: '0.0.0',
        ),
        isFalse,
      );
    });
  });
}
