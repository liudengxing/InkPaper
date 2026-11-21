import 'package:flutter/material.dart';

/// 笔记操作的悬浮卡片外壳：三点菜单、删除确认、删除结果提示共用这一套。
///
/// 抽出来是因为它们本来就是同一个东西的三种状态：菜单浮在卡片右上角、
/// 确认框浮在屏幕中央、删除结果浮在底部。三处各写一遍材质，圆角、阴影、
/// 底色的数值迟早会分叉，看起来就像三个应用弹出的框。
class NoteActionCard extends StatelessWidget {
  const NoteActionCard({required this.child, super.key});

  final Widget child;

  /// 卡片圆角，与三点菜单一致。
  static const double radius = 16;

  /// 危险操作的红色，取 iOS 系统红，深色模式也看得清。
  static const Color danger = Color(0xFFFF3B30);

  static Color surfaceOf(bool isDarkMode) =>
      isDarkMode ? const Color(0xFF1C1C1E) : Colors.white;

  static Color dividerOf(bool isDarkMode) => isDarkMode
      ? Colors.white.withValues(alpha: 0.08)
      : Colors.black.withValues(alpha: 0.06);

  @override
  Widget build(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: surfaceOf(isDarkMode),
      elevation: 12,
      shadowColor: Colors.black.withValues(alpha: 0.28),
      borderRadius: BorderRadius.circular(radius),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

/// 卡片里的一行：图标、文字、可选尾部。危险行整行变红。
class NoteActionCardRow extends StatelessWidget {
  const NoteActionCardRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.isDanger = false,
    this.trailing,
    this.fontSize = 15,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool isDanger;
  final Widget? trailing;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final iconColor = isDanger
        ? NoteActionCard.danger
        : (isDarkMode ? Colors.grey[400]! : Colors.grey[700]!);
    final textColor = isDanger
        ? NoteActionCard.danger
        : (isDarkMode ? Colors.white : Colors.black);

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        child: Row(
          children: [
            Icon(icon, size: 20, color: iconColor),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: TextStyle(fontSize: fontSize, color: textColor),
              ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }
}

/// 卡片内的 0.5dp 分隔线。
class NoteActionCardDivider extends StatelessWidget {
  const NoteActionCardDivider({super.key});

  @override
  Widget build(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    return Divider(
      height: 0.5,
      thickness: 0.5,
      color: NoteActionCard.dividerOf(isDarkMode),
    );
  }
}
