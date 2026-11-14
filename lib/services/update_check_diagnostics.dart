import 'package:inkpaper/services/update_check_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 上一次更新检查留在本机的结论，供「关于页」展示。
///
/// 起因是 1.1.85 → 1.1.86 那次「为什么没提示更新」查了一圈：检查逻辑散在五个
/// 闸门里（首启未完成 / 节流窗口 / 网络失败 / 版本没变 / 用户点过稍后再说），
/// 任意一个命中都静默 return，而 release 包的日志是全关的，用户和开发者都拿
/// 不到任何痕迹。这里把每次检查的结论落到 SharedPreferences，关于页直接读，
/// 以后「到底查没查、查到什么、为什么没弹」一眼就有答案。
class UpdateCheckDiagnostics {
  const UpdateCheckDiagnostics({
    this.lastCheckAt,
    this.latestVersion,
    this.sourceLabel,
    this.errorMessage,
    this.skippedVersion,
    this.lastCheckVersion,
    this.auto = true,
  });

  /// 上次检查的时间戳（毫秒）。旧版本只写过这一个键，保留原键名才能读到。
  static const String lastCheckAtKey = 'update_last_check_at';

  /// 上次查到的远端版本（已去 `v` 前缀）
  static const String lastLatestVersionKey = 'update_last_latest_version';

  /// 上次命中的数据源展示名
  static const String lastSourceKey = 'update_last_source';

  /// 上次失败的原因；成功时会被清掉
  static const String lastErrorKey = 'update_last_error';

  /// 上次是不是自动检查（false = 用户在关于页手动点的）
  static const String lastAutoKey = 'update_last_auto';

  /// 上次检查时本机的应用版本。用来判断「是不是刚升级过」—— 刚升级那一次
  /// 值得立刻查一遍，不该被节流窗口挡住。
  static const String lastCheckVersionKey = 'update_last_check_version';

  /// 用户点过「稍后再说」的版本号
  static const String skippedVersionKey = 'update_skipped_version';

  /// 界面上一行放得下多少字，超长截断（错误信息可能带 URL 和堆栈）
  static const int maxErrorLength = 60;

  final DateTime? lastCheckAt;
  final String? latestVersion;
  final String? sourceLabel;
  final String? errorMessage;
  final String? skippedVersion;
  final String? lastCheckVersion;
  final bool auto;

  /// 有没有检查记录。全新安装、或者刚清过应用数据时为 false。
  bool get hasRecord => lastCheckAt != null;

  /// 上次检查是否失败
  bool get failed => errorMessage != null;

  /// 给界面看的一行结论。
  ///
  /// [currentVersion] 传本机版本，用来判断「有新版本 / 已是最新」。旧版本只
  /// 写了时间戳没写结果，这时 [latestVersion] 为空，如实说明而不是装作查到了。
  ///
  /// 文案刻意压短：关于页那一行只有三百多 dp，源名带「（国内加速）」这类后缀
  /// 会把「已是最新」挤到第二行，还断在词中间。
  String describe({required String currentVersion}) {
    if (lastCheckAt == null) {
      return '暂无检查记录';
    }
    final when = formatTime(lastCheckAt!);
    final trigger = auto ? '自动' : '手动';
    final head = '$when $trigger';
    final error = errorMessage;
    if (error != null && error.isNotEmpty) {
      return '$head · 失败：${_truncate(error)}';
    }
    final latest = latestVersion;
    if (latest == null || latest.isEmpty) {
      return '$head · 当时未记录结果';
    }
    final source = shortSource(sourceLabel);
    final verdict =
        compareVersions(latest, currentVersion) > 0 ? '有新版本' : '已是最新';
    final middle = source == null ? 'v$latest' : 'v$latest · $source';
    return '$head · $middle · $verdict';
  }

  /// 数据源短名。存的是完整展示名（下载弹窗里要用），诊断这行只用得上简称。
  static String? shortSource(String? raw) {
    if (raw == null || raw.isEmpty) {
      return null;
    }
    final lower = raw.toLowerCase();
    if (lower.contains('github')) {
      return 'GitHub';
    }
    if (lower.contains('gitee')) {
      return 'Gitee';
    }
    return raw;
  }

  /// 「稍后再说」的提示，没有跳过记录时返回 null。
  String? get skippedHint {
    final version = skippedVersion;
    if (version == null || version.isEmpty) {
      return null;
    }
    return '已忽略 v$version（点过「稍后再说」）';
  }

  /// 检查时间。当天只给时分，今年给月日时分，跨年补上年份 —— 一行放得下的
  /// 前提下尽量多留信息。
  static String formatTime(DateTime value, {DateTime? now}) {
    final current = now ?? DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final clock = '${two(value.hour)}:${two(value.minute)}';
    final sameDay = value.year == current.year &&
        value.month == current.month &&
        value.day == current.day;
    if (sameDay) {
      return clock;
    }
    final day = '${two(value.month)}-${two(value.day)}';
    if (value.year != current.year) {
      return '${value.year}-$day $clock';
    }
    return '$day $clock';
  }

  static String _truncate(String raw) {
    final flat = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (flat.length <= maxErrorLength) {
      return flat;
    }
    return '${flat.substring(0, maxErrorLength)}…';
  }

  static UpdateCheckDiagnostics fromPrefs(SharedPreferences prefs) {
    final ms = prefs.getInt(lastCheckAtKey);
    final skipped = prefs.getString(skippedVersionKey);
    return UpdateCheckDiagnostics(
      lastCheckAt: ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms),
      latestVersion: prefs.getString(lastLatestVersionKey),
      sourceLabel: prefs.getString(lastSourceKey),
      errorMessage: prefs.getString(lastErrorKey),
      skippedVersion: (skipped == null || skipped.isEmpty) ? null : skipped,
      lastCheckVersion: prefs.getString(lastCheckVersionKey),
      auto: prefs.getBool(lastAutoKey) ?? true,
    );
  }

  static Future<UpdateCheckDiagnostics> load() async {
    final prefs = await SharedPreferences.getInstance();
    return fromPrefs(prefs);
  }

  /// 记一次成功的检查。[auto] 区分开屏自动检查与关于页手动点的。
  static Future<void> recordSuccess(
    UpdateCheckResult result, {
    required bool auto,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      lastCheckAtKey,
      DateTime.now().millisecondsSinceEpoch,
    );
    await prefs.setString(lastLatestVersionKey, result.latestVersion);
    await prefs.setString(lastSourceKey, result.sourceLabel);
    await prefs.setString(lastCheckVersionKey, result.currentVersion);
    await prefs.setBool(lastAutoKey, auto);
    // 上一轮失败的原因留着会误导：这次明明查到了。
    await prefs.remove(lastErrorKey);
  }

  /// 记一次失败的检查。时间戳照写，节流才有意义（否则每次冷启动都重试一遍）。
  static Future<void> recordFailure(
    String message, {
    required bool auto,
    required String currentVersion,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      lastCheckAtKey,
      DateTime.now().millisecondsSinceEpoch,
    );
    await prefs.setString(lastErrorKey, message);
    await prefs.setString(lastCheckVersionKey, currentVersion);
    await prefs.setBool(lastAutoKey, auto);
    await prefs.remove(lastLatestVersionKey);
  }

  /// 记下用户点了「稍后再说」的版本。
  static Future<void> recordSkipped(String version) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(skippedVersionKey, version);
  }

  /// 清掉「稍后再说」的记录，下一个版本窗口重新开始提醒。
  static Future<void> clearSkipped() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(skippedVersionKey);
  }
}
