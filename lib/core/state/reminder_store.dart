import 'package:inkpaper/services/notification_service.dart';
import 'package:inkpaper/services/reminder_notification_service.dart';

/// 提醒 / 通知域状态（`STATE-CORE-005` 第五步）。
///
/// 只做字段归属迁移：把提醒通知服务、应用内通知服务、通知初始化标记与未读公告数
/// 从 `AppProvider` 搬到这里，`AppProvider` 仅保留 `_reminderStore.` 转发。
/// 业务逻辑、方法签名与调用方行为均不变。
class ReminderStore {
  /// 提醒通知服务（本地定时提醒）。
  final ReminderNotificationService reminderService =
      ReminderNotificationService();

  /// 应用内通知服务（公告、系统消息）。
  final NotificationService appNotificationService = NotificationService();

  /// 应用内通知服务是否已完成初始化。
  bool appNotificationInitialized = false;

  /// 未读公告数，驱动首页红点。
  int unreadAnnouncementsCount = 0;
}
