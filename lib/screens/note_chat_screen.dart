import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:inkpaper/l10n/app_localizations_simple.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/providers/app_provider.dart';
import 'package:inkpaper/services/notes_context_builder.dart';
import 'package:inkpaper/services/notes_qa_service.dart';
import 'package:inkpaper/themes/app_theme.dart';
import 'package:inkpaper/utils/snackbar_utils.dart';
import 'package:inkpaper/widgets/deepseek_whale.dart';
import 'package:inkpaper/widgets/sidebar.dart';
import 'package:provider/provider.dart';

/// 「问笔记」：以全库笔记为资料跟 AI 对话。
class NoteChatScreen extends StatefulWidget {
  const NoteChatScreen({super.key});

  @override
  State<NoteChatScreen> createState() => _NoteChatScreenState();
}

class _NoteChatScreenState extends State<NoteChatScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final NotesQaService _service = NotesQaService();
  final FocusNode _inputFocusNode = FocusNode();

  final List<_ChatMessage> _messages = <_ChatMessage>[];
  final List<QaTurn> _history = <QaTurn>[];

  bool _isSending = false;
  NotesContext? _lastContext;

  /// DeepSeek 品牌蓝，AI 气泡底色
  static const Color _whaleBlue = DeepSeekWhale.brandBlue;

  /// 全量笔记快照：第一次提问时读一次，之后复用，避免每次发送都查一遍数据库
  List<Note>? _allNotesSnapshot;
  int _totalNoteCount = 0;

  static const List<String> _suggestions = <String>[
    '我这周主要在关注什么？',
    '关于运动，我的记录里有哪些进展？',
    '我最早关于运动的笔记是什么时候？',
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _preloadNotes();
    });
  }

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    _inputFocusNode.dispose();
    super.dispose();
  }

  /// 预取全量笔记：首页列表是分页的，直接用 provider.notes 只能拿到几十条
  Future<void> _preloadNotes() async {
    final provider = Provider.of<AppProvider>(context, listen: false);
    final notes = await provider.loadAllNotesSnapshot();
    if (!mounted) {
      return;
    }
    setState(() {
      _allNotesSnapshot = notes;
      _totalNoteCount = notes.length;
    });
  }

  void _openDrawer() => _scaffoldKey.currentState?.openDrawer();

  String _contextLabel(NotesContext context) {
    final base = context.truncated
        ? '已读入 ${context.noteCount} / ${context.totalCandidates} 条'
        : '已读入 ${context.noteCount} 条笔记';
    if (!context.hasRetrieval) {
      return base;
    }
    return '$base · 相关 ${context.relevantCount} 条';
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) {
        return;
      }
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _send([String? preset]) async {
    final question = (preset ?? _inputController.text).trim();
    if (question.isEmpty || _isSending) {
      return;
    }

    final provider = Provider.of<AppProvider>(context, listen: false);
    setState(() {
      _isSending = true;
      _messages.add(_ChatMessage.user(question));
      _messages.add(_ChatMessage.pending());
      _inputController.clear();
    });
    _scrollToBottom();

    final notes = _allNotesSnapshot ?? await provider.loadAllNotesSnapshot();
    _allNotesSnapshot = notes;

    final result = await _service.ask(
      config: provider.appConfig,
      notes: notes,
      history: List<QaTurn>.from(_history),
      question: question,
    );

    if (!mounted) {
      return;
    }
    setState(() {
      _messages.removeLast(); // 去掉 pending
      _lastContext = result.context;
      if (result.isError) {
        _messages.add(_ChatMessage.error(result.error!));
      } else {
        _messages.add(_ChatMessage.ai(result.answer));
        _history.add(QaTurn(question: question, answer: result.answer));
      }
      _isSending = false;
    });
    _scrollToBottom();
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) {
      return;
    }
    SnackBarUtils.showSuccess(
      context,
      AppLocalizationsSimple.of(context)?.reviewCopiedShort ?? '已复制',
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final backgroundColor =
        isDarkMode ? AppTheme.darkBackgroundColor : AppTheme.backgroundColor;
    final textColor =
        isDarkMode ? AppTheme.darkTextPrimaryColor : Colors.black87;
    final iconColor =
        isDarkMode ? AppTheme.primaryLightColor : AppTheme.primaryColor;
    final isDesktop = !kIsWeb && (Platform.isMacOS || Platform.isWindows);

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: backgroundColor,
      resizeToAvoidBottomInset: true,
      drawer: isDesktop ? null : const Sidebar(),
      drawerEdgeDragWidth:
          isDesktop ? null : MediaQuery.of(context).size.width * 0.2,
      appBar: AppBar(
        backgroundColor: backgroundColor,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        automaticallyImplyLeading: false,
        leading: isDesktop
            ? null
            : IconButton(
                tooltip: '菜单',
                icon: Icon(Icons.menu_rounded, color: iconColor),
                onPressed: _openDrawer,
              ),
        centerTitle: true,
        title: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              AppLocalizationsSimple.of(context)?.askNotes ?? '问笔记',
              style: TextStyle(
                color: textColor,
                fontWeight: FontWeight.w600,
                fontSize: 18,
              ),
            ),
            if (_lastContext != null)
              Text(
                // 有截断时把"装了多少 / 总共多少"说清楚，别让人以为全读了；
                // 检索命中时再补一句"其中多少条和这次问题相关"
                _contextLabel(_lastContext!),
                style: TextStyle(
                  fontSize: 11,
                  color: isDarkMode ? Colors.grey[500] : Colors.grey[600],
                ),
              ),
          ],
        ),
        actions: [
          if (_messages.isNotEmpty)
            IconButton(
              tooltip: '清空对话',
              icon: Icon(
                Icons.delete_outline_rounded,
                color: iconColor,
                size: 22,
              ),
              onPressed: _isSending
                  ? null
                  : () {
                      setState(() {
                        _messages.clear();
                        _history.clear();
                        _lastContext = null;
                      });
                    },
            ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty
                ? _buildEmptyState(isDarkMode)
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) => _buildBubble(
                      _messages[index],
                      isDarkMode,
                    ),
                  ),
          ),
          _buildInputBar(isDarkMode),
        ],
      ),
    );
  }

  Widget _buildEmptyState(bool isDarkMode) {
    final textColor =
        isDarkMode ? AppTheme.darkTextPrimaryColor : Colors.black87;
    final secondaryColor = isDarkMode ? Colors.grey[400] : Colors.grey[600];
    final accent =
        isDarkMode ? AppTheme.primaryLightColor : AppTheme.primaryColor;
    final noteCountText =
        _totalNoteCount > 0 ? '本机 $_totalNoteCount 条' : '本机全部';

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 40, 20, 20),
      children: [
        Icon(Icons.forum_outlined, size: 56, color: accent),
        const SizedBox(height: 18),
        Text(
          '就你的笔记问点什么',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: textColor,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '会把$noteCountText笔记（不含图片）作为资料交给 AI，'
          '回答只依据这些内容。',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: secondaryColor, height: 1.5),
        ),
        const SizedBox(height: 24),
        Text(
          '试试这些',
          style: TextStyle(fontSize: 12, color: secondaryColor),
        ),
        const SizedBox(height: 10),
        for (final suggestion in _suggestions)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: GestureDetector(
              onTap: () => _send(suggestion),
              behavior: HitTestBehavior.opaque,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: isDarkMode ? AppTheme.darkCardColor : Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isDarkMode
                        ? Colors.white.withValues(alpha: 0.06)
                        : Colors.black.withValues(alpha: 0.05),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        suggestion,
                        style: TextStyle(fontSize: 14, color: textColor),
                      ),
                    ),
                    Icon(Icons.north_east_rounded, size: 16, color: accent),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildBubble(_ChatMessage message, bool isDarkMode) {
    final accent =
        isDarkMode ? AppTheme.primaryLightColor : AppTheme.primaryColor;
    final cardColor = isDarkMode ? AppTheme.darkCardColor : Colors.white;

    if (message.isUser) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.only(bottom: 14, left: 48),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: accent,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(14),
              topRight: Radius.circular(14),
              bottomLeft: Radius.circular(14),
              bottomRight: Radius.circular(4),
            ),
          ),
          child: Text(
            message.text,
            style: const TextStyle(
              fontSize: 14,
              height: 1.5,
              color: Colors.white,
            ),
          ),
        ),
      );
    }

    if (message.isPending) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildWhaleAvatar(),
          const SizedBox(width: 8),
          Flexible(
            child: Container(
              margin: const EdgeInsets.only(bottom: 14, right: 32),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: const BoxDecoration(
                color: _whaleBlue,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(6),
                  topRight: Radius.circular(16),
                  bottomLeft: Radius.circular(16),
                  bottomRight: Radius.circular(16),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.8,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '正在翻你的笔记…',
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.white.withValues(alpha: 0.85),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    final isError = message.isError;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildWhaleAvatar(dimmed: isError),
        const SizedBox(width: 8),
        Flexible(
          child: Container(
            margin: const EdgeInsets.only(bottom: 14, right: 32),
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
            decoration: BoxDecoration(
              // 正常回答用 DeepSeek 的深蓝，错误仍留在浅色卡片里保证可读
              color: isError ? cardColor : _whaleBlue,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(6),
                topRight: Radius.circular(16),
                bottomLeft: Radius.circular(16),
                bottomRight: Radius.circular(16),
              ),
              border: isError
                  ? Border.all(color: Colors.orange.withValues(alpha: 0.4))
                  : null,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  message.text,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.65,
                    color: isError ? Colors.orange[800] : Colors.white,
                  ),
                ),
                if (!isError)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        minimumSize: const Size(0, 32),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: () => _copy(message.text),
                      icon: Icon(
                        Icons.copy_rounded,
                        size: 14,
                        color: Colors.white.withValues(alpha: 0.75),
                      ),
                      label: Text(
                        '复制',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.white.withValues(alpha: 0.75),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// AI 侧的头像：透明底的蓝色胖鲸鱼
  Widget _buildWhaleAvatar({bool dimmed = false}) {
    return SizedBox(
      width: 34,
      height: 34,
      child: Center(
        child: DeepSeekWhale(
          size: 26,
          color: dimmed ? Colors.grey[400]! : DeepSeekWhale.brandBlue,
        ),
      ),
    );
  }

  Widget _buildInputBar(bool isDarkMode) {
    final cardColor = isDarkMode ? AppTheme.darkCardColor : Colors.white;
    final textColor =
        isDarkMode ? AppTheme.darkTextPrimaryColor : Colors.black87;
    final accent =
        isDarkMode ? AppTheme.primaryLightColor : AppTheme.primaryColor;

    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: BoxDecoration(
          color: isDarkMode ? AppTheme.darkBackgroundColor : AppTheme.backgroundColor,
          border: Border(
            top: BorderSide(
              color: isDarkMode
                  ? Colors.white.withValues(alpha: 0.06)
                  : Colors.black.withValues(alpha: 0.05),
            ),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Container(
                constraints: const BoxConstraints(maxHeight: 120),
                decoration: BoxDecoration(
                  color: cardColor,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: isDarkMode
                        ? Colors.white.withValues(alpha: 0.08)
                        : Colors.black.withValues(alpha: 0.06),
                  ),
                ),
                child: TextField(
                  controller: _inputController,
                  focusNode: _inputFocusNode,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  style: TextStyle(fontSize: 14, color: textColor),
                  decoration: InputDecoration(
                    hintText:
                        AppLocalizationsSimple.of(context)?.askNotesHint ??
                            '问问你的笔记…',
                    hintStyle: TextStyle(
                      fontSize: 14,
                      color: isDarkMode ? Colors.grey[500] : Colors.grey[500],
                    ),
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: _isSending ? null : _send,
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: _isSending ? accent.withValues(alpha: 0.4) : accent,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  _isSending ? Icons.hourglass_top_rounded : Icons.arrow_upward_rounded,
                  color: Colors.white,
                  size: 20,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChatMessage {
  _ChatMessage._({
    required this.text,
    required this.isUser,
    required this.isPending,
    required this.isError,
  });

  factory _ChatMessage.user(String text) => _ChatMessage._(
        text: text,
        isUser: true,
        isPending: false,
        isError: false,
      );

  factory _ChatMessage.ai(String text) => _ChatMessage._(
        text: text,
        isUser: false,
        isPending: false,
        isError: false,
      );

  factory _ChatMessage.error(String text) => _ChatMessage._(
        text: text,
        isUser: false,
        isPending: false,
        isError: true,
      );

  factory _ChatMessage.pending() => _ChatMessage._(
        text: '',
        isUser: false,
        isPending: true,
        isError: false,
      );

  final String text;
  final bool isUser;
  final bool isPending;
  final bool isError;
}
