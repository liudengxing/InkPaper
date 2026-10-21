import 'package:inkpaper/services/notion_sync_service.dart';

/// Notion 域状态（`STATE-CORE-005` 第四步）。
///
/// 只做字段归属迁移：把 Notion 同步服务与同步中标记从 `AppProvider` 搬到这里，
/// `AppProvider` 仅保留 `_notionStore.` 转发。业务逻辑与调用方行为均不变。
class NotionStore {
  /// Notion 同步服务实例（无状态，可长期复用）。
  final NotionSyncService syncService = NotionSyncService();

  /// 是否正在执行 Notion 同步（驱动按钮 loading 与防重入）。
  bool isSyncing = false;
}
