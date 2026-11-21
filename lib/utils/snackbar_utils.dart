import 'dart:async';

import 'package:flutter/material.dart';
import 'package:inkpaper/themes/app_theme.dart';
import 'package:liquid_glass_renderer/liquid_glass_renderer.dart';

class SnackBarUtils {
  /// 所有提示条共用的圆角：撤销条原本 26、普通条 25，差 1dp 也能看出边缘不齐。
  static const double _toastRadius = 26;

  /// [duration] 仅对有阅读价值的多行结果（备份/恢复统计等）需要放长，
  /// 普通一句话提示保持默认 1.5 秒。
  static void showSuccess(
    BuildContext context,
    String message, {
    Duration duration = const Duration(milliseconds: 1500),
  }) {
    _showCustomSnackBar(
      context,
      message,
      backgroundColor: AppTheme.successColor,
      icon: Icons.check,
      duration: duration,
    );
  }

  static void showError(
    BuildContext context,
    String message, {
    VoidCallback? onRetry,
    Duration duration = const Duration(milliseconds: 1500),
    int maxLines = 2,
  }) {
    if (onRetry != null) {
      _showErrorWithRetry(context, message, onRetry);
    } else {
      _showCustomSnackBar(
        context,
        message,
        backgroundColor: Colors.red.shade600,
        icon: Icons.close,
        duration: duration,
        maxLines: maxLines,
      );
    }
  }

  static void showInfo(BuildContext context, String message) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    _showCustomSnackBar(
      context,
      message,
      backgroundColor:
          isDarkMode ? AppTheme.primaryLightColor : AppTheme.primaryColor,
      icon: Icons.info,
    );
  }

  static void showWarning(
    BuildContext context,
    String message, {
    Duration duration = const Duration(milliseconds: 1500),
  }) {
    _showCustomSnackBar(
      context,
      message,
      backgroundColor: Colors.orange.shade600,
      icon: Icons.warning,
      duration: duration,
    );
  }

  /// 原生提示条：Material 默认那条，贴屏幕底边、从下往上滑一下。
  ///
  /// 玻璃胶囊是给「带撤销/重试的操作」用的——里面有按钮，值得一块浮起的面板。
  /// 删除确认这类「动作已经做完，只需一句话交代结果」的反馈用原生条更轻，
  /// 不再需要折射、也不再需要一块常驻的面板。
  static void showNative(
    BuildContext context,
    String message, {
    IconData? icon,
    Color? backgroundColor,
    Duration duration = const Duration(seconds: 2),
  }) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) {
      return;
    }
    showNativeOn(
      messenger,
      message,
      icon: icon,
      backgroundColor: backgroundColor,
      duration: duration,
    );
  }

  /// 同上，但直接拿 [ScaffoldMessengerState]。
  ///
  /// 行被摘掉后原 context 会失效，删除这类「先摘行、再提示」的调用方
  /// 要提前把 messenger 抓在手里。
  static void showNativeOn(
    ScaffoldMessengerState messenger,
    String message, {
    IconData? icon,
    Color? backgroundColor,
    Duration duration = const Duration(seconds: 2),
  }) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Row(
            children: [
              if (icon != null) ...[
                Icon(icon, color: Colors.white, size: 18),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  message,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    height: 1.35,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          // 主题里默认是 floating，这里显式贴底：要的就是原生那条
          behavior: SnackBarBehavior.fixed,
          backgroundColor: backgroundColor,
          duration: duration,
        ),
      );
  }

  /// 显示网络错误提示，会自动根据错误类型提供友好的提示信息
  static void showNetworkError(
    BuildContext context,
    Object? error, {
    VoidCallback? onRetry,
  }) {
    var userFriendlyMessage = '网络出了点问题，请检查网络连接后重试';

    if (error != null) {
      final errorString = error.toString().toLowerCase();

      if (errorString.contains('socketexception') ||
          errorString.contains('networkexception')) {
        userFriendlyMessage = '网络连接失败，请检查手机网络或切换网络后重试';
      } else if (errorString.contains('timeoutexception')) {
        userFriendlyMessage = '连接超时了，请检查网络是否正常，稍后再试';
      } else if (errorString.contains('formatexception')) {
        userFriendlyMessage = '服务器地址可能不对，请确认后重试';
      } else if (errorString.contains('handshakeexception') ||
          errorString.contains('tlsexception')) {
        userFriendlyMessage = '连接安全验证失败，请检查服务器地址是否以 https:// 开头';
      } else if (errorString.contains('unauthorized') ||
          errorString.contains('401')) {
        userFriendlyMessage = '登录信息已过期，请重新登录';
      } else if (errorString.contains('forbidden') ||
          errorString.contains('403')) {
        userFriendlyMessage = '没有访问权限，请联系管理员';
      } else if (errorString.contains('notfound') ||
          errorString.contains('404')) {
        userFriendlyMessage = '找不到服务器，请检查服务器地址是否正确';
      } else if (errorString.contains('500')) {
        userFriendlyMessage = '服务器出了点问题，请稍后再试';
      } else if (errorString.contains('service unavailable') ||
          errorString.contains('503')) {
        userFriendlyMessage = '服务器正在维护中，请稍后再试';
      }
    }

    showError(context, userFriendlyMessage, onRetry: onRetry);
  }

  static void _showErrorWithRetry(
    BuildContext context,
    String message,
    VoidCallback onRetry,
  ) {
    final messenger = ScaffoldMessenger.of(context)..clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(
              Icons.error_outline,
              color: Colors.white,
              size: 20,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        backgroundColor: Colors.red.shade600,
        behavior: SnackBarBehavior.floating,
        margin: toastMargin(context, compact: false),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
        action: SnackBarAction(
          label: '重试',
          textColor: Colors.white,
          onPressed: () {
            ScaffoldMessenger.of(context).hideCurrentSnackBar();
            onRetry();
          },
        ),
      ),
    );
  }

  /// 带操作的提示（删除笔记后的「撤销」）：玻璃胶囊。
  ///
  /// 视觉与首页底部输入条是同一套 `liquid_glass_renderer` 材质。
  /// SnackBar 自身背景透明、elevation 归零，玻璃由 content 里的
  /// [LiquidGlass] 画出来 —— 这样它浮在列表上时能真的折射下面的内容，
  /// 而不是一块纯色底。
  ///
  /// 动画不能交给 SnackBar 自带的淡入淡出：玻璃是 BackdropFilter 系
  /// 特效，不吃祖先 Opacity（文字会淡、玻璃本体瞬间满强度），直接用
  /// 会突兀地闪现闪没。入场/退场都由 [_GlassActionToast] 自己驱动，
  /// 动画播完我们再手动收 SnackBar。
  static void showAction(
    BuildContext context,
    String message, {
    required String actionLabel,
    required VoidCallback onAction,
    IconData? icon,
    Duration duration = const Duration(milliseconds: 2800),
  }) {
    final messenger = ScaffoldMessenger.of(context)..clearSnackBars();
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    // SnackBar 自己的隐藏计时只做兜底：留出比入场+退场更长的时间，
    // 正常路径都走下面的主动收回（带动画）。
    final showDuration = duration + const Duration(milliseconds: 600);

    final toastKey = GlobalKey<_GlassActionToastState>();
    var settled = false;

    Future<void> dismissAnimated() async {
      await toastKey.currentState?.animateOut();
      messenger.hideCurrentSnackBar(reason: SnackBarClosedReason.timeout);
    }

    void settle() {
      if (settled) {
        return;
      }
      settled = true;
      unawaited(dismissAnimated());
    }

    messenger.showSnackBar(
      SnackBar(
        content: _GlassActionToast(
          key: toastKey,
          isDarkMode: isDarkMode,
          message: message,
          icon: icon,
          actionLabel: actionLabel,
          // 动作立刻执行、不等退场动画，避免撤销手感发涩
          onActionPressed: () {
            settle();
            onAction();
          },
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        behavior: SnackBarBehavior.floating,
        margin: toastMargin(context),
        padding: EdgeInsets.zero,
        duration: showDuration,
        persist: false,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(_toastRadius)),
        ),
      ),
    );

    unawaited(
      Future<void>.delayed(duration, () {
        if (!context.mounted) {
          return;
        }
        settle();
      }),
    );
  }

  static void _showCustomSnackBar(
    BuildContext context,
    String message, {
    required Color backgroundColor,
    required IconData icon,
    Duration duration = const Duration(milliseconds: 1500),
    int maxLines = 2,
  }) {
    final messenger = ScaffoldMessenger.of(context)..clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        content: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: Colors.white, size: 18),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  height: 1.35,
                ),
                maxLines: maxLines,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        backgroundColor: backgroundColor,
        behavior: SnackBarBehavior.floating,
        margin: toastMargin(context),
        duration: duration,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(_toastRadius)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      ),
    );
  }

  /// 全项目提示条共用的一套几何。
  ///
  /// 首页有底部输入条（bottomNavigationBar），Scaffold 已经把 floating
  /// SnackBar 垫在它上方，这时左右各留 12、底部 10 —— 与那条玻璃输入条
  /// 同宽同基线，撤销条不会比输入条窄一截（之前撤销条走 24，比输入条窄 24）。
  /// 没有底部导航的页面按屏宽断点留边，底部让开手势条。
  static EdgeInsets toastMargin(BuildContext context, {bool compact = true}) {
    final mediaQuery = MediaQuery.of(context);
    final width = mediaQuery.size.width;
    final scaffold = Scaffold.maybeOf(context);
    final hasBottomBar = scaffold?.widget.bottomNavigationBar != null ||
        (scaffold?.widget.persistentFooterButtons?.isNotEmpty ?? false);
    final horizontal = hasBottomBar
        ? 12.0
        : width < 360
            ? 16.0
            : width < 600
                ? 24.0
                : (width - 420).clamp(24.0, double.infinity) / 2;
    final bottom = hasBottomBar
        ? 10.0
        : mediaQuery.padding.bottom + (compact ? 28.0 : 18.0);
    return EdgeInsets.fromLTRB(horizontal, 0, horizontal, bottom);
  }
}

/// 撤销提示的玻璃胶囊本体，自带入场/退场动画。
///
/// 玻璃是 BackdropFilter 系特效，不吃祖先 Opacity——SnackBar 自带的
/// 淡入淡出对玻璃本体无效。所以折射/着色这些玻璃参数自己从零渐入，
/// 文字按钮等内容再单独淡入，加上自下而上的位移，凑成完整的「浮起」。
class _GlassActionToast extends StatefulWidget {
  const _GlassActionToast({
    required this.isDarkMode,
    required this.message,
    required this.icon,
    required this.actionLabel,
    required this.onActionPressed,
    super.key,
  });

  final bool isDarkMode;
  final String message;
  final IconData? icon;
  final String actionLabel;
  final VoidCallback onActionPressed;

  @override
  State<_GlassActionToast> createState() => _GlassActionToastState();
}

class _GlassActionToastState extends State<_GlassActionToast>
    with SingleTickerProviderStateMixin {
  static const _toastTransition = Duration(milliseconds: 280);

  late final AnimationController _controller =
      AnimationController(vsync: this, duration: _toastTransition)..forward();

  bool _dismissing = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 退场：反向播放入场动画，完成后外部再收起 SnackBar。
  Future<void> animateOut() async {
    if (_dismissing) {
      return;
    }
    _dismissing = true;
    await _controller.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final isDarkMode = widget.isDarkMode;
    final brightness = isDarkMode ? Brightness.dark : Brightness.light;
    // 玻璃上的前景色：浅色用深灰、深色用白，与底部输入条同一口径
    final foreground = isDarkMode ? Colors.white : const Color(0xFF2E2E2E);
    final baseShadow =
        isDarkMode ? const Color(0x80000000) : const Color(0x26000000);
    final baseSettings = LiquidGlassSettings.ios27Regular(
      brightness: brightness,
      tintAmount: 0.35,
    );
    // 与首页底部输入条同一个圆角，视觉上才是同一颗胶囊
    const shapeRadius = 26.0;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = CurvedAnimation(
          parent: _controller,
          curve: Curves.easeOutCubic,
        ).value;
        return Transform.translate(
          // 入场自下而上浮起 20px，退场反向沉回去
          offset: Offset(0, 20 * (1 - t)),
          child: LiquidGlassLayer(
            // 玻璃参数随 t 渐入：t=0 时折射/着色全无，
            // 补上 BackdropFilter 不吃 Opacity 的那部分过渡。
            settings: baseSettings.copyWith(
              tintAmount: 0.35 * t,
              refractionHeight: 14 * t,
              refractionAmount: 40 * t,
            ),
            defaultAppearance:
                LiquidGlassAppearance.ios27Regular(brightness: brightness),
            child: LiquidGlass(
              shape: const LiquidRoundedSuperellipse(borderRadius: shapeRadius),
              shadows: [
                BoxShadow(
                  color: baseShadow.withAlpha(
                    (baseShadow.a * 255.0).round().clamp(0, 255),
                  ),
                  blurRadius: 20,
                  offset: const Offset(0, 6),
                ),
              ],
              child: Opacity(
                opacity: t,
                child: Material(
                  color: Colors.transparent,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
                    child: Row(
                      children: [
                        if (widget.icon != null) ...[
                          Icon(widget.icon, color: foreground, size: 20),
                          const SizedBox(width: 10),
                        ],
                        Expanded(
                          child: Text(
                            widget.message,
                            style: TextStyle(
                              color: foreground,
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              height: 1.35,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        TextButton(
                          onPressed: widget.onActionPressed,
                          style: TextButton.styleFrom(
                            foregroundColor: isDarkMode
                                ? AppTheme.primaryLightColor
                                : AppTheme.primaryColor,
                            minimumSize: const Size(0, 40),
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            textStyle: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          child: Text(widget.actionLabel),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
