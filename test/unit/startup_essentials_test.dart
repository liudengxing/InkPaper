import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/models/app_config_model.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/providers/app_provider.dart';
import 'package:inkpaper/services/feature_flag_service.dart';
import 'package:inkpaper/services/feed_snapshot_service.dart';
import 'package:inkpaper/utils/startup_essentials.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 首帧前六项准备的并行契约（OPT-06A）。
///
/// 守的是「全部发起后再统一等待」这件事本身：只要有人把某一项改成
/// 「前一项 await 完再发起」，这里的前三条就会红。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory sandbox;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('inkpaper_startup_');
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, (call) async => sandbox.path);
    const secureChannel =
        MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, (call) async => null);
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDown(() {
    if (sandbox.existsSync()) {
      sandbox.deleteSync(recursive: true);
    }
  });

  /// 六个可控任务：都先记 start，再等同一个闸门，放开后才记 done。
  ({
    StartupTask<void> loadDateFormatting,
    StartupTask<void> prepareImageCache,
    StartupTask<void> prepareAttachmentCache,
    StartupTask<void> prepareThumbCache,
    StartupTask<List<Note>> loadFeedSnapshot,
    StartupTask<AppConfig> loadAppConfig,
  }) gatedTasks(Completer<void> gate, List<String> log) {
    StartupTask<T> task<T>(String name, T value) => () async {
          log.add('start:$name');
          await gate.future;
          log.add('done:$name');
          return value;
        };

    return (
      loadDateFormatting: task<void>('date', null),
      prepareImageCache: task<void>('image', null),
      prepareAttachmentCache: task<void>('attachment', null),
      prepareThumbCache: task<void>('thumb', null),
      loadFeedSnapshot: task<List<Note>>('feed', const <Note>[]),
      loadAppConfig: task<AppConfig>('config', AppConfig()),
    );
  }

  test('SE-01 六项全部发起之后才开始等待，没有一项是串行接上的', () async {
    final gate = Completer<void>();
    final log = <String>[];
    final tasks = gatedTasks(gate, log);

    final future = loadStartupEssentials(
      loadDateFormatting: tasks.loadDateFormatting,
      prepareImageCache: tasks.prepareImageCache,
      prepareAttachmentCache: tasks.prepareAttachmentCache,
      prepareThumbCache: tasks.prepareThumbCache,
      loadFeedSnapshot: tasks.loadFeedSnapshot,
      loadAppConfig: tasks.loadAppConfig,
    );

    await pumpEventQueue(times: 5);

    expect(
      log.where((entry) => entry.startsWith('start:')).length,
      6,
      reason: '闸门没放开就应看到六项全部进入等待，少一项说明它是串在别人后面发的',
    );
    expect(log.where((entry) => entry.startsWith('done:')), isEmpty);

    gate.complete();
    await future;

    expect(log.where((entry) => entry.startsWith('done:')).length, 6);
  });

  test('SE-02 总耗时等于最慢一项，而不是六项相加', () async {
    const perTask = Duration(milliseconds: 50);
    StartupTask<T> slow<T>(T value) => () async {
          await Future<void>.delayed(perTask);
          return value;
        };

    final watch = Stopwatch()..start();
    await loadStartupEssentials(
      loadDateFormatting: slow<void>(null),
      prepareImageCache: slow<void>(null),
      prepareAttachmentCache: slow<void>(null),
      prepareThumbCache: slow<void>(null),
      loadFeedSnapshot: slow<List<Note>>(const <Note>[]),
      loadAppConfig: slow<AppConfig>(AppConfig()),
    );
    watch.stop();

    // 串行是 300ms；并行就该在 60ms 上下，留足机器抖动余量。
    expect(
      watch.elapsedMilliseconds,
      lessThan(150),
      reason: '实测 ${watch.elapsedMilliseconds}ms，串行应为 300ms 左右',
    );
  });

  test('SE-03 缩略图索引卡住时，首屏快照与配置照常先好', () async {
    final thumbGate = Completer<void>();
    var feedDone = false;
    var configDone = false;
    var settled = false;

    final future = loadStartupEssentials(
      loadDateFormatting: () async {},
      prepareImageCache: () async {},
      prepareAttachmentCache: () async {},
      prepareThumbCache: () async {
        await thumbGate.future;
      },
      loadFeedSnapshot: () async {
        feedDone = true;
        return const <Note>[];
      },
      loadAppConfig: () async {
        configDone = true;
        return AppConfig();
      },
    );
    unawaited(future.whenComplete(() => settled = true));

    await pumpEventQueue(times: 5);

    expect(feedDone, isTrue);
    expect(configDone, isTrue);
    expect(
      settled,
      isFalse,
      reason: '夹具还没放开，整体不该完成——它们仍是首帧前的硬依赖',
    );

    thumbGate.complete();
    await future;
    expect(settled, isTrue);
  });

  test('SE-04 空缓存 + 离线：没有任何快照与配置也能拿到可用的首帧输入', () async {
    final essentials = await loadStartupEssentials();

    expect(essentials.feedSnapshot, isEmpty, reason: '没有快照时首帧画空列表');
    expect(essentials.appConfig.themeSelection, AppConfig.THEME_SYSTEM);
    expect(essentials.appConfig.locale, isNull, reason: '没有配置时跟随系统语言');
    // 日期格式必须已经可用，否则首帧卡片格式化 createdAt 会抛异常
    expect(
      DateFormat('yyyy-MM-dd', 'zh_CN').format(DateTime(2026, 11, 23)),
      '2026-11-23',
    );
  });

  test('SE-05 有快照时按原样读回，卡片字段不缺', () async {
    final notes = List<Note>.generate(
      20,
      (i) => Note(
        id: 'seed-$i',
        content: '第 $i 条，正文里带 #标签',
        createdAt: DateTime(2026, 10, 1, 9, i),
        updatedAt: DateTime(2026, 10, 2, 9, i),
        tags: const ['标签'],
        isPinned: i == 3,
        resourceList: const [
          {'uid': 'r1', 'type': 'image/png', 'filename': 'a.png'},
        ],
      ),
    );
    await FeedSnapshotService.instance.save(notes);

    final essentials = await loadStartupEssentials();

    expect(essentials.feedSnapshot, hasLength(20));
    final pinned =
        essentials.feedSnapshot.firstWhere((note) => note.id == 'seed-3');
    expect(pinned.isPinned, isTrue);
    expect(pinned.tags, ['标签']);
    expect(pinned.resourceList, hasLength(1));
    expect(pinned.createdAt, DateTime(2026, 10, 1, 9, 3));
  });

  test('SE-06 功能开关首帧前只读本地缓存，isEnabled 立刻可用', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'feature_flags': jsonEncode(<String, Object?>{'speech_to_text': true}),
    });

    await FeatureFlagService().loadLocal();

    // 默认值是 false，读到 true 说明确实用了本地缓存
    expect(FeatureFlagService().isEnabled('speech_to_text'), isTrue);
  });

  test('SE-07 已保存的主题与语言在首帧就生效，不会先渲染一帧默认值', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'app_config': jsonEncode(<String, Object?>{
        'themeSelection': AppConfig.THEME_DARK,
        'locale': 'en_US',
      }),
    });
    TestWidgetsFlutterBinding.instance.platformDispatcher
        .platformBrightnessTestValue = Brightness.light;
    addTearDown(
      TestWidgetsFlutterBinding
          .instance.platformDispatcher.clearPlatformBrightnessTestValue,
    );

    final essentials = await loadStartupEssentials();

    expect(essentials.appConfig.themeSelection, AppConfig.THEME_DARK);
    expect(essentials.appConfig.locale, 'en_US');

    final provider = AppProvider(initialConfig: essentials.appConfig);
    expect(
      provider.isDarkMode,
      isTrue,
      reason: '系统是浅色、用户选深色：首帧就必须按用户配置渲染',
    );
    expect(provider.locale, 'en_US');
  });
}
