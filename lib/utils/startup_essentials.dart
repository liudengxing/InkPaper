import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:inkpaper/models/app_config_model.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/services/feed_snapshot_service.dart';
import 'package:inkpaper/services/preferences_service.dart';
import 'package:inkpaper/utils/attachment_cache.dart';
import 'package:inkpaper/utils/image_cache_manager.dart';
import 'package:inkpaper/utils/thumb_cache.dart';
import 'package:intl/date_symbol_data_local.dart';

/// 冷启动首帧需要的两样真实数据，其余准备只有副作用（建目录、扫缓存索引）。
@immutable
class StartupEssentials {
  const StartupEssentials({
    required this.feedSnapshot,
    required this.appConfig,
  });

  /// 上次的首屏快照；没有就是空列表——首帧先画空列表，真实数据一到就整体替换。
  final List<Note> feedSnapshot;

  /// 主题 / 语言 / 登录态等外壳配置。必须在 `runApp` 之前拿到：`MaterialApp`
  /// 首帧若按默认配置渲染，用户会先看到一帧系统主题再闪回自己选的那套。
  final AppConfig appConfig;
}

typedef StartupTask<T> = Future<T> Function();

/// 首帧前的六项准备：日期格式、图片缓存、附件缓存、缩略图索引、首屏快照、
/// 外壳配置。
///
/// 六项互不依赖，**全部先发起再统一等待**，总耗时等于最慢的一项。此前首屏
/// 快照与外壳配置是在前四项 `await` 完之后才发起的，等于在最慢项之上又加了
/// 「快照/配置里较慢的那个」，白白多等一轮（真机上配置要读 Keystore）。
///
/// 哪些必须卡在首帧前：
/// - 日期格式：卡片要格式化 `createdAt`，未初始化时 `DateFormat('zh_CN')` 直接抛异常；
/// - 附件缓存：`fileFor()` 未预热就返回 null，远程附件会退化成走网络；
/// - 缩略图索引：`lookup()` 未预热返回 null，首帧卡片只能去解原图。这一项是
///   全组最慢的（合成目录实测：5000 个文件 37ms），但移走首帧会明显变重，故保留；
/// - 图片缓存：目前是空实现，留着只为不改变既有顺序语义；
/// - 首屏快照：直接决定首帧画什么；
/// - 外壳配置：直接决定首帧主题与语言。
///
/// [loadDateFormatting] 等参数仅供测试注入，生产调用不传。
Future<StartupEssentials> loadStartupEssentials({
  StartupTask<void>? loadDateFormatting,
  StartupTask<void>? prepareImageCache,
  StartupTask<void>? prepareAttachmentCache,
  StartupTask<void>? prepareThumbCache,
  StartupTask<List<Note>>? loadFeedSnapshot,
  StartupTask<AppConfig>? loadAppConfig,
}) async {
  // ⚠️ 这六行必须连续发起：中间插一个 await，并行就退回串行。
  final dateFormatting = (loadDateFormatting ?? _loadDateFormatting)();
  final imageCache = (prepareImageCache ?? _prepareImageCache)();
  final attachmentCache = (prepareAttachmentCache ?? _prepareAttachmentCache)();
  final thumbCache = (prepareThumbCache ?? _prepareThumbCache)();
  final feedSnapshot = (loadFeedSnapshot ?? _loadFeedSnapshot)();
  final appConfig = (loadAppConfig ?? _loadAppConfig)();

  // 用一次 `Future.wait` 收口，而不是逐个 `await`：一次注册全部监听，
  // 任何一项失败都不会因为「还没轮到 await」被当成未捕获异常。
  final results = await Future.wait<Object?>(<Future<Object?>>[
    dateFormatting,
    imageCache,
    attachmentCache,
    thumbCache,
    feedSnapshot,
    appConfig,
  ]);

  return StartupEssentials(
    feedSnapshot: results[4]! as List<Note>,
    appConfig: results[5]! as AppConfig,
  );
}

Future<void> _loadDateFormatting() => initializeDateFormatting('zh_CN');

Future<void> _prepareImageCache() => ImageCacheManager.initialize();

Future<void> _prepareAttachmentCache() => AttachmentCache.instance.prepare();

Future<void> _prepareThumbCache() => ThumbCache.instance.prepare();

Future<List<Note>> _loadFeedSnapshot() => FeedSnapshotService.instance.load();

Future<AppConfig> _loadAppConfig() => PreferencesService().loadAppConfig();
