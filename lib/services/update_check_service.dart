import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:inkpaper/config/app_config.dart';
import 'package:inkpaper/services/app_info_service.dart';
import 'package:inkpaper/utils/logger.dart';

/// 一个更新检查数据源。
///
/// 国内优先 Gitee 镜像，失败再回落 GitHub 官方。两家的 Release JSON 结构基本
/// 一致（`tag_name` / `name` / `body` / `assets[].browser_download_url`），差别
/// 只在 Gitee 没有 `html_url`、`published_at` 和资产里的 `size`，缺的字段用本
/// 类的模板补出来。
class UpdateSource {
  const UpdateSource({
    required this.id,
    required this.label,
    required this.apiUrl,
    required this.releasePageTemplate,
    required this.apkUrlTemplate,
  });

  /// 数据源标识（写日志用）
  final String id;

  /// 展示给用户的名字
  final String label;

  /// `releases/latest` 接口
  final String apiUrl;

  /// Release 页面模板，`{tag}` 会替换成 `v1.1.75`
  final String releasePageTemplate;

  /// APK 直链模板，`{tag}` 会替换成 `v1.1.75`
  ///
  /// Gitee 的 Release JSON 里不一定带附件直链，所以按 CI 的固定命名规则
  /// （`InkPaper-<tag>-android.apk`）拼出来兜底。
  final String apkUrlTemplate;

  Uri? releasePageFor(String tag) =>
      Uri.tryParse(releasePageTemplate.replaceAll('{tag}', tag));

  Uri? apkUrlFor(String tag) =>
      Uri.tryParse(apkUrlTemplate.replaceAll('{tag}', tag));

  /// 默认数据源：只走国内镜像。
  ///
  /// GitHub 在国内直连很慢（50MB 的包实测 5 分钟只下来 8MB），把它当兜底等于
  /// 「Gitee 一抖动就多等好几分钟」，用户看到的还是「检查更新卡住」。所以默认
  /// 列表里只放 Gitee；真需要回落 GitHub 时显式传
  /// `sources: [UpdateSource.gitee, UpdateSource.github]`。
  static const List<UpdateSource> all = [gitee];

  static const UpdateSource gitee = UpdateSource(
    id: 'gitee',
    label: 'Gitee 镜像（国内加速）',
    apiUrl: AppConfig.giteeLatestReleaseApi,
    releasePageTemplate: '${AppConfig.giteeRepo}/releases/tag/{tag}',
    apkUrlTemplate:
        '${AppConfig.giteeRepo}/releases/download/{tag}/InkPaper-{tag}-android.apk',
  );

  static const UpdateSource github = UpdateSource(
    id: 'github',
    label: 'GitHub',
    apiUrl: AppConfig.githubLatestReleaseApi,
    releasePageTemplate: '${AppConfig.githubRepo}/releases/tag/{tag}',
    apkUrlTemplate:
        '${AppConfig.githubRepo}/releases/download/{tag}/InkPaper-{tag}-android.apk',
  );
}

/// 一次更新检查的结果。
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
    this.sourceId = '',
    this.sourceLabel = '',
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

  /// APK 直链，Release 里找不到时为 null
  final Uri? apkDownloadUrl;

  /// APK 字节数（Gitee 不返回该字段，可能为 null）
  final int? apkSizeBytes;

  /// 发布时间
  final DateTime? publishedAt;

  /// 命中哪个数据源（`gitee` / `github`）
  final String sourceId;

  /// 数据源展示名
  final String sourceLabel;

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
/// 抽成顶层函数便于单测：不碰网络也能覆盖各种资产组合。[source] 用来补
/// JSON 里缺的字段（Gitee 没有 `html_url` / `published_at` / `size`）。
UpdateCheckResult parseLatestRelease(
  Map<String, dynamic> json, {
  required String currentVersion,
  UpdateSource? source,
}) {
  final tag = (json['tag_name'] as String?)?.trim() ?? '';
  final latestVersion =
      tag.startsWith('v') || tag.startsWith('V') ? tag.substring(1) : tag;
  if (latestVersion.isEmpty) {
    throw const UpdateCheckException('返回数据缺少版本号');
  }

  // 注意 `Uri.tryParse('')` 返回的是空 Uri 而不是 null，不能直接用 ?? 兜底。
  final htmlUrl = (json['html_url'] as String?)?.trim() ?? '';
  final parsedHtmlUrl = htmlUrl.isEmpty ? null : Uri.tryParse(htmlUrl);
  final releasePageUrl = parsedHtmlUrl ??
      source?.releasePageFor(tag) ??
      Uri.parse(AppConfig.githubRepo);

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
      apkUrl = url.isEmpty ? null : Uri.tryParse(url);
      final size = asset['size'];
      if (size is int) {
        apkSize = size;
      }
      break;
    }
  }
  // Gitee 的附件不一定会出现在 assets 里，按固定命名规则拼直链兜底。
  apkUrl ??= source?.apkUrlFor(tag);

  final rawName = (json['name'] as String?)?.trim() ?? '';
  final publishedRaw = (json['published_at'] as String?) ??
      (json['created_at'] as String?) ??
      '';

  return UpdateCheckResult(
    currentVersion: currentVersion,
    latestVersion: latestVersion,
    releaseName: rawName.isEmpty ? 'v$latestVersion' : rawName,
    releaseNotes: (json['body'] as String?)?.trim() ?? '',
    releasePageUrl: releasePageUrl,
    apkDownloadUrl: apkUrl,
    apkSizeBytes: apkSize,
    publishedAt: DateTime.tryParse(publishedRaw),
    sourceId: source?.id ?? '',
    sourceLabel: source?.label ?? '',
  );
}

/// 依次尝试各个数据源拉最新 Release 并与本机版本比对。
///
/// 顺序由构造参数决定，默认只走 Gitee 镜像（见 [UpdateSource.all]）：任一源拿到
/// 数据就立即返回，只有全部失败才抛 [UpdateCheckException]（用最后一个错误）。
class UpdateCheckService {
  UpdateCheckService({
    http.Client? client,
    List<UpdateSource>? sources,
  })  : _client = client ?? http.Client(),
        _sources = sources ?? UpdateSource.all;

  static const Logger _log = Logger('UpdateCheck');

  final http.Client _client;
  final List<UpdateSource> _sources;

  /// 检查更新；所有数据源都失败时抛 [UpdateCheckException]。
  Future<UpdateCheckResult> check() async {
    UpdateCheckException? lastError;
    for (final source in _sources) {
      try {
        return await _checkFrom(source);
      } on UpdateCheckException catch (e) {
        lastError = e;
        _log.warning(
          'Update source failed',
          data: {'source': source.id, 'error': e.message},
        );
      }
    }
    throw lastError ?? const UpdateCheckException('网络请求失败，请检查网络后重试');
  }

  Future<UpdateCheckResult> _checkFrom(UpdateSource source) async {
    final uri = Uri.parse(source.apiUrl);
    http.Response response;
    try {
      response = await _client.get(
        uri,
        headers: {
          'Accept': 'application/json',
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
      // 说明里含中文，按 UTF-8 解码避免乱码。
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
      source: source,
    );
    _log.info(
      'Checked latest release',
      data: {
        'source': source.id,
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
