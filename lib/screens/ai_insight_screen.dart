import 'package:flutter/material.dart';
import 'package:inkpaper/l10n/app_localizations_simple.dart';
import 'package:inkpaper/models/app_config_model.dart' as models;
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/services/deepseek_api_service.dart';
import 'package:inkpaper/themes/app_theme.dart';
import 'package:inkpaper/utils/snackbar_utils.dart';

/// AI 洞察页：按时间 / 标签 / 关键词筛选全库笔记，交给 AI 做整理分析。
///
/// 原先是 `home_screen.dart` 里的私有 widget，与首页只通过 `notes` +
/// `appConfig` 两个入参耦合，因此独立成文件，便于后续挂到侧边栏或设置页。
class AiInsightScreen extends StatefulWidget {
  const AiInsightScreen({
    required this.notes,
    required this.appConfig,
    super.key,
  });
  final List<Note> notes;
  final models.AppConfig appConfig;

  @override
  State<AiInsightScreen> createState() => _AiInsightScreenState();
}

class _AiInsightScreenState extends State<AiInsightScreen> {
  final _keywordController = TextEditingController();
  final _scrollController = ScrollController(); // 🔥 添加滚动控制器
  final Set<String> _selectedTags = {};
  final Set<String> _excludedTags = {};
  String _timeRange = 'all'; // all, week, month, year
  bool _isAnalyzing = false;
  String? _insightResult;
  bool _isIncludeTagsExpanded = false; // 包含标签是否展开
  bool _isExcludeTagsExpanded = false; // 排除标签是否展开
  String? _errorMessage;
  final GlobalKey _insightResultKey = GlobalKey(); // 🔥 结果区域的key，用于定位

  @override
  void dispose() {
    _keywordController.dispose();
    _scrollController.dispose(); // 🔥 释放滚动控制器
    super.dispose();
  }

  // 获取所有可用标签
  List<String> get _availableTags {
    final tags = <String>{};
    for (final note in widget.notes) {
      tags.addAll(note.tags);
    }
    return tags.toList()..sort();
  }

  // 根据筛选条件过滤笔记
  List<Note> get _filteredNotes => widget.notes.where((note) {
        // 时间范围筛选
        if (_timeRange != 'all') {
          final now = DateTime.now();
          final noteDate = note.createdAt;
          switch (_timeRange) {
            case 'week':
              if (now.difference(noteDate).inDays > 7) {
                return false;
              }
              break;
            case 'month':
              if (now.difference(noteDate).inDays > 30) {
                return false;
              }
              break;
            case 'year':
              if (now.difference(noteDate).inDays > 365) {
                return false;
              }
              break;
          }
        }

        // 标签筛选
        if (_selectedTags.isNotEmpty) {
          if (!_selectedTags.any((tag) => note.tags.contains(tag))) {
            return false;
          }
        }

        // 排除标签
        if (_excludedTags.isNotEmpty) {
          if (_excludedTags.any((tag) => note.tags.contains(tag))) {
            return false;
          }
        }

        // 关键词筛选
        if (_keywordController.text.isNotEmpty) {
          if (!note.content
              .toLowerCase()
              .contains(_keywordController.text.toLowerCase())) {
            return false;
          }
        }

        return true;
      }).toList();

  @override
  Widget build(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final backgroundColor =
        isDarkMode ? AppTheme.darkBackgroundColor : Colors.white;
    final surfaceColor =
        isDarkMode ? AppTheme.darkSurfaceColor : AppTheme.surfaceColor;
    final textColor =
        isDarkMode ? AppTheme.darkTextPrimaryColor : AppTheme.textPrimaryColor;
    final subTextColor = isDarkMode
        ? AppTheme.darkTextSecondaryColor
        : AppTheme.textSecondaryColor;

    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(
        backgroundColor: backgroundColor,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.close, color: textColor),
          onPressed: () => Navigator.pop(context),
        ),
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.psychology_rounded,
              color: AppTheme.primaryColor,
              size: 24,
            ),
            const SizedBox(width: 8),
            Text(
              'AI 洞察',
              style: TextStyle(
                color: textColor,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        centerTitle: true,
      ),
      body: Column(
        children: [
          // 筛选区域
          Expanded(
            child: SingleChildScrollView(
              controller: _scrollController, // 🔥 添加滚动控制器
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 关键词输入
                  _buildSectionTitle(
                    context,
                    AppLocalizationsSimple.of(context)?.keywords ?? '关键词',
                    AppLocalizationsSimple.of(context)?.inputKeywords ??
                        '输入想要洞察的关键词',
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _keywordController,
                    style: TextStyle(color: textColor),
                    decoration: InputDecoration(
                      hintText: AppLocalizationsSimple.of(context)
                              ?.tagInputExampleHint ??
                          '例如：工作、学习、思考...',
                      hintStyle:
                          TextStyle(color: subTextColor.withValues(alpha: 0.5)),
                      prefixIcon: const Icon(
                        Icons.search,
                        color: AppTheme.primaryColor,
                      ),
                      filled: true,
                      fillColor: surfaceColor,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),

                  const SizedBox(height: 24),

                  // 时间范围
                  _buildSectionTitle(
                    context,
                    AppLocalizationsSimple.of(context)?.timeRange ?? '时间范围',
                    AppLocalizationsSimple.of(context)
                            ?.selectAnalysisTimeRange ??
                        '选择要分析的时间段',
                  ),
                  const SizedBox(height: 12),
                  _buildTimeRangeSelector(),

                  const SizedBox(height: 24),

                  // 包含标签
                  _buildSectionTitle(
                    context,
                    AppLocalizationsSimple.of(context)?.includeTags ?? '包含标签',
                    AppLocalizationsSimple.of(context)?.selectIncludeTags ??
                        '选择要包含的标签',
                  ),
                  const SizedBox(height: 12),
                  _buildTagSelector(
                    isInclude: true,
                    isExpanded: _isIncludeTagsExpanded,
                  ),
                  if (_availableTags.length > 10)
                    _buildExpandButton(isInclude: true),

                  const SizedBox(height: 24),

                  // 排除标签
                  _buildSectionTitle(
                    context,
                    AppLocalizationsSimple.of(context)?.excludeTags ?? '排除标签',
                    AppLocalizationsSimple.of(context)?.selectExcludeTags ??
                        '选择要排除的标签',
                  ),
                  const SizedBox(height: 12),
                  _buildTagSelector(
                    isInclude: false,
                    isExpanded: _isExcludeTagsExpanded,
                  ),
                  if (_availableTags.length > 10)
                    _buildExpandButton(isInclude: false),

                  const SizedBox(height: 24),

                  // 统计信息
                  _buildStatistics(),

                  const SizedBox(height: 24),

                  // 洞察结果
                  if (_insightResult != null) ...[
                    Container(
                      key: _insightResultKey, // 🔥 添加key用于定位
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildSectionTitle(
                            context,
                            AppLocalizationsSimple.of(context)
                                    ?.insightResults ??
                                '洞察结果',
                            AppLocalizationsSimple.of(context)
                                    ?.aiGeneratedAnalysis ??
                                '根据当前筛选生成的整理结果',
                          ),
                          const SizedBox(height: 12),
                          _buildInsightResult(),
                        ],
                      ),
                    ),
                  ],

                  if (_errorMessage != null) ...[
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.red.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Colors.red.withValues(alpha: 0.3),
                        ),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.error_outline, color: Colors.red),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              _errorMessage!,
                              style: const TextStyle(
                                color: Colors.red,
                                fontSize: 14,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),

          // 底部操作栏
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: surfaceColor,
              border: Border(
                top: BorderSide(
                  color: (isDarkMode ? Colors.white : Colors.black)
                      .withValues(alpha: 0.1),
                ),
              ),
            ),
            child: SafeArea(
              child: SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  onPressed: _isAnalyzing ? null : _startAnalysis,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primaryColor,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    elevation: 0,
                  ),
                  child: _isAnalyzing
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor:
                                    AlwaysStoppedAnimation<Color>(Colors.white),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Text(
                              AppLocalizationsSimple.of(context)?.aiAnalyzing ??
                                  'AI正在分析中...',
                            ),
                          ],
                        )
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.auto_awesome, size: 20),
                            const SizedBox(width: 8),
                            Text(
                              AppLocalizationsSimple.of(context)
                                      ?.startInsightWithCount(
                                    _filteredNotes.length,
                                  ) ??
                                  '开始洞察 (${_filteredNotes.length} 条笔记)',
                            ),
                          ],
                        ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(
    BuildContext context,
    String title,
    String subtitle,
  ) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final textColor =
        isDarkMode ? AppTheme.darkTextPrimaryColor : AppTheme.textPrimaryColor;
    final subTextColor = isDarkMode
        ? AppTheme.darkTextSecondaryColor
        : AppTheme.textSecondaryColor;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: textColor,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: TextStyle(
            fontSize: 13,
            color: subTextColor,
          ),
        ),
      ],
    );
  }

  Widget _buildTimeRangeSelector() {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final surfaceColor =
        isDarkMode ? AppTheme.darkSurfaceColor : AppTheme.surfaceColor;

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: surfaceColor,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          _buildTimeRangeOption(
            AppLocalizationsSimple.of(context)?.allTime ?? '全部',
            'all',
          ),
          _buildTimeRangeOption(
            AppLocalizationsSimple.of(context)?.last7Days ?? '近7天',
            'week',
          ),
          _buildTimeRangeOption(
            AppLocalizationsSimple.of(context)?.last30Days ?? '近30天',
            'month',
          ),
          _buildTimeRangeOption(
            AppLocalizationsSimple.of(context)?.last1Year ?? '近1年',
            'year',
          ),
        ],
      ),
    );
  }

  Widget _buildTimeRangeOption(String label, String value) {
    final isSelected = _timeRange == value;

    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _timeRange = value),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: isSelected ? AppTheme.primaryColor : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
              color: isSelected ? Colors.white : AppTheme.primaryColor,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTagSelector({
    required bool isInclude,
    required bool isExpanded,
  }) {
    final tags = _availableTags;
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final surfaceColor =
        isDarkMode ? AppTheme.darkSurfaceColor : AppTheme.surfaceColor;

    if (tags.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: surfaceColor,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          AppLocalizationsSimple.of(context)?.noAvailableTags ?? '暂无可用标签',
          style: const TextStyle(
            color: AppTheme.darkTextSecondaryColor,
            fontSize: 14,
          ),
          textAlign: TextAlign.center,
        ),
      );
    }

    // 🔥 标签折叠：默认只显示前10个，点击展开查看全部
    final tagList = tags.toList()..sort();
    final displayTags = isExpanded ? tagList : tagList.take(10).toList();

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: displayTags.map((tag) {
        final isSelected = isInclude
            ? _selectedTags.contains(tag)
            : _excludedTags.contains(tag);

        return GestureDetector(
          onTap: () {
            setState(() {
              if (isInclude) {
                if (isSelected) {
                  _selectedTags.remove(tag);
                } else {
                  _selectedTags.add(tag);
                  _excludedTags.remove(tag); // 从排除列表移除
                }
              } else {
                if (isSelected) {
                  _excludedTags.remove(tag);
                } else {
                  _excludedTags.add(tag);
                  _selectedTags.remove(tag); // 从包含列表移除
                }
              }
            });
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: isSelected
                  ? (isInclude ? AppTheme.primaryColor : Colors.red)
                  : surfaceColor,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: isSelected
                    ? (isInclude ? AppTheme.primaryColor : Colors.red)
                    : (isDarkMode
                        ? Colors.white.withValues(alpha: 0.2)
                        : Colors.black.withValues(alpha: 0.1)),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isSelected)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Icon(
                      isInclude ? Icons.check : Icons.close,
                      size: 16,
                      color: Colors.white,
                    ),
                  ),
                Text(
                  tag,
                  style: TextStyle(
                    fontSize: 14,
                    color: isSelected ? Colors.white : AppTheme.primaryColor,
                    fontWeight:
                        isSelected ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  // 构建展开/收起按钮
  Widget _buildExpandButton({required bool isInclude}) {
    final isExpanded =
        isInclude ? _isIncludeTagsExpanded : _isExcludeTagsExpanded;
    final tagCount = _availableTags.length;

    return Center(
      child: TextButton.icon(
        onPressed: () {
          setState(() {
            if (isInclude) {
              _isIncludeTagsExpanded = !_isIncludeTagsExpanded;
            } else {
              _isExcludeTagsExpanded = !_isExcludeTagsExpanded;
            }
          });
        },
        icon: Icon(
          isExpanded ? Icons.expand_less : Icons.expand_more,
          size: 18,
          color: AppTheme.primaryColor,
        ),
        label: Text(
          isExpanded
              ? (AppLocalizationsSimple.of(context)?.collapse ?? '收起')
              : (AppLocalizationsSimple.of(context)
                      ?.expandAllTagsWithCount(tagCount) ??
                  '展开全部 ($tagCount个标签)'),
          style: const TextStyle(
            fontSize: 13,
            color: AppTheme.primaryColor,
          ),
        ),
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        ),
      ),
    );
  }

  Widget _buildStatistics() {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final surfaceColor =
        isDarkMode ? AppTheme.darkSurfaceColor : AppTheme.surfaceColor;

    final totalNotes = widget.notes.length;
    final filteredCount = _filteredNotes.length;
    final totalWords = _filteredNotes.fold<int>(
      0,
      (sum, note) => sum + _getActualWordCount(note.content),
    );

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: surfaceColor,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _buildStatItem(
            icon: Icons.description_outlined,
            label: AppLocalizationsSimple.of(context)?.filterNotes ?? '筛选笔记',
            value: '$filteredCount / $totalNotes',
            color: AppTheme.primaryColor,
          ),
          Container(
            width: 1,
            height: 40,
            color: (isDarkMode ? Colors.white : Colors.black)
                .withValues(alpha: 0.1),
          ),
          _buildStatItem(
            icon: Icons.text_fields,
            label: AppLocalizationsSimple.of(context)?.totalWordCount ?? '总字数',
            value: totalWords.toString(),
            color: Colors.orange,
          ),
          Container(
            width: 1,
            height: 40,
            color: (isDarkMode ? Colors.white : Colors.black)
                .withValues(alpha: 0.1),
          ),
          _buildStatItem(
            icon: Icons.label_outlined,
            label: AppLocalizationsSimple.of(context)?.tagCount ?? '标签数',
            value: _availableTags.length.toString(),
            color: Colors.green,
          ),
        ],
      ),
    );
  }

  Widget _buildStatItem({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final textColor =
        isDarkMode ? AppTheme.darkTextPrimaryColor : AppTheme.textPrimaryColor;
    final subTextColor = isDarkMode
        ? AppTheme.darkTextSecondaryColor
        : AppTheme.textSecondaryColor;

    return Column(
      children: [
        Icon(icon, color: color, size: 24),
        const SizedBox(height: 8),
        Text(
          value,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: textColor,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: subTextColor,
          ),
        ),
      ],
    );
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

  Widget _buildInsightResult() {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final textColor =
        isDarkMode ? AppTheme.darkTextPrimaryColor : AppTheme.textPrimaryColor;

    // 🔥 flomo风格：简洁的卡片展示，强调内容而非装饰 + 淡入动画
    return TweenAnimationBuilder<double>(
      duration: const Duration(milliseconds: 500),
      tween: Tween(begin: 0, end: 1),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.scale(
          scale: 0.95 + (0.05 * value), // 从0.95缩放到1.0
          child: child,
        ),
      ),
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: isDarkMode ? AppTheme.darkCardColor : Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDarkMode ? 0.3 : 0.08),
              blurRadius: 20,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 简洁的标题
            Row(
              children: [
                const Text(
                  '💌',
                  style: TextStyle(fontSize: 20),
                ),
                const SizedBox(width: 8),
                Text(
                  '分析结果',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: textColor,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            // 洞察内容 - flomo风格：简洁清晰的文本（可复制）
            SelectableText(
              _insightResult!,
              style: TextStyle(
                fontSize: 16,
                height: 1.8,
                color: textColor,
                letterSpacing: 0.3,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 🔥 自动滚动到结果区域
  void _scrollToResult() {
    // 延迟一下，确保Widget已经渲染完成
    Future.delayed(const Duration(milliseconds: 300), () {
      if (!mounted) {
        return;
      }

      try {
        // 获取结果区域的RenderBox
        final resultBox =
            _insightResultKey.currentContext?.findRenderObject() as RenderBox?;
        if (resultBox == null) {
          return;
        }

        // 计算需要滚动的位置（结果区域顶部 - 一些padding）
        final position = resultBox.localToGlobal(Offset.zero).dy;
        final scrollPosition =
            _scrollController.offset + position - 100; // 减去100px，留出一些空间

        // 平滑滚动到结果区域
        _scrollController.animateTo(
          scrollPosition,
          duration: const Duration(milliseconds: 600),
          curve: Curves.easeInOutCubic,
        );
      } on Object {
        // 如果出错，直接滚动到底部
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 600),
          curve: Curves.easeInOutCubic,
        );
      }
    });
  }

  // 清理Markdown符号，转换为纯文本
  String _cleanMarkdown(String text) {
    var cleaned = text;

    // 移除Markdown标题符号 (# ## ###)
    cleaned = cleaned.replaceAll(RegExp(r'^#+\s*', multiLine: true), '');

    // 移除加粗符号 (** __ )
    cleaned = cleaned.replaceAll(RegExp(r'\*\*(.*?)\*\*'), r'$1');
    cleaned = cleaned.replaceAll(RegExp('__(.*?)__'), r'$1');

    // 移除斜体符号 (* _)
    cleaned = cleaned.replaceAll(
      RegExp(r'(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)'),
      r'$1',
    );
    cleaned =
        cleaned.replaceAll(RegExp('(?<!_)_(?!_)(.+?)(?<!_)_(?!_)'), r'$1');

    // 移除删除线 (~~)
    cleaned = cleaned.replaceAll(RegExp('~~(.*?)~~'), r'$1');

    // 移除代码块符号 (```)
    cleaned = cleaned.replaceAll(RegExp(r'```[\s\S]*?```'), '');
    cleaned = cleaned.replaceAll(RegExp('`(.*?)`'), r'$1');

    // 移除链接格式 [text](url)
    cleaned = cleaned.replaceAll(RegExp(r'\[([^\]]+)\]\([^\)]+\)'), r'$1');

    // 移除图片格式 ![alt](url)
    cleaned = cleaned.replaceAll(RegExp(r'!\[([^\]]*)\]\([^\)]+\)'), r'$1');

    // 移除引用符号 (>)
    cleaned = cleaned.replaceAll(RegExp(r'^>\s*', multiLine: true), '');

    // 移除水平线 (--- ***)
    cleaned =
        cleaned.replaceAll(RegExp(r'^[\-\*]{3,}\s*$', multiLine: true), '');

    // 移除列表符号 (- * 1.)
    cleaned = cleaned.replaceAll(RegExp(r'^[\-\*\+]\s+', multiLine: true), '');
    cleaned = cleaned.replaceAll(RegExp(r'^\d+\.\s+', multiLine: true), '');

    // 清理多余的空行（保留段落间的单个空行）
    cleaned = cleaned.replaceAll(RegExp(r'\n{3,}'), '\n\n');

    return cleaned.trim();
  }

  Future<void> _startAnalysis() async {
    if (_filteredNotes.isEmpty) {
      SnackBarUtils.showWarning(
        context,
        AppLocalizationsSimple.of(context)?.noNotesMatchingCriteria ??
            '没有符合条件的笔记',
      );
      return;
    }

    setState(() {
      _isAnalyzing = true;
      _errorMessage = null;
      _insightResult = null;
    });

    try {
      final apiService = DeepSeekApiService(
        apiUrl: widget.appConfig.aiApiUrl!,
        apiKey: widget.appConfig.aiApiKey!,
        model: widget.appConfig.aiModel,
      );

      // 构建笔记内容摘要
      final notesSummary = _filteredNotes
          .take(50)
          .map(
            (note) =>
                '【${note.tags.join(', ')}】${note.content.length > 200 ? '${note.content.substring(0, 200)}...' : note.content}',
          )
          .join('\n\n');

      // 🎯 使用自定义Prompt或系统默认Prompt
      final systemPrompt = widget.appConfig.useCustomPrompt &&
              widget.appConfig.customInsightPrompt != null &&
              widget.appConfig.customInsightPrompt!.isNotEmpty
          ? widget.appConfig.customInsightPrompt!
          : '''
你是一位善于洞察的笔记分析师，用自然的对话方式提供完整的分析闭环。

输出格式要求（重要！）：
- 纯文本，绝对不要用 # * ** 等Markdown符号
- 不要用emoji
- 用"你"称呼用户
- 自然地直接进入内容，不要固定开头
- 分4段，每段2-3句话，段落间空一行

内容结构（完整闭环）：

第1段 - 整体观察：
用一个直接、有洞察力的句子开场，概括你看到的核心模式或特点。

第2段 - 值得肯定：
指出笔记中闪光的思考、有价值的探索方向，或值得保持的习惯。用"我注意到"、"这里有个亮点"等自然表述。

第3段 - 可改进之处：
坦诚地指出可以优化的地方，比如思考的盲区、缺失的连接，或值得深入的方向。用"或许可以"、"有个地方值得注意"等温和表述。

第4段 - 具体建议：
给出1-2条清晰、可操作的建议，帮助用户形成行动闭环。

写作风格：
- 像Notion AI那样：直接、专业、有温度
- 坦诚但不批评，建设性而非说教
- 每个部分自然过渡，不要生硬分段
- 保持对话感，避免报告感
''';

      var userPrompt = '请分析这${_filteredNotes.length}条笔记';
      if (_selectedTags.isNotEmpty) {
        userPrompt += '（标签：${_selectedTags.join(', ')}）';
      }
      if (_excludedTags.isNotEmpty) {
        userPrompt += '（排除：${_excludedTags.join(', ')}）';
      }
      if (_keywordController.text.isNotEmpty) {
        userPrompt += '（关键词：${_keywordController.text}）';
      }
      userPrompt +=
          '，按4段结构提供完整分析：整体观察、值得肯定、可改进之处、具体建议。\n\n笔记内容：\n\n$notesSummary';

      final messages = [
        DeepSeekApiService.buildSystemMessage(systemPrompt),
        DeepSeekApiService.buildUserMessage(userPrompt),
      ];

      final (result, error) = await apiService.chat(messages: messages);

      if (mounted) {
        setState(() {
          _isAnalyzing = false;
          if (error != null) {
            _errorMessage = error;
          } else {
            // 🔥 清理Markdown符号，得到纯文本结果
            _insightResult = result != null ? _cleanMarkdown(result) : null;
            // 🔥 分析完成后显示提示
            SnackBarUtils.showSuccess(context, '✨ AI洞察分析完成！');
            // 🔥 自动滚动到结果区域
            _scrollToResult();
          }
        });
      }
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _isAnalyzing = false;
          _errorMessage = 'AI分析失败: $e';
        });
      }
    }
  }
}
