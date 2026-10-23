import 'package:flutter/material.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/providers/app_provider.dart';
import 'package:inkpaper/services/draft_service.dart';
import 'package:inkpaper/themes/app_theme.dart';
import 'package:inkpaper/utils/snackbar_utils.dart';
import 'package:inkpaper/widgets/note_editor.dart';
import 'package:provider/provider.dart';

/// 草稿箱：列出编辑器自动暂存的草稿，可继续编辑或删除。
///
/// 草稿默认保留 [DraftService.retention]，过期后打开本页时自动清理。
class DraftBoxScreen extends StatefulWidget {
  const DraftBoxScreen({super.key});

  @override
  State<DraftBoxScreen> createState() => _DraftBoxScreenState();
}

class _DraftBoxScreenState extends State<DraftBoxScreen> {
  final DraftService _draftService = DraftService();
  List<NoteDraft> _drafts = const [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadDrafts();
  }

  Future<void> _loadDrafts() async {
    final drafts = await _draftService.list();
    if (!mounted) {
      return;
    }
    setState(() {
      _drafts = drafts;
      _isLoading = false;
    });
  }

  Future<void> _openDraft(NoteDraft draft) async {
    final appProvider = Provider.of<AppProvider>(context, listen: false);
    Note? linkedNote;
    if (draft.noteId != null) {
      for (final note in appProvider.notes) {
        if (note.id == draft.noteId) {
          linkedNote = note;
          break;
        }
      }
    }
    final note = linkedNote;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => NoteEditor(
        initialContent: draft.content,
        currentNoteId: note?.id,
        preserveDraftOnClose: true,
        onSave: (content) async {
          if (content.trim().isEmpty) {
            return;
          }
          if (note != null) {
            await appProvider.updateNote(note, content);
          } else {
            await appProvider.createNote(content);
          }
        },
      ),
    );

    await _loadDrafts();
  }

  Future<void> _deleteDraft(NoteDraft draft) async {
    await _draftService.clear(draft.draftId);
    await _loadDrafts();
    if (mounted) {
      SnackBarUtils.showInfo(context, '草稿已删除');
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final backgroundColor =
        isDarkMode ? AppTheme.darkBackgroundColor : AppTheme.backgroundColor;
    final cardColor = isDarkMode ? AppTheme.darkCardColor : Colors.white;
    final textColor =
        isDarkMode ? AppTheme.darkTextPrimaryColor : AppTheme.textPrimaryColor;
    final secondaryTextColor =
        isDarkMode ? AppTheme.darkTextSecondaryColor : AppTheme.textSecondaryColor;

    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(
        title: const Text('草稿箱'),
        elevation: 0,
        backgroundColor: cardColor,
        foregroundColor: textColor,
        centerTitle: true,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _drafts.isEmpty
              ? _buildEmptyState(secondaryTextColor)
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: _drafts.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (context, index) {
                    final draft = _drafts[index];
                    return _buildDraftCard(
                      draft: draft,
                      cardColor: cardColor,
                      textColor: textColor,
                      secondaryTextColor: secondaryTextColor,
                    );
                  },
                ),
    );
  }

  Widget _buildEmptyState(Color secondaryTextColor) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.drafts_outlined, size: 56, color: secondaryTextColor),
            const SizedBox(height: 12),
            Text(
              '暂无草稿',
              style: TextStyle(fontSize: 16, color: secondaryTextColor),
            ),
            const SizedBox(height: 8),
            Text(
              '编辑笔记时会自动暂存，误关编辑器也能在这里找回',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: secondaryTextColor),
            ),
          ],
        ),
      );

  Widget _buildDraftCard({
    required NoteDraft draft,
    required Color cardColor,
    required Color textColor,
    required Color secondaryTextColor,
  }) =>
      Card(
        elevation: 1,
        color: cardColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _openDraft(draft),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      draft.isNewNote ? Icons.add_circle_outline : Icons.edit_note,
                      size: 16,
                      color: AppTheme.primaryColor,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      draft.isNewNote ? '新笔记草稿' : '编辑草稿',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.primaryColor,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      _formatTime(draft.updatedAt),
                      style: TextStyle(fontSize: 12, color: secondaryTextColor),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  _previewText(draft.content),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14, height: 1.5, color: textColor),
                ),
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () => _deleteDraft(draft),
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, 32),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    icon: Icon(
                      Icons.delete_outline,
                      size: 16,
                      color: secondaryTextColor,
                    ),
                    label: Text(
                      '删除',
                      style: TextStyle(
                        fontSize: 12,
                        color: secondaryTextColor,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

  String _previewText(String content) {
    final withoutImages = content.replaceAll(
      RegExp(r'!\[[^\]]*\]\([^)]*\)'),
      '[图片]',
    );
    final normalized = withoutImages.replaceAll(RegExp(r'\s+'), ' ').trim();
    return normalized.isEmpty ? '（空白草稿）' : normalized;
  }

  String _formatTime(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) {
      return '刚刚';
    }
    if (diff.inMinutes < 60) {
      return '${diff.inMinutes} 分钟前';
    }
    if (diff.inHours < 24) {
      return '${diff.inHours} 小时前';
    }
    if (diff.inDays < 7) {
      return '${diff.inDays} 天前';
    }
    return '${time.month}月${time.day}日';
  }
}
