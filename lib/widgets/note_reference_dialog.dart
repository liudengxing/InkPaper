import 'package:flutter/material.dart';
import 'package:inkpaper/l10n/app_localizations_simple.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/themes/app_theme.dart';
import 'package:intl/intl.dart';

/// 选择要引用的笔记（「引用笔记」对话框）。
///
/// 从 `note_editor.dart` 独立出来：它只吃 `isDarkMode / allNotes /
/// onReferenceSelected` 三个入参，跟编辑器状态机毫无关系，放在编辑器里
/// 会让那个文件多背 380 行。
class NoteReferenceDialog extends StatefulWidget {
  const NoteReferenceDialog({
    required this.isDarkMode,
    required this.allNotes,
    required this.onReferenceSelected,
    super.key,
  });
  final bool isDarkMode;
  final List<Note> allNotes;
  final ValueChanged<String> onReferenceSelected;

  @override
  State<NoteReferenceDialog> createState() => _NoteReferenceDialogState();
}

class _NoteReferenceDialogState extends State<NoteReferenceDialog> {
  final TextEditingController _searchController = TextEditingController();
  List<Note> _filteredNotes = [];

  @override
  void initState() {
    super.initState();
    _filteredNotes = widget.allNotes;
    _searchController.addListener(_filterNotes);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _filterNotes() {
    final query = _searchController.text.toLowerCase();
    setState(() {
      if (query.isEmpty) {
        _filteredNotes = widget.allNotes;
      } else {
        _filteredNotes = widget.allNotes
            .where((note) => note.content.toLowerCase().contains(query))
            .toList();
      }
    });
  }

  @override
  Widget build(BuildContext context) => Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 20),
        backgroundColor: Colors.transparent,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: widget.isDarkMode ? AppTheme.darkCardColor : Colors.white,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.15),
                blurRadius: 25,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 标题区域
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      AppTheme.primaryColor.withValues(alpha: 0.1),
                      AppTheme.primaryColor.withValues(alpha: 0.05),
                    ],
                  ),
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(20),
                    topRight: Radius.circular(20),
                  ),
                ),
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppTheme.primaryColor.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(50),
                      ),
                      child: const Icon(
                        Icons.link,
                        color: AppTheme.primaryColor,
                        size: 24,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      AppLocalizationsSimple.of(context)?.addNoteReference ??
                          '添加笔记引用',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                        color: widget.isDarkMode
                            ? Colors.white
                            : AppTheme.textPrimaryColor,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      AppLocalizationsSimple.of(context)
                              ?.selectNoteToReference ??
                          '选择要引用的笔记，建立笔记间的关联关系',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        color: (widget.isDarkMode
                                ? Colors.white
                                : AppTheme.textPrimaryColor)
                            .withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ),
              ),

              // 搜索框
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                child: TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText:
                        AppLocalizationsSimple.of(context)?.searchNoteContent ??
                            '搜索笔记内容...',
                    prefixIcon: Icon(
                      Icons.search,
                      color: AppTheme.primaryColor.withValues(alpha: 0.7),
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(
                        color: AppTheme.primaryColor.withValues(alpha: 0.3),
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(
                        color: AppTheme.primaryColor,
                        width: 2,
                      ),
                    ),
                    filled: true,
                    fillColor: widget.isDarkMode
                        ? Colors.white.withValues(alpha: 0.05)
                        : Colors.grey.shade50,
                  ),
                  style: TextStyle(
                    color: widget.isDarkMode
                        ? Colors.white
                        : AppTheme.textPrimaryColor,
                  ),
                ),
              ),

              // 笔记列表
              Container(
                constraints: const BoxConstraints(maxHeight: 350),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: _filteredNotes.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(32),
                        child: Column(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: Colors.grey.shade100,
                                borderRadius: BorderRadius.circular(50),
                              ),
                              child: Icon(
                                widget.allNotes.isEmpty
                                    ? Icons.note_outlined
                                    : Icons.search_off,
                                size: 32,
                                color: Colors.grey.shade400,
                              ),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              widget.allNotes.isEmpty
                                  ? (AppLocalizationsSimple.of(context)
                                          ?.noNotesToReference ??
                                      '暂无笔记可引用')
                                  : (AppLocalizationsSimple.of(context)
                                          ?.noMatchingNotes ??
                                      '没有找到相关笔记'),
                              style: TextStyle(
                                color: Colors.grey.shade600,
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              widget.allNotes.isEmpty
                                  ? (AppLocalizationsSimple.of(context)
                                          ?.createNotesFirstToReference ??
                                      '先创建一些笔记再来建立引用关系')
                                  : (AppLocalizationsSimple.of(context)
                                          ?.tryOtherKeywords ??
                                      '试试其他关键词'),
                              style: TextStyle(
                                color: Colors.grey.shade500,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(left: 8, bottom: 12),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.notes,
                                  size: 16,
                                  color: AppTheme.primaryColor,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  AppLocalizationsSimple.of(context)
                                          ?.foundNotesCount
                                          .replaceAll(
                                            '{count}',
                                            '${_filteredNotes.length}',
                                          ) ??
                                      '找到 ${_filteredNotes.length} 个笔记',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                    color: AppTheme.primaryColor,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Expanded(
                            child: ListView.builder(
                              itemCount: _filteredNotes.length,
                              itemBuilder: (context, index) {
                                final note = _filteredNotes[index];
                                final preview = note.content.length > 40
                                    ? '${note.content.substring(0, 40)}...'
                                    : note.content;

                                return Container(
                                  margin: const EdgeInsets.only(bottom: 8),
                                  child: InkWell(
                                    onTap: () =>
                                        widget.onReferenceSelected(note.id),
                                    borderRadius: BorderRadius.circular(12),
                                    child: Container(
                                      padding: const EdgeInsets.all(12),
                                      decoration: BoxDecoration(
                                        color: widget.isDarkMode
                                            ? Colors.white
                                                .withValues(alpha: 0.05)
                                            : Colors.grey.shade50,
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(
                                          color: AppTheme.primaryColor
                                              .withValues(alpha: 0.1),
                                        ),
                                      ),
                                      child: Row(
                                        children: [
                                          Container(
                                            padding: const EdgeInsets.all(8),
                                            decoration: BoxDecoration(
                                              color: AppTheme.primaryColor
                                                  .withValues(alpha: 0.1),
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                            ),
                                            child: const Icon(
                                              Icons.note_outlined,
                                              color: AppTheme.primaryColor,
                                              size: 16,
                                            ),
                                          ),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  preview,
                                                  style: TextStyle(
                                                    fontSize: 14,
                                                    fontWeight: FontWeight.w500,
                                                    color: widget.isDarkMode
                                                        ? AppTheme
                                                            .darkTextPrimaryColor
                                                        : AppTheme
                                                            .textPrimaryColor,
                                                  ),
                                                  maxLines: 2,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                                const SizedBox(height: 4),
                                                Text(
                                                  DateFormat('yyyy-MM-dd HH:mm')
                                                      .format(note.createdAt),
                                                  style: TextStyle(
                                                    fontSize: 11,
                                                    color: (widget.isDarkMode
                                                            ? AppTheme
                                                                .darkTextSecondaryColor
                                                            : AppTheme
                                                                .textSecondaryColor)
                                                        .withValues(alpha: 0.8),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          Icon(
                                            Icons.add_link,
                                            size: 16,
                                            color: AppTheme.primaryColor
                                                .withValues(alpha: 0.7),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
              ),

              // 底部按钮
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                child: SizedBox(
                  width: double.infinity,
                  child: TextButton(
                    onPressed: () => Navigator.pop(context),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      backgroundColor: widget.isDarkMode
                          ? AppTheme.primaryColor.withValues(alpha: 0.1)
                          : AppTheme.primaryColor.withValues(alpha: 0.05),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: Text(
                      AppLocalizationsSimple.of(context)?.cancel ?? '取消',
                      style: const TextStyle(
                        color: AppTheme.primaryColor,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
}
