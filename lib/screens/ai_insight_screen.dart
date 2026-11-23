import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:inkpaper/l10n/app_localizations_simple.dart';
import 'package:inkpaper/models/insight_lens.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/providers/app_provider.dart';
import 'package:inkpaper/screens/insight_history_screen.dart';
import 'package:inkpaper/services/ai_insight_service.dart';
import 'package:inkpaper/services/insight_history_service.dart';
import 'package:inkpaper/themes/app_theme.dart';
import 'package:inkpaper/utils/insight_text_spans.dart';
import 'package:inkpaper/utils/snackbar_utils.dart';
import 'package:inkpaper/widgets/insight_live_output.dart';
import 'package:inkpaper/widgets/insight_reasoning_panel.dart';
import 'package:inkpaper/widgets/insight_source_sheet.dart';
import 'package:inkpaper/widgets/insight_summary_card.dart';
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
///
/// 视觉按 flomo 5.5.5 实测（activity_ai_insight.xml / item_insight_template_card）：
/// 页面底 #F9F9F9、卡片纯白 12dp 圆角无描边、大标题 21sp、次要文字 #949494、
/// 模板一行一条（图标 36dp 槽 + 标题描述 + 箭头）、行间距 10、主按钮 48 高。
/// 唯一不抄的是玻璃——纯色底上真玻璃只会发灰（LESSONS §5.5）。
class AiInsightScreen extends StatefulWidget {
  const AiInsightScreen({super.key});

  @override
  State<AiInsightScreen> createState() => _AiInsightScreenState();
}

class _AiInsightScreenState extends State<AiInsightScreen> {
  // ── 视觉 token（对齐 flomo 实测值）────────────────────────────────
  static const _pagePadding = EdgeInsets.fromLTRB(16, 8, 16, 40);
  static const _cardRadius = 12.0;
  static const _rowGap = 10.0;

  /// 行首图标占位：对齐 flomo 模板行的 36dp 图标槽。
  static const _iconSlot = 36.0;
  static const _switchDuration = Duration(milliseconds: 240);

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

  InsightLiveOutputController? _liveOutput;
  final InsightRefRecognizers _refRecognizers = InsightRefRecognizers();

  @override
  void initState() {
    super.initState();
    _loadLenses();
  }

  @override
  void dispose() {
    _liveOutput?.dispose();
    _refRecognizers.dispose();
    super.dispose();
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
    final liveOutput = InsightLiveOutputController();
    _liveOutput?.dispose();
    setState(() {
      _generating = true;
      _liveOutput = liveOutput;
      _activeLens = lens;
      _result = null;
      _error = null;
    });
    // 新一批笔记，旧编号的含义已经变了，角标的 recognizer 必须重建。
    _refRecognizers.clear();

    try {
      // 首页的 notes 是分页的，洞察要看全量，所以直接查库。
      final all = await appProvider.databaseService.getNotes();
      final scoped = _filterNotes(all);
      final result = await _service.generate(
        config: appProvider.appConfig,
        lens: lens,
        notes: scoped,
        scopeLabel: _range.label(l10n),
        onProgress: (delta, {required reasoning}) {
          if (mounted) {
            liveOutput.append(delta, reasoning: reasoning);
          }
        },
        onStatus: (message) {
          if (!mounted) {
            return;
          }
          liveOutput.updateStatus(message);
        },
      );
      if (!mounted) {
        return;
      }
      liveOutput.stop();
      setState(() {
        _generating = false;
        if (result.isError) {
          _error = result.error;
          _result = null;
        } else {
          _result = result;
        }
      });
      if (!result.isError) {
        // 成功就落一份历史。不 await、失败只打日志：写盘慢不该拖住
        // 结果页的第一帧，写失败也不该把已经生成的报告判成失败。
        unawaited(
          InsightHistoryService.instance.save(
            lensId: lens.id,
            lensName: lens.name,
            scopeLabel: _range.label(l10n),
            noteCount: result.noteCount,
            content: result.text,
            title: result.title,
            summary: result.summary,
            reasoning: result.reasoning,
            // 存 id 而不是正文快照：回看时点开就是这条笔记当前的版本。
            sourceIds: [
              for (final source in result.sources) source.noteId,
            ],
          ),
        );
      }
    } on Object catch (e) {
      liveOutput.stop();
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

  /// 正文样式：角标的字号是按这个基底算的（-3.5），两处必须取同一个值。
  static TextStyle _bodyStyle(ThemeData theme) =>
      (theme.textTheme.bodyMedium ?? const TextStyle()).copyWith(
        fontSize: 15.5,
        height: 1.85,
        color: theme.colorScheme.onSurface.withValues(alpha: 0.92),
      );

  /// 点正文里的 `[12]`：当场把第 12 条笔记的原文摊开。
  ///
  /// 不跳详情页——用户正在读一句判断，跳到别处会丢掉阅读位置，而且这里要的
  /// 只是「这句话有没有依据」这一个验证动作。
  void _showSource(AiInsightResult result, int index) {
    final source = result.sourceAt(index);
    if (source == null) {
      return;
    }
    unawaited(
      showInsightSourceSheet(
        context,
        index: source.index,
        time: source.createdAt,
        tags: source.tags,
        text: source.text,
        truncated: source.truncated,
        imagePaths: source.imagePaths,
        serverUrl: context.read<AppProvider>().appConfig.memosApiUrl,
      ),
    );
  }

  Future<void> _copyResult() async {
    final result = _result;
    if (result == null || result.text.isEmpty) {
      return;
    }
    // 标题 + 摘要也带上：粘到别处时，读的人需要先看结论要点再看长文。
    final buffer = StringBuffer();
    if (result.title.isNotEmpty) {
      buffer.writeln(result.title);
      buffer.writeln();
    }
    if (result.summary.isNotEmpty) {
      buffer.writeln('【分析摘要】');
      buffer.writeln(result.summary);
      buffer.writeln();
    }
    buffer.write(result.text);
    final text = buffer.toString();
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
        isDarkMode ? AppTheme.darkTextPrimaryColor : AppTheme.textPrimaryColor;
    final iconColor =
        isDarkMode ? AppTheme.primaryLightColor : AppTheme.primaryColor;
    final showResult = _result != null || _generating || _error != null;
    // 结果页是「洞察页里的第二层」，不是独立页面：系统返回应该退回视角
    // 列表，而不是一路退到笔记列表。生成中不拦——用户想中断就让他走。
    final canLeavePage = _result == null && _error == null;
    return PopScope(
      canPop: canLeavePage,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          _backToPicker();
        }
      },
      child: Scaffold(
        key: _scaffoldKey,
        backgroundColor: backgroundColor,
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
        body: AnimatedSwitcher(
          duration: _switchDuration,
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          // 进出两页叠在一起做交叉淡入，避免切换瞬间页面高度塌一下
          layoutBuilder: (current, previous) => Stack(
            alignment: Alignment.topCenter,
            children: [...previous, if (current != null) current],
          ),
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.02),
                end: Offset.zero,
              ).animate(animation),
              child: child,
            ),
          ),
          child: KeyedSubtree(
            // 生成中 → 结果也算一次切换，重新渐入一遍
            key: ValueKey(
              showResult
                  ? (_generating
                      ? 'gen'
                      : (_error != null ? 'error' : 'result'))
                  : 'picker',
            ),
            child: showResult ? _buildResultArea(l10n) : _buildPicker(l10n),
          ),
        ),
      ),
    );
  }

  Widget _buildPicker(AppLocalizationsSimple? l10n) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final muted = colorScheme.onSurfaceVariant;
    return ListView(
      padding: _pagePadding,
      children: [
        // 分析范围 + 历史入口并排：历史是「回顾已经发生过的事」，
        // 和范围选择同属「这次看哪些」的上下文，放在一行里不打断列表。
        Row(
          children: [
            Expanded(child: _buildScopeRow(l10n)),
            const SizedBox(width: 10),
            _buildHistoryEntry(),
          ],
        ),
        const SizedBox(height: 26),
        Text(
          l10n?.aiInsightPickLens ?? '选择一个视角，开始洞察',
          style: theme.textTheme.titleMedium?.copyWith(
            fontSize: 21,
            height: 1.25,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.2,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '同一个你，换个视角看，会得出不同的结论。',
          style: theme.textTheme.bodySmall?.copyWith(
            fontSize: 12.5,
            height: 1.5,
            color: muted.withValues(alpha: 0.85),
          ),
        ),
        const SizedBox(height: 16),
        if (_loadingLenses)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 40),
            child: Center(child: CircularProgressIndicator()),
          )
        else ...[
          // flomo 的模板是纵向一条一条排的（一行一个视角），不是双列方块。
          // 行式列表还能让描述写满整行宽度，不再被半宽卡切碎。
          for (var i = 0; i < _lenses.length; i++) ...[
            if (i > 0) const SizedBox(height: _rowGap),
            _buildLensRow(
              _lenses[i],
              onLongPress: () => _showLensMenu(_lenses[i]),
            ),
          ],
          const SizedBox(height: _rowGap),
          _buildAddLensRow(l10n),
          const SizedBox(height: 20),
          Text(
            '长按视角可以查看或修改它的提示词。',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              fontSize: 11.5,
              color: muted.withValues(alpha: 0.7),
            ),
          ),
        ],
      ],
    );
  }

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;

  /// 卡片底：浅色纯白，深色用卡片色。不用 surfaceContainerHighest ——
  /// 深色下它偏蓝，和 flomo 的中性灰不是一回事。
  Color get _cardFill => _isDark ? AppTheme.darkCardColor : Colors.white;

  List<BoxShadow> get _cardShadow => _isDark
      ? const []
      : [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.035),
            blurRadius: 12,
            offset: const Offset(0, 2),
          ),
        ];

  /// 所有行共用的白卡外壳：12dp 圆角 + 极浅阴影，点按有水波纹。
  Widget _rowCard({
    required Widget child,
    required VoidCallback? onTap,
    VoidCallback? onLongPress,
  }) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: _cardFill,
        borderRadius: BorderRadius.circular(_cardRadius),
        boxShadow: _cardShadow,
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(_cardRadius),
        child: InkWell(
          borderRadius: BorderRadius.circular(_cardRadius),
          onTap: onTap,
          onLongPress: onLongPress,
          child: child,
        ),
      ),
    );
  }

  /// 范围选择：flomo 的分组设置行（一行、右侧当前值 + 箭头）。
  /// 不用一排 ChoiceChip —— 四个选项在小屏会折成两排，视觉很碎。
  Widget _buildScopeRow(AppLocalizationsSimple? l10n) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return _rowCard(
      onTap: _generating ? null : () => _showRangePicker(l10n),
      child: SizedBox(
        height: 52,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Icon(Icons.tune_rounded, size: 16, color: muted),
              const SizedBox(width: 10),
              Text(
                l10n?.aiInsightScope ?? '分析范围',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const Spacer(),
              Text(
                _range.label(l10n),
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontSize: 14,
                  color: muted,
                ),
              ),
              const SizedBox(width: 2),
              Icon(Icons.chevron_right_rounded, size: 18, color: muted),
            ],
          ),
        ),
      ),
    );
  }

  /// 「历史」入口：和范围行同高同圆角，宽度只够图标 + 两个字。
  ///
  /// 不做角标计数——每次进页面都要异步查一次，为了一个数字多一次读库
  /// 不值得；点进去看就是了。
  Widget _buildHistoryEntry() {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return SizedBox(
      width: 88,
      height: 52,
      child: _rowCard(
        onTap: () => Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => const InsightHistoryScreen(),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.history_rounded, size: 16, color: muted),
            const SizedBox(width: 6),
            Text(
              '历史',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showRangePicker(AppLocalizationsSimple? l10n) async {
    final picked = await showModalBottomSheet<_InsightRange>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        final primaryColor = Theme.of(sheetContext).colorScheme.primary;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final range in _InsightRange.values)
                ListTile(
                  title: Text(range.label(l10n)),
                  trailing: _range == range
                      ? Icon(Icons.check_rounded, color: primaryColor)
                      : null,
                  onTap: () => Navigator.of(sheetContext).pop(range),
                ),
            ],
          ),
        );
      },
    );
    if (picked != null && mounted && picked != _range) {
      setState(() => _range = picked);
    }
  }

  /// 视角行：flomo 的模板是一行一个（图标 → 标题/描述 → 箭头），
  /// 不是双列方块。行式排布也让描述能用满整行宽度。
  Widget _buildLensRow(InsightLens lens, {required VoidCallback onLongPress}) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final muted = colorScheme.onSurfaceVariant;
    return _rowCard(
      onTap: () => _generate(lens),
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(15, 13, 12, 13),
        child: Row(
          children: [
            SizedBox(
              width: _iconSlot,
              child: Icon(
                lens.icon.icon,
                size: 22,
                color: colorScheme.primary,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          lens.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontSize: 15.5,
                            height: 1.2,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -0.1,
                          ),
                        ),
                      ),
                      // 「已改」只留一个圆点：行里再加色块就太吵了
                      if (lens.edited) ...[
                        const SizedBox(width: 6),
                        Container(
                          width: 5,
                          height: 5,
                          decoration: BoxDecoration(
                            color: colorScheme.primary.withValues(alpha: 0.6),
                            shape: BoxShape.circle,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    lens.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 12.5,
                      height: 1.45,
                      color: muted.withValues(alpha: 0.85),
                    ),
                  ),
                  // 行里不回署名：内置视角全是「by InkPaper」，纯噪音；
                  // 自定义视角本来就只有自己建的，也用不着标「by 我」。
                ],
              ),
            ),
            const SizedBox(width: 6),
            Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: muted.withValues(alpha: 0.45),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAddLensRow(AppLocalizationsSimple? l10n) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return _rowCard(
      onTap: () => _editLensDialog(l10n),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(15, 14, 12, 14),
        child: Row(
          children: [
            SizedBox(
              width: _iconSlot,
              child: Icon(
                Icons.add_rounded,
                size: 20,
                color: muted.withValues(alpha: 0.5),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                l10n?.aiInsightNewLens ?? '新建视角',
                style: theme.textTheme.labelLarge?.copyWith(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: muted,
                ),
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: muted.withValues(alpha: 0.45),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResultArea(AppLocalizationsSimple? l10n) {
    if (_generating) {
      return InsightLiveOutput(controller: _liveOutput!);
    }
    if (_error != null) {
      return _buildErrorView(l10n);
    }
    return _buildResultView(l10n);
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
    final muted = colorScheme.onSurfaceVariant;
    final result = _result!;
    final lens = _activeLens;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
      children: [
        // 小标 + 条数，给下面的大标题做语境。
        // 模型给了标题时，大标题就是标题句，视角名降到小标里（否则视角名就
        // 丢了）；模型没给标题时，大标题退回视角名，小标只写 AI Insight，
        // 两行都写视角名等于说了两遍。
        Row(
          children: [
            Expanded(
              child: Text(
                result.title.isEmpty
                    ? 'AI Insight'
                    : 'AI Insight · ${lens?.name ?? '洞察'}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.6,
                  color: colorScheme.primary.withValues(alpha: 0.85),
                ),
              ),
            ),
            Text(
              '${result.noteCount} 条笔记',
              style: theme.textTheme.labelSmall?.copyWith(
                fontSize: 11.5,
                color: muted.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          result.title.isEmpty ? (lens?.name ?? '洞察') : result.title,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontSize: 21,
            height: 1.32,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.2,
          ),
        ),
        if (result.truncated)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '库内共 ${result.totalCandidates} 条可分析的笔记，按时间加权抽取了其中 ${result.noteCount} 条。',
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 11.5,
                height: 1.5,
                color: muted.withValues(alpha: 0.75),
              ),
            ),
          ),
        if (result.summary.trim().isNotEmpty) ...[
          const SizedBox(height: 16),
          InsightSummaryCard(
            summary: result.summary.trim(),
            style: _bodyStyle(theme),
            recognizers: _refRecognizers,
            onTapRef: (index) => _showSource(result, index),
          ),
        ],
        if (result.reasoning.trim().isNotEmpty) ...[
          const SizedBox(height: 16),
          InsightReasoningPanel(reasoning: result.reasoning.trim()),
        ],
        const SizedBox(height: 20),
        // 一小段短线代替整条 Divider：断点更轻，不打断阅读
        Align(
          alignment: Alignment.centerLeft,
          child: Container(
            width: 40,
            height: 1.5,
            color: colorScheme.primary.withValues(alpha: 0.25),
          ),
        ),
        const SizedBox(height: 20),
        // 用 Text.rich 而不是 SelectableText：编辑控件里的 span recognizer
        // 不参与点击分发，角标就点不开了。复制全文有下面的按钮兼顾。
        Text.rich(
          TextSpan(
            children: buildInsightSpans(
              result.text,
              _bodyStyle(theme),
              colorScheme,
              recognizers: _refRecognizers,
              onTapRef: (index) => _showSource(result, index),
            ),
          ),
          style: _bodyStyle(theme),
        ),
        const SizedBox(height: 32),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonalIcon(
              onPressed: _copyResult,
              icon: const Icon(Icons.copy_rounded, size: 18),
              label: Text(l10n?.aiInsightCopy ?? '复制全文'),
            ),
            TextButton.icon(
              onPressed: lens == null ? null : () => _generate(lens),
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: Text(l10n?.aiInsightRegenerate ?? '重新生成'),
            ),
            TextButton.icon(
              onPressed: _backToPicker,
              icon: const Icon(Icons.swap_horiz_rounded, size: 18),
              label: Text(l10n?.aiInsightSwitchLens ?? '换个视角'),
            ),
          ],
        ),
        const SizedBox(height: 20),
        Text(
          '洞察只基于你自己的记录，不是事实判断。有共鸣的部分可以继续想，不认同的部分直接略过。',
          style: theme.textTheme.bodySmall?.copyWith(
            fontSize: 11.5,
            height: 1.5,
            color: muted.withValues(alpha: 0.6),
          ),
        ),
      ],
    );
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
