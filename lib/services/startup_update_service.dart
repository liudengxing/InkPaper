import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:inkpaper/config/app_config.dart';
import 'package:inkpaper/services/app_info_service.dart';
import 'package:inkpaper/services/update_check_diagnostics.dart';
import 'package:inkpaper/services/update_check_service.dart';
import 'package:inkpaper/utils/logger.dart';
import 'package:inkpaper/widgets/update_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 开屏自动检查更新。
///
/// 之前只有「关于页 → 检查更新」一个入口，用户得先想起来去点；现在冷启动后
/// 自动拉一次 Release，有新版本直接在弹窗里下载安装。
///
/// 三条「不打扰」的规矩：
/// - 首帧之后再等 [launchDelay]，别把弹窗糊在启动页上；
/// - 两次自动检查间隔不少于 [minInterval]，一天最多叨扰几次；
/// - 用户点过「稍后再说」的版本记下来，同一个版本不再问第二遍，出了新版本
///   照常提示。
///
/// 每次检查的结论都会落到 [UpdateCheckDiagnostics]，关于页可查 —— 静默跳过
/// 是这套机制的本意，但「为什么没提示」必须能回答。
class StartupUpdateService {
  StartupUpdateService._();

  static const Logger _log = Logger('StartupUpdate');

  /// 自动检查的最小间隔。
  ///
  /// 原来是 6 小时，代价是「傍晚发版、用户早上开过 App」这种常见组合要等到
  /// 下午才会提示。发版节奏是一天几次，2 小时既能让新版本在两小时内被发现，
  /// 也不至于每次冷启动都发请求。成不成功都会写时间戳，弱网下不会反复超时。
  static const Duration minInterval = Duration(hours: 2);

  /// 首帧之后再缓一下，让首页先把内容渲染出来
  static const Duration launchDelay = Duration(milliseconds: 1500);

  /// 现在该不该发请求。首次总该查一次；刚升级过也总该查一次。
  ///
  /// 「刚升级过」这条是后加的：升级到新版本之后，节流窗口里那条旧记录是上一版
  /// 写的，再拿它挡着就等于「刚装好却什么都看不到」—— 诊断里也是一片空白。
  /// 判定用版本号而不是时间，[currentVersion] 拿不到（未初始化成 `0.0.0`）时
  /// 不参与判断，免得变成每次启动都发请求。
  static bool shouldCheckNow({
    required DateTime now,
    DateTime? lastCheckAt,
    String? lastCheckVersion,
    String? currentVersion,
  }) {
    if (lastCheckAt == null) {
      return true;
    }
    final current = currentVersion;
    if (current != null && current.isNotEmpty && current != '0.0.0') {
      if (lastCheckVersion != current) {
        return true;
      }
    }
    return now.difference(lastCheckAt) >= minInterval;
  }

  /// 这次结果该不该弹窗：确实有更新，且不是用户已经点过「稍后再说」的版本。
  static bool shouldPrompt({
    required String latestVersion,
    required String currentVersion,
    String? skippedVersion,
  }) {
    if (compareVersions(latestVersion, currentVersion) <= 0) {
      return false;
    }
    return skippedVersion != latestVersion;
  }

  /// 冷启动后调用一次；本身不阻塞调用方，所有异常都吞掉。
  ///
  /// [navigatorState] 传一个「取当前 Navigator」的回调即可，这样本服务不用
  /// 依赖 GoRouter，也不会把 BuildContext 长期持有在闭包里。
  static Future<void> checkOnLaunch({
    required NavigatorState? Function() navigatorState,
  }) async {
    final service = UpdateCheckService();
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(AppConfig.prefKeyFirstLaunch) ?? true) {
        // 首次启动：先让引导页走完，不叠加弹窗。
        return;
      }
      final diagnostics = UpdateCheckDiagnostics.fromPrefs(prefs);
      final currentVersion = AppInfoService.version;
      if (!shouldCheckNow(
        now: DateTime.now(),
        lastCheckAt: diagnostics.lastCheckAt,
        lastCheckVersion: diagnostics.lastCheckVersion,
        currentVersion: currentVersion,
      )) {
        return;
      }

      await Future<void>.delayed(launchDelay);
      final UpdateCheckResult result;
      try {
        result = await service.check();
      } on UpdateCheckException catch (e) {
        // 失败也写时间戳：否则弱网下每次冷启动都要重超时一遍（两个源各 10 秒）。
        await UpdateCheckDiagnostics.recordFailure(
          e.message,
          auto: true,
          currentVersion: currentVersion,
        );
        _log.warning('Startup update check failed', data: {'error': e.message});
        return;
      }
      await UpdateCheckDiagnostics.recordSuccess(result, auto: true);

      if (!shouldPrompt(
        latestVersion: result.latestVersion,
        currentVersion: result.currentVersion,
        skippedVersion: diagnostics.skippedVersion,
      )) {
        _log.info(
          'Startup update check found nothing to prompt',
          data: {
            'current': result.currentVersion,
            'latest': result.latestVersion,
            'skipped': diagnostics.skippedVersion,
          },
        );
        return;
      }

      final context = navigatorState()?.context;
      if (context == null || !context.mounted) {
        return;
      }
      _log.info(
        'Prompting update',
        data: {'latest': result.latestVersion, 'source': result.sourceId},
      );
      await showUpdateDialog(
        context,
        result,
        onPostpone: () => unawaited(
          UpdateCheckDiagnostics.recordSkipped(result.latestVersion),
        ),
      );
    } on Object catch (e) {
      // 开屏检查是锦上添花，网络不通、接口变更都不该影响用户打开应用。
      _log.debug('Startup update check skipped', data: {'error': '$e'});
    } finally {
      service.dispose();
    }
  }
}
