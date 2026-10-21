import 'package:inkpaper/models/cloud_verification_models.dart';
import 'package:inkpaper/services/cloud_verification_service.dart';

/// 云验证域状态（`STATE-CORE-005` 第七步）。
///
/// 云验证指从云端拉取「应用配置 / 公告 / 版本策略」等运营数据。这组状态决定
/// 要不要发起请求（缓存 5 分钟）以及最近一次拉取时间。
///
/// 只做字段归属迁移，`AppProvider` 仅保留 `_cloudStore.` 转发。
class CloudVerificationStore {
  /// 云验证请求服务。
  final CloudVerificationService service = CloudVerificationService();

  /// 最近一次拉取到的云端配置；null 表示尚未成功拉取。
  CloudAppConfigData? appConfig;

  /// 最近一次拉取时间，用于 5 分钟缓存判断。
  DateTime? lastVerificationTime;
}
