import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:inkpaper/config/app_config.dart' as Config;
import 'package:inkpaper/l10n/app_localizations_simple.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/providers/app_provider.dart';
import 'package:inkpaper/utils/snackbar_utils.dart';
import 'package:inkpaper/widgets/note_actions_ui.dart';
import 'package:provider/provider.dart';

/// 🎨 笔记更多选项菜单组件（Popup菜单版）
///
/// 在点击位置附近弹出，符合iOS上下文菜单设计规范
class NoteMoreOptionsMenu {
  /// 显示更多选项菜单（flomo 式底部面板）
  static Future<void> show({
    required BuildContext context,
    required Note note,
    VoidCallback? onNoteUpdated,
    // 覆盖默认删除行为（例如示例笔记只提示、不落库）。
    VoidCallback? onDeleteOverride,
  }) =>
      _showOptionsSheet(
        context: context,
        note: note,
        onNoteUpdated: onNoteUpdated,
        onDeleteOverride: onDeleteOverride,
      );

  /// 内部方法：底部面板 + 统一处理选项
  static Future<void> _showOptionsSheet({
    required BuildContext context,
    required Note note,
    VoidCallback? onNoteUpdated,
    VoidCallback? onDeleteOverride,
  }) {
    final localizations = AppLocalizationsSimple.of(context);
    var currentNote = note;

    // 用于在异步操作后刷新笔记数据
    Future<void> reloadNote() async {
      final appProvider = Provider.of<AppProvider>(context, listen: false);
      final updatedNote = appProvider.notes.firstWhere(
        (n) => n.id == currentNote.id,
        orElse: () => currentNote,
      );
      currentNote = updatedNote;
    }

    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetContext) => _buildOptionsSheet(
        sheetContext,
        currentNote,
        localizations,
      ),
    ).then((value) async {
      if (value == null) {
        return;
      }
      if (!context.mounted) {
        return;
      }

      switch (value) {
        case 'share':
          await NoteActionsUi.showShareOptions(
            context: context,
            note: currentNote,
          );
          break;
        case 'copy':
          await Clipboard.setData(ClipboardData(text: currentNote.content));
          if (context.mounted) {
            SnackBarUtils.showSuccess(
              context,
              localizations?.copiedToClipboard ?? '已复制到剪贴板',
            );
          }
          break;
        case 'edit':
          await NoteActionsUi.editNote(
            context: context,
            note: currentNote,
            onUpdated: () {
              reloadNote();
              onNoteUpdated?.call();
            },
          );
          break;
        case 'annotations':
          await NoteActionsUi.showAnnotations(
            context: context,
            note: currentNote,
            onUpdated: () {
              reloadNote();
              onNoteUpdated?.call();
            },
          );
          break;
        case 'pin':
          await NoteActionsUi.togglePin(
            context: context,
            note: currentNote,
            onUpdated: () {
              reloadNote();
              onNoteUpdated?.call();
            },
          );
          break;
        case 'ai':
          await NoteActionsUi.showAiReview(
            context: context,
            note: currentNote,
          );
          break;
        case 'link':
          await NoteActionsUi.copyShareLink(
            context: context,
            note: currentNote,
            onUpdated: () {
              reloadNote();
              onNoteUpdated?.call();
            },
          );
          break;
        case 'reference':
          await NoteActionsUi.showReferences(
            context: context,
            note: currentNote,
          );
          break;
        case 'reminder':
          final result = await NoteActionsUi.showReminderSettings(
            context: context,
            note: currentNote,
            onUpdated: () {
              reloadNote();
              onNoteUpdated?.call();
            },
          );
          // 🔥 显示通知
          if (context.mounted) {
            if (result ?? false) {
              SnackBarUtils.showSuccess(context, '设置成功');
            } else if (result == false) {
              SnackBarUtils.showError(context, '设置失败');
            }
          }
          break;
        case 'visibility':
          await NoteActionsUi.showVisibilitySelector(
            context: context,
            note: currentNote,
            onUpdated: () {
              reloadNote();
              onNoteUpdated?.call();
            },
          );
          break;
        case 'change_time':
          await _showChangeTimeDialog(
            context: context,
            note: currentNote,
            onUpdated: () {
              reloadNote();
              onNoteUpdated?.call();
            },
          );
          break;
        case 'info':
          await NoteActionsUi.showNoteDetails(
            context: context,
            note: currentNote,
          );
          break;
        case 'delete':
          {
            // 示例笔记等特殊场景由调用方接管删除行为
            final override = onDeleteOverride;
            if (override != null) {
              override();
              break;
            }
            await NoteActionsUi.deleteNote(
              context: context,
              note: currentNote,
              onDeleted: () {
                onNoteUpdated?.call();
              },
            );
            break;
          }
      }
    });
  }

  /// 显示修改时间对话框
  static Future<void> _showChangeTimeDialog({
    required BuildContext context,
    required Note note,
    required VoidCallback onUpdated,
  }) async {
    final appProvider = Provider.of<AppProvider>(context, listen: false);
    final localizations = AppLocalizationsSimple.of(context);

    debugPrint('🕐 [ChangeTime] 开始修改时间');
    debugPrint('🕐 [ChangeTime] 笔记ID: ${note.id}');
    debugPrint('🕐 [ChangeTime] 当前updatedAt: ${note.updatedAt}');
    debugPrint('🕐 [ChangeTime] 当前createdAt: ${note.createdAt}');

    final selectedDate = note.updatedAt;
    final selectedTime = TimeOfDay.fromDateTime(note.updatedAt);

    // 显示日期选择器
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: selectedDate,
      firstDate: DateTime(1970), // 允许选择很早的时间
      lastDate: DateTime.now().add(const Duration(days: 3650)), // 允许选择未来10年
      locale: Localizations.localeOf(context), // 明确指定locale
      helpText: localizations?.selectDate ?? '选择日期',
      cancelText: localizations?.cancel ?? '取消',
      confirmText: localizations?.confirm ?? '确定',
      builder: (context, child) {
        // 修复宽度溢出问题
        return Theme(
          data: Theme.of(context).copyWith(
            dialogTheme: const DialogThemeData(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.all(Radius.circular(16)),
              ),
            ),
          ),
          child: child!,
        );
      },
    );

    if (pickedDate == null || !context.mounted) {
      debugPrint('🕐 [ChangeTime] 用户取消选择日期或context已销毁');
      return;
    }

    debugPrint('🕐 [ChangeTime] 用户选择的日期: $pickedDate');

    // 显示时间选择器
    final pickedTime = await showTimePicker(
      context: context,
      initialTime: selectedTime,
      helpText: localizations?.selectTime ?? '选择时间',
      cancelText: localizations?.cancel ?? '取消',
      confirmText: localizations?.confirm ?? '确定',
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          dialogTheme: const DialogThemeData(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(16)),
            ),
          ),
        ),
        child: child!,
      ),
    );

    if (pickedTime == null || !context.mounted) {
      debugPrint('🕐 [ChangeTime] 用户取消选择时间或context已销毁');
      return;
    }

    debugPrint('🕐 [ChangeTime] 用户选择的时间: $pickedTime');

    // 合并日期和时间
    final newDateTime = DateTime(
      pickedDate.year,
      pickedDate.month,
      pickedDate.day,
      pickedTime.hour,
      pickedTime.minute,
    );

    debugPrint('🕐 [ChangeTime] 合并后的新时间: $newDateTime');
    debugPrint('🕐 [ChangeTime] 原始时间: ${note.updatedAt}');

    // 更新笔记时间（仅本地操作，不同步到服务器）
    try {
      final updatedNote = note.copyWith(
        updatedAt: newDateTime,
        // ✅ 保持已同步状态，避免触发服务器同步
        // 因为 Memos API 不支持自定义 updatedAt，修改时间是纯本地功能
        isSynced: note.isSynced,
      );

      debugPrint(
        '🕐 [ChangeTime] 创建updatedNote，新的updatedAt: ${updatedNote.updatedAt}',
      );
      debugPrint('🕐 [ChangeTime] 直接更新本地数据库和内存，不同步到服务器');

      // ✅ 直接更新本地数据库，不触发服务器同步
      await appProvider.updateNoteLocally(updatedNote);

      debugPrint('🕐 [ChangeTime] 本地更新完成');

      if (context.mounted) {
        SnackBarUtils.showSuccess(
          context,
          localizations?.timeUpdated ?? '时间已更新',
        );
        debugPrint('🕐 [ChangeTime] 调用onUpdated回调');
        onUpdated();
      }
    } on Object catch (e, stackTrace) {
      debugPrint('🕐 [ChangeTime] ❌ 更新失败: $e');
      debugPrint('🕐 [ChangeTime] ❌ 堆栈: $stackTrace');
      if (context.mounted) {
        SnackBarUtils.showError(
          context,
          localizations?.timeUpdateFailed ?? '时间更新失败',
        );
      }
    }
  }

  /// flomo 式底部面板：顶部一排快捷操作 + 元信息 + 其它操作。
  static Widget _buildOptionsSheet(
    BuildContext context,
    Note note,
    AppLocalizationsSimple? localizations,
  ) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final surface = isDarkMode ? const Color(0xFF1C1C1E) : Colors.white;
    final secondaryText = isDarkMode ? Colors.grey[500] : Colors.grey[600];
    final dividerColor = isDarkMode
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.06);

    void select(String value) => Navigator.of(context).pop(value);

    return SafeArea(
      top: false,
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.82,
        ),
        decoration: BoxDecoration(
          color: surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 拖动指示条
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(top: 10),
              decoration: BoxDecoration(
                color: isDarkMode ? Colors.grey[700] : Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // 顶部独立操作块：分享 / 编辑 / 复制
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
              child: Row(
                children: [
                  _buildQuickAction(
                    icon: Icons.ios_share_rounded,
                    label: localizations?.share ?? '分享',
                    isDarkMode: isDarkMode,
                    onTap: () => select('share'),
                  ),
                  _buildQuickAction(
                    icon: Icons.edit_rounded,
                    label: localizations?.edit ?? '编辑',
                    isDarkMode: isDarkMode,
                    onTap: () => select('edit'),
                  ),
                  _buildQuickAction(
                    icon: Icons.copy_rounded,
                    label: localizations?.copyNote ?? '复制',
                    isDarkMode: isDarkMode,
                    onTap: () => select('copy'),
                  ),
                ],
              ),
            ),
            Divider(height: 0.5, thickness: 0.5, color: dividerColor),
            // 其它操作
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  children: [
                    _buildSheetAction(
                      icon: Icons.comment_outlined,
                      label: localizations?.viewAnnotations ?? '查看批注',
                      isDarkMode: isDarkMode,
                      onTap: () => select('annotations'),
                      trailing: note.annotations.isNotEmpty
                          ? Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.orange.withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                '${note.annotations.length}',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.orange.shade700,
                                ),
                              ),
                            )
                          : null,
                    ),
                    _buildSheetAction(
                      icon: note.isPinned
                          ? Icons.push_pin
                          : Icons.push_pin_outlined,
                      label: note.isPinned
                          ? (localizations?.unpinNote ?? '取消置顶')
                          : (localizations?.pinNote ?? '置顶'),
                      isDarkMode: isDarkMode,
                      onTap: () => select('pin'),
                    ),
                    _buildSheetAction(
                      icon: Icons.rate_review_rounded,
                      label: localizations?.aiReview ?? 'AI点评',
                      isDarkMode: isDarkMode,
                      onTap: () => select('ai'),
                    ),
                    _buildSheetAction(
                      icon: Icons.link_rounded,
                      label: localizations?.linkNote ?? '链接',
                      isDarkMode: isDarkMode,
                      onTap: () => select('link'),
                    ),
                    _buildSheetAction(
                      icon: Icons.account_tree_outlined,
                      label: localizations?.referenceDetails ?? '引用详情',
                      isDarkMode: isDarkMode,
                      onTap: () => select('reference'),
                    ),
                    if (Config.AppConfig.enableReminders)
                      _buildSheetAction(
                        icon: Icons.alarm_add,
                        label: localizations?.setReminder ?? '提醒设置',
                        isDarkMode: isDarkMode,
                        onTap: () => select('reminder'),
                        trailing: note.reminderTime != null
                            ? Text(
                                localizations?.reminderSet ?? '已设置',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: secondaryText,
                                ),
                              )
                            : null,
                      ),
                    _buildSheetAction(
                      icon: note.isPublic ? Icons.public : Icons.lock_outline,
                      label: localizations?.noteVisibility ?? '可见性',
                      isDarkMode: isDarkMode,
                      onTap: () => select('visibility'),
                      trailing: Text(
                        note.isPublic
                            ? (localizations?.public ?? '公开')
                            : (localizations?.private ?? '私有'),
                        style: TextStyle(fontSize: 13, color: secondaryText),
                      ),
                    ),
                    _buildSheetAction(
                      icon: Icons.access_time_rounded,
                      label: localizations?.changeTime ?? '修改时间',
                      isDarkMode: isDarkMode,
                      onTap: () => select('change_time'),
                    ),
                    _buildSheetAction(
                      icon: Icons.info_outline,
                      label: localizations?.detailedInfo ?? '详细信息',
                      isDarkMode: isDarkMode,
                      onTap: () => select('info'),
                    ),
                    _buildSheetAction(
                      icon: Icons.delete_rounded,
                      label: localizations?.delete ?? '删除',
                      isDarkMode: isDarkMode,
                      isDanger: true,
                      onTap: () => select('delete'),
                    ),
                  ],
                ),
              ),
            ),
            Divider(height: 0.5, thickness: 0.5, color: dividerColor),
            // 元信息固定在面板最下面
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildMetaRow(
                    localizations?.characterCount ?? '字数统计',
                    '${note.content.length}',
                    secondaryText,
                  ),
                  _buildMetaRow(
                    localizations?.createdTime ?? '创建时间',
                    _formatMenuTime(note.createdAt),
                    secondaryText,
                  ),
                  _buildMetaRow(
                    localizations?.lastEdited ?? '最后编辑',
                    _formatMenuTime(note.updatedAt),
                    secondaryText,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 顶部圆形图标按钮（flomo 快捷操作）。
  static Widget _buildQuickAction({
    required IconData icon,
    required String label,
    required bool isDarkMode,
    required VoidCallback onTap,
  }) =>
      Expanded(
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: isDarkMode
                        ? Colors.white.withValues(alpha: 0.06)
                        : Colors.black.withValues(alpha: 0.04),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    icon,
                    size: 21,
                    color: isDarkMode ? Colors.grey[300] : Colors.black87,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    color: isDarkMode ? Colors.grey[300] : Colors.black87,
                  ),
                ),
              ],
            ),
          ),
        ),
      );

  /// 元信息行（灰色小字，左侧标签右侧值）。
  static Widget _buildMetaRow(String label, String value, Color? color) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: TextStyle(fontSize: 12, color: color)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                value,
                style: TextStyle(
                  fontSize: 12,
                  color: color,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      );

  /// 长列表里的操作行。
  static Widget _buildSheetAction({
    required IconData icon,
    required String label,
    required bool isDarkMode,
    required VoidCallback onTap,
    bool isDanger = false,
    Widget? trailing,
  }) =>
      InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
          child: _buildMenuItem(
            icon: icon,
            label: label,
            isDarkMode: isDarkMode,
            isDanger: isDanger,
            trailing: trailing,
          ),
        ),
      );

  static String _formatMenuTime(DateTime time) {
    final local = time.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  /// 构建菜单项
  static Widget _buildMenuItem({
    required IconData icon,
    required String label,
    required bool isDarkMode,
    bool isDanger = false,
    Widget? trailing,
  }) {
    final iconColor = isDanger
        ? const Color(0xFFFF3B30)
        : (isDarkMode ? Colors.grey[400]! : Colors.grey[700]!);
    final textColor = isDanger
        ? const Color(0xFFFF3B30)
        : (isDarkMode ? Colors.white : Colors.black);

    return Row(
      children: [
        Icon(icon, size: 20, color: iconColor),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 15,
              color: textColor,
            ),
          ),
        ),
        if (trailing != null) trailing,
      ],
    );
  }
}
