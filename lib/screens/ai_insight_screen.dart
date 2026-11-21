import 'dart:async';

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

  // ── 流式生成时的实时内容 ─────────────────────────────────────────
  //
  // 回调是按 token 来的，token 级 setState 会把整页重建上千次；这里先攒进
  // buffer，由 140ms 的定时器统一刷一次，观感是「一行行往下长」而不是卡。
  final StringBuffer _liveReasoning = StringBuffer();
  final StringBuffer _liveContent = StringBuffer();
  String _liveReasoningText = '';
  String _liveContentText = '';
  Timer? _liveFlush;

  /// 结果页里「推理过程」是否展开（默认收起，想看再点）。
  bool _reasoningExpanded = false;

  @override
  void initState() {
    super.initState();
    _loadLenses();
  }

  @override
  void dispose() {
    _liveFlush?.cancel();
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
    setState(() {
      _generating = true;
      _activeLens = lens;
      _result = null;
      _error = null;
      _reasoningExpanded = false;
    });
    _startLiveFlush();

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
          if (reasoning) {
            _liveReasoning.write(delta);
          } else {
            _liveContent.write(delta);
          }
        },
      );
      if (!mounted) {
        return;
      }
      _stopLiveFlush();
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
      _stopLiveFlush();
      if (!mounted) {
        return;
      }
      setState(() {
        _generating = false;
        _error = '生成失败：$e';
      });
    }
  }

  /// 开始把流式 buffer 定时刷进界面。
  void _startLiveFlush() {
    _liveReasoning.clear();
    _liveContent.clear();
    _liveReasoningText = '';
    _liveContentText = '';
    _liveFlush?.cancel();
    _liveFlush = Timer.periodic(const Duration(milliseconds: 140), (_) {
      if (!mounted) {
        return;
      }
      final reasoning = _liveReasoning.toString();
      final content = _liveContent.toString();
      if (reasoning == _liveReasoningText && content == _liveContentText) {
        return;
      }
      setState(() {
        _liveReasoningText = reasoning;
        _liveContentText = content;
      });
    });
  }

  void _stopLiveFlush() {
    _liveFlush?.cancel();
    _liveFlush = null;
  }

  void _backToPicker() {
    setState(() {
      _result = null;
      _error = null;
      _activeLens = null;
      _reasoningExpanded = false;
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
        isDarkMode ? AppTheme.darkTextPrimaryColor : AppTheme.textPrimaryColor;
    final iconColor =
        isDarkMode ? AppTheme.primaryLightColor : AppTheme.primaryColor;
    final showResult = _result != null || _generating || _error != null;
    return Scaffold(
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
                ? (_generating ? 'gen' : (_error != null ? 'error' : 'result'))
                : 'picker',
          ),
          child: showResult ? _buildResultArea(l10n) : _buildPicker(l10n),
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
        _buildScopeRow(l10n),
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
    final muted = colorScheme.onSurfaceVariant;
    final skeleton = colorScheme.onSurface.withValues(alpha: 0.06);

    final reasoning = _liveReasoningText.trim();
    final content = _liveContentText.trim();
    final hasReasoning = reasoning.isNotEmpty;
    final hasContent = content.isNotEmpty;

    return ListView(
      padding: _pagePadding,
      children: [
        const SizedBox(height: 8),
        Row(
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                hasReasoning
                    ? '正在推理…'
                    : (l10n?.aiInsightGenerating ?? '正在通读你的笔记…'),
                style: theme.textTheme.titleSmall?.copyWith(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),

        // 还没收到任何内容时用骨架条占位；一旦开始推理，就把思考过程
        // 原样铺出来——等 40 秒却什么都看不到，是这个页面最伤人的地方。
        if (!hasReasoning && !hasContent)
          for (final factor in const [1.0, 0.86, 0.62]) ...[
            FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: factor,
              child: _skeletonBar(skeleton),
            ),
            const SizedBox(height: 10),
          ]
        else ...[
          if (hasReasoning) ...[
            Row(
              children: [
                Icon(
                  Icons.psychology_alt_outlined,
                  size: 15,
                  color: muted.withValues(alpha: 0.8),
                ),
                const SizedBox(width: 6),
                Text(
                  '思考过程',
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.3,
                    color: muted.withValues(alpha: 0.85),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '${reasoning.length} 字',
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontSize: 11,
                    color: muted.withValues(alpha: 0.55),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.only(left: 12),
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(
                    color: colorScheme.primary.withValues(alpha: 0.22),
                    width: 2,
                  ),
                ),
              ),
              child: Text(
                reasoning,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 12.5,
                  height: 1.75,
                  color: muted.withValues(alpha: 0.95),
                ),
              ),
            ),
          ],
          if (hasContent) ...[
            const SizedBox(height: 18),
            Text(
              '正在落笔',
              style: theme.textTheme.labelSmall?.copyWith(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.3,
                color: colorScheme.primary.withValues(alpha: 0.8),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              content,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontSize: 15,
                height: 1.8,
                color: colorScheme.onSurface.withValues(alpha: 0.9),
              ),
            ),
          ],
        ],

        const SizedBox(height: 18),
        Text(
          '用「${_activeLens?.name ?? ''}」这个视角 · 思考过程会边想边显示，生成后也能在结果页展开回看',
          style: theme.textTheme.bodySmall?.copyWith(
            fontSize: 12,
            height: 1.5,
            color: muted.withValues(alpha: 0.8),
          ),
        ),
      ],
    );
  }

  Widget _skeletonBar(Color color) => Container(
        height: 12,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(6),
        ),
      );

  /// 结果页的「推理过程」折叠块：默认收起，只留一行摘要，想看再展。
  Widget _buildReasoningPanel(String reasoning, ThemeData theme) {
    final colorScheme = theme.colorScheme;
    final muted = colorScheme.onSurfaceVariant;
    final expanded = _reasoningExpanded;
    return Material(
      color: colorScheme.onSurface.withValues(alpha: 0.035),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => setState(() => _reasoningExpanded = !expanded),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 11, 12, 11),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.psychology_alt_outlined,
                    size: 15,
                    color: muted.withValues(alpha: 0.8),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '推理过程',
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: muted.withValues(alpha: 0.95),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '${reasoning.length} 字',
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontSize: 11,
                      color: muted.withValues(alpha: 0.55),
                    ),
                  ),
                  const Spacer(),
                  Text(
                    expanded ? '收起' : '展开',
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontSize: 11.5,
                      color: muted.withValues(alpha: 0.7),
                    ),
                  ),
                  Icon(
                    expanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 18,
                    color: muted.withValues(alpha: 0.6),
                  ),
                ],
              ),
              if (expanded) ...[
                const SizedBox(height: 10),
                Text(
                  reasoning,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: 12.5,
                    height: 1.75,
                    color: muted.withValues(alpha: 0.9),
                  ),
                ),
              ],
            ],
          ),
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
    final muted = colorScheme.onSurfaceVariant;
    final result = _result!;
    final lens = _activeLens;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
      children: [
        // 小标签 + 条数，给下面的大标题做语境
        Row(
          children: [
            Expanded(
              child: Text(
                'AI 洞察 · ${lens?.name ?? '洞察'}',
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
          lens?.name ?? '洞察',
          style: theme.textTheme.headlineSmall?.copyWith(
            fontSize: 21,
            height: 1.25,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.2,
          ),
        ),
        if (result.truncated)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '共 ${result.totalCandidates} 条有文字内容，模型这次看的是最近 ${result.noteCount} 条。',
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 11.5,
                height: 1.5,
                color: muted.withValues(alpha: 0.75),
              ),
            ),
          ),
        if (result.reasoning.trim().isNotEmpty) ...[
          const SizedBox(height: 16),
          _buildReasoningPanel(result.reasoning.trim(), theme),
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
        SelectableText.rich(
          TextSpan(
            children: _buildInsightSpans(
              result.text,
              theme.textTheme.bodyMedium ?? const TextStyle(fontSize: 15.5),
              colorScheme,
            ),
          ),
          style: (theme.textTheme.bodyMedium ?? const TextStyle()).copyWith(
            fontSize: 15.5,
            height: 1.85,
            color: colorScheme.onSurface.withValues(alpha: 0.92),
          ),
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
            fontSize: (base.fontSize ?? 15.5) - 3,
            color: colorScheme.primary.withValues(alpha: 0.75),
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
