import 'dart:async';

import 'package:inkpaper/models/webdav_config.dart';
import 'package:inkpaper/services/webdav_service.dart';
import 'package:inkpaper/services/webdav_sync_engine.dart';

/// WebDAV 域状态（`STATE-CORE-005` 第三步）。
///
/// 只做字段归属迁移：把 WebDAV 配置、服务实例、同步引擎、定时备份计时器与
/// 启动备份标记从 `AppProvider` 搬到这里，`AppProvider` 仅保留 `_webDavStore.` 转发。
/// 业务逻辑、方法签名与调用方行为均不变。
class WebDavStore {
  /// WebDAV 配置（服务器地址、账号、备份策略等）。
  WebDavConfig config = const WebDavConfig();

  /// WebDAV 客户端服务；null 表示未配置或未初始化。
  WebDavService? service;

  /// WebDAV 同步引擎；null 表示未初始化。
  WebDavSyncEngine? syncEngine;

  /// 定时备份计时器。
  Timer? backupTimer;

  /// 本次进程是否已执行过启动备份（避免每次冷启动重复备份）。
  bool hasPerformedStartupBackup = false;
}
