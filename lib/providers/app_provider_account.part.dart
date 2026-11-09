part of 'app_provider.dart';

/// 账号 / 登录域（L3 · STATE-CORE-005 收尾）。
///
/// 用户信息、登录信息存取、API 服务初始化、Token 过期处理、头像预加载原先都
/// 堆在 `AppProvider` 类体里，与笔记 CRUD 交错，找一处就要先翻两千行。这里按
/// 域整体切出来，**实现一行未改**：靠 `extension` 直接访问 `_authStore` /
/// `_appConfig` / `_preferencesService` 等私有字段，运行链路与原类完全一致。
extension AppProviderAccountPart on AppProvider {
  // 更新用户信息到服务器
  Future<bool> updateUserInfo({
    String? nickname,
    String? email,
    String? avatarUrl,
    String? description,
  }) async {
    if (!isLoggedIn ||
        _authStore.apiService == null ||
        _authStore.user == null) {
      return false;
    }

    _setLoading(true);

    try {
      // 使用Memos API更新用户信息
      final updatedUser = await _authStore.apiService!.updateUserInfo(
        nickname: nickname,
        email: email,
        avatarUrl: avatarUrl,
        description: description,
      );

      // 更新本地用户信息
      _authStore.user = updatedUser;
      await _preferencesService.saveUser(_authStore.user!);

      notifyListeners();
      return true;
    } on Object catch (e) {
      debugPrint('更新用户信息失败: $e');
      return false;
    } finally {
      _setLoading(false);
    }
  }

  Future<bool> updatePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    if (!isLoggedIn ||
        _authStore.apiService == null ||
        _authStore.user == null) {
      return false;
    }

    _setLoading(true);
    try {
      return await _authStore.apiService!.updatePassword(
        currentPassword: currentPassword,
        newPassword: newPassword,
      );
    } on Object catch (e) {
      debugPrint('更新密码失败: $e');
      return false;
    } finally {
      _setLoading(false);
    }
  }

  // 保存登录信息
  Future<void> saveLoginInfo(
    String server,
    String usernameOrToken, {
    String? token,
    String? password,
  }) async {
    debugPrint('AppProvider: 保存登录信息 - 服务器: $server');
    // 规范化URL（确保末尾没有斜杠）
    final normalizedUrl =
        server.endsWith('/') ? server.substring(0, server.length - 1) : server;

    // 生成一个刷新令牌（这里只是为了满足接口要求）
    final refreshToken = const Uuid().v4();

    // 如果提供了token参数，则usernameOrToken是用户名，否则是token（兼容旧版本）
    if (token != null) {
      // 新版本：保存用户名和token
      await _preferencesService.saveLoginInfo(
        token: token,
        refreshToken: refreshToken,
        serverUrl: normalizedUrl,
        username: usernameOrToken, // 这里是用户名
        password: password, // 保存密码（如果提供）
      );

      // 同时更新AppConfig
      final updatedConfig = _appConfig.copyWith(
        memosApiUrl: normalizedUrl,
        lastToken: token,
        lastUsername: usernameOrToken,
        lastServerUrl: normalizedUrl,
        rememberLogin: true,
      );
      await updateConfig(updatedConfig);
    } else {
      // 旧版本：usernameOrToken是token
      await _preferencesService.saveLoginInfo(
        token: usernameOrToken,
        refreshToken: refreshToken,
        serverUrl: normalizedUrl,
      );

      // 同时更新AppConfig
      final updatedConfig = _appConfig.copyWith(
        memosApiUrl: normalizedUrl,
        lastToken: usernameOrToken,
        lastServerUrl: normalizedUrl,
        rememberLogin: true,
      );
      await updateConfig(updatedConfig);
    }
  }

  // 清除登录信息
  Future<void> clearLoginInfo() async {
    await _preferencesService.clearLoginInfo();
  }

  // 获取保存的服务器地址
  Future<String?> getSavedServer() async =>
      _preferencesService.getSavedServer();

  // 获取保存的Token
  Future<String?> getSavedToken() async => _preferencesService.getSavedToken();

  // 获取保存的用户名
  Future<String?> getSavedUsername() async =>
      _preferencesService.getSavedUsername();

  // 获取保存的密码
  Future<String?> getSavedPassword() async =>
      _preferencesService.getSavedPassword();

  // 设置当前用户
  Future<void> setUser(User user) async {
    _authStore.user = user;
    await _preferencesService.saveUser(user);
    notifyListeners();
  }

  /// 在后台初始化API服务，不阻塞启动流程
  Future<void> _initializeApiServiceInBackground() async {
    if (_authStore.apiService != null) {
      return;
    }

    // 检查是否启用自动登录
    if (!_appConfig.autoLogin) {
      if (kDebugMode) {
        debugPrint('AppProvider: 未启用自动登录，跳过自动登录');
      }
      return;
    }

    // 检查是否有保存的token和服务器信息
    final savedServerUrl =
        _appConfig.lastServerUrl ?? _authStore.user?.serverUrl;
    final savedToken = _appConfig.lastToken ?? _authStore.user?.token;

    if (savedServerUrl == null || savedToken == null) {
      if (kDebugMode) {
        debugPrint('AppProvider: 缺少保存的服务器信息或token，跳过自动登录');
      }
      return;
    }

    try {
      if (kDebugMode) {
        debugPrint('AppProvider: 开始验证保存的token并尝试自动登录');
      }

      // 尝试使用保存的token自动登录
      final loginResult = await loginWithToken(savedServerUrl, savedToken);

      if (loginResult.$1) {
        if (kDebugMode) {
          debugPrint('AppProvider: 自动登录成功');
        }

        // 初始化API服务
        _authStore.apiService = await ApiServiceFactory.createApiService(
          baseUrl: savedServerUrl,
          token: savedToken,
        ) as MemosApiServiceFixed;

        _resourceService = MemosResourceService(
          baseUrl: savedServerUrl,
          token: savedToken,
          serverVersion: await MemosApiServiceFixed.getServerVersion(
            savedServerUrl,
          ),
        );

        // 更新应用配置为在线模式
        if (_appConfig.isLocalMode) {
          if (kDebugMode) {
            debugPrint('AppProvider: 切换到在线模式');
          }
          _appConfig = _appConfig.copyWith(isLocalMode: false);
          await _preferencesService.saveAppConfig(_appConfig);
        }

        if (kDebugMode) {
          debugPrint('AppProvider: API服务和资源服务初始化成功');
        }

        // 启动自动同步
        startAutoSync();

        notifyListeners();
      } else {
        if (kDebugMode) {
          debugPrint('AppProvider: 自动登录失败: ${loginResult.$2}，清除保存的登录信息');
        }

        // Token无效，清除保存的登录信息
        await _preferencesService.clearLoginInfo();
        _authStore.user = null;
        _appConfig = _appConfig.copyWith();
        await _preferencesService.saveAppConfig(_appConfig);
        notifyListeners();
      }
    } on Object catch (e) {
      if (kDebugMode) {
        debugPrint('AppProvider: 自动登录过程中发生异常: $e');
      }

      // 发生异常时清除保存的登录信息
      try {
        await _preferencesService.clearLoginInfo();
        _authStore.user = null;
        _appConfig = _appConfig.copyWith();
        await _preferencesService.saveAppConfig(_appConfig);
        notifyListeners();
      } on Object catch (clearError) {
        if (kDebugMode) {
          debugPrint('AppProvider: 清除登录信息时发生异常: $clearError');
        }
      }
    }
  }

  /// 确保API服务已初始化
  /// 这个方法会快速检查并重新初始化API服务，避免重复的UI更新
  Future<void> _ensureApiServiceInitialized() async {
    if (_authStore.apiService != null) {
      return;
    }

    // 只在真正需要初始化时才显示消息
    _syncStore.message = '初始化API服务...';
    notifyListeners();

    if (kDebugMode) {
      debugPrint('AppProvider: API服务未初始化，尝试重新初始化');
    }

    try {
      // 优先使用当前用户的Token
      if (_appConfig.memosApiUrl != null && _authStore.user?.token != null) {
        if (kDebugMode) {
          debugPrint('AppProvider: 使用当前用户Token初始化API服务');
        }
        _authStore.apiService = await ApiServiceFactory.createApiService(
          baseUrl: _appConfig.memosApiUrl!,
          token: _authStore.user!.token,
        ) as MemosApiServiceFixed;

        // 同时初始化资源服务
        _resourceService = MemosResourceService(
          baseUrl: _appConfig.memosApiUrl!,
          token: _authStore.user!.token,
          serverVersion: await MemosApiServiceFixed.getServerVersion(
            _appConfig.memosApiUrl!,
          ),
        );
      }
      // 备用：使用上次保存的Token
      else if (_appConfig.memosApiUrl != null && _appConfig.lastToken != null) {
        if (kDebugMode) {
          debugPrint('AppProvider: 使用上次的Token初始化API服务');
        }
        _authStore.apiService = await ApiServiceFactory.createApiService(
          baseUrl: _appConfig.memosApiUrl!,
          token: _appConfig.lastToken,
        ) as MemosApiServiceFixed;

        // 同时初始化资源服务
        _resourceService = MemosResourceService(
          baseUrl: _appConfig.memosApiUrl!,
          token: _appConfig.lastToken,
          serverVersion: await MemosApiServiceFixed.getServerVersion(
            _appConfig.memosApiUrl!,
          ),
        );
      }

      if (_authStore.apiService == null) {
        throw Exception('API服务初始化失败：缺少必要的配置信息');
      }

      if (kDebugMode) {
        debugPrint('AppProvider: API服务重新初始化成功');
      }
    } on Object catch (e) {
      if (kDebugMode) {
        debugPrint('AppProvider: API服务初始化失败: $e');
      }
      final reason =
          e.toString().replaceFirst('Exception: ', '').split('\n').first;
      throw Exception('API服务初始化失败：$reason');
    }
  }

  // 处理Token过期的情况
  Future<void> _handleTokenExpired() async {
    try {
      if (kDebugMode) {
        debugPrint('AppProvider: 处理Token过期，清除登录状态');
      }

      // 1. 停止自动同步
      stopAutoSync();

      // 2. 尝试撤销过期的token（尽力而为）
      if (_authStore.apiService != null) {
        try {
          await _authStore.apiService!.logout();
          if (kDebugMode) {
            debugPrint('AppProvider: 过期token撤销成功');
          }
        } on Object catch (e) {
          if (kDebugMode) {
            debugPrint('AppProvider: 过期token撤销失败: $e');
          }
          // 继续执行，因为token已经过期
        }
      }

      // 3. 清除API服务
      _authStore.apiService = null;
      _resourceService = null;

      // 4. 清除用户信息和登录状态
      await _preferencesService.clearLoginInfo();
      _authStore.user = null;

      // 5. 更新应用配置，切换到本地模式
      _appConfig = _appConfig.copyWith(
        isLocalMode: true,
        autoLogin: false, // 禁用自动登录
      );
      await _preferencesService.saveAppConfig(_appConfig);

      // 6. 设置同步消息提示用户
      _syncStore.message = 'Token已过期，请重新登录';
      _syncStore.isSyncing = false;

      // 7. 通知UI更新
      notifyListeners();

      if (kDebugMode) {
        debugPrint('AppProvider: Token过期处理完成，已切换到本地模式');
      }
    } on Object catch (e) {
      if (kDebugMode) {
        debugPrint('AppProvider: 处理Token过期时发生错误: $e');
      }
    }
  }

  // 🖼️ 异步预加载用户头像
  void _preloadUserAvatarAsync() {
    if (_authStore.user?.avatarUrl == null ||
        _authStore.user!.avatarUrl!.trim().isEmpty) {
      return; // 没有头像URL，无需预加载
    }

    // 在微任务中执行预加载，避免阻塞主线程
    Future.microtask(() async {
      try {
        // 使用NavigatorState获取context，但只在widget树构建完成后
        final context = NavigatorKey.currentContext;
        if (context != null && context.mounted && _authStore.user != null) {
          debugPrint('AppProvider: 开始预加载用户头像');
          await AvatarPreloader.preloadUserAvatar(context, _authStore.user!);
        }
      } on Object catch (e) {
        // 预加载失败不影响正常功能
        debugPrint('AppProvider: 头像预加载失败（不影响正常使用）: $e');
      }
    });
  }
}
