import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:inkpaper/l10n/app_localizations_simple.dart';
import 'package:inkpaper/providers/app_provider.dart';
import 'package:inkpaper/services/periodic_review_service.dart';
import 'package:inkpaper/themes/app_theme.dart';
import 'package:inkpaper/utils/snackbar_utils.dart';
import 'package:inkpaper/widgets/sidebar.dart';
import 'package:provider/provider.dart';

/// 周回顾 / 月回顾：统计当前周期，并让 AI 写一段回顾。
class PeriodicReviewScreen extends StatefulWidget {
  const PeriodicReviewScreen({super.key});

  @override
  State<PeriodicReviewScreen> createState() => _PeriodicReviewScreenState();
}

class _PeriodicReviewScreenState extends State<PeriodicReviewScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final PeriodicReviewService _service = PeriodicReviewService();

  ReviewPeriod _period = ReviewPeriod.week;
  PeriodicReviewResult? _result;
  bool _isLoading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _generate();
      }
    });
  }

  void _openDrawer() => _scaffoldKey.currentState?.openDrawer();

  Future<void> _generate({bool force = false}) async {
    if (_isLoading) {
      return;
    }
    final provider = Provider.of<AppProvider>(context, listen: false);
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final result = await _service.generate(
        config: provider.appConfig,
        allNotes: provider.notes,
        period: _period,
        forceRefresh: force,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _result = result;
        _isLoading = false;
      });
    } on Object catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = '生成失败：$e';
        _isLoading = false;
      });
    }
  }

  void _switchPeriod(ReviewPeriod period) {
    if (period == _period) {
      return;
    }
    setState(() {
      _period = period;
      _result = null;
    });
    _generate();
  }

  Future<void> _copySummary(String content) async {
    if (content.trim().isEmpty) {
      return;
    }
    await Clipboard.setData(ClipboardData(text: content));
    if (!mounted) {
      return;
    }
    SnackBarUtils.showSuccess(
      context,
      AppLocalizationsSimple.of(context)?.periodicReviewCopied ?? '已复制',
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final backgroundColor =
        isDarkMode ? AppTheme.darkBackgroundColor : AppTheme.backgroundColor;
    final textColor =
        isDarkMode ? AppTheme.darkTextPrimaryColor : Colors.black87;
    final iconColor =
        isDarkMode ? AppTheme.primaryLightColor : AppTheme.primaryColor;
    final isDesktop = !kIsWeb && (Platform.isMacOS || Platform.isWindows);
    final l10n = AppLocalizationsSimple.of(context);

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: backgroundColor,
      drawer: isDesktop ? null : const Sidebar(),
      drawerEdgeDragWidth:
          isDesktop ? null : MediaQuery.of(context).size.width * 0.2,
      appBar: AppBar(
        backgroundColor: backgroundColor,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        automaticallyImplyLeading: false,
        leading: isDesktop
            ? null
            : IconButton(
                tooltip: '菜单',
                icon: Icon(Icons.menu_rounded, color: iconColor),
                onPressed: _openDrawer,
              ),
        centerTitle: true,
        title: Text(
          l10n?.periodicReview ?? '回顾',
          style: TextStyle(
            color: textColor,
            fontWeight: FontWeight.w600,
            fontSize: 18,
          ),
        ),
        actions: [
          IconButton(
            tooltip: l10n?.reviewRegenerate ?? '重新生成',
            icon: Icon(
              Icons.refresh_rounded,
              color: iconColor,
              size: 22,
            ),
            onPressed: _isLoading ? null : () => _generate(force: true),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Consumer<AppProvider>(
        builder: (context, appProvider, _) {
          if (appProvider.isLoading) {
            return const Center(child: CircularProgressIndicator());
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              _buildPeriodSwitcher(isDarkMode),
              const SizedBox(height: 16),
              if (_error != null) _buildError(_error!),
              if (_result == null)
                _buildLoading()
              else if (_result!.stats.isEmpty)
                _buildEmpty(isDarkMode)
              else ...[
                _buildStatsCard(_result!, isDarkMode),
                const SizedBox(height: 14),
                if (_result!.stats.tagCounts.isNotEmpty) ...[
                  _buildTagCard(_result!, isDarkMode),
                  const SizedBox(height: 14),
                ],
                _buildSummaryCard(_result!, isDarkMode),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _buildPeriodSwitcher(bool isDarkMode) {
    final l10n = AppLocalizationsSimple.of(context);
    final items = <(ReviewPeriod, String)>[
      (ReviewPeriod.week, l10n?.weeklyReview ?? '本周'),
      (ReviewPeriod.month, l10n?.monthlyReview ?? '本月'),
    ];

    return Row(
      children: [
        for (final item in items) ...[
          Expanded(
            child: GestureDetector(
              onTap: () => _switchPeriod(item.$1),
              behavior: HitTestBehavior.opaque,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: _period == item.$1
                      ? (isDarkMode
                          ? AppTheme.primaryLightColor.withValues(alpha: 0.18)
                          : AppTheme.primaryColor.withValues(alpha: 0.12))
                      : (isDarkMode ? AppTheme.darkCardColor : Colors.white),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: _period == item.$1
                        ? (isDarkMode
                            ? AppTheme.primaryLightColor
                            : AppTheme.primaryColor)
                        : (isDarkMode
                            ? Colors.white.withValues(alpha: 0.06)
                            : Colors.black.withValues(alpha: 0.06)),
                  ),
                ),
                child: Center(
                  child: Text(
                    item.$2,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: _period == item.$1
                          ? FontWeight.w600
                          : FontWeight.normal,
                      color: _period == item.$1
                          ? (isDarkMode
                              ? AppTheme.primaryLightColor
                              : AppTheme.primaryColor)
                          : (isDarkMode
                              ? AppTheme.darkTextPrimaryColor
                              : Colors.black87),
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (item.$1 != items.last.$1) const SizedBox(width: 10),
        ],
      ],
    );
  }

  Widget _buildStatsCard(PeriodicReviewResult result, bool isDarkMode) {
    final stats = result.stats;
    final textColor =
        isDarkMode ? AppTheme.darkTextPrimaryColor : Colors.black87;
    final secondaryColor = isDarkMode ? Colors.grey[400] : Colors.grey[600];

    return _card(
      isDarkMode,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${result.range.shortLabel} · ${stats.noteCount} 条',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: textColor,
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              _metric(
                '笔记',
                '${stats.noteCount}',
                _deltaText(stats.noteDelta),
                isDarkMode,
              ),
              _metric(
                '活跃天数',
                '${stats.activeDays}',
                _deltaText(stats.activeDayDelta),
                isDarkMode,
              ),
              _metric('字数', _formatCount(stats.charCount), null, isDarkMode),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '日均 ${(stats.noteCount / result.range.days).toStringAsFixed(1)} 条',
            style: TextStyle(fontSize: 12, color: secondaryColor),
          ),
        ],
      ),
    );
  }

  String? _deltaText(int delta) {
    if (delta == 0) {
      return '持平';
    }
    return delta > 0 ? '+$delta' : '$delta';
  }

  String _formatCount(int count) {
    if (count >= 10000) {
      return '${(count / 10000).toStringAsFixed(1)}w';
    }
    if (count >= 1000) {
      return '${(count / 1000).toStringAsFixed(1)}k';
    }
    return '$count';
  }

  Widget _metric(
    String label,
    String value,
    String? delta,
    bool isDarkMode,
  ) {
    final textColor =
        isDarkMode ? AppTheme.darkTextPrimaryColor : Colors.black87;
    final secondaryColor = isDarkMode ? Colors.grey[500] : Colors.grey[600];
    final accent =
        isDarkMode ? AppTheme.primaryLightColor : AppTheme.primaryColor;

    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                value,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                  color: textColor,
                  height: 1.1,
                ),
              ),
              if (delta != null) ...[
                const SizedBox(width: 4),
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(
                    delta,
                    style: TextStyle(
                      fontSize: 11,
                      color: delta.startsWith('+')
                          ? accent
                          : (delta.startsWith('-')
                              ? Colors.orange
                              : secondaryColor),
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(fontSize: 12, color: secondaryColor),
          ),
        ],
      ),
    );
  }

  Widget _buildTagCard(PeriodicReviewResult result, bool isDarkMode) {
    final textColor =
        isDarkMode ? AppTheme.darkTextPrimaryColor : Colors.black87;
    final accent =
        isDarkMode ? AppTheme.primaryLightColor : AppTheme.primaryColor;

    return _card(
      isDarkMode,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '关注点',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: textColor,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final entry in result.stats.tagCounts)
                GestureDetector(
                  onTap: () => context.pushNamed(
                    'tag-notes',
                    queryParameters: {'tag': entry.key},
                  ),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '#${entry.key} ${entry.value}',
                      style: TextStyle(
                        fontSize: 12,
                        color: accent,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryCard(PeriodicReviewResult result, bool isDarkMode) {
    final textColor =
        isDarkMode ? AppTheme.darkTextPrimaryColor : Colors.black87;
    final secondaryColor = isDarkMode ? Colors.grey[400] : Colors.grey[600];
    final accent =
        isDarkMode ? AppTheme.primaryLightColor : AppTheme.primaryColor;

    final paragraphs = result.content
        .split(RegExp(r'\n\s*\n'))
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();

    return _card(
      isDarkMode,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.auto_awesome_rounded, size: 16, color: accent),
              const SizedBox(width: 6),
              Text(
                '回顾',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: textColor,
                ),
              ),
              const Spacer(),
              Text(
                result.usedRemote ? 'AI 生成' : '本地统计',
                style: TextStyle(fontSize: 11, color: secondaryColor),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (paragraphs.isEmpty)
            Text(
              '暂无内容',
              style: TextStyle(fontSize: 13, color: secondaryColor),
            )
          else
            for (var i = 0; i < paragraphs.length; i++)
              Padding(
                padding: EdgeInsets.only(
                  bottom: i == paragraphs.length - 1 ? 0 : 12,
                ),
                child: Text(
                  paragraphs[i],
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.7,
                    color: textColor,
                  ),
                ),
              ),
          if (result.remoteError != null) ...[
            const SizedBox(height: 12),
            Text(
              'AI 调用失败，已降级为本地统计：${result.remoteError}',
              style: TextStyle(fontSize: 11, color: Colors.orange[700]),
            ),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              TextButton.icon(
                onPressed: _isLoading
                    ? null
                    : () => _generate(force: true),
                icon: Icon(
                  Icons.refresh_rounded,
                  size: 16,
                  color: accent,
                ),
                label: Text(
                  AppLocalizationsSimple.of(context)?.reviewRegenerate ??
                      '重新生成',
                  style: TextStyle(fontSize: 13, color: accent),
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: () => _copySummary(result.content),
                icon: Icon(
                  Icons.copy_rounded,
                  size: 16,
                  color: secondaryColor,
                ),
                label: Text(
                  AppLocalizationsSimple.of(context)?.reviewCopy ?? '复制',
                  style: TextStyle(fontSize: 13, color: secondaryColor),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty(bool isDarkMode) {
    final secondaryColor = isDarkMode ? Colors.grey[500] : Colors.grey[600];
    return Padding(
      padding: const EdgeInsets.only(top: 80),
      child: Column(
        children: [
          Icon(Icons.auto_stories_outlined, size: 64, color: secondaryColor),
          const SizedBox(height: 16),
          Text(
            AppLocalizationsSimple.of(context)?.reviewNoNotes ??
                '这个周期还没有笔记',
            style: TextStyle(fontSize: 14, color: secondaryColor),
          ),
        ],
      ),
    );
  }

  Widget _buildLoading() {
    return Padding(
      padding: const EdgeInsets.only(top: 80),
      child: Column(
        children: [
          const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(height: 16),
          Text(
            AppLocalizationsSimple.of(context)?.reviewGenerating ?? '正在生成回顾…',
            style: TextStyle(
              fontSize: 13,
              color: Theme.of(context).brightness == Brightness.dark
                  ? Colors.grey[400]
                  : Colors.grey[600],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildError(String message) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        message,
        style: TextStyle(fontSize: 13, color: Colors.orange[700]),
      ),
    );
  }

  Widget _card(bool isDarkMode, {required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDarkMode ? AppTheme.darkCardColor : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDarkMode
              ? Colors.white.withValues(alpha: 0.06)
              : Colors.black.withValues(alpha: 0.05),
        ),
      ),
      child: child,
    );
  }
}
