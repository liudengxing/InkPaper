import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:inkpaper/l10n/app_localizations_simple.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/providers/app_provider.dart';
import 'package:inkpaper/services/random_review_selector_service.dart';
import 'package:inkpaper/themes/app_theme.dart';
import 'package:inkpaper/utils/snackbar_utils.dart';
import 'package:inkpaper/utils/tag_utils.dart' as tag_utils;
import 'package:inkpaper/widgets/note_actions_ui.dart';
import 'package:inkpaper/widgets/note_card.dart';
import 'package:inkpaper/widgets/note_editor_page.dart';
import 'package:inkpaper/widgets/on_this_day_card.dart';
import 'package:inkpaper/widgets/sidebar.dart';
import 'package:provider/provider.dart';

class RandomReviewScreen extends StatefulWidget {
  const RandomReviewScreen({super.key});

  @override
  State<RandomReviewScreen> createState() => _RandomReviewScreenState();
}

class _RandomReviewScreenState extends State<RandomReviewScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final Random _random = Random();

  List<Note> _reviewNotes = [];

  /// 往年同月同日的笔记，作为信息流顶部的「那年今日」卡片（与首页同款）。
  List<Note> _onThisDayNotes = const <Note>[];
  bool _onThisDayDismissed = false;

  // 回顾设置
  int _reviewDays = 999999; // 默认回顾全部笔记

  /// 每批条数。随机回顾现在是信息流：一屏一批 N 条，下拉换下一批。
  int _reviewCount = 5;

  Set<String> _selectedTags = {}; // 选中的标签集合

  @override
  void initState() {
    super.initState();

    // 初始化时获取笔记
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadReviewNotes();
    });
  }

  // 加载回顾笔记
  //
  // [excludeIds] 非空时是「换一批」：这批刚看过的先排掉再抽。
  Future<void> _loadReviewNotes({
    Set<String> excludeIds = const <String>{},
  }) async {
    final appProvider = Provider.of<AppProvider>(context, listen: false);
    final allNotes = appProvider.notes;

    // 🕰️ 往年同月同日的笔记：独立成顶部的「那年今日」卡片，不占用本批名额
    var onThisDayNotes = const <Note>[];
    try {
      onThisDayNotes = await appProvider.loadNotesOnThisDay();
    } on Object catch (e) {
      debugPrint('RandomReview: 加载那年今日失败: $e');
    }
    if (!mounted) {
      return;
    }

    final selectedNotes = RandomReviewSelectorService.select(
      notes: allNotes,
      reviewDays: _reviewDays,
      reviewCount: _reviewCount,
      selectedTags: _selectedTags,
      excludeIds: excludeIds,
      random: _random,
    );

    setState(() {
      _reviewNotes = selectedNotes;
      _onThisDayNotes = onThisDayNotes;
    });
  }

  /// 换一批：整批换掉（下拉刷新与 AppBar 的「换一批」共用同一条路径）
  Future<void> _shuffleBatch() {
    return _loadReviewNotes(
      excludeIds: _reviewNotes.map((note) => note.id).toSet(),
    );
  }

  void _dismissOnThisDay() {
    setState(() {
      _onThisDayDismissed = true;
    });
  }

  /// 把某条笔记在 provider 里的最新对象换回本批。
  ///
  /// 本批存的是抽签那一刻的 Note 快照，编辑、置顶、勾待办之后 provider 里
  /// 已经是新对象了，不换回来卡片会一直显示旧内容。
  void _syncNoteFromProvider(String id) {
    if (!mounted) {
      return;
    }
    final batchIndex = _reviewNotes.indexWhere((note) => note.id == id);
    if (batchIndex == -1) {
      return;
    }
    final provider = Provider.of<AppProvider>(context, listen: false);
    final freshIndex = provider.notes.indexWhere((note) => note.id == id);
    if (freshIndex == -1) {
      return;
    }
    final fresh = provider.notes[freshIndex];
    setState(() {
      _reviewNotes[batchIndex] = fresh;
    });
  }

  /// 批次提示条：这一批有几条、怎么换下一批（下拉或右上角换一批）
  Widget _buildBatchHeader(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final subtleColor =
        isDarkMode ? AppTheme.darkTimestampColor : AppTheme.timestampColor;
    final l10n = AppLocalizationsSimple.of(context);
    final style = TextStyle(fontSize: 13, color: subtleColor);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      child: Row(
        children: [
          Text('${_reviewNotes.length} ${l10n?.noteUnit ?? '条'}', style: style),
          const Spacer(),
          Icon(Icons.arrow_downward_rounded, size: 13, color: subtleColor),
          const SizedBox(width: 4),
          Text(l10n?.refreshBatch ?? '换一批', style: style),
        ],
      ),
    );
  }

  // 🔥 获取所有可用的标签
  Set<String> _getAllTags() {
    final appProvider = Provider.of<AppProvider>(context, listen: false);
    final allNotes = appProvider.notes;
    final allTags = <String>{};

    // 使用改进的标签识别规则（排除URL中的#）
    for (final note in allNotes) {
      final tags = tag_utils.extractTagsFromContent(note.content);
      allTags.addAll(tags);
    }

    return allTags;
  }

  // 编辑已有笔记：走全屏编辑器，卡片只留给新建
  void _showEditNoteForm(Note note) {
    NoteEditorPage.open(
      context,
      noteId: note.id,
      initialContent: note.content,
      onSave: (content) async {
        if (content.trim().isEmpty) {
          return;
        }
        try {
          final appProvider = Provider.of<AppProvider>(context, listen: false);
          await appProvider.updateNote(note, content);
          if (!mounted || !context.mounted) {
            return;
          }
          // 改完原地换掉这一条，不重新抽签：整批换掉会让用户刚写的
          // 那一段从眼前消失
          _syncNoteFromProvider(note.id);
        } on Object catch (e) {
          if (mounted && context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  '${AppLocalizationsSimple.of(context)?.updatingFailed ?? '更新失败'}: $e',
                ),
                backgroundColor: Colors.red,
              ),
            );
          }
        }
      },
    );
  }

  // 🔥 显示iOS风格的设置页面
  void _showSettingsDialog() {
    var tempDays = _reviewDays;
    var tempCount = _reviewCount;
    var tempSelectedTags = Set<String>.from(_selectedTags);

    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final backgroundColor =
        isDarkMode ? AppTheme.darkCardColor : const Color(0xFFF2F2F7);
    final cardColor = isDarkMode ? const Color(0xFF2C2C2E) : Colors.white;
    final textColor = isDarkMode ? Colors.white : Colors.black87;
    final secondaryTextColor = isDarkMode ? Colors.grey[400] : Colors.grey[600];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (BuildContext context) => StatefulBuilder(
        builder: (BuildContext context, StateSetter setModalState) {
          final allTags = _getAllTags().toList()..sort();

          return Container(
            height: MediaQuery.of(context).size.height * 0.85,
            decoration: BoxDecoration(
              color: backgroundColor,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(20),
                topRight: Radius.circular(20),
              ),
            ),
            child: Column(
              children: [
                // 🔥 顶部拖动条和标题
                Container(
                  padding: const EdgeInsets.only(top: 12, bottom: 16),
                  decoration: BoxDecoration(
                    color: cardColor,
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(20),
                      topRight: Radius.circular(20),
                    ),
                  ),
                  child: Column(
                    children: [
                      // 拖动条
                      Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: secondaryTextColor,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(height: 16),
                      // 标题栏
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              AppLocalizationsSimple.of(context)
                                      ?.reviewSettings ??
                                  '回顾设置',
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w600,
                                color: textColor,
                              ),
                            ),
                            TextButton(
                              onPressed: () {
                                setState(() {
                                  _reviewDays = tempDays;
                                  _reviewCount = tempCount;
                                  _selectedTags = tempSelectedTags;
                                });
                                Navigator.pop(context);
                                _loadReviewNotes();
                              },
                              child: Text(
                                AppLocalizationsSimple.of(context)?.confirm ??
                                    '完成',
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: AppTheme.primaryColor,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

                // 🔥 设置内容（可滚动）
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.only(top: 20, bottom: 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 📅 时间范围设置
                        Container(
                          margin: const EdgeInsets.symmetric(horizontal: 16),
                          decoration: BoxDecoration(
                            color: cardColor,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            children: [
                              _buildSettingItem(
                                title: AppLocalizationsSimple.of(context)
                                        ?.reviewTimeRange ??
                                    '时间范围',
                                trailing: _buildOptionButton(
                                  tempDays == 999999
                                      ? (AppLocalizationsSimple.of(context)
                                              ?.all ??
                                          '全部')
                                      : '$tempDays ${AppLocalizationsSimple.of(context)?.dayUnit ?? '天'}',
                                  () => _showTimeRangePicker(context, tempDays,
                                      (value) {
                                    setModalState(() {
                                      tempDays = value;
                                    });
                                  }),
                                  isDarkMode,
                                ),
                                isDarkMode: isDarkMode,
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(height: 16),

                        // 📊 回顾数量设置
                        Container(
                          margin: const EdgeInsets.symmetric(horizontal: 16),
                          decoration: BoxDecoration(
                            color: cardColor,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            children: [
                              _buildSettingItem(
                                title: AppLocalizationsSimple.of(context)
                                        ?.reviewNotesCount ??
                                    '笔记数量',
                                trailing: _buildOptionButton(
                                  '$tempCount ${AppLocalizationsSimple.of(context)?.noteUnit ?? '条'}',
                                  () => _showCountPicker(context, tempCount,
                                      (value) {
                                    setModalState(() {
                                      tempCount = value;
                                    });
                                  }),
                                  isDarkMode,
                                ),
                                isDarkMode: isDarkMode,
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(height: 16),

                        // 🏷️ 标签筛选
                        if (allTags.isNotEmpty) ...[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(32, 8, 32, 8),
                            child: Text(
                              '🏷️ 标签筛选',
                              style: TextStyle(
                                fontSize: 13,
                                color: secondaryTextColor,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                          Container(
                            margin: const EdgeInsets.symmetric(horizontal: 16),
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: cardColor,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // 全选/取消全选按钮
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Flexible(
                                      child: Text(
                                        tempSelectedTags.isEmpty
                                            ? '选择标签（全部）'
                                            : '已选 ${tempSelectedTags.length} 个标签',
                                        style: TextStyle(
                                          fontSize: 14,
                                          color: secondaryTextColor,
                                          fontWeight: FontWeight.w500,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    TextButton(
                                      onPressed: () {
                                        setModalState(() {
                                          if (tempSelectedTags.isEmpty) {
                                            tempSelectedTags =
                                                Set.from(allTags);
                                          } else {
                                            tempSelectedTags.clear();
                                          }
                                        });
                                      },
                                      style: TextButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                          vertical: 4,
                                        ),
                                        minimumSize: Size.zero,
                                        tapTargetSize:
                                            MaterialTapTargetSize.shrinkWrap,
                                      ),
                                      child: Text(
                                        tempSelectedTags.isEmpty ? '全选' : '清空',
                                        style: const TextStyle(
                                          fontSize: 13,
                                          color: AppTheme.primaryColor,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                // 🔥 标签网格（限制最大高度，可滚动）
                                ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxHeight: 300, // 最大高度限制，避免溢出
                                  ),
                                  child: SingleChildScrollView(
                                    child: Wrap(
                                      spacing: 8,
                                      runSpacing: 8,
                                      children: allTags.map((tag) {
                                        final isSelected =
                                            tempSelectedTags.contains(tag);
                                        return GestureDetector(
                                          onTap: () {
                                            setModalState(() {
                                              if (isSelected) {
                                                tempSelectedTags.remove(tag);
                                              } else {
                                                tempSelectedTags.add(tag);
                                              }
                                            });
                                          },
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 12,
                                              vertical: 6,
                                            ),
                                            decoration: BoxDecoration(
                                              color: isSelected
                                                  ? AppTheme.primaryColor
                                                  : (isDarkMode
                                                      ? Colors.grey[800]
                                                      : Colors.grey[200]),
                                              borderRadius:
                                                  BorderRadius.circular(16),
                                              border: Border.all(
                                                color: isSelected
                                                    ? AppTheme.primaryColor
                                                    : Colors.transparent,
                                                width: 1.5,
                                              ),
                                            ),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                if (isSelected)
                                                  const Padding(
                                                    padding: EdgeInsets.only(
                                                      right: 4,
                                                    ),
                                                    child: Icon(
                                                      Icons.check,
                                                      size: 14,
                                                      color: Colors.white,
                                                    ),
                                                  ),
                                                Text(
                                                  '#$tag',
                                                  style: TextStyle(
                                                    fontSize: 13,
                                                    color: isSelected
                                                        ? Colors.white
                                                        : textColor,
                                                    fontWeight: isSelected
                                                        ? FontWeight.w600
                                                        : FontWeight.normal,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        );
                                      }).toList(),
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
              ],
            ),
          );
        },
      ),
    );
  }

  // 🔥 构建设置项
  Widget _buildSettingItem({
    required String title,
    required Widget trailing,
    required bool isDarkMode,
    String? subtitle,
    VoidCallback? onTap,
  }) {
    final textColor = isDarkMode ? Colors.white : Colors.black87;
    final secondaryTextColor = isDarkMode ? Colors.grey[400] : Colors.grey[600];

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 16,
                      color: textColor,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 13,
                        color: secondaryTextColor,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            trailing,
          ],
        ),
      ),
    );
  }

  // 🔥 构建选项按钮
  Widget _buildOptionButton(String text, VoidCallback onTap, bool isDarkMode) =>
      GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: (isDarkMode ? Colors.grey[800] : Colors.grey[100]),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                text,
                style: const TextStyle(
                  fontSize: 14,
                  color: AppTheme.primaryColor,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: 4),
              const Icon(
                Icons.arrow_forward_ios,
                size: 12,
                color: AppTheme.primaryColor,
              ),
            ],
          ),
        ),
      );

  // 🔥 显示时间范围选择器
  void _showTimeRangePicker(
    BuildContext context,
    int currentValue,
    Function(int) onSelect,
  ) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final options = [7, 14, 30, 60, 90, 180, 365, 999999];

    showModalBottomSheet(
      context: context,
      backgroundColor: isDarkMode ? AppTheme.darkCardColor : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(20),
          topRight: Radius.circular(20),
        ),
      ),
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.6,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  AppLocalizationsSimple.of(context)?.reviewTimeRange ??
                      '选择时间范围',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: isDarkMode ? Colors.white : Colors.black87,
                  ),
                ),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: options.length,
                  itemBuilder: (context, index) {
                    final days = options[index];
                    final isSelected = days == currentValue;
                    return ListTile(
                      title: Text(
                        days == 999999
                            ? (AppLocalizationsSimple.of(context)?.all ?? '全部')
                            : '$days ${AppLocalizationsSimple.of(context)?.dayUnit ?? '天'}',
                        style: TextStyle(
                          color: isSelected ? AppTheme.primaryColor : null,
                          fontWeight:
                              isSelected ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                      trailing: isSelected
                          ? const Icon(
                              Icons.check,
                              color: AppTheme.primaryColor,
                            )
                          : null,
                      onTap: () {
                        onSelect(days);
                        Navigator.pop(context);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 🔥 显示数量选择器
  void _showCountPicker(
    BuildContext context,
    int currentValue,
    Function(int) onSelect,
  ) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final options = [1, 5, 10, 20, 30, 50, 100];

    showModalBottomSheet(
      context: context,
      backgroundColor: isDarkMode ? AppTheme.darkCardColor : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(20),
          topRight: Radius.circular(20),
        ),
      ),
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.6,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  AppLocalizationsSimple.of(context)?.reviewNotesCount ??
                      '选择笔记数量',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: isDarkMode ? Colors.white : Colors.black87,
                  ),
                ),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: options.length,
                  itemBuilder: (context, index) {
                    final count = options[index];
                    final isSelected = count == currentValue;
                    return ListTile(
                      title: Text(
                        '$count ${AppLocalizationsSimple.of(context)?.noteUnit ?? '条'}',
                        style: TextStyle(
                          color: isSelected ? AppTheme.primaryColor : null,
                          fontWeight:
                              isSelected ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                      trailing: isSelected
                          ? const Icon(
                              Icons.check,
                              color: AppTheme.primaryColor,
                            )
                          : null,
                      onTap: () {
                        onSelect(count);
                        Navigator.pop(context);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 打开侧边栏
  void _openDrawer() {
    _scaffoldKey.currentState?.openDrawer();
  }

  @override
  Widget build(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final backgroundColor =
        isDarkMode ? AppTheme.darkBackgroundColor : AppTheme.backgroundColor;
    final textColor =
        isDarkMode ? AppTheme.darkTextPrimaryColor : Colors.black87;
    final secondaryTextColor = isDarkMode ? Colors.grey[400] : Colors.grey[600];
    final iconColor =
        isDarkMode ? AppTheme.primaryLightColor : AppTheme.primaryColor;

    // 侧边栏由DesktopLayout处理

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
          icon: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: backgroundColor,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 16,
                  height: 2,
                  decoration: BoxDecoration(
                    color: iconColor,
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
                const SizedBox(height: 4),
                Container(
                  width: 10,
                  height: 2,
                  decoration: BoxDecoration(
                    color: iconColor,
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
              ],
            ),
          ),
          onPressed: _openDrawer,
        ),
        centerTitle: true,
        title: Text(
          AppLocalizationsSimple.of(context)?.randomReviewTitle ?? '随机回顾',
          style: TextStyle(
            color: textColor,
            fontWeight: FontWeight.w600,
            fontSize: 18,
          ),
        ),
        actions: [
          // 🔀 换一批：重新随机抽样
          IconButton(
            tooltip: AppLocalizationsSimple.of(context)?.refreshBatch ?? '换一批',
            icon: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: backgroundColor,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                Icons.shuffle_rounded,
                size: 20,
                color: iconColor,
              ),
            ),
            onPressed: _shuffleBatch,
          ),
          IconButton(
            icon: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: backgroundColor,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                Icons.settings,
                size: 20,
                color: iconColor,
              ),
            ),
            onPressed: _showSettingsDialog,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Consumer<AppProvider>(
        builder: (context, appProvider, _) {
          if (appProvider.isLoading) {
            return const Center(
              child: CircularProgressIndicator(),
            );
          }

          final hasOnThisDay =
              !_onThisDayDismissed && _onThisDayNotes.isNotEmpty;

          if (_reviewNotes.isEmpty && !hasOnThisDay) {
            // 空态也要能下拉重试，所以不能直接给一个 Center
            return RefreshIndicator(
              onRefresh: _loadReviewNotes,
              color: AppTheme.primaryColor,
              child: LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight,
                    ),
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.event_note,
                            size: 80,
                            color: isDarkMode
                                ? Colors.grey.shade700
                                : Colors.grey.shade300,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            AppLocalizationsSimple.of(context)
                                    ?.noNotesToReview ??
                                '没有可回顾的笔记',
                            style: TextStyle(
                              fontSize: 16,
                              color: secondaryTextColor,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          }

          // 信息流：和首页同一套卡片（NoteCard，12dp 圆角、左右 12、间距 8），
          // 一屏一批，下拉整批换。
          return RefreshIndicator(
            onRefresh: _shuffleBatch,
            color: AppTheme.primaryColor,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.only(top: 4, bottom: 96),
              children: [
                if (_reviewNotes.isNotEmpty) _buildBatchHeader(context),
                if (hasOnThisDay)
                  OnThisDayCard(
                    notes: _onThisDayNotes,
                    onClose: _dismissOnThisDay,
                    onOpenNote: (note) => context.push('/note/${note.id}'),
                  ),
                for (final note in _reviewNotes)
                  NoteCard(
                    key: ValueKey('review_${note.id}'),
                    note: note,
                    onEdit: () => _showEditNoteForm(note),
                    // 卡片内的编辑/置顶不重新抽签，只把这一个对象换成新的，
                    // 否则刚改完的内容会被下一批顶掉
                    onNoteUpdated: () => _syncNoteFromProvider(note.id),
                    onDelete: () {
                      // 与首页、详情页收敛到同一条删除路径（含撤销条）
                      NoteActionsUi.deleteNote(
                        context: context,
                        note: note,
                        onDeleted: () {
                          setState(() {
                            _reviewNotes.removeWhere((n) => n.id == note.id);
                          });
                        },
                      );
                    },
                    onPin: () async {
                      final willPin = !note.isPinned;
                      await appProvider.togglePinStatus(note);
                      _syncNoteFromProvider(note.id);
                      if (!context.mounted) {
                        return;
                      }
                      SnackBarUtils.showSuccess(
                        context,
                        willPin
                            ? (AppLocalizationsSimple.of(context)?.pinned ??
                                '已置顶')
                            : (AppLocalizationsSimple.of(context)?.unpinned ??
                                '已取消置顶'),
                      );
                    },
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}
