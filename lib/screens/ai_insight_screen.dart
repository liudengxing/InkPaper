import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:inkpaper/l10n/app_localizations_simple.dart';
import 'package:inkpaper/models/insight_lens.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/providers/app_provider.dart';
import 'package:inkpaper/services/ai_insight_service.dart';
import 'package:inkpaper/themes/app_theme.dart';
import 'package:inkpaper/utils/snackbar_utils.dart';
import 'package:inkpaper/widgets/sidebar.dart';
import 'package:provider/provider.dart';

/// 洞察的分析范围。
enum _InsightRange {
  all(null),
  last30(30),
  last90(90),
  lastYear(365);

  const _InsightRange(this.days);

  final int? days;

  String label(AppLocalizationsSimple? l10n) => switch (this) {
        _InsightRange.all => l10n?.aiInsightScopeAll ?? '全部笔记',
        _InsightRange.last30 => l10n?.aiInsightScope30 ?? '最近 30 天',
        _InsightRange.last90 => l10n?.aiInsightScope90 ?? '最近 90 天',
        _InsightRange.lastYear => l10n?.aiInsightScopeYear ?? '最近一年',
      };
}

/// AI 洞察：选一个视角，让 AI 通读一批笔记，给出针对「这个人」的判断。
///
/// 和「问笔记」是互补的：问笔记要用户先有问题，洞察不需要——它主动找模式。
class AiInsightScreen extends StatefulWidget {
  const AiInsightScreen({super.key});

  @override
  State<AiInsightScreen> createState() => _AiInsightScreenState();
}

class _AiInsightScreenState extends State<AiInsightScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final InsightLensStore _store = const InsightLensStore();
  final AiInsightService _service = const AiInsightService();

  List<InsightLens> _lenses = const [];
  bool _loadingLenses = true;
  _InsightRange _range = _InsightRange.all;

  bool _generating = false;
  AiInsightResult? _result;
  InsightLens? _activeLens;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadLenses();
  }

  Future<void> _loadLenses() async {
    final lenses = await _store.load();
    if (!mounted) {
      return;
    }
    setState(() {
      _lenses = lenses;
      _loadingLenses = false;
    });
  }

  void _openDrawer() => _scaffoldKey.currentState?.openDrawer();

  List<Note> _filterNotes(List<Note> notes) {
    final days = _range.days;
    if (days == null) {
      return notes;
    }
    final cutoff = DateTime.now().subtract(Duration(days: days));
    return notes.where((note) => !note.displayTime.isBefore(cutoff)).toList();
  }

  Future<void> _generate(InsightLens lens) async {
    if (_generating) {
      return;
    }
    final appProvider = context.read<AppProvider>();
    // 取在 await 之前：后面要跨 async gap 用 l10n，不能再用 context。
    final l10n = AppLocalizationsSimple.of(context);
    setState(() {
      _generating = true;
      _activeLens = lens;
      _result = null;
      _error = null;
    });

    try {
      // 首页的 notes 是分页的，洞察要看全量，所以直接查库。
      final all = await appProvider.databaseService.getNotes();
      final scoped = _filterNotes(all);
      final result = await _service.generate(
        config: appProvider.appConfig,
        lens: lens,
        notes: scoped,
        scopeLabel: _range.label(l10n),
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _generating = false;
        if (result.isError) {
          _error = result.error;
          _result = null;
        } else {
          _result = result;
        }
      });
    } on Object catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _generating = false;
        _error = '生成失败：$e';
      });
    }
  }

  void _backToPicker() {
    setState(() {
      _result = null;
      _error = null;
      _activeLens = null;
    });
  }

  Future<void> _copyResult() async {
    final text = _result?.text;
    if (text == null || text.isEmpty) {
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) {
      return;
    }
    SnackBarUtils.showSuccess(context, '已复制');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizationsSimple.of(context);
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final backgroundColor =
        isDarkMode ? AppTheme.darkBackgroundColor : AppTheme.backgroundColor;
    final textColor =
        isDarkMode ? AppTheme.darkTextPrimaryColor : Colors.black87;
    final iconColor =
        isDarkMode ? AppTheme.primaryLightColor : AppTheme.primaryColor;
    final showResult = _result != null || _generating || _error != null;
    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: backgroundColor,
      // 遮罩留给抽屉自己的毛玻璃去做，不要压暗页面，
      // 否则 BackdropFilter 采样到的是遮罩色而不是内容。
      drawerScrimColor: Colors.transparent,
      drawer: const Sidebar(),
      drawerEdgeDragWidth: MediaQuery.of(context).size.width * 0.2,
      appBar: AppBar(
        backgroundColor: backgroundColor,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        automaticallyImplyLeading: false,
        leading: IconButton(
          icon: Icon(Icons.menu_rounded, color: iconColor),
          onPressed: _openDrawer,
          tooltip: '菜单',
        ),
        centerTitle: true,
        title: Text(
          l10n?.aiInsight ?? 'AI 洞察',
          style: TextStyle(
            color: textColor,
            fontWeight: FontWeight.w600,
            fontSize: 18,
          ),
        ),
        actions: [
          if (showResult)
            IconButton(
              tooltip: '返回',
              icon: Icon(Icons.close_rounded, color: iconColor),
              onPressed: _backToPicker,
            ),
          const SizedBox(width: 4),
        ],
      ),
      body: showResult ? _buildResultArea(l10n) : _buildPicker(l10n),
    );
  }

  Widget _buildPicker(AppLocalizationsSimple? l10n) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        _buildScopeCard(l10n),
        const SizedBox(height: 24),
        Text(
          l10n?.aiInsightPickLens ?? '选择一个视角，开始洞察',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '同一个你，换个视角看，会得出不同的结论。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 14),
        if (_loadingLenses)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 40),
            child: Center(child: CircularProgressIndicator()),
          )
        else ...[
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 1.02,
            children: [
              for (final lens in _lenses)
                _buildLensCard(lens, onLongPress: () => _showLensMenu(lens)),
              _buildAddLensCard(l10n),
            ],
          ),
          const SizedBox(height: 20),
          Text(
            '长按视角卡片可以查看或修改它的提示词。',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildScopeCard(AppLocalizationsSimple? l10n) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: 0.4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.tune_rounded,
                size: 18,
                color: colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Text(
                l10n?.aiInsightScope ?? '分析范围',
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final range in _InsightRange.values)
                ChoiceChip(
                  label: Text(range.label(l10n)),
                  selected: _range == range,
                  onSelected: _generating
                      ? null
                      : (_) => setState(() => _range = range),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '会读取本地笔记的正文（图片和音视频不参与），只在生成时发送给已配置的 AI 服务。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.85),
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLensCard(InsightLens lens, {required VoidCallback onLongPress}) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () => _generate(lens),
      onLongPress: onLongPress,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 13, 14, 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
          border: Border.all(
            color: colorScheme.outlineVariant.withValues(alpha: 0.45),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(lens.icon.icon, size: 20, color: colorScheme.primary),
                const Spacer(),
                if (lens.edited)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: colorScheme.primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '已改',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: colorScheme.primary,
                        fontSize: 10,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              lens.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 5),
            Expanded(
              child: Text(
                lens.description,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  height: 1.35,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'by ${lens.authorLabel}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                fontSize: 10,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAddLensCard(AppLocalizationsSimple? l10n) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () => _editLensDialog(l10n),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: colorScheme.outlineVariant.withValues(alpha: 0.6),
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.add_rounded,
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
            const SizedBox(height: 8),
            Text(
              l10n?.aiInsightNewLens ?? '新建视角',
              style: theme.textTheme.labelLarge?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '写一段自己的提示词',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResultArea(AppLocalizationsSimple? l10n) {
    if (_generating) {
      return _buildGeneratingView(l10n);
    }
    if (_error != null) {
      return _buildErrorView(l10n);
    }
    return _buildResultView(l10n);
  }

  Widget _buildGeneratingView(AppLocalizationsSimple? l10n) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 34,
              height: 34,
              child: CircularProgressIndicator(strokeWidth: 2.6),
            ),
            const SizedBox(height: 20),
            Text(
              l10n?.aiInsightGenerating ?? '正在通读你的笔记…',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '用「${_activeLens?.name ?? ''}」这个视角。笔记多的时候要 10-30 秒。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorView(AppLocalizationsSimple? l10n) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off_rounded,
              size: 36,
              color: colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 14),
            Text(
              _error ?? '生成失败',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                OutlinedButton(
                  onPressed: _backToPicker,
                  child: Text(l10n?.aiInsightSwitchLens ?? '换个视角'),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: _activeLens == null
                      ? null
                      : () => _generate(_activeLens!),
                  child: Text(l10n?.aiInsightRegenerate ?? '重试'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResultView(AppLocalizationsSimple? l10n) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final result = _result!;
    final lens = _activeLens;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
      children: [
        Row(
          children: [
            Icon(
              lens?.icon.icon ?? Icons.auto_awesome_outlined,
              size: 18,
              color: colorScheme.primary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                lens?.name ?? '洞察',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Text(
              '${result.noteCount} 条笔记',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        if (result.truncated)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '共 ${result.totalCandidates} 条有文字内容，模型这次看的是最近 ${result.noteCount} 条。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
              ),
            ),
          ),
        const SizedBox(height: 14),
        Divider(height: 1, color: colorScheme.outlineVariant),
        const SizedBox(height: 16),
        SelectableText.rich(
          TextSpan(
            children: _buildInsightSpans(
              result.text,
              theme.textTheme.bodyMedium ?? const TextStyle(fontSize: 15),
              colorScheme,
            ),
          ),
          style: (theme.textTheme.bodyMedium ?? const TextStyle()).copyWith(
            fontSize: 15,
            height: 1.72,
            color: colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 28),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            FilledButton.tonalIcon(
              onPressed: _copyResult,
              icon: const Icon(Icons.copy_rounded, size: 18),
              label: Text(l10n?.aiInsightCopy ?? '复制全文'),
            ),
            OutlinedButton.icon(
              onPressed: lens == null ? null : () => _generate(lens),
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: Text(l10n?.aiInsightRegenerate ?? '重新生成'),
            ),
            OutlinedButton.icon(
              onPressed: _backToPicker,
              icon: const Icon(Icons.swap_horiz_rounded, size: 18),
              label: Text(l10n?.aiInsightSwitchLens ?? '换个视角'),
            ),
          ],
        ),
        const SizedBox(height: 18),
        Text(
          '洞察只基于你自己的记录，不是事实判断。有共鸣的部分可以继续想，不认同的部分直接略过。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant.withValues(alpha: 0.75),
            height: 1.45,
          ),
        ),
      ],
    );
  }

  /// 把正文里的 `[12]` 渲染成带色的小标记，方便对照上方笔记编号。
  List<InlineSpan> _buildInsightSpans(
    String text,
    TextStyle base,
    ColorScheme colorScheme,
  ) {
    final spans = <InlineSpan>[];
    final regex = RegExp(r'\[(\d+)\]');
    var last = 0;
    for (final match in regex.allMatches(text)) {
      if (match.start > last) {
        spans.add(TextSpan(text: text.substring(last, match.start)));
      }
      spans.add(
        TextSpan(
          text: ' [${match.group(1)}]',
          style: base.copyWith(
            fontSize: (base.fontSize ?? 15) - 2.5,
            color: colorScheme.primary.withValues(alpha: 0.85),
            fontWeight: FontWeight.w600,
          ),
        ),
      );
      last = match.end;
    }
    if (last < text.length) {
      spans.add(TextSpan(text: text.substring(last)));
    }
    return spans;
  }

  Future<void> _showLensMenu(InsightLens lens) async {
    final l10n = AppLocalizationsSimple.of(context);
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.code_rounded),
              title: Text(l10n?.aiInsightViewPrompt ?? '查看提示词'),
              onTap: () => Navigator.of(sheetContext).pop('view'),
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: Text(l10n?.aiInsightEditPrompt ?? '编辑提示词'),
              onTap: () => Navigator.of(sheetContext).pop('edit'),
            ),
            if (!lens.builtIn)
              ListTile(
                leading: const Icon(Icons.delete_outline_rounded),
                title: const Text('删除这个视角'),
                onTap: () => Navigator.of(sheetContext).pop('delete'),
              ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) {
      return;
    }
    switch (action) {
      case 'view':
        await _showPromptDialog(lens);
        break;
      case 'edit':
        await _editLensDialog(l10n, lens: lens);
        break;
      case 'delete':
        await _store.deleteCustom(lens.id);
        await _loadLenses();
        if (!mounted) {
          return;
        }
        SnackBarUtils.showInfo(context, '已删除「${lens.name}」');
        break;
    }
  }

  Future<void> _showPromptDialog(InsightLens lens) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('${lens.name} · 提示词'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(
              lens.prompt.trim(),
              style: const TextStyle(fontSize: 13, height: 1.55),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _editLensDialog(
    AppLocalizationsSimple? l10n, {
    InsightLens? lens,
  }) async {
    final isNew = lens == null;
    final canRename = isNew || !lens.builtIn;
    final nameController = TextEditingController(text: lens?.name ?? '');
    final descController = TextEditingController(text: lens?.description ?? '');
    final promptController = TextEditingController(text: lens?.prompt ?? '');
    var saving = false;

    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(
            isNew ? (l10n?.aiInsightNewLens ?? '新建视角') : '编辑视角',
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: nameController,
                    enabled: canRename,
                    maxLength: 12,
                    decoration: const InputDecoration(
                      labelText: '名称',
                      counterText: '',
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: descController,
                    enabled: canRename,
                    maxLength: 40,
                    decoration: const InputDecoration(
                      labelText: '一句话描述',
                      counterText: '',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: promptController,
                    minLines: 8,
                    maxLines: 14,
                    style: const TextStyle(fontSize: 13, height: 1.5),
                    decoration: const InputDecoration(
                      labelText: '提示词',
                      alignLabelWithHint: true,
                      helperText: '写「怎么分析」，不用写格式和引用规则，那些是固定的。',
                    ),
                  ),
                  if (!isNew && lens.builtIn)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: () async {
                          final original = builtInInsightLenses.firstWhere(
                            (item) => item.id == lens.id,
                          );
                          promptController.text = original.prompt;
                        },
                        child: const Text('恢复默认提示词'),
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed:
                  saving ? null : () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: saving
                  ? null
                  : () async {
                      final prompt = promptController.text.trim();
                      if (prompt.length < 20) {
                        SnackBarUtils.showWarning(
                          context,
                          '提示词太短了，至少写 20 个字',
                        );
                        return;
                      }
                      setDialogState(() => saving = true);
                      if (isNew) {
                        if (nameController.text.trim().isEmpty) {
                          setDialogState(() => saving = false);
                          SnackBarUtils.showWarning(context, '给它起个名字');
                          return;
                        }
                        await _store.addCustom(
                          name: nameController.text,
                          description: descController.text,
                          prompt: prompt,
                        );
                      } else if (lens.builtIn) {
                        await _store.saveBuiltInPrompt(lens.id, prompt);
                      } else {
                        await _store.updateCustom(
                          lens.copyWith(
                            name: nameController.text.trim(),
                            description: descController.text.trim(),
                            prompt: prompt,
                          ),
                        );
                      }
                      if (dialogContext.mounted) {
                        Navigator.of(dialogContext).pop(true);
                      }
                    },
              child: saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('保存'),
            ),
          ],
        ),
      ),
    );

    nameController.dispose();
    descController.dispose();
    promptController.dispose();

    if (saved ?? false) {
      await _loadLenses();
      if (!mounted) {
        return;
      }
      SnackBarUtils.showSuccess(context, '已保存');
    }
  }
}
