import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:inkpaper/config/app_config.dart';
import 'package:inkpaper/services/app_info_service.dart';
import 'package:inkpaper/utils/logger.dart';

/// 一次下载进度快照。
///
/// [total] 为 null 表示服务端没给 `Content-Length`，此时只能显示已下载量。
class UpdateDownloadProgress {
  const UpdateDownloadProgress({required this.received, this.total});

  final int received;
  final int? total;

  /// 0~1 的完成度；没有总大小时返回 null。
  double? get fraction {
    final value = total;
    if (value == null || value <= 0) {
      return null;
    }
    final ratio = received / value;
    return ratio > 1 ? 1 : ratio;
  }
}

/// 下载失败，[message] 可直接展示给用户。
class UpdateDownloadException implements Exception {
  const UpdateDownloadException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => 'UpdateDownloadException: $message (${cause ?? '-'})';
}

/// 把 Release 上的 APK 下载到应用私有目录。
///
/// 之前点「下载安装包」是 `launchUrl` 把链接丢给浏览器，进度、失败提示、
/// 何去何从全归浏览器管；改成应用内下载后这条链路自己闭环：进度可见、
/// 可取消、字节数可校验，下完直接把文件交给系统安装器。
///
/// 只负责「把字节搬到本地」，安装交给 `ApkInstallService`（需要原生侧
/// FileProvider，只能做在 Android 上）。
class UpdateDownloadService {
  UpdateDownloadService({
    http.Client? client,
    Future<Directory> Function()? directoryProvider,
  })  : _client = client ?? http.Client(),
        _directoryProvider = directoryProvider ?? _defaultDirectory;

  static const Logger _log = Logger('UpdateDownload');

  final http.Client _client;
  final Future<Directory> Function() _directoryProvider;
  bool _cancelled = false;

  /// 默认落到临时目录：桌面/测试环境用得上；Android 由调用方注入
  /// 原生的 `cacheDir/updates`，好让 FileProvider 的 `cache-path` 对得上。
  static Future<Directory> _defaultDirectory() async =>
      Directory('${Directory.systemTemp.path}/inkpaper-updates');

  /// 请求取消。会同时关掉底层连接，避免卡在等下一块数据上。
  void cancel() {
    _cancelled = true;
    _client.close();
  }

  /// [fallbackUrls] 是主地址拿不到包时的退路，按顺序尝试。目前只有一种场景：
  /// Gitee 的 Release 建出来了、但附件没传上去（1.1.83 就翻过这车），此时 Gitee
  /// 直链恒返回 404，而 GitHub 上的同名资产是好的。只在 403/404/410 这种「这个
  /// 地址上确实没有东西」的状态下回退，网络超时 / 5xx 不换源 —— GitHub 在国内太慢，
  /// 换过去大概率是从「失败」变成「卡十分钟」。
  Future<File> download(
    Uri url, {
    required String fileName,
    int? expectedBytes,
    List<Uri> fallbackUrls = const <Uri>[],
    void Function(UpdateDownloadProgress progress)? onProgress,
  }) async {
    final directory = await _directoryProvider();
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }

    // 先写 .part 再改名：中途失败不会留下一个「看起来完整」的安装包。
    final target = File('${directory.path}${Platform.pathSeparator}$fileName');
    final partial = File('${target.path}.part');
    await _deleteQuietly(partial);

    // 主地址在前，退路在后；同一个地址只试一次。
    final candidates = <Uri>[url];
    for (final fallback in fallbackUrls) {
      if (!candidates.contains(fallback)) {
        candidates.add(fallback);
      }
    }

    http.StreamedResponse? response;
    for (var i = 0; i < candidates.length; i++) {
      final candidate = candidates[i];
      final opened = await _open(candidate);
      if (opened.statusCode == 200) {
        response = opened;
        break;
      }
      final hasFallback = i + 1 < candidates.length;
      if (hasFallback && _meansMissingAsset(opened.statusCode)) {
        _log.warning(
          'Download source missing, trying fallback',
          data: {'host': candidate.host, 'status': opened.statusCode},
        );
        await _discard(opened);
        continue;
      }
      await _discard(opened);
      throw UpdateDownloadException('下载失败（HTTP ${opened.statusCode}）');
    }
    if (response == null) {
      // 候选列表为空理论上进不来（至少有一个地址），留一道保险更稳妥。
      throw const UpdateDownloadException('下载失败，请检查网络后重试');
    }

    final total = response.contentLength;
    final sink = partial.openWrite();
    var received = 0;
    try {
      await for (final chunk in response.stream) {
        if (_cancelled) {
          throw const UpdateDownloadException('已取消下载');
        }
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(
          UpdateDownloadProgress(received: received, total: total),
        );
      }
      await sink.flush();
      await sink.close();
    } on Object catch (e) {
      // 连接被 cancel 掉时这里拿到的是 ClientException，统一收敛成可读文案。
      try {
        await sink.close();
      } on Object {
        // sink 已经因连接中断而失效，关闭失败不影响后续清理。
      }
      await _deleteQuietly(partial);
      if (_cancelled || e is UpdateDownloadException) {
        if (_cancelled) {
          throw const UpdateDownloadException('已取消下载');
        }
        rethrow;
      }
      throw UpdateDownloadException('下载中断，请重试', cause: e);
    }

    final expected = expectedBytes;
    if (expected != null && expected > 0 && received != expected) {
      await _deleteQuietly(partial);
      throw UpdateDownloadException(
        '安装包不完整（$received / $expected 字节），请重试',
      );
    }

    await _deleteQuietly(target);
    await partial.rename(target.path);
    _log.info(
      'APK downloaded',
      data: {'bytes': received, 'path': target.path},
    );
    return target;
  }

  /// 发一次 GET 并返回流式响应，把底层异常收敛成可读文案。
  Future<http.StreamedResponse> _open(Uri url) async {
    try {
      final request = http.Request('GET', url)
        ..headers['User-Agent'] = AppInfoService.userAgent;
      return await _client
          .send(request)
          .timeout(AppConfig.updateDownloadTimeout);
    } on TimeoutException catch (e) {
      throw UpdateDownloadException('连接下载服务器超时，请稍后重试', cause: e);
    } on Object catch (e) {
      if (_cancelled) {
        throw const UpdateDownloadException('已取消下载');
      }
      throw UpdateDownloadException('下载失败，请检查网络后重试', cause: e);
    }
  }

  /// 这个状态码是不是「地址上没有这个包」，而不是「网络有问题」。
  ///
  /// 403 是 Gitee 附件被撤下后直链的表现，404 是附件从来没传上去，410 是资源
  /// 已删除 —— 三者都说明换一个源是唯一出路。
  static bool _meansMissingAsset(int statusCode) =>
      statusCode == 403 || statusCode == 404 || statusCode == 410;

  /// 丢弃一个不用的响应体。不读干净会让 keep-alive 连接一直挂着。
  static Future<void> _discard(http.StreamedResponse response) async {
    try {
      await response.stream.drain<void>();
    } on Object {
      // 丢弃失败不影响后续重试。
    }
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } on Object {
      // 清理失败不该盖住真正的下载错误。
    }
  }

  void dispose() => _client.close();
}
