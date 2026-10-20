/// Product identity values that should stay consistent across the app.
///
/// Runtime version/build metadata still comes from `pubspec.yaml` through
/// `PackageInfo`; these values cover brand, bundle, and default storage names.
class AppIdentity {
  const AppIdentity._();

  static const String name = 'InkPaper';
  static const String displayName = 'InkPaper';
  static const String fullName = 'InkPaper-墨鸣笔记';
  static const String packageName = 'com.didichou.inkpaper';
  static const String defaultWebDavPath = '/InkPaper/';
  static const String botName = 'InkPaper_Bot';
}
