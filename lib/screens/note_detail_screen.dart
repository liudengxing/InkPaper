import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:inkpaper/l10n/app_localizations_simple.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/providers/app_provider.dart';
import 'package:inkpaper/services/ai_enhanced_service.dart';
import 'package:inkpaper/services/ai_review_service.dart';
import 'package:inkpaper/services/memos_resource_service.dart';
import 'package:inkpaper/services/user_behavior_service.dart';
import 'package:inkpaper/themes/app_theme.dart';
import 'package:inkpaper/utils/image_utils.dart';
import 'package:inkpaper/utils/logger.dart';
import 'package:inkpaper/utils/memos_content_helper.dart';
import 'package:inkpaper/utils/note_timestamp_format.dart';
import 'package:inkpaper/utils/snackbar_utils.dart';
import 'package:inkpaper/utils/tag_path_utils.dart';
import 'package:inkpaper/utils/tag_utils.dart' as tag_utils;
import 'package:inkpaper/utils/text_style_helper.dart';
import 'package:inkpaper/utils/todo_parser.dart';
import 'package:inkpaper/widgets/note_editor.dart';
import 'package:inkpaper/widgets/note_image_grid.dart';
import 'package:inkpaper/widgets/note_more_options_menu.dart';
import 'package:inkpaper/widgets/note_preview_text.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

class NoteDetailScreen extends StatefulWidget {
  const NoteDetailScreen({required this.noteId, super.key});
  final String noteId;

  @override
  State<NoteDetailScreen> createState() => _NoteDetailScreenState();
}

class _NoteDetailScreenState extends State<NoteDetailScreen> {
  Note? _note;

  // 🧠 本地 AI 学习偏好：浏览时长埋点（覆盖所有进入详情页的入口）
  final UserBehaviorService _behaviorService = UserBehaviorService();
  final Stopwatch _viewStopwatch = Stopwatch()..start();
  bool _viewRecorded = false;

  // AI 摘要
  final AIEnhancedService _aiEnhancedService = AIEnhancedService();
  final AiReviewService _aiReviewService = const AiReviewService();
  String? _aiSummary;
  bool _isGeneratingSummary = false;
  bool _showSummary = false;

  /// 图片路径只在笔记数据变化时算一次。放在 build 里的话，
  /// 每次 setState 都要重跑一遍全文正则。
  List<String> _renderImagePaths = const <String>[];

  @override
  void initState() {
    super.initState();
    _loadNote();
  }

  @override
  void dispose() {
    // 🧠 离开详情页时回填本次浏览时长
    _completeViewTracking();
    super.dispose();
  }

  /// 把本次浏览的时长交给偏好服务；配不上对就由服务侧另落一条记录。
  void _completeViewTracking() {
    if (_viewRecorded) {
      return;
    }
    _viewRecorded = true;
    final note = _note;
    if (note == null) {
      return;
    }
    _viewStopwatch.stop();
    unawaited(
      _behaviorService.completeView(
        noteId: note.id,
        noteTags: note.tags,
        viewDurationSeconds: _viewStopwatch.elapsed.inSeconds,
      ),
    );
  }

  /// 统一更新笔记，并同步图片路径缓存。只能在 setState 内调用。
  void _setNote(Note? note) {
    _note = note;
    if (note == null) {
      _renderImagePaths = const <String>[];
      return;
    }
    _renderImagePaths = MemosContentHelper.extractNoteImagePaths(note);
  }

  Future<void> _loadNote() async {
    final appProvider = Provider.of<AppProvider>(context, listen: false);
    final note = appProvider.getNoteById(widget.noteId) ??
        await appProvider.databaseService.getNoteById(widget.noteId);
    if (!mounted) {
      return;
    }
    setState(() {
      _setNote(note);
    });
  }

  /// 九宫格长按：服务端资源要补全 URL 和鉴权头再交给保存流程。
  void _showGridImageSaveDialog(String path) {
    final appProvider = Provider.of<AppProvider>(context, listen: false);
    if (MemosResourceService.isServerResourcePath(path)) {
      final service = appProvider.resourceService;
      final baseUrl = appProvider.appConfig.memosApiUrl ??
          appProvider.appConfig.lastServerUrl ??
          '';
      final fullUrl = service != null
          ? service.buildImageUrl(path)
          : (baseUrl.isEmpty ? path : '$baseUrl$path');
      final token = appProvider.user?.token;
      ImageUtils.showImageSaveDialog(
        context,
        fullUrl,
        headers: token != null ? {'Authorization': 'Bearer $token'} : null,
      );
      return;
    }
    ImageUtils.showImageSaveDialog(context, path);
  }

  // 🔥 处理链接点击
  Future<void> _handleLinkTap(String? href) async {
    if (href == null || href.isEmpty) {
      return;
    }

    try {
      // 处理笔记内部引用：NotePreviewText 传来的 ref:<encodedId>，
      // 兼容旧的 [[noteId]] 形式
      if (href.startsWith('ref:') || href.startsWith('[[')) {
        final encoded = href.startsWith('ref:')
            ? href.substring(4)
            : href.substring(2, href.length - 2);
        var noteId = Uri.decodeComponent(encoded);
        // memos/ 前缀（Memos 引用约定）与查询参数一并剥掉
        if (noteId.startsWith('memos/')) {
          noteId = noteId.substring(6);
        }
        noteId = noteId.split('?').first.trim();
        if (noteId.isNotEmpty && mounted) {
          final appProvider = Provider.of<AppProvider>(context, listen: false);
          final exists = appProvider.getNoteById(noteId) != null ||
              await appProvider.databaseService.getNoteById(noteId) != null;
          if (!mounted) {
            return;
          }
          if (!exists) {
            SnackBarUtils.showError(
              context,
              AppLocalizationsSimple.of(context)?.referenceNoteMissing(
                    noteId,
                  ) ??
                  '引用的笔记不存在或已被删除 (ID: $noteId)',
            );
            return;
          }
          unawaited(
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (context) => NoteDetailScreen(noteId: noteId),
              ),
            ),
          );
        }
        return;
      }

      // 处理外部链接
      final uri = Uri.parse(href);
      if (await canLaunchUrl(uri)) {
        await launchUrl(
          uri,
          mode: LaunchMode.externalApplication,
        );
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  const Icon(Icons.error, color: Colors.white),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '${AppLocalizationsSimple.of(context)?.unableToOpenLink ?? '无法打开链接'}: $href',
                    ),
                  ),
                ],
              ),
              backgroundColor: Colors.orange,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          );
        }
      }
    } on Object catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.error, color: Colors.white),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '${AppLocalizationsSimple.of(context)?.linkError ?? '链接错误'}: $e',
                  ),
                ),
              ],
            ),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        );
      }
    }
  }

  // 🔥 AI点评功能 - 大厂风格底部Sheet
  Future<void> _showAiReviewDialog() async {
    if (_note == null) {
      return;
    }

    final appProvider = Provider.of<AppProvider>(context, listen: false);
    final appConfig = appProvider.appConfig;

    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    String? aiReview;
    var isLoading = true;
    String? errorMessage;
    var reviewSource = AiReviewSource.local;

    // 🔥 使用底部Sheet替代Dialog - 更现代的体验
    unawaited(
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (bottomSheetContext) => StatefulBuilder(
          builder: (context, setState) {
            // 开始点评。AI 未配置或失败时使用本地分析，不阻断用户。
            if (isLoading && aiReview == null && errorMessage == null) {
              _aiReviewService
                  .generateReview(
                appConfig: appConfig,
                note: _note!,
                allNotes: appProvider.notes,
              )
                  .then((result) {
                if (mounted && context.mounted) {
                  setState(() {
                    isLoading = false;
                    aiReview = result.review;
                    reviewSource = result.source;
                    errorMessage = null;
                  });
                  // 🔥 完成后显示提示
                  if (result.usedRemote) {
                    SnackBarUtils.showSuccess(
                      context,
                      AppLocalizationsSimple.of(context)?.aiReviewCompleted ??
                          '✨ AI点评完成！',
                    );
                  } else if (result.usedFallback) {
                    SnackBarUtils.showInfo(
                      context,
                      'AI暂不可用，已使用本地点评',
                    );
                  }
                }
              });
            }

            // 🔥 大厂风格的底部Sheet
            return Container(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.8,
              ),
              decoration: BoxDecoration(
                color: isDarkMode ? AppTheme.darkCardColor : Colors.white,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(24)),
                boxShadow: [
                  BoxShadow(
                    color:
                        Colors.black.withValues(alpha: isDarkMode ? 0.5 : 0.1),
                    blurRadius: 20,
                    offset: const Offset(0, -2),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 🔥 拖动指示器 - iOS风格
                  Container(
                    margin: const EdgeInsets.only(top: 12, bottom: 8),
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: (isDarkMode ? Colors.white : Colors.black)
                          .withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),

                  // 🔥 标题栏 - 简洁现代
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                    child: Row(
                      children: [
                        const Text(
                          '💬',
                          style: TextStyle(fontSize: 24),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            reviewSource == AiReviewSource.remote
                                ? (AppLocalizationsSimple.of(context)
                                        ?.aiReviewTitle ??
                                    '给你的点评')
                                : '本地点评',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: isDarkMode
                                  ? Colors.white
                                  : AppTheme.textPrimaryColor,
                              letterSpacing: 0.3,
                            ),
                          ),
                        ),
                        if (!isLoading)
                          IconButton(
                            icon: Icon(
                              Icons.close,
                              color: (isDarkMode ? Colors.white : Colors.black)
                                  .withValues(alpha: 0.5),
                            ),
                            onPressed: () => Navigator.pop(context),
                          ),
                      ],
                    ),
                  ),

                  // 🔥 内容区域 - flomo风格
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: isLoading
                          ? Center(
                              child: Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 60),
                                child: Column(
                                  children: [
                                    const CircularProgressIndicator(),
                                    const SizedBox(height: 20),
                                    Text(
                                      AppLocalizationsSimple.of(context)
                                              ?.aiReadingNote ??
                                          'AI正在阅读笔记...',
                                      style: TextStyle(
                                        color: (isDarkMode
                                                ? Colors.white
                                                : Colors.black)
                                            .withValues(alpha: 0.6),
                                        fontSize: 15,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            )
                          : errorMessage != null
                              ? Center(
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 60,
                                    ),
                                    child: Column(
                                      children: [
                                        const Icon(
                                          Icons.error_outline,
                                          color: Colors.red,
                                          size: 48,
                                        ),
                                        const SizedBox(height: 16),
                                        Text(
                                          errorMessage!,
                                          textAlign: TextAlign.center,
                                          style: const TextStyle(
                                            color: Colors.red,
                                            fontSize: 14,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                )
                              : Padding(
                                  padding: const EdgeInsets.only(bottom: 24),
                                  child: _buildReviewContent(
                                    aiReview!,
                                    isDarkMode,
                                  ),
                                ),
                    ),
                  ),

                  // 🔥 底部按钮 - 简洁设计
                  if (!isLoading && aiReview != null)
                    SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Row(
                          children: [
                            // 复制按钮
                            OutlinedButton.icon(
                              onPressed: () async {
                                await Clipboard.setData(
                                  ClipboardData(text: aiReview!),
                                );
                                if (mounted && context.mounted) {
                                  SnackBarUtils.showSuccess(
                                    context,
                                    AppLocalizationsSimple.of(context)
                                            ?.reviewCopiedShort ??
                                        '✨ 点评已复制',
                                  );
                                }
                              },
                              icon: const Icon(Icons.copy_rounded, size: 18),
                              label: Text(
                                AppLocalizationsSimple.of(context)
                                        ?.copyContent ??
                                    '复制',
                              ),
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 24,
                                  vertical: 14,
                                ),
                                side: const BorderSide(
                                  color: AppTheme.primaryColor,
                                ),
                                foregroundColor: AppTheme.primaryColor,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            // 完成按钮
                            Expanded(
                              child: ElevatedButton(
                                onPressed: () => Navigator.pop(context),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppTheme.primaryColor,
                                  foregroundColor: Colors.white,
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 14),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  elevation: 0,
                                ),
                                child: const Text(
                                  '完成',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  // 🔥 flomo风格的点评内容展示 - 带淡入动画
  Widget _buildReviewContent(String review, bool isDarkMode) =>
      TweenAnimationBuilder<double>(
        duration: const Duration(milliseconds: 500),
        tween: Tween(begin: 0, end: 1),
        curve: Curves.easeOutCubic,
        builder: (context, value, child) => Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, 20 * (1 - value)), // 从下往上淡入
            child: child,
          ),
        ),
        child: Text(
          review,
          style: TextStyle(
            fontSize: 16,
            height: 1.8,
            color: isDarkMode ? Colors.white : AppTheme.textPrimaryColor,
            letterSpacing: 0.3,
          ),
        ),
      );

  void _showEditNoteForm(Note note) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => NoteEditor(
        initialContent: note.content,
        onSave: (content) async {
          if (content.trim().isNotEmpty) {
            try {
              final appProvider =
                  Provider.of<AppProvider>(context, listen: false);
              await appProvider.updateNote(note, content);
              await _loadNote(); // 重新加载笔记
              if (mounted && context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Row(
                      children: [
                        const Icon(Icons.check_circle, color: Colors.white),
                        const SizedBox(width: 12),
                        Text(
                          AppLocalizationsSimple.of(context)?.noteUpdated ??
                              '笔记已更新',
                        ),
                      ],
                    ),
                    backgroundColor: Colors.green,
                    behavior: SnackBarBehavior.floating,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    duration: const Duration(seconds: 1),
                  ),
                );
              }
            } on Object catch (e) {
              if (mounted && context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Row(
                      children: [
                        const Icon(Icons.error, color: Colors.white),
                        const SizedBox(width: 12),
                        Text(
                          '${AppLocalizationsSimple.of(context)?.updateFailed ?? '更新失败'}: $e',
                        ),
                      ],
                    ),
                    backgroundColor: Colors.red,
                    behavior: SnackBarBehavior.floating,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    duration: const Duration(seconds: 2),
                  ),
                );
              }
            }
          }
        },
      ),
    );
  }

  // 显示更多选项菜单（统一使用 NoteMoreOptionsMenu）
  void _showMoreOptions(BuildContext btnContext) {
    if (_note == null) {
      return;
    }

    NoteMoreOptionsMenu.show(
      context: btnContext,
      note: _note!,
      onNoteUpdated: _loadNote,
    );
  }

  // 🎯 切换笔记中指定索引的待办事项
  void _toggleTodoInNote(int todoIndex) {
    if (_note == null) {
      return;
    }

    final previousNote = _note!;
    final todos = TodoParser.parseTodos(previousNote.content);
    if (todoIndex < 0 || todoIndex >= todos.length) {
      if (kDebugMode) {
        debugPrint('NoteDetailScreen: 待办事项索引越界 $todoIndex/${todos.length}');
      }
      return;
    }

    final todo = todos[todoIndex];
    final newContent =
        TodoParser.toggleTodoAtLine(previousNote.content, todo.lineNumber);
    if (kDebugMode) {
      debugPrint(
        'NoteDetailScreen: 切换待办事项 #$todoIndex 行${todo.lineNumber}: "${todo.text}"',
      );
    }

    setState(() {
      _setNote(
        previousNote.copyWith(
          content: newContent,
          updatedAt: DateTime.now(),
          tags: tag_utils.extractTagsFromContent(newContent),
          isSynced: false,
        ),
      );
    });

    final appProvider = Provider.of<AppProvider>(context, listen: false);
    appProvider.updateNote(previousNote, newContent).then((success) {
      if (kDebugMode) {
        debugPrint('NoteDetailScreen: 待办事项状态已更新 success=$success');
      }
      if (!mounted) {
        return;
      }
      if (success) {
        _loadNote(); // 刷新笔记数据
      } else {
        setState(() => _setNote(previousNote));
        SnackBarUtils.showError(
          context,
          AppLocalizationsSimple.of(context)?.updateFailed ?? '更新失败',
        );
      }
    }).catchError((error) {
      if (kDebugMode) {
        debugPrint('NoteDetailScreen: 更新待办事项失败: $error');
      }
      if (!mounted) {
        return;
      }
      setState(() => _setNote(previousNote));
      SnackBarUtils.showError(
        context,
        AppLocalizationsSimple.of(context)?.updateFailed ?? '更新失败',
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_note == null) {
      return Scaffold(
        appBar: AppBar(
          title: Text(AppLocalizationsSimple.of(context)?.noteDetail ?? '笔记详情'),
        ),
        body: const Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final bgColor =
        isDarkMode ? AppTheme.darkBackgroundColor : AppTheme.backgroundColor;
    final cardColor = isDarkMode ? AppTheme.darkCardColor : Colors.white;
    final textColor =
        isDarkMode ? AppTheme.darkTextPrimaryColor : Colors.black87;
    final secondaryTextColor =
        isDarkMode ? Colors.grey[400]! : const Color(0xFF666666);
    final iconColor =
        isDarkMode ? AppTheme.primaryLightColor : AppTheme.primaryColor;

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        elevation: 0,
        backgroundColor: Colors.transparent,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios, size: 20, color: iconColor),
          onPressed: () => Navigator.of(context).pop(),
        ),
        centerTitle: true,
        title: Text(
          AppLocalizationsSimple.of(context)?.noteDetail ?? '笔记详情',
          style: TextStyle(
            color: textColor,
            fontWeight: FontWeight.w600,
            fontSize: 18,
          ),
        ),
        actions: [
          // 📝 AI 摘要按钮
          IconButton(
            icon: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color:
                    _showSummary ? iconColor.withValues(alpha: 0.1) : bgColor,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(Icons.article_outlined, size: 20, color: iconColor),
            ),
            tooltip:
                AppLocalizationsSimple.of(context)?.aiSummary ?? 'AI Summary',
            onPressed: () {
              if (_showSummary && _aiSummary != null) {
                setState(() => _showSummary = false);
              } else {
                _generateAISummary();
              }
            },
          ),
          // 🔥 AI点评按钮
          IconButton(
            icon: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: BorderRadius.circular(8),
              ),
              child:
                  Icon(Icons.rate_review_rounded, size: 20, color: iconColor),
            ),
            tooltip: AppLocalizationsSimple.of(context)?.aiReview ?? 'AI点评',
            onPressed: _showAiReviewDialog,
          ),
          // 编辑按钮
          IconButton(
            icon: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(Icons.edit, size: 20, color: iconColor),
            ),
            tooltip: AppLocalizationsSimple.of(context)?.editNote ?? '编辑笔记',
            onPressed: () => _showEditNoteForm(_note!),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Center(
        child: Container(
          padding: const EdgeInsets.all(16),
          child: Card(
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(12)),
            ),
            color: cardColor,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 顶部：时间 + 更多按钮
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 详情页展示创建时间：最后编辑时间会随待办等
                          // 操作不断变化，不便于定位这条笔记是什么时候记下的。
                          // 样式对齐首页卡片：flomo 缩减式 + 10sp 浅灰细字。
                          Text(
                            formatNoteTimestamp(_note!.createdAt),
                            style: TextStyle(
                              fontSize: 10,
                              height: 1.1,
                              fontWeight: FontWeight.w300,
                              letterSpacing: 0.2,
                              color: isDarkMode
                                  ? const Color(0xFF8E8E93)
                                  : const Color(0xFF949494),
                            ),
                          ),
                          if (_note!.reminderTime != null) ...[
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                const Icon(
                                  Icons.alarm,
                                  size: 14,
                                  color: AppTheme.primaryColor,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  '提醒: ${DateFormat('MM-dd HH:mm').format(_note!.reminderTime!)}',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: AppTheme.primaryColor,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                      Builder(
                        builder: (btnContext) => InkWell(
                          onTap: () => _showMoreOptions(btnContext),
                          child: Icon(
                            Icons.more_horiz,
                            color: isDarkMode
                                ? Colors.grey.shade400
                                : AppTheme.textPrimaryColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // 中间：笔记内容（双击编辑）
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onDoubleTap: () {
                        if (kDebugMode) {
                          debugPrint('🖱️ 双击检测到，打开编辑');
                        }
                        _showEditNoteForm(_note!);
                      },
                      child: SingleChildScrollView(
                        physics: const BouncingScrollPhysics(),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // AI 摘要卡片
                            if (_showSummary)
                              AnimatedContainer(
                                duration: const Duration(milliseconds: 300),
                                margin: const EdgeInsets.only(bottom: 16),
                                padding: const EdgeInsets.all(16),
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    colors: isDarkMode
                                        ? [
                                            AppTheme.primaryColor
                                                .withValues(alpha: 0.1),
                                            AppTheme.accentColor
                                                .withValues(alpha: 0.1),
                                          ]
                                        : [
                                            AppTheme.primaryColor
                                                .withValues(alpha: 0.05),
                                            AppTheme.accentColor
                                                .withValues(alpha: 0.05),
                                          ],
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                  ),
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                    color: iconColor.withValues(alpha: 0.3),
                                    width: 1.5,
                                  ),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.all(8),
                                          decoration: BoxDecoration(
                                            gradient: LinearGradient(
                                              colors: [
                                                iconColor,
                                                AppTheme.accentColor,
                                              ],
                                            ),
                                            borderRadius:
                                                BorderRadius.circular(8),
                                          ),
                                          child: const Icon(
                                            Icons.auto_awesome,
                                            color: Colors.white,
                                            size: 16,
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        Text(
                                          AppLocalizationsSimple.of(context)
                                                  ?.aiSummary ??
                                              'AI Summary',
                                          style: const TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        const Spacer(),
                                        IconButton(
                                          icon:
                                              const Icon(Icons.close, size: 18),
                                          onPressed: () => setState(
                                            () => _showSummary = false,
                                          ),
                                          padding: EdgeInsets.zero,
                                          constraints: const BoxConstraints(),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 12),
                                    if (_isGeneratingSummary)
                                      Center(
                                        child: Column(
                                          children: [
                                            SizedBox(
                                              width: 24,
                                              height: 24,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                                valueColor:
                                                    AlwaysStoppedAnimation<
                                                        Color>(
                                                  iconColor,
                                                ),
                                              ),
                                            ),
                                            const SizedBox(height: 8),
                                            Text(
                                              '正在生成摘要...',
                                              style: TextStyle(
                                                fontSize: 13,
                                                color: secondaryTextColor,
                                              ),
                                            ),
                                          ],
                                        ),
                                      )
                                    else if (_aiSummary != null)
                                      Text(
                                        _aiSummary!,
                                        style: TextStyle(
                                          fontSize: 14,
                                          height: 1.6,
                                          color: textColor,
                                        ),
                                      ),
                                  ],
                                ),
                              ),

                            // 原有的笔记内容：与首页卡片同源（NotePreviewText
                            // 轻量渲染），图片单独走九宫格
                            Builder(
                              builder: (context) {
                                final serverUrl = Provider.of<AppProvider>(
                                  context,
                                  listen: false,
                                ).appConfig.memosApiUrl;

                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    NotePreviewText(
                                      content: _note!.content,
                                      style: AppTextStyles.bodyLarge(
                                        context,
                                        height: 1.6,
                                        color: textColor,
                                      ),
                                      accentColor: isDarkMode
                                          ? AppTheme.primaryLightColor
                                          : AppTheme.primaryColor,
                                      selectable: true,
                                      onCheckboxTap: _toggleTodoInNote,
                                      onTagTap: (tagName) {
                                        try {
                                          final tagPath =
                                              normalizeIncomingTagPath(tagName);
                                          if (tagPath == null) {
                                            return;
                                          }
                                          context.pushNamed(
                                            'tag-notes',
                                            queryParameters: {
                                              'tag': tagPath,
                                            },
                                          );
                                        } on Object catch (e, stackTrace) {
                                          Log.ui.error(
                                            'Failed to navigate from note detail tag',
                                            error: e,
                                            stackTrace: stackTrace,
                                            data: {'tagName': tagName},
                                          );
                                        }
                                      },
                                      onLinkTap: _handleLinkTap,
                                    ),
                                    // 图片统一走九宫格，长按弹保存菜单
                                    if (_renderImagePaths.isNotEmpty) ...[
                                      const SizedBox(height: 10),
                                      NoteImageGrid(
                                        imagePaths: _renderImagePaths,
                                        serverUrl: serverUrl,
                                        onLongPress: _showGridImageSaveDialog,
                                      ),
                                    ],
                                  ],
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),

                // 底部：字数统计
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    '${_note!.content.length} 字',
                    style: TextStyle(
                      fontSize: 14,
                      color: secondaryTextColor,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 生成 AI 摘要
  Future<void> _generateAISummary() async {
    if (_note == null || _isGeneratingSummary) {
      return;
    }

    setState(() {
      _isGeneratingSummary = true;
      _showSummary = true;
    });

    try {
      final appProvider = Provider.of<AppProvider>(context, listen: false);

      // 获取 AI 配置
      final apiKey = appProvider.appConfig.aiApiKey;
      final apiUrl = appProvider.appConfig.aiApiUrl;
      final model = appProvider.appConfig.aiModel;

      // 检查配置
      if (apiKey == null ||
          apiKey.isEmpty ||
          apiUrl == null ||
          apiUrl.isEmpty) {
        SnackBarUtils.showError(
          context,
          AppLocalizationsSimple.of(context)?.aiApiConfigRequired ??
              'Please configure AI API in settings first',
        );
        setState(() {
          _isGeneratingSummary = false;
          _showSummary = false;
        });
        return;
      }

      // 生成摘要
      final (summary, error) = await _aiEnhancedService.generateSummary(
        content: _note!.content,
        apiKey: apiKey,
        apiUrl: apiUrl,
        model: model,
      );

      if (error != null) {
        SnackBarUtils.showError(context, error);
        setState(() {
          _isGeneratingSummary = false;
          _showSummary = false;
        });
        return;
      }

      setState(() {
        _aiSummary = summary;
        _isGeneratingSummary = false;
      });
    } on Object catch (e) {
      debugPrint('❌ 生成摘要失败: $e');
      setState(() {
        _isGeneratingSummary = false;
        _showSummary = false;
      });
      SnackBarUtils.showError(
        context,
        AppLocalizationsSimple.of(context)?.aiGenerateSummaryFailed ??
            'Failed to generate summary, please try again later',
      );
    }
  }
}
