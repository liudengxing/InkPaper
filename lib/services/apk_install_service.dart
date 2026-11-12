import 'dart:io';

import 'package:flutter/services.dart';
import 'package:inkpaper/config/app_config.dart';
import 'package:inkpaper/utils/logger.dart';

/// 拉起系统安装器的结果。
enum ApkInstallStatus {
  /// 已交给系统安装界面，后续由用户确认
  started,

  /// 用户还没允许「安装未知应用」，原生侧已把设置页打开
  permissionRequired,

  /// 文件不存在（多半被系统清了缓存）
  missingFile,

  /// 系统里没有能处理 APK 的安装器（部分机型把 PackageInstaller 禁了）
  noInstaller,

  /// 当前平台没有这条原生通道（桌面 / iOS）
  unsupported,

  /// 其它原生异常
  failed,
}

/// 应用内更新安装：拿下载好的 APK 调系统安装器。
///
/// 全程只跟现有原生通道 `channelNativeAlarm` 打交道，没有新增 Flutter 依赖。
class ApkInstallService {
  ApkInstallService._();

  static const Logger _log = Logger('ApkInstall');

  static const MethodChannel _channel = MethodChannel(
    AppConfig.channelNativeAlarm,
  );

  /// 原生侧的下载目录（Android 是 `cacheDir/updates`）。
  ///
  /// 必须由原生给：FileProvider 只允许授权自己声明的路径，Dart 侧自己拼
  /// `Directory.systemTemp` 有可能落在授权范围之外，安装器会读不到文件。
  static Future<Directory?> updatesDirectory() async {
    try {
      final path = await _channel.invokeMethod<String>('getApkUpdatesDir');
      if (path == null || path.isEmpty) {
        return null;
      }
      return Directory(path);
    } on PlatformException catch (e) {
      _log.warning('读取下载目录失败', data: {'error': e.message});
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  static Future<ApkInstallStatus> install(String path) async {
    try {
      final status = await _channel.invokeMethod<String>('installApk', {
        'path': path,
      });
      switch (status) {
        case 'started':
          return ApkInstallStatus.started;
        case 'permission_required':
          return ApkInstallStatus.permissionRequired;
        case 'missing_file':
          return ApkInstallStatus.missingFile;
        case 'no_installer':
          return ApkInstallStatus.noInstaller;
        default:
          return ApkInstallStatus.failed;
      }
    } on PlatformException catch (e) {
      _log.warning('拉起安装器失败', data: {'error': e.message});
      return ApkInstallStatus.failed;
    } on MissingPluginException {
      return ApkInstallStatus.unsupported;
    }
  }
}
