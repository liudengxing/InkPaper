import 'package:flutter/material.dart';
import 'package:inkpaper/l10n/app_localizations_simple.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/providers/app_provider.dart';
import 'package:inkpaper/services/database_service.dart';
import 'package:inkpaper/utils/snackbar_utils.dart';
import 'package:inkpaper/utils/time_utils.dart';
import 'package:provider/provider.dart';

/// 「最近删除」：软删笔记的回收站，支持恢复与彻底删除。
class RecentlyDeletedScreen extends StatefulWidget {
  const RecentlyDeletedScreen({super.key});

  /// 回收站保留期，超过后访问本页时自动清理。
  static const Duration retention = Duration(days: 30);

  @override
  State<RecentlyDeletedScreen> createState() => _RecentlyDeletedScreenState();
}

class _RecentlyDeletedScreenState extends State<RecentlyDeletedScreen> {
  bool _isLoading = true;
  List<Note> _notes = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final provider = context.read<AppProvider>();
    setState(() => _isLoading = true);

    // 过期回收站数据在进入本页时惰性清理，避免启动路径多一次写库
    try {
      await DatabaseService()
          .purgeDeletedNotesOlderThan(RecentlyDeletedScreen.retention);
    } on Object catch (e) {
      debugPrint('最近删除: 过期清理失败: $e');
    }

    final notes = await provider.loadRecentlyDeletedNotes();

    if (!mounted) {
      return;
    }
    setState(() {
      _notes = notes;
      _isLoading = false;
    });
  }

  Future<void> _restore(Note note) async {
    final l10n = AppLocalizationsSimple.of(context);
    final provider = context.read<AppProvider>();
    final restored = await provider.restoreRecentlyDeletedNote(note.id);
    if (!mounted) {
      return;
    }
    if (restored) {
      SnackBarUtils.showSuccess(context, l10n?.noteRestored ?? '笔记已恢复');
    } else {
      SnackBarUtils.showError(
        context,
        l10n?.restoreFailedRetry ?? '恢复失败，请重试',
      );
    }
    await _load();
  }

  Future<void> _purge(Note note) async {
    final l10n = AppLocalizationsSimple.of(context);
    final confirmed = await _confirm(
      title: l10n?.purgeForever ?? '彻底删除',
      content: l10n?.purgeForeverMessage ?? '这条笔记将被永久删除，无法恢复。',
      confirmText: l10n?.purgeForever ?? '彻底删除',
    );
    if (confirmed != true || !mounted) {
      return;
    }

    final purged =
        await context.read<AppProvider>().purgeRecentlyDeletedNote(note.id);
    if (!mounted) {
      return;
    }
    if (purged) {
      SnackBarUtils.showSuccess(context, l10n?.notePurged ?? '已彻底删除');
    } else {
      SnackBarUtils.showError(
        context,
        l10n?.deleteFailedRetry ?? '删除失败，请重试',
      );
    }
    await _load();
  }

  Future<void> _purgeAll() async {
    final l10n = AppLocalizationsSimple.of(context);
    final confirmed = await _confirm(
      title: l10n?.purgeAllTitle ?? '清空最近删除',
      content: l10n?.purgeAllMessage(_notes.length) ??
          '最近删除中的 ${_notes.length} 条笔记将被永久删除，无法恢复。',
      confirmText: l10n?.purgeAllAction ?? '全部删除',
    );
    if (confirmed != true || !mounted) {
      return;
    }

    final removed =
        await context.read<AppProvider>().purgeAllRecentlyDeletedNotes();
    if (!mounted) {
      return;
    }
    SnackBarUtils.showSuccess(
      context,
      l10n?.purgeAllSuccess(removed) ?? '已彻底删除 $removed 条笔记',
    );
    await _load();
  }

  Future<bool?> _confirm({
    required String title,
    required String content,
    required String confirmText,
  }) =>
      showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(title),
          content: Text(content),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(AppLocalizationsSimple.of(context)?.cancel ?? '取消'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
              ),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(confirmText),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizationsSimple.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n?.recentlyDeleted ?? '最近删除'),
        centerTitle: true,
        actions: [
          if (_notes.isNotEmpty)
            IconButton(
              tooltip: l10n?.emptyTrashAction ?? '清空',
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: _purgeAll,
            ),
        ],
      ),
      body: _buildBody(theme),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_notes.isEmpty) {
      final l10n = AppLocalizationsSimple.of(context);
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.delete_outline,
              size: 56,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text(
              l10n?.recentlyDeletedEmpty ?? '最近删除是空的',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              l10n?.recentlyDeletedRetention(
                    RecentlyDeletedScreen.retention.inDays,
                  ) ??
                  '删除的笔记会在这里保留 '
                      '${RecentlyDeletedScreen.retention.inDays} 天',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: _notes.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final note = _notes[index];
          return _buildNoteItem(note, theme);
        },
      ),
    );
  }

  Widget _buildNoteItem(Note note, ThemeData theme) {
    final l10n = AppLocalizationsSimple.of(context);
    final preview = _previewText(note.content);
    final deletedAt = note.deletedAt;
    final String subtitle;
    if (deletedAt == null) {
      subtitle = l10n?.deletedAtUnknown ?? '删除时间未知';
    } else {
      final formatted = TimeUtils.formatDateTime(deletedAt);
      final label = l10n?.deletedAtLabel(formatted) ?? '删除于 $formatted';
      final relative =
          l10n?.relativeTime(deletedAt) ?? TimeUtils.getRelativeTime(deletedAt);
      final wrapped = l10n?.relativeTimeInParens(relative) ?? '（$relative）';
      subtitle = '$label$wrapped';
    }

    return ListTile(
      isThreeLine: true,
      title: Text(
        preview.isEmpty ? (l10n?.untitledNote ?? '无标题笔记') : preview,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 2),
          Text(subtitle, style: theme.textTheme.bodySmall),
          const SizedBox(height: 2),
          Text(
            l10n?.noteCharCount(note.content.length) ??
                '共 ${note.content.length} 字',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: l10n?.restoreAction ?? '恢复',
            icon: const Icon(Icons.restore),
            onPressed: () => _restore(note),
          ),
          IconButton(
            tooltip: l10n?.purgeForever ?? '彻底删除',
            icon: Icon(
              Icons.delete_forever_outlined,
              color: theme.colorScheme.error,
            ),
            onPressed: () => _purge(note),
          ),
        ],
      ),
    );
  }

  String _previewText(String content) {
    for (final line in content.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        continue;
      }
      return trimmed.replaceFirst(RegExp(r'^#{1,6}\s*'), '');
    }
    return '';
  }
}
