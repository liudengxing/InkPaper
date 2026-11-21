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
import 'package:inkpaper/utils/tag_input_helper.dart';
import 'package:inkpaper/utils/tag_utils.dart' as tag_utils;
import 'package:inkpaper/widgets/note_actions_ui.dart';
import 'package:inkpaper/widgets/note_card.dart';
import 'package:inkpaper/widgets/note_editor_page.dart';
import 'package:inkpaper/widgets/on_this_day_card.dart';
import 'package:inkpaper/widgets/sidebar.dart';
import 'package:inkpaper/widgets/slide_out_row.dart';
import 'package:intl/intl.dart';
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

  /// 正在播放退场动效的行：确认删除后先滑出去，播完再真删。
  final Set<String> _leavingNoteIds = <String>{};
  final Map<String, Completer<void>> _noteExitCompleters =
      <String, Completer<void>>{};

  /// 往年同月同日的笔记，作为信息流顶部的「那年今日」卡片（与首页同款）。
  List<Note> _onThisDayNotes = const <Note>[];
  bool _onThisDayDismissed = false;

  // 回顾设置
  //
  // 时间范围只有 7 / 30 / 180 / 365 四档加自定义（自定义走日期区间选择器），
  // 默认 30 天：覆盖最近一个月的记录，池子又不至于大到抽出来的都是旧笔记。
  int _reviewDays = 30;

  /// 自定义区间（含首尾两天）；非空时优先于 [_reviewDays]。
  DateTimeRange? _customRange;

  /// 每批条数。随机回顾现在是信息流：一屏一批 N 条，下拉换下一批。
  int _reviewCount = 5;

  final Set<String> _selectedTags = <String>{}; // 选中的标签集合

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

    final customRange = _customRange;
    final selectedNotes = RandomReviewSelectorService.select(
      notes: allNotes,
      reviewDays: _reviewDays,
      // 区间选择器给的是自然日，右边界要挪到次日 0 点，否则最后一天整天被排除
      customStart: customRange == null
          ? null
          : DateTime(
              customRange.start.year,
              customRange.start.month,
              customRange.start.day,
            ),
      customEnd: customRange == null
          ? null
          : DateTime(
              customRange.end.year,
              customRange.end.month,
              customRange.end.day + 1,
            ),
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

  /// 播放一行的退场动效，等播完（或 400ms 兜底）再返回。
  Future<void> _playNoteExit(String noteId) {
    if (!mounted) {
      return Future<void>.value();
    }
    final completer = Completer<void>();
    setState(() {
      _leavingNoteIds.add(noteId);
      _noteExitCompleters[noteId] = completer;
    });
    return completer.future.timeout(
      const Duration(milliseconds: 400),
      onTimeout: () {},
    );
  }

  void _handleNoteExitFinished(String noteId) {
    _noteExitCompleters.remove(noteId)?.complete();
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
          // 原来是「↓ 换一批」：箭头容易被读成「可以点」，但它本来就是
          // 下拉手势的提示。直接写中文，不用猜。
          Text('下拉换一批', style: style),
        ],
      ),
    );
  }

  /// 设置页的标签清单。
  ///
  /// 两个来源取并集：库里的 `tags` 字段（Memos 同步过来的标签常常只存在
  /// 这里）和正文里的 `#标签`。只看正文会少一大截，用户会以为标签丢了。
  ///
  /// 排序直接用编辑器那套「最近 + 最常用」加权分（utils/tag_input_helper），
  /// 不另立一套字典序。
  List<String> _getRankedTags() {
    final notes = Provider.of<AppProvider>(context, listen: false).notes;
    final entries = <TagUsageEntry>[];
    for (final note in notes) {
      final tags = <String>{
        ...note.tags,
        ...tag_utils.extractTagsFromContent(note.content),
      };
      if (tags.isEmpty) {
        continue;
      }
      entries.add((tags: tags.toList(), updatedAt: note.updatedAt));
    }
    return rankTagsByUsage(notes: entries);
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

  // ── 回顾设置 ─────────────────────────────────────────────
  //
  // 选择即保存：没有「完成」按钮，改哪一项立刻生效，关掉面板时统一重算
  // 一批。这样用户不必猜「我改了到底存没存」。
  Future<void> _showSettingsDialog() async {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final backgroundColor =
        isDarkMode ? AppTheme.darkCardColor : const Color(0xFFF4F4F6);
    final cardColor = isDarkMode ? const Color(0xFF2C2C2E) : Colors.white;
    final textColor = isDarkMode ? Colors.white : Colors.black87;
    final secondaryTextColor = isDarkMode ? Colors.grey[400] : Colors.grey[600];
    final rankedTags = _getRankedTags();
    final searchController = TextEditingController();
    var searchText = '';

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setModalState) {
          final query = searchText.trim().toLowerCase();
          final visibleTags = query.isEmpty
              ? rankedTags
              : rankedTags
                  .where((tag) => tag.toLowerCase().contains(query))
                  .toList();

          // 立刻写回页面状态 + 刷新面板上的当前值
          void apply(VoidCallback change) {
            setState(change);
            setModalState(() {});
          }

          // 高度按内容走，最多占屏幕 82%：内容少的时候不要留一大片空白，
          // 标签一多再自己长到上限内滚动。键盘弹起时按 viewInsets 再收一收。
          return ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.82 -
                  MediaQuery.of(context).viewInsets.bottom,
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: backgroundColor,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(20),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                    child: Column(
                      children: [
                        Container(
                          width: 40,
                          height: 4,
                          decoration: BoxDecoration(
                            color: secondaryTextColor,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Row(
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
                            const SizedBox(width: 8),
                            Padding(
                              padding: const EdgeInsets.only(top: 3),
                              child: Text(
                                '选择即保存',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: secondaryTextColor,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                      children: [
                        _settingsCard(
                          cardColor,
                          children: [
                            _buildSettingItem(
                              title: '时间范围',
                              trailing: _buildOptionButton(
                                _timeRangeLabel(),
                                () => _showTimeRangePicker(
                                  (days, customRange) {
                                    apply(() {
                                      _reviewDays = days;
                                      _customRange = customRange;
                                    });
                                  },
                                ),
                                isDarkMode,
                              ),
                              isDarkMode: isDarkMode,
                            ),
                            _settingsDivider(isDarkMode),
                            _buildSettingItem(
                              title: '笔记数量',
                              trailing: _buildOptionButton(
                                '$_reviewCount ${AppLocalizationsSimple.of(context)?.noteUnit ?? '条'}',
                                () => _showCountPicker(
                                  context,
                                  _reviewCount,
                                  (value) => apply(() => _reviewCount = value),
                                ),
                                isDarkMode,
                              ),
                              isDarkMode: isDarkMode,
                            ),
                          ],
                        ),
                        const SizedBox(height: 20),
                        if (rankedTags.isNotEmpty) ...[
                          Row(
                            children: [
                              Text(
                                '🏷️ 标签筛选',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: secondaryTextColor,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                _selectedTags.isEmpty
                                    ? '全部'
                                    : '已选 ${_selectedTags.length} 个',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: (secondaryTextColor ?? Colors.grey)
                                      .withValues(alpha: 0.8),
                                ),
                              ),
                              const Spacer(),
                              // 搜索框放在标签区右上角：标签一多就得靠它，
                              // 放在整页顶部会和「时间范围」抢注意力。
                              SizedBox(
                                width: 148,
                                height: 34,
                                child: TextField(
                                  controller: searchController,
                                  onChanged: (value) => setModalState(
                                    () => searchText = value,
                                  ),
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: textColor,
                                  ),
                                  decoration: InputDecoration(
                                    isDense: true,
                                    hintText: '搜索标签',
                                    hintStyle: TextStyle(
                                      fontSize: 12.5,
                                      color: secondaryTextColor,
                                    ),
                                    prefixIcon: Icon(
                                      Icons.search_rounded,
                                      size: 16,
                                      color: secondaryTextColor,
                                    ),
                                    prefixIconConstraints: const BoxConstraints(
                                      minWidth: 30,
                                    ),
                                    contentPadding: const EdgeInsets.symmetric(
                                      vertical: 8,
                                      horizontal: 8,
                                    ),
                                    filled: true,
                                    fillColor: isDarkMode
                                        ? Colors.white.withValues(alpha: 0.06)
                                        : const Color(0xFFF2F2F5),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(9),
                                      borderSide: BorderSide.none,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          _settingsCard(
                            cardColor,
                            children: [
                              Padding(
                                padding: const EdgeInsets.all(14),
                                child: visibleTags.isEmpty
                                    ? Text(
                                        '没有匹配的标签',
                                        style: TextStyle(
                                          fontSize: 13,
                                          color: secondaryTextColor,
                                        ),
                                      )
                                    : Wrap(
                                        spacing: 8,
                                        runSpacing: 8,
                                        children: [
                                          for (final tag in visibleTags)
                                            _buildTagChip(
                                              tag: tag,
                                              selected:
                                                  _selectedTags.contains(tag),
                                              isDarkMode: isDarkMode,
                                              textColor: textColor,
                                              onTap: () => apply(() {
                                                if (_selectedTags
                                                    .contains(tag)) {
                                                  _selectedTags.remove(tag);
                                                } else {
                                                  _selectedTags.add(tag);
                                                }
                                              }),
                                            ),
                                        ],
                                      ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );

    searchController.dispose();
    if (mounted) {
      await _loadReviewNotes();
    }
  }

  Widget _settingsCard(Color color, {required List<Widget> children}) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(children: children),
    );
  }

  Widget _settingsDivider(bool isDarkMode) => Divider(
        height: 0.5,
        thickness: 0.5,
        indent: 16,
        endIndent: 16,
        color: isDarkMode
            ? Colors.white.withValues(alpha: 0.06)
            : Colors.black.withValues(alpha: 0.05),
      );

  Widget _buildTagChip({
    required String tag,
    required bool selected,
    required bool isDarkMode,
    required Color textColor,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? AppTheme.primaryColor
              : (isDarkMode ? Colors.grey[800] : Colors.grey[200]),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? AppTheme.primaryColor : Colors.transparent,
            width: 1.5,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (selected)
              const Padding(
                padding: EdgeInsets.only(right: 4),
                child: Icon(Icons.check, size: 14, color: Colors.white),
              ),
            Text(
              '#$tag',
              style: TextStyle(
                fontSize: 13,
                color: selected ? Colors.white : textColor,
                fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
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

  /// 当前时间范围的展示文案：档位写「30 天」，自定义写「10.1 - 10.20」。
  String _timeRangeLabel() {
    final range = _customRange;
    if (range == null) {
      return '$_reviewDays 天';
    }
    final format = DateFormat('M.d');
    return '${format.format(range.start)} - ${format.format(range.end)}';
  }

  /// 时间范围选择：7 / 30 / 180 / 365 天 + 自定义（日期区间选择器）。
  Future<void> _showTimeRangePicker(
    void Function(int days, DateTimeRange? customRange) onSelect,
  ) async {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    const presets = <int>[7, 30, 180, 365];
    final currentIsCustom = _customRange != null;

    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: isDarkMode ? AppTheme.darkCardColor : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                '时间范围',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: isDarkMode ? Colors.white : Colors.black87,
                ),
              ),
            ),
            for (final days in presets)
              ListTile(
                title: Text(
                  '$days 天',
                  style: TextStyle(
                    color: !currentIsCustom && days == _reviewDays
                        ? AppTheme.primaryColor
                        : null,
                    fontWeight: !currentIsCustom && days == _reviewDays
                        ? FontWeight.w600
                        : FontWeight.normal,
                  ),
                ),
                trailing: !currentIsCustom && days == _reviewDays
                    ? const Icon(Icons.check, color: AppTheme.primaryColor)
                    : null,
                onTap: () => Navigator.pop(sheetContext, '$days'),
              ),
            ListTile(
              title: Text(
                '自定义',
                style: TextStyle(
                  color: currentIsCustom ? AppTheme.primaryColor : null,
                  fontWeight:
                      currentIsCustom ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
              subtitle: currentIsCustom
                  ? Text(
                      _timeRangeLabel(),
                      style: const TextStyle(fontSize: 12),
                    )
                  : null,
              trailing: currentIsCustom
                  ? const Icon(Icons.check, color: AppTheme.primaryColor)
                  : const Icon(Icons.chevron_right_rounded),
              onTap: () => Navigator.pop(sheetContext, 'custom'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );

    if (!mounted || choice == null) {
      return;
    }

    if (choice == 'custom') {
      final now = DateTime.now();
      final picked = await showDateRangePicker(
        context: context,
        firstDate: DateTime(now.year - 5),
        lastDate: now,
        initialDateRange: _customRange ??
            DateTimeRange(
              start: now.subtract(const Duration(days: 30)),
              end: now,
            ),
        helpText: '选择回顾的时间范围',
        saveText: '确定',
        cancelText: '取消',
      );
      if (picked == null) {
        return;
      }
      onSelect(_reviewDays, picked);
      return;
    }

    onSelect(int.parse(choice), null);
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
          // 换一批只走下拉手势（列表顶部的提示条已经写明「下拉换一批」），
          // 右上角再放一个 shuffle 按钮是重复的第二入口，删掉。
          IconButton(
            tooltip:
                AppLocalizationsSimple.of(context)?.reviewSettings ?? '回顾设置',
            icon: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: backgroundColor,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                Icons.settings,
                size: 20,
                // 设置是低频入口，用灰色而不是品牌色，别抢标题的注意力
                color: isDarkMode ? Colors.grey[400] : Colors.grey[600],
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
                  SlideOutRow(
                    key: ValueKey('review_exit_${note.id}'),
                    leaving: _leavingNoteIds.contains(note.id),
                    onExited: () => _handleNoteExitFinished(note.id),
                    child: NoteCard(
                      key: ValueKey('review_${note.id}'),
                      note: note,
                      playDeleteExit: () => _playNoteExit(note.id),
                      onEdit: () => _showEditNoteForm(note),
                      // 卡片内的编辑/置顶不重新抽签，只把这一个对象换成新的，
                      // 否则刚改完的内容会被下一批顶掉
                      onNoteUpdated: () => _syncNoteFromProvider(note.id),
                      onDelete: () {
                        // 与首页、详情页同一条删除路径：二次确认 + 行退出
                        NoteActionsUi.deleteNote(
                          context: context,
                          note: note,
                          playExit: () => _playNoteExit(note.id),
                          onDeleted: () {
                            setState(() {
                              _reviewNotes.removeWhere((n) => n.id == note.id);
                              _leavingNoteIds.remove(note.id);
                              _noteExitCompleters.remove(note.id)?.complete();
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
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}
