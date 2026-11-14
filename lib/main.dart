import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'package:inkpaper/config/app_config.dart' as Config;
import 'package:inkpaper/l10n/app_localizations_simple.dart';
import 'package:inkpaper/models/app_config_model.dart';
import 'package:inkpaper/providers/app_provider.dart';
import 'package:inkpaper/routes/app_router.dart';
import 'package:inkpaper/services/app_info_service.dart';
import 'package:inkpaper/services/feature_flag_service.dart';
import 'package:inkpaper/services/feed_snapshot_service.dart';
import 'package:inkpaper/services/notification_service.dart';
import 'package:inkpaper/services/observability_service.dart';
import 'package:inkpaper/services/performance_monitor_service.dart';
import 'package:inkpaper/services/preferences_service.dart';
import 'package:inkpaper/services/startup_update_service.dart';
import 'package:inkpaper/themes/app_theme.dart';
// 🚀 大厂标准：新增工具
import 'package:inkpaper/utils/attachment_cache.dart';
import 'package:inkpaper/utils/error_handler.dart';
import 'package:inkpaper/utils/image_cache_manager.dart';
import 'package:inkpaper/utils/logger.dart';
import 'package:inkpaper/utils/responsive_utils.dart';
import 'package:inkpaper/utils/shared_payload_utils.dart';
import 'package:inkpaper/utils/tag_path_utils.dart';
import 'package:inkpaper/utils/thumb_cache.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:timeago/timeago.dart' as timeago;

// 🔥 全局NavigatorKey，用于通知点击跳转
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  // 需要在任何平台通道调用前初始化（package_info_plus 等）
  WidgetsFlutterBinding.ensureInitialized();
  if (Config.AppConfig.isReleaseBuild) {
    debugPrint = (String? message, {int? wrapWidth}) {};
  }

  // 🚀 大厂标准：初始化错误监控
  GlobalErrorCatcher.initialize();

  // 单一真源：初始化版本信息（来自 pubspec.yaml）
  await AppInfoService.init();

  // 🚀 大厂标准：Sentry 错误监控
  await SentryFlutter.init(
    (options) {
      // ✅ 从配置中心读取Sentry配置
      options.dsn = Config.AppConfig.sentryDsn;
      options.tracesSampleRate = Config.AppConfig.sentrySampleRate;
      options.environment = Config.AppConfig.environment;
      options.release =
          '${Config.AppConfig.appName}@${Config.AppConfig.appVersion}';
      options.enableAutoSessionTracking = true;
      options.attachStacktrace = true;
      options.sendDefaultPii = false; // 不发送个人信息

      // 🔥 关键修复：禁用 Firebase 集成（避免 Firebase 未初始化错误）
      options.enableAutoPerformanceTracing = false; // 禁用自动性能追踪（需要 Firebase）
    },
    appRunner: () async {
      await _runApp();
    },
  );
}

// 提取应用初始化逻辑到独立函数
Future<void> _runApp() async {
  // 🚀 初始化 Flutter 绑定并保留原生启动页
  final widgetsBinding = WidgetsFlutterBinding.ensureInitialized();
  FlutterNativeSplash.preserve(widgetsBinding: widgetsBinding);

  // 🚀 大厂标准：初始化日志系统
  Log.database.info('App starting...');
  Log.performance.debug('Flutter binding initialized');

  // 🚀 大厂标准：性能监控服务（默认关闭，避免日志刷屏影响用户体验）
  // 如需启用性能监控，请在 AppConfig 中设置 enablePerformanceLogging = true
  if (Config.AppConfig.enablePerformanceLogging) {
    PerformanceMonitorService().init();
    Log.performance.info('Performance monitor started');
  }

  // 设置全局 Flutter 错误处理
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    Log.custom('FlutterError').error(
      'Unhandled Flutter error',
      error: details.exception,
      stackTrace: details.stack,
    );

    // 🚀 大厂标准：错误日志记录
    StructuredLogger().error(
      'Flutter Error',
      category: 'system',
      error: details.exception,
      stackTrace: details.stack,
      context: {
        'library': details.library,
        'context': details.context?.toString(),
      },
    );

    // 🚀 发送到 Sentry
    Sentry.captureException(
      details.exception,
      stackTrace: details.stack,
    );
  };

  await _initializeApp();
}

/// 初始化应用
Future<void> _initializeApp() async {
  // 🚀 大厂标准：记录应用启动开始
  PerformanceMonitorService().trackAppLaunch('init_start');

  // 🚀 大厂标准：启用功能开关
  await FeatureFlagService().init();
  Log.service.info('Feature flag service initialized');

  // 🚀 大厂标准：设置结构化日志上下文
  StructuredLogger().setContext(
    extras: {
      'app_version': Config.AppConfig.appVersion,
      'platform': Platform.operatingSystem,
      'platform_version': Platform.version,
    },
  );
  Log.service.info('Observability service initialized');

  // 记录应用启动日志
  StructuredLogger().info(
    'InkPaper application starting',
    category: 'startup',
    context: {
      'version': Config.AppConfig.appVersion,
      'platform': Platform.operatingSystem,
    },
  );

  // 初始化中文日期格式支持
  // ⚡ 首帧前的准备互不依赖，全部先并行跑起来；下面逐个 await 只是取结果，
  // 总耗时 = 最慢的一个，不再是一串串行相加。
  final dateFormattingFuture = initializeDateFormatting('zh_CN');
  final imageCacheFuture = ImageCacheManager.initialize();
  final attachmentCacheFuture = AttachmentCache.instance.prepare();
  final thumbCacheFuture = ThumbCache.instance.prepare();

  // 初始化timeago库，添加中文支持
  timeago.setLocaleMessages('zh', timeago.ZhCnMessages());
  timeago.setDefaultLocale('zh');

  // 图片纹理缓存上限：默认 100MB/1000 张，在「列表缩略图 → 详情多图 →
  // 查看器大图」之间来回切换时，刚解好的图很容易被挤掉，回到列表/详情又要
  // 重新解码。适量上调后跨页面复用更稳定（三档解码宽度已统一，命中率更高）。
  PaintingBinding.instance.imageCache
    ..maximumSize = 300
    ..maximumSizeBytes = 300 << 20;

  // ⚡ 逐个取回并行准备的结果（这些都必须在首帧渲染前就绪）
  await dateFormattingFuture;
  await imageCacheFuture;
  await attachmentCacheFuture;
  await thumbCacheFuture;

  // 🚀 大厂标准：记录初始化完成
  PerformanceMonitorService().trackAppLaunch('init_completed');

  // 🔥 权限按需请求策略（模仿微信/支付宝）
  // ✅ 麦克风权限：用户点击语音识别按钮时请求
  // ✅ 通知权限：用户设置提醒时请求
  // ✅ 相机权限：用户点击拍照按钮时请求
  // ✅ 相册权限：用户选择图片时请求
  // ❌ 不在启动时请求任何权限！

  // 设置全局的页面转换配置，使所有动画更平滑
  // 🔥 提前设置状态栏样式，避免启动时闪烁
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark, // 默认深色图标（浅色背景）
      systemNavigationBarColor: Colors.white,
      systemNavigationBarIconBrightness: Brightness.dark,
    ),
  );

  // 冷启动首帧先用上次的首屏快照渲染，避免先闪一条「欢迎笔记」再被真实数据顶掉
  // ⚡ 与上面四项准备并行
  final cachedFeedFuture = FeedSnapshotService.instance.load();

  // 主题 / 语言在 runApp 之前就要定下来：MaterialApp 首帧若用默认配置
  // （themeSelection = system）渲染，系统是深色模式时用户会先看到一帧深色，
  // 等 initializeApp 读完配置再闪回自己选的浅色主题。
  final initialConfigFuture = PreferencesService().loadAppConfig();

  // ⚡ 首屏快照与主题/语言配置在提供器构造前取回
  final cachedFeed = await cachedFeedFuture;
  final initialConfig = await initialConfigFuture;

  // 创建主应用提供器
  final appProvider = AppProvider(
    initialFeed: cachedFeed,
    initialConfig: initialConfig,
  );

  // 创建路由器（需要在通知服务和 MethodChannel 回调中使用）
  final appRouter = AppRouter(appProvider);

  // 🔥 关键：设置全局Router和AppProvider供NotificationService使用
  NotificationService.setGlobalRouter(appRouter.router);
  NotificationService.setGlobalAppProvider(appProvider);

  // 🚀 完全延迟初始化通知服务（只在用户设置提醒时才初始化）
  // 微信/支付宝的做法：按需请求权限，启动时不做任何权限相关操作
  // 通知服务将在用户第一次设置提醒时自动初始化

  // 🔥 监听来自原生的通知点击和分享事件
  const platform = MethodChannel(Config.AppConfig.channelNativeAlarm);
  platform.setMethodCallHandler((call) async {
    // 🔥🔥🔥 市场主流做法：通知触发时立即保存到数据库
    if (call.method == 'saveReminderNotification') {
      try {
        final data = call.arguments as Map;
        final noteId = data['noteId'] as int;
        final title = data['title'] as String;
        final body = data['body'] as String;
        final triggerTime = data['triggerTime'] as int;

        Log.service.debug(
          'Native reminder notification callback',
          data: {
            'noteId': noteId,
            'title': title,
            'triggerTime':
                DateTime.fromMillisecondsSinceEpoch(triggerTime).toString(),
          },
        );

        // 从映射中获取真实的noteId字符串
        final noteIdString = NotificationService.noteIdMapping[noteId];
        if (noteIdString != null) {
          // 保存到数据库
          await appProvider.saveReminderNotificationToDatabase(
            noteIdString: noteIdString,
            title: title,
            body: body,
            triggerTime: DateTime.fromMillisecondsSinceEpoch(triggerTime),
          );
        }
      } on Object catch (_) {
        // Best-effort native callback handling; never break app startup.
      }
    }
    // 🔥 处理通知点击（用户查看通知）
    else if (call.method == 'openNote') {
      // 🔥 关键修复：iOS传递的是字符串payload，Android传递的是int hashCode
      final noteIdString = call.arguments is String
          ? call.arguments as String
          : (call.arguments is int
              ? NotificationService.noteIdMapping[call.arguments as int]
              : null);

      if (noteIdString == null) {
        return;
      }

      // 等待一小段时间确保应用完全启动
      await Future.delayed(const Duration(milliseconds: 500));

      // 🔥 使用GoRouter实例直接导航（不需要context）
      try {
        appRouter.router.go('/note/$noteIdString');

        // 🔥 取消该笔记的提醒（通知已查看）
        try {
          final note =
              appProvider.notes.firstWhere((n) => n.id == noteIdString);
          if (note.reminderTime != null) {
            await appProvider.cancelNoteReminder(noteIdString);
          }
        } on Object catch (_) {
          // The note may no longer exist locally; navigation already succeeded.
        }
      } on Object catch (_) {
        // Native notification routing is best-effort.
      }
    }
    // 🔥 处理分享的文本
    else if (call.method == 'onSharedText') {
      final sharedText = call.arguments as String;

      // 等待应用完全启动
      await Future.delayed(const Duration(milliseconds: 500));

      // 跳转到主页并打开笔记编辑器（内容预填充）
      appRouter.router.go('/', extra: {'sharedContent': sharedText});
    }
    // 🔥 统一处理Android分享载荷，覆盖冷启动/后台/选中文本菜单
    else if (call.method == 'onSharedPayload') {
      final content = sharedPayloadToContent(call.arguments);
      if (content == null || content.trim().isEmpty) {
        return;
      }

      await Future.delayed(const Duration(milliseconds: 500));
      appRouter.router.go('/', extra: {'sharedContent': content});
    }
    // 🔥 处理分享的单张图片
    else if (call.method == 'onSharedImage') {
      final imagePath = call.arguments as String;

      await Future.delayed(const Duration(milliseconds: 500));

      // 跳转到主页并打开编辑器
      final content = '来自分享的图片:\n\n![图片](file://$imagePath)';
      appRouter.router.go('/', extra: {'sharedContent': content});
    }
    // 🔥 处理分享的多张图片
    else if (call.method == 'onSharedImages') {
      final imagePaths = (call.arguments as List).cast<String>();

      await Future.delayed(const Duration(milliseconds: 500));

      // 跳转到主页并打开编辑器
      final buffer = StringBuffer();
      buffer.writeln('来自分享的图片 (${imagePaths.length}张):\n');
      for (final path in imagePaths) {
        buffer.writeln('![图片](file://$path)\n');
      }
      appRouter.router.go('/', extra: {'sharedContent': buffer.toString()});
    }
    // 🔥 处理分享的文件
    else if (call.method == 'onSharedFile') {
      final filePath = call.arguments as String;

      await Future.delayed(const Duration(milliseconds: 500));

      // 跳转到主页并打开编辑器
      final fileName = filePath.split('/').last;
      final content = '分享的文件:\n\n📎 $fileName\n\n路径: $filePath';
      appRouter.router.go('/', extra: {'sharedContent': content});
    } else if (call.method == 'openDeepLink') {
      final rawUrl = call.arguments as String?;
      if (rawUrl == null || rawUrl.isEmpty) {
        return;
      }
      await Future.delayed(const Duration(milliseconds: 250));
      _handleInkPaperDeepLink(appRouter, rawUrl);
    }
  });

  // 🔥 关键：检查应用是否从通知点击冷启动（模仿Android的getInitialNoteId）
  // ⚡ 三个冷启动载荷探测挪到首帧之后：它们只是延迟导航，晚几百毫秒
  // 完全无感，却能在首帧前省下三次 MethodChannel 往返。
  Future<void> checkColdStartPayloads() async {
    try {
      final initialPayload = await platform.invokeMethod('getInitialPayload');
      if (initialPayload != null && initialPayload is String) {
        // 延迟跳转，确保应用完全初始化
        Future.delayed(const Duration(seconds: 1), () {
          appRouter.router.go('/note/$initialPayload');
          appProvider.cancelNoteReminder(initialPayload).catchError((_) {});
        });
      }
    } on Object catch (_) {
      // Cold-start payload is optional and may be unavailable on some platforms.
    }

    try {
      final initialSharedPayload =
          await platform.invokeMethod('getInitialSharedPayload');
      final initialSharedContent = sharedPayloadToContent(initialSharedPayload);
      if (initialSharedContent != null &&
          initialSharedContent.trim().isNotEmpty) {
        Future.delayed(const Duration(milliseconds: 700), () {
          appRouter.router
              .go('/', extra: {'sharedContent': initialSharedContent});
        });
      }
    } on Object catch (_) {
      // Cold-start share payload is optional and Android-only.
    }

    try {
      final initialDeepLink = await platform.invokeMethod('getInitialDeepLink');
      if (initialDeepLink != null && initialDeepLink is String) {
        Future.delayed(const Duration(milliseconds: 700), () {
          _handleInkPaperDeepLink(appRouter, initialDeepLink);
        });
      }
    } on Object catch (_) {
      // Cold-start deep link is optional and may be unavailable on some platforms.
    }
  }

  // 🚀 大厂标准：记录主应用创建
  PerformanceMonitorService().trackAppLaunch('app_created');

  // 运行应用
  runApp(MyApp(appProvider: appProvider, appRouter: appRouter));

  // 🚀 大厂标准：记录应用运行
  PerformanceMonitorService().trackAppLaunch('app_running');

  // ⚡ 首帧之后才探测冷启动载荷
  unawaited(checkColdStartPayloads());

  // 存量图片的缩略图后台补齐。延迟 3 秒再开跑：首屏这会儿正在解码图片，
  // 补缩略图不但帮不上忙，还会跟它抢 CPU 和内存带宽。内部有时间预算，跑不完
  // 的下次启动接着补。
  Future<void>.delayed(
    const Duration(seconds: 3),
    () => unawaited(ThumbCache.instance.backfill()),
  );

  // 开屏检查更新：首帧之后自动拉一次 Release，有新版本直接在弹窗里下载安装。
  // 内部自己做了 6 小时节流与「稍后再说」记忆，失败一律静默。
  unawaited(
    StartupUpdateService.checkOnLaunch(
      navigatorState: () =>
          appRouter.router.routerDelegate.navigatorKey.currentState,
    ),
  );
}

void _handleInkPaperDeepLink(AppRouter appRouter, String rawUrl) {
  final uri = Uri.tryParse(rawUrl);
  if (uri == null) {
    return;
  }

  final action = uri.host.isNotEmpty
      ? uri.host
      : uri.pathSegments.isNotEmpty
          ? uri.pathSegments.first
          : '';

  switch (action) {
    case 'share':
      return;
    case 'quick-note':
      final quickNoteTag =
          normalizeIncomingTagPath(uri.queryParameters['tag'] ?? '');
      appRouter.router.go(
        Uri(
          path: '/',
          queryParameters: <String, String>{
            'quickNote': '1',
            'quickNoteAction': DateTime.now().millisecondsSinceEpoch.toString(),
            if (quickNoteTag != null) 'tag': quickNoteTag,
          },
        ).toString(),
      );
      return;
    case 'random-review':
      appRouter.router.go('/random-review');
      return;
    case 'note':
      final noteId = uri.pathSegments.isNotEmpty
          ? uri.pathSegments.last
          : uri.queryParameters['id'];
      if (noteId != null && noteId.trim().isNotEmpty) {
        appRouter.router.go('/note/${Uri.encodeComponent(noteId.trim())}');
      }
      return;
    case 'tag':
      final tag = uri.pathSegments.length > 1
          ? uri.pathSegments.last
          : uri.queryParameters['name'];
      final tagPath = tag == null ? null : normalizeIncomingTagPath(tag);
      if (tagPath != null) {
        appRouter.router.go(
          Uri(
            path: '/tags/detail',
            queryParameters: {'tag': tagPath},
          ).toString(),
        );
      }
      return;
  }
}

/// 只影响 `MaterialApp` 外壳的主题 / 语言配置。
///
/// 用值相等语义把 `AppProvider` 的变更面收窄：笔记增删、同步进度、登录
/// 状态变化都不再触发整个 `MaterialApp` 树重建。
class _AppChrome {
  const _AppChrome({
    required this.isDark,
    required this.themeSelection,
    required this.themeMode,
    required this.fontScale,
    required this.fontFamily,
    required this.locale,
  });

  final bool isDark;
  final String themeSelection;
  final String themeMode;
  final double fontScale;
  final String fontFamily;
  final String? locale;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _AppChrome &&
          other.isDark == isDark &&
          other.themeSelection == themeSelection &&
          other.themeMode == themeMode &&
          other.fontScale == fontScale &&
          other.fontFamily == fontFamily &&
          other.locale == locale;

  @override
  int get hashCode => Object.hash(
        isDark,
        themeSelection,
        themeMode,
        fontScale,
        fontFamily,
        locale,
      );
}

// 创建自定义页面切换动画
class FadeTransitionPageRoute<T> extends PageRouteBuilder<T> {
  FadeTransitionPageRoute({required this.page})
      : super(
          pageBuilder: (context, animation, secondaryAnimation) => page,
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            const begin = 0.0;
            const end = 1.0;
            final tween = Tween(begin: begin, end: end);
            final fadeAnimation = animation.drive(tween);

            return FadeTransition(
              opacity: fadeAnimation,
              child: child,
            );
          },
          transitionDuration: const Duration(milliseconds: 220),
          reverseTransitionDuration: const Duration(milliseconds: 200),
        );
  final Widget page;
}

class MyApp extends StatefulWidget {
  const MyApp({required this.appProvider, required this.appRouter, super.key});
  final AppProvider appProvider;
  final AppRouter appRouter;

  @override
  State<MyApp> createState() => _MyAppState();
}

/// 🚀 缓存主题对象，避免每次build都重新创建（大厂优化技巧）
class _ThemeCache {
  static final Map<String, ThemeData> _cache = {};

  static ThemeData getTheme(String mode, bool isDark, String fontFamily) {
    final key = '${mode}_${isDark}_$fontFamily';
    if (!_cache.containsKey(key)) {
      _cache[key] = AppTheme.getTheme(mode, isDark, fontFamily: fontFamily);
    }
    return _cache[key]!;
  }
}

class _MyAppState extends State<MyApp> {
  @override
  void initState() {
    super.initState();
    // 首屏渲染完成后立即移除启动页，减少用户感知启动时间
    WidgetsBinding.instance.addPostFrameCallback((_) {
      FlutterNativeSplash.remove();
    });
  }

  @override
  Widget build(BuildContext context) => ChangeNotifierProvider.value(
        value: widget.appProvider,
        child: Selector<AppProvider, _AppChrome>(
          selector: (_, provider) => _AppChrome(
            isDark: provider.isDarkMode,
            themeSelection: provider.themeSelection,
            themeMode: provider.themeMode,
            fontScale: provider.appConfig.fontScale,
            fontFamily: provider.appConfig.fontFamily,
            locale: provider.locale,
          ),
          builder: (context, chrome, child) {
            final isDarkMode = chrome.isDark;
            final themeSelection = chrome.themeSelection;
            final themeMode = chrome.themeMode;
            final fontScale = chrome.fontScale;
            final fontFamily = chrome.fontFamily;
            final locale = chrome.locale;

            // 🚀 优化：立即设置状态栏，避免延迟导致的闪烁
            final statusBarColor =
                isDarkMode ? AppTheme.darkSurfaceColor : Colors.white;

            SystemChrome.setSystemUIOverlayStyle(
              SystemUiOverlayStyle(
                statusBarColor: Colors.transparent,
                statusBarIconBrightness:
                    isDarkMode ? Brightness.light : Brightness.dark,
                systemNavigationBarColor: statusBarColor,
                systemNavigationBarIconBrightness:
                    isDarkMode ? Brightness.light : Brightness.dark,
              ),
            );

            // 🚀 使用缓存主题，避免重复创建（大厂优化）
            final theme =
                _ThemeCache.getTheme(themeMode, false, fontFamily); // 亮色主题
            final darkTheme =
                _ThemeCache.getTheme(themeMode, true, fontFamily); // 深色主题

            // 根据主题选择设置ThemeMode
            ThemeMode appThemeMode;
            if (themeSelection == AppConfig.THEME_SYSTEM) {
              appThemeMode = ThemeMode.system;
            } else if (themeSelection == AppConfig.THEME_LIGHT) {
              appThemeMode = ThemeMode.light;
            } else if (themeSelection == AppConfig.THEME_DARK) {
              appThemeMode = ThemeMode.dark;
            } else {
              appThemeMode = ThemeMode.system;
            }

            // 解析locale字符串为Locale对象
            // 🌍 null表示跟随系统语言（大厂标准实现，支持23种语言）
            Locale? appLocale;
            if (locale == null || locale == 'system') {
              // 跟随系统：不设置locale，Flutter会自动使用系统语言
              appLocale = null;
            } else {
              // 解析语言代码 (格式: zh_CN, en_US, ja_JP等)
              final parts = locale.split('_');
              if (parts.length == 2) {
                appLocale = Locale(parts[0], parts[1]);
              } else if (parts.length == 1) {
                appLocale = Locale(parts[0]);
              } else {
                // 格式不正确，跟随系统
                appLocale = null;
              }
            }

            return MaterialApp.router(
              key: ValueKey(
                'app_${themeSelection}_$locale',
              ), // 主题和语言需要重建；字体缩放交给MediaQuery局部生效，避免路由树抖动
              title: 'InkPaper-墨鸣笔记',
              themeMode: appThemeMode,
              theme: theme,
              darkTheme: darkTheme,
              debugShowCheckedModeBanner: false,
              // 配置本地化
              localizationsDelegates: const [
                AppLocalizationsSimple.delegate, // 应用自定义本地化
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              supportedLocales: const [
                Locale('zh', 'CN'),
                Locale('en', 'US'),
              ],
              locale: appLocale, // 使用用户选择的语言
              // 🌍 添加locale解析回调，确保正确匹配系统语言
              localeResolutionCallback: (deviceLocale, supportedLocales) {
                // 如果用户明确设置了语言（locale不为null且不为'system'），使用用户设置
                if (locale != null && locale != 'system') {
                  // 用户明确选择了语言，返回用户选择的locale
                  return appLocale;
                }

                // 用户选择了"跟随系统"，根据设备语言匹配
                if (deviceLocale != null) {
                  // 优先完全匹配（语言+地区）
                  for (final supportedLocale in supportedLocales) {
                    if (supportedLocale.languageCode ==
                            deviceLocale.languageCode &&
                        supportedLocale.countryCode ==
                            deviceLocale.countryCode) {
                      return supportedLocale;
                    }
                  }

                  // 其次只匹配语言代码
                  for (final supportedLocale in supportedLocales) {
                    if (supportedLocale.languageCode ==
                        deviceLocale.languageCode) {
                      return supportedLocale;
                    }
                  }
                }

                // 如果没有匹配，使用简体中文作为默认（因为app主要面向中文用户）
                return const Locale('zh', 'CN');
              },
              routerConfig: widget.appRouter.router,
              // 添加全局页面切换配置
              builder: (context, child) {
                final clampedFontScale =
                    ResponsiveUtils.clampAppTextScale(fontScale);
                final routeChild = AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: child ?? const SizedBox.shrink(),
                );

                return MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(clampedFontScale),
                  ),
                  child: routeChild,
                );
              },
            );
          },
        ),
      );
}
