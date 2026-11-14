import 'package:flutter/material.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/themes/app_theme.dart';
import 'package:inkpaper/utils/memos_content_helper.dart';
import 'package:intl/intl.dart';

/// 卡片时间戳格式：与列表里的笔记卡片一致（往年显示完整日期与时间）。
final DateFormat _onThisDayDateFormat = DateFormat('yyyy-MM-dd HH:mm');

/// 「那年今日」卡片：首页列表顶部的可滑动回顾。
///
/// 卡片里按年份从近到远排列往年同月同日的笔记，左右滑动切换；
/// 右上角的关闭按钮由调用方处理（当天不再出现）。
class OnThisDayCard extends StatefulWidget {
  const OnThisDayCard({
    required this.notes,
    required this.onClose,
    required this.onOpenNote,
    super.key,
  });

  /// 往年同月同日的笔记，第一条应是最近的年份（去年优先）。
  final List<Note> notes;

  /// 点关闭按钮：调用方负责持久化「今天不再展示」。
  final VoidCallback onClose;

  /// 点卡片正文：打开对应笔记详情。
  final ValueChanged<Note> onOpenNote;

  @override
  State<OnThisDayCard> createState() => _OnThisDayCardState();
}

class _OnThisDayCardState extends State<OnThisDayCard> {
  /// 单页高度：年份行 + 四行正文。
  static const double _pageHeight = 128;

  late final PageController _controller = PageController();
  int _currentIndex = 0;

  @override
  void didUpdateWidget(covariant OnThisDayCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.notes.length != oldWidget.notes.length) {
      _currentIndex = 0;
      if (_controller.hasClients) {
        _controller.jumpToPage(0);
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.notes.isEmpty) {
      return const SizedBox.shrink();
    }

    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final cardColor = isDarkMode ? AppTheme.darkCardColor : Colors.white;
    final textColor =
        isDarkMode ? AppTheme.darkTextPrimaryColor : AppTheme.textPrimaryColor;
    final secondaryTextColor = isDarkMode
        ? AppTheme.darkTextSecondaryColor
        : AppTheme.textSecondaryColor;
    // 卡片外观对齐列表里的笔记卡片：不用品牌绿描边，时间也是那套次级灰
    final timestampColor =
        isDarkMode ? const Color(0xFF8E8E93) : const Color(0xFF949494);
    final borderColor = isDarkMode
        ? Colors.white.withValues(alpha: 0.06)
        : Colors.black.withValues(alpha: 0.05);
    final multiple = widget.notes.length > 1;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Material(
        color: cardColor,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: borderColor, width: 0.5),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 6, 0),
              child: Row(
                children: [
                  OnThisDayBadge(label: '那年今日', color: timestampColor),
                  const Spacer(),
                  if (multiple)
                    Text(
                      '${_currentIndex + 1}/${widget.notes.length}',
                      style: TextStyle(
                        fontSize: 12,
                        color: secondaryTextColor,
                      ),
                    ),
                  IconButton(
                    icon: Icon(
                      Icons.close_rounded,
                      size: 16,
                      color: secondaryTextColor,
                    ),
                    tooltip: '关闭',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                    onPressed: widget.onClose,
                  ),
                ],
              ),
            ),
            SizedBox(
              height: _pageHeight,
              child: PageView.builder(
                controller: _controller,
                itemCount: widget.notes.length,
                onPageChanged: (index) => setState(() => _currentIndex = index),
                itemBuilder: (context, index) {
                  final note = widget.notes[index];
                  return _buildPage(
                    context,
                    note,
                    timestampColor: timestampColor,
                    textColor: textColor,
                    secondaryTextColor: secondaryTextColor,
                  );
                },
              ),
            ),
            if (multiple)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var i = 0; i < widget.notes.length; i++)
                      Container(
                        width: i == _currentIndex ? 14 : 5,
                        height: 5,
                        margin: const EdgeInsets.symmetric(horizontal: 2),
                        decoration: BoxDecoration(
                          color: i == _currentIndex
                              ? secondaryTextColor.withValues(alpha: 0.85)
                              : secondaryTextColor.withValues(alpha: 0.25),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildPage(
    BuildContext context,
    Note note, {
    required Color timestampColor,
    required Color textColor,
    required Color secondaryTextColor,
  }) {
    final preview = MemosContentHelper.previewVisibleText(note.content);

    return InkWell(
      onTap: () => widget.onOpenNote(note),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              // 不 toLocal：Memos 时间字段值是本地挂钟时间（详见 formatNoteTimestamp）
              _onThisDayDateFormat.format(note.createdAt),
              style: TextStyle(
                fontSize: 10,
                height: 1.1,
                fontWeight: FontWeight.w300,
                letterSpacing: 0.2,
                color: timestampColor,
              ),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: Text(
                preview.isEmpty ? '（无文字内容）' : preview,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.5,
                  color: preview.isEmpty ? secondaryTextColor : textColor,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 「那年今日」小胶囊标签，首页卡片与随机回顾页共用。
class OnThisDayBadge extends StatelessWidget {
  const OnThisDayBadge({
    required this.label,
    required this.color,
    super.key,
  });

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.history_rounded, size: 12, color: color),
            const SizedBox(width: 3),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ],
        ),
      );
}
