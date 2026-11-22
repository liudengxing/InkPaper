import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/providers/app_provider.dart';
import 'package:inkpaper/themes/app_theme.dart';
import 'package:inkpaper/utils/home_tag_filter.dart';
import 'package:inkpaper/utils/tag_input_helper.dart';
import 'package:provider/provider.dart';

/// 首页标签屏蔽的选择页。
///
/// 交互对齐随机回顾那套：**选择即保存**，没有「完成」按钮。屏蔽是个反复
/// 微调的动作，让人先勾一堆再点保存，中途退出还会怀疑到底存没存。
class HomeTagFilterScreen extends StatefulWidget {
  const HomeTagFilterScreen({super.key});

  @override
  State<HomeTagFilterScreen> createState() => _HomeTagFilterScreenState();
}

/// 一个标签在列表里的样子：名字、用了多少条笔记。
typedef _TagEntry = ({String tag, int count});

class _HomeTagFilterScreenState extends State<HomeTagFilterScreen> {
  final TextEditingController _searchController = TextEditingController();
  bool _loading = true;
  List<_TagEntry> _tags = const <_TagEntry>[];
  String _query = '';

  @override
  void initState() {
    super.initState();
    _loadTags();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// 标签清单必须查全库。
  ///
  /// 首页的 `appProvider.notes` 只是 50 条一页的缓存，用它统计出来的标签
  /// 只覆盖最近那批，用户想屏蔽一个去年的标签会发现列表里根本没有。
  Future<void> _loadTags() async {
    final provider = Provider.of<AppProvider>(context, listen: false);
    var notes = const <Note>[];
    try {
      notes = await provider.databaseService.getNotes();
    } on Object catch (error) {
      debugPrint('HomeTagFilterScreen: 读取笔记失败: $error');
    }

    final counts = <String, int>{};
    final usage = <TagUsageEntry>[];
    for (final note in notes) {
      final tags = collectNoteTags(note);
      if (tags.isEmpty) {
        continue;
      }
      usage.add((tags: tags.toList(), updatedAt: note.updatedAt));
      for (final tag in tags) {
        counts[tag] = (counts[tag] ?? 0) + 1;
      }
    }

    final ranked = <_TagEntry>[
      for (final tag in rankTagsByUsage(notes: usage))
        (tag: tag, count: counts[tag] ?? 0),
    ];

    if (!mounted) {
      return;
    }
    setState(() {
      _tags = ranked;
      _loading = false;
    });
  }

  /// 这个标签是不是已经在屏蔽范围内（可能是它自己，也可能被父标签带着）。
  bool _isCovered(String tag, Set<String> hidden) {
    for (final blocked in hidden) {
      if (tag == blocked || tag.startsWith('$blocked/')) {
        return true;
      }
    }
    return false;
  }

  Future<void> _toggleTag(String tag) async {
    final provider = Provider.of<AppProvider>(context, listen: false);
    final next = Set<String>.from(provider.hiddenHomeTags);
    if (next.contains(tag)) {
      next.remove(tag);
    } else if (next.any((blocked) => tag.startsWith('$blocked/'))) {
      // 被父标签带着屏蔽：点一下等于取消那个父标签，否则点了没反应。
      next.removeWhere((blocked) => tag.startsWith('$blocked/'));
    } else {
      next.add(tag);
    }
    await provider.setHomeHiddenTags(next);
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _clearAll() async {
    final provider = Provider.of<AppProvider>(context, listen: false);
    if (!provider.hasHiddenHomeTags) {
      return;
    }
    await provider.setHomeHiddenTags(const <String>[]);
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final backgroundColor =
        isDarkMode ? AppTheme.darkBackgroundColor : AppTheme.backgroundColor;
    final textColor =
        isDarkMode ? AppTheme.darkTextPrimaryColor : AppTheme.textPrimaryColor;
    final secondaryTextColor = isDarkMode
        ? AppTheme.darkTextSecondaryColor
        : AppTheme.textSecondaryColor;
    final provider = Provider.of<AppProvider>(context);

    // 已屏蔽但库里已经删干净的标签也要留在列表里，否则用户永远取消不掉。
    final hidden = provider.hiddenHomeTags;
    final hiddenNotListed = hidden
        .where((tag) => !_tags.any((entry) => entry.tag == tag))
        .toList()
      ..sort();
    final all = <_TagEntry>[
      ..._tags,
      for (final tag in hiddenNotListed) (tag: tag, count: 0),
    ];
    final query = _query.trim().toLowerCase();
    final visible = query.isEmpty
        ? all
        : all
            .where((entry) => entry.tag.toLowerCase().contains(query))
            .toList();

    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(
        backgroundColor: backgroundColor,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          icon: Icon(
            Icons.arrow_back_ios_new,
            size: 20,
            color:
                isDarkMode ? AppTheme.primaryLightColor : AppTheme.primaryColor,
          ),
          onPressed: () => context.pop(),
        ),
        title: Text(
          '首页标签屏蔽',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: textColor,
          ),
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Column(
          children: [
            _buildIntro(secondaryTextColor),
            _buildSearchField(isDarkMode),
            _buildSummary(
              hiddenCount: hidden.length,
              textColor: textColor,
              secondaryTextColor: secondaryTextColor,
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : visible.isEmpty
                      ? _buildEmptyState(secondaryTextColor)
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                          itemCount: visible.length,
                          itemBuilder: (context, index) {
                            final entry = visible[index];
                            return _buildTagRow(
                              entry: entry,
                              selected: _isCovered(entry.tag, hidden),
                              isDarkMode: isDarkMode,
                              textColor: textColor,
                              secondaryTextColor: secondaryTextColor,
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildIntro(Color secondaryTextColor) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
      child: Text(
        '被屏蔽标签的笔记不会出现在首页信息流。搜索、标签页、AI 洞察和随机回顾不受影响。',
        style: TextStyle(
          fontSize: 13,
          height: 1.5,
          color: secondaryTextColor,
        ),
      ),
    );
  }

  Widget _buildSearchField(bool isDarkMode) {
    final fillColor = isDarkMode
        ? Colors.white.withValues(alpha: 0.06)
        : const Color(0xFFF2F2F5);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: TextField(
        controller: _searchController,
        style: TextStyle(
          fontSize: 15,
          color: isDarkMode ? Colors.white : Colors.black87,
        ),
        onChanged: (value) => setState(() => _query = value),
        decoration: InputDecoration(
          hintText: '搜索标签',
          hintStyle: TextStyle(
            fontSize: 15,
            color: isDarkMode ? Colors.grey[500] : Colors.grey[500],
          ),
          prefixIcon: Icon(
            Icons.search,
            size: 20,
            color: isDarkMode ? Colors.grey[400] : Colors.grey[500],
          ),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  color: isDarkMode ? Colors.grey[400] : Colors.grey[500],
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _query = '');
                  },
                ),
          filled: true,
          fillColor: fillColor,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }

  Widget _buildSummary({
    required int hiddenCount,
    required Color textColor,
    required Color secondaryTextColor,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 12, 6),
      child: Row(
        children: [
          Text(
            hiddenCount == 0 ? '未屏蔽任何标签' : '已屏蔽 $hiddenCount 个标签',
            style: TextStyle(fontSize: 13, color: secondaryTextColor),
          ),
          const Spacer(),
          if (hiddenCount > 0)
            TextButton(
              onPressed: _clearAll,
              style: TextButton.styleFrom(
                minimumSize: Size.zero,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('全部取消', style: TextStyle(fontSize: 13)),
            ),
        ],
      ),
    );
  }

  Widget _buildTagRow({
    required _TagEntry entry,
    required bool selected,
    required bool isDarkMode,
    required Color textColor,
    required Color secondaryTextColor,
  }) {
    final accent =
        isDarkMode ? AppTheme.primaryLightColor : AppTheme.primaryColor;
    final cardColor = isDarkMode ? AppTheme.darkCardColor : Colors.white;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _toggleTag(entry.tag),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: cardColor,
              borderRadius: BorderRadius.circular(12),
              border: selected
                  ? Border.all(color: accent.withValues(alpha: 0.5))
                  : null,
            ),
            child: Row(
              children: [
                Icon(
                  selected
                      ? Icons.check_circle_rounded
                      : Icons.radio_button_unchecked_rounded,
                  size: 22,
                  color: selected
                      ? accent
                      : secondaryTextColor.withValues(alpha: 0.5),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '#${entry.tag}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                      color: textColor,
                    ),
                  ),
                ),
                Text(
                  '${entry.count} 条',
                  style: TextStyle(fontSize: 13, color: secondaryTextColor),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState(Color secondaryTextColor) {
    final searching = _query.trim().isNotEmpty;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.label_off_outlined,
            size: 52,
            color: secondaryTextColor.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 12),
          Text(
            searching ? '没有匹配的标签' : '还没有任何标签',
            style: TextStyle(fontSize: 15, color: secondaryTextColor),
          ),
          const SizedBox(height: 6),
          Text(
            searching ? '换个关键词试试' : '笔记里带上 #标签 之后会出现在这里',
            style: TextStyle(fontSize: 13, color: secondaryTextColor),
          ),
        ],
      ),
    );
  }
}
