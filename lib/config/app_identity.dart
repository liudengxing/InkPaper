/// Product identity values that should stay consistent across the app.
///
/// Runtime version/build metadata still comes from `pubspec.yaml` through
/// `PackageInfo`; these values cover brand, bundle, and default storage names.
class AppIdentity {
  const AppIdentity._();

  static const String name = 'InkPaper';
  static const String displayName = 'InkPaper';

  /// 全称只用于分享、备份文件抬头等少数位置。历史上这里带过一段中文别名后缀，
  /// 已统一为品牌名，不再拼接别名（2026-11-17）。
  static const String fullName = 'InkPaper';
  static const String packageName = 'com.didichou.inkpaper';
  static const String defaultWebDavPath = '/InkPaper/';
  static const String botName = 'InkPaper_Bot';
}
