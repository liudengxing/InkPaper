import 'package:inkpaper/models/user_model.dart';
import 'package:inkpaper/services/memos_api_service_fixed.dart';

/// 认证域状态。
///
/// `STATE-CORE-005` 的第一步：把认证相关字段从 `AppProvider` 迁出，
/// `AppProvider` 只保留 `_authStore.` 转发，业务逻辑与对外行为不变。
class AuthStore {
  /// 已登录用户信息；null 表示未登录。
  User? user;

  /// Memos API 客户端；非 null 表示已配置服务器连接。
  MemosApiServiceFixed? apiService;

  /// 是否已登录（用户信息与 API 客户端同时存在）。
  bool get isLoggedIn => user != null && apiService != null;

  /// 退出登录时清空认证状态。
  void clear() {
    user = null;
    apiService = null;
  }
}
