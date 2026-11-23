import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:inkpaper/l10n/app_localizations_simple.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/providers/app_provider.dart';
import 'package:inkpaper/screens/note_detail_screen.dart';
import 'package:inkpaper/screens/share_image_preview_screen.dart';
import 'package:inkpaper/services/note_actions_service.dart';
import 'package:inkpaper/themes/app_theme.dart';
import 'package:inkpaper/utils/snackbar_utils.dart';
import 'package:inkpaper/widgets/intelligent_related_notes_sheet.dart';
import 'package:inkpaper/widgets/ios_datetime_picker.dart';
import 'package:inkpaper/widgets/note_action_card.dart';
import 'package:inkpaper/widgets/note_editor_page.dart';
import 'package:inkpaper/widgets/permission_guide_dialog.dart';
import 'package:inkpaper/widgets/references_sidebar.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

/// 📦 笔记操作 UI 编排层（ARCH-LAYER-002 / A-05）
///
/// 负责笔记操作的**界面**部分：底部弹窗、对话框、页面跳转、SnackBar 反馈：
/// - 编辑、删除、置顶
/// - 分享（文本/图片/链接）
/// - 提醒设置
/// - 引用查看
///
/// 数据层操作（更新/删除/置顶/可见性）在 `services/note_actions_service.dart`，
/// 这里不再直接调用 `AppProvider` 的写接口，避免 UI 层与数据层耦合。
class NoteActionsUi {
  /// 编辑笔记
  static Future<void> editNote({
    required BuildContext context,
    required Note note,
    required VoidCallback onUpdated,
  }) async {
    await NoteEditorPage.open(
      context,
      noteId: note.id,
      initialContent: note.content,
      onSave: (content) async {
        if (content.trim().isNotEmpty) {
          try {
            final appProvider =
                Provider.of<AppProvider>(context, listen: false);
            await NoteActionsService.updateContent(
              appProvider,
              note,
              content,
            );
            onUpdated();
            if (context.mounted) {
              SnackBarUtils.showSuccess(
                context,
                AppLocalizationsSimple.of(context)?.noteUpdated ?? '笔记已更新',
              );
            }
          } on Object catch (e) {
            if (context.mounted) {
              SnackBarUtils.showError(
                context,
                '${AppLocalizationsSimple.of(context)?.updatingFailed ?? '更新失败'}: $e',
              );
            }
          }
        }
      },
    );
  }

  /// 删除笔记：二次确认 → 行退出动效 → 从列表与库里删除 → 卡片提示。
  ///
  /// 提示条上带「撤销」：删除本身会先进回收站，但用户点错的那一刻是希望
  /// 立刻退回来的，让他翻设置去找回收站太远。撤销直接调 `restoreNote`，
  /// 原 id、原位置、引用关系都还在。
  ///
  /// [playExit] 由列表页提供：它把这一行标记为「正在离开」，等动效播完再返回。
  /// 详情页这类没有行的场景不传，确认后直接删。
  static Future<void> deleteNote({
    required BuildContext context,
    required Note note,
    required VoidCallback onDeleted,
    Future<void> Function()? playExit,
  }) async {
    final appProvider = Provider.of<AppProvider>(context, listen: false);
    final l10n = AppLocalizationsSimple.of(context);

    final confirmed = await showDeleteConfirmDialog(context);
    if (!confirmed || !context.mounted) {
      return;
    }

    // 动效期间先别摘行：直接摘会让下面整列往上硬跳一格，看着就像卡了一下
    if (playExit != null) {
      await playExit();
      if (!context.mounted) {
        return;
      }
    }

    // 摘行之后原 context 就失效了，提示条要用的 messenger 和边距先抓在手里
    final messenger = ScaffoldMessenger.maybeOf(context);
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final toastMargin = SnackBarUtils.toastMargin(context);
    final future = NoteActionsService.delete(appProvider, note.id);
    onDeleted();

    if (messenger != null) {
      // 与三点菜单同一张卡片：刚在那张卡里点的删除，反馈就从同一套材质里出来
      SnackBarUtils.showCardOn(
        messenger,
        l10n?.noteDeleted ?? '笔记已删除',
        isDarkMode: isDarkMode,
        margin: toastMargin,
        icon: Icons.delete_outline_rounded,
        actionLabel: l10n?.undo ?? '撤销',
        onAction: () => unawaited(
          _undoDelete(
            appProvider: appProvider,
            note: note,
            messenger: messenger,
            l10n: l10n,
            isDarkMode: isDarkMode,
            margin: toastMargin,
          ),
        ),
      );
    }

    final ok = await future;
    if (!ok && messenger != null) {
      // 落库失败时 AppProvider 已经把笔记插回原位（列表页的动效会反向播回）
      SnackBarUtils.showNativeOn(
        messenger,
        l10n?.deleteFailed ?? '删除失败',
        icon: Icons.error_outline_rounded,
        backgroundColor: Colors.red.shade600,
      );
    }
  }

  /// 撤销刚完成的删除：把笔记按原 id 恢复回原位。
  static Future<void> _undoDelete({
    required AppProvider appProvider,
    required Note note,
    required ScaffoldMessengerState messenger,
    required AppLocalizationsSimple? l10n,
    required bool isDarkMode,
    required EdgeInsets margin,
  }) async {
    final ok = await appProvider.restoreNote(id: note.id);
    SnackBarUtils.showCardOn(
      messenger,
      ok ? (l10n?.noteRestored ?? '笔记已恢复') : (l10n?.undoFailed ?? '撤销失败'),
      isDarkMode: isDarkMode,
      margin: margin,
      icon: ok ? Icons.undo_rounded : Icons.error_outline_rounded,
      duration: const Duration(milliseconds: 1800),
    );
  }

  /// 删除前的二次确认。
  ///
  /// 文案固定交代「进回收站、30 天内可恢复」——用户真正怕的是不可逆，
  /// 说清这一点，比在提示条里塞一个 2.8 秒就消失的撤销按钮更有效。
  ///
  /// 形态直接改用卡片右上角三点菜单那一套：同一个圆角、同一层阴影、同样的
  /// 行高。原先的 AlertDialog 收窄到 320 宽之后，标题和两行正文挤成一块，
  /// 在手机上看着矮胖；换成菜单式的竖排小卡片，一眼就认得出「这是笔记操作」。
  static Future<bool> showDeleteConfirmDialog(BuildContext context) async {
    final l10n = AppLocalizationsSimple.of(context);
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final titleColor = isDarkMode ? Colors.white : Colors.black;
    final bodyColor = isDarkMode ? Colors.grey[500] : Colors.grey[600];

    final confirmed = await showGeneralDialog<bool>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'delete-note-confirm',
      barrierColor: Colors.black.withValues(alpha: 0.2),
      transitionDuration: const Duration(milliseconds: 160),
      pageBuilder: (dialogContext, _, __) => Center(
        child: Padding(
          // 左右 44：窄屏也能留出边，卡片本身不会被压到边缘
          padding: const EdgeInsets.symmetric(horizontal: 44),
          child: NoteActionCard(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.delete_outline_rounded,
                        size: 20,
                        color: NoteActionCard.danger,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          l10n?.deleteNoteConfirmTitle ?? '删除笔记',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: titleColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                  child: Text(
                    l10n?.deleteNoteConfirmBody ??
                        '是否确认删除，删除笔记会移至回收站，30 天内可以前往回收站恢复',
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.45,
                      color: bodyColor,
                    ),
                  ),
                ),
                const NoteActionCardDivider(),
                NoteActionCardRow(
                  icon: Icons.delete_rounded,
                  label: l10n?.delete ?? '删除',
                  isDanger: true,
                  onTap: () => Navigator.of(dialogContext).pop(true),
                ),
                const NoteActionCardDivider(),
                NoteActionCardRow(
                  icon: Icons.close_rounded,
                  label: l10n?.cancel ?? '取消',
                  onTap: () => Navigator.of(dialogContext).pop(false),
                ),
              ],
            ),
          ),
        ),
      ),
      transitionBuilder: (dialogContext, animation, _, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.94, end: 1).animate(curved),
            child: child,
          ),
        );
      },
    );
    return confirmed ?? false;
  }

  /// 置顶/取消置顶
  static Future<void> togglePin({
    required BuildContext context,
    required Note note,
    required VoidCallback onUpdated,
  }) async {
    try {
      final appProvider = Provider.of<AppProvider>(context, listen: false);
      // 🔥 在切换之前判断：如果现在是置顶，操作后就是取消置顶；反之亦然
      final willPin = !note.isPinned; // 切换后的状态
      await NoteActionsService.togglePin(appProvider, note);
      onUpdated();
      if (context.mounted) {
        SnackBarUtils.showSuccess(
          context,
          // 🔥 显示切换后的状态
          willPin
              ? (AppLocalizationsSimple.of(context)?.pinned ?? '已置顶')
              : (AppLocalizationsSimple.of(context)?.unpinned ?? '已取消置顶'),
        );
      }
    } on Object {
      if (context.mounted) {
        SnackBarUtils.showError(
          context,
          AppLocalizationsSimple.of(context)?.operationFailed ?? '操作失败',
        );
      }
    }
  }

  /// 显示分享选项菜单
  static Future<void> showShareOptions({
    required BuildContext context,
    required Note note,
  }) async {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _ShareOptionsSheet(note: note, isDarkMode: isDarkMode),
    );
  }

  /// 分享文本
  static Future<void> shareText({
    required BuildContext context,
    required Note note,
  }) async {
    try {
      await Share.share(
        note.content,
        subject: AppLocalizationsSimple.of(context)?.shareNote ?? '分享笔记',
      );
    } on Object catch (e) {
      if (context.mounted) {
        SnackBarUtils.showError(
          context,
          AppLocalizationsSimple.of(context)?.shareFailedDetail(e) ??
              '分享失败: $e',
        );
      }
    }
  }

  /// 分享图片
  static Future<void> shareImage({
    required BuildContext context,
    required Note note,
  }) async {
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => ShareImagePreviewScreen(
            noteId: note.id,
            content: note.content,
            timestamp: note.updatedAt,
          ),
          fullscreenDialog: true,
        ),
      ),
    );
  }

  /// 复制分享链接（需要先设为公开）
  static Future<void> copyShareLink({
    required BuildContext context,
    required Note note,
    required VoidCallback onUpdated,
  }) async {
    if (note.isPublic) {
      // 已经是公开状态，直接复制链接
      _copyShareLinkDirectly(context, note);
    } else {
      // 显示权限确认对话框
      _showPublicPermissionDialog(context, note, onUpdated);
    }
  }

  /// 直接复制分享链接
  static void _copyShareLinkDirectly(BuildContext context, Note note) {
    final appProvider = Provider.of<AppProvider>(context, listen: false);
    final serverUrl = appProvider.appConfig.memosApiUrl;
    final shareUrl = '$serverUrl/m/${note.id}';

    Clipboard.setData(ClipboardData(text: shareUrl));
    SnackBarUtils.showSuccess(
      context,
      AppLocalizationsSimple.of(context)?.linkCopied ?? '链接已复制到剪贴板',
    );
  }

  /// 显示公开权限确认对话框
  static void _showPublicPermissionDialog(
    BuildContext context,
    Note note,
    VoidCallback onUpdated,
  ) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.public_rounded, color: Colors.orange),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                AppLocalizationsSimple.of(context)
                        ?.sharePermissionConfirmation ??
                    '分享权限确认',
              ),
            ),
          ],
        ),
        content: Text(
          AppLocalizationsSimple.of(context)?.sharePermissionMessage ??
              '要分享此笔记，需要将其设置为公开状态。\n任何拥有链接的人都可以查看该笔记的内容。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(AppLocalizationsSimple.of(context)?.cancel ?? '取消'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.of(context).pop();
              await _proceedWithSharing(context, note, onUpdated);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primaryColor,
              foregroundColor: Colors.white,
            ),
            child: Text(
              AppLocalizationsSimple.of(context)?.confirmAndShare ?? '确定并分享',
            ),
          ),
        ],
      ),
    );
  }

  /// 执行分享操作（将笔记设为公开并复制链接）
  static Future<void> _proceedWithSharing(
    BuildContext context,
    Note note,
    VoidCallback onUpdated,
  ) async {
    try {
      // 显示加载对话框
      unawaited(
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            content: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(width: 16),
                Text(
                  AppLocalizationsSimple.of(context)?.generatingShareLink ??
                      '正在生成分享链接...',
                ),
              ],
            ),
          ),
        ),
      );

      final appProvider = Provider.of<AppProvider>(context, listen: false);
      final serverUrl =
          appProvider.appConfig.memosApiUrl ?? appProvider.user?.serverUrl;

      if (serverUrl == null || serverUrl.isEmpty) {
        if (context.mounted) {
          Navigator.of(context).pop();
        }
        if (context.mounted) {
          SnackBarUtils.showError(
            context,
            AppLocalizationsSimple.of(context)?.serverConfigMissing ??
                '未登录或服务器配置错误',
          );
        }
        return;
      }

      final updatedNote =
          await NoteActionsService.setVisibility(appProvider, note, 'PUBLIC');

      if (context.mounted) {
        Navigator.of(context).pop();
      }

      if (updatedNote != null) {
        onUpdated();
        final shareUrl = '$serverUrl/m/${updatedNote.id}';
        unawaited(Clipboard.setData(ClipboardData(text: shareUrl)));

        if (context.mounted) {
          SnackBarUtils.showSuccess(
            context,
            AppLocalizationsSimple.of(context)?.linkCopied ?? '链接已复制到剪贴板',
          );
        }
      } else {
        if (context.mounted) {
          SnackBarUtils.showError(
            context,
            AppLocalizationsSimple.of(context)?.generateShareLinkFailed ??
                '生成分享链接失败',
          );
        }
      }
    } on Object catch (e) {
      if (context.mounted) {
        Navigator.of(context).pop();
      }
      if (context.mounted) {
        SnackBarUtils.showError(
          context,
          '${AppLocalizationsSimple.of(context)?.operationFailed ?? '操作失败'}: $e',
        );
      }
    }
  }

  /// 查找并展示与当前笔记相关的笔记。
  ///
  /// 使用本机全库索引查找当前笔记的关联。
  static Future<void> showRelatedNotes({
    required BuildContext context,
    required Note note,
  }) async {
    final appProvider = Provider.of<AppProvider>(context, listen: false);
    final localizations = AppLocalizationsSimple.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);

    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          localizations?.findingRelatedNotes ?? '正在查找相关笔记…',
        ),
        duration: const Duration(seconds: 30),
        behavior: SnackBarBehavior.floating,
      ),
    );

    try {
      final index = await appProvider.loadNoteDiscoveryIndex();
      final links = index.rankRelatedNotes(note.id);
      final notes = await Future.wait(
        links.map((link) => appProvider.loadRandomWalkNote(link.id)),
      );
      final result = <RelatedNoteItem>[
        for (var i = 0; i < links.length; i++)
          if (notes[i] case final target?)
            (
              note: target,
              link: links[i],
              preview: index.note(target.id)!.preview
            ),
      ];

      messenger?.hideCurrentSnackBar();
      if (!context.mounted) {
        return;
      }

      if (result.isEmpty) {
        SnackBarUtils.showInfo(
          context,
          localizations?.aiRelatedNotesEmpty ?? '未找到相关笔记',
        );
      } else {
        await IntelligentRelatedNotesSheet.show(context, result);
      }
    } on Object catch (e) {
      messenger?.hideCurrentSnackBar();
      if (context.mounted) {
        SnackBarUtils.showError(
          context,
          '${localizations?.operationFailed ?? '操作失败'}: $e',
        );
      }
    }
  }

  /// 显示引用详情（侧边栏版本）
  static Future<void> showReferences({
    required BuildContext context,
    required Note note,
  }) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.9,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (context, scrollController) => ReferencesSidebar(
          note: note,
          onNoteTap: (noteId) {
            Navigator.pop(context);
            // 导航到笔记详情页
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => NoteDetailScreen(noteId: noteId),
              ),
            );
          },
        ),
      ),
    );
  }

  /// 显示提醒设置（完整版 - 从详情页复制，包含权限检查和完整UI）
  /// 返回值：true=设置成功, false=设置失败, null=用户取消
  static Future<bool?> showReminderSettings({
    required BuildContext context,
    required Note note,
    required VoidCallback onUpdated,
  }) async {
    final appProvider = Provider.of<AppProvider>(context, listen: false);
    final currentReminderTime = note.reminderTime;

    // 🔥 直接进入时间选择，不再显示"修改/取消"选项

    // 🔥 先检查权限，没有权限先显示引导
    // 检查通知权限
    final notificationService = appProvider.notificationService;
    var hasPermission = await notificationService.areNotificationsEnabled();

    if (!hasPermission) {
      if (context.mounted) {
        // 显示权限引导弹窗
        await showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) => const PermissionGuideDialog(),
        );

        // 🔥 权限引导后重新检查权限
        hasPermission = await notificationService.areNotificationsEnabled();

        // 如果还是没有权限，提示用户并返回
        if (!hasPermission) {
          if (context.mounted) {
            SnackBarUtils.showWarning(
              context,
              AppLocalizationsSimple.of(context)?.enableNotificationFirst ??
                  '请先开启通知权限才能设置提醒',
            );
          }
          return null;
        }
      } else {
        return null;
      }
    }

    // 🔥 修复：确保初始时间不早于最小时间
    final now = DateTime.now();
    DateTime initialTime;

    if (currentReminderTime != null && currentReminderTime.isAfter(now)) {
      // 如果已有提醒时间且在未来，使用该时间
      initialTime = currentReminderTime;
    } else {
      // 否则使用1小时后
      initialTime = now.add(const Duration(hours: 1));
    }

    if (!context.mounted) {
      return null;
    }

    final reminderDateTime = await IOSDateTimePicker.show(
      context: context,
      initialDateTime: initialTime,
      minimumDateTime: now,
      maximumDateTime: now.add(const Duration(days: 365)),
      showQuickOptions: false, // 🔥 不显示快捷选择
    );
    if (!context.mounted) {
      return null;
    }

    // 用户取消了时间选择
    if (reminderDateTime == null) {
      return null;
    }

    // 检查时间是否在未来
    if (reminderDateTime.isBefore(DateTime.now())) {
      if (context.mounted) {
        SnackBarUtils.showWarning(
          context,
          AppLocalizationsSimple.of(context)?.reminderTimeMustBeFuture ??
              '提醒时间必须在未来',
        );
      }
      return false;
    }

    // 设置提醒
    try {
      final success =
          await appProvider.setNoteReminder(note.id, reminderDateTime);

      if (!success) {
        return false;
      }

      // 重新加载笔记
      onUpdated();

      return true;
    } on Object {
      return false;
    }
  }
}

/// 分享选项底部面板
class _ShareOptionsSheet extends StatelessWidget {
  const _ShareOptionsSheet({
    required this.note,
    required this.isDarkMode,
  });
  final Note note;
  final bool isDarkMode;

  @override
  Widget build(BuildContext context) {
    final surfaceColor =
        isDarkMode ? AppTheme.darkCardColor : AppTheme.surfaceColor;

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: surfaceColor,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(24),
          topRight: Radius.circular(24),
        ),
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 标题
            Text(
              AppLocalizationsSimple.of(context)?.shareNote ?? '分享笔记',
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 24),

            // 分享选项
            Row(
              children: [
                Expanded(
                  child: _buildShareOption(
                    context,
                    icon: Icons.text_fields,
                    label: AppLocalizationsSimple.of(context)?.share ?? '分享',
                    color: AppTheme.primaryColor,
                    onTap: () {
                      Navigator.pop(context);
                      NoteActionsUi.shareText(
                        context: context,
                        note: note,
                      );
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildShareOption(
                    context,
                    icon: Icons.image_rounded,
                    label:
                        AppLocalizationsSimple.of(context)?.shareImage ?? '图片',
                    color: Colors.green,
                    onTap: () {
                      Navigator.pop(context);
                      NoteActionsUi.shareImage(
                        context: context,
                        note: note,
                      );
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildShareOption(
    BuildContext context, {
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) =>
      Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: color.withValues(alpha: 0.3)),
            ),
            child: Column(
              children: [
                Icon(icon, color: color, size: 32),
                const SizedBox(height: 8),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
}
