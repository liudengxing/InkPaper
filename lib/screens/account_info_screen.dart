import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:inkpaper/l10n/app_localizations_simple.dart';
import 'package:inkpaper/models/user_model.dart';
import 'package:inkpaper/providers/app_provider.dart';
import 'package:inkpaper/services/memos_api_service_fixed.dart';
import 'package:inkpaper/services/memos_resource_service.dart';
import 'package:inkpaper/services/preferences_service.dart';
import 'package:inkpaper/utils/snackbar_utils.dart';
import 'package:inkpaper/widgets/cached_avatar.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

class AccountInfoScreen extends StatefulWidget {
  const AccountInfoScreen({super.key});

  @override
  State<AccountInfoScreen> createState() => _AccountInfoScreenState();
}

class _AccountInfoScreenState extends State<AccountInfoScreen> {
  final PreferencesService _preferencesService = PreferencesService();
  final ImagePicker _picker = ImagePicker();
  late TextEditingController _nicknameController;
  late TextEditingController _emailController;
  late TextEditingController _bioController;
  bool _isUpdatingAvatar = false;
  File? _selectedImage;

  // Memos 连接状态（原「服务器连接」页并入）
  bool _isSyncing = false;
  bool _isDiagnosing = false;
  bool _isConnectionHealthy = false;
  bool _hasServerUrl = false;
  String _serverHost = '';
  String _latency = '';
  String _lastSyncLabel = '';
  Timer? _statusCheckTimer;

  @override
  void initState() {
    super.initState();
    final user = Provider.of<AppProvider>(context, listen: false).user;
    _nicknameController =
        TextEditingController(text: user?.nickname ?? user?.username ?? '');
    _emailController = TextEditingController(text: user?.email ?? '');
    _bioController = TextEditingController(text: user?.description ?? '');

    // 页面加载后自动同步一次用户信息
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      // 如果上次同步时间超过15分钟，或者没有头像，自动同步
      if (user != null &&
          (user.lastSyncTime == null ||
              DateTime.now().difference(user.lastSyncTime!).inMinutes > 15 ||
              user.avatarUrl == null ||
              user.avatarUrl!.isEmpty)) {
        _syncUserInfo(showSuccessMessage: false);
      }
      // 初始化 Memos 连接状态
      _refreshConnectionInfo();
      final appProvider = Provider.of<AppProvider>(context, listen: false);
      if (appProvider.isLoggedIn && appProvider.appConfig.memosApiUrl != null) {
        _updateConnectionStatus();
        _statusCheckTimer = Timer.periodic(
          const Duration(seconds: 30),
          (_) {
            if (mounted) {
              _updateConnectionStatus();
            }
          },
        );
      }
    });
  }

  @override
  void dispose() {
    _statusCheckTimer?.cancel();
    _nicknameController.dispose();
    _emailController.dispose();
    _bioController.dispose();
    super.dispose();
  }

  // 格式化创建时间
  String _formatCreationTime(User user) {
    if (user.lastSyncTime != null) {
      return DateFormat('yyyy-MM-dd HH:mm:ss').format(user.lastSyncTime!);
    }
    return AppLocalizationsSimple.of(context)?.unknown ?? '未知';
  }

  // 从服务器同步用户信息
  Future<void> _syncUserInfo({bool showSuccessMessage = true}) async {
    final l10n = AppLocalizationsSimple.of(context);
    final appProvider = Provider.of<AppProvider>(context, listen: false);
    if (!appProvider.isLoggedIn || appProvider.memosApiService == null) {
      SnackBarUtils.showError(
        context,
        l10n?.notLoggedInOrAPINotInitialized ?? '未登录或API服务未初始化',
      );
      return;
    }

    try {
      setState(() {
        _isUpdatingAvatar = true; // 使用同一个loading状态
      });

      final apiUser = await appProvider.memosApiService!.getUserInfo();

      // 更新本地用户信息
      final currentUser = appProvider.user;
      if (currentUser == null) {
        throw Exception(l10n?.currentUserInfoEmpty ?? '当前用户信息为空');
      }

      final updatedUser = User(
        id: apiUser.id,
        username: apiUser.username.isNotEmpty
            ? apiUser.username
            : currentUser.username,
        nickname: apiUser.nickname ?? currentUser.nickname,
        email: apiUser.email ?? currentUser.email,
        description: apiUser.description ?? currentUser.description,
        role: apiUser.role,
        avatarUrl: apiUser.avatarUrl ?? currentUser.avatarUrl,
        token: currentUser.token, // 保留原token
        lastSyncTime: DateTime.now(),
        serverUrl: currentUser.serverUrl,
      );

      await _preferencesService.saveUser(updatedUser);
      await appProvider.setUser(updatedUser);
      if (!mounted) {
        return;
      }

      // 重新加载控制器的值
      setState(() {
        _nicknameController.text = updatedUser.nickname ?? updatedUser.username;
        _emailController.text = updatedUser.email ?? '';
        _bioController.text = updatedUser.description ?? '';
      });

      if (showSuccessMessage) {
        SnackBarUtils.showSuccess(
          context,
          l10n?.userInfoSyncSuccess ?? '用户信息同步成功',
        );
      }
    } on Object catch (e) {
      if (mounted) {
        SnackBarUtils.showError(
          context,
          '${l10n?.userInfoSyncFailed ?? '同步失败'}: $e',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isUpdatingAvatar = false;
        });
      }
    }
  }

  // ---------- Memos 连接（原「服务器连接」页并入） ----------

  String get _l10nServer =>
      AppLocalizationsSimple.of(context)?.serverUrl ?? '服务器连接';

  /// 刷新连接信息（地址、上次同步时间）
  void _refreshConnectionInfo() {
    final appProvider = Provider.of<AppProvider>(context, listen: false);
    final url = appProvider.appConfig.memosApiUrl;
    var host = '';
    if (url != null && url.isNotEmpty) {
      try {
        final uri = Uri.parse(url);
        host = '${uri.host}${uri.hasPort ? ':${uri.port}' : ''}';
      } on Object {
        host = url;
      }
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _hasServerUrl = url != null && url.isNotEmpty;
      _serverHost = host;
      _lastSyncLabel = _formatLastSync(appProvider.user?.lastSyncTime);
    });
  }

  String _formatLastSync(DateTime? lastSync) {
    final l10n = AppLocalizationsSimple.of(context);
    if (lastSync == null) {
      return l10n?.notSynced ?? '未同步';
    }
    final diff = DateTime.now().difference(lastSync);
    if (diff.inMinutes < 1) {
      return l10n?.justNow ?? '刚刚';
    } else if (diff.inMinutes < 60) {
      return l10n?.minutesAgo(diff.inMinutes) ?? '${diff.inMinutes}分钟前';
    } else if (diff.inHours < 24) {
      return l10n?.hoursAgo(diff.inHours) ?? '${diff.inHours}小时前';
    }
    return l10n?.daysAgo(diff.inDays) ?? '${diff.inDays}天前';
  }

  Future<http.Response?> _pingMemosApi(AppProvider appProvider) async {
    final baseUrl = appProvider.appConfig.memosApiUrl;
    if (baseUrl == null || baseUrl.isEmpty) {
      return null;
    }
    final headers = {
      'Accept': 'application/json',
      if (appProvider.appConfig.lastToken != null)
        'Authorization': 'Bearer ${appProvider.appConfig.lastToken}',
    };
    http.Response? lastResponse;
    for (final path in ['/api/v1/workspace/profile', '/api/v1/status']) {
      final response = await http
          .get(Uri.parse('$baseUrl$path'), headers: headers)
          .timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) {
        return response;
      }
      lastResponse = response;
    }
    return lastResponse;
  }

  Future<void> _updateConnectionStatus() async {
    final appProvider = Provider.of<AppProvider>(context, listen: false);
    if (!appProvider.isLoggedIn) {
      return;
    }
    try {
      final response = await _pingMemosApi(appProvider);
      if (response != null && response.statusCode == 200) {
        final start = DateTime.now();
        await _pingMemosApi(appProvider);
        final latency = DateTime.now().difference(start).inMilliseconds;
        if (mounted) {
          setState(() {
            _isConnectionHealthy = true;
            _latency = '$latency ms';
          });
        }
      } else {
        throw Exception('HTTP ${response?.statusCode}');
      }
    } on Object {
      if (mounted) {
        setState(() {
          _isConnectionHealthy = false;
          _latency = AppLocalizationsSimple.of(context)?.timeout ?? '超时';
        });
      }
    }
  }

  Future<void> _syncData() async {
    if (_isSyncing) {
      return;
    }
    setState(() {
      _isSyncing = true;
    });
    try {
      final appProvider = Provider.of<AppProvider>(context, listen: false);
      if (!appProvider.isLoggedIn) {
        SnackBarUtils.showError(context, '同步失败: 请先登录');
        return;
      }
      final syncResult = await appProvider.syncLocalDataToServer();
      await appProvider.fetchNotesFromServer();
      if (!mounted) {
        return;
      }
      if (syncResult) {
        SnackBarUtils.showSuccess(context, '同步成功');
        setState(() {
          _lastSyncLabel = AppLocalizationsSimple.of(context)?.justNow ?? '刚刚';
        });
        if (appProvider.user != null) {
          final updatedUser =
              appProvider.user!.copyWith(lastSyncTime: DateTime.now());
          await appProvider.setUser(updatedUser);
        }
      } else {
        SnackBarUtils.showError(context, '同步失败');
      }
    } on Object catch (e) {
      if (mounted) {
        SnackBarUtils.showError(context, '同步失败: $e');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSyncing = false;
        });
      }
    }
  }

  Future<void> _diagnoseConnection() async {
    if (_isDiagnosing) {
      return;
    }
    setState(() {
      _isDiagnosing = true;
    });
    final steps = <_ConnLog>[];
    void addStep(String message, _ConnLogType type) {
      steps.add(_ConnLog(message, type));
    }

    try {
      final appProvider = Provider.of<AppProvider>(context, listen: false);
      final url = appProvider.appConfig.memosApiUrl;
      if (url == null || url.isEmpty) {
        addStep('未配置服务器地址', _ConnLogType.error);
        _showDiagResult(steps);
        return;
      }
      Uri uri;
      try {
        uri = Uri.parse(url);
        addStep('服务器地址: ${uri.host}', _ConnLogType.success);
        addStep('协议: ${uri.scheme.toUpperCase()}', _ConnLogType.success);
      } on Object catch (e) {
        addStep('解析服务器地址失败: $e', _ConnLogType.error);
        _showDiagResult(steps);
        return;
      }

      try {
        final start = DateTime.now();
        await http
            .head(Uri.parse('${uri.scheme}://${uri.host}:${uri.port}'))
            .timeout(const Duration(seconds: 5));
        addStep(
          '连通性检查通过，耗时 '
          '${DateTime.now().difference(start).inMilliseconds}ms',
          _ConnLogType.success,
        );
      } on Object catch (e) {
        addStep('连通性检查失败: $e', _ConnLogType.error);
      }

      var apiHealthy = false;
      try {
        final start = DateTime.now();
        final response = await _pingMemosApi(appProvider);
        final duration = DateTime.now().difference(start).inMilliseconds;
        if (response != null && response.statusCode == 200) {
          apiHealthy = true;
          addStep('API 连接成功，响应时间: ${duration}ms', _ConnLogType.success);
        } else {
          addStep('API 连接失败: HTTP ${response?.statusCode}', _ConnLogType.error);
        }
      } on Object catch (e) {
        addStep('API 连接失败: $e', _ConnLogType.error);
      }

      if (appProvider.appConfig.lastToken != null) {
        try {
          final tokenService = MemosApiServiceFixed(
            baseUrl: url,
            token: appProvider.appConfig.lastToken,
          );
          await tokenService.getUserInfo().timeout(const Duration(seconds: 5));
          addStep('登录凭证验证成功', _ConnLogType.success);
        } on Object catch (e) {
          addStep('登录凭证验证失败: $e', _ConnLogType.error);
        }
      }

      addStep(
        apiHealthy ? '诊断结果: 连接正常' : '诊断结果: 连接异常',
        apiHealthy ? _ConnLogType.success : _ConnLogType.error,
      );
      setState(() {
        _isConnectionHealthy = apiHealthy;
      });
      _showDiagResult(steps);
    } finally {
      if (mounted) {
        setState(() {
          _isDiagnosing = false;
        });
      }
    }
  }

  void _showDiagResult(List<_ConnLog> steps) {
    if (!mounted) {
      return;
    }
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('连接诊断'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 280),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final step in steps)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          switch (step.type) {
                            _ConnLogType.success => Icons.check_circle_outline,
                            _ConnLogType.error => Icons.error_outline,
                            _ConnLogType.warning =>
                              Icons.warning_amber_outlined,
                          },
                          size: 16,
                          color: switch (step.type) {
                            _ConnLogType.success => const Color(0xFF34C759),
                            _ConnLogType.error => const Color(0xFFFF3B30),
                            _ConnLogType.warning => const Color(0xFFFF9500),
                          },
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            step.message,
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(AppLocalizationsSimple.of(context)?.confirm ?? '确定'),
          ),
        ],
      ),
    );
  }

  // 选择头像
  Future<void> _pickImage(User user) async {
    final l10n = AppLocalizationsSimple.of(context);
    try {
      setState(() {
        _isUpdatingAvatar = true;
      });

      final image = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 800,
        maxHeight: 800,
        imageQuality: 95,
      );
      if (!mounted) {
        return;
      }

      if (image == null) {
        setState(() {
          _isUpdatingAvatar = false;
        });
        return;
      }

      setState(() {
        _selectedImage = File(image.path);
      });

      final appProvider = Provider.of<AppProvider>(context, listen: false);
      if (appProvider.memosApiService != null && appProvider.isLoggedIn) {
        try {
          final resourceService = appProvider.resourceService;
          if (resourceService == null) {
            throw Exception(
              l10n?.resourceServiceNotInitialized ?? '资源服务未初始化',
            );
          }

          final uploadResult =
              await resourceService.uploadImage(_selectedImage!);
          final serverPath = uploadResult['serverPath']?.toString() ??
              MemosResourceService.buildResourcePath(
                uploadResult['data'] as Map<String, dynamic>,
              );
          final imageUrl = resourceService.buildImageUrl(serverPath);

          if (imageUrl.isNotEmpty) {
            // 使用AppProvider的updateUserInfo方法确保全局状态同步
            final success =
                await appProvider.updateUserInfo(avatarUrl: imageUrl);
            if (!mounted) {
              return;
            }

            if (!success) {
              // 如果AppProvider更新失败，手动更新本地状态
              final updatedUser = user.copyWith(avatarUrl: imageUrl);
              await _preferencesService.saveUser(updatedUser);
              await appProvider.setUser(updatedUser);
            }

            if (mounted) {
              SnackBarUtils.showSuccess(
                context,
                l10n?.avatarUpdated ?? '头像已更新',
              );

              // 清除网络图片缓存，确保新头像能立即显示
              PaintingBinding.instance.imageCache.clear();
              PaintingBinding.instance.imageCache.clearLiveImages();
            }

            await _syncUserInfo(showSuccessMessage: false);
            if (!mounted) {
              return;
            }
          } else {
            final uploadedAvatarUrlMissingText =
                l10n?.uploadedAvatarUrlMissing ?? '无法获取上传的头像URL';
            throw Exception(uploadedAvatarUrlMissingText);
          }
        } on Object catch (e) {
          if (mounted) {
            SnackBarUtils.showError(
              context,
              '${l10n?.uploadAvatarFailed ?? '上传头像失败'}: $e',
            );
          }
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _isUpdatingAvatar = false;
        });
      }
    }
  }

  // 显示修改昵称对话框
  void _showNicknameDialog(BuildContext context, User user) {
    final controller = TextEditingController(text: user.nickname);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(AppLocalizationsSimple.of(context)?.nickname ?? '修改昵称'),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(
            labelText: AppLocalizationsSimple.of(context)?.nickname ?? '昵称',
            hintText:
                AppLocalizationsSimple.of(context)?.pleaseEnterNewNickname ??
                    '请输入新的昵称',
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(AppLocalizationsSimple.of(context)?.cancel ?? '取消'),
          ),
          TextButton(
            onPressed: () async {
              final newNickname = controller.text.trim();
              if (newNickname.isNotEmpty) {
                final appProvider =
                    Provider.of<AppProvider>(context, listen: false);
                final result =
                    await appProvider.updateUserInfo(nickname: newNickname);

                if (context.mounted) {
                  Navigator.pop(context);

                  if (result) {
                    SnackBarUtils.showSuccess(
                      context,
                      AppLocalizationsSimple.of(context)
                              ?.nicknameUpdateSuccess ??
                          '昵称更新成功',
                    );
                  } else {
                    SnackBarUtils.showError(
                      context,
                      AppLocalizationsSimple.of(context)
                              ?.nicknameUpdateFailed ??
                          '昵称更新失败',
                    );
                  }
                }
              }
            },
            child: Text(AppLocalizationsSimple.of(context)?.save ?? '保存'),
          ),
        ],
      ),
    );
  }

  // 显示修改简介对话框
  // 显示修改邮箱对话框
  void _showEmailDialog(BuildContext context, User user) {
    final controller = TextEditingController(text: user.email);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(AppLocalizationsSimple.of(context)?.email ?? '修改邮箱'),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(
            labelText: AppLocalizationsSimple.of(context)?.email ?? '邮箱',
            hintText: AppLocalizationsSimple.of(context)?.pleaseEnterNewEmail ??
                '请输入新的邮箱地址',
          ),
          keyboardType: TextInputType.emailAddress,
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(AppLocalizationsSimple.of(context)?.cancel ?? '取消'),
          ),
          TextButton(
            onPressed: () async {
              final newEmail = controller.text.trim();
              if (newEmail.isNotEmpty) {
                final appProvider =
                    Provider.of<AppProvider>(context, listen: false);
                final result =
                    await appProvider.updateUserInfo(email: newEmail);

                if (context.mounted) {
                  Navigator.pop(context);

                  if (result) {
                    SnackBarUtils.showSuccess(
                      context,
                      AppLocalizationsSimple.of(context)?.emailUpdateSuccess ??
                          '邮箱更新成功',
                    );
                  } else {
                    SnackBarUtils.showError(
                      context,
                      AppLocalizationsSimple.of(context)?.emailUpdateFailed ??
                          '邮箱更新失败',
                    );
                  }
                }
              }
            },
            child: Text(AppLocalizationsSimple.of(context)?.save ?? '保存'),
          ),
        ],
      ),
    );
  }

  // 🚀 大厂标准：显示退出登录确认对话框（与侧边栏逻辑一致）
  void _showLogoutDialog(BuildContext context) {
    final appProvider = Provider.of<AppProvider>(context, listen: false);
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final dialogBgColor = isDarkMode ? const Color(0xFF2C2C2C) : Colors.white;
    final textColor = isDarkMode ? Colors.white : Colors.black87;
    final secondaryTextColor = isDarkMode ? Colors.grey[400] : Colors.grey[600];

    // 显示选项对话框
    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: dialogBgColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: isDarkMode
                      ? Colors.red.shade900.withValues(alpha: 0.2)
                      : Colors.red.shade50,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.logout_rounded,
                  color: Colors.red.shade400,
                  size: 32,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                AppLocalizationsSimple.of(context)?.logout ?? '退出登录',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: textColor,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                AppLocalizationsSimple.of(context)?.logoutMessage ??
                    '退出登录时如何处理本地数据？',
                style: TextStyle(
                  fontSize: 14,
                  color: secondaryTextColor,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  Expanded(
                    child: TextButton(
                      style: TextButton.styleFrom(
                        backgroundColor: Colors.grey.shade100,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: () {
                        Navigator.pop(context);
                        // 清空本地数据
                        _processLogout(
                          context,
                          appProvider,
                          keepLocalData: false,
                        );
                      },
                      child: Text(
                        AppLocalizationsSimple.of(context)?.clearLocalData ??
                            '清空本地数据',
                        style: const TextStyle(
                          color: Colors.red,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Theme.of(context).primaryColor,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: () {
                        Navigator.pop(context);
                        // 保留本地数据
                        _processLogout(
                          context,
                          appProvider,
                          keepLocalData: true,
                        );
                      },
                      child: Text(
                        AppLocalizationsSimple.of(context)?.keepLocalData ??
                            '保留本地数据',
                        style: const TextStyle(
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 处理退出登录逻辑（与侧边栏逻辑一致）
  void _processLogout(
    BuildContext context,
    AppProvider appProvider, {
    required bool keepLocalData,
  }) {
    // 先检查是否有未同步的笔记
    appProvider.logout(keepLocalData: keepLocalData).then((result) {
      if (!context.mounted) {
        return;
      }
      final (success, message) = result;

      if (!success && message != null) {
        // 有未同步的笔记，显示确认对话框
        showDialog(
          context: context,
          builder: (context) => Dialog(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.amber.shade50,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.warning_amber_rounded,
                      color: Colors.amber.shade600,
                      size: 32,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    AppLocalizationsSimple.of(context)?.logoutConfirm ?? '确认退出',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    message,
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey[600],
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      Expanded(
                        child: TextButton(
                          style: TextButton.styleFrom(
                            backgroundColor: Colors.grey.shade100,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          onPressed: () => Navigator.pop(context),
                          child: Text(
                            AppLocalizationsSimple.of(context)?.cancel ?? '取消',
                            style: TextStyle(
                              color: Colors.grey[700],
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red.shade400,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          onPressed: () {
                            // 用户确认退出，强制退出
                            Navigator.pop(context);
                            // 强制退出登录
                            appProvider
                                .logout(
                              force: true,
                              keepLocalData: keepLocalData,
                            )
                                .then((_) {
                              if (mounted && this.context.mounted) {
                                this.context.go('/login');
                              }
                            });
                          },
                          child: Text(
                            AppLocalizationsSimple.of(context)?.confirmLogout ??
                                '确定退出',
                            style: const TextStyle(
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      } else if (success) {
        // 没有未同步的笔记，直接退出
        context.go('/login');
      } else {
        // 退出失败，显示错误信息
        SnackBarUtils.showError(
          context,
          message ??
              (AppLocalizationsSimple.of(context)?.logoutFailed ?? '退出登录失败'),
        );
      }
    });
  }

  // 显示修改密码对话框
  void _showPasswordDialog(BuildContext context, User user) {
    final currentPasswordController = TextEditingController();
    final newPasswordController = TextEditingController();
    final confirmPasswordController = TextEditingController();
    var isCurrentPasswordVisible = false;
    var isNewPasswordVisible = false;
    var isConfirmPasswordVisible = false;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(
            AppLocalizationsSimple.of(context)?.modifyPassword ?? '修改密码',
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: currentPasswordController,
                decoration: InputDecoration(
                  labelText: AppLocalizationsSimple.of(context)
                          ?.currentPasswordLabel ??
                      '当前密码',
                  hintText: AppLocalizationsSimple.of(context)
                          ?.enterCurrentPassword ??
                      '请输入当前密码',
                  suffixIcon: IconButton(
                    icon: Icon(
                      isCurrentPasswordVisible
                          ? Icons.visibility
                          : Icons.visibility_off,
                    ),
                    onPressed: () {
                      setState(() {
                        isCurrentPasswordVisible = !isCurrentPasswordVisible;
                      });
                    },
                  ),
                ),
                obscureText: !isCurrentPasswordVisible,
                autofocus: true,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: newPasswordController,
                decoration: InputDecoration(
                  labelText:
                      AppLocalizationsSimple.of(context)?.newPassword ?? '新密码',
                  hintText: AppLocalizationsSimple.of(context)
                          ?.enterNewPasswordWithMin ??
                      '请输入新密码（至少3位）',
                  suffixIcon: IconButton(
                    icon: Icon(
                      isNewPasswordVisible
                          ? Icons.visibility
                          : Icons.visibility_off,
                    ),
                    onPressed: () {
                      setState(() {
                        isNewPasswordVisible = !isNewPasswordVisible;
                      });
                    },
                  ),
                ),
                obscureText: !isNewPasswordVisible,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: confirmPasswordController,
                decoration: InputDecoration(
                  labelText:
                      AppLocalizationsSimple.of(context)?.confirmNewPassword ??
                          '确认新密码',
                  hintText: AppLocalizationsSimple.of(context)
                          ?.enterNewPasswordAgain ??
                      '请再次输入新密码',
                  suffixIcon: IconButton(
                    icon: Icon(
                      isConfirmPasswordVisible
                          ? Icons.visibility
                          : Icons.visibility_off,
                    ),
                    onPressed: () {
                      setState(() {
                        isConfirmPasswordVisible = !isConfirmPasswordVisible;
                      });
                    },
                  ),
                ),
                obscureText: !isConfirmPasswordVisible,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(AppLocalizationsSimple.of(context)?.cancel ?? '取消'),
            ),
            TextButton(
              onPressed: () async {
                final currentPassword = currentPasswordController.text.trim();
                final newPassword = newPasswordController.text.trim();
                final confirmPassword = confirmPasswordController.text.trim();

                // 验证输入
                if (currentPassword.isEmpty) {
                  SnackBarUtils.showError(
                    context,
                    AppLocalizationsSimple.of(context)?.enterCurrentPassword ??
                        '请输入当前密码',
                  );
                  return;
                }

                if (newPassword.isEmpty) {
                  SnackBarUtils.showError(
                    context,
                    AppLocalizationsSimple.of(context)?.enterNewPassword ??
                        '请输入新密码',
                  );
                  return;
                }

                if (newPassword.length < 3) {
                  SnackBarUtils.showError(
                    context,
                    AppLocalizationsSimple.of(context)?.newPasswordTooShort ??
                        '新密码至少需要3位',
                  );
                  return;
                }

                if (newPassword != confirmPassword) {
                  SnackBarUtils.showError(
                    context,
                    AppLocalizationsSimple.of(context)?.newPasswordMismatch ??
                        '两次输入的新密码不一致',
                  );
                  return;
                }

                if (currentPassword == newPassword) {
                  SnackBarUtils.showError(
                    context,
                    AppLocalizationsSimple.of(context)
                            ?.newPasswordSameAsCurrent ??
                        '新密码不能与当前密码相同',
                  );
                  return;
                }

                try {
                  final appProvider =
                      Provider.of<AppProvider>(context, listen: false);
                  final result = await appProvider.updatePassword(
                    currentPassword: currentPassword,
                    newPassword: newPassword,
                  );

                  if (context.mounted && mounted) {
                    Navigator.pop(context);

                    if (result) {
                      SnackBarUtils.showSuccess(
                        this.context,
                        AppLocalizationsSimple.of(this.context)
                                ?.passwordUpdateSuccessRelogin ??
                            '密码修改成功，请重新登录',
                      );
                      // 密码修改成功后，清除登录状态，要求用户重新登录
                      await appProvider.logout();
                      if (mounted) {
                        unawaited(
                          Navigator.of(this.context).pushNamedAndRemoveUntil(
                            '/login',
                            (route) => false,
                          ),
                        );
                      }
                    } else {
                      SnackBarUtils.showError(
                        context,
                        AppLocalizationsSimple.of(context)
                                ?.passwordUpdateFailedCheckCurrent ??
                            '密码修改失败，请检查当前密码是否正确',
                      );
                    }
                  }
                } on Object catch (e) {
                  if (context.mounted && mounted) {
                    Navigator.pop(context);
                    SnackBarUtils.showError(
                      this.context,
                      '${AppLocalizationsSimple.of(this.context)?.passwordUpdateFailed ?? '密码修改失败'}: $e',
                    );
                  }
                }
              },
              child: Text(AppLocalizationsSimple.of(context)?.save ?? '保存'),
            ),
          ],
        ),
      ),
    );
  }

  // 构建头像图像，支持URL和base64格式

  // 🚀 大厂标准：未登录状态的引导界面
  Widget _buildLoginPromptUI(BuildContext context) {
    final theme = Theme.of(context);
    final isDarkMode = theme.brightness == Brightness.dark;

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: isDarkMode
              ? [
                  const Color(0xFF1a1a1a),
                  const Color(0xFF0a0a0a),
                ]
              : [
                  const Color(0xFFF5F7FA),
                  const Color(0xFFFFFFFF),
                ],
        ),
      ),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: Column(
            children: [
              const SizedBox(height: 40),

              // 占位头像 + 点击登录提示
              GestureDetector(
                onTap: () => _navigateToLogin(context),
                child: Container(
                  width: 100,
                  height: 100,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        theme.primaryColor.withValues(alpha: 0.3),
                        theme.primaryColor.withValues(alpha: 0.1),
                      ],
                    ),
                    border: Border.all(
                      color: theme.primaryColor.withValues(alpha: 0.3),
                      width: 2,
                    ),
                  ),
                  child: Icon(
                    Icons.person_outline,
                    size: 50,
                    color: theme.primaryColor.withValues(alpha: 0.7),
                  ),
                ),
              ),

              const SizedBox(height: 24),

              // 欢迎信息
              Text(
                AppLocalizationsSimple.of(context)?.welcomeToInkPaperShort ??
                    '欢迎使用 InkPaper',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: theme.textTheme.bodyLarge?.color,
                ),
              ),

              const SizedBox(height: 12),

              Text(
                AppLocalizationsSimple.of(context)?.loginToUnlockFeatures ??
                    '登录后解锁更多精彩功能',
                style: TextStyle(
                  fontSize: 15,
                  color:
                      theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.6),
                ),
              ),

              const SizedBox(height: 40),

              // 功能预览卡片
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: theme.cardColor,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.05),
                      blurRadius: 10,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    _buildFeatureItem(
                      context,
                      icon: Icons.cloud_sync,
                      title: AppLocalizationsSimple.of(context)
                              ?.cloudSyncFeature ??
                          '云端同步',
                      description:
                          AppLocalizationsSimple.of(context)?.cloudSyncDesc ??
                              '笔记实时同步，随时随地访问',
                      color: const Color(0xFF3E9BFF),
                    ),
                    const SizedBox(height: 16),
                    _buildFeatureItem(
                      context,
                      icon: Icons.psychology,
                      title: AppLocalizationsSimple.of(context)
                              ?.aiAssistantFeature ??
                          'AI 助手',
                      description:
                          AppLocalizationsSimple.of(context)?.aiAssistantDesc ??
                              '智能总结、扩展、改进笔记内容',
                      color: const Color(0xFF46B696),
                    ),
                    const SizedBox(height: 16),
                    _buildFeatureItem(
                      context,
                      icon: Icons.notifications_active,
                      title: AppLocalizationsSimple.of(context)
                              ?.remindersFeature ??
                          '定时提醒',
                      description:
                          AppLocalizationsSimple.of(context)?.remindersDesc ??
                              '重要事项不错过，高效管理时间',
                      color: const Color(0xFFFF6B6B),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 32),

              // 登录按钮（主按钮）
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  onPressed: () => _navigateToLogin(context),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: theme.primaryColor,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    elevation: 2,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.login, size: 20),
                      const SizedBox(width: 8),
                      Text(
                        AppLocalizationsSimple.of(context)?.login ?? '立即登录',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 12),

              // 注册按钮（次按钮）
              SizedBox(
                width: double.infinity,
                height: 50,
                child: OutlinedButton(
                  onPressed: () => _navigateToRegister(context),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: theme.primaryColor,
                    side: BorderSide(color: theme.primaryColor, width: 1.5),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.person_add, size: 20),
                      const SizedBox(width: 8),
                      Text(
                        AppLocalizationsSimple.of(context)?.register ?? '注册新账号',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 功能预览项
  Widget _buildFeatureItem(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String description,
    required Color color,
  }) =>
      Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: color, size: 24),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).textTheme.bodyLarge?.color,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.color
                        ?.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
        ],
      );

  // 跳转到登录页（使用GoRouter）
  void _navigateToLogin(BuildContext context) {
    context.go('/login');
  }

  // 跳转到注册页（使用GoRouter）
  void _navigateToRegister(BuildContext context) {
    context.push('/register');
  }

  // 默认头像

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(AppLocalizationsSimple.of(context)?.accountInfo ?? '账户信息'),
        centerTitle: true,
      ),
      body: Consumer<AppProvider>(
        builder: (context, appProvider, child) {
          // 🚀 大厂标准：未登录状态的友好引导界面
          if (appProvider.user == null) {
            return _buildLoginPromptUI(context);
          }

          final user = appProvider.user!;

          return ListView(
            padding: const EdgeInsets.symmetric(vertical: 20),
            children: [
              // 用户基本信息卡片
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: theme.cardColor,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.05),
                      blurRadius: 10,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    Stack(
                      children: [
                        GestureDetector(
                          onTap: () => _pickImage(user),
                          child: Container(
                            width: 80,
                            height: 80,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.1),
                                  blurRadius: 8,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: _isUpdatingAvatar
                                ? const Center(
                                    child: CircularProgressIndicator(),
                                  )
                                : CachedAvatar.fromUser(
                                    user,
                                    size: 120,
                                  ),
                          ),
                        ),
                        if (!_isUpdatingAvatar)
                          Positioned(
                            bottom: 0,
                            left: 0,
                            right: 0,
                            child: Container(
                              height: 28,
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.5),
                                borderRadius: const BorderRadius.only(
                                  bottomLeft: Radius.circular(40),
                                  bottomRight: Radius.circular(40),
                                ),
                              ),
                              child: const Center(
                                child: Icon(
                                  Icons.edit,
                                  color: Colors.white,
                                  size: 16,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text(
                      user.nickname ?? user.username,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      user.email ??
                          (AppLocalizationsSimple.of(context)?.emailNotSet ??
                              '未设置邮箱'),
                      style: TextStyle(
                        fontSize: 14,
                        color: theme.textTheme.bodyMedium?.color
                            ?.withValues(alpha: 0.7),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${AppLocalizationsSimple.of(context)?.createdTimeLabel ?? '创建时间：'}${_formatCreationTime(user)}',
                      style: TextStyle(
                        fontSize: 14,
                        color: theme.textTheme.bodyMedium?.color
                            ?.withValues(alpha: 0.5),
                      ),
                    ),
                  ],
                ),
              ),

              // Memos 连接状态（原「服务器连接」页并入）
              Container(
                margin:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: theme.cardColor,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.05),
                      blurRadius: 10,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: !_hasServerUrl
                                ? Colors.grey.withValues(alpha: 0.15)
                                : (_isConnectionHealthy
                                    ? const Color(0xFF34C759)
                                        .withValues(alpha: 0.15)
                                    : const Color(0xFFFF3B30)
                                        .withValues(alpha: 0.15)),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            !_hasServerUrl
                                ? Icons.cloud_off_outlined
                                : (_isConnectionHealthy
                                    ? Icons.cloud_done_outlined
                                    : Icons.cloud_off_outlined),
                            color: !_hasServerUrl
                                ? Colors.grey
                                : (_isConnectionHealthy
                                    ? const Color(0xFF34C759)
                                    : const Color(0xFFFF3B30)),
                            size: 26,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _l10nServer,
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                !_hasServerUrl
                                    ? '未配置 Memos 服务器'
                                    : (_isConnectionHealthy ? '连接正常' : '连接异常'),
                                style: TextStyle(
                                  fontSize: 13,
                                  color: theme.textTheme.bodyMedium?.color
                                      ?.withValues(alpha: 0.6),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    if (_hasServerUrl) ...[
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: theme.dividerColor.withValues(alpha: 0.05),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          children: [
                            _buildServerDetail('服务器', _serverHost),
                            const SizedBox(height: 8),
                            _buildServerDetail('延迟', _latency),
                            const SizedBox(height: 8),
                            _buildServerDetail('上次同步', _lastSyncLabel),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton(
                              onPressed: !_isSyncing ? _syncData : null,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: theme.primaryColor,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              child: _isSyncing
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        valueColor:
                                            AlwaysStoppedAnimation<Color>(
                                          Colors.white,
                                        ),
                                      ),
                                    )
                                  : const Text('立即同步'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextButton(
                              onPressed:
                                  !_isDiagnosing ? _diagnoseConnection : null,
                              style: TextButton.styleFrom(
                                backgroundColor:
                                    theme.dividerColor.withValues(alpha: 0.05),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              child: _isDiagnosing
                                  ? SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        valueColor:
                                            AlwaysStoppedAnimation<Color>(
                                          theme.primaryColor,
                                        ),
                                      ),
                                    )
                                  : const Text('连接诊断'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),

              // 基本信息设置
              Container(
                margin:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                decoration: BoxDecoration(
                  color: theme.cardColor,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.05),
                      blurRadius: 10,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
                      child: Text(
                        AppLocalizationsSimple.of(context)?.basicInfo ?? '基本信息',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: theme.primaryColor,
                        ),
                      ),
                    ),
                    ListTile(
                      leading: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: const Color(0xFF46B696).withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(
                          Icons.person_outline,
                          color: Color(0xFF46B696),
                        ),
                      ),
                      title: Text(
                        AppLocalizationsSimple.of(context)?.modifyNickname ??
                            '修改昵称',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _showNicknameDialog(context, user),
                    ),
                    ListTile(
                      leading: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: const Color(0xFF3E9BFF).withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(
                          Icons.email_outlined,
                          color: Color(0xFF3E9BFF),
                        ),
                      ),
                      title: Text(
                        AppLocalizationsSimple.of(context)?.modifyEmail ??
                            '修改邮箱',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _showEmailDialog(context, user),
                    ),
                    ListTile(
                      leading: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: const Color(0xFFFF6B6B).withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(
                          Icons.lock_outline,
                          color: Color(0xFFFF6B6B),
                        ),
                      ),
                      title: Text(
                        AppLocalizationsSimple.of(context)?.modifyPassword ??
                            '修改密码',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _showPasswordDialog(context, user),
                    ),
                  ],
                ),
              ),

              // 🚀 大厂标准：退出登录区域（放在显眼位置）
              Container(
                margin:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                decoration: BoxDecoration(
                  color: theme.cardColor,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.05),
                      blurRadius: 10,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    ListTile(
                      leading: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: const Color(0xFF3E9BFF).withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(
                          Icons.sync,
                          color: Color(0xFF3E9BFF),
                        ),
                      ),
                      title: Text(
                        AppLocalizationsSimple.of(context)?.syncPersonalInfo ??
                            '同步个人信息',
                      ),
                      subtitle: Text(
                        AppLocalizationsSimple.of(context)
                                ?.syncPersonalInfoDesc ??
                            '从服务器同步最新的个人资料',
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.textTheme.bodyMedium?.color
                              ?.withValues(alpha: 0.6),
                        ),
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: _syncUserInfo,
                    ),
                    const Divider(height: 1, indent: 56, endIndent: 16),
                    ListTile(
                      leading: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: const Color(0xFFFF6B6B).withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(
                          Icons.logout,
                          color: Color(0xFFFF6B6B),
                        ),
                      ),
                      title: Text(
                        AppLocalizationsSimple.of(context)?.logout ?? '退出登录',
                        style: const TextStyle(
                          color: Color(0xFFFF6B6B),
                        ),
                      ),
                      subtitle: Text(
                        AppLocalizationsSimple.of(context)?.logoutDesc ??
                            '退出当前账号并返回登录页',
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.textTheme.bodyMedium?.color
                              ?.withValues(alpha: 0.6),
                        ),
                      ),
                      trailing: const Icon(
                        Icons.chevron_right,
                        color: Color(0xFFFF6B6B),
                      ),
                      onTap: () => _showLogoutDialog(context),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildServerDetail(String label, String value) => Row(
        children: [
          Expanded(
            flex: 2,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 14,
                color: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.color
                    ?.withValues(alpha: 0.7),
              ),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 3,
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
              textAlign: TextAlign.right,
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
        ],
      );
}

/// 连接诊断步骤（弹窗展示用）
enum _ConnLogType { success, error, warning }

class _ConnLog {
  _ConnLog(this.message, this.type);
  final String message;
  final _ConnLogType type;
}
