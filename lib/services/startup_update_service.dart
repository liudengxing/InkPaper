import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:inkpaper/config/app_config.dart';
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
class StartupUpdateService {
  StartupUpdateService._();

  static const Logger _log = Logger('StartupUpdate');

  /// 用户明确说过「稍后再说」的版本号
  static const String skippedVersionKey = 'update_skipped_version';

  /// 上次自动检查的时间戳（毫秒）
  static const String lastCheckAtKey = 'update_last_check_at';

  /// 自动检查的最小间隔
  static const Duration minInterval = Duration(hours: 6);

  /// 首帧之后再缓一下，让首页先把内容渲染出来
  static const Duration launchDelay = Duration(milliseconds: 1500);

  /// 现在该不该发请求。首次总该查一次。
  static bool shouldCheckNow({required DateTime now, DateTime? lastCheckAt}) {
    if (lastCheckAt == null) {
      return true;
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
      final lastMs = prefs.getInt(lastCheckAtKey);
      final lastCheckAt =
          lastMs == null ? null : DateTime.fromMillisecondsSinceEpoch(lastMs);
      if (!shouldCheckNow(now: DateTime.now(), lastCheckAt: lastCheckAt)) {
        return;
      }

      await Future<void>.delayed(launchDelay);
      final result = await service.check();
      unawaited(
        prefs.setInt(lastCheckAtKey, DateTime.now().millisecondsSinceEpoch),
      );

      if (!shouldPrompt(
        latestVersion: result.latestVersion,
        currentVersion: result.currentVersion,
        skippedVersion: prefs.getString(skippedVersionKey),
      )) {
        _log.info(
          'Startup update check found nothing to prompt',
          data: {
            'current': result.currentVersion,
            'latest': result.latestVersion,
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
          prefs.setString(skippedVersionKey, result.latestVersion),
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
