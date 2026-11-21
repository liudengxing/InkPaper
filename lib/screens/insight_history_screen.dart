import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:inkpaper/services/insight_history_service.dart';
import 'package:inkpaper/themes/app_theme.dart';
import 'package:inkpaper/utils/insight_text_spans.dart';
import 'package:inkpaper/utils/note_timestamp_format.dart';
import 'package:inkpaper/utils/snackbar_utils.dart';

/// 洞察历史列表。
///
/// 每生成成功一份洞察就自动落一条，所以这里不需要「保存」按钮——它的
/// 定位是回看，不是收藏夹。
class InsightHistoryScreen extends StatefulWidget {
  const InsightHistoryScreen({super.key});

  @override
  State<InsightHistoryScreen> createState() => _InsightHistoryScreenState();
}

class _InsightHistoryScreenState extends State<InsightHistoryScreen> {
  final InsightHistoryService _service = InsightHistoryService.instance;
  List<InsightReportEntry> _entries = const <InsightReportEntry>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final entries = await _service.list();
    if (!mounted) {
      return;
    }
    setState(() {
      _entries = entries;
      _loading = false;
    });
  }

  Future<void> _open(InsightReportEntry entry) async {
    final deleted = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => InsightReportScreen(entryId: entry.id),
      ),
    );
    if (deleted ?? false) {
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final backgroundColor =
        isDarkMode ? AppTheme.darkBackgroundColor : AppTheme.backgroundColor;
    final textColor =
        isDarkMode ? AppTheme.darkTextPrimaryColor : AppTheme.textPrimaryColor;
    final iconColor =
        isDarkMode ? AppTheme.primaryLightColor : AppTheme.primaryColor;
    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(
        backgroundColor: backgroundColor,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_rounded, color: iconColor),
          onPressed: () => Navigator.of(context).pop(),
          tooltip: '返回',
        ),
        centerTitle: true,
        title: Text(
          '洞察历史',
          style: TextStyle(
            color: textColor,
            fontWeight: FontWeight.w600,
            fontSize: 18,
          ),
        ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_entries.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 48),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.history_rounded,
                size: 32,
                color: muted.withValues(alpha: 0.4),
              ),
              const SizedBox(height: 14),
              Text(
                '还没有历史记录',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '每次生成成功都会自动存在这里，换手机前记得先备份。',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 12.5,
                  height: 1.6,
                  color: muted.withValues(alpha: 0.75),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      itemCount: _entries.length,
      separatorBuilder: (context, index) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final entry = _entries[index];
        return _HistoryCard(
          entry: entry,
          onTap: () => _open(entry),
        );
      },
    );
  }
}

class _HistoryCard extends StatelessWidget {
  const _HistoryCard({required this.entry, required this.onTap});

  final InsightReportEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final muted = theme.colorScheme.onSurfaceVariant;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: isDark ? AppTheme.darkCardColor : Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: isDark
            ? const []
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.035),
                  blurRadius: 12,
                  offset: const Offset(0, 2),
                ),
              ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        entry.lensName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Text(
                      formatNoteTimestamp(entry.createdAt),
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: 11.5,
                        color: muted.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  entry.preview,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: 12.5,
                    height: 1.65,
                    color: muted.withValues(alpha: 0.95),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  '${entry.scopeLabel} · ${entry.noteCount} 条笔记',
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontSize: 11,
                    color: muted.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 单份报告的回看页：排版与洞察结果页一致。
class InsightReportScreen extends StatefulWidget {
  const InsightReportScreen({required this.entryId, super.key});

  final int entryId;

  @override
  State<InsightReportScreen> createState() => _InsightReportScreenState();
}

class _InsightReportScreenState extends State<InsightReportScreen> {
  final InsightHistoryService _service = InsightHistoryService.instance;
  InsightReportEntry? _entry;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final entry = await _service.get(widget.entryId);
    if (!mounted) {
      return;
    }
    setState(() {
      _entry = entry;
      _loading = false;
    });
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除这份洞察？'),
        content: const Text('删除后无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    await _service.delete(widget.entryId);
    if (!mounted) {
      return;
    }
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDarkMode = theme.brightness == Brightness.dark;
    final backgroundColor =
        isDarkMode ? AppTheme.darkBackgroundColor : AppTheme.backgroundColor;
    final textColor =
        isDarkMode ? AppTheme.darkTextPrimaryColor : AppTheme.textPrimaryColor;
    final iconColor =
        isDarkMode ? AppTheme.primaryLightColor : AppTheme.primaryColor;
    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(
        backgroundColor: backgroundColor,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_rounded, color: iconColor),
          onPressed: () => Navigator.of(context).pop(),
          tooltip: '返回',
        ),
        centerTitle: true,
        title: Text(
          _entry?.lensName ?? '洞察',
          style: TextStyle(
            color: textColor,
            fontWeight: FontWeight.w600,
            fontSize: 18,
          ),
        ),
        actions: [
          if (_entry != null)
            IconButton(
              tooltip: '复制',
              icon: Icon(Icons.copy_rounded, color: iconColor),
              onPressed: _copy,
            ),
          if (_entry != null)
            IconButton(
              tooltip: '删除',
              icon: Icon(Icons.delete_outline_rounded, color: iconColor),
              onPressed: _delete,
            ),
          const SizedBox(width: 4),
        ],
      ),
      body: _buildBody(theme),
    );
  }

  Future<void> _copy() async {
    final entry = _entry;
    if (entry == null) {
      return;
    }
    await Clipboard.setData(ClipboardData(text: entry.content));
    if (!mounted) {
      return;
    }
    SnackBarUtils.showSuccess(context, '已复制');
  }

  Widget _buildBody(ThemeData theme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final entry = _entry;
    final muted = theme.colorScheme.onSurfaceVariant;
    if (entry == null) {
      return Center(
        child: Text(
          '这条记录已经不在了',
          style: theme.textTheme.bodyMedium?.copyWith(color: muted),
        ),
      );
    }
    final colorScheme = theme.colorScheme;
    final base = (theme.textTheme.bodyMedium ?? const TextStyle()).copyWith(
      fontSize: 15.5,
      height: 1.85,
      color: colorScheme.onSurface.withValues(alpha: 0.92),
    );
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 48),
      children: [
        Text(
          '${formatNoteTimestamp(entry.createdAt)} · ${entry.scopeLabel} · '
          '${entry.noteCount} 条笔记',
          style: theme.textTheme.labelSmall?.copyWith(
            fontSize: 11.5,
            color: muted.withValues(alpha: 0.7),
          ),
        ),
        const SizedBox(height: 18),
        Align(
          alignment: Alignment.centerLeft,
          child: Container(
            width: 40,
            height: 1.5,
            color: colorScheme.primary.withValues(alpha: 0.25),
          ),
        ),
        const SizedBox(height: 20),
        SelectableText.rich(
          TextSpan(
            children: buildInsightSpans(entry.content, base, colorScheme),
          ),
          style: base,
        ),
      ],
    );
  }
}
