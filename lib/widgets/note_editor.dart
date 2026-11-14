import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:inkpaper/l10n/app_localizations_simple.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/providers/app_provider.dart';
import 'package:inkpaper/services/ai_enhanced_service.dart';
import 'package:inkpaper/services/draft_service.dart';
import 'package:inkpaper/services/local_reference_service.dart';
import 'package:inkpaper/services/memos_resource_service.dart';
import 'package:inkpaper/services/speech_service.dart';
import 'package:inkpaper/themes/app_theme.dart';
import 'package:inkpaper/utils/attachment_cache.dart';
import 'package:inkpaper/utils/image_decode_width.dart';
import 'package:inkpaper/utils/live_photo_utils.dart';
import 'package:inkpaper/utils/note_image_anchor.dart';
import 'package:inkpaper/utils/snackbar_utils.dart';
import 'package:inkpaper/utils/tag_input_helper.dart';
import 'package:inkpaper/utils/thumb_cache.dart';
import 'package:inkpaper/widgets/capsule_text_selection_toolbar.dart';
import 'package:inkpaper/widgets/memo_editing_controller.dart';
import 'package:inkpaper/widgets/note_reference_dialog.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

class NoteEditor extends StatefulWidget {
  // 当前编辑的笔记ID，用于建立引用关系

  const NoteEditor({
    required this.onSave,
    super.key,
    this.initialContent,
    this.currentNoteId,
    this.startWithSpeech = false,
    this.preserveDraftOnClose = false,
  });
  final Function(String content) onSave;
  final String? initialContent;
  final String? currentNoteId;
  final bool startWithSpeech;

  /// 从草稿箱进来时置 true：没做修改就关闭也不会把草稿删掉，
  /// 避免用户只是看一眼就把草稿弄丢了。
  final bool preserveDraftOnClose;

  @override
  State<NoteEditor> createState() => _NoteEditorState();
}

class _NoteEditorState extends State<NoteEditor>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late MemoEditingController _textController;
  final ScrollController _scrollController = ScrollController();
  final ImagePicker _imagePicker = ImagePicker();
  final FocusNode _textFocusNode = FocusNode();
  TextSelection? _lastUsableSelection;

  // 语音识别动画控制器
  late AnimationController _speechAnimationController;

  // 单行文本的估计高度
  final double _singleLineHeight = 22; // 字体大小 * 行高

  // 最大显示的行数
  final int _maxLines = 10;

  // 文本内容行数（用 Notifier 驱动，避免输入路径 setState 整页重建）
  final ValueNotifier<int> _lineCountNotifier = ValueNotifier<int>(1);

  // 添加一个标志来防止多次保存
  bool _isSaving = false;

  // 关闭流程防重入：点空白和点关闭按钮可能同时触发，避免连 pop 两次
  bool _isClosingEditor = false;

  // 是否显示更多选项
  bool _showingMoreOptions = false;

  // 🚀 标志：是否已成功保存笔记（用于判断是否需要保存草稿）
  bool _hasSuccessfullySaved = false;

  // ✨ AI 功能相关
  final AIEnhancedService _aiService = AIEnhancedService();
  bool _isAIProcessing = false;
  bool _showingAIOptions = false;

  // 🚀 标志：是否是新建笔记（用于判断是否需要保存/加载草稿）
  late bool _isNewNote;
  String _initialSavedContent = '';

  // ── 草稿暂存 ─────────────────────────────────────────────────────────
  // 误触空白、系统返回、切后台都可能让编辑器消失，内容靠草稿兜住。
  final DraftService _draftService = DraftService();
  Timer? _draftDebounce;

  /// 编辑已有笔记时自动恢复了草稿，这里存恢复前的笔记原文，供「撤销」回退。
  /// 非空也代表草稿槽位里压着一条不该被随手清掉的草稿。
  String? _draftRevertContent;

  /// 「已恢复上次未保存的草稿」提示条是否还挂着。
  bool _showDraftRecovered = false;

  String get _draftId => widget.currentNoteId ?? DraftService.newNoteDraftId;

  // 添加图片列表和Markdown代码
  List<_ImageItem> _imageList = [];
  List<String> _mdCodes = [];
  List<int?> _imageAnchors = [];

  /// 九宫格自己的滚动控制器：拖动时要把指针的全局坐标换算回网格内容坐标，
  /// 换算里得把已滚动的距离加回去。
  final ScrollController _imageGridScrollController = ScrollController();

  /// 用 [GlobalKey] 取九宫格 viewport 的 RenderBox 做坐标换算。
  final GlobalKey _imageGridKey = GlobalKey();

  /// 九宫格拖动排序的实时状态：正在拖的那张的原始下标、指针当前压住的格子。
  ///
  /// 没用 `DragTarget` 判定：格子让位后位置会变，「指针不动但命中的格子变了」
  /// 会让 DragTarget 反复进出、让位动画来回抽搐。改成直接从指针坐标反算格子。
  int? _dragSourceIndex;
  int? _dragHoverIndex;

  String _lastTextForImageAnchors = '';
  bool _suppressImageAnchorSync = false;

  // 语音识别相关
  final SpeechService _speechService = SpeechService();
  bool _isSpeechListening = false;
  String _partialSpeechText = '';
  // 🚀 标签自动补全相关
  OverlayEntry? _tagSuggestionOverlay;
  int _tagStartPosition = 0;
  final LayerLink _textFieldLayerLink = LayerLink(); // 用于跟踪光标位置

  String _loadVisualContent(String markdown) {
    final imageRegex = RegExp(r'!\[(.*?)\]\((.*?)\)');
    final imageItems = <_ImageItem>[];
    final markdownCodes = <String>[];
    final markdownAnchors = <int>[];
    final imageAnchors = <int?>[];
    final body = StringBuffer();
    var cursor = 0;

    for (final match in imageRegex.allMatches(markdown)) {
      final alt =
          match.group(1) ?? (AppLocalizationsSimple.of(context)?.image ?? '图片');
      final imagePath = match.group(2) ?? '';
      final fullMatch = match.group(0) ?? '';

      if (imagePath.isEmpty || fullMatch.isEmpty) {
        continue;
      }

      body.write(markdown.substring(cursor, match.start));
      imageItems.add(_ImageItem(path: imagePath, alt: alt));
      markdownCodes.add(fullMatch);
      markdownAnchors.add(body.length);
      cursor = match.end;
    }
    body.write(markdown.substring(cursor));
    final bodyText = body.toString();

    for (final anchor in markdownAnchors) {
      imageAnchors.add(
        MemoMarkdownEditingCodec.decode(bodyText.substring(0, anchor))
            .text
            .length,
      );
    }

    _imageList = imageItems;
    _mdCodes = markdownCodes;
    _imageAnchors = imageAnchors;
    return bodyText;
  }

  // 更新内容行数（只更新 Notifier，不触发整页 setState）
  void _updateLineCount() {
    final nextCount = '\n'.allMatches(_textController.text).length + 1;
    if (_lineCountNotifier.value != nextCount) {
      _lineCountNotifier.value = nextCount;
    }
  }

  void _syncImageAnchorsForTextChange() {
    if (_suppressImageAnchorSync) {
      return;
    }

    final nextText = _textController.text;
    if (nextText == _lastTextForImageAnchors) {
      return;
    }

    _imageAnchors = shiftImageOffsets(
      offsets: _imageAnchors,
      previousText: _lastTextForImageAnchors,
      currentText: nextText,
    );
    _lastTextForImageAnchors = nextText;
  }

  // 🚀 检测标签输入
  //
  // 「光标是否在 #标签里」和候选排序都是纯字符串逻辑，见
  // utils/tag_input_helper.dart；这里只负责取数据与挂 Overlay。
  void _detectTagInput() {
    final tagContext = detectTagPrefix(
      text: _textController.text,
      cursorPosition: _textController.selection.baseOffset,
    );
    if (tagContext == null) {
      _hideTagSuggestions();
      return;
    }

    final appProvider = Provider.of<AppProvider>(context, listen: false);
    // 候选按「最近 + 最常用」排，而不是字典序：
    // 用户攒起来的常用标签要浮到前面，否则每次都得在字母表里翻。
    final allTags = rankTagsByUsage(
      notes: appProvider.notes.map(
        (note) => (tags: note.tags, updatedAt: note.updatedAt),
      ),
    );

    final suggestions = rankTagSuggestions(
      allTags: allTags,
      prefix: tagContext.prefix,
    );

    if (suggestions.isNotEmpty) {
      _tagStartPosition = tagContext.start;
      _showTagSuggestions(suggestions);
    } else {
      _hideTagSuggestions();
    }
  }

  // 🚀 显示标签建议（参考VSCode自动补全、IDE风格）
  void _showTagSuggestions(List<String> suggestions) {
    // 如果没有建议，隐藏并返回
    if (suggestions.isEmpty) {
      _hideTagSuggestions();
      return;
    }

    // 移除旧的overlay
    _tagSuggestionOverlay?.remove();

    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    // 🎯 显示最多8个建议，横向滚动
    final displaySuggestions = suggestions.take(8).toList();

    // 🎨 参考小红书/抖音 - 紧凑的标签卡片，在工具栏上方
    _tagSuggestionOverlay = OverlayEntry(
      builder: (context) => Positioned(
        left: 0,
        right: 0,
        bottom: MediaQuery.of(context).viewInsets.bottom + 50, // 在工具栏正上方
        child: Material(
          color: Colors.transparent,
          child: Container(
            height: 36, // 更小巧
            margin: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: isDarkMode
                  ? const Color(0xFF2C2C2E).withValues(alpha: 0.95)
                  : Colors.white.withValues(alpha: 0.95),
              borderRadius: BorderRadius.circular(8),
              boxShadow: [
                BoxShadow(
                  color:
                      Colors.black.withValues(alpha: isDarkMode ? 0.3 : 0.06),
                  blurRadius: 8,
                  offset: const Offset(0, -1),
                ),
              ],
            ),
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              scrollDirection: Axis.horizontal, // 横向滚动
              itemCount: displaySuggestions.length,
              separatorBuilder: (context, index) => const SizedBox(width: 6),
              itemBuilder: (context, index) {
                final tag = displaySuggestions[index];
                return InkWell(
                  onTap: () => _insertTag(tag),
                  borderRadius: BorderRadius.circular(6),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppTheme.primaryColor.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: AppTheme.primaryColor.withValues(alpha: 0.15),
                        width: 0.5,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // 话题图标
                        const Text(
                          '#',
                          style: TextStyle(
                            fontSize: 13,
                            color: AppTheme.primaryColor,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 4),
                        // 标签文字
                        Text(
                          tag,
                          style: TextStyle(
                            fontSize: 13,
                            color: isDarkMode
                                ? Colors.white.withValues(alpha: 0.9)
                                : Colors.black87,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );

    Overlay.of(context).insert(_tagSuggestionOverlay!);
  }

  // 🚀 隐藏标签建议
  void _hideTagSuggestions() {
    _tagSuggestionOverlay?.remove();
    _tagSuggestionOverlay = null;
  }

  // 🚀 插入选中的标签
  void _insertTag(String tag) {
    final result = applyTagInsertion(
      text: _textController.text,
      cursorPosition: _textController.selection.baseOffset,
      tagStart: _tagStartPosition,
      tag: tag,
    );

    _textController.value = TextEditingValue(
      text: result.text,
      selection: TextSelection.collapsed(offset: result.cursor),
    );

    _hideTagSuggestions();
  }

  // 🚀 草稿暂存：输入停顿 800ms 后自动落盘。
  // 编辑器被点空白/返回键/切后台/被系统回收时，内容都还能找回来。
  void _scheduleDraftSave() {
    _draftDebounce?.cancel();
    _draftDebounce = Timer(const Duration(milliseconds: 800), () {
      unawaited(_saveDraft());
    });
  }

  Future<void> _saveDraft() async {
    if (_hasSuccessfullySaved) {
      return;
    }
    // 内容与打开编辑器时完全一致，就没有暂存的必要（避免制造空草稿）
    if (!_hasUnsavedChanges) {
      return;
    }
    final content = _prepareFinalContent();
    if (content.trim().isEmpty) {
      return;
    }
    await _draftService.save(
      draftId: _draftId,
      noteId: widget.currentNoteId,
      content: content,
    );
    if (kDebugMode) {
      debugPrint(
        '📝 草稿已保存($_draftId): '
        '${content.substring(0, math.min(50, content.length))}...',
      );
    }
  }

  Future<NoteDraft?> _loadDraft() => _draftService.load(_draftId);

  // 🚀 清除草稿（成功保存笔记后调用）
  Future<void> _clearDraft() async {
    _draftDebounce?.cancel();
    await _draftService.clear(_draftId);
    if (kDebugMode) {
      debugPrint('🗑️ 草稿已清除');
    }
  }

  /// 把草稿内容写回编辑器（连同图片一起重建）。
  ///
  /// [originalContent] 是恢复前的笔记原文，撤销时要用；新建笔记没有原文，留空。
  void _restoreDraftContent(String content, {String? originalContent}) {
    setState(() {
      final draftBody = _loadVisualContent(content);
      _suppressImageAnchorSync = true;
      try {
        _textController.setMarkdown(draftBody);
      } finally {
        _suppressImageAnchorSync = false;
      }
      _lastTextForImageAnchors = _textController.text;
      _initialSavedContent = originalContent ?? '';
      _updateLineCount();
    });
    _focusEditorAfterOpen();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // 切后台 / 被系统回收前立刻落盘，不等 debounce
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _draftDebounce?.cancel();
      unawaited(_saveDraft());
    }
  }

  @override
  void initState() {
    super.initState();
    final initialMarkdown = widget.initialContent ?? '';
    final initialBody = _loadVisualContent(initialMarkdown);
    _textController = MemoEditingController(markdown: initialBody);
    _lastTextForImageAnchors = _textController.text;
    _initialSavedContent = _prepareFinalContent();

    // 🚀 判断是否是新建笔记（initialContent为空）
    _isNewNote =
        widget.initialContent == null || widget.initialContent!.isEmpty;

    // 草稿恢复：
    //   · 新建笔记 → 直接恢复（用户本来就是从空白开始写）
    //   · 编辑已有笔记 → 也直接恢复，但顶部给一条「已恢复」提示 + 撤销
    //
    // 以前编辑已有笔记只弹提示、等用户点「恢复」。可是提示很容易被忽略，
    // 用户直接在原文上接着写，输入停顿 800ms 的自动暂存就会把带图片的草稿
    // 整条盖掉 —— 表现就是「明明说保存了草稿，图却没留下」。
    _loadDraft().then((draft) {
      if (!mounted || draft == null || draft.content.trim().isEmpty) {
        return;
      }
      if (_isNewNote) {
        _restoreDraftContent(draft.content);
        return;
      }
      final original = _initialSavedContent;
      if (draft.content.trim() == original.trim()) {
        return;
      }
      _restoreDraftContent(draft.content, originalContent: original);
      setState(() {
        _draftRevertContent = original;
        _showDraftRecovered = true;
      });
    });

    WidgetsBinding.instance.addObserver(this);

    // 初始化语音识别动画控制器
    _speechAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    ); // 不自动重复，根据音量控制

    // 初始化内容行数
    _updateLineCount();

    _focusEditorAfterOpen();
    if (widget.startWithSpeech && _speechEnabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Future<void>.delayed(const Duration(milliseconds: 320), () {
          if (mounted && !_isSpeechListening) {
            _toggleSpeechRecognition();
          }
        });
      });
    }

    // 监听输入变化，更新保存按钮状态和行数
    _textController.addListener(() {
      _preserveCurrentSelection();
      _syncImageAnchorsForTextChange();
      _updateLineCount();

      // 🚀 输入停顿后自动暂存草稿
      _scheduleDraftSave();

      // 🚀 检测标签输入并显示建议
      _detectTagInput();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // 编辑器被关掉时兜底再存一次草稿（成功保存过、或本来就没改动的不存）
    _draftDebounce?.cancel();
    if (!_hasSuccessfullySaved && _hasUnsavedChanges) {
      unawaited(_saveDraft());
    }

    // 🚀 清理标签建议overlay
    _tagSuggestionOverlay?.remove();
    _tagSuggestionOverlay = null;

    // 🔥 确保停止语音识别，释放麦克风资源
    _speechWatchdog?.cancel();
    if (_isSpeechListening) {
      _speechService.stopListening();
      _speechAnimationController.stop();
      _speechAnimationController.reset();
    }

    _textController.dispose();
    _lineCountNotifier.dispose();
    _textFocusNode.dispose();
    _scrollController.dispose();
    _imageGridScrollController.dispose();
    _speechAnimationController.dispose();
    super.dispose();
  }

  // 从设备选择图片并插入（支持多选）
  Future<void> _pickImage() async {
    try {
      final pickedFiles = await _imagePicker.pickMultiImage();
      if (!mounted) {
        return;
      }

      if (pickedFiles.isNotEmpty) {
        final appProvider = Provider.of<AppProvider>(context, listen: false);
        final newImages = <_ImageItem>[];
        final newMdCodes = <String>[];

        // 1. 立即保存到本地并显示，提供即时响应
        for (final pickedFile in pickedFiles) {
          await _saveImageLocally(pickedFile, newImages, newMdCodes);
          if (!mounted) {
            return;
          }
        }

        // 2. 立即更新UI，让用户看到图片
        setState(() {
          _imageList.addAll(newImages);
          _mdCodes.addAll(newMdCodes);
          _imageAnchors.addAll(List<int?>.filled(newImages.length, null));
        });

        // 移除成功通知，减少干扰用户体验

        // 3. 如果已登录且不是本地模式，启动后台上传
        if (appProvider.isLoggedIn &&
            !appProvider.isLocalMode &&
            appProvider.resourceService != null) {
          unawaited(_uploadImagesInBackground(pickedFiles, newImages));
        }
      }
    } on Object catch (e) {
      if (kDebugMode) {
        debugPrint('选择图片失败: $e');
      }
      SnackBarUtils.showError(
        context,
        AppLocalizationsSimple.of(context)?.selectImageFailed ?? '选择图片失败',
      );
    }
  }

  // 后台上传图片到服务器
  Future<void> _uploadImagesInBackground(
    List<XFile> pickedFiles,
    List<_ImageItem> localImages,
  ) async {
    final appProvider = Provider.of<AppProvider>(context, listen: false);

    try {
      // if (kDebugMode) debugPrint('NoteEditor: 开始后台上传 ${pickedFiles.length} 张图片');

      // 标记图片为上传中状态
      if (!mounted) {
        return;
      }
      setState(() {
        for (var i = 0; i < localImages.length; i++) {
          final index = _imageList.indexOf(localImages[i]);
          if (index != -1) {
            _imageList[index] =
                localImages[i].copyWith(uploadStatus: UploadStatus.uploading);
          }
        }
      });

      final imageFiles = <File>[];
      for (final xfile in pickedFiles) {
        imageFiles.add(File(xfile.path));
      }

      final uploadResults =
          await appProvider.resourceService!.uploadImages(imageFiles);
      if (!mounted) {
        return;
      }
      debugPrint('NoteEditor: 获得上传结果，共 ${uploadResults.length} 个结果');
      var successCount = 0;

      for (var i = 0; i < uploadResults.length; i++) {
        final result = uploadResults[i];
        final localImage = localImages[i];

        debugPrint('NoteEditor: 处理第$i张图片结果: $result');
        debugPrint('NoteEditor: 寻找本地图片: ${localImage.path}');

        // 通过路径找到对应的图片索引，而不是通过对象引用
        var localImageIndex = -1;
        for (var j = 0; j < _imageList.length; j++) {
          if (_imageList[j].path == localImage.path) {
            localImageIndex = j;
            break;
          }
        }

        debugPrint('NoteEditor: 本地图片索引: $localImageIndex');

        if (localImageIndex == -1) {
          debugPrint('NoteEditor: 在_imageList中未找到对应图片，尝试按文件名匹配');
          // 如果按完整路径找不到，尝试按文件名匹配
          final localFileName = path.basename(localImage.path);
          for (var j = 0; j < _imageList.length; j++) {
            final fileName = path.basename(_imageList[j].path);
            if (fileName == localFileName) {
              localImageIndex = j;
              debugPrint('NoteEditor: 通过文件名找到匹配图片，索引: $localImageIndex');
              break;
            }
          }
        }

        if (localImageIndex == -1) {
          debugPrint('NoteEditor: 完全找不到对应的本地图片，跳过');
          continue; // 图片已被删除
        }

        if (result['success'] == true) {
          final serverPath = result['serverPath']?.toString();
          if (serverPath == null || serverPath.isEmpty) {
            debugPrint('NoteEditor: 上传成功但缺少服务器路径，跳过');
            continue;
          }
          final localPath = localImage.path;

          debugPrint('NoteEditor: 准备更新图片路径: $localPath -> $serverPath');

          // 更新图片项为服务器路径
          if (!mounted) {
            return;
          }
          setState(() {
            _imageList[localImageIndex] = localImage.copyWith(
              path: serverPath,
              uploadStatus: UploadStatus.success,
            );
          });

          // 替换Markdown中的本地路径为服务器路径
          final localMdPattern = '![图片]($localPath)';
          final serverMdPattern = '![图片]($serverPath)';
          final mdIndex = _mdCodes.indexOf(localMdPattern);
          debugPrint(
            'NoteEditor: Markdown替换: $localMdPattern -> $serverMdPattern, 索引: $mdIndex',
          );
          if (mdIndex != -1) {
            if (!mounted) {
              return;
            }
            setState(() {
              _mdCodes[mdIndex] = serverMdPattern;
            });
          }

          // 清除缓存以确保显示最新图片
          _clearImageCache(serverPath);

          // 注意：不更新文本编辑器内容，保持图片Markdown隐藏

          successCount++;
          debugPrint('NoteEditor: 图片 $i 上传成功，路径: $serverPath');
        } else {
          // 上传失败，保持本地路径，标记失败状态
          if (!mounted) {
            return;
          }
          setState(() {
            _imageList[localImageIndex] =
                localImage.copyWith(uploadStatus: UploadStatus.failed);
          });
          debugPrint('NoteEditor: 图片 $i 上传失败: ${result['error']}');
        }
      }

      // 删除上传成功提示，提升用户体验
      // if (successCount > 0) {
      //   SnackBarUtils.showSuccess(context, '成功上传 $successCount 张图片到服务器');
      // }

      if (successCount < pickedFiles.length) {
        if (!mounted) {
          return;
        }
        SnackBarUtils.showError(
          context,
          '${pickedFiles.length - successCount} 张图片上传失败',
        );
      }
    } on Object catch (e, stackTrace) {
      debugPrint('NoteEditor: 后台上传异常: $e');
      debugPrint('NoteEditor: 异常堆栈: $stackTrace');
      // 标记所有图片为上传失败
      if (!mounted) {
        return;
      }
      setState(() {
        for (var i = 0; i < localImages.length; i++) {
          final index = _imageList.indexOf(localImages[i]);
          if (index != -1) {
            _imageList[index] =
                localImages[i].copyWith(uploadStatus: UploadStatus.failed);
          }
        }
      });
    }
  }

  // 清除图片缓存
  void _clearImageCache(String imagePath) {
    try {
      final appProvider = Provider.of<AppProvider>(context, listen: false);
      if (appProvider.resourceService != null &&
          MemosResourceService.isServerResourcePath(imagePath)) {
        final fullUrl = appProvider.resourceService!.buildImageUrl(imagePath);
        // 清除CachedNetworkImage的缓存
        CachedNetworkImage.evictFromCache(fullUrl);
        debugPrint('NoteEditor: 已清除图片缓存 - $fullUrl');
      }
    } on Object catch (e) {
      debugPrint('NoteEditor: 清除缓存失败: $e');
    }
  }

  // 构建上传状态指示器
  Widget _buildUploadStatusIcon(UploadStatus status) {
    switch (status) {
      case UploadStatus.uploading:
        return Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            color: Colors.blue.withValues(alpha: 0.8),
            shape: BoxShape.circle,
          ),
          child: const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
            ),
          ),
        );
      case UploadStatus.success:
        return Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            color: Colors.green.withValues(alpha: 0.8),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.cloud_done,
            color: Colors.white,
            size: 12,
          ),
        );
      case UploadStatus.failed:
        return Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            color: Colors.red.withValues(alpha: 0.8),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.cloud_off,
            color: Colors.white,
            size: 12,
          ),
        );
      case UploadStatus.none:
        return const SizedBox.shrink(); // 不显示任何图标
    }
  }

  // 保存图片到本地的辅助方法
  Future<void> _saveImageLocally(
    XFile pickedFile,
    List<_ImageItem> newImages,
    List<String> newMdCodes,
  ) async {
    // 获取应用文档目录
    final appDir = await getApplicationDocumentsDirectory();
    final imagesDir = Directory('${appDir.path}/images');

    // 确保图片目录存在
    if (!await imagesDir.exists()) {
      await imagesDir.create(recursive: true);
    }

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final ext = path.extension(pickedFile.path).isNotEmpty
        ? path.extension(pickedFile.path)
        : '.jpg';
    final fileName = 'image_$timestamp$ext';
    final localImagePath = '${imagesDir.path}/$fileName';

    // 用 readAsBytes() 兼容 Android content URI（部分 OEM 如 vivo/iQOO 返回的不是文件路径）
    var bytes = await pickedFile.readAsBytes();

    // Live 图（Motion Photo）：照片尾部嵌了一段 MP4。把视频抽出来单独存一份，
    // 图片本身只保留静态部分 —— 既能让查看器播放动效，又能让图片体积和解码量
    // 回到普通照片的水平（原图带着几十 MB 的视频会让进详情明显变慢）。
    final motionPhoto = LivePhotoUtils.extractMotionPhoto(bytes);
    if (motionPhoto != null) {
      try {
        await File(
          LivePhotoUtils.videoPathFor(localImagePath),
        ).writeAsBytes(motionPhoto.videoBytes, flush: true);
        bytes = bytes.sublist(0, motionPhoto.imageLength);
      } on Object catch (e) {
        debugPrint('保存 Live 图视频片段失败: $e');
      }
    }

    await File(localImagePath).writeAsBytes(bytes);
    // 插入这一刻顺手生成缩略图：之后每次进列表、详情、编辑器都省掉原图解码，
    // 不用等后台补齐，也不会出现「刚插的图在首页还是慢」的落差。
    unawaited(ThumbCache.instance.ensure(localImagePath));
    if (!mounted) {
      return;
    }

    // 添加到列表
    final mdCode = '![图片](file://$localImagePath)';
    newImages.add(
      _ImageItem(
        path: 'file://$localImagePath',
        alt: AppLocalizationsSimple.of(context)?.image ?? '图片',
      ),
    );
    newMdCodes.add(mdCode);
  }

  // 用于保存笔记前的最终内容准备
  String _prepareFinalContent() {
    final bodyText = _textController.text;
    if (_imageList.isEmpty) {
      final bodyMarkdown = _textController.toMarkdown();
      return bodyMarkdown.trim().isEmpty ? '' : bodyMarkdown;
    }

    final anchoredImages = <NoteImageAnchor>[];
    final trailingImages = <String>[];
    for (var i = 0; i < _imageList.length; i++) {
      final img = _imageList[i];
      final mdCode =
          i < _mdCodes.length ? _mdCodes[i] : '![${img.alt}](${img.path})';
      final anchor = i < _imageAnchors.length ? _imageAnchors[i] : null;
      if (anchor == null) {
        trailingImages.add(mdCode);
      } else {
        anchoredImages.add(
          NoteImageAnchor(
            offset: anchor.clamp(0, bodyText.length),
            markdown: mdCode,
            order: i,
          ),
        );
      }
    }

    anchoredImages.sort((a, b) {
      final offsetCompare = a.offset.compareTo(b.offset);
      return offsetCompare != 0 ? offsetCompare : a.order.compareTo(b.order);
    });

    final buffer = StringBuffer();
    var cursor = 0;
    for (final image in anchoredImages) {
      buffer
        ..write(bodyText.substring(cursor, image.offset))
        ..write(image.markdown);
      cursor = image.offset;
    }
    buffer.write(bodyText.substring(cursor));

    if (trailingImages.isNotEmpty) {
      if (buffer.isNotEmpty &&
          buffer.toString().trim().isNotEmpty &&
          !buffer.toString().endsWith('\n')) {
        buffer.write('\n');
      }
      for (final imageMarkdown in trailingImages) {
        buffer.writeln(imageMarkdown);
      }
    }

    final finalContent = MemoMarkdownEditingCodec.encode(
      buffer.toString(),
      _rangesWithImages(images: anchoredImages),
    );
    return finalContent.trim().isEmpty ? '' : finalContent;
  }

  Future<void> _saveNote() async {
    if (_isSaving) {
      return;
    }

    setState(() {
      _isSaving = true;
    });

    try {
      debugPrint('NoteEditor: 开始保存笔记...');

      final finalContent = _prepareFinalContent();

      if (finalContent.isEmpty && _imageList.isEmpty) {
        return;
      }

      await widget.onSave(finalContent);
      await _clearDraft();
      _hasSuccessfullySaved = true;

      if (!mounted) {
        return;
      }
      try {
        Navigator.pop(context);
        debugPrint('NoteEditor: 编辑器已关闭');
      } on Object catch (e) {
        debugPrint('NoteEditor: 关闭编辑器失败: $e');
      }
    } on Object catch (e) {
      debugPrint('NoteEditor: 保存笔记时出错: $e');
      if (mounted) {
        SnackBarUtils.showError(
          context,
          '${AppLocalizationsSimple.of(context)?.saveFailed ?? '保存失败'}: $e',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  /// 样式区间 → 最终 markdown 里的位置。
  ///
  /// 区间若横跨图片会在图片处断开（图片本身不吃样式），切段算法在
  /// `utils/note_image_anchor.dart` 的 `splitRangeByImages`。
  List<MemoStyleRange> _rangesWithImages({
    required List<NoteImageAnchor> images,
  }) {
    final sourceRanges = _textController.ranges;
    if (sourceRanges.isEmpty || images.isEmpty) {
      return sourceRanges;
    }

    final ranges = <MemoStyleRange>[];
    for (final range in sourceRanges) {
      for (final segment in splitRangeByImages(
        rangeStart: range.start,
        rangeEnd: range.end,
        images: images,
      )) {
        ranges.add(range.copyWith(start: segment.start, end: segment.end));
      }
    }
    return ranges;
  }

  bool get _hasUnsavedChanges {
    final current = _prepareFinalContent();
    if (current.isEmpty && _initialSavedContent.isEmpty) {
      return false;
    }
    return current != _initialSavedContent;
  }

  /// 统一的「关闭编辑器」入口：点关闭按钮、点上方空白区域、系统返回键都走这里。
  ///
  /// 只要还有未保存的改动，就先落草稿再关闭 —— 误触退出最多多一条草稿，
  /// 不会出现「写了一半的内容直接没了」。
  Future<void> _requestCloseEditor() async {
    if (_isClosingEditor) {
      return;
    }
    _isClosingEditor = true;

    try {
      if (!_hasUnsavedChanges) {
        // 没有改动就不留草稿；但刚恢复出来的草稿（撤销前）、
        // 以及从草稿箱打开待继续编辑的草稿要保留
        if (_draftRevertContent == null && !widget.preserveDraftOnClose) {
          await _clearDraft();
        }
        if (mounted) {
          Navigator.pop(context);
        }
        return;
      }

      final messenger = ScaffoldMessenger.maybeOf(context);
      await _saveDraft();
      if (!mounted) {
        return;
      }
      Navigator.pop(context);
      messenger
        ?..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('已保存草稿，下次打开这条笔记可恢复'),
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: 3),
          ),
        );
    } on Object catch (error) {
      // 关闭失败时允许再次尝试，避免编辑器彻底关不掉
      _isClosingEditor = false;
      debugPrint('NoteEditor: 关闭编辑器失败 - $error');
    }
  }

  /// 提示条里点「撤销」：丢掉这份草稿，正文退回笔记原文。
  Future<void> _revertDraftRecovery() async {
    final original = _draftRevertContent;
    if (original == null) {
      return;
    }
    setState(() {
      final body = _loadVisualContent(original);
      _suppressImageAnchorSync = true;
      try {
        _textController.setMarkdown(body);
      } finally {
        _suppressImageAnchorSync = false;
      }
      _lastTextForImageAnchors = _textController.text;
      _initialSavedContent = original;
      _draftRevertContent = null;
      _showDraftRecovered = false;
      _updateLineCount();
    });
    await _draftService.clear(_draftId);
  }

  /// 提示条里点「知道了」：只收掉提示，草稿已经恢复进编辑器，不动内容。
  void _dismissDraftRecovered() {
    setState(() => _showDraftRecovered = false);
  }

  /// 「发现未保存草稿」提示条。
  Widget _buildDraftBanner({
    required Color accentColor,
    required Color textColor,
    required Color secondaryTextColor,
  }) =>
      Container(
        margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
        padding: const EdgeInsets.only(left: 12, right: 4),
        decoration: BoxDecoration(
          color: accentColor.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: accentColor.withValues(alpha: 0.25)),
        ),
        child: Row(
          children: [
            Icon(Icons.history, size: 16, color: accentColor),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '已恢复上次未保存的草稿',
                style: TextStyle(fontSize: 12, color: textColor),
              ),
            ),
            TextButton(
              onPressed: _dismissDraftRecovered,
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 34),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                '知道了',
                style: TextStyle(fontSize: 12, color: secondaryTextColor),
              ),
            ),
            TextButton(
              onPressed: _revertDraftRecovery,
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 34),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                '撤销',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: accentColor,
                ),
              ),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    // 行数变化只重建编辑器子树，不再经 setState 触发整页重建
    // 系统返回键 / 手势返回也走统一的关闭逻辑（先落草稿再关），
    // 否则 showModalBottomSheet 会直接 pop，内容来不及保存。
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          return;
        }
        unawaited(_requestCloseEditor());
      },
      child: ValueListenableBuilder<int>(
        valueListenable: _lineCountNotifier,
        builder: (context, lineCount, _) => _buildEditor(context, lineCount),
      ),
    );
  }

  Widget _buildEditor(BuildContext context, int lineCount) {
    // 获取屏幕尺寸
    final mediaQuery = MediaQuery.of(context);
    final screenSize = mediaQuery.size;

    // 基础编辑框高度 - 屏幕高度的35%或300像素，取较大值
    final baseEditorHeight = math.max(screenSize.height * 0.35, 300);

    // 计算编辑区域的自适应高度（根据行数）
    final contentHeight = math.min(
      lineCount * _singleLineHeight, // 根据行数计算高度
      _maxLines * _singleLineHeight, // 最大高度（10行）
    );

    // 底部工具栏高度
    const toolbarHeight = 50.0;
    final keyboardInset = mediaQuery.viewInsets.bottom;

    // 顶部指示器和内边距高度
    const topElementsHeight = 20.0;

    // 图片预览区域的目标高度：九宫格按行数自适应，屏幕放不下时内部滚动。
    // 卡片是全宽的（外层 Container 撑满），所以直接用屏宽换算格子边长。
    final imageTargetHeight = _imageGridContentHeight(screenSize.width);

    // 图片区是文字区的兄弟节点，卡片总高不变时它只能从 Expanded 的文字区里抢
    // 空间（选 1 张图就少 110），表现为「输入框变窄、多行文字被挡住」。所以有图
    // 时让卡片整体长高 imageTargetHeight，文字区维持原来的高度。
    final desiredEditorHeight = math.max(
      // 无图时等于 baseEditorHeight，视觉与改前逐像素一致
      baseEditorHeight + imageTargetHeight,
      contentHeight +
          toolbarHeight +
          topElementsHeight +
          imageTargetHeight +
          32,
    );

    // 上限要按「键盘上方的可用高度」算：卡片底部垫了 keyboardInset，用整屏
    // 高度做上限的话键盘弹出时卡片会顶到屏幕外，底部工具栏被裁掉。
    final availableHeight = screenSize.height - keyboardInset;
    final editorHeight = math.min(desiredEditorHeight, availableHeight * 0.92);

    // 卡片高度被上面一句钳住时（图片多 + 键盘弹出几乎必然发生），图片区不能
    // 还按满格九宫格的高度长：卡片已经不再变高，多出来的空间只能从文字区抢，
    // 文字会被挤扁。这里让图片区主动让步——只显示能放下的**完整行**，其余靠
    // 内部滚动；给到 1.3 行会让第二行被裁掉一截，看起来像图片没加载完。
    final imageSectionHeight = _imageList.isEmpty
        ? 0.0
        : _imageGridFitHeight(
            editorHeight - baseEditorHeight,
            screenSize.width,
          );

    // 获取当前主题模式
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final backgroundColor = isDarkMode ? AppTheme.darkCardColor : Colors.white;
    final textColor =
        isDarkMode ? AppTheme.darkTextPrimaryColor : AppTheme.textPrimaryColor;
    final secondaryTextColor = isDarkMode
        ? (Colors.grey[600] ?? Colors.grey)
        : (Colors.grey[800] ?? Colors.grey);
    final iconColor =
        isDarkMode ? AppTheme.primaryLightColor : AppTheme.primaryColor;
    final dividerColor = isDarkMode
        ? Colors.grey[800] ?? Colors.grey.shade800
        : Colors.grey[200] ?? Colors.grey.shade200;
    final hintTextColor = isDarkMode ? Colors.grey[600] : Colors.grey[400];

    // 确保即使只有图片也能保存
    // 注意：发送按钮的可用状态不能在这里算。本方法只在行数变化（或 setState）
    // 时重建，而首行输入不改变行数，按钮会一直是灰的、点不动（要按一次回车
    // 才「刷」过来）。所以把这部分交给按钮自己的 ValueListenableBuilder 监听
    // 输入内容，见下方「发送按钮」。

    return Scaffold(
      backgroundColor: Colors.transparent,
      resizeToAvoidBottomInset: false,
      // 点上方空白区域：先收起键盘，再走统一关闭流程（有改动会先落草稿）
      body: GestureDetector(
        onTap: () {
          _textFocusNode.unfocus();
          unawaited(_requestCloseEditor());
        },
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: double.infinity,
          height: double.infinity,
          color: Colors.transparent,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.end, // 确保内容位于底部
            children: [
              // 编辑器主体 - 使用GestureDetector拦截点击事件
              GestureDetector(
                onTap: () {}, // 空的onTap阻止点击事件冒泡
                child: AnimatedPadding(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  padding: EdgeInsets.only(bottom: keyboardInset),
                  // 高度不做动画：卡片和图片区各有各的动画曲线就无法逐帧对齐，
                  // 中间帧会先把多出来的空间灌进文字区再收回去（抽搐）。切换九宫格
                  // 时高度瞬变、图片区内容交叉淡化，文字区位置全程不动。
                  child: Container(
                    height: editorHeight,
                    decoration: BoxDecoration(
                      // 颜色交给内层 ColoredBox（半透明），这里只留圆角与投影
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(20),
                        topRight: Radius.circular(20),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.12),
                          blurRadius: 16,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    // flomo 式玻璃卡片：半透明底 + 自身 BackdropFilter，
                    // 卡片边缘后面也是模糊背景，而不是一整块实心白
                    child: ClipRRect(
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(20),
                        topRight: Radius.circular(20),
                      ),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                        child: ColoredBox(
                          color: isDarkMode
                              ? const Color(0xE01C1C1E)
                              : Colors.white.withValues(alpha: 0.9),
                          child: Column(
                            children: [
                              // 顶部：左关闭 / 中拖动指示条 / 右侧占位保持视觉居中
                              Padding(
                                padding: const EdgeInsets.fromLTRB(6, 4, 6, 0),
                                child: Row(
                                  children: [
                                    IconButton(
                                      onPressed: _requestCloseEditor,
                                      tooltip:
                                          AppLocalizationsSimple.of(context)
                                                  ?.cancel ??
                                              '关闭',
                                      icon: Icon(
                                        Icons.close,
                                        size: 20,
                                        color: secondaryTextColor,
                                      ),
                                    ),
                                    const Spacer(),
                                    Container(
                                      width: 40,
                                      height: 4,
                                      decoration: BoxDecoration(
                                        color: isDarkMode
                                            ? Colors.grey[700]
                                            : Colors.grey[300],
                                        borderRadius: BorderRadius.circular(2),
                                      ),
                                    ),
                                    const Spacer(),
                                    const SizedBox(width: 40),
                                  ],
                                ),
                              ),

                              // 自动恢复草稿后给一条可撤销的提示
                              if (_showDraftRecovered)
                                _buildDraftBanner(
                                  accentColor: iconColor,
                                  textColor: textColor,
                                  secondaryTextColor: secondaryTextColor,
                                ),

                              // 编辑区域 - 高度自适应，支持滚动
                              Expanded(
                                child: Stack(
                                  children: [
                                    // 正文输入框的高度只跟着文字走，文字下面的空白在
                                    // 它自己的矩形之外，双击那儿不会触发 Flutter 的
                                    // 双击选词，系统工具栏也就弹不出来。这里在最底层
                                    // 铺一层兜底手势：文字和浮层先吃事件，剩下的空白
                                    // 由它接住 —— 单击落光标，双击选中该处最近的词并
                                    // 弹出复制/粘贴工具栏。
                                    Positioned.fill(
                                      child: GestureDetector(
                                        behavior: HitTestBehavior.opaque,
                                        onTapDown: _handleBlankAreaTapDown,
                                        onDoubleTapDown:
                                            _handleBlankAreaDoubleTapDown,
                                        child: const SizedBox.expand(),
                                      ),
                                    ),
                                    Container(
                                      padding: const EdgeInsets.only(
                                        left: 16,
                                        right: 56,
                                        top: 8,
                                        bottom: 8,
                                      ),
                                      child: CompositedTransformTarget(
                                        link:
                                            _textFieldLayerLink, // 🎯 用于跟踪光标位置
                                        // 只旁听，不抢手势：TextField 自身的落点、
                                        // 选词、双击判定全部照旧。
                                        child: Listener(
                                          onPointerUp: _handleBodyPointerUp,
                                          child: TextField(
                                            controller: _textController,
                                            focusNode: _textFocusNode,
                                            scrollController: _scrollController,
                                            keyboardType:
                                                TextInputType.multiline,
                                            maxLines: null, // 允许无限行
                                            autofocus: true,
                                            decoration: InputDecoration(
                                              hintText:
                                                  AppLocalizationsSimple.of(
                                                        context,
                                                      )?.editorPlaceholder ??
                                                      '现在的想法是...',
                                              // 全局主题给输入框设了 filled:true，
                                              // 玻璃卡片上会糊出一块实心白，这里关掉
                                              filled: false,
                                              border: InputBorder.none,
                                              contentPadding: EdgeInsets.zero,
                                              hintStyle: TextStyle(
                                                fontSize: 16,
                                                color: hintTextColor,
                                                height: 1.5,
                                              ),
                                              enabledBorder: InputBorder.none,
                                              focusedBorder: InputBorder.none,
                                              disabledBorder: InputBorder.none,
                                              errorBorder: InputBorder.none,
                                              focusedErrorBorder:
                                                  InputBorder.none,
                                            ),
                                            cursorColor: iconColor,
                                            // 选中文字的复制/粘贴菜单换成
                                            // 仿系统的胶囊横条，尺寸参考
                                            // HyperOS 的 ActionMode 悬浮条。
                                            contextMenuBuilder:
                                                (context, editableTextState) {
                                              final anchors = editableTextState
                                                  .contextMenuAnchors;
                                              return CapsuleTextSelectionToolbar(
                                                anchorAbove:
                                                    anchors.primaryAnchor,
                                                anchorBelow:
                                                    anchors.secondaryAnchor ??
                                                        anchors.primaryAnchor,
                                                buttonItems: editableTextState
                                                    .contextMenuButtonItems,
                                              );
                                            },
                                            style: TextStyle(
                                              fontSize: 16,
                                              color: textColor,
                                              height: 1.5,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),

                                    // 语音识别按钮 - 固定在右上角；语音未开启时不渲染
                                    if (_speechEnabled)
                                      Positioned(
                                        top: 4,
                                        right: 12,
                                        child: _buildSpeechButton(
                                          iconColor,
                                          secondaryTextColor,
                                        ),
                                      ),

                                    // 实时识别文本提示 - 大厂级别的炫酷动效
                                    if (_isSpeechListening)
                                      Positioned(
                                        bottom: 8,
                                        left: 16,
                                        right: 56,
                                        child: GestureDetector(
                                          onTap:
                                              _toggleSpeechRecognition, // 点击整个识别框停止
                                          behavior: HitTestBehavior
                                              .opaque, // 确保整个区域可点击
                                          child: AnimatedContainer(
                                            duration: const Duration(
                                              milliseconds: 200,
                                            ),
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 16,
                                              vertical: 16,
                                            ),
                                            decoration: BoxDecoration(
                                              gradient: LinearGradient(
                                                colors: _partialSpeechText
                                                        .isEmpty
                                                    ? [
                                                        iconColor.withValues(
                                                          alpha: 0.05,
                                                        ),
                                                        iconColor.withValues(
                                                          alpha: 0.1,
                                                        ),
                                                      ]
                                                    : [
                                                        iconColor.withValues(
                                                          alpha: 0.12,
                                                        ),
                                                        iconColor.withValues(
                                                          alpha: 0.18,
                                                        ),
                                                      ],
                                                begin: Alignment.topLeft,
                                                end: Alignment.bottomRight,
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(16),
                                              border: Border.all(
                                                color: iconColor.withValues(
                                                  alpha: 0.4,
                                                ),
                                                width: 1.5,
                                              ),
                                              boxShadow: [
                                                BoxShadow(
                                                  color: iconColor.withValues(
                                                    alpha: 0.25,
                                                  ),
                                                  blurRadius: 12,
                                                  offset: const Offset(0, 4),
                                                ),
                                              ],
                                            ),
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Row(
                                                  children: [
                                                    // 音波动画
                                                    _buildSoundWaveAnimation(
                                                      iconColor,
                                                    ),
                                                    const SizedBox(width: 12),
                                                    Expanded(
                                                      child: Column(
                                                        crossAxisAlignment:
                                                            CrossAxisAlignment
                                                                .start,
                                                        children: [
                                                          // 状态文字
                                                          Text(
                                                            _partialSpeechText
                                                                    .isEmpty
                                                                ? (AppLocalizationsSimple
                                                                            .of(
                                                                      context,
                                                                    )
                                                                        ?.voiceListening ??
                                                                    '正在聆听...')
                                                                : (AppLocalizationsSimple
                                                                        .of(
                                                                      context,
                                                                    )?.voiceRecognizing ??
                                                                    '识别中'),
                                                            style: TextStyle(
                                                              color: iconColor,
                                                              fontSize: 12,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w500,
                                                            ),
                                                          ),
                                                          if (_partialSpeechText
                                                              .isNotEmpty) ...[
                                                            const SizedBox(
                                                              height: 8,
                                                            ),
                                                            // 识别文字 - 带打字机效果
                                                            AnimatedDefaultTextStyle(
                                                              duration:
                                                                  const Duration(
                                                                milliseconds:
                                                                    150,
                                                              ),
                                                              style: TextStyle(
                                                                color:
                                                                    textColor,
                                                                fontSize: 16,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w600,
                                                                height: 1.4,
                                                              ),
                                                              child: Text(
                                                                _partialSpeechText,
                                                                maxLines: 3,
                                                                overflow:
                                                                    TextOverflow
                                                                        .ellipsis,
                                                              ),
                                                            ),
                                                          ],
                                                        ],
                                                      ),
                                                    ),
                                                    // 点击停止提示
                                                    Container(
                                                      padding: const EdgeInsets
                                                          .symmetric(
                                                        horizontal: 8,
                                                        vertical: 4,
                                                      ),
                                                      decoration: BoxDecoration(
                                                        color: iconColor
                                                            .withValues(
                                                          alpha: 0.15,
                                                        ),
                                                        borderRadius:
                                                            BorderRadius
                                                                .circular(8),
                                                      ),
                                                      child: Text(
                                                        AppLocalizationsSimple
                                                                .of(
                                                              context,
                                                            )?.clickToStop ??
                                                            '点击停止',
                                                        style: TextStyle(
                                                          color: iconColor,
                                                          fontSize: 11,
                                                          fontWeight:
                                                              FontWeight.w500,
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),

                              // 图片预览区域：九宫格（长按拖动排序）
                              if (_imageList.isNotEmpty)
                                _buildImageSection(
                                  dividerColor,
                                  imageSectionHeight,
                                ),

                              // 更多选项栏（条件显示）
                              if (_showingMoreOptions)
                                Container(
                                  margin:
                                      const EdgeInsets.fromLTRB(12, 8, 12, 0),
                                  decoration: BoxDecoration(
                                    color: backgroundColor,
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color:
                                          dividerColor.withValues(alpha: 0.3),
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: isDarkMode
                                            ? Colors.black
                                                .withValues(alpha: 0.3)
                                            : Colors.grey
                                                .withValues(alpha: 0.1),
                                        blurRadius: 4,
                                        offset: const Offset(0, 2),
                                      ),
                                    ],
                                  ),
                                  child: SizedBox(
                                    height: 50,
                                    child: SingleChildScrollView(
                                      scrollDirection: Axis.horizontal,
                                      child: Row(
                                        children: [
                                          const SizedBox(width: 8),

                                          // 下划线
                                          _buildMoreOptionButton(
                                            icon: Icons.format_underlined,
                                            onPressed: () {
                                              _wrapSelectedText('<u>', '</u>');
                                              setState(
                                                () =>
                                                    _showingMoreOptions = false,
                                              );
                                            },
                                            secondaryTextColor:
                                                secondaryTextColor,
                                          ),

                                          // 链接
                                          _buildMoreOptionButton(
                                            icon: Icons.link,
                                            onPressed: () {
                                              setState(
                                                () =>
                                                    _showingMoreOptions = false,
                                              );
                                              _showLinkDialog();
                                            },
                                            secondaryTextColor:
                                                secondaryTextColor,
                                          ),

                                          // 引用格式
                                          _buildMoreOptionButton(
                                            icon: Icons.format_quote,
                                            onPressed: () {
                                              _insertQuoteLine();
                                              setState(
                                                () =>
                                                    _showingMoreOptions = false,
                                              );
                                            },
                                            secondaryTextColor:
                                                secondaryTextColor,
                                          ),

                                          // 标题
                                          _buildMoreOptionButton(
                                            icon: Icons.title,
                                            onPressed: () {
                                              _toggleHeading();
                                              setState(
                                                () =>
                                                    _showingMoreOptions = false,
                                              );
                                            },
                                            secondaryTextColor:
                                                secondaryTextColor,
                                          ),

                                          // 代码
                                          _buildMoreOptionButton(
                                            icon: Icons.code,
                                            onPressed: () {
                                              _wrapSelectedText('`', '`');
                                              setState(
                                                () =>
                                                    _showingMoreOptions = false,
                                              );
                                            },
                                            secondaryTextColor:
                                                secondaryTextColor,
                                          ),

                                          // 笔记引用（使用@图标）
                                          _buildMoreOptionButton(
                                            icon: Icons.alternate_email,
                                            onPressed: () {
                                              _showNoteReferenceDialog();
                                              setState(
                                                () =>
                                                    _showingMoreOptions = false,
                                              );
                                            },
                                            secondaryTextColor:
                                                secondaryTextColor,
                                          ),

                                          const SizedBox(width: 8),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),

                              // AI 选项栏（条件显示）
                              if (_showingAIOptions)
                                Container(
                                  margin:
                                      const EdgeInsets.fromLTRB(12, 8, 12, 0),
                                  decoration: BoxDecoration(
                                    color: backgroundColor,
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color:
                                          dividerColor.withValues(alpha: 0.3),
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: isDarkMode
                                            ? Colors.black
                                                .withValues(alpha: 0.3)
                                            : Colors.grey
                                                .withValues(alpha: 0.1),
                                        blurRadius: 4,
                                        offset: const Offset(0, 2),
                                      ),
                                    ],
                                  ),
                                  child: SizedBox(
                                    height: 50,
                                    child: Row(
                                      children: [
                                        const SizedBox(width: 8),

                                        // AI 续写 - 使用魔法棒图标表示AI自动续写
                                        _buildMoreOptionButton(
                                          icon: Icons.auto_fix_high,
                                          onPressed: () {
                                            setState(
                                              () => _showingAIOptions = false,
                                            );
                                            _aiContinueWriting();
                                          },
                                          secondaryTextColor:
                                              secondaryTextColor,
                                        ),

                                        // 智能标签 - 使用价签图标表示标签
                                        _buildMoreOptionButton(
                                          icon: Icons.local_offer_outlined,
                                          onPressed: () {
                                            setState(
                                              () => _showingAIOptions = false,
                                            );
                                            _aiGenerateTags();
                                          },
                                          secondaryTextColor:
                                              secondaryTextColor,
                                        ),

                                        const SizedBox(width: 8),
                                      ],
                                    ),
                                  ),
                                ),

                              // 底部功能栏和发送按钮
                              Container(
                                height: toolbarHeight,
                                decoration: BoxDecoration(
                                  color: backgroundColor,
                                  border: Border(
                                    top: BorderSide(
                                      color: dividerColor,
                                      width: 0.5,
                                    ),
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    // 功能按钮容器
                                    Expanded(
                                      child: SingleChildScrollView(
                                        scrollDirection: Axis.horizontal,
                                        child: Row(
                                          children: [
                                            const SizedBox(width: 12),

                                            // # 标签按钮
                                            _buildToolbarIconButton(
                                              icon: Text(
                                                '#',
                                                style: TextStyle(
                                                  fontSize: 20,
                                                  fontWeight: FontWeight.bold,
                                                  color: secondaryTextColor,
                                                ),
                                              ),
                                              onPressed: () => _insertText('#'),
                                              iconColor: secondaryTextColor,
                                              activeColor: iconColor,
                                            ),

                                            // 图片按钮
                                            _buildToolbarIconButton(
                                              icon: Icon(
                                                Icons.photo_outlined,
                                                size: 20,
                                                color: secondaryTextColor,
                                              ),
                                              onPressed: _pickImage,
                                              iconColor: secondaryTextColor,
                                              activeColor: iconColor,
                                            ),

                                            // 🎯 待办按钮
                                            _buildToolbarIconButton(
                                              icon: Icon(
                                                Icons.check_box_outlined,
                                                size: 20,
                                                color: secondaryTextColor,
                                              ),
                                              onPressed: _insertTodoItem,
                                              iconColor: secondaryTextColor,
                                              activeColor: iconColor,
                                            ),

                                            // AI 按钮 - 与工具栏统一，点击展开/收起选项
                                            _buildToolbarIconButton(
                                              icon: Icon(
                                                _showingAIOptions
                                                    ? Icons.keyboard_arrow_down
                                                    : Icons.auto_awesome,
                                                size: 20,
                                                color: secondaryTextColor,
                                              ),
                                              onPressed: () {
                                                setState(() {
                                                  _showingAIOptions =
                                                      !_showingAIOptions;
                                                });
                                              },
                                              iconColor: secondaryTextColor,
                                              activeColor: iconColor,
                                              isActive: _showingAIOptions,
                                            ),

                                            // B 粗体按钮
                                            _buildToolbarIconButton(
                                              icon: Text(
                                                'B',
                                                style: TextStyle(
                                                  fontSize: 20,
                                                  fontWeight: FontWeight.bold,
                                                  color: secondaryTextColor,
                                                ),
                                              ),
                                              onPressed: _toggleBold,
                                              iconColor: secondaryTextColor,
                                              activeColor: iconColor,
                                              isActive:
                                                  _textController.isMarkActive(
                                                MemoTextMark.bold,
                                              ),
                                            ),

                                            // 列表按钮
                                            _buildToolbarIconButton(
                                              icon: Icon(
                                                Icons.format_list_bulleted,
                                                size: 20,
                                                color: secondaryTextColor,
                                              ),
                                              onPressed: _insertBulletItem,
                                              iconColor: secondaryTextColor,
                                              activeColor: iconColor,
                                            ),

                                            // 更多按钮
                                            _buildToolbarIconButton(
                                              icon: Icon(
                                                _showingMoreOptions
                                                    ? Icons.keyboard_arrow_down
                                                    : Icons.more_horiz,
                                                size: 20,
                                                color: secondaryTextColor,
                                              ),
                                              onPressed: _showMoreOptions,
                                              iconColor: secondaryTextColor,
                                              activeColor: iconColor,
                                              isActive: _showingMoreOptions,
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),

                                    // 发送按钮
                                    // 直接监听输入内容，不再依赖外层 build 重建：
                                    // 首行打字不改变行数，原先按钮会一直保持灰色。
                                    ValueListenableBuilder<TextEditingValue>(
                                      valueListenable: _textController,
                                      builder: (context, textValue, _) {
                                        final canSave =
                                            textValue.text.trim().isNotEmpty ||
                                                _imageList.isNotEmpty;
                                        return Container(
                                          padding:
                                              const EdgeInsets.only(right: 12),
                                          child: Container(
                                            width: 70,
                                            height: 32,
                                            decoration: BoxDecoration(
                                              color: canSave
                                                  ? (isDarkMode
                                                      ? AppTheme
                                                          .primaryLightColor
                                                      : AppTheme.primaryColor)
                                                  : (isDarkMode
                                                      ? Colors.grey[700]
                                                      : Colors.grey[300]),
                                              borderRadius:
                                                  BorderRadius.circular(16),
                                            ),
                                            child: IconButton(
                                              icon: const Icon(
                                                Icons.send,
                                                color: Colors.white,
                                                size: 18,
                                              ),
                                              padding: EdgeInsets.zero,
                                              onPressed: (canSave && !_isSaving)
                                                  ? _saveNote
                                                  : null,
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 九宫格布局参数（拖动排序的坐标反算依赖这几个值，别只改 GridView）
  static const int _imageGridColumns = 3;
  static const double _imageGridSpacing = 8;
  static const double _imageGridHPadding = 16;
  static const double _imageGridTopPadding = 4;
  static const double _imageGridBottomPadding = 16;

  /// 标题行（「N 张图片 · 长按拖动排序」）的高度。
  ///
  /// 写死是为了让图片区总高能在 build 里先算出来——这个高度同时决定卡片高度，
  /// 不能等布局完成再回填（回填会让首帧高度跳一下）。
  static const double _imageGridHeaderHeight = 22;

  /// 单格边长。网格撑满屏宽，左右各留 [_imageGridHPadding]，格间留
  /// [_imageGridSpacing]；高度预估与拖动坐标反算必须共用这一个式子。
  static double _imageGridTileSize(double width) =>
      (width -
          _imageGridHPadding * 2 -
          _imageGridSpacing * (_imageGridColumns - 1)) /
      _imageGridColumns;

  /// 九宫格行数（图片按 3 列铺开）。
  int get _imageRows =>
      (_imageList.length + _imageGridColumns - 1) ~/ _imageGridColumns;

  /// 九宫格内容总高：标题行 + 行数 × 格子 + 行间距 + 底部留白。
  ///
  /// 底部留白由 Column 末尾的 SizedBox 提供，**不在 GridView 的 padding 里**：
  /// 放进滚动视图的话第一屏视口会多出这段高度，第一行下面就会露出第二行的上沿，
  /// 看起来像图片被裁了一半。
  ///
  /// 图片越多越高，屏幕放不下时由图片区高度与卡片高度上限共同收口，
  /// 溢出的部分在格子里滚动，不再留一条固定的空高度。
  double _imageGridContentHeight(double width) {
    if (_imageList.isEmpty) {
      return 0;
    }
    final rows = _imageRows;
    return _imageGridHeaderHeight +
        _imageGridTopPadding +
        rows * _imageGridTileSize(width) +
        (rows - 1) * _imageGridSpacing +
        _imageGridBottomPadding;
  }

  /// 在 [budget] 里能放下的完整行数对应的高度（至少一行，至多全部）。
  ///
  /// 只给整数行：卡片被屏幕钳住时，图片区拿到的预算往往不是整行高度，照着
  /// 预算给就会露出半行残图，读起来像加载失败。
  double _imageGridFitHeight(double budget, double width) {
    final target = _imageGridContentHeight(width);
    if (budget >= target) {
      return target;
    }
    final tile = _imageGridTileSize(width);
    // 首行不含行间距，所以先把固定部分减掉、再补一个 spacing 才能按步长取整。
    final fit = ((budget -
                _imageGridHeaderHeight -
                _imageGridTopPadding -
                _imageGridBottomPadding +
                _imageGridSpacing) /
            (tile + _imageGridSpacing))
        .floor()
        .clamp(1, _imageRows);
    return _imageGridHeaderHeight +
        _imageGridTopPadding +
        fit * tile +
        (fit - 1) * _imageGridSpacing +
        _imageGridBottomPadding;
  }

  /// 让位动画时长。拖动时读起来是「跟着手走」而不是「慢半拍」。
  static const Duration _imageGridSwapDuration = Duration(milliseconds: 130);

  /// 图片区：九宫格，长按格子拖动排序。
  ///
  /// 高度由调用方按行数算好后传入；不足时裁掉下沿（滚动交给内层 GridView），
  /// 所以这里只需要一个裁剪壳，不再有两态切换。
  Widget _buildImageSection(Color dividerColor, double height) => SizedBox(
        key: const ValueKey('note-editor-image-section'),
        // 宽度必须显式给满：Column 默认 center，容器宽度一旦退回「由内容决定」，
        // 格子边长就会跟着内容重算。
        width: double.infinity,
        height: height,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(color: dividerColor, width: 0.5),
            ),
          ),
          child: ClipRect(child: _buildImageGrid()),
        ),
      );

  Widget _buildImageGrid() {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final secondaryTextColor = isDarkMode ? Colors.grey[400] : Colors.grey[700];
    return Column(
      children: [
        // 高度必须固定：它已经算进图片区总高，这里若随字号/字体缩放变高，卡片
        // 就会比预算的矮一截，九宫格底部被裁。
        SizedBox(
          height: _imageGridHeaderHeight,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '${_imageList.length} 张图片 · 长按拖动排序',
                style: TextStyle(fontSize: 12, color: secondaryTextColor),
              ),
            ),
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              // 格子是正方形，间距两个方向一致，所以横竖位移都用同一个步长。
              final tileSize = _imageGridTileSize(constraints.maxWidth);
              final stride = tileSize + _imageGridSpacing;
              return GridView.builder(
                key: _imageGridKey,
                controller: _imageGridScrollController,
                padding: const EdgeInsets.fromLTRB(
                  _imageGridHPadding,
                  _imageGridTopPadding,
                  _imageGridHPadding,
                  0,
                ),
                // 拖动排序时每帧都会重建，省掉 keep-alive 的额外开销。
                addAutomaticKeepAlives: false,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: _imageGridColumns,
                  crossAxisSpacing: _imageGridSpacing,
                  mainAxisSpacing: _imageGridSpacing,
                ),
                itemCount: _imageList.length,
                itemBuilder: (context, index) =>
                    _buildGridImageItem(index, tileSize, stride),
              );
            },
          ),
        ),
        // 底部留白放在滚动视图**外面**：放进去第一屏视口就多出一段，第一行下面
        // 会露出第二行的上沿。
        const SizedBox(height: _imageGridBottomPadding),
      ],
    );
  }

  /// 九宫格里的一格。
  ///
  /// 拖动时不再用 `DragTarget` 做「放下才交换」，而是：
  /// 1. 长按起拖记下原始下标；
  /// 2. 指针每次移动按坐标反算压住了哪一格（[_updateGridDragHover]）；
  /// 3. 被跨越的格子用 [AnimatedSlide] 实时让开一格，看起来像整块在流动；
  /// 4. 松手才真正改数据顺序，位移与重排在同一帧抵掉，不会看到回弹。
  Widget _buildGridImageItem(int index, double tileSize, double stride) {
    final image = _imageList[index];
    return AnimatedSlide(
      key: ObjectKey(image),
      offset: _gridTileDisplacement(index, stride, tileSize),
      // 松手那一刻要让位移瞬间归零：数据重排和位移复位必须落在同一帧，否则会
      // 先看到格子滑回原位、再跳到新位置的两段动作。
      duration:
          _dragSourceIndex == null ? Duration.zero : _imageGridSwapDuration,
      curve: Curves.easeOut,
      child: LongPressDraggable<int>(
        data: index,
        // 让位后原位置的半透明占位要跟着「空位」走，所以拖起来的是哪一格就只有
        // 那一格变淡。
        childWhenDragging: Opacity(
          opacity: 0.25,
          child: _buildGridTile(image, index, showDelete: false),
        ),
        feedback: Material(
          color: Colors.transparent,
          elevation: 8,
          borderRadius: BorderRadius.circular(10),
          child: SizedBox(
            width: tileSize,
            height: tileSize,
            child: _buildGridTile(image, index, showDelete: false),
          ),
        ),
        onDragStarted: () => setState(() {
          _dragSourceIndex = index;
          _dragHoverIndex = index;
        }),
        onDragUpdate: (details) => _updateGridDragHover(details.globalPosition),
        onDragEnd: (details) => _finishGridDrag(),
        onDraggableCanceled: (velocity, offset) =>
            _finishGridDrag(cancelled: true),
        child: _buildGridTile(image, index, showDelete: false),
      ),
    );
  }

  /// 第 [index] 格在拖动中应该偏移多少像素。
  ///
  /// 把网格按行优先展平成一维序列：从起拖格拖到被压住的格子时，中间被越过的
  /// 格子依次顶上（或退后）一格。跨行时横纵位移分开算，所以第二行第一列会正确
  /// 斜着挪。
  Offset _gridTileDisplacement(int index, double stride, double tileSize) {
    final from = _dragSourceIndex;
    final to = _dragHoverIndex;
    if (from == null || to == null) {
      return Offset.zero;
    }
    final steps = gridSwapSteps(
      index: index,
      from: from,
      to: to,
      columns: _imageGridColumns,
    );
    if (steps == null) {
      return Offset.zero;
    }
    // AnimatedSlide 的 offset 是相对自身尺寸的比例，格子是正方形、步长也相等，
    // 横纵可以共用一个换算系数。
    final unit = stride / tileSize;
    return Offset(steps.dx * unit, steps.dy * unit);
  }

  /// 按指针位置反算压在哪个格子上。
  ///
  /// 不用 `DragTarget` 是因为格子会让位，「指针没动、命中目标却变了」会让
  /// DragTarget 反复触发 onMove/onLeave，让位动画来回抖。坐标反算则完全取决于
  /// 指针本身，稳定。
  void _updateGridDragHover(Offset globalPosition) {
    final from = _dragSourceIndex;
    if (from == null) {
      return;
    }
    final box = _imageGridKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || _imageList.isEmpty) {
      return;
    }
    final local = box.globalToLocal(globalPosition);
    final tileSize = _imageGridTileSize(box.size.width);
    final stride = tileSize + _imageGridSpacing;
    final scrolled = _imageGridScrollController.hasClients
        ? _imageGridScrollController.offset
        : 0.0;

    // 列先夹住：指针在左右边距里时 floor 会算出 -1 或 3，直接代入会把「同一行
    // 第一格」错算成「上一行最后一格」。
    final col = ((local.dx - _imageGridHPadding) / stride)
        .floor()
        .clamp(0, _imageGridColumns - 1);
    final row =
        ((local.dy + scrolled - _imageGridTopPadding) / stride).floor().clamp(
              0,
              (_imageList.length + _imageGridColumns - 1) ~/ _imageGridColumns,
            );
    final index =
        (row * _imageGridColumns + col).clamp(0, _imageList.length - 1);
    if (index != _dragHoverIndex) {
      setState(() => _dragHoverIndex = index);
    }
  }

  /// 松手：先清掉让位状态，再把数据真正挪过去。
  ///
  /// 两次 setState 在同一帧内生效，位移归零与列表重排同时发生，视觉上没有回弹。
  void _finishGridDrag({bool cancelled = false}) {
    final from = _dragSourceIndex;
    final to = _dragHoverIndex;
    if (from == null) {
      return;
    }
    setState(() {
      _dragSourceIndex = null;
      _dragHoverIndex = null;
    });
    if (!cancelled && to != null && from != to) {
      _moveImage(from, to);
    }
  }

  Widget _buildGridTile(
    _ImageItem image,
    int index, {
    bool showDelete = true,
    bool highlighted = false,
  }) =>
      DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: highlighted
                ? AppTheme.primaryColor
                : Colors.grey.withValues(alpha: 0.3),
            width: highlighted ? 2 : 1,
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(9),
          child: Stack(
            fit: StackFit.expand,
            children: [
              _buildImageWidget(image.path),
              Positioned(
                top: 4,
                left: 4,
                child: _buildUploadStatusIcon(image.uploadStatus),
              ),
              if (showDelete)
                Positioned(
                  top: 4,
                  right: 4,
                  child: GestureDetector(
                    onTap: () => _removeImage(index),
                    child: Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.5),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.close,
                        color: Colors.white,
                        size: 16,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );

  /// 把第 [from] 张图片移动到第 [to] 个位置。
  ///
  /// `_mdCodes` 跟着图片一起走；`_imageAnchors` 视为正文里的「插槽」保持不动，
  /// 拖动只是让图片换到别的插槽。这样保存后的 Markdown 顺序与列表一致，
  /// 也不会把原本插在正文中间的图片整体挪到文末。
  void _moveImage(int from, int to) {
    if (from == to || from < 0 || from >= _imageList.length) {
      return;
    }
    final target = to.clamp(0, _imageList.length - 1);
    if (target == from) {
      return;
    }
    setState(() {
      _imageList.insert(target, _imageList.removeAt(from));
      if (from < _mdCodes.length) {
        final code = _mdCodes.removeAt(from);
        _mdCodes.insert(target.clamp(0, _mdCodes.length), code);
      }
    });
  }

  // 删除图片
  void _removeImage(int index) {
    setState(() {
      if (index < _imageList.length) {
        _imageList.removeAt(index);

        if (index < _mdCodes.length) {
          _mdCodes.removeAt(index);
        }
        if (index < _imageAnchors.length) {
          _imageAnchors.removeAt(index);
        }
      }
    });
  }

  // 在当前光标位置插入文本
  void _insertText(String text) {
    _textController.insertPlainText(text);
  }

  void _insertVisualLinePrefix(String prefix) {
    final currentText = _textController.text;
    final selection = _textController.selection;
    final cursorPos = selection.isValid ? selection.start : currentText.length;

    final searchOffset = math.max(0, cursorPos - 1);
    var lineStart = currentText.lastIndexOf('\n', searchOffset);
    lineStart = lineStart == -1 ? 0 : lineStart + 1;

    final lineEndIndex = currentText.indexOf('\n', cursorPos);
    final lineEnd = lineEndIndex == -1 ? currentText.length : lineEndIndex;
    final line = currentText.substring(lineStart, lineEnd);
    final existingPrefixMatch = RegExp(r'^(\s*)(☐ |☑ |• |│ )').firstMatch(line);
    final cleanLine = existingPrefixMatch == null
        ? line
        : '${existingPrefixMatch.group(1) ?? ''}'
            '${line.substring(existingPrefixMatch.end)}';

    final indent = RegExp(r'^\s*').firstMatch(cleanLine)?.group(0) ?? '';
    final nextLine = '$indent$prefix${cleanLine.substring(indent.length)}';
    final nextText = currentText.replaceRange(lineStart, lineEnd, nextLine);
    final cursorDelta = nextLine.length - line.length;

    _textController.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(
        offset: math.max(0, cursorPos + cursorDelta),
      ),
    );
  }

  // 🎯 插入待办事项（用户看到复选框，保存时转为 Memos Markdown）
  void _insertTodoItem() {
    _insertVisualLinePrefix('☐ ');
  }

  void _insertBulletItem() {
    _insertVisualLinePrefix('• ');
  }

  void _insertQuoteLine() {
    _insertVisualLinePrefix('│ ');
  }

  void _toggleBold() {
    _restoreSelectionForFormatting();
    _textController.toggleMark(MemoTextMark.bold);
    setState(() {});
  }

  void _toggleInlineCode() {
    _restoreSelectionForFormatting();
    _textController.toggleMark(MemoTextMark.code);
    setState(() {});
  }

  void _toggleUnderline() {
    _restoreSelectionForFormatting();
    _textController.toggleMark(MemoTextMark.underline);
    setState(() {});
  }

  void _toggleHeading() {
    _textController.toggleCurrentLineHeading();
    setState(() {});
  }

  Future<void> _showLinkDialog() async {
    final selection = _textController.selection;
    final selectedText = selection.isValid && !selection.isCollapsed
        ? _textController.text.substring(selection.start, selection.end)
        : '';
    final labelController = TextEditingController(text: selectedText);
    final urlController = TextEditingController();

    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) {
        final isDarkMode = Theme.of(context).brightness == Brightness.dark;
        return AlertDialog(
          title: Text(AppLocalizationsSimple.of(context)?.addLink ?? '添加链接'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: labelController,
                decoration: InputDecoration(
                  labelText:
                      AppLocalizationsSimple.of(context)?.displayText ?? '显示文字',
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: urlController,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  labelText:
                      AppLocalizationsSimple.of(context)?.linkAddress ?? '链接地址',
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(
                AppLocalizationsSimple.of(context)?.cancel ?? '取消',
                style: TextStyle(
                  color: isDarkMode
                      ? AppTheme.darkTextSecondaryColor
                      : AppTheme.textSecondaryColor,
                ),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, {
                'label': labelController.text,
                'url': urlController.text,
              }),
              child: Text(AppLocalizationsSimple.of(context)?.confirm ?? '确定'),
            ),
          ],
        );
      },
    );

    labelController.dispose();
    urlController.dispose();

    if (result == null) {
      return;
    }
    _textController.insertLink(result['label'] ?? '', result['url'] ?? '');
    setState(() {});
  }

  // 用指定的标记包裹所选文本
  void _wrapSelectedText(String prefix, String suffix) {
    if (prefix == '**' && suffix == '**') {
      _toggleBold();
      return;
    }

    if (prefix == '`' && suffix == '`') {
      _toggleInlineCode();
      return;
    }

    if (prefix == '<u>' && suffix == '</u>') {
      _toggleUnderline();
      return;
    }

    _textController.insertPlainText(prefix + suffix);
  }

  // 构建图片Widget，处理认证问题
  /// 编辑器图格的解码宽度（物理像素）。
  ///
  /// 必须和列表卡片 / 详情页九宫格用同一个档位（[kGridTileDecodeWidth]），否则
  /// `ImageCache` 的 key 不同，从首页双击进编辑器时会把同一批图再解码一份：缓存
  /// 条目凭空 +N，首次进入要卡上一秒左右（1.1.86 实测 5 张图的笔记）。
  ///
  /// 不设这个值时会按原图尺寸解码：一张 4000x3000 的手机照片就是 45.8MB 位图，
  /// 九宫格首帧要解 9 张（实测 412MB / 514ms），中端机直接 GC 风暴。
  static const int _imageDecodeWidth = kGridTileDecodeWidth;

  Widget _buildImageWidget(String uriString) {
    // 数据维护里缓存过的服务端附件：直接读本地副本
    final cachedAttachment = AttachmentCache.instance.fileFor(uriString);
    if (cachedAttachment != null) {
      // 默认档位就是网格档（480），与 _imageDecodeWidth 是同一个值
      final thumb = ThumbCache.instance.lookup(cachedAttachment.path);
      return Image.file(
        thumb ?? cachedAttachment,
        fit: BoxFit.cover,
        cacheWidth: thumb == null ? _imageDecodeWidth : null,
        errorBuilder: (context, error, stackTrace) => Container(
          color: Colors.grey[200],
          child: const Icon(Icons.broken_image, color: Colors.grey),
        ),
      );
    }

    if (MemosResourceService.isServerResourcePath(uriString)) {
      // Memos服务器资源路径，需要认证
      final appProvider = Provider.of<AppProvider>(context, listen: false);
      if (appProvider.resourceService != null) {
        final fullUrl = appProvider.resourceService!.buildImageUrl(uriString);
        final token = appProvider.user?.token;

        return CachedNetworkImage(
          imageUrl: fullUrl,
          fit: BoxFit.cover,
          // 编辑器里只显示 90~110px 的小格子，按缩略尺寸解码即可
          memCacheWidth: _imageDecodeWidth,
          httpHeaders: token != null ? {'Authorization': 'Bearer $token'} : {},
          placeholder: (context, url) => Container(
            color: Colors.grey[200],
            child: const Center(
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
          errorWidget: (context, url, error) {
            // 只在真出错时打一条，正常的 build 路径不能有 log：拖动排序时每帧
            // 都会重建这九个格子，debugPrint 的字符串拼接 + logcat 写入足够把
            // 60fps 拖到掉帧。
            debugPrint('NoteEditor: CachedNetworkImage 加载失败 - $url');
            return Container(
              color: Colors.grey[200],
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.broken_image, color: Colors.grey),
                  Text(
                    AppLocalizationsSimple.of(context)?.loadFailed ?? '加载失败',
                    style: TextStyle(color: Colors.grey[600], fontSize: 10),
                  ),
                ],
              ),
            );
          },
        );
      }
    }

    // 其他情况使用常规Image
    return Image(
      image: ResizeImage.resizeIfNeeded(
        _imageDecodeWidth,
        null,
        _getImageProvider(uriString),
      ),
      fit: BoxFit.cover,
      errorBuilder: (context, error, stackTrace) {
        debugPrint('Image error for $uriString: $error');
        return Container(
          color: Colors.grey[200],
          child: const Icon(Icons.broken_image, color: Colors.grey),
        );
      },
    );
  }

  // 根据URI获取适当的ImageProvider
  ImageProvider _getImageProvider(String uriString) {
    try {
      final cachedAttachment = AttachmentCache.instance.fileFor(uriString);
      if (cachedAttachment != null) {
        return FileImage(cachedAttachment);
      }

      if (uriString.startsWith('http://') || uriString.startsWith('https://')) {
        // 网络图片
        return NetworkImage(uriString);
      } else if (MemosResourceService.isServerResourcePath(uriString)) {
        // Memos服务器资源路径，构建完整URL并添加认证头
        final appProvider = Provider.of<AppProvider>(context, listen: false);
        if (appProvider.resourceService != null) {
          final fullUrl = appProvider.resourceService!.buildImageUrl(uriString);
          final token = appProvider.user?.token;
          if (token != null) {
            return CachedNetworkImageProvider(
              fullUrl,
              headers: {'Authorization': 'Bearer $token'},
            );
          } else {
            return CachedNetworkImageProvider(fullUrl);
          }
        } else {
          // 如果没有资源服务，尝试使用基础URL
          final baseUrl = appProvider.user?.serverUrl ??
              appProvider.appConfig.memosApiUrl ??
              '';
          if (baseUrl.isNotEmpty) {
            final token = appProvider.user?.token;
            final fullUrl = '$baseUrl$uriString';
            if (token != null) {
              return CachedNetworkImageProvider(
                fullUrl,
                headers: {'Authorization': 'Bearer $token'},
              );
            } else {
              return CachedNetworkImageProvider(fullUrl);
            }
          }
        }
        return const AssetImage('assets/images/logo.png');
      } else if (uriString.startsWith('file://')) {
        // 本地文件：优先读持久化缩略图，绕开 12MP 原图的解码开销
        final filePath = uriString.replaceFirst('file://', '');
        final thumb = ThumbCache.instance.lookup(filePath);
        return FileImage(thumb ?? File(filePath));
      } else if (uriString.startsWith('resource:')) {
        // 资源图片
        final assetPath = uriString.replaceFirst('resource:', '');
        return AssetImage(assetPath);
      } else {
        // 尝试作为本地文件处理
        try {
          final thumb = ThumbCache.instance.lookup(uriString);
          return FileImage(thumb ?? File(uriString));
        } on Object catch (e) {
          debugPrint('Error loading image: $e for $uriString');
          // 默认使用资源图片
          return const AssetImage('assets/images/logo.png');
        }
      }
    } on Object catch (e) {
      debugPrint('Error in _getImageProvider: $e');
      return const AssetImage('assets/images/logo.png');
    }
  }

  // 显示更多Markdown选项
  // 显示笔记引用对话框
  void _showNoteReferenceDialog() {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final appProvider = Provider.of<AppProvider>(context, listen: false);
    // 过滤掉当前正在编辑的笔记
    final allNotes = appProvider.notes
        .where((note) => note.id != widget.currentNoteId)
        .toList();

    showDialog(
      context: context,
      builder: (context) => NoteReferenceDialog(
        isDarkMode: isDarkMode,
        allNotes: allNotes,
        onReferenceSelected: (noteId) {
          Navigator.pop(context);
          _addNoteReference(noteId);
        },
      ),
    );
  }

  // 添加笔记引用关系（支持离线）
  Future<void> _addNoteReference(String relatedMemoId) async {
    try {
      final appProvider = Provider.of<AppProvider>(context, listen: false);
      final localRefService = LocalReferenceService.instance;

      // 找到被引用的笔记
      final referencedNote = appProvider.notes.firstWhere(
        (note) => note.id == relatedMemoId,
        orElse: () => Note(
          id: '',
          content: '',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );

      if (referencedNote.id.isEmpty) {
        SnackBarUtils.showError(
          context,
          AppLocalizationsSimple.of(context)?.noteNotFound ?? '找不到要引用的笔记',
        );
        return;
      }

      // 🎯 底层存储笔记ID（v1 API 兼容格式）
      // 使用纯数字 ID（v1 API 格式），确保 Memos 网站能识别
      final referenceText = '[[${referencedNote.id}]]';
      _insertText(referenceText);

      // 如果是新笔记（没有currentNoteId），只插入内容，保存时再建立关系
      if (widget.currentNoteId == null) {
        // 引用插入不显示通知，保持操作流畅
        return;
      }

      // 创建本地引用关系
      final success = await localRefService.createReference(
        widget.currentNoteId!,
        relatedMemoId,
      );
      if (!mounted) {
        return;
      }

      if (success) {
        SnackBarUtils.showSuccess(
          context,
          AppLocalizationsSimple.of(context)?.referenceCreated ?? '引用关系已创建',
        );

        // 如果是在线模式，尝试后台同步到服务器
        if (appProvider.isLoggedIn && !appProvider.isLocalMode) {
          unawaited(
            _syncReferenceToServer(widget.currentNoteId!, relatedMemoId),
          );
        }
      } else {
        SnackBarUtils.showError(
          context,
          AppLocalizationsSimple.of(context)?.referenceCreationFailed ??
              '创建引用关系失败',
        );
      }
    } on Object catch (e) {
      if (kDebugMode) {
        debugPrint('Error adding note reference: $e');
      }
      SnackBarUtils.showError(
        context,
        '${AppLocalizationsSimple.of(context)?.referenceFailed ?? '引用失败'}：$e',
      );
    }
  }

  // 同步引用关系到服务器（后台执行，不阻塞UI）
  Future<void> _syncReferenceToServer(
    String fromNoteId,
    String toNoteId,
  ) async {
    try {
      final appProvider = Provider.of<AppProvider>(context, listen: false);
      if (!appProvider.isLoggedIn || appProvider.memosApiService == null) {
        return;
      }

      // 调用AppProvider的引用关系处理方法
      // 这会在保存笔记时自动处理引用关系同步
    } on Object {
      // 不显示错误信息，因为本地引用关系已经创建成功
    }
  }

  void _showMoreOptions() {
    _preserveCurrentSelection();
    setState(() {
      _showingMoreOptions = !_showingMoreOptions;
    });
    _keepEditorFocused();
  }

  void _preserveCurrentSelection() {
    final selection = _textController.selection;
    if (selection.isValid && !selection.isCollapsed) {
      _lastUsableSelection = selection;
    }
  }

  void _restoreSelectionForFormatting() {
    final selection = _textController.selection;
    if (selection.isValid && !selection.isCollapsed) {
      _lastUsableSelection = selection;
      return;
    }

    final lastSelection = _lastUsableSelection;
    if (lastSelection == null || !lastSelection.isValid) {
      return;
    }
    if (lastSelection.start < 0 ||
        lastSelection.end > _textController.text.length ||
        lastSelection.isCollapsed) {
      return;
    }
    _textController.selection = lastSelection;
  }

  void _keepEditorFocused() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _textFocusNode.requestFocus();
    });
  }

  /// 空白区单击：把光标落到点击处（越界时由 RenderEditable 夹到最近的位置）。
  void _handleBlankAreaTapDown(TapDownDetails details) {
    final editableState = _editableTextState();
    if (editableState == null) {
      return;
    }
    final renderEditable = editableState.renderEditable;
    renderEditable.handleTapDown(details);
    renderEditable.selectPosition(cause: SelectionChangedCause.tap);
  }

  /// 空白区双击：选中点击处最近的词并弹出系统工具栏。
  ///
  /// 走的是 Flutter 自己的选词与工具栏（`RenderEditable.selectWord` /
  /// `EditableTextState.showToolbar`），所以行为和长按框选出来的那个工具栏
  /// 完全一致，不是另造一个菜单。
  void _handleBlankAreaDoubleTapDown(TapDownDetails details) {
    final editableState = _editableTextState();
    // 空笔记没有词可选，交给单击逻辑落光标就够了。
    if (editableState == null || _textController.text.isEmpty) {
      return;
    }
    final renderEditable = editableState.renderEditable;
    // selectWord 依赖上一次 tapDown 记录的位置，必须先喂进去。
    renderEditable.handleTapDown(details);
    renderEditable.selectWord(cause: SelectionChangedCause.doubleTap);
    // 选区叠加层是在选词之后那一帧才建好的，工具栏得等下一帧再显示。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _editableTextState()?.showToolbar();
    });
  }

  /// 点在当前光标所在的位置时，把系统工具栏叫出来。
  ///
  /// Flutter 只在双击选词、长按拖动之后 showToolbar；光标已经落在字中间
  /// （selection 折叠）时再点同一个字，框架只是把光标摆回原地 —— 位置没变，
  /// 也就没有选区变化事件，复制/粘贴菜单根本不会出现。
  ///
  /// 这里旁听指针抬起：把落点换算成字符位置，正好等于当前光标就手动弹菜单。
  /// 用 [Listener] 而不是 GestureDetector 是有意的 —— 它不参与手势竞技场，
  /// TextField 该落的落点、该选的词、双击判定一律照旧。
  void _handleBodyPointerUp(PointerUpEvent event) {
    final editableState = _editableTextState();
    if (editableState == null || !_textFocusNode.hasFocus) {
      return;
    }

    final renderEditable = editableState.renderEditable;
    if (!renderEditable.hasSize) {
      return;
    }

    final selection = _textController.selection;
    if (!selection.isValid || !selection.isCollapsed) {
      return;
    }

    // 注意 getPositionForPoint 收的是全局坐标，内部自己会转局部，别再转一次。
    final tapped = renderEditable.getPositionForPoint(event.position);
    // 点在别处就是在挪光标，交给 TextField 自己处理。
    if (tapped.offset != selection.baseOffset) {
      return;
    }

    // 抬起时 Flutter 的单击还得过一道双击判定才落定，落定过程会再摆一次光标；
    // 等这一帧收尾再弹，避免刚出来就被收起。若这时选区已经变成选词（用户其实
    // 是在双击），说明框架自己会弹，这里就不插手。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final current = _textController.selection;
      if (!_textFocusNode.hasFocus ||
          !current.isValid ||
          !current.isCollapsed) {
        return;
      }
      _editableTextState()?.showToolbar();
    });
  }

  /// TextField 不对外暴露内部的 [EditableTextState]，而选词、显示工具栏这些能力
  /// 都在它身上，只能从编辑器子树里把它捞出来。
  EditableTextState? _editableTextState() {
    EditableTextState? found;
    void visit(Element element) {
      if (found != null) {
        return;
      }
      if (element is StatefulElement && element.state is EditableTextState) {
        found = element.state as EditableTextState;
        return;
      }
      element.visitChildren(visit);
    }

    (context as Element).visitChildren(visit);
    return found;
  }

  void _focusEditorAfterOpen() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      FocusScope.of(context).requestFocus(_textFocusNode);
      Future<void>.delayed(const Duration(milliseconds: 180), () {
        if (!mounted) {
          return;
        }
        FocusScope.of(context).requestFocus(_textFocusNode);
      });
    });
  }

  // 防止重复点击的标志
  //
  // 之前是 bool + try/finally 复位，但开始/停止都要 await 平台通道调用；某些机型
  // 上这些调用会一直不返回，标志就永久停在 true，之后点麦克风、点"正在聆听"整条
  // 都变成哑的 —— 用户看到的就是"停不了"。改成带超时的判断：最多挡 3 秒，
  // 卡住的等待不会再把这个按钮锁死。
  static const Duration _speechToggleGuard = Duration(seconds: 3);
  DateTime? _speechToggleStartedAt;

  /// 语音入口是否可见：与首页同一口径（设置里开启 + 讯飞密钥填全）。
  bool get _speechEnabled => Provider.of<AppProvider>(context, listen: false)
      .appConfig
      .speechInputEnabled;

  /// 识别"哑火"看门狗：开始后这么久既没声音也没出字，就判定识别没工作。
  static const Duration _speechSilenceTimeout = Duration(seconds: 12);
  Timer? _speechWatchdog;
  bool _speechHeardAnySound = false;

  bool get _isProcessing {
    final startedAt = _speechToggleStartedAt;
    return startedAt != null &&
        DateTime.now().difference(startedAt) < _speechToggleGuard;
  }

  /// 讯飞的 VAD 判停（说完停顿 3s）会把这一段结束掉：
  /// 把结果落进正文并复位"录音中"状态，用户不用再点一次停止。
  void _handleSpeechDone(String text) {
    _speechWatchdog?.cancel();
    if (!mounted || !_isSpeechListening) {
      return;
    }
    final recognized =
        text.trim().isNotEmpty ? text.trim() : _partialSpeechText.trim();
    if (recognized.isNotEmpty) {
      _insertText(recognized);
    }
    _speechAnimationController.stop();
    _speechAnimationController.reset();
    setState(() {
      _isSpeechListening = false;
      _partialSpeechText = '';
    });
    // 顺手释放麦克风，下次点击能立刻重新开始
    unawaited(_speechService.stopListening());
  }

  /// 识别中途出错（没有识别引擎、被别的应用占用、没网…）：
  /// 把界面从"正在聆听"收回来，并把原因告诉用户。
  ///
  /// 讯飞只在出错时回调一次，之前没人接，录音条就会一直挂在屏幕上。
  void _handleSpeechError(String message) {
    _speechWatchdog?.cancel();
    if (!mounted || !_isSpeechListening) {
      return;
    }
    debugPrint('NoteEditor: 语音识别出错 - $message');
    _speechAnimationController.stop();
    _speechAnimationController.reset();
    setState(() {
      _isSpeechListening = false;
      _partialSpeechText = '';
    });
    SnackBarUtils.showError(context, message);
  }

  // 启动识别（可重用）
  Future<void> _startRecognition() async {
    // 🎯 不在这里启动动画，等有声音时再启动（像大厂一样）
    // 动画由 onSoundLevel 回调控制

    final success = await _speechService.startListening(
      appConfig: Provider.of<AppProvider>(context, listen: false).appConfig,
      onResult: (text) async {
        debugPrint('NoteEditor: 收到识别结果 - "$text"');

        if (text.isNotEmpty && mounted) {
          // 有结果说明识别链路是通的，看门狗可以撤了
          _speechWatchdog?.cancel();
          // 🎯 实时显示识别文本（像微信一样）
          setState(() {
            _partialSpeechText = text;
          });
        }
      },
      // 🎤 监听音量变化，控制动画播放
      onSoundLevel: (level) {
        if (mounted) {
          // 🎯 只在有声音时播放动画（像大厂一样）
          if (level > 0.1) {
            _speechHeardAnySound = true;
            _speechWatchdog?.cancel();
            if (!_speechAnimationController.isAnimating) {
              _speechAnimationController.repeat();
            }
          } else {
            // 静音时暂停动画
            if (_speechAnimationController.isAnimating) {
              _speechAnimationController.stop();
              _speechAnimationController.reset();
            }
          }
        }
      },
      // 讯飞判停把这次识别收尾了：
      // 把文本落进正文并把"录音中"状态复位，避免按钮一直停在停止态。
      onDone: _handleSpeechDone,
      // 识别中途出错（没有识别引擎 / 被别的应用占用 / 没网）：
      // 立刻把界面从"正在聆听"收回来，并把原因告诉用户。
      onError: _handleSpeechError,
    );

    if (!success) {
      if (mounted) {
        setState(() {
          _isSpeechListening = false;
        });
      }
      return;
    }

    // 系统"假装"启动成功时（没有识别引擎 / 麦克风被别的应用占着），
    // 既不会有结果也不会有错误回调，界面就一直挂在"正在聆听"。
    // 这里起一个看门狗：只要期间既没听到声音也没出过字，就自己收尾并说明原因。
    _speechHeardAnySound = false;
    _speechWatchdog?.cancel();
    _speechWatchdog = Timer(_speechSilenceTimeout, () {
      if (!mounted || !_isSpeechListening || _speechHeardAnySound) {
        return;
      }
      if (_partialSpeechText.isNotEmpty) {
        return;
      }
      debugPrint('NoteEditor: 识别长时间无输入，判定识别未工作');
      _abortSpeechWithHint('没有检测到麦克风输入，语音识别可能不可用');
    });
  }

  /// 看门狗判定识别没有真正工作时，收尾并提示。
  void _abortSpeechWithHint(String message) {
    _speechWatchdog?.cancel();
    _speechAnimationController.stop();
    _speechAnimationController.reset();
    if (mounted) {
      setState(() {
        _isSpeechListening = false;
        _partialSpeechText = '';
      });
      SnackBarUtils.showError(context, message);
    }
    unawaited(_speechService.stopListening());
  }

  // 开始/停止语音识别
  Future<void> _toggleSpeechRecognition() async {
    // 防止重复点击
    if (_isProcessing) {
      debugPrint('NoteEditor: 操作进行中，忽略重复点击');
      return;
    }

    _speechToggleStartedAt = DateTime.now();

    try {
      if (_isSpeechListening) {
        debugPrint('NoteEditor: 停止语音识别');
        _speechWatchdog?.cancel();
        // 停止语音识别 - 将当前识别的文本插入
        final recognizedText = _partialSpeechText.trim().isNotEmpty
            ? _partialSpeechText.trim()
            : _speechService.lastRecognizedText.trim();
        if (recognizedText.isNotEmpty) {
          _insertText(recognizedText);
        }

        // 🎯 先复位界面，再去等平台释放麦克风：
        // 平台调用即使卡住，用户也不会再看到"正在聆听"一直挂在屏幕上
        _speechAnimationController.stop();
        _speechAnimationController.reset();
        setState(() {
          _isSpeechListening = false;
          _partialSpeechText = '';
        });

        // 🔥 Android: 确保完全释放麦克风资源（带超时，卡住也不拖死界面）
        await _speechService.stopListening().timeout(
              const Duration(seconds: 3),
              onTimeout: () {},
            );

        // 🎯 给用户反馈，确认已停止
        if (mounted) {
          debugPrint('NoteEditor: ✅ 语音识别已停止，麦克风已释放');
        }
      } else {
        debugPrint('NoteEditor: 开始语音识别');
        // 开始语音识别
        final hasPermission = await _speechService.checkPermission();
        if (!hasPermission) {
          final granted = await _speechService.requestPermission();
          if (!granted) {
            if (mounted) {
              SnackBarUtils.showError(
                context,
                AppLocalizationsSimple.of(context)
                        ?.microphonePermissionRequired ??
                    '需要麦克风权限才能使用语音识别',
              );
            }
            return;
          }
        }

        // 清空之前的识别结果
        setState(() {
          _partialSpeechText = '';
          _isSpeechListening = true;
        });

        // 启动识别
        await _startRecognition();
      }
    } finally {
      // 立刻释放防抖标志；即使上面的 await 一直不返回，_isProcessing 也会在
      // [_speechToggleGuard] 之后自动过期，按钮不会永久失效
      _speechToggleStartedAt = null;
    }
  }

  Widget _buildMoreOptionButton({
    required IconData icon,
    required VoidCallback onPressed,
    required Color secondaryTextColor,
  }) =>
      Listener(
        onPointerDown: (_) => _preserveCurrentSelection(),
        child: IconButton(
          icon: Icon(
            icon,
            size: 20,
            color: secondaryTextColor,
          ),
          onPressed: () {
            onPressed();
            _keepEditorFocused();
          },
          padding: const EdgeInsets.all(8),
          constraints: const BoxConstraints(),
          visualDensity: VisualDensity.compact,
        ),
      );

  Widget _buildToolbarIconButton({
    required Widget icon,
    required VoidCallback onPressed,
    required Color iconColor,
    Color? activeColor,
    bool isActive = false,
  }) {
    final effectiveActiveColor = activeColor ?? iconColor;
    return Container(
      width: 36,
      height: 36,
      margin: const EdgeInsets.symmetric(horizontal: 1),
      decoration: BoxDecoration(
        color: isActive ? effectiveActiveColor.withValues(alpha: 0.12) : null,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Listener(
        onPointerDown: (_) => _preserveCurrentSelection(),
        child: IconButton(
          icon: IconTheme(
            data: IconThemeData(
              color: isActive ? effectiveActiveColor : iconColor,
              size: 20,
            ),
            child: DefaultTextStyle.merge(
              style: TextStyle(
                color: isActive ? effectiveActiveColor : iconColor,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
              child: icon,
            ),
          ),
          onPressed: () {
            onPressed();
            _keepEditorFocused();
          },
          padding: const EdgeInsets.all(8),
          constraints: const BoxConstraints(),
          visualDensity: VisualDensity.compact,
        ),
      ),
    );
  }

  // 🎯 简化音波动画 - 大厂风格（Siri/微信）
  Widget _buildSoundWaveAnimation(Color color) => Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(
          3, // 简化为3个条（更优雅）
          (index) => AnimatedBuilder(
            animation: _speechAnimationController,
            builder: (context, child) {
              // 🎯 简化波形计算：每个条延迟不同相位
              final phase = index * 0.33;
              final value = math.sin(
                (_speechAnimationController.value * 2 * math.pi) +
                    (phase * 2 * math.pi),
              );

              // 🎯 基础高度 + 动画幅度（8-20像素，更温和）
              const baseHeight = 12.0;
              final animatedHeight = baseHeight + (value.abs() * 8);

              return Container(
                width: 3,
                height: animatedHeight,
                margin: const EdgeInsets.symmetric(horizontal: 2),
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(1.5),
                ),
              );
            },
          ),
        ),
      );

  // 构建语音识别按钮
  Widget _buildSpeechButton(Color iconColor, Color secondaryTextColor) =>
      GestureDetector(
        onTap: _toggleSpeechRecognition,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: _isSpeechListening
                ? iconColor.withValues(alpha: 0.15)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(18),
            border: _isSpeechListening
                ? Border.all(
                    color: iconColor.withValues(alpha: 0.3),
                    width: 1.5,
                  )
                : null,
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              // 录音动画波纹效果
              if (_isSpeechListening)
                AnimatedBuilder(
                  animation: _speechAnimationController,
                  builder: (context, child) {
                    final value = _speechAnimationController.value;
                    return Container(
                      width: 36 + (value * 12),
                      height: 36 + (value * 12),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: iconColor.withValues(alpha: 0.3 * (1 - value)),
                          width: 2,
                        ),
                      ),
                    );
                  },
                ),

              // 麦克风图标
              Icon(
                _isSpeechListening ? Icons.mic : Icons.mic_none,
                size: 20,
                color: _isSpeechListening ? iconColor : secondaryTextColor,
              ),
            ],
          ),
        ),
      );

  // ================ ✨ AI 功能方法 ================

  /// AI 续写
  Future<void> _aiContinueWriting() async {
    final content = _textController.text.trim();

    if (content.isEmpty) {
      SnackBarUtils.showError(
        context,
        AppLocalizationsSimple.of(context)?.aiContentRequired ??
            'Please enter some content first',
      );
      return;
    }

    if (_isAIProcessing) {
      return;
    }

    setState(() => _isAIProcessing = true);

    // 显示持久加载提示（使用主题色）
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                AppLocalizationsSimple.of(context)
                        ?.aiContinueWritingProcessing ??
                    '✨ AI is continuing...',
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
            ),
          ],
        ),
        duration: const Duration(minutes: 2),
        backgroundColor:
            isDarkMode ? AppTheme.primaryLightColor : AppTheme.primaryColor,
        behavior: SnackBarBehavior.floating,
      ),
    );

    try {
      final appProvider = Provider.of<AppProvider>(context, listen: false);
      final appConfig = appProvider.appConfig;
      final apiKey = appConfig.aiApiKey;
      final apiUrl = appConfig.aiApiUrl;
      final model = appConfig.aiModel;

      if (apiKey == null || apiUrl == null) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        SnackBarUtils.showError(
          context,
          AppLocalizationsSimple.of(context)?.aiConfigRequired ??
              'Please configure AI in settings first',
        );
        setState(() => _isAIProcessing = false);
        return;
      }

      // 🚀 使用革命性引擎（上下文增强 + 质量保证）
      final (continuation, error) = await _aiService.continueWriting(
        content: content,
        apiKey: apiKey,
        apiUrl: apiUrl,
        model: model,
        allNotes: appProvider.notes, // 🔥 传入所有笔记作为上下文
        customPrompt: appConfig.useCustomPrompt
            ? appConfig.customContinuationPrompt
            : null, // 🔥 传递自定义续写提示词
      );

      ScaffoldMessenger.of(context).hideCurrentSnackBar();

      if (error != null) {
        SnackBarUtils.showError(context, error);
        setState(() => _isAIProcessing = false);
        return;
      }

      if (continuation != null) {
        // 在光标位置插入续写内容
        final cursorPos = _textController.selection.baseOffset;
        final newText =
            '${content.substring(0, cursorPos)}\n\n$continuation${content.substring(cursorPos)}';

        _textController.text = newText;
        _textController.selection = TextSelection.collapsed(
          offset: cursorPos + continuation.length + 2,
        );

        SnackBarUtils.showSuccess(
          context,
          AppLocalizationsSimple.of(context)?.aiContinueWritingSuccess ??
              '✅ AI continue completed!',
        );
      }
    } on Object catch (e) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      SnackBarUtils.showError(context, 'AI 续写失败: $e');
    } finally {
      setState(() => _isAIProcessing = false);
    }
  }

  /// AI 生成标签
  Future<void> _aiGenerateTags() async {
    final content = _textController.text.trim();

    if (content.isEmpty) {
      SnackBarUtils.showError(
        context,
        AppLocalizationsSimple.of(context)?.aiContentRequired ??
            'Please enter some content first',
      );
      return;
    }

    if (_isAIProcessing) {
      return;
    }

    setState(() => _isAIProcessing = true);

    // 显示持久加载提示（使用主题色）
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                AppLocalizationsSimple.of(context)?.aiTagsProcessing ??
                    '🏷️ AI is generating tags...',
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
            ),
          ],
        ),
        duration: const Duration(minutes: 2),
        backgroundColor:
            isDarkMode ? AppTheme.primaryLightColor : AppTheme.primaryColor,
        behavior: SnackBarBehavior.floating,
      ),
    );

    try {
      final appProvider = Provider.of<AppProvider>(context, listen: false);
      final apiKey = appProvider.appConfig.aiApiKey;
      final apiUrl = appProvider.appConfig.aiApiUrl;
      final model = appProvider.appConfig.aiModel;

      if (apiKey == null || apiUrl == null) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        SnackBarUtils.showError(
          context,
          AppLocalizationsSimple.of(context)?.aiConfigRequired ??
              'Please configure AI in settings first',
        );
        setState(() => _isAIProcessing = false);
        return;
      }

      final (tags, error) = await _aiService.generateTags(
        content: content,
        apiKey: apiKey,
        apiUrl: apiUrl,
        model: model,
        allNotes: appProvider.notes,
      );

      ScaffoldMessenger.of(context).hideCurrentSnackBar();

      if (error != null) {
        SnackBarUtils.showError(context, error);
        setState(() => _isAIProcessing = false);
        return;
      }

      if (tags != null && tags.isNotEmpty) {
        // 在内容末尾添加标签
        final tagsText = tags.map((t) => '#$t').join(' ');
        final newText = '$content\n\n$tagsText';

        _textController.text = newText;
        _textController.selection =
            TextSelection.collapsed(offset: newText.length);

        SnackBarUtils.showSuccess(
          context,
          AppLocalizationsSimple.of(context)?.aiTagsSuccess(tags.length) ??
              '✅ Generated ${tags.length} tags!',
        );
      }
    } on Object catch (e) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      SnackBarUtils.showError(context, 'AI 标签生成失败: $e');
    } finally {
      setState(() => _isAIProcessing = false);
    }
  }
}

/// 九宫格拖动排序时，第 [index] 格应该朝哪个方向挪几格。
///
/// 把网格按行优先展平成一维序列：被拖动的格子从 [from] 移到 [to] 时，中间被
/// 越过的格子依次顶上（或退后）一格。返回值以「格」为单位，[Offset.dx] 是列、
/// [Offset.dy] 是行，*不* 需要挪动时返回 null。
///
/// 抽成纯函数是为了能直接测跨行这类边界：第二行第一列被推挤时要斜着走
/// （dx = 1, dy = -1），单看一维下标很容易算错。
@visibleForTesting
Offset? gridSwapSteps({
  required int index,
  required int from,
  required int to,
  required int columns,
}) {
  if (columns <= 0 || from == to || index == from) {
    return null;
  }
  final int target;
  if (from < to) {
    // 往后拖：区间 (from, to] 的格子各退一格
    if (index <= from || index > to) {
      return null;
    }
    target = index - 1;
  } else {
    // 往前拖：区间 [to, from) 的格子各进一格
    if (index >= from || index < to) {
      return null;
    }
    target = index + 1;
  }
  final colDelta = (target % columns) - (index % columns);
  final rowDelta = (target ~/ columns) - (index ~/ columns);
  if (colDelta == 0 && rowDelta == 0) {
    return null;
  }
  return Offset(colDelta.toDouble(), rowDelta.toDouble());
}

// 上传状态枚举
enum UploadStatus {
  none, // 无状态（本地图片）
  uploading, // 上传中
  success, // 上传成功
  failed, // 上传失败
}

// 图片项类
class _ImageItem {
  _ImageItem({
    required this.path,
    required this.alt,
    this.uploadStatus = UploadStatus.none,
  });
  final String path;
  final String alt;
  final UploadStatus uploadStatus;

  // 复制方法，用于更新状态
  _ImageItem copyWith({
    String? path,
    String? alt,
    UploadStatus? uploadStatus,
  }) =>
      _ImageItem(
        path: path ?? this.path,
        alt: alt ?? this.alt,
        uploadStatus: uploadStatus ?? this.uploadStatus,
      );
}
