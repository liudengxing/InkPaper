import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:inkpaper/config/app_config.dart';
import 'package:inkpaper/services/app_info_service.dart';
import 'package:inkpaper/utils/logger.dart';

/// 一次更新检查的结果。
///
/// 数据全部来自 GitHub Release（`releases/latest`），APK 就是 CI 挂在
/// Release 资产上的那个安装包，不再依赖自建后端。
class UpdateCheckResult {
  const UpdateCheckResult({
    required this.currentVersion,
    required this.latestVersion,
    required this.releasePageUrl,
    this.releaseName = '',
    this.releaseNotes = '',
    this.apkDownloadUrl,
    this.apkSizeBytes,
    this.publishedAt,
  });

  /// 本机版本（来自打包元数据，形如 `1.1.68`）
  final String currentVersion;

  /// 远端最新版本（已去掉 `v` 前缀，形如 `1.1.69`）
  final String latestVersion;

  /// Release 页面
  final Uri releasePageUrl;

  /// Release 标题
  final String releaseName;

  /// Release 说明（markdown，来自 CHANGELOG）
  final String releaseNotes;

  /// APK 直链，Release 里没有 APK 资产时为 null
  final Uri? apkDownloadUrl;

  /// APK 字节数
  final int? apkSizeBytes;

  /// 发布时间
  final DateTime? publishedAt;

  /// 远端版本是否比本机新
  bool get hasUpdate => compareVersions(latestVersion, currentVersion) > 0;

  /// 下载链接：优先 APK 直链，没有就回落到 Release 页面
  Uri get downloadUrl => apkDownloadUrl ?? releasePageUrl;
}

/// 检查更新失败，[message] 可直接展示给用户。
class UpdateCheckException implements Exception {
  const UpdateCheckException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => 'UpdateCheckException: $message (${cause ?? '-'})';
}

/// 比较两个版本号：返回 `> 0` 表示 [a] 更新，`0` 表示相同。
///
/// 只比较 `x.y.z` 数字段：忽略 `v` 前缀、`+build` 构建号和 `-beta` 之类的
/// 预发布后缀；段数不齐时缺失段按 0 补齐（`1.2` == `1.2.0`）。
int compareVersions(String a, String b) {
  final left = _versionSegments(a);
  final right = _versionSegments(b);
  final length = left.length > right.length ? left.length : right.length;
  for (var i = 0; i < length; i++) {
    final l = i < left.length ? left[i] : 0;
    final r = i < right.length ? right[i] : 0;
    if (l != r) {
      return l > r ? 1 : -1;
    }
  }
  return 0;
}

List<int> _versionSegments(String raw) {
  var value = raw.trim();
  if (value.startsWith('v') || value.startsWith('V')) {
    value = value.substring(1);
  }
  value = value.split('+').first.split('-').first;
  if (value.isEmpty) {
    return const [];
  }
  return value
      .split('.')
      .map((part) => int.tryParse(part.trim()) ?? 0)
      .toList(growable: false);
}

/// 把 `releases/latest` 的 JSON 解析成 [UpdateCheckResult]。
///
/// 抽成顶层函数便于单测：不碰网络也能覆盖各种资产组合。
UpdateCheckResult parseLatestRelease(
  Map<String, dynamic> json, {
  required String currentVersion,
}) {
  final tag = (json['tag_name'] as String?)?.trim() ?? '';
  final latestVersion =
      tag.startsWith('v') || tag.startsWith('V') ? tag.substring(1) : tag;
  if (latestVersion.isEmpty) {
    throw const UpdateCheckException('返回数据缺少版本号');
  }

  final htmlUrl = (json['html_url'] as String?)?.trim() ?? '';
  final releasePageUrl =
      Uri.tryParse(htmlUrl) ?? Uri.parse(AppConfig.githubRepo);

  Uri? apkUrl;
  int? apkSize;
  final assets = json['assets'];
  if (assets is List) {
    for (final asset in assets) {
      if (asset is! Map) {
        continue;
      }
      final name = asset['name'];
      final url = asset['browser_download_url'];
      if (name is! String || url is! String) {
        continue;
      }
      if (!name.toLowerCase().endsWith('.apk')) {
        continue;
      }
      apkUrl = Uri.tryParse(url);
      final size = asset['size'];
      if (size is int) {
        apkSize = size;
      }
      break;
    }
  }

  final rawName = (json['name'] as String?)?.trim() ?? '';

  return UpdateCheckResult(
    currentVersion: currentVersion,
    latestVersion: latestVersion,
    releaseName: rawName.isEmpty ? 'v$latestVersion' : rawName,
    releaseNotes: (json['body'] as String?)?.trim() ?? '',
    releasePageUrl: releasePageUrl,
    apkDownloadUrl: apkUrl,
    apkSizeBytes: apkSize,
    publishedAt: DateTime.tryParse((json['published_at'] as String?) ?? ''),
  );
}

/// 从 GitHub 拉最新 Release 并与本机版本比对。
class UpdateCheckService {
  UpdateCheckService({http.Client? client}) : _client = client ?? http.Client();

  static const Logger _log = Logger('UpdateCheck');

  final http.Client _client;

  /// 检查更新；失败抛 [UpdateCheckException]。
  Future<UpdateCheckResult> check() async {
    final uri = Uri.parse(AppConfig.githubLatestReleaseApi);
    http.Response response;
    try {
      response = await _client.get(
        uri,
        headers: {
          'Accept': 'application/vnd.github+json',
          'User-Agent': AppInfoService.userAgent,
        },
      ).timeout(AppConfig.updateCheckTimeout);
    } on TimeoutException catch (e) {
      throw UpdateCheckException('请求超时，请稍后重试', cause: e);
    } on Object catch (e) {
      throw UpdateCheckException('网络请求失败，请检查网络后重试', cause: e);
    }

    // 未认证的 GitHub API 按 IP 限流（60 次/小时），触发时是 403 / 429。
    if (response.statusCode == 403 || response.statusCode == 429) {
      throw const UpdateCheckException('请求过于频繁，请稍后再试');
    }
    if (response.statusCode == 404) {
      throw const UpdateCheckException('仓库还没有已发布的正式版本');
    }
    if (response.statusCode != 200) {
      throw UpdateCheckException('服务返回异常（HTTP ${response.statusCode}）');
    }

    final Object? decoded;
    try {
      // GitHub 的说明里含中文，按 UTF-8 解码避免乱码。
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } on Object catch (e) {
      throw UpdateCheckException('返回数据格式异常', cause: e);
    }
    if (decoded is! Map<String, dynamic>) {
      throw const UpdateCheckException('返回数据格式异常');
    }

    final result = parseLatestRelease(
      decoded,
      currentVersion: AppInfoService.version,
    );
    _log.info(
      'Checked latest release',
      data: {
        'current': result.currentVersion,
        'latest': result.latestVersion,
        'hasUpdate': result.hasUpdate,
        'hasApk': result.apkDownloadUrl != null,
      },
    );
    return result;
  }

  void dispose() => _client.close();
}
