import 'package:flutter/material.dart';
import 'package:inkpaper/themes/app_theme.dart';

/// 仿系统 ActionMode 的胶囊形文本选择工具栏。
///
/// Flutter 默认的 `AdaptiveTextSelectionToolbar` 在 Android 上是 Material
/// 规格：小圆角矩形 + 紧凑按钮。而小米 HyperOS 长按选中文字弹的是一条
/// 更宽、全圆角（胶囊）、字更大、点击区更松的横条 ——「问小爱」「翻译」
/// 就在里面。这里按那条横条的尺寸重绘，让 App 内的复制/粘贴菜单和
/// 系统视觉接上，不再是两套长相。
class CapsuleTextSelectionToolbar extends StatelessWidget {
  const CapsuleTextSelectionToolbar({
    required this.anchorAbove,
    required this.anchorBelow,
    required this.buttonItems,
    super.key,
  });

  /// 选区上方的锚点：工具栏优先摆到它上面。
  final Offset anchorAbove;

  /// 选区下方的锚点：上方放不下时摆到它下面。
  final Offset anchorBelow;

  /// 由 `EditableTextState.contextMenuButtonItems` 提供（剪切/复制/粘贴…）。
  final List<ContextMenuButtonItem> buttonItems;

  /// 参考 HyperOS 悬浮条：实测触控区 150px / density 3 = 50dp 高，字号 15sp。
  static const double _height = 50;
  static const double _radius = _height / 2;
  static const double _fontSize = 15;

  @override
  Widget build(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final isZh = Localizations.localeOf(context).languageCode == 'zh';
    final backgroundColor = isDarkMode ? AppTheme.darkCardColor : Colors.white;
    final labelColor = isDarkMode ? Colors.white : const Color(0xFF1C1C1E);

    // 项多时（剪切/复制/粘贴/全选/分享/搜索）不撑出屏幕，横向滚动兜底。
    return CustomSingleChildLayout(
      delegate: TextSelectionToolbarLayoutDelegate(
        anchorAbove: anchorAbove,
        anchorBelow: anchorBelow,
      ),
      child: Material(
        color: backgroundColor,
        elevation: 4,
        shadowColor: Colors.black.withValues(alpha: 0.18),
        clipBehavior: Clip.antiAlias,
        borderRadius: BorderRadius.circular(_radius),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width - 24,
            maxHeight: _height,
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              height: _height,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final item in buttonItems)
                    if (_labelOf(item, isZh).isNotEmpty)
                      _CapsuleButton(
                        label: _labelOf(item, isZh),
                        color: labelColor,
                        onTap: item.onPressed,
                      ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Dart 的 switch 已经穷尽 `ContextMenuButtonType`，新增枚举值会编译报错，
  /// 正好提醒补文案。
  String _labelOf(ContextMenuButtonItem item, bool isZh) {
    switch (item.type) {
      case ContextMenuButtonType.cut:
        return isZh ? '剪切' : 'Cut';
      case ContextMenuButtonType.copy:
        return isZh ? '复制' : 'Copy';
      case ContextMenuButtonType.paste:
        return isZh ? '粘贴' : 'Paste';
      case ContextMenuButtonType.selectAll:
        return isZh ? '全选' : 'Select all';
      case ContextMenuButtonType.delete:
        return isZh ? '删除' : 'Delete';
      case ContextMenuButtonType.share:
        return isZh ? '分享' : 'Share';
      case ContextMenuButtonType.searchWeb:
        return isZh ? '搜索' : 'Search';
      case ContextMenuButtonType.lookUp:
        return isZh ? '查询' : 'Look up';
      case ContextMenuButtonType.liveTextInput:
        return isZh ? '扫描文本' : 'Scan text';
      case ContextMenuButtonType.custom:
        // 第三方 PROCESS_TEXT 注入的项（「朗读」「在浏览器中打开」之类）文案
        // 长度不可控，塞进来会把胶囊撑出屏幕、末端被硬切，统一不显示。
        return '';
    }
  }
}

class _CapsuleButton extends StatelessWidget {
  const _CapsuleButton({
    required this.label,
    required this.color,
    required this.onTap,
  });

  final String label;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        // 系统那条按钮间的留白比 Material 松，靠水平 14dp 撑开；
        // 再大会让「剪切/复制/粘贴/分享/全选」六项顶出屏幕。
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontSize: CapsuleTextSelectionToolbar._fontSize,
              fontWeight: FontWeight.w500,
              height: 1.1,
              color: color,
            ),
          ),
        ),
      ),
    );
  }
}
