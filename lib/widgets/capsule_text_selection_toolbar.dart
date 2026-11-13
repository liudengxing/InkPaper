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

    // 平台注入的自定义项（「朗读」「在浏览器中打开」）文案长度不可控，
    // 直接铺在主条上会把胶囊顶出屏幕；按系统做法收进末尾的 ⋮ 里。
    final primaryItems = <ContextMenuButtonItem>[];
    final overflowItems = <ContextMenuButtonItem>[];
    for (final item in buttonItems) {
      if (item.type == ContextMenuButtonType.custom) {
        if ((item.label ?? '').isNotEmpty) {
          overflowItems.add(item);
        }
      } else if (_labelOf(item, isZh).isNotEmpty) {
        primaryItems.add(item);
      }
    }

    // 项多时不撑出屏幕，横向滚动兜底。
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
                  for (final item in primaryItems)
                    _CapsuleButton(
                      label: _labelOf(item, isZh),
                      color: labelColor,
                      onTap: item.onPressed,
                    ),
                  if (overflowItems.isNotEmpty)
                    Builder(
                      builder: (buttonContext) => _CapsuleButton(
                        icon: Icons.more_vert,
                        color: labelColor,
                        onTap: () => _showOverflowMenu(
                          buttonContext,
                          overflowItems,
                          backgroundColor,
                          labelColor,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// ⋮ 二级菜单：贴着按钮下方弹出，样式跟胶囊保持一致（圆角白卡）。
  Future<void> _showOverflowMenu(
    BuildContext buttonContext,
    List<ContextMenuButtonItem> items,
    Color backgroundColor,
    Color labelColor,
  ) async {
    final box = buttonContext.findRenderObject() as RenderBox?;
    final overlayBox =
        Overlay.of(buttonContext).context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || overlayBox == null) {
      return;
    }

    final anchor =
        box.localToGlobal(Offset.zero, ancestor: overlayBox) & box.size;
    final selected = await showMenu<ContextMenuButtonItem>(
      context: buttonContext,
      position: RelativeRect.fromRect(
        anchor,
        Offset.zero & overlayBox.size,
      ),
      color: backgroundColor,
      elevation: 4,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
      ),
      items: [
        for (final item in items)
          PopupMenuItem<ContextMenuButtonItem>(
            value: item,
            height: 44,
            child: Text(
              item.label ?? '',
              style: TextStyle(fontSize: _fontSize, color: labelColor),
            ),
          ),
      ],
    );

    selected?.onPressed?.call();
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
        // 主条不显示，统一由 build 里挑出来丢进 ⋮ 菜单，label 用平台给的原文。
        return '';
    }
  }
}

class _CapsuleButton extends StatelessWidget {
  const _CapsuleButton({
    required this.color,
    required this.onTap,
    this.label,
    this.icon,
  }) : assert(label != null || icon != null, '文字或图标至少给一个');

  final String? label;
  final IconData? icon;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final icon = this.icon;
    return InkWell(
      onTap: onTap,
      child: Padding(
        // 系统那条按钮间的留白比 Material 松，靠水平 14dp 撑开；
        // 再大会让「剪切/复制/粘贴/分享/全选」连 ⋮ 一起顶出屏幕。
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Center(
          child: icon != null
              ? Icon(icon, size: 20, color: color)
              : Text(
                  label ?? '',
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
