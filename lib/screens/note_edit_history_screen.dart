import 'package:flutter/material.dart';
import 'package:inkpaper/l10n/app_localizations_simple.dart';
import 'package:inkpaper/providers/app_provider.dart';
import 'package:inkpaper/services/note_edit_history_service.dart';
import 'package:inkpaper/themes/app_theme.dart';
import 'package:inkpaper/utils/snackbar_utils.dart';
import 'package:provider/provider.dart';

/// 笔记历史版本列表（参考 flomo 编辑历史）。
///
/// 每个条目是一份完整正文快照：点开看全文，满意就一键恢复。
/// 恢复前会把当前内容先存进历史，所以恢复本身是可撤销的（再恢复回去即可）。
class NoteEditHistoryScreen extends StatefulWidget {
  const NoteEditHistoryScreen({required this.noteId, super.key});

  final String noteId;

  @override
  State<NoteEditHistoryScreen> createState() => _NoteEditHistoryScreenState();
}

class _NoteEditHistoryScreenState extends State<NoteEditHistoryScreen> {
  List<NoteEditHistoryEntry>? _entries;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final entries =
        await NoteEditHistoryService.instance.listSnapshots(widget.noteId);
    if (!mounted) {
      return;
    }
    setState(() => _entries = entries);
  }

  @override
  Widget build(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final backgroundColor =
        isDarkMode ? AppTheme.darkBackgroundColor : AppTheme.backgroundColor;
    final textColor =
        isDarkMode ? AppTheme.darkTextPrimaryColor : AppTheme.textPrimaryColor;
    final secondaryColor = isDarkMode
        ? AppTheme.darkTextSecondaryColor
        : AppTheme.textSecondaryColor;
    final cardColor =
        isDarkMode ? AppTheme.darkSurfaceColor : AppTheme.surfaceColor;
    final l10n = AppLocalizationsSimple.of(context);

    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(
        title: Text(
          l10n?.noteHistory ?? '历史版本',
          style: TextStyle(color: textColor, fontSize: 17),
        ),
        centerTitle: true,
        backgroundColor: backgroundColor,
        elevation: 0,
        iconTheme: IconThemeData(color: textColor),
      ),
      body: _entries == null
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : _entries!.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.history_rounded,
                        size: 56,
                        color: isDarkMode ? Colors.grey[600] : Colors.grey[400],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        l10n?.noHistory ?? '暂无历史版本',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: secondaryColor,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        child: Text(
                          l10n?.noHistoryHint ??
                              '每次保存和编辑过程都会自动留档，最多保留 20 份、30 天内的版本',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.5,
                            color: secondaryColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: () async {
                    await _load();
                  },
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                    itemCount: _entries!.length,
                    separatorBuilder: (context, index) =>
                        const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final entry = _entries![index];
                      return _HistoryCard(
                        entry: entry,
                        isDarkMode: isDarkMode,
                        cardColor: cardColor,
                        textColor: textColor,
                        secondaryColor: secondaryColor,
                        onTap: () => _showEntryDetail(entry),
                      );
                    },
                  ),
                ),
    );
  }

  /// 查看全文 + 恢复入口。
  void _showEntryDetail(NoteEditHistoryEntry entry) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final textColor =
        isDarkMode ? AppTheme.darkTextPrimaryColor : AppTheme.textPrimaryColor;
    final secondaryColor = isDarkMode
        ? AppTheme.darkTextSecondaryColor
        : AppTheme.textSecondaryColor;
    final l10n = AppLocalizationsSimple.of(context);

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.78,
          ),
          decoration: BoxDecoration(
            color:
                isDarkMode ? AppTheme.darkSurfaceColor : AppTheme.surfaceColor,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(20),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Text(
                  _formatTime(entry.createdAt),
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: textColor,
                  ),
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: SelectableText(
                    entry.content,
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.55,
                      color: textColor,
                    ),
                  ),
                ),
              ),
              SafeArea(
                minimum: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.of(sheetContext).pop(),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: secondaryColor,
                          side: BorderSide(
                            color: secondaryColor.withValues(alpha: 0.4),
                          ),
                        ),
                        child: Text(l10n?.cancel ?? '取消'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: () {
                          Navigator.of(sheetContext).pop();
                          _restore(entry);
                        },
                        child: Text(l10n?.restoreVersion ?? '恢复此版本'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 恢复版本：先把当前内容存进历史（恢复可撤销），再写回笔记。
  Future<void> _restore(NoteEditHistoryEntry entry) async {
    final appProvider = Provider.of<AppProvider>(context, listen: false);
    final note =
        appProvider.notes.where((n) => n.id == widget.noteId).firstOrNull;
    final l10n = AppLocalizationsSimple.of(context);
    if (note == null) {
      if (mounted) {
        SnackBarUtils.showError(context, l10n?.restoreFailed ?? '恢复失败');
      }
      return;
    }

    await NoteEditHistoryService.instance
        .addSnapshot(noteId: note.id, content: note.content);
    final ok = await appProvider.updateNote(note, entry.content);
    if (!mounted) {
      return;
    }
    if (ok) {
      SnackBarUtils.showSuccess(context, l10n?.versionRestored ?? '已恢复该版本');
      Navigator.of(context).pop();
    } else {
      SnackBarUtils.showError(context, l10n?.restoreFailed ?? '恢复失败');
    }
  }

  static String _formatTime(DateTime time) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}';
  }
}

/// 单个版本卡片：时间 + 内容预览。
class _HistoryCard extends StatelessWidget {
  const _HistoryCard({
    required this.entry,
    required this.isDarkMode,
    required this.cardColor,
    required this.textColor,
    required this.secondaryColor,
    required this.onTap,
  });

  final NoteEditHistoryEntry entry;
  final bool isDarkMode;
  final Color cardColor;
  final Color textColor;
  final Color secondaryColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizationsSimple.of(context);
    final preview = _preview(entry.content);

    return Material(
      color: cardColor,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.history_rounded,
                    size: 15,
                    color: secondaryColor,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _formatTime(entry.createdAt),
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: textColor,
                      ),
                    ),
                  ),
                  Text(
                    '${entry.content.length} ${l10n?.characters ?? '字符'}',
                    style: TextStyle(fontSize: 12, color: secondaryColor),
                  ),
                ],
              ),
              if (preview.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  preview,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.5,
                    color: secondaryColor,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 预览：图片行折叠成「[图片]」，空行压掉。
  static String _preview(String content) {
    final lines = <String>[];
    for (final line in content.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.startsWith('![')) {
        lines.add('[图片]');
        continue;
      }
      if (trimmed.isEmpty) {
        continue;
      }
      lines.add(trimmed);
    }
    return lines.join('\n');
  }

  static String _formatTime(DateTime time) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}';
  }
}
