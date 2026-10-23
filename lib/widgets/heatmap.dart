import 'package:flutter/material.dart';
import 'package:inkpaper/l10n/app_localizations_simple.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/themes/app_theme.dart';
import 'package:inkpaper/utils/text_style_helper.dart';
import 'package:intl/intl.dart' show DateFormat;

class Heatmap extends StatefulWidget {
  const Heatmap({
    required this.notes,
    super.key,
    this.cellColor,
    this.activeColor = AppTheme.primaryColor,
  });
  final List<Note> notes;
  final Color? cellColor;
  final Color activeColor;

  @override
  State<Heatmap> createState() => _HeatmapState();
}

// 统计信息卡片 - 简化版
class _StatCardWidget extends StatelessWidget {
  const _StatCardWidget({
    required this.label,
    required this.value,
    required this.isDarkMode,
    required this.primaryColor,
  });
  final String label;
  final String value;
  final bool isDarkMode;
  final Color primaryColor;

  @override
  Widget build(BuildContext context) => Expanded(
        child: Padding(
          // flomo 风格：统计数字直接排在背景上，不再套浅色底块
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                value,
                style: AppTextStyles.bodyMedium(
                  context,
                  fontWeight: FontWeight.w600,
                  color: isDarkMode
                      ? AppTheme.darkTextPrimaryColor
                      : AppTheme.textPrimaryColor,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                label,
                style: AppTextStyles.custom(
                  context,
                  10,
                  color: isDarkMode
                      ? AppTheme.darkTextSecondaryColor.withValues(alpha: 0.8)
                      : AppTheme.textSecondaryColor,
                ),
              ),
            ],
          ),
        ),
      );
}

class _HeatmapState extends State<Heatmap> {
  // 每页展示的自然月数：三个月窗口
  static const int _monthsPerPage = 3;
  static const double _cellGap = 2.0;

  // 0 = 最近一页，1 = 再往前翻一页
  int _pageOffset = 0;

  final DateFormat _keyDateFormat = DateFormat('yyyy-MM-dd');

  // 获取本地化的日期格式
  DateFormat _getDateFormat(BuildContext context) {
    final isZh =
        AppLocalizationsSimple.of(context)?.locale.languageCode == 'zh';
    return isZh ? DateFormat('yyyy年M月') : DateFormat('MMMM yyyy', 'en_US');
  }

  DateFormat _getFullDateFormat(BuildContext context) {
    final isZh =
        AppLocalizationsSimple.of(context)?.locale.languageCode == 'zh';
    return isZh
        ? DateFormat('yyyy年MM月dd日')
        : DateFormat('MMM dd, yyyy', 'en_US');
  }

  // 热力图颜色定义 - 从浅到深
  static const List<Color> lightModeColors = [
    Color(0xFFEBEDF0), // 灰色 - 无活动
    Color(0xFFE3F5E8), // 非常浅的绿色 - 级别1
    Color(0xFFCCECD4), // 浅绿色 - 级别2
    Color(0xFFA8DFBA), // 中浅绿色 - 级别3
    Color(0xFF7ECDA0), // 中绿色 - 级别4
  ];

  // 深色模式下的热力图颜色
  static const List<Color> darkModeColors = [
    Color(0xFF2C2C2C), // 深灰色 - 无活动
    Color(0xFF1A3B2D), // 非常深的绿色 - 级别1
    Color(0xFF204836), // 深绿色 - 级别2
    Color(0xFF275C42), // 中深绿色 - 级别3
    Color(0xFF306E4F), // 中绿色 - 级别4
  ];

  // 区间末尾（含）：最近一页是今天，往前翻按整页（3 个自然月）回退
  DateTime get _rangeEnd {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    if (_pageOffset == 0) {
      return today;
    }
    // 上一页的最后一天 = 当前月往前 (offset*3 - 1) 个月的月末
    return DateTime(
      today.year,
      today.month - _pageOffset * _monthsPerPage + 1,
      0,
    );
  }

  // 区间起始：末尾往前推 3 个自然月，再对齐到周一（列 = 周，行 = 周一…周日）
  DateTime get _rangeStart {
    final end = _rangeEnd;
    final firstOfMonth = DateTime(end.year, end.month - (_monthsPerPage - 1));
    return firstOfMonth.subtract(Duration(days: firstOfMonth.weekday - 1));
  }

  int get _weekCount {
    final days = _rangeEnd.difference(_rangeStart).inDays + 1;
    return (days / 7).ceil();
  }

  // 不能再往未来翻
  bool get _canGoNext => _pageOffset > 0;

  void _previousPage() {
    setState(() {
      _pageOffset++;
    });
  }

  void _nextPage() {
    if (_canGoNext) {
      setState(() {
        _pageOffset--;
      });
    }
  }

  // 计算总字数
  int _getTotalWordCount() =>
      widget.notes.fold(0, (sum, note) => sum + note.content.length);

  // 计算记录总天数（去重）
  int _getTotalDays() {
    final uniqueDates = <String>{};
    for (final note in widget.notes) {
      uniqueDates.add(_keyDateFormat.format(note.createdAt));
    }
    return uniqueDates.length;
  }

  // 计算今日记录字数（大厂标准：只统计纯文字）
  int _getTodayWordCount() {
    final today = DateTime.now();
    final todayStr = _keyDateFormat.format(today);
    var count = 0;
    for (final note in widget.notes) {
      final createDateStr = _keyDateFormat.format(note.createdAt);
      if (createDateStr == todayStr) {
        count += _getActualWordCount(note.content);
      }
    }
    return count;
  }

  // 🎯 大厂标准：只统计实际文字（去除Markdown语法、标点、空格）
  int _getActualWordCount(String content) {
    if (content.isEmpty) {
      return 0;
    }

    var cleaned = content;

    // 移除Markdown语法
    cleaned = cleaned.replaceAll(RegExp(r'!\[([^\]]*)\]\([^\)]+\)'), ''); // 图片
    cleaned =
        cleaned.replaceAll(RegExp(r'\[([^\]]+)\]\([^\)]+\)'), r'$1'); // 链接，保留文字
    cleaned = cleaned.replaceAll(RegExp(r'`{3}[\s\S]*?`{3}'), ''); // 代码块
    cleaned = cleaned.replaceAll(RegExp('`[^`]+`'), ''); // 行内代码
    cleaned = cleaned.replaceAll(RegExp(r'[*_~#>\-\[\]\(\)]'), ''); // 符号

    // 移除标点符号和空格
    cleaned = cleaned.replaceAll(RegExp('[，。！？；：、""' '《》【】（）,.!?;:"\'s]'), '');

    // 返回纯文字字符数
    return cleaned.length;
  }

  // 计算今日新增笔记数量。热力图表示记录历史，不把同步/批量更新算作新记录。
  int _getTodayNewNoteCount() {
    final today = DateTime.now();
    final todayStr = _keyDateFormat.format(today);
    return widget.notes.where((note) {
      final createDateStr = _keyDateFormat.format(note.createdAt);
      return createDateStr == todayStr;
    }).length;
  }

  // 计算今日新增标签数量。
  int _getTodayNewTagCount() {
    final today = DateTime.now();
    final todayStr = _keyDateFormat.format(today);
    final todayTags = <String>{};
    for (final note in widget.notes) {
      final createDateStr = _keyDateFormat.format(note.createdAt);
      if (createDateStr == todayStr) {
        todayTags.addAll(note.tags);
      }
    }
    return todayTags.length;
  }

  // 格式化数字（大于1000时显示为k）
  String _formatNumber(int number) {
    if (number >= 1000) {
      return '${(number / 1000).toStringAsFixed(1)}k';
    }
    return number.toString();
  }

  @override
  Widget build(BuildContext context) {
    // 获取当前主题模式
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final textColor =
        isDarkMode ? AppTheme.darkTextPrimaryColor : AppTheme.textPrimaryColor;
    final secondaryTextColor = isDarkMode
        ? AppTheme.darkTextSecondaryColor
        : AppTheme.textSecondaryColor;
    final primaryColor =
        isDarkMode ? AppTheme.primaryLightColor : AppTheme.primaryColor;

    // 生成一个更可靠的key，同时考虑笔记数量和最近的更新时间以及月份偏移
    // 注意：无笔记时必须用固定值，用 now() 会让 key 每次 build 都变，
    // 导致热力图整棵子树（42 个 Tooltip + 三张统计卡）反复重建
    final latestUpdateTime = widget.notes.isEmpty
        ? 0
        : widget.notes
            .map((note) => note.updatedAt.millisecondsSinceEpoch)
            .reduce((max, time) => time > max ? time : max);

    final uniqueKey = ValueKey(
      'heatmap-${widget.notes.length}-$latestUpdateTime-$_pageOffset',
    );

    final dailyCounts = _calculateDailyCounts();
    final maxCount =
        dailyCounts.values.fold(0, (max, count) => count > max ? count : max);

    return Column(
      key: uniqueKey,
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 总体统计卡片 - 清晰版
        Row(
          children: [
            _StatCardWidget(
              label: AppLocalizationsSimple.of(context)?.totalWords ?? '总字数',
              value: _formatNumber(_getTotalWordCount()),
              isDarkMode: isDarkMode,
              primaryColor: primaryColor,
            ),
            const SizedBox(width: 4),
            _StatCardWidget(
              label: AppLocalizationsSimple.of(context)?.totalNotes ?? '笔记数',
              value: _formatNumber(widget.notes.length),
              isDarkMode: isDarkMode,
              primaryColor: primaryColor,
            ),
            const SizedBox(width: 4),
            _StatCardWidget(
              label: AppLocalizationsSimple.of(context)?.totalDays ?? '记录天数',
              value: _formatNumber(_getTotalDays()),
              isDarkMode: isDarkMode,
              primaryColor: primaryColor,
            ),
          ],
        ),
        const SizedBox(height: 8),

        // 月份标题和切换按钮
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // 左箭头按钮
            Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: _previousPage,
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: isDarkMode
                        ? Colors.white.withValues(alpha: 0.05)
                        : Colors.black.withValues(alpha: 0.03),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Icon(
                    Icons.chevron_left,
                    size: 16,
                    color: primaryColor,
                  ),
                ),
              ),
            ),

            // 区间标题（半年窗口，例如「2026年5月 - 2026年10月」）
            Text(
              _rangeLabel(context),
              style: AppTextStyles.labelSmall(
                context,
                fontWeight: FontWeight.w600,
                color: textColor,
              ),
            ),

            // 右箭头按钮
            Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: _canGoNext ? _nextPage : null,
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: _canGoNext
                        ? (isDarkMode
                            ? Colors.white.withValues(alpha: 0.05)
                            : Colors.black.withValues(alpha: 0.03))
                        : (isDarkMode
                            ? Colors.white.withValues(alpha: 0.02)
                            : Colors.black.withValues(alpha: 0.01)),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Icon(
                    Icons.chevron_right,
                    size: 16,
                    color: _canGoNext
                        ? primaryColor
                        : (isDarkMode
                            ? Colors.white.withValues(alpha: 0.2)
                            : Colors.black.withValues(alpha: 0.2)),
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),

        // 热力图网格：列 = 周，行 = 周一…周日（flomo / GitHub 式连续时间轴）。
        // 26 列铺满抽屉宽度后单格约 11dp，比「一个月 7 列」的小得多。
        LayoutBuilder(
          builder: (context, constraints) {
            const weekdayLabelWidth = 16.0;
            final columns = _weekCount;
            final gridWidth = constraints.maxWidth - weekdayLabelWidth;
            // 13 列时格宽约 22dp；上限给到 26 保证仍然铺满，不回到留白状态
            final cell = ((gridWidth - _cellGap * (columns - 1)) / columns)
                .clamp(7.0, 26.0);
            final start = _rangeStart;
            final end = _rangeEnd;

            DateTime dateAt(int week, int weekday) => start.add(
                  Duration(days: week * 7 + weekday),
                );

            // 月份标签：某一列的周一跨入新月份时，在这列上方标一次。
            // 标签比格子宽，必须用 Stack 绝对定位 —— 放进 Row 会把行撑爆。
            final monthLabels = <int, String>{};
            var lastMonthKey = '';
            final startIsMonthStart = start.day == 1;
            for (var week = 0; week < columns; week++) {
              final first = dateAt(week, 0);
              final key = '${first.year}-${first.month}';
              if (key == lastMonthKey) {
                continue;
              }
              lastMonthKey = key;
              // 起始月只占了半周时不标，保证顶部只出现 3 个月份
              if (week == 0 && !startIsMonthStart) {
                continue;
              }
              monthLabels[week] = _monthShortLabel(context, first);
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 月份标签行
                SizedBox(
                  height: 12,
                  child: Row(
                    children: [
                      const SizedBox(width: weekdayLabelWidth),
                      Expanded(
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            for (final entry in monthLabels.entries)
                              Positioned(
                                left: entry.key * (cell + _cellGap),
                                top: 0,
                                child: Text(
                                  entry.value,
                                  maxLines: 1,
                                  softWrap: false,
                                  style: AppTextStyles.custom(
                                    context,
                                    8,
                                    color: secondaryTextColor
                                        .withValues(alpha: 0.7),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),

                // 7 行 × N 列
                for (var weekday = 0; weekday < 7; weekday++)
                  Row(
                    children: [
                      SizedBox(
                        width: weekdayLabelWidth,
                        height: cell + _cellGap,
                        child: weekday.isEven
                            ? Text(
                                const ['一', '二', '三', '四', '五', '六', '日'][weekday],
                                style: AppTextStyles.custom(
                                  context,
                                  8,
                                  color:
                                      secondaryTextColor.withValues(alpha: 0.6),
                                ),
                              )
                            : null,
                      ),
                      for (var week = 0; week < columns; week++)
                        Padding(
                          padding: EdgeInsets.only(
                            right: week == columns - 1 ? 0 : _cellGap,
                            bottom: weekday == 6 ? 0 : _cellGap,
                          ),
                          child: SizedBox(
                            width: cell,
                            height: cell,
                            child: _buildHeatCell(
                              context: context,
                              date: dateAt(week, weekday),
                              dailyCounts: dailyCounts,
                              maxCount: maxCount,
                              isDarkMode: isDarkMode,
                              inRange:
                                  !dateAt(week, weekday).isAfter(end),
                            ),
                          ),
                        ),
                    ],
                  ),
              ],
            );
          },
        ),

        // 添加颜色说明
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Text(
              '${AppLocalizationsSimple.of(context)?.activityLevel ?? '活跃度'}: ',
              style: AppTextStyles.custom(
                context,
                8,
                color: secondaryTextColor.withValues(alpha: 0.6),
              ),
            ),
            ...List.generate(4, (index) {
              final colors = isDarkMode ? darkModeColors : lightModeColors;
              return Container(
                width: 7,
                height: 7,
                margin: const EdgeInsets.symmetric(horizontal: 1.2),
                decoration: BoxDecoration(
                  color: colors[index + 1],
                  borderRadius: BorderRadius.circular(2),
                ),
              );
            }),
          ],
        ),

        // 今日统计卡片 - 清晰版
        const SizedBox(height: 8),
        Row(
          children: [
            _StatCardWidget(
              label: AppLocalizationsSimple.of(context)?.todayWords ?? '今日字数',
              value: _formatNumber(_getTodayWordCount()),
              isDarkMode: isDarkMode,
              primaryColor: primaryColor,
            ),
            const SizedBox(width: 4),
            _StatCardWidget(
              label:
                  AppLocalizationsSimple.of(context)?.todayNewNotes ?? '活跃笔记',
              value: _formatNumber(_getTodayNewNoteCount()),
              isDarkMode: isDarkMode,
              primaryColor: primaryColor,
            ),
            const SizedBox(width: 4),
            _StatCardWidget(
              label: AppLocalizationsSimple.of(context)?.todayNewTags ?? '活跃标签',
              value: _formatNumber(_getTodayNewTagCount()),
              isDarkMode: isDarkMode,
              primaryColor: primaryColor,
            ),
          ],
        ),
      ],
    );
  }

  /// 统计当前区间内每天的笔记数（只按创建日，避免同步/恢复污染历史分布）。
  Map<String, int> _calculateDailyCounts() {
    final result = <String, int>{};
    final start = _rangeStart;
    final end = _rangeEnd;
    final totalDays = end.difference(start).inDays;

    for (var i = 0; i <= totalDays; i++) {
      result[_keyDateFormat.format(start.add(Duration(days: i)))] = 0;
    }

    for (final note in widget.notes) {
      final created = DateTime(
        note.createdAt.year,
        note.createdAt.month,
        note.createdAt.day,
      );
      if (created.isBefore(start) || created.isAfter(end)) {
        continue;
      }
      final key = _keyDateFormat.format(created);
      result[key] = (result[key] ?? 0) + 1;
    }

    return result;
  }

  /// 列上方的短月份标签（"5月" / "May"），避免比格子宽太多而互相压叠。
  String _monthShortLabel(BuildContext context, DateTime date) {
    final isZh =
        AppLocalizationsSimple.of(context)?.locale.languageCode == 'zh';
    return isZh ? '${date.month}月' : DateFormat('MMM', 'en_US').format(date);
  }

  /// 区间标题：与顶部月份标签保持一致，起始月残缺时从下一个整月算起。
  String _rangeLabel(BuildContext context) {
    final format = _getDateFormat(context);
    var start = _rangeStart;
    if (start.day != 1) {
      start = DateTime(start.year, start.month + 1);
    }
    final end = _rangeEnd;
    if (start.year == end.year && start.month == end.month) {
      return format.format(end);
    }
    return '${format.format(start)} - ${format.format(end)}';
  }

  /// 单个热力格（A-11：从 GridView.builder 的 itemBuilder 抽出，供 Row/Column 复用）
  Widget _buildHeatCell({
    required BuildContext context,
    required DateTime date,
    required Map<String, int> dailyCounts,
    required int maxCount,
    required bool isDarkMode,
    required bool inRange,
  }) {
    final dateKey = _keyDateFormat.format(date);
    final count = dailyCounts[dateKey] ?? 0;

    return Tooltip(
      message:
          '${_getFullDateFormat(context).format(date)}: ${AppLocalizationsSimple.of(context)?.notesCountFormatted(count) ?? '$count 条笔记'}',
      child: Center(
        child: Container(
          decoration: BoxDecoration(
            color: inRange
                ? _getHeatmapColor(count, maxCount, isDarkMode)
                : (widget.cellColor ??
                        (isDarkMode ? darkModeColors[0] : lightModeColors[0]))
                    .withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(3), // 小方格圆角
          ),
        ),
      ),
    );
  }

  Color _getHeatmapColor(int count, int maxCount, bool isDarkMode) {
    final colors = isDarkMode ? darkModeColors : lightModeColors;

    // 无活动返回灰色
    if (count == 0) {
      return widget.cellColor ?? colors[0];
    }

    // 计算颜色级别
    int level;
    if (maxCount <= 1) {
      // 如果最大值是1，则直接使用第一个颜色
      level = 1;
    } else if (count == maxCount) {
      // 如果是最大值，使用最深的颜色
      level = colors.length - 1;
    } else {
      // 使用线性比例计算颜色级别
      final ratio = count / maxCount;
      level = (ratio * (colors.length - 2)).round() + 1;
    }

    // 确保级别在有效范围内
    level = level.clamp(1, colors.length - 1);
    return colors[level];
  }
}
