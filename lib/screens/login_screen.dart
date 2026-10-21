import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:inkpaper/config/app_config.dart';
import 'package:inkpaper/l10n/app_localizations_simple.dart';
import 'package:inkpaper/providers/app_provider.dart';
import 'package:inkpaper/themes/app_theme.dart';
import 'package:inkpaper/utils/responsive_utils.dart';
import 'package:inkpaper/utils/snackbar_utils.dart';
import 'package:provider/provider.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({
    super.key,
    this.showBackButton = false,
  });
  final bool showBackButton;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with TickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  final _serverController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  bool _rememberLogin = true;
  bool _obscurePassword = true;

  // 🎬 动画控制器
  late AnimationController _fadeController;
  late AnimationController _slideController;
  late AnimationController _scaleController;
  late AnimationController _floatingController;

  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;
  late Animation<double> _scaleAnimation;
  late Animation<double> _floatingAnimation;

  @override
  void initState() {
    super.initState();
    debugPrint('LoginScreen: initState');
    _loadSavedLoginInfo();
    _rememberLogin = true;

    // 🎨 初始化动画系统
    _fadeController = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    );
    _slideController = AnimationController(
      duration: const Duration(milliseconds: 1000),
      vsync: this,
    );
    _scaleController = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );
    _floatingController = AnimationController(
      duration: const Duration(seconds: 4),
      vsync: this,
    );

    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeOutCubic,
    );

    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 0.5),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(
        parent: _slideController,
        curve: Curves.easeOutBack,
      ),
    );

    _scaleAnimation = Tween<double>(
      begin: 0,
      end: 1,
    ).animate(
      CurvedAnimation(
        parent: _scaleController,
        curve: Curves.elasticOut,
      ),
    );

    _floatingAnimation = Tween<double>(
      begin: 0,
      end: 1,
    ).animate(
      CurvedAnimation(
        parent: _floatingController,
        curve: Curves.easeInOutSine,
      ),
    );

    // 🎬 启动动画序列
    _fadeController.forward();
    Future.delayed(const Duration(milliseconds: 200), () {
      _slideController.forward();
    });
    Future.delayed(const Duration(milliseconds: 400), () {
      _scaleController.forward();
    });
    _floatingController.repeat(reverse: true);
  }

  @override
  void dispose() {
    _fadeController.dispose();
    _slideController.dispose();
    _scaleController.dispose();
    _floatingController.dispose();
    _serverController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _loadSavedLoginInfo() async {
    debugPrint('LoginScreen: 加载保存的登录信息');
    final appProvider = Provider.of<AppProvider>(context, listen: false);

    // 🎯 大厂标准：加载服务器地址偏好（跨页面共享）
    final prefsService = appProvider.preferencesService;
    final customServerUrl = await prefsService.getCustomServerUrl();

    final savedServer = await appProvider.getSavedServer();
    final savedUsername = await appProvider.getSavedUsername();
    final savedPassword = await appProvider.getSavedPassword();
    final savedToken = await appProvider.getSavedToken(); // 获取保存的token

    debugPrint('LoginScreen: 服务器地址: $customServerUrl');

    setState(() {
      _serverController.text = (customServerUrl != null &&
              customServerUrl.isNotEmpty &&
              customServerUrl != AppConfig.officialMemosServer)
          ? customServerUrl
          : '';
    });

    if (savedUsername != null) {
      debugPrint('LoginScreen: 发现保存的用户名');
      setState(() {
        _usernameController.text = savedUsername;
      });
    }

    if (savedPassword != null) {
      debugPrint('LoginScreen: 发现保存的密码');
      setState(() {
        _passwordController.text = savedPassword;
      });
    }

    // 🔑 检查是否有有效的token可以快速登录
    if (savedToken != null && savedServer != null && savedUsername != null) {
      unawaited(_attemptQuickLogin(savedServer, savedToken));
    }
  }

  // 🎯 大厂标准：处理自定义服务器地址变化
  Future<void> _onCustomServerUrlChanged(String url) async {
    final appProvider = Provider.of<AppProvider>(context, listen: false);
    final prefsService = appProvider.preferencesService;

    // 保存到SharedPreferences，实现跨页面同步
    await prefsService.saveCustomServerUrl(url);

    debugPrint('LoginScreen: 自定义服务器地址已更新: $url');
  }

  // 🚀 尝试使用保存的token快速登录
  Future<void> _attemptQuickLogin(String serverUrl, String token) async {
    try {
      final appProvider = Provider.of<AppProvider>(context, listen: false);

      // 尝试使用token登录
      final result =
          await appProvider.loginWithToken(serverUrl, token, remember: true);

      if (result.$1 && mounted) {
        // 成功则直接跳转到主页
        context.go('/');

        // 后台同步数据
        Future.delayed(const Duration(milliseconds: 500), () async {
          try {
            debugPrint('LoginScreen: 开始后台数据同步');
            await appProvider.fetchNotesFromServer();
          } on Object catch (e) {
            debugPrint('LoginScreen: 后台同步失败: $e');
          }
        });
      } else {
        // Token失效，清除保存的登录信息，让用户手动登录
        await appProvider.clearLoginInfo();
      }
    } on Object {
      // 异常情况下清除保存的登录信息
      if (mounted) {
        final appProvider = Provider.of<AppProvider>(context, listen: false);
        await appProvider.clearLoginInfo();
      }
    }
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() => _isLoading = true);

    try {
      final appProvider = Provider.of<AppProvider>(context, listen: false);
      final serverUrl = _serverController.text.trim();
      final username = _usernameController.text.trim();
      final password = _passwordController.text.trim();

      debugPrint('LoginScreen: 尝试登录，记住密码: $_rememberLogin');

      final result = await appProvider.loginWithPassword(
        serverUrl,
        username,
        password,
        remember: _rememberLogin,
      );

      if (result.$1 && mounted) {
        debugPrint('LoginScreen: 登录成功，立即进入主界面');

        // 🎉 显示成功提示
        await _showSuccessLoginDialog();

        // 🎉 成功动画
        await _scaleController.reverse();
        if (!mounted) {
          return;
        }

        context.go('/');

        // 后台执行数据同步
        unawaited(
          Future.microtask(() async {
            try {
              debugPrint('LoginScreen: 开始后台数据同步');
              await appProvider.fetchNotesFromServer();
              final hasLocalData = await appProvider.hasLocalData();
              if (hasLocalData) {
                await appProvider.syncLocalDataToServer();
              }
            } on Object catch (e) {
              debugPrint('LoginScreen: 后台同步失败: $e');
            }
          }),
        );
      } else if (mounted) {
        debugPrint('LoginScreen: 登录失败: ${result.$2}');
        SnackBarUtils.showError(
          context,
          result.$2 ??
              (AppLocalizationsSimple.of(context)
                      ?.loginFailedCheckCredentials ??
                  '登录失败，请检查账号密码和服务器地址'),
          onRetry: _login,
        );
      }
    } on Object catch (e) {
      debugPrint('LoginScreen: 登录异常: $e');
      if (mounted) {
        SnackBarUtils.showNetworkError(
          context,
          e,
          onRetry: _login,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  // 🎉 显示登录成功对话框
  Future<void> _showSuccessLoginDialog() async {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext context) => AlertDialog(
          backgroundColor: isDarkMode ? AppTheme.darkCardColor : Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          contentPadding: ResponsiveUtils.responsivePadding(context, all: 24),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 成功动画图标
              TweenAnimationBuilder<double>(
                duration: const Duration(milliseconds: 800),
                tween: Tween<double>(begin: 0, end: 1),
                curve: Curves.elasticOut,
                builder: (context, value, child) => Transform.scale(
                  scale: value,
                  child: Container(
                    width: ResponsiveUtils.responsiveIconSize(context, 80),
                    height: ResponsiveUtils.responsiveIconSize(context, 80),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Colors.green.withValues(alpha: 0.1),
                          Colors.green.withValues(alpha: 0.05),
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(40),
                    ),
                    child: Icon(
                      Icons.check_circle_rounded,
                      size: ResponsiveUtils.responsiveIconSize(context, 50),
                      color: Colors.green,
                    ),
                  ),
                ),
              ),

              SizedBox(height: ResponsiveUtils.responsiveSpacing(context, 20)),

              Text(
                AppLocalizationsSimple.of(context)?.loginSuccessful ?? '登录成功！',
                style: TextStyle(
                  fontSize: ResponsiveUtils.responsiveFontSize(context, 20),
                  fontWeight: FontWeight.bold,
                  color: isDarkMode ? Colors.white : AppTheme.textPrimaryColor,
                ),
              ),

              SizedBox(height: ResponsiveUtils.responsiveSpacing(context, 12)),

              Text(
                AppLocalizationsSimple.of(context)?.welcomeBackPreparingSpace ??
                    '欢迎回来！正在为您准备个人笔记空间...',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: ResponsiveUtils.responsiveFontSize(context, 14),
                  color: isDarkMode ? Colors.white70 : Colors.black54,
                  height: 1.5,
                ),
              ),

              SizedBox(height: ResponsiveUtils.responsiveSpacing(context, 20)),

              // 加载进度指示器
              SizedBox(
                width: ResponsiveUtils.responsive<double>(
                  context,
                  mobile: 200,
                  tablet: 220,
                  desktop: 250,
                ),
                child: LinearProgressIndicator(
                  backgroundColor:
                      isDarkMode ? Colors.grey[700] : Colors.grey[200],
                  valueColor: const AlwaysStoppedAnimation<Color>(
                    AppTheme.primaryColor,
                  ),
                  borderRadius: BorderRadius.circular(4),
                  minHeight: 6,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    // 1.5秒后自动关闭对话框
    await Future.delayed(const Duration(milliseconds: 1500));
    if (mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final screenHeight = MediaQuery.of(context).size.height;

    // 🎨 现代化配色方案 - 绿色主题
    const primaryColor = AppTheme.primaryColor;
    const primaryLight = AppTheme.primaryLightColor;

    final surfaceColor =
        isDarkMode ? AppTheme.darkBackgroundColor : AppTheme.backgroundColor;

    final cardColor =
        isDarkMode ? AppTheme.darkCardColor : AppTheme.surfaceColor;

    final textPrimary =
        isDarkMode ? AppTheme.darkTextPrimaryColor : AppTheme.textPrimaryColor;

    final textSecondary = isDarkMode
        ? AppTheme.darkTextSecondaryColor
        : AppTheme.textSecondaryColor;

    return Scaffold(
      backgroundColor: surfaceColor,
      extendBodyBehindAppBar: true,
      appBar: widget.showBackButton
          ? AppBar(
              backgroundColor: Colors.transparent,
              elevation: 0,
              leading: _buildNavButton(
                icon: Icons.arrow_back_ios_new,
                onTap: () => context.go('/'),
                isDarkMode: isDarkMode,
                cardColor: cardColor,
                textPrimary: textPrimary,
              ),
              actions: [
                _buildNavButton(
                  icon: Icons.help_outline,
                  onTap: _showHelpDialog,
                  isDarkMode: isDarkMode,
                  cardColor: cardColor,
                  textPrimary: textPrimary,
                ),
              ],
            )
          : AppBar(
              backgroundColor: Colors.transparent,
              elevation: 0,
              actions: [
                _buildNavButton(
                  icon: Icons.help_outline,
                  onTap: _showHelpDialog,
                  isDarkMode: isDarkMode,
                  cardColor: cardColor,
                  textPrimary: textPrimary,
                ),
              ],
            ),
      body: Stack(
        children: [
          // 🌟 背景装饰层
          _buildBackgroundDecoration(isDarkMode, primaryColor, screenHeight),

          // 🎭 主要内容层
          GestureDetector(
            onTap: () => FocusScope.of(context).unfocus(),
            child: SafeArea(
              child: ResponsiveLayout(
                mobile: _buildMobileLayout(
                  textPrimary,
                  textSecondary,
                  primaryColor,
                  primaryLight,
                  cardColor,
                  isDarkMode,
                ),
                tablet: _buildTabletLayout(
                  textPrimary,
                  textSecondary,
                  primaryColor,
                  primaryLight,
                  cardColor,
                  isDarkMode,
                ),
                desktop: _buildDesktopLayout(
                  textPrimary,
                  textSecondary,
                  primaryColor,
                  primaryLight,
                  cardColor,
                  isDarkMode,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // 移动端布局
  Widget _buildMobileLayout(
    Color textPrimary,
    Color textSecondary,
    Color primaryColor,
    Color primaryLight,
    Color cardColor,
    bool isDarkMode,
  ) =>
      CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          // 🚀 英雄区域
          SliverToBoxAdapter(
            child: _buildHeroSection(
              textPrimary: textPrimary,
              textSecondary: textSecondary,
              primaryColor: primaryColor,
              isDarkMode: isDarkMode,
            ),
          ),

          // 📝 登录表单
          SliverToBoxAdapter(
            child: _buildLoginForm(
              cardColor: cardColor,
              textPrimary: textPrimary,
              textSecondary: textSecondary,
              primaryColor: primaryColor,
              primaryLight: primaryLight,
              isDarkMode: isDarkMode,
            ),
          ),

          // 🔗 快速操作
          SliverToBoxAdapter(
            child: _buildQuickActions(
              textPrimary: textPrimary,
              textSecondary: textSecondary,
              primaryColor: primaryColor,
            ),
          ),

          // 📱 底部空间
          SliverToBoxAdapter(
            child: SizedBox(
              height: ResponsiveUtils.responsiveSpacing(context, 40),
            ),
          ),
        ],
      );

  // 平板布局
  Widget _buildTabletLayout(
    Color textPrimary,
    Color textSecondary,
    Color primaryColor,
    Color primaryLight,
    Color cardColor,
    bool isDarkMode,
  ) =>
      // 平板使用左右分栏布局，类似桌面但比例调整
      Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 1000),
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
          child: Row(
            children: [
              // 左侧装饰区域
              Expanded(
                flex: 4,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      AppConfig.appName,
                      style: TextStyle(
                        fontSize: 40,
                        fontWeight: FontWeight.bold,
                        color: primaryColor,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      AppLocalizationsSimple.of(context)
                              ?.intelligentNoteManagement ??
                          '智能笔记管理，\n让思考更有条理',
                      style: TextStyle(
                        fontSize: 20,
                        color: textSecondary,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 40),

              // 右侧登录区域
              Expanded(
                flex: 5,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildLoginForm(
                        cardColor: cardColor,
                        textPrimary: textPrimary,
                        textSecondary: textSecondary,
                        primaryColor: primaryColor,
                        primaryLight: primaryLight,
                        isDarkMode: isDarkMode,
                      ),
                      const SizedBox(height: 24),
                      _buildQuickActions(
                        textPrimary: textPrimary,
                        textSecondary: textSecondary,
                        primaryColor: primaryColor,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );

  // 桌面布局
  Widget _buildDesktopLayout(
    Color textPrimary,
    Color textSecondary,
    Color primaryColor,
    Color primaryLight,
    Color cardColor,
    bool isDarkMode,
  ) =>
      Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1000),
          child: Padding(
            padding: const EdgeInsets.all(48),
            child: Row(
              children: [
                // 左侧装饰区域
                Expanded(
                  flex: 5,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        AppConfig.appName,
                        style: TextStyle(
                          fontSize: 48,
                          fontWeight: FontWeight.bold,
                          color: primaryColor,
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        AppLocalizationsSimple.of(context)
                                ?.intelligentNoteManagement ??
                            '智能笔记管理，\n让思考更有条理',
                        style: TextStyle(
                          fontSize: 24,
                          color: textSecondary,
                          height: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 48),

                // 右侧登录区域
                Expanded(
                  flex: 4,
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildLoginForm(
                          cardColor: cardColor,
                          textPrimary: textPrimary,
                          textSecondary: textSecondary,
                          primaryColor: primaryColor,
                          primaryLight: primaryLight,
                          isDarkMode: isDarkMode,
                        ),
                        const SizedBox(height: 32),
                        _buildQuickActions(
                          textPrimary: textPrimary,
                          textSecondary: textSecondary,
                          primaryColor: primaryColor,
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

  // 🌟 背景装饰层
  Widget _buildBackgroundDecoration(
    bool isDarkMode,
    Color primaryColor,
    double screenHeight,
  ) =>
      AnimatedBuilder(
        animation: _floatingAnimation,
        builder: (context, child) => Stack(
          children: [
            // 渐变背景
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: isDarkMode
                      ? [
                          AppTheme.darkBackgroundColor,
                          AppTheme.darkSurfaceColor,
                          AppTheme.darkCardColor,
                        ]
                      : [
                          AppTheme.backgroundColor,
                          AppTheme.surfaceColor,
                          Colors.white,
                        ],
                ),
              ),
            ),

            // 浮动装饰圆圈
            Positioned(
              top: screenHeight * 0.15 + _floatingAnimation.value * 30,
              right: -50,
              child: Container(
                width: 200,
                height: 200,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      primaryColor.withValues(alpha: 0.15),
                      primaryColor.withValues(alpha: 0.05),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),

            // 左侧装饰
            Positioned(
              bottom: screenHeight * 0.3 - _floatingAnimation.value * 20,
              left: -100,
              child: Container(
                width: 250,
                height: 250,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      primaryColor.withValues(alpha: 0.1),
                      primaryColor.withValues(alpha: 0.03),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      );

  // 🎯 导航按钮
  Widget _buildNavButton({
    required IconData icon,
    required VoidCallback onTap,
    required bool isDarkMode,
    required Color cardColor,
    required Color textPrimary,
  }) =>
      Container(
        margin: const EdgeInsets.all(12),
        child: Material(
          color: cardColor.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: onTap,
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isDarkMode
                      ? Colors.white.withValues(alpha: 0.1)
                      : Colors.black.withValues(alpha: 0.05),
                ),
              ),
              child: Icon(
                icon,
                color: textPrimary,
                size: 20,
              ),
            ),
          ),
        ),
      );

  // 🚀 英雄区域
  Widget _buildHeroSection({
    required Color textPrimary,
    required Color textSecondary,
    required Color primaryColor,
    required bool isDarkMode,
  }) {
    // 根据屏幕类型判断是否显示英雄区域
    if (ResponsiveUtils.isDesktop(context)) {
      return const SizedBox.shrink(); // 桌面版本不显示英雄区域
    }

    return FadeTransition(
      opacity: _fadeAnimation,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, -0.3),
          end: Offset.zero,
        ).animate(_fadeAnimation),
        child: Container(
          padding: ResponsiveUtils.responsivePadding(
            context,
            horizontal: 32,
            vertical: 60,
          ),
          child: Column(
            children: [
              // Logo区域
              ScaleTransition(
                scale: _scaleAnimation,
                child: Container(
                  width: ResponsiveUtils.responsive<double>(
                    context,
                    mobile: 80,
                    tablet: 100,
                  ),
                  height: ResponsiveUtils.responsive<double>(
                    context,
                    mobile: 80,
                    tablet: 100,
                  ),
                  margin: ResponsiveUtils.responsivePadding(
                    context,
                    bottom: 32,
                  ),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        primaryColor,
                        AppTheme.primaryLightColor,
                      ],
                    ),
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: [
                      BoxShadow(
                        color: primaryColor.withValues(alpha: 0.3),
                        blurRadius: 20,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: Image.asset(
                      Theme.of(context).brightness == Brightness.dark
                          ? 'assets/images/black2logo.png'
                          : 'assets/images/logo.png',
                      width: ResponsiveUtils.responsiveIconSize(context, 40),
                      height: ResponsiveUtils.responsiveIconSize(context, 40),
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
              ),

              // 主标题
              Text(
                AppLocalizationsSimple.of(context)?.welcomeBack ?? '欢迎回来',
                style: TextStyle(
                  fontSize: ResponsiveUtils.responsiveFontSize(context, 36),
                  fontWeight: FontWeight.w800,
                  color: textPrimary,
                  height: 1.2,
                  letterSpacing: -0.5,
                ),
              ),

              SizedBox(height: ResponsiveUtils.responsiveSpacing(context, 12)),

              // 副标题
              Text(
                AppLocalizationsSimple.of(context)?.continueCreativeJourney ??
                    '继续您的创作之旅',
                style: TextStyle(
                  fontSize: ResponsiveUtils.responsiveFontSize(context, 16),
                  color: textSecondary,
                  height: 1.5,
                  letterSpacing: 0.1,
                ),
              ),

            ],
          ),
        ),
      ),
    );
  }

  // 📝 登录表单
  Widget _buildLoginForm({
    required Color cardColor,
    required Color textPrimary,
    required Color textSecondary,
    required Color primaryColor,
    required Color primaryLight,
    required bool isDarkMode,
  }) =>
      SlideTransition(
        position: _slideAnimation,
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: Container(
            margin: ResponsiveUtils.responsivePadding(context, horizontal: 24),
            decoration: BoxDecoration(
              color: cardColor.withValues(alpha: 0.95),
              borderRadius: BorderRadius.circular(
                ResponsiveUtils.responsive<double>(
                  context,
                  mobile: 24,
                  tablet: 28,
                  desktop: 32,
                ),
              ),
              boxShadow: [
                BoxShadow(
                  color: isDarkMode
                      ? Colors.black.withValues(alpha: 0.3)
                      : Colors.black.withValues(alpha: 0.08),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
              border: Border.all(
                color: isDarkMode
                    ? Colors.white.withValues(alpha: 0.1)
                    : Colors.black.withValues(alpha: 0.05),
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                child: Container(
                  padding: const EdgeInsets.all(32),
                  decoration: BoxDecoration(
                    color: cardColor.withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 服务器选择
                        _buildServerSection(
                          textPrimary,
                          textSecondary,
                          primaryColor,
                          isDarkMode,
                        ),

                        const SizedBox(height: 24),

                        // 用户名
                        _buildTextField(
                          controller: _usernameController,
                          label: AppLocalizationsSimple.of(context)?.username ??
                              '用户名',
                          hint: AppLocalizationsSimple.of(context)?.username ??
                              '请输入您的用户名',
                          icon: Icons.person_outline,
                          textPrimary: textPrimary,
                          textSecondary: textSecondary,
                          primaryColor: primaryColor,
                          isDarkMode: isDarkMode,
                          validator: (value) {
                            final l10n = AppLocalizationsSimple.of(context);
                            if (value == null || value.trim().isEmpty) {
                              return l10n?.usernameRequired ??
                                  '请填写用户名，不能为空';
                            }
                            if (value.trim().length < 2) {
                              return l10n?.usernameTooShort ??
                                  '用户名太短了，至少需要 2 个字符';
                            }
                            if (value.contains(' ')) {
                              return l10n?.usernameNoSpaces ??
                                  '用户名里不能有空格，请去掉空格再试';
                            }
                            return null;
                          },
                        ),

                        const SizedBox(height: 20),

                        // 密码
                        _buildTextField(
                          controller: _passwordController,
                          label: AppLocalizationsSimple.of(context)?.password ??
                              '密码',
                          hint: AppLocalizationsSimple.of(context)
                                  ?.pleaseEnterPassword ??
                              '请输入您的密码',
                          icon: Icons.lock_outline,
                          textPrimary: textPrimary,
                          textSecondary: textSecondary,
                          primaryColor: primaryColor,
                          isDarkMode: isDarkMode,
                          obscureText: _obscurePassword,
                          suffixIcon: IconButton(
                            icon: Icon(
                              _obscurePassword
                                  ? Icons.visibility_off
                                  : Icons.visibility,
                              color: textSecondary,
                              size: 20,
                            ),
                            onPressed: () {
                              setState(() {
                                _obscurePassword = !_obscurePassword;
                              });
                            },
                          ),
                          validator: (value) {
                            final l10n = AppLocalizationsSimple.of(context);
                            if (value == null || value.isEmpty) {
                              return l10n?.passwordRequired ?? '请填写密码，不能为空';
                            }
                            if (value.length < 6) {
                              return l10n?.passwordTooShort ?? '密码太短了，至少需要 6 位';
                            }
                            return null;
                          },
                        ),

                        const SizedBox(height: 20),

                        // 记住密码开关
                        _buildRememberSwitch(
                          textPrimary,
                          textSecondary,
                          primaryColor,
                        ),

                        const SizedBox(height: 32),

                        // 登录按钮
                        _buildLoginButton(
                          primaryColor,
                          primaryLight,
                          isDarkMode,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

  // 🎯 大厂标准：服务器地址输入
  Widget _buildServerSection(
    Color textPrimary,
    Color textSecondary,
    Color primaryColor,
    bool isDarkMode,
  ) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          Text(
            AppLocalizationsSimple.of(context)?.serverAddress ?? '服务器地址',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: _serverController,
            style: TextStyle(
              fontSize: 16,
              color: textPrimary,
              fontWeight: FontWeight.w500,
            ),
            keyboardType: TextInputType.url,
            onChanged: _onCustomServerUrlChanged,
            validator: (value) {
              final l10n = AppLocalizationsSimple.of(context);
              if (value == null || value.trim().isEmpty) {
                return l10n?.serverUrlRequired ??
                    '请填写服务器地址，例如：https://demo.memos.app';
              }
              if (!value.startsWith('http://') &&
                  !value.startsWith('https://')) {
                return l10n?.serverUrlInvalid ??
                    '地址格式不对，需要以 https:// 开头\n'
                        '示例：https://demo.memos.app';
              }
              return null;
            },
            decoration: InputDecoration(
              hintText: 'https://your-memos-server.com',
              hintStyle: TextStyle(
                color: textSecondary,
                fontSize: 15,
                fontWeight: FontWeight.normal,
              ),
              prefixIcon: Container(
                margin: const EdgeInsets.all(12),
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  color: primaryColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.cloud_outlined,
                  size: 18,
                  color: primaryColor,
                ),
              ),
              filled: true,
              fillColor: isDarkMode
                  ? Colors.white.withValues(alpha: 0.03)
                  : Colors.black.withValues(alpha: 0.02),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: isDarkMode
                      ? Colors.white.withValues(alpha: 0.1)
                      : Colors.black.withValues(alpha: 0.08),
                ),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: isDarkMode
                      ? Colors.white.withValues(alpha: 0.1)
                      : Colors.black.withValues(alpha: 0.08),
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: primaryColor,
                  width: 2,
                ),
              ),
              errorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(
                  color: Colors.red,
                  width: 1.5,
                ),
              ),
              focusedErrorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(
                  color: Colors.red,
                  width: 2,
                ),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 20,
                vertical: 16,
              ),
            ),
          ),
        ],
      );

  // 📝 输入框组件
  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    required Color textPrimary,
    required Color textSecondary,
    required Color primaryColor,
    required bool isDarkMode,
    bool obscureText = false,
    Widget? suffixIcon,
    String? Function(String?)? validator,
  }) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: controller,
            validator: validator,
            obscureText: obscureText,
            style: TextStyle(
              fontSize: 16,
              color: textPrimary,
              fontWeight: FontWeight.w500,
            ),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: TextStyle(
                color: textSecondary,
                fontSize: 15,
                fontWeight: FontWeight.normal,
              ),
              prefixIcon: Container(
                margin: const EdgeInsets.all(12),
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  color: primaryColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  icon,
                  color: primaryColor,
                  size: 16,
                ),
              ),
              suffixIcon: suffixIcon,
              filled: true,
              fillColor: isDarkMode
                  ? Colors.white.withValues(alpha: 0.03)
                  : Colors.black.withValues(alpha: 0.02),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(
                  color: isDarkMode
                      ? Colors.white.withValues(alpha: 0.1)
                      : Colors.black.withValues(alpha: 0.08),
                ),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(
                  color: isDarkMode
                      ? Colors.white.withValues(alpha: 0.1)
                      : Colors.black.withValues(alpha: 0.08),
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(color: primaryColor, width: 2),
              ),
              errorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: Colors.red, width: 2),
              ),
              focusedErrorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: Colors.red, width: 2),
              ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
            ),
          ),
        ],
      );

  // 💡 记住密码开关
  Widget _buildRememberSwitch(
    Color textPrimary,
    Color textSecondary,
    Color primaryColor,
  ) =>
      Row(
        children: [
          Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              color: primaryColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(
              Icons.save_alt,
              color: primaryColor,
              size: 12,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppLocalizationsSimple.of(context)?.rememberPassword ??
                      '记住密码',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  AppLocalizationsSimple.of(context)?.saveAccountLocally ??
                      '保存账号和密码到本地',
                  style: TextStyle(
                    fontSize: 12,
                    color: textSecondary,
                  ),
                ),
              ],
            ),
          ),
          Switch.adaptive(
            value: _rememberLogin,
            activeThumbColor: primaryColor,
            onChanged: (value) {
              setState(() {
                _rememberLogin = value;
              });
            },
          ),
        ],
      );

  // 🎯 登录按钮
  Widget _buildLoginButton(
    Color primaryColor,
    Color primaryLight,
    bool isDarkMode,
  ) =>
      Container(
        width: double.infinity,
        height: 56,
        decoration: BoxDecoration(
          gradient: _isLoading
              ? null
              : LinearGradient(
                  colors: [
                    primaryColor,
                    primaryLight,
                  ],
                ),
          color: _isLoading
              ? (isDarkMode ? Colors.grey[700] : Colors.grey[300])
              : null,
          borderRadius: BorderRadius.circular(16),
          boxShadow: _isLoading
              ? []
              : [
                  BoxShadow(
                    color: primaryColor.withValues(alpha: 0.3),
                    blurRadius: 20,
                    offset: const Offset(0, 8),
                  ),
                ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: _isLoading ? null : _login,
            child: Container(
              alignment: Alignment.center,
              child: _isLoading
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Text(
                      AppLocalizationsSimple.of(context)?.login ?? '登录',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.5,
                      ),
                    ),
            ),
          ),
        ),
      );

  // 🔗 快速操作
  Widget _buildQuickActions({
    required Color textPrimary,
    required Color textSecondary,
    required Color primaryColor,
  }) =>
      Container(
        margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        child: Column(
          children: [
            Text(
              AppLocalizationsSimple.of(context)?.noAccount ?? '还没有账号？',
              style: TextStyle(
                fontSize: 14,
                color: textSecondary,
              ),
            ),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              height: 48,
              decoration: BoxDecoration(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: primaryColor,
                  width: 1.5,
                ),
              ),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => context.push('/register'),
                  child: Container(
                    alignment: Alignment.center,
                    child: Text(
                      AppLocalizationsSimple.of(context)?.registerNow ?? '立即注册',
                      style: TextStyle(
                        color: primaryColor,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            ),

            const SizedBox(height: 32),

            // 版本兼容性详细说明
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: primaryColor.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: primaryColor.withValues(alpha: 0.15),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.support,
                        size: 18,
                        color: primaryColor,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        AppLocalizationsSimple.of(context)
                                ?.versionCompatibility ??
                            '版本兼容性说明',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: primaryColor,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    AppLocalizationsSimple.of(context)?.loginServerTips ??
                        '✅ 支持常见 Memos 版本，并按检测结果选择接口\n'
                            '🔒 建议使用 HTTPS，登录凭证会保存在系统安全存储中\n'
                            '📱 登录并同步成功后，可在多个设备查看笔记',
                    style: TextStyle(
                      fontSize: 12,
                      color: textSecondary,
                      height: 1.6,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    AppLocalizationsSimple.of(context)?.loginHelpHint ??
                        '遇到问题？点右上角 ? 查看常见问题解答',
                    style: TextStyle(
                      fontSize: 11,
                      color: textSecondary.withValues(alpha: 0.8),
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );

  // 🆘 帮助对话框 - 常见问题
  void _showHelpDialog() {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final dialogColor =
        isDarkMode ? AppTheme.darkCardColor : AppTheme.surfaceColor;
    final textPrimary =
        isDarkMode ? AppTheme.darkTextPrimaryColor : AppTheme.textPrimaryColor;
    final textSecondary = isDarkMode
        ? AppTheme.darkTextSecondaryColor
        : AppTheme.textSecondaryColor;
    const primaryColor = AppTheme.primaryColor;
    const accentColor = AppTheme.accentColor;

    showDialog(
      context: context,
      builder: (context) => BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Dialog(
          backgroundColor: Colors.transparent,
          child: Container(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.8,
              maxWidth:
                  ResponsiveUtils.isMobile(context) ? double.infinity : 600,
            ),
            decoration: BoxDecoration(
              color: dialogColor,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: isDarkMode
                    ? Colors.white.withValues(alpha: 0.1)
                    : Colors.black.withValues(alpha: 0.05),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDarkMode ? 0.4 : 0.1),
                  blurRadius: 30,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 🎨 对话框头部
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        primaryColor.withValues(alpha: 0.1),
                        accentColor.withValues(alpha: 0.05),
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(24),
                      topRight: Radius.circular(24),
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: primaryColor.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: const Icon(
                          Icons.help_outline_rounded,
                          color: primaryColor,
                          size: 26,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              AppLocalizationsSimple.of(context)?.faq ?? '常见问题',
                              style: TextStyle(
                                color: textPrimary,
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 0.5,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              AppLocalizationsSimple.of(context)
                                      ?.answerYourQuestions ??
                                  '为您解答使用中的疑问',
                              style: TextStyle(
                                color: textSecondary,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: Icon(
                          Icons.close_rounded,
                          color: textSecondary,
                        ),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                ),

                // 📋 问题列表
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      children: [
                        // ── 最常见问题排在最前 ──────────────────────────
                        _buildFAQItem(
                          icon: Icons.error_outline_rounded,
                          iconColor: Colors.orange,
                          question: '登录失败了，怎么办？',
                          answer: '请按以下步骤逐一排查：\n\n'
                              '① 检查用户名和密码是否正确（注意大小写）\n'
                              '② 确认服务器地址填写正确，格式如 https://demo.memos.app\n'
                              '③ 检查手机网络是否正常，可以尝试切换 Wi-Fi / 移动网络\n'
                              '④ 如果是自建服务器，确认服务器正在运行\n\n'
                              '以上都试过还是不行？请点底部「联系客服」',
                          isDarkMode: isDarkMode,
                          textPrimary: textPrimary,
                          textSecondary: textSecondary,
                        ),
                        const SizedBox(height: 16),
                        _buildFAQItem(
                          icon: Icons.dns_outlined,
                          iconColor: accentColor,
                          question: '服务器地址填什么？',
                          answer: '请填写你的 Memos 服务器完整地址，格式如：\nhttps://你的域名.com\n\n'
                              '如果服务器使用非标准端口，请一并写上，例如：\nhttps://你的域名.com:5230\n\n'
                              '不确定地址时，请联系你的服务器管理员获取。',
                          isDarkMode: isDarkMode,
                          textPrimary: textPrimary,
                          textSecondary: textSecondary,
                        ),
                        const SizedBox(height: 16),
                        _buildFAQItem(
                          icon: Icons.person_add_outlined,
                          iconColor: primaryColor,
                          question: '还没有账号，怎么注册？',
                          answer: '点击登录页面下方的「立即注册」按钮，填写用户名和密码即可完成注册。\n\n'
                              '注意：用户名注册后不能更改，请提前想好。\n\n'
                              '注册后即可使用该账号登录你的 Memos 服务器。',
                          isDarkMode: isDarkMode,
                          textPrimary: textPrimary,
                          textSecondary: textSecondary,
                        ),
                        const SizedBox(height: 16),
                        _buildFAQItem(
                          icon: Icons.lock_reset_outlined,
                          iconColor: Colors.red.shade400,
                          question: '忘记密码怎么找回？',
                          answer: '由于 Memos 目前不支持通过邮件找回密码，请按以下方式处理：\n\n'
                              '• 请联系你的服务器管理员，由管理员在后台重置密码\n\n'
                              '建议平时开启「记住密码」功能，下次打开 App 会自动登录，不用重新输入。',
                          isDarkMode: isDarkMode,
                          textPrimary: textPrimary,
                          textSecondary: textSecondary,
                        ),
                        const SizedBox(height: 16),
                        _buildFAQItem(
                          icon: Icons.login_outlined,
                          iconColor: primaryColor,
                          question: '什么是「记住密码」？',
                          answer: '开启后，账号和密码会保存在系统安全存储中。\n\n'
                              '下次打开 App 时会自动登录，不用每次手动输入。\n\n'
                              '如果您不想保存，可以关掉这个开关，退出登录后密码不会被记住。',
                          isDarkMode: isDarkMode,
                          textPrimary: textPrimary,
                          textSecondary: textSecondary,
                        ),
                        const SizedBox(height: 16),
                        _buildFAQItem(
                          icon: Icons.cloud_sync_outlined,
                          iconColor: primaryColor,
                          question: '笔记会自动保存吗？',
                          answer: '笔记会先保存在本机。登录并同步成功后，会上传到你连接的服务器。\n\n'
                              '离线时可以继续记录，恢复网络后再同步。同步是否成功取决于网络和服务器状态。\n\n'
                              '重要内容建议定期使用备份功能额外保存。',
                          isDarkMode: isDarkMode,
                          textPrimary: textPrimary,
                          textSecondary: textSecondary,
                        ),
                        const SizedBox(height: 16),
                        _buildFAQItem(
                          icon: Icons.edit_note_outlined,
                          iconColor: accentColor,
                          question: '这个 App 能做什么？',
                          answer: 'InkPaper 是一款笔记 App，主要功能包括：\n\n'
                              '📝 随手记录想法，支持文字、图片\n'
                              '#️⃣ 用标签整理笔记，快速分类查找\n'
                              '🔍 全文搜索，按关键词查找内容\n'
                              '📅 热力图，直观看到每天的记录情况\n'
                              '🔔 设置提醒，减少遗漏\n'
                              '📖 支持 Markdown 格式排版（可选）',
                          isDarkMode: isDarkMode,
                          textPrimary: textPrimary,
                          textSecondary: textSecondary,
                        ),
                        const SizedBox(height: 16),
                        _buildFAQItem(
                          icon: Icons.security_outlined,
                          iconColor: primaryColor,
                          question: '我的数据安全吗？',
                          answer: 'InkPaper 会尽量使用系统和服务器提供的安全能力：\n\n'
                              '🔐 建议使用 HTTPS 服务器地址传输数据\n'
                              '📱 密码在本地安全存储，不会明文保存\n'
                              '🏠 使用自建服务器时，远端数据由你的服务器保存和管理\n\n'
                              '建议：重要笔记通过「备份」功能额外保存一份。',
                          isDarkMode: isDarkMode,
                          textPrimary: textPrimary,
                          textSecondary: textSecondary,
                        ),
                      ],
                    ),
                  ),
                ),

                // 🎯 底部操作区
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    border: Border(
                      top: BorderSide(
                        color: isDarkMode
                            ? Colors.white.withValues(alpha: 0.1)
                            : Colors.black.withValues(alpha: 0.05),
                      ),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.support_agent_rounded,
                        color: primaryColor,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          AppLocalizationsSimple.of(context)
                                  ?.loginMoreQuestions ??
                              '还有其他问题？',
                          style: TextStyle(
                            color: textSecondary,
                            fontSize: 14,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () {
                          Navigator.of(context).pop();
                          // 可以跳转到帮助中心或联系客服
                          context.push('/help');
                        },
                        style: TextButton.styleFrom(
                          foregroundColor: primaryColor,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                        ),
                        child: Text(
                          AppLocalizationsSimple.of(context)
                                  ?.loginViewHelpCenter ??
                              '查看帮助中心',
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // 🎨 FAQ 条目组件
  Widget _buildFAQItem({
    required IconData icon,
    required Color iconColor,
    required String question,
    required String answer,
    required bool isDarkMode,
    required Color textPrimary,
    required Color textSecondary,
  }) =>
      DecoratedBox(
        decoration: BoxDecoration(
          color: isDarkMode
              ? Colors.white.withValues(alpha: 0.03)
              : Colors.black.withValues(alpha: 0.02),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isDarkMode
                ? Colors.white.withValues(alpha: 0.08)
                : Colors.black.withValues(alpha: 0.05),
          ),
        ),
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            leading: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                icon,
                color: iconColor,
                size: 20,
              ),
            ),
            title: Text(
              question,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: textPrimary,
              ),
            ),
            iconColor: iconColor,
            collapsedIconColor: textSecondary,
            tilePadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: isDarkMode
                      ? Colors.white.withValues(alpha: 0.03)
                      : Colors.black.withValues(alpha: 0.02),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      margin: const EdgeInsets.only(top: 2),
                      width: 4,
                      height: 4,
                      decoration: BoxDecoration(
                        color: iconColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        answer,
                        style: TextStyle(
                          fontSize: 14,
                          color: textSecondary,
                          height: 1.6,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
}
