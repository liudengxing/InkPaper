/// Product identity values that should stay consistent across the app.
///
/// Runtime version/build metadata still comes from `pubspec.yaml` through
/// `PackageInfo`; these values cover brand, bundle, and default storage names.
class AppIdentity {
  const AppIdentity._();

  static const String name = 'IntPaper';
  static const String displayName = 'IntPaper';
  static const String fullName = 'IntPaper-墨鸣笔记';
  static const String packageName = 'com.didichou.intpaper';
  static const String defaultWebDavPath = '/IntPaper/';
  static const String botName = 'IntPaper_Bot';
}
