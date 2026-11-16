import 'dart:async';

import 'package:flutter/material.dart';
import 'package:inkpaper/themes/app_theme.dart';
import 'package:liquid_glass_renderer/liquid_glass_renderer.dart';

class SnackBarUtils {
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
        margin: _floatingMargin(context, compact: false),
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
    final brightness = isDarkMode ? Brightness.dark : Brightness.light;
    // 玻璃上的前景色：浅色用深灰、深色用白，与底部输入条同一口径
    final foreground = isDarkMode ? Colors.white : const Color(0xFF2E2E2E);
    // 与首页底部输入条同一个圆角，视觉上才是同一颗胶囊
    const shapeRadius = 26.0;

    messenger.showSnackBar(
      SnackBar(
        content: LiquidGlassLayer(
          // 与首页输入条一致：58dp 高太陡，倒角收到 14/40，
          // tintAmount 0.35 兼顾通透与文字可读性。
          settings: LiquidGlassSettings.ios27Regular(
            brightness: brightness,
            tintAmount: 0.35,
          ).copyWith(refractionHeight: 14, refractionAmount: 40),
          defaultAppearance:
              LiquidGlassAppearance.ios27Regular(brightness: brightness),
          child: LiquidGlass(
            shape: const LiquidRoundedSuperellipse(borderRadius: shapeRadius),
            shadows: [
              BoxShadow(
                color: isDarkMode
                    ? const Color(0x80000000)
                    : const Color(0x26000000),
                blurRadius: 20,
                offset: const Offset(0, 6),
              ),
            ],
            child: Material(
              color: Colors.transparent,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
                child: Row(
                  children: [
                    if (icon != null) ...[
                      Icon(icon, color: foreground, size: 20),
                      const SizedBox(width: 10),
                    ],
                    Expanded(
                      child: Text(
                        message,
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
                      onPressed: () {
                        // 先收起提示再执行，避免连点两次「撤销」
                        messenger.hideCurrentSnackBar();
                        onAction();
                      },
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
                      child: Text(actionLabel),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        behavior: SnackBarBehavior.floating,
        margin: _floatingMargin(context, compact: false),
        padding: EdgeInsets.zero,
        duration: duration,
        persist: false,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(shapeRadius)),
        ),
      ),
    );

    unawaited(
      Future<void>.delayed(duration + const Duration(milliseconds: 120), () {
        if (!context.mounted) {
          return;
        }
        messenger.hideCurrentSnackBar(reason: SnackBarClosedReason.timeout);
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
        margin: _floatingMargin(context),
        duration: duration,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(25),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      ),
    );
  }

  static EdgeInsets _floatingMargin(
    BuildContext context, {
    bool compact = true,
  }) {
    final mediaQuery = MediaQuery.of(context);
    final width = mediaQuery.size.width;
    final horizontal = width < 360
        ? 16.0
        : width < 600
            ? 24.0
            : (width - 420).clamp(24.0, double.infinity) / 2;
    final bottom = mediaQuery.padding.bottom + (compact ? 28.0 : 18.0);
    return EdgeInsets.fromLTRB(horizontal, 0, horizontal, bottom);
  }
}
