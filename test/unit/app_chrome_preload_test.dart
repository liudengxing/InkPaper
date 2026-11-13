import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/models/app_config_model.dart';
import 'package:inkpaper/providers/app_provider.dart';

/// 回归：系统是深色模式、用户设置的是浅色主题时，首帧不能先渲染成深色。
///
/// 修法是 `main` 在 `runApp` 之前把配置读好，通过 `initialConfig` 传给
/// `AppProvider`；这里直接校验「传了配置就按配置来」，不依赖真实 prefs。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final dispatcher = TestWidgetsFlutterBinding.instance.platformDispatcher;

  tearDown(dispatcher.clearPlatformBrightnessTestValue);

  test('系统深色 + 用户选浅色：直接把配置传进构造器，首帧就是浅色', () {
    dispatcher.platformBrightnessTestValue = Brightness.dark;

    final provider = AppProvider(
      initialConfig: AppConfig(themeSelection: AppConfig.THEME_LIGHT),
    );

    expect(provider.themeSelection, AppConfig.THEME_LIGHT);
    expect(provider.isDarkMode, isFalse);
  });

  test('系统深色 + 用户选深色：预载配置同样生效', () {
    dispatcher.platformBrightnessTestValue = Brightness.dark;

    final provider = AppProvider(
      initialConfig: AppConfig(themeSelection: AppConfig.THEME_DARK),
    );

    expect(provider.isDarkMode, isTrue);
  });

  test('跟随系统时仍以系统亮度为准', () {
    dispatcher.platformBrightnessTestValue = Brightness.dark;

    final provider = AppProvider(
      // 显式跟随系统 = 配置里的默认值，这里不重复写 themeSelection
      initialConfig: AppConfig(),
    );

    expect(provider.isDarkMode, isTrue);
  });

  test('不传预载配置时沿用默认值（跟随系统）', () {
    dispatcher.platformBrightnessTestValue = Brightness.dark;

    final provider = AppProvider();

    expect(provider.themeSelection, AppConfig.THEME_SYSTEM);
    expect(
      provider.isDarkMode,
      isTrue,
      reason: '这正是修复前的行为：首帧跟随系统，配置读回后才切到浅色',
    );
  });
}
