import 'dart:io';

import 'package:inkpaper/services/apk_install_service.dart';
import 'package:inkpaper/services/update_check_service.dart';
import 'package:inkpaper/services/update_download_service.dart';
import 'package:inkpaper/utils/logger.dart';

/// 应用内更新的「下载 → 安装」链路。
///
/// 单独抽出来有两个原因：
/// 1. 更新入口不止一个（开屏自动检查、关于页手动检查），两条入口要共享同一份
///    已经下好的安装包 —— 否则用户去系统设置里授权「安装未知应用」再回来，
///    又得重下 50MB；
/// 2. 下载与安装是两个明确的状态，UI 只负责展示进度，不碰文件。
class UpdateInstaller {
  UpdateInstaller();

  static const Logger _log = Logger('UpdateInstaller');

  /// 已下好、但还没装成功的包，连同它对应的版本号。
  ///
  /// 放静态字段是因为弹窗是短命对象：用户点「稍后再说」关掉弹窗、或者被系统
  /// 安装器切到后台，重建 UI 时不该把这份文件忘掉。文件名里带版本号，跨版本
  /// 不会串用。
  static File? _cachedApk;
  static String? _cachedVersion;

  UpdateDownloadService? _activeDownload;

  /// 当前是否有下载在跑。
  bool get isDownloading => _activeDownload != null;

  /// 取回某个版本已经下载、并且文件还在的安装包。
  ///
  /// 系统清理缓存时会把 `cacheDir/updates` 下的文件回收，所以每次都要
  /// 校验一次存在性，不能只信内存里的路径。
  static File? cachedApkFor(String version) {
    final file = _cachedApk;
    if (file == null || _cachedVersion != version) {
      return null;
    }
    if (!file.existsSync()) {
      forgetCache();
      return null;
    }
    return file;
  }

  /// 丢掉缓存（文件损坏、被系统清掉、装完不想再留时调用）。
  static void forgetCache() {
    _cachedApk = null;
    _cachedVersion = null;
  }

  /// 下载 [result] 对应的安装包；已缓存同版本时直接返回本地文件。
  ///
  /// [onProgress] 在缓存命中时会立刻回调一次「已完成」的进度，UI 不用为
  /// 这条快路径单独写分支。
  ///
  /// [sourceUrl] / [fallbackUrls] 让弹窗能按用户选的下载源覆盖默认顺序：
  /// 默认走 [UpdateCheckResult.apkDownloadUrl]（国内镜像），退路是 GitHub。
  Future<File> download(
    UpdateCheckResult result, {
    Uri? sourceUrl,
    List<Uri>? fallbackUrls,
    void Function(UpdateDownloadProgress progress)? onProgress,
  }) async {
    final cached = cachedApkFor(result.latestVersion);
    if (cached != null) {
      final size = cached.lengthSync();
      _log.info(
        'Reuse downloaded apk',
        data: {'version': result.latestVersion, 'bytes': size},
      );
      onProgress?.call(UpdateDownloadProgress(received: size, total: size));
      return cached;
    }

    final url = sourceUrl ?? result.apkDownloadUrl;
    if (url == null) {
      throw const UpdateDownloadException('这个版本没有提供安装包，请到发布页手动下载');
    }

    final service = UpdateDownloadService(directoryProvider: _updatesDirectory);
    _activeDownload = service;
    try {
      final file = await service.download(
        url,
        fileName: 'InkPaper-${result.latestVersion}.apk',
        expectedBytes: result.apkSizeBytes,
        fallbackUrls: fallbackUrls ?? result.fallbackApkUrls,
        onProgress: onProgress,
      );
      _cachedApk = file;
      _cachedVersion = result.latestVersion;
      await _pruneOtherPackages(file);
      return file;
    } finally {
      _activeDownload = null;
      service.dispose();
    }
  }

  /// 中止正在进行的下载。
  void cancel() {
    _activeDownload?.cancel();
  }

  /// 把本地安装包交给系统安装器。
  Future<ApkInstallStatus> install(File file) =>
      ApkInstallService.install(file.path);

  /// 下载目录优先用原生给的 `cacheDir/updates`：FileProvider 只授权了那一个
  /// 目录，Dart 侧自己拼的路径可能落在授权范围之外，安装器会读不到文件。
  static Future<Directory> _updatesDirectory() async {
    final native = await ApkInstallService.updatesDirectory();
    return native ?? Directory('${Directory.systemTemp.path}/inkpaper-updates');
  }

  /// 装包一个 50MB 的东西，留着上个版本纯属浪费缓存空间。
  static Future<void> _pruneOtherPackages(File keep) async {
    try {
      await for (final entity in keep.parent.list()) {
        if (entity is File &&
            entity.path != keep.path &&
            entity.path.toLowerCase().endsWith('.apk')) {
          await entity.delete();
        }
      }
    } on Object catch (e) {
      // 清理失败不影响本次安装。
      _log.debug('清理旧安装包失败', data: {'error': '$e'});
    }
  }
}
