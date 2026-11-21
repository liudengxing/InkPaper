import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:inkpaper/l10n/app_localizations_simple.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/providers/app_provider.dart';
import 'package:inkpaper/services/ai_enhanced_service.dart';
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
import 'package:inkpaper/widgets/note_editor_page.dart';
import 'package:inkpaper/widgets/note_image_grid.dart';
import 'package:inkpaper/widgets/note_more_options_menu.dart';
import 'package:inkpaper/widgets/note_preview_text.dart';
import 'package:inkpaper/widgets/note_video_card.dart';
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
  String? _aiSummary;
  bool _isGeneratingSummary = false;
  bool _showSummary = false;

  /// 图片路径只在笔记数据变化时算一次。放在 build 里的话，
  /// 每次 setState 都要重跑一遍全文正则。
  List<String> _renderImagePaths = const <String>[];

  /// 视频路径同理，一条笔记最多一段。
  List<String> _renderVideoPaths = const <String>[];

  /// 正文字数：只数看得见的字，图片/视频/链接的 Markdown 语法不算。
  int _wordCount = 0;

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
      _renderVideoPaths = const <String>[];
      return;
    }
    _renderImagePaths = MemosContentHelper.extractNoteImagePaths(note);
    _renderVideoPaths = MemosContentHelper.extractNoteVideoPaths(note);
    _wordCount = _countVisibleChars(note.content);
  }

  /// 字数口径：只数「看得见的字」，空白不算，Markdown 语法也不算。
  ///
  /// 原来直接用 `note.content.length`：一张图写成 `![](https://.../a.jpg)`
  /// 就凭空多出 90 多个字，用户明明只写了几句却显示几百字。
  int _countVisibleChars(String content) {
    final visible = MemosContentHelper.previewVisibleText(content);
    return visible.replaceAll(RegExp(r'\s+'), '').length;
  }

  Future<void> _loadNote() async {
    final appProvider = Provider.of<AppProvider>(context, listen: false);
    final note = appProvider.getNoteById(widget.noteId) ??
        await appProvider.databaseService.getNoteById(widget.noteId);
    if (!mounted) {
      return;
    }
    if (note == null && _note != null) {
      // 原本有内容、现在查不到 = 这条被删了（详情页「⋯」删除后会回调这里）。
      // 直接退回列表，否则 _note 被置空后页面永远停在转圈。
      Navigator.of(context).maybePop();
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

  /// 长按正文：复制笔记内容（正文不再可选中，复制走这里）。
  Future<void> _copyNoteContent() async {
    final note = _note;
    if (note == null) {
      return;
    }
    final text = MemosContentHelper.previewVisibleText(note.content).trim();
    final copyText = text.isEmpty ? note.content.trim() : text;
    if (copyText.isEmpty) {
      return;
    }
    await Clipboard.setData(ClipboardData(text: copyText));
    if (!mounted) {
      return;
    }
    unawaited(HapticFeedback.selectionClick());
    SnackBarUtils.showSuccess(context, '已复制笔记内容');
  }

  /// 打开全屏编辑器。
  ///
  /// 原来这里是「双击正文 → 弹底部小卡片」。编辑已有笔记是重活：正文可能有
  /// 几十行、还要调图片顺序、加标签，220px 高的小卡片撑不住。现在统一走全屏
  /// 编辑器，保存后 pop 回本页再刷新——阅读与编辑仍是同一个入口，只是多了一个
  /// 「编辑」状态，不再需要用户先猜「双击可以编辑」。
  Future<void> _openEditor(Note note) async {
    if (_note == null) {
      return;
    }
    final appProvider = Provider.of<AppProvider>(context, listen: false);
    // 编辑的几分钟不该算进浏览时长，回来重新计时
    _viewStopwatch.stop();
    await NoteEditorPage.open(
      context,
      noteId: note.id,
      initialContent: note.content,
      onSave: (content) async {
        await appProvider.updateNote(note, content);
      },
    );
    if (!mounted) {
      return;
    }
    _viewStopwatch.start();
    await _loadNote();
  }

  // 显示更多选项菜单（统一使用 NoteMoreOptionsMenu）；
  // 顶栏三点按钮与 AI 摘要开关都从这里走。
  void _showMoreOptions(BuildContext btnContext) {
    if (_note == null) {
      return;
    }

    NoteMoreOptionsMenu.show(
      context: btnContext,
      note: _note!,
      onNoteUpdated: _loadNote,
      onAiSummary: _toggleAiSummary,
    );
  }

  /// AI 摘要开关：已展示完整摘要时收起，否则（重新）生成。
  void _toggleAiSummary() {
    if (_showSummary && _aiSummary != null) {
      setState(() => _showSummary = false);
    } else {
      _generateAISummary();
    }
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
    // 配色对齐全屏编辑器（note_editor.dart _buildEditor）：整页一张实色底，
    // 不再有「灰底 + 白色圆角卡」的容器层级
    final surfaceColor = isDarkMode ? AppTheme.darkCardColor : Colors.white;
    final textColor =
        isDarkMode ? AppTheme.darkTextPrimaryColor : AppTheme.textPrimaryColor;
    final secondaryTextColor = isDarkMode
        ? (Colors.grey[600] ?? Colors.grey)
        : (Colors.grey[800] ?? Colors.grey);
    // 底部时间条与首页卡片同一档灰，避免同一段时间在列表和详情里两种深浅。
    final timestampColor =
        isDarkMode ? AppTheme.darkTimestampColor : AppTheme.timestampColor;
    final dividerColor = isDarkMode
        ? Colors.grey[800] ?? Colors.grey.shade800
        : Colors.grey[200] ?? Colors.grey.shade200;
    final iconColor =
        isDarkMode ? AppTheme.primaryLightColor : AppTheme.primaryColor;

    return Scaffold(
      backgroundColor: surfaceColor,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 顶栏与全屏编辑器同构（返回 / 标题 / 更多），不走 AppBar：
          // 状态栏高度要像全屏编辑器那样手动让开
          SizedBox(height: MediaQuery.of(context).padding.top),
          _buildDetailHeader(
            textColor: textColor,
            secondaryTextColor: secondaryTextColor,
            dividerColor: dividerColor,
          ),

          // 中间：笔记内容（单击进编辑态，长按复制全文）
          Expanded(
            child: Padding(
              // 顶边距 8 与编辑页正文输入框的 top:8 对齐：两边切换时正文起点不跳
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                // 单击正文＝编辑。原来要双击，等于把「能改」藏起来了：
                // 点一下没反应，绝大多数人就不会再点第二下。
                // 长按仍是复制全文（与首页卡片同一套手势）
                onTap: () => _openEditor(_note!),
                onLongPress: _copyNoteContent,
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
                                      borderRadius: BorderRadius.circular(8),
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
                                    icon: const Icon(Icons.close, size: 18),
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
                                              AlwaysStoppedAnimation<Color>(
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
                              // 这里刻意不用 SelectableText /
                              // SelectionArea：两者都会把单击吞进选区逻辑，
                              // 正文就再也点不进编辑态了（实测 SelectionArea
                              // 同样吃单击）。想复制片段就点进编辑态复制
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
                                onCheckboxTap: _toggleTodoInNote,
                                onTagTap: (tagName) {
                                  try {
                                    final tagPath = normalizeIncomingTagPath(
                                      tagName,
                                    );
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
                              // 视频与图片互斥：有视频就只显示视频卡片，
                              // 点开走全屏播放器
                              if (_renderVideoPaths.isNotEmpty) ...[
                                const SizedBox(height: 24),
                                NoteVideoCard(
                                  videoPath: _renderVideoPaths.first,
                                ),
                              ]
                              // 图片统一走九宫格，长按弹保存菜单
                              else if (_renderImagePaths.isNotEmpty) ...[
                                const SizedBox(height: 24),
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

          // 底部信息区：时间 | 字数，位置对齐编辑页底部工具栏
          _buildBottomInfo(
            timestampColor: timestampColor,
            iconColor: iconColor,
            dividerColor: dividerColor,
          ),
        ],
      ),
    );
  }

  /// 顶栏：与全屏编辑器的「取消 / 编辑笔记 / 完成」同构——左「返回」、
  /// 中标题、右「更多」。高度、分隔线、按钮内边距逐项对齐
  /// note_editor.dart 的 _buildFullScreenHeader。
  Widget _buildDetailHeader({
    required Color textColor,
    required Color secondaryTextColor,
    required Color dividerColor,
  }) {
    final l10n = AppLocalizationsSimple.of(context);
    return Container(
      height: 50,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: dividerColor, width: 0.5)),
      ),
      child: Row(
        children: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            style: TextButton.styleFrom(
              foregroundColor: secondaryTextColor,
              padding: const EdgeInsets.symmetric(horizontal: 12),
            ),
            child: Text(l10n?.back ?? '返回'),
          ),
          Expanded(
            child: Text(
              l10n?.noteDetail ?? '笔记详情',
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: textColor,
              ),
            ),
          ),
          Builder(
            builder: (btnContext) => IconButton(
              onPressed: () => _showMoreOptions(btnContext),
              tooltip: AppLocalizationsSimple.of(context)?.more ?? '更多',
              icon: Icon(Icons.more_vert, size: 22, color: secondaryTextColor),
            ),
          ),
        ],
      ),
    );
  }

  /// 底部信息条：高度与分隔线对齐编辑页底部工具栏（50px + 0.5 线），
  /// 切换编辑态时底部不跳。时间（创建，按当前显示口径）在左、
  /// 「|」分隔、字数在右同一套字体字号；设了提醒就排在行尾。
  Widget _buildBottomInfo({
    required Color timestampColor,
    required Color iconColor,
    required Color dividerColor,
  }) {
    final note = _note!;
    final infoStyle = TextStyle(fontSize: 14, color: timestampColor);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 50,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: dividerColor, width: 0.5)),
          ),
          child: Row(
            children: [
              Expanded(
                // 详情页展示创建时间：最后编辑时间会随待办等操作不断变化，
                // 不便于定位这条笔记是什么时候记下的。显示口径与首页卡片一致。
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: formatNoteTimestamp(note.createdAt),
                        style: infoStyle,
                      ),
                      TextSpan(
                        text: ' | ',
                        style: infoStyle.copyWith(
                          color: dividerColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      TextSpan(
                        text: '$_wordCount 字',
                        style: infoStyle,
                      ),
                      if (_renderImagePaths.isNotEmpty)
                        TextSpan(
                          text: ' · ${_renderImagePaths.length} 张图',
                          style: infoStyle,
                        ),
                      if (_renderVideoPaths.isNotEmpty)
                        TextSpan(
                          text: ' · 1 段视频',
                          style: infoStyle,
                        ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (note.reminderTime != null) ...[
                const SizedBox(width: 12),
                Icon(Icons.alarm, size: 14, color: iconColor),
                const SizedBox(width: 4),
                Text(
                  DateFormat('MM-dd HH:mm').format(note.reminderTime!),
                  style: TextStyle(
                    fontSize: 12,
                    color: iconColor,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ],
          ),
        ),
        // 手势条高度自己让开：外层是自绘 Column，没有 Scaffold/SafeArea 帮垫
        SizedBox(height: MediaQuery.of(context).padding.bottom),
      ],
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
