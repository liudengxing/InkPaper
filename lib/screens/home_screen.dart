import 'dart:async'; // 🚀 用于搜索防抖
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:go_router/go_router.dart';
import 'package:inkpaper/config/app_config.dart';
import 'package:inkpaper/l10n/app_localizations_simple.dart';
import 'package:inkpaper/models/note_media_filter.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/models/sort_order.dart';
import 'package:inkpaper/providers/app_provider.dart';
import 'package:inkpaper/services/preferences_service.dart';
import 'package:inkpaper/themes/app_theme.dart';
import 'package:inkpaper/utils/responsive_utils.dart';
import 'package:inkpaper/utils/snackbar_utils.dart';
import 'package:inkpaper/widgets/note_actions_ui.dart';
import 'package:inkpaper/widgets/note_card.dart';
import 'package:inkpaper/widgets/note_editor.dart';
import 'package:inkpaper/widgets/note_editor_page.dart';
import 'package:inkpaper/widgets/on_this_day_card.dart';
import 'package:inkpaper/widgets/sidebar.dart';
import 'package:inkpaper/widgets/slide_out_row.dart';
import 'package:liquid_glass_renderer/liquid_glass_renderer.dart';
import 'package:provider/provider.dart';

const bool _screenshotMode = bool.fromEnvironment('INKPAPER_SCREENSHOT_MODE');

/// 主页 feed 需要订阅的最小状态集。
///
/// 记录类型有结构相等：`notes` 未被清缓存时是同一个 List 实例，配合
/// `AppProvider.notifyUiStateChanged()`，同步进度、登录态这类高频变化
/// 不会再把整个列表重建一遍。
typedef _FeedSnapshot = ({
  List<Note> notes,
  bool hasMoreData,
  bool isLoadingMore,
  int loadedCount,
  int totalCount,
  String loadMoreStage,
  bool isInitialized,
  String mediaFilter,
  bool isMediaFilterLoading,
});

/// 标题下拉的一次选择：排序或媒体筛选，二选一。
///
/// 菜单原本直接 `showMenu<SortOrder>`，加筛选后再开一个菜单就会出现两个
/// 入口。合成一个选择对象后仍是同一张卡片，只是多了一组「筛选」。
class _FeedMenuChoice {
  const _FeedMenuChoice.sort(this.sortOrder) : filter = null;
  const _FeedMenuChoice.filter(this.filter) : sortOrder = null;

  final SortOrder? sortOrder;
  final NoteMediaFilter? filter;
}

class HomeScreen extends StatefulWidget {
  // 🔥 接收分享的内容

  const HomeScreen({
    super.key,
    this.sharedContent,
    this.openQuickNote = false,
    this.quickNoteTag,
    this.quickNoteActionToken,
    this.quickNoteVoice = false,
  });
  final String? sharedContent;
  final bool openQuickNote;
  final String? quickNoteTag;
  final String? quickNoteActionToken;

  /// 桌面组件「快速记录 · 语音」拉起来的：直接进编辑态并开始录音。
  final bool quickNoteVoice;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  // 🏢 大厂方案：会话标记 - 标记本次应用会话是否已自动弹出编辑框
  // 参考微信、Notion等应用，只在应用冷启动时弹出一次，而不是每次进入页面
  static bool _hasShownEditorInThisSession = false;

  // 🔧 恢复 _scaffoldKey 以修复侧边栏按钮
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  // 排序浮层的定位锚点（首页标题）
  final GlobalKey _titleAnchorKey = GlobalKey();
  bool _isSearchActive = false;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  List<Note> _searchResults = [];
  Timer? _searchDebounceTimer;
  int _searchRequestSeq = 0;
  bool _isSearchLoading = false;
  bool _isRefreshing = false;

  /// 搜索态三处位移（抽屉收起、标题↔搜索框、右侧图标↔取消）共用同一组
  /// 时长与曲线，整体才像一次动作；分开配曲线会各走各的，看着发飘。
  static const Duration _searchTransition = Duration(milliseconds: 220);

  /// 抽屉按钮的固有尺寸。AnimatedContainer 只做横向收放，高度必须给死——
  /// AppBar 的 title 槽位高约束是无限的，宽度动画带上无限高度会让里面的
  /// OverflowBox 撑到 Infinity。
  static const double _drawerButtonExtent = 48;

  /// 信息流「换源」时的一点淡起。
  ///
  /// 这里不能把 ListView 塞进 AnimatedSwitcher：切换期间新旧两个 ListView
  /// 会同时挂到同一个 _scrollController 上，直接触发 assert。所以只在外面
  /// 挂一层 FadeTransition，靠重播 value 表达「这一块内容换过了」。
  late final AnimationController _feedFadeController;
  late final Animation<double> _feedFade;
  SortOrder _currentSortOrder = SortOrder.newest;

  /// 正在播放「从右往左退出」的行。
  ///
  /// 删除确认后先把 id 放进来，卡片自己滑出去、收起高度；动效播完才真正
  /// 从 provider 里摘掉这一条，否则整列会在点确认的那一帧往上硬跳一格。
  final Set<String> _leavingNoteIds = <String>{};
  final Map<String, Completer<void>> _noteExitCompleters =
      <String, Completer<void>>{};

  /// 📝 欢迎笔记文案。
  ///
  /// 只在「本地一条笔记都没有」时作为列表唯一的一条展示，
  /// 不写入数据库：用户创建第一条真实笔记后它自然消失，
  /// 也不会被同步到 Memos / WebDAV，避免污染真实数据。
  static const String _welcomeNoteContent = '小纸是一款面向个人知识记录的 Android 笔记应用。'
      '它可以本地优先使用，也可以连接自托管 Memos 服务进行同步。'
      '应用提供 Memos 兼容 Markdown、图片、标签、提醒、搜索、WebDAV 备份、'
      '导入导出、系统分享、小组件和可选 AI 辅助等能力。'
      '（本条笔记在您正式使用后会自动删除）';

  /// 欢迎笔记的首次构建时刻（文案随语言变化，时间保持不变）
  late final DateTime _welcomeNoteTime;

  /// 欢迎笔记的展示用对象（id 不会落库），文案随系统语言变化。
  Note get _welcomeNote {
    final content = AppLocalizationsSimple.of(context)?.welcomeNoteContent ??
        _welcomeNoteContent;
    return Note(
      id: 'welcome_note_guide',
      content: content,
      createdAt: _welcomeNoteTime,
      updatedAt: _welcomeNoteTime,
      isSynced: true,
    );
  }

  // 🚀 分页加载相关
  final ScrollController _scrollController = ScrollController();
  bool _isLoadingMore = false;
  bool _hasHandledWidgetQuickAction = false;

  // 🕰️ 那年今日：往年同月同日的笔记（去年在最前），首页顶部展示
  List<Note> _onThisDayNotes = const <Note>[];
  bool _onThisDayDismissed = false;

  // ListView.builder 本身是懒构建，不需要再手写「分帧递增可见数量」。

  @override
  void initState() {
    super.initState();

    // 📝 欢迎笔记：时间取首次构建时刻，列表为空时展示
    _welcomeNoteTime = DateTime.now();

    // 静置态是不透明的，只在换源时重播一次
    _feedFadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    )..value = 1;
    _feedFade = Tween<double>(begin: 0.35, end: 1).animate(
      CurvedAnimation(parent: _feedFadeController, curve: Curves.easeOut),
    );

    // 🕰️ 那年今日：首帧之后异步查库，避免阻塞启动
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadOnThisDay();
    });

    // 🚀 大厂做法：先渲染 UI，再异步初始化（不阻塞 UI）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeApp(); // 异步执行，不阻塞首帧
    });
    // 🚀 添加滚动监听，实现分页加载
    _scrollController.addListener(_onScroll);

    // 在页面加载完成后异步刷新通知
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 🚀 最优延迟策略：与后台云验证协调（启动后8-10秒）
      // 此时后台已开始云验证，直接使用缓存数据
      Future.delayed(const Duration(seconds: 10), () {
        if (mounted) {
          _refreshNotifications();
        }
      });

      // 🔥 如果有分享的内容，打开编辑器（延迟确保页面完全加载）
      if (widget.sharedContent != null && widget.sharedContent!.isNotEmpty) {
        Future.delayed(const Duration(milliseconds: 300), () {
          if (mounted) {
            _showAddNoteFormWithContent(widget.sharedContent!);
          }
        });
      } else if (widget.openQuickNote) {
        _hasHandledWidgetQuickAction = true;
        _hasShownEditorInThisSession = true;
        Future.delayed(const Duration(milliseconds: 220), () {
          if (mounted) {
            _showAddNoteFormWithContent(
              _quickNoteInitialContent(),
              startWithSpeech: widget.quickNoteVoice,
            );
          }
        });
      } else {
        // 🔥 大厂标准：等待 AppProvider 初始化完成后再检查自动弹出设置
        // 解决部分用户配置未生效的问题
        _checkAndShowEditorOnLaunch();
      }
    });
  }

  @override
  void didUpdateWidget(covariant HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    _handleSharedContentUpdate(oldWidget);

    if (!widget.openQuickNote) {
      _hasHandledWidgetQuickAction = false;
      return;
    }
    if (_hasHandledWidgetQuickAction &&
        oldWidget.quickNoteTag == widget.quickNoteTag &&
        oldWidget.quickNoteActionToken == widget.quickNoteActionToken) {
      return;
    }
    _hasHandledWidgetQuickAction = true;
    _hasShownEditorInThisSession = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _showAddNoteFormWithContent(
          _quickNoteInitialContent(),
          startWithSpeech: widget.quickNoteVoice,
        );
      }
    });
  }

  /// App 已经在前台时又收到分享：路由 go('/') 只是替换 page 的 child，
  /// HomeScreen 不会重新 initState，光靠 initState 那段永远等不到第二次分享。
  void _handleSharedContentUpdate(HomeScreen oldWidget) {
    final incoming = widget.sharedContent;
    if (incoming == null || incoming.trim().isEmpty) {
      return;
    }
    if (oldWidget.sharedContent == incoming) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _showAddNoteFormWithContent(incoming);
      }
    });
  }

  String _quickNoteInitialContent() {
    final tag = widget.quickNoteTag?.trim();
    if (tag == null || tag.isEmpty) {
      return '';
    }
    return '#${tag.replaceAll(RegExp('^#+'), '')} ';
  }

  // 🎯 退出搜索状态
  void _exitSearch() {
    if (!_isSearchActive) {
      return;
    }

    setState(() {
      _isSearchActive = false;
      _searchController.clear();
      _searchResults.clear();
    });
    FocusScope.of(context).unfocus(); // 收起键盘
    _replayFeedFade();
  }

  void _enterSearch() {
    if (_isSearchActive) {
      _searchFocusNode.requestFocus();
      return;
    }

    setState(() {
      _isSearchActive = true;
    });
    _replayFeedFade();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _searchFocusNode.requestFocus();
      }
    });
  }

  void _clearSearchQuery() {
    _searchController.clear();
    _searchDebounceTimer?.cancel();
    _searchRequestSeq++;
    final hadResults = _searchResults.isNotEmpty;
    setState(() {
      _searchResults.clear();
      _isSearchLoading = false;
    });
    _searchFocusNode.requestFocus();
    // 清空输入会把列表从「结果」切回全部笔记，整块内容换了才淡一下
    if (hadResults) {
      _replayFeedFade();
    }
  }

  void _dismissSearchKeyboard() {
    if (_isSearchActive) {
      _searchFocusNode.unfocus();
    }
  }

  /// 换源那一帧把信息流从半透明拉到不透明，替代没法做的整块交叉淡入。
  void _replayFeedFade() {
    if (!mounted) {
      return;
    }
    _feedFadeController.forward(from: 0);
  }

  void _handleSearchChanged(String query) {
    final normalizedQuery = query.trim();
    _searchDebounceTimer?.cancel();
    final requestSeq = ++_searchRequestSeq;

    if (normalizedQuery.isEmpty) {
      final hadResults = _searchResults.isNotEmpty;
      setState(() {
        _searchResults.clear();
        _isSearchLoading = false;
      });
      if (hadResults) {
        _replayFeedFade();
      }
      return;
    }

    setState(() {
      _isSearchLoading = true;
    });

    _searchDebounceTimer = Timer(const Duration(milliseconds: 240), () async {
      try {
        final appProvider = Provider.of<AppProvider>(context, listen: false);
        final results = await appProvider.searchNotes(normalizedQuery);
        if (!mounted || requestSeq != _searchRequestSeq) {
          return;
        }
        final hadResults = _searchResults.isNotEmpty;
        setState(() {
          _searchResults = results;
          _isSearchLoading = false;
        });
        // 只在「有结果 ↔ 无结果」那一下淡起：逐字输入时结果集是连续的，
        // 每条都播一次会闪。
        if (hadResults != results.isNotEmpty) {
          _replayFeedFade();
        }
      } on Object catch (e) {
        if (kDebugMode) {
          debugPrint('HomeScreen: 搜索失败: $e');
        }
        if (!mounted || requestSeq != _searchRequestSeq) {
          return;
        }
        setState(() {
          _searchResults.clear();
          _isSearchLoading = false;
        });
      }
    });
  }

  // 🚀 滚动监听 - 检测底部并加载更多
  void _onScroll() {
    if (!_scrollController.hasClients || _isSearchActive) {
      return;
    }

    final position = _scrollController.position;
    final isActuallyScrollable = position.maxScrollExtent > 0;
    final isUserScrollingDown =
        position.userScrollDirection == ScrollDirection.reverse;
    final nearBottom = position.extentAfter < 300;
    if (isActuallyScrollable && isUserScrollingDown && nearBottom) {
      _loadMoreNotes();
    }
  }

  // 🚀 加载更多笔记
  Future<void> _loadMoreNotes() async {
    if (_isLoadingMore) {
      return;
    }

    final appProvider = Provider.of<AppProvider>(context, listen: false);
    if (!appProvider.hasMoreData) {
      return;
    }

    setState(() {
      _isLoadingMore = true;
    });

    try {
      await appProvider.loadMoreNotes();
    } on Object catch (e) {
      if (kDebugMode) {
        debugPrint('HomeScreen: 加载更多失败: $e');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingMore = false;
        });
      }
    }
  }

  // 刷新通知数据
  Future<void> _refreshNotifications() async {
    if (!mounted) {
      return;
    }

    final appProvider = Provider.of<AppProvider>(context, listen: false);
    // 异步刷新通知数量，不阻塞UI
    unawaited(appProvider.refreshUnreadAnnouncementsCount());
  }

  // 🏢 大厂方案：等待配置加载完成后检查并自动弹出编辑框
  // 参考微信、Notion等应用，只在应用冷启动时弹出一次
  Future<void> _checkAndShowEditorOnLaunch() async {
    if (!mounted) {
      return;
    }

    // 🎯 核心优化：检查本次会话是否已弹出过
    // 避免每次页面切换都弹出（如从设置页返回主页）
    if (_hasShownEditorInThisSession) {
      if (kDebugMode) {
        debugPrint('HomeScreen: 本次会话已弹出过编辑框，跳过自动弹出');
      }
      return;
    }

    if (widget.openQuickNote) {
      return;
    }

    final appProvider = Provider.of<AppProvider>(context, listen: false);

    // 🎯 等待 AppProvider 初始化完成
    // 最多等待5秒，避免无限等待
    var attempts = 0;
    while (!appProvider.isInitialized && attempts < 50 && mounted) {
      await Future.delayed(const Duration(milliseconds: 100));
      attempts++;
    }

    // 检查配置是否启用了自动弹出
    if (mounted && appProvider.appConfig.autoShowEditorOnLaunch) {
      // 再延迟一小段时间，确保UI完全准备好
      await Future.delayed(const Duration(milliseconds: 300));

      if (mounted) {
        // 🏢 标记本次会话已弹出，避免重复弹出
        _hasShownEditorInThisSession = true;

        if (kDebugMode) {
          debugPrint('HomeScreen: 应用启动时自动弹出编辑框');
        }

        _showAddNoteForm();
      }
    }
  }

  @override
  void dispose() {
    _searchDebounceTimer?.cancel();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _scrollController.dispose(); // 🚀 释放滚动控制器
    _feedFadeController.dispose();
    super.dispose();
  }

  Future<void> _initializeApp() async {
    if (!mounted) {
      return;
    }

    final appProvider = Provider.of<AppProvider>(context, listen: false);
    final preferencesService = PreferencesService();

    // 🎯 检查是否首次启动（路由已处理，这里做二次防御）
    final isFirstLaunch =
        !_screenshotMode && await preferencesService.isFirstLaunch();
    if (isFirstLaunch) {
      // 🔒 首次启动时清理所有旧数据（防止卸载后重装时残留 Keychain 数据）
      await preferencesService.clearAllSecureData();

      if (mounted) {
        // 跳转到引导页（路由应该已经处理了，这里是兜底）
        context.go('/onboarding');
        return;
      }
    }

    // 初始化应用
    if (!appProvider.isInitialized) {
      await appProvider.initializeApp();
    }

    // 后台数据同步现在已经在AppProvider.initializeApp中自动处理
    // 无需在UI层再次触发
  }

  // 刷新笔记数据
  Future<void> _refreshNotes() async {
    if (_isRefreshing) {
      return;
    }

    setState(() {
      _isRefreshing = true;
    });

    try {
      final appProvider = Provider.of<AppProvider>(context, listen: false);

      // 🚀 使用增量同步：速度快10倍以上！
      if (appProvider.isLoggedIn && !appProvider.isLocalMode) {
        if (kDebugMode) {
          // 🚀 执行增量同步（静默）
        }
        await appProvider.refreshFromServerFast();

        // 显示同步成功提示
        if (mounted) {
          SnackBarUtils.showSuccess(
            context,
            AppLocalizationsSimple.of(context)?.syncSuccess ?? '同步成功',
          );
        }
      }

      // 🔧 移除自动 WebDAV 同步，避免干扰 UI
      // WebDAV 同步改为在设置页面手动触发或定时自动执行
      if (!appProvider.isWebDavEnabled) {
        // 本地模式下重新加载本地数据
        if (kDebugMode) {
          // 🚀 加载本地数据（静默）
        }
        await appProvider.loadNotesFromLocal();

        // 显示刷新成功提示
        if (mounted) {
          SnackBarUtils.showSuccess(
            context,
            AppLocalizationsSimple.of(context)?.refreshSuccess ?? '刷新成功',
          );
        }
      }

      // 🚀 下拉刷新时同步到 Notion（异步执行，不阻塞UI）
      try {
        await appProvider.syncToNotion();
        if (kDebugMode) {
          debugPrint('HomeScreen: Notion 同步成功');
        }
      } on Object catch (e) {
        // Notion 同步失败不影响主流程
        if (kDebugMode) {
          debugPrint('HomeScreen: Notion 同步失败: $e');
        }
      }
    } on Object catch (e) {
      if (kDebugMode) {
        debugPrint('HomeScreen: 刷新失败: $e');
      }
      // 显示刷新失败提示
      if (mounted) {
        SnackBarUtils.showError(
          context,
          '${AppLocalizationsSimple.of(context)?.refreshFailed ?? '刷新失败'}: $e',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isRefreshing = false;
        });
      }
    }
  }

  // ── 🕰️ 那年今日 ──────────────────────────────────────────

  Future<void> _loadOnThisDay() async {
    final notes = await Provider.of<AppProvider>(context, listen: false)
        .loadNotesOnThisDay();
    if (!mounted) {
      return;
    }
    setState(() => _onThisDayNotes = notes);
  }

  /// 关闭只收起本次会话的卡片：避免关一次就整天看不到，
  /// 想再看时重启应用即可恢复。
  void _dismissOnThisDay() {
    setState(() {
      _onThisDayDismissed = true;
      _onThisDayNotes = const <Note>[];
    });
  }

  /// 首页顶部的三个快捷入口。
  ///
  /// 对齐 flomo 首页 `fragment_main.xml` 的 `headerLayout`：那三颗白色胶囊
  /// （AI 洞察 / 每日回顾 / 随机漫步）挂在可折叠 AppBar 上，滚动时跟着收起。
  /// 我们没有可折叠 AppBar，就把它们放进信息流第一条——滚到顶就看得见，
  /// 往下滚跟着列表走，观感一致。
  ///
  /// 尺寸照抄反编译资源，不自己估：整行上下各留 12 → 胶囊高 40，圆角
  /// 12（cornerRadiusLarge），左右内边距 16，胶囊间距 8，图标 16，
  /// 文字 14sp（textRegular）。
  Widget _buildShortcutPills() {
    final l10n = AppLocalizationsSimple.of(context);
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final textColor =
        isDarkMode ? AppTheme.darkTextPrimaryColor : AppTheme.textPrimaryColor;
    final fillColor = isDarkMode ? AppTheme.darkCardColor : Colors.white;

    final entries = <({String label, IconData icon, String route})>[
      (
        label: l10n?.aiInsight ?? 'AI 洞察',
        icon: Icons.auto_awesome_outlined,
        route: '/ai-insight',
      ),
      (
        label: l10n?.periodicReview ?? '周期回顾',
        icon: Icons.auto_stories_rounded,
        route: '/periodic-review',
      ),
      (
        label: l10n?.randomReview ?? '随机回顾',
        icon: Icons.shuffle_rounded,
        route: '/random-review',
      ),
    ];

    return Padding(
      // 左右 12 与卡片外边距对齐；底部 8 是卡片之间的常规间距
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      child: Row(
        children: [
          for (var i = 0; i < entries.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            // 胶囊本身按内容宽（flomo 是 wrap_content），这里用 Flexible 让
            // 极窄屏/time长文案时能收窄并省略，不至于把整行挤爆
            Flexible(
              child: _buildShortcutPill(
                label: entries[i].label,
                icon: entries[i].icon,
                fillColor: fillColor,
                textColor: textColor,
                onTap: () => context.push(entries[i].route),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildShortcutPill({
    required String label,
    required IconData icon,
    required Color fillColor,
    required Color textColor,
    required VoidCallback onTap,
  }) {
    final radius = BorderRadius.circular(12);
    return SizedBox(
      height: 40,
      child: Material(
        color: fillColor,
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 16, color: textColor),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.15,
                      fontWeight: FontWeight.w500,
                      color: textColor,
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

  Widget _buildOnThisDayCard() {
    if (_onThisDayDismissed || _onThisDayNotes.isEmpty) {
      return const SizedBox.shrink();
    }
    return OnThisDayCard(
      notes: _onThisDayNotes,
      onClose: _dismissOnThisDay,
      onOpenNote: (note) => context.push('/note/${note.id}'),
    );
  }

  // 打开侧边栏
  void _openDrawer() {
    _scaffoldKey.currentState?.openDrawer();
  }

  // 排序选项：参照 flomo，点标题后在标题下方直接展开一列选项
  Future<void> _showFeedOptions() async {
    final anchorBox = _titleAnchorKey.currentContext?.findRenderObject();
    final overlayBox = Overlay.of(context).context.findRenderObject();
    if (anchorBox is! RenderBox || overlayBox is! RenderBox) {
      return;
    }

    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final backgroundColor = isDarkMode ? AppTheme.darkCardColor : Colors.white;
    final textColor =
        isDarkMode ? AppTheme.darkTextPrimaryColor : Colors.black87;
    final primaryColor =
        isDarkMode ? AppTheme.primaryLightColor : AppTheme.primaryColor;

    final topLeft = anchorBox.localToGlobal(Offset.zero, ancestor: overlayBox);
    final bottomRight = anchorBox.localToGlobal(
      anchorBox.size.bottomRight(Offset.zero),
      ancestor: overlayBox,
    );
    final anchorRect = Rect.fromPoints(topLeft, bottomRight);
    // showMenu 会把菜单顶部对齐到锚点顶部，那样正好盖住标题文字，
    // 因此把定位矩形整体挪到标题下方，并留一点缝隙。
    final position = RelativeRect.fromRect(
      anchorRect.translate(0, anchorRect.height + 6),
      Offset.zero & overlayBox.size,
    );

    final headerColor = isDarkMode
        ? Colors.white.withValues(alpha: 0.5)
        : Colors.black.withValues(alpha: 0.5);

    final l10n = AppLocalizationsSimple.of(context);
    final selected = await showMenu<_FeedMenuChoice>(
      context: context,
      position: position,
      color: backgroundColor,
      elevation: 10,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      // 贴着标题的一张小卡片，不要铺满大半个屏幕
      constraints: const BoxConstraints(minWidth: 196, maxWidth: 248),
      items: [
        _buildSortMenuHeader(l10n?.sortBy ?? '排序方式', headerColor),
        const PopupMenuDivider(height: 1),
        _buildSortMenuItem(
          l10n?.newestFirst ?? '创建时间：从新到旧',
          SortOrder.newest,
          primaryColor,
          textColor,
        ),
        _buildSortMenuItem(
          l10n?.oldestFirst ?? '创建时间：从旧到新',
          SortOrder.oldest,
          primaryColor,
          textColor,
        ),
        _buildSortMenuItem(
          l10n?.updatedTime ?? '编辑时间：从新到旧',
          SortOrder.updated,
          primaryColor,
          textColor,
        ),
        _buildSortMenuItem(
          l10n?.oldestEdited ?? '编辑时间：从旧到新',
          SortOrder.updatedOldest,
          primaryColor,
          textColor,
        ),
        const PopupMenuDivider(height: 1),
        // 「有图片 / 有视频」是按媒体筛笔记，产出仍是笔记列表 ——
        // 和 flomo 一致，不是独立相册。相册入口挪到筛选态右上角的按钮。
        _buildSortMenuHeader(l10n?.mediaFilter ?? '筛选', headerColor),
        _buildFilterMenuItem(
          l10n?.allNotes ?? '全部笔记',
          NoteMediaFilter.all,
          primaryColor,
          textColor,
        ),
        _buildFilterMenuItem(
          l10n?.imageGallery ?? '有图片',
          NoteMediaFilter.images,
          primaryColor,
          textColor,
        ),
        _buildFilterMenuItem(
          l10n?.videoGallery ?? '有视频',
          NoteMediaFilter.videos,
          primaryColor,
          textColor,
        ),
      ],
    );

    if (selected == null || !mounted) {
      return;
    }

    if (selected.sortOrder != null) {
      setState(() => _currentSortOrder = selected.sortOrder!);
      _applySorting();
      return;
    }

    final filter = selected.filter;
    if (filter != null) {
      await _applyMediaFilter(filter);
    }
  }

  /// 切换媒体筛选。结果是一次性全量查询，切完把列表滚回顶部，
  /// 否则用户会停在上一份列表的滚动位置，看起来像「筛完还是那些笔记」。
  Future<void> _applyMediaFilter(NoteMediaFilter filter) async {
    final appProvider = Provider.of<AppProvider>(context, listen: false);
    if (appProvider.mediaFilter == filter) {
      return;
    }
    await appProvider.setMediaFilter(filter);
    if (!mounted || !_scrollController.hasClients) {
      return;
    }
    _scrollController.jumpTo(0);
  }

  /// 标题文本：筛选态用筛选名，否则用品牌名。
  String _feedTitleText() {
    final appProvider = Provider.of<AppProvider>(context, listen: false);
    final l10n = AppLocalizationsSimple.of(context);
    return switch (appProvider.mediaFilter) {
      NoteMediaFilter.images => l10n?.imageGallery ?? '有图片',
      NoteMediaFilter.videos => l10n?.videoGallery ?? '有视频',
      NoteMediaFilter.all => AppConfig.appName,
    };
  }

  /// 菜单头：只是标题，不可点击，也不会被选中
  PopupMenuItem<_FeedMenuChoice> _buildSortMenuHeader(
    String title,
    Color color,
  ) {
    return PopupMenuItem<_FeedMenuChoice>(
      enabled: false,
      height: 34,
      padding: const EdgeInsets.only(left: 16, right: 16, top: 8, bottom: 2),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
          color: color,
        ),
      ),
    );
  }

  PopupMenuItem<_FeedMenuChoice> _buildSortMenuItem(
    String title,
    SortOrder sortOrder,
    Color primaryColor,
    Color textColor,
  ) {
    final isSelected = _currentSortOrder == sortOrder;

    return PopupMenuItem<_FeedMenuChoice>(
      value: _FeedMenuChoice.sort(sortOrder),
      height: 44,
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                fontSize: 15,
                color: isSelected ? primaryColor : textColor,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ),
          if (isSelected)
            Icon(
              Icons.check_rounded,
              color: primaryColor,
              size: 18,
            ),
        ],
      ),
    );
  }

  /// 媒体筛选项（全部笔记 / 有图片 / 有视频）。
  PopupMenuItem<_FeedMenuChoice> _buildFilterMenuItem(
    String title,
    NoteMediaFilter filter,
    Color primaryColor,
    Color textColor,
  ) {
    final appProvider = Provider.of<AppProvider>(context, listen: false);
    final isSelected = appProvider.mediaFilter == filter;

    return PopupMenuItem<_FeedMenuChoice>(
      value: _FeedMenuChoice.filter(filter),
      height: 44,
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                fontSize: 15,
                color: isSelected ? primaryColor : textColor,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ),
          if (isSelected)
            Icon(
              Icons.check_rounded,
              color: primaryColor,
              size: 18,
            ),
        ],
      ),
    );
  }

  // 应用排序
  void _applySorting() {
    final appProvider = Provider.of<AppProvider>(context, listen: false);
    appProvider.setSortOrder(_currentSortOrder);
  }

  // 显示添加笔记表单
  /// 弹出编辑器：全屏模糊遮罩 + 底部编辑卡片（参考 flomo 的毛玻璃浮层）
  ///
  /// 原来用 showModalBottomSheet，遮罩只有 Material 的半透明黑，无法模糊底层内容；
  /// 这里换成 showGeneralDialog 自绘遮罩：BackdropFilter 糊住首页，
  /// 编辑器本身仍是全屏透明的 Scaffold（自带点击空白关闭与键盘避让）。
  Future<void> _showComposerSheet(Widget editor) => showGeneralDialog<void>(
        context: context,
        barrierDismissible: true,
        barrierLabel: 'note-composer',
        barrierColor: Colors.transparent,
        transitionDuration: const Duration(milliseconds: 220),
        pageBuilder: (dialogContext, _, __) {
          final isDark = Theme.of(dialogContext).brightness == Brightness.dark;
          return Stack(
            children: [
              Positioned.fill(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                  child: ColoredBox(
                    color: isDark
                        ? Colors.black.withValues(alpha: 0.28)
                        : Colors.white.withValues(alpha: 0.18),
                  ),
                ),
              ),
              editor,
            ],
          );
        },
        transitionBuilder: (context, animation, _, child) => FadeTransition(
          opacity: animation,
          child: child,
        ),
      );

  void _showAddNoteForm({bool startWithSpeech = false}) {
    _showComposerSheet(
      NoteEditor(
        startWithSpeech: startWithSpeech,
        onSave: (content) async {
          if (content.trim().isNotEmpty) {
            try {
              final appProvider =
                  Provider.of<AppProvider>(context, listen: false);
              await appProvider.createNote(content);

              if (!mounted || !context.mounted) {
                return;
              }

              _afterNoteCreated(appProvider);
            } on Object catch (e) {
              if (kDebugMode) {
                debugPrint('HomeScreen: 创建笔记失败: $e');
              }
              if (mounted && context.mounted) {
                SnackBarUtils.showError(
                  context,
                  '${AppLocalizationsSimple.of(context)?.createNoteFailed ?? '创建笔记失败'}: $e',
                );
              }
            }
          }
        },
      ),
    ).then((_) {
      // 🚀 表单关闭（静默）
    });
  }

  void _afterNoteCreated(AppProvider appProvider) {
    if (_isSearchActive) {
      _exitSearch();
    }

    if (!mounted) {
      return;
    }

    if (_scrollController.hasClients) {
      unawaited(
        _scrollController.animateTo(
          0,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        ),
      );
    }
  }

  // 🔥 显示添加笔记表单（带初始内容）- 用于分享接收
  void _showAddNoteFormWithContent(
    String initialContent, {
    bool startWithSpeech = false,
  }) {
    _showComposerSheet(
      NoteEditor(
        initialContent: initialContent, // 🔥 预填充分享的内容
        startWithSpeech: startWithSpeech,
        onSave: (content) async {
          if (content.trim().isNotEmpty) {
            try {
              final appProvider =
                  Provider.of<AppProvider>(context, listen: false);
              await appProvider.createNote(content);

              if (!mounted || !context.mounted) {
                return;
              }

              _afterNoteCreated(appProvider);

              // 显示成功提示
              if (mounted && context.mounted) {
                SnackBarUtils.showSuccess(
                  context,
                  AppLocalizationsSimple.of(context)?.addedFromShare ??
                      '已添加来自分享的笔记',
                );
              }
            } on Object catch (e) {
              if (kDebugMode) {
                debugPrint('HomeScreen: 创建笔记失败: $e');
              }
              if (mounted && context.mounted) {
                SnackBarUtils.showError(
                  context,
                  '${AppLocalizationsSimple.of(context)?.createNoteFailed ?? '创建笔记失败'}: $e',
                );
              }
            }
          }
        },
      ),
    ).then((_) {
      // 🚀 表单关闭（静默）
    });
  }

  // 显示编辑笔记表单
  /// 编辑已有笔记：进全屏编辑器（卡片只留给新建）。
  ///
  /// 入口有三个——卡片双击、卡片三点菜单、长按菜单，全都汇到这里，
  /// 免得改一处漏一处。
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
          // 🚀 笔记更新成功（静默）
        } on Object catch (e) {
          if (kDebugMode) {
            debugPrint('HomeScreen: 更新笔记失败: $e');
          }
          if (mounted && context.mounted) {
            SnackBarUtils.showError(
              context,
              '${AppLocalizationsSimple.of(context)?.updateFailed ?? '更新失败'}: $e',
            );
          }
        }
      },
    );
  }

  // 构建通知提示框（仅提醒通知）
  //
  // 用 Selector 只订阅未读数：原先的 Provider.of(context) 会在订阅者列表里
  // 挂上整个 HomeScreen，任何 provider 通知都会让 AppBar 和列表一起重建。
  /// 播放一行的退场动效，等它播完再返回。
  ///
  /// 兜底 400ms：动画被系统掉帧、或这一行恰好被别的刷新摘掉时，
  /// 也不能把删除流程卡在这里。
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

  /// 删除结束后收尾：
  /// - 删除成功 → 这一条已不在列表里，把动效标记丢掉，避免集合越积越大；
  /// - 落库失败 → 行还在，标记改回 false，让它滑回原位。
  void _finishNoteDelete(String noteId, AppProvider appProvider) {
    final stillThere = appProvider.notes.any((n) => n.id == noteId);
    if (!stillThere) {
      _leavingNoteIds.remove(noteId);
      _noteExitCompleters.remove(noteId);
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _leavingNoteIds.remove(noteId);
      _noteExitCompleters.remove(noteId);
    });
  }

  Widget _buildNotificationBanner() => Selector<AppProvider, int>(
        selector: (_, provider) => provider.unreadAnnouncementsCount,
        builder: (context, unreadCount, child) {
          if (unreadCount <= 0) {
            return const SizedBox.shrink();
          }
          return _buildNotificationBannerBody(context, unreadCount);
        },
      );

  Widget _buildNotificationBannerBody(BuildContext context, int unreadCount) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    // 设置颜色 - 使用卡片背景色和应用主题强调色
    final backgroundColor = isDarkMode ? AppTheme.darkCardColor : Colors.white;
    final textColor =
        isDarkMode ? AppTheme.primaryLightColor : AppTheme.primaryColor;
    final iconColor = textColor;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8), // 减少下边距
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () async {
            // 🎯 点击跳转到通知页面（不自动标记已读）
            if (context.mounted) {
              unawaited(context.pushNamed('notifications'));
            }
          },
          borderRadius: BorderRadius.circular(12),
          child: Ink(
            decoration: BoxDecoration(
              color: backgroundColor,
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color:
                      Colors.black.withValues(alpha: isDarkMode ? 0.3 : 0.05),
                  offset: const Offset(0, 1),
                  blurRadius: 3,
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 8,
              ), // 减少内边距，降低高度
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center, // 居中对齐
                children: [
                  Icon(
                    Icons.notifications_active,
                    color: iconColor,
                    size: 16, // 减小图标尺寸
                  ),
                  const SizedBox(width: 8),
                  Text(
                    AppLocalizationsSimple.of(context)
                            ?.unreadNotificationsCount(unreadCount) ??
                        '$unreadCount条未读信息',
                    style: TextStyle(
                      color: textColor,
                      fontWeight: FontWeight.w400, // 减轻字重
                      fontSize: 12, // 减小字体
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

  /// 筛选态下的空态：这个口径下没有笔记，给一个回到「全部笔记」的口子。
  Widget _buildMediaFilterEmptyState() {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final secondaryTextColor = isDarkMode
        ? AppTheme.darkTextSecondaryColor
        : AppTheme.textSecondaryColor;
    final appProvider = Provider.of<AppProvider>(context, listen: false);
    final l10n = AppLocalizationsSimple.of(context);
    final isVideo = appProvider.mediaFilter == NoteMediaFilter.videos;

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isVideo
                ? Icons.videocam_off_outlined
                : Icons.photo_library_outlined,
            size: 56,
            color: secondaryTextColor.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 12),
          Text(
            isVideo
                ? (l10n?.noVideoNotes ?? '还没有带视频的笔记')
                : (l10n?.noImageNotes ?? '还没有带图片的笔记'),
            style: TextStyle(fontSize: 15, color: secondaryTextColor),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => _applyMediaFilter(NoteMediaFilter.all),
            child: Text(l10n?.allNotes ?? '全部笔记'),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final cardColor = isDarkMode ? AppTheme.darkCardColor : Colors.white;
    final textColor =
        isDarkMode ? AppTheme.darkTextPrimaryColor : AppTheme.textPrimaryColor;
    final secondaryTextColor = isDarkMode
        ? AppTheme.darkTextSecondaryColor
        : AppTheme.textSecondaryColor;
    final iconColor =
        isDarkMode ? AppTheme.primaryLightColor : AppTheme.primaryColor;
    final cardShadow = AppTheme.neuCardShadow(isDark: isDarkMode);

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(height: 100),
          Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              color: cardColor,
              borderRadius: BorderRadius.circular(60),
              boxShadow: cardShadow,
            ),
            child: Center(
              child: Icon(
                Icons.note_add_rounded,
                size: 48,
                color: iconColor.withValues(alpha: 0.6),
              ),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            AppLocalizationsSimple.of(context)?.noNotesYet ?? '还没有笔记',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: textColor,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            AppLocalizationsSimple.of(context)?.clickToCreate ?? '点击右下角的按钮开始创建',
            style: TextStyle(
              fontSize: 16,
              color: secondaryTextColor,
            ),
          ),
        ],
      ),
    );
  }

  /// 首屏数据尚未就绪时的占位骨架。
  ///
  /// 有快照时会直接渲染快照里的笔记，只有没有快照（首次安装、快照损坏）
  /// 才会落到这里；这样冷启动不会再先闪一条「欢迎笔记」再被真实数据顶掉。
  Widget _buildFeedSkeleton() {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final blockColor = isDarkMode
        ? Colors.white.withValues(alpha: 0.06)
        : Colors.black.withValues(alpha: 0.05);

    Widget line(double widthFactor) => FractionallySizedBox(
          widthFactor: widthFactor,
          child: Container(
            height: 13,
            margin: const EdgeInsets.only(bottom: 10),
            decoration: BoxDecoration(
              color: blockColor,
              borderRadius: BorderRadius.circular(6),
            ),
          ),
        );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < 3; i++)
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 12),
              decoration: BoxDecoration(
                color: blockColor.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  line(0.92),
                  line(0.78),
                  line(0.46),
                  const SizedBox(height: 6),
                  Container(
                    height: 10,
                    width: 64,
                    decoration: BoxDecoration(
                      color: blockColor,
                      borderRadius: BorderRadius.circular(5),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// 📝 空列表时展示的欢迎笔记
  ///
  /// 复用 [NoteCard] 让观感与真实笔记完全一致；
  /// 点击进入编辑器并预填内容，保存后它就是一条真实笔记，
  /// 列表不再为空，这条示例也就自然消失了。
  Widget _buildWelcomeNoteCard() {
    final note = _welcomeNote;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: NoteCard(
        note: note,
        isExample: true,
        onEdit: () => _showAddNoteFormWithContent(note.content),
        onDelete: _showWelcomeNoteHint,
        onPin: _showWelcomeNoteHint,
      ),
    );
  }

  /// 示例笔记不参与删除/置顶，给一句说明即可
  void _showWelcomeNoteHint() {
    SnackBarUtils.showSuccess(
      context,
      AppLocalizationsSimple.of(context)?.welcomeNoteHint ??
          '这是示例笔记，创建第一条笔记后会自动消失',
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final backgroundColor =
        isDarkMode ? AppTheme.darkBackgroundColor : AppTheme.backgroundColor;
    final cardColor = isDarkMode ? AppTheme.darkCardColor : Colors.white;
    final textColor =
        isDarkMode ? AppTheme.darkTextPrimaryColor : AppTheme.textPrimaryColor;
    final secondaryTextColor = isDarkMode
        ? AppTheme.darkTextSecondaryColor
        : AppTheme.textSecondaryColor;
    final iconColor = isDarkMode
        ? AppTheme.darkTextSecondaryColor
        : AppTheme.textSecondaryColor;
    final hintColor = isDarkMode ? Colors.grey[500] : Colors.grey[400];

    // 🎯 允许直接返回（最小化应用）
    // 桌面端侧边栏由DesktopLayout处理，这里只需要内容区域
    final content = _buildMobileLayout(
      backgroundColor,
      cardColor,
      textColor,
      secondaryTextColor,
      iconColor,
      hintColor ?? Colors.grey,
      isDarkMode,
    );

    return ResponsiveLayout(
      mobile: content,
      tablet: content, // 平板端也使用相同布局
      desktop: content, // 桌面端使用相同布局，侧边栏由DesktopLayout处理
    );
  }

  // 移动端布局
  Widget _buildMobileLayout(
    Color backgroundColor,
    Color cardColor,
    Color textColor,
    Color secondaryTextColor,
    Color iconColor,
    Color hintColor,
    bool isDarkMode,
  ) {
    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: backgroundColor,
      // 🧊 列表延伸到底部，玻璃输入条才能模糊到下方的笔记内容
      extendBody: true,
      drawer: const Sidebar(),
      drawerEdgeDragWidth: MediaQuery.of(context).size.width * 0.25,
      appBar: AppBar(
        backgroundColor: backgroundColor,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        automaticallyImplyLeading: false,
        // 抽屉入口、标题、右侧动作合成一条 Row 放进 title 里。
        //
        // 原来是 leading + title + actions 三个槽位各管各的：进搜索态时
        // leading 变 null，那 44px 槽位却仍占着，titleSpacing 又从 0 跳到
        // 16，搜索框左边缘和标题左边缘对不上，切换那一下还会横向硬跳——
        // 光调曲线盖不住，只能把三段并到一起同步位移。
        titleSpacing: 0,
        title: Row(
          children: [
            // 抽屉按钮：搜索态横向收起（44 → 12）。里面的按钮用 OverflowBox
            // 保持 44 的自身尺寸，只让外层 ClipRect 裁掉多余部分，否则宽度
            // 收到 12 时 IconButton 会被压变形、点按热区也跟着缩。
            //
            // ⚠️ height 必须显式给：AppBar 的 title 槽位高约束是无限的，
            // AnimatedContainer 只给 width 时会把 maxHeight=∞ 透传给
            // OverflowBox，它按 fit=max 撑到 Infinity → 整个 title 子树
            // 布局失败（release 下不红屏，只是整块画不出来）。
            ClipRect(
              child: IgnorePointer(
                // 收到 12px 后图标已被裁掉，但那条缝仍会吃掉点击，
                // 搜索态下点它等于误开抽屉。
                ignoring: _isSearchActive,
                child: AnimatedContainer(
                  duration: _searchTransition,
                  curve: Curves.easeOutCubic,
                  width: _isSearchActive ? 12 : 44,
                  height: _drawerButtonExtent,
                  alignment: Alignment.centerLeft,
                  child: OverflowBox(
                    minWidth: 44,
                    maxWidth: 44,
                    minHeight: _drawerButtonExtent,
                    maxHeight: _drawerButtonExtent,
                    alignment: Alignment.centerLeft,
                    child: IconButton(
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
                      tooltip: '菜单',
                      onPressed: _openDrawer,
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: AnimatedSwitcher(
                duration: _searchTransition,
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                // 原来是横向 SizeTransition：宽度从 0 拉满的过程中，里面的
                // 标题文字和输入框会被一路压扁再撑开，像在挤牙膏。改成整块
                // 淡入 + 6px 上浮，新旧两块同场交叉，谁也不会变形。
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, 0.14),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                ),
                // 默认的 Stack 是居中的，标题得靠左
                layoutBuilder: (currentChild, previousChildren) => Stack(
                  alignment: Alignment.centerLeft,
                  children: <Widget>[
                    ...previousChildren,
                    if (currentChild != null) currentChild,
                  ],
                ),
                child: _isSearchActive
                    ? Container(
                        key: const ValueKey('home_search_field'),
                        height: 42,
                        decoration: BoxDecoration(
                          color: cardColor,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isDarkMode
                                ? Colors.white.withValues(alpha: 0.08)
                                : Colors.black.withValues(alpha: 0.06),
                          ),
                        ),
                        child: TextField(
                          controller: _searchController,
                          focusNode: _searchFocusNode,
                          textInputAction: TextInputAction.search,
                          decoration: InputDecoration(
                            hintText: AppLocalizationsSimple.of(context)
                                    ?.searchNotes ??
                                '搜索笔记',
                            hintStyle: TextStyle(
                              color: hintColor,
                              fontSize: 15,
                            ),
                            prefixIcon: Icon(
                              Icons.search,
                              color: secondaryTextColor,
                              size: 20,
                            ),
                            suffixIcon: _searchController.text.isEmpty
                                ? null
                                : IconButton(
                                    tooltip: AppLocalizationsSimple.of(context)
                                            ?.clear ??
                                        '清除',
                                    icon: Icon(
                                      Icons.cancel_rounded,
                                      color: secondaryTextColor.withValues(
                                        alpha: 0.7,
                                      ),
                                      size: 18,
                                    ),
                                    onPressed: _clearSearchQuery,
                                  ),
                            border: InputBorder.none,
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(
                              vertical: 10,
                            ),
                          ),
                          style: TextStyle(
                            color: textColor,
                            fontSize: 15,
                            height: 1.25,
                          ),
                          onChanged: _handleSearchChanged,
                        ),
                      )
                    : GestureDetector(
                        key: const ValueKey('home_title'),
                        onTap: _showFeedOptions,
                        child: Container(
                          key: _titleAnchorKey,
                          // 文字与列表内容左边缘对齐，不再额外缩进
                          padding: const EdgeInsets.only(
                            right: 6,
                            top: 6,
                            bottom: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.transparent,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // 标题就是当前视图的名字：筛选态显示「有图片 / 有视频」，
                              // 否则保持品牌名。用 Selector 只订阅筛选值，切换排序
                              // 之类的通知不会连带重建标题。
                              Selector<AppProvider, String>(
                                selector: (_, provider) =>
                                    provider.mediaFilter.name,
                                builder: (context, _, __) => Text(
                                  _feedTitleText(),
                                  style: TextStyle(
                                    color: textColor,
                                    fontWeight: FontWeight.w600,
                                    fontSize: 18,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 4),
                              Icon(
                                Icons.keyboard_arrow_down_rounded,
                                color: textColor,
                                size: 20,
                              ),
                            ],
                          ),
                        ),
                      ),
              ),
            ),
          ],
        ),
        centerTitle: false,
        actions: [
          // 右侧动作跟着一起过渡：三个图标 ↔「取消」。直接条件渲染会从
          // 144px 硬切成 60px，标题右边突然腾出空位；AnimatedSize 只负责
          // 宽度，AnimatedSwitcher 负责内容本体。
          AnimatedSize(
            duration: _searchTransition,
            curve: Curves.easeOutCubic,
            alignment: Alignment.centerRight,
            child: AnimatedSwitcher(
              duration: _searchTransition,
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) =>
                  FadeTransition(opacity: animation, child: child),
              child: _isSearchActive
                  ? TextButton(
                      key: const ValueKey('home_search_cancel'),
                      onPressed: _exitSearch,
                      child: Text(
                        AppLocalizationsSimple.of(context)?.cancel ?? '取消',
                        style: TextStyle(
                          color: iconColor,
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    )
                  : Row(
                      key: const ValueKey('home_actions'),
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // 筛选到「有图片」时给一个画册入口：宫格浏览仍然是看图最快的
                        // 方式，只是不再占侧边栏一个独立菜单项。
                        Selector<AppProvider, bool>(
                          selector: (_, provider) =>
                              provider.mediaFilter == NoteMediaFilter.images,
                          builder: (context, showGalleryEntry, _) =>
                              showGalleryEntry
                                  ? IconButton(
                                      icon: Container(
                                        padding: EdgeInsets.all(
                                          ResponsiveUtils.fontScaledSpacing(
                                            context,
                                            8,
                                          ),
                                        ),
                                        decoration: BoxDecoration(
                                          color: backgroundColor,
                                          borderRadius: BorderRadius.circular(
                                            ResponsiveUtils
                                                .fontScaledBorderRadius(
                                              context,
                                              8,
                                            ),
                                          ),
                                        ),
                                        child: Icon(
                                          Icons.photo_library_outlined,
                                          size: ResponsiveUtils
                                              .fontScaledIconSize(context, 20),
                                          color: iconColor,
                                        ),
                                      ),
                                      tooltip: '画册',
                                      onPressed: () =>
                                          context.pushNamed('imageGallery'),
                                    )
                                  : const SizedBox.shrink(),
                        ),
                        // 问笔记：把全库笔记当资料，跟 AI 对话。
                        // 透明底的蓝色鲸鱼，和聊天页里的 AI 头像保持同一套视觉。
                        IconButton(
                          icon: Container(
                            padding: EdgeInsets.all(
                              ResponsiveUtils.fontScaledSpacing(context, 8),
                            ),
                            // 官方 DeepSeek logo 资产（与设置页同一份），替换自绘鲸鱼剪影；
                            // 资产自带留边，24px 实际鲸鱼宽度与旧 20px 自绘版相当
                            child: Image.asset(
                              'assets/images/deepseek_logo.png',
                              width: 24,
                              height: 24,
                              fit: BoxFit.contain,
                            ),
                          ),
                          tooltip:
                              AppLocalizationsSimple.of(context)?.askNotes ??
                                  '问笔记',
                          onPressed: () => context.pushNamed('noteChat'),
                        ),
                        // 搜索按钮
                        IconButton(
                          icon: Container(
                            padding: EdgeInsets.all(
                              ResponsiveUtils.fontScaledSpacing(context, 8),
                            ),
                            decoration: BoxDecoration(
                              color: backgroundColor,
                              borderRadius: BorderRadius.circular(
                                ResponsiveUtils.fontScaledBorderRadius(
                                  context,
                                  8,
                                ),
                              ),
                            ),
                            child: Icon(
                              Icons.search,
                              size: ResponsiveUtils.fontScaledIconSize(
                                context,
                                20,
                              ),
                              color: iconColor,
                            ),
                          ),
                          tooltip: AppLocalizationsSimple.of(context)?.search ??
                              '搜索',
                          onPressed: _enterSearch,
                        ),
                      ],
                    ),
            ),
          ),
          SizedBox(width: ResponsiveUtils.fontScaledSpacing(context, 8)),
        ],
      ),
      body: Selector<AppProvider, _FeedSnapshot>(
        selector: (_, provider) => (
          notes: provider.feedNotes,
          hasMoreData: provider.hasMoreData,
          isLoadingMore: provider.isLoadingMore,
          loadedCount: provider.loadedNotesCount,
          totalCount: provider.totalNotesCount,
          loadMoreStage: provider.loadMoreState.name,
          isInitialized: provider.isInitialized,
          mediaFilter: provider.mediaFilter.name,
          isMediaFilterLoading: provider.isMediaFilterLoading,
        ),
        builder: (context, feed, child) {
          // 🚀 极速启动：不等loading，立即显示界面
          // 如果没有数据会显示空白状态，数据加载完立即刷新
          final appProvider = Provider.of<AppProvider>(context, listen: false);

          final allVisibleNotes = feed.notes;
          final notes = _isSearchActive
              ? (_searchController.text.isEmpty
                  ? allVisibleNotes
                  : _searchResults
                      .where(
                        (note) =>
                            note.content.trim().isNotEmpty ||
                            note.resourceList.isNotEmpty,
                      )
                      .toList())
              : allVisibleNotes;

          final searchQuery = _searchController.text.trim();
          final showSearchSummary = _isSearchActive && searchQuery.isNotEmpty;

          return Column(
            children: [
              Expanded(
                child: Stack(
                  children: [
                    GestureDetector(
                      onTap: _dismissSearchKeyboard,
                      behavior: HitTestBehavior.translucent,
                      // 换源那一下整体淡起（见 _replayFeedFade）：
                      // 只有一个 ListView，不会和 AnimatedSwitcher 抢 controller
                      child: FadeTransition(
                        opacity: _feedFade,
                        child: RefreshIndicator(
                          onRefresh: _refreshNotes,
                          color: AppTheme.primaryColor,
                          child: SlidableAutoCloseBehavior(
                            // 🔥 类似微信：同时只能打开一个侧滑项
                            child: notes.isEmpty
                                ? ListView(
                                    physics:
                                        const AlwaysScrollableScrollPhysics(),
                                    children: [
                                      if (!_isSearchActive)
                                        _buildNotificationBanner(),
                                      // 固定高度只给需要撑满首屏的空态/加载态；
                                      // 欢迎卡片必须按内容自适应，否则小屏/大字号下
                                      // 会被「屏幕高度 - 240」压出 RenderFlex 溢出
                                      if (showSearchSummary && _isSearchLoading)
                                        SizedBox(
                                          height: MediaQuery.of(context)
                                                  .size
                                                  .height -
                                              240,
                                          child: _buildSearchLoadingState(),
                                        )
                                      else if (showSearchSummary)
                                        SizedBox(
                                          height: MediaQuery.of(context)
                                                  .size
                                                  .height -
                                              240,
                                          child: _buildSearchEmptyState(
                                            searchQuery,
                                          ),
                                        )
                                      else if (_isSearchActive)
                                        SizedBox(
                                          height: MediaQuery.of(context)
                                                  .size
                                                  .height -
                                              240,
                                          child: _buildEmptyState(),
                                        )
                                      // 首屏数据没就绪时给骨架，别先闪一条「欢迎笔记」
                                      else if (!appProvider.isInitialized)
                                        _buildFeedSkeleton()
                                      // 筛选态还没查到结果：继续给骨架，别闪欢迎卡片
                                      else if (feed.isMediaFilterLoading)
                                        _buildFeedSkeleton()
                                      // 筛出来是空的：明确告诉用户这个口径下没有笔记，
                                      // 而不是落到「欢迎笔记」（那是给全新用户的）
                                      else if (appProvider.isMediaFilterActive)
                                        _buildMediaFilterEmptyState()
                                      // 确认本地一条笔记都没有时才展示欢迎笔记
                                      else
                                        _buildWelcomeNoteCard(),
                                    ],
                                  )
                                : ListView.builder(
                                    controller: _scrollController, // 🚀 添加滚动控制器
                                    physics:
                                        const AlwaysScrollableScrollPhysics(), // 🎯 确保下拉刷新可用
                                    itemCount:
                                        notes.length + 3, // +1头部 +1加载指示器 +1底部间距
                                    padding: EdgeInsets.zero,
                                    itemBuilder: (context, index) {
                                      // 第一个item是「那年今日」+ 通知栏 / 搜索结果摘要
                                      if (index == 0) {
                                        // 头部整块换：搜索摘要 ↔ 那年今日/通知。
                                        // 竖向 SizeTransition 让高度跟着收放，否则
                                        // 摘要一出现，下面所有卡片会瞬移一段。
                                        return AnimatedSwitcher(
                                          duration: const Duration(
                                            milliseconds: 180,
                                          ),
                                          switchInCurve: Curves.easeOutCubic,
                                          switchOutCurve: Curves.easeInCubic,
                                          transitionBuilder:
                                              (child, animation) =>
                                                  FadeTransition(
                                            opacity: animation,
                                            child: SizeTransition(
                                              sizeFactor: animation,
                                              child: child,
                                            ),
                                          ),
                                          child: showSearchSummary
                                              ? KeyedSubtree(
                                                  key: const ValueKey(
                                                    'feed_search_summary',
                                                  ),
                                                  child: _buildSearchSummary(
                                                    notes.length,
                                                  ),
                                                )
                                              : KeyedSubtree(
                                                  key: const ValueKey(
                                                    'feed_headers',
                                                  ),
                                                  child: Column(
                                                    mainAxisSize:
                                                        MainAxisSize.min,
                                                    children: [
                                                      // 三个快捷入口常驻列表顶部，
                                                      // 搜索态收起来（那时用户在找
                                                      // 具体一条，不需要入口）
                                                      if (!_isSearchActive)
                                                        _buildShortcutPills(),
                                                      // 有图片 / 有视频是「只看某类
                                                      // 媒体」的视图，那条横幅展示的
                                                      // 是任意旧笔记，混进去等于筛选
                                                      // 失效。
                                                      if (appProvider
                                                              .mediaFilter ==
                                                          NoteMediaFilter.all)
                                                        _buildOnThisDayCard(),
                                                      _buildNotificationBanner(),
                                                    ],
                                                  ),
                                                ),
                                        );
                                      }

                                      // 倒数第二个item是加载更多指示器
                                      if (index == notes.length + 1) {
                                        if (_isSearchActive) {
                                          return const SizedBox.shrink();
                                        }
                                        return _buildLoadMoreIndicator(
                                          appProvider,
                                        );
                                      }

                                      // 最后一个item是底部间距
                                      // 🧊 底部玻璃输入条会盖住一段，留足空间让最后一条
                                      // 笔记能滚到条下方，模糊叠加才看得见
                                      if (index == notes.length + 2) {
                                        return const SizedBox(height: 120);
                                      }

                                      final noteIndex =
                                          index - 1; // 调整索引，因为第一个是通知栏

                                      final note = notes[noteIndex];
                                      return RepaintBoundary(
                                        key: ValueKey(
                                          note.id,
                                        ), // 🚀 添加key避免不必要的重建
                                        child: SlideOutRow(
                                          key: ValueKey('exit_${note.id}'),
                                          leaving: _leavingNoteIds.contains(
                                            note.id,
                                          ),
                                          onExited: () =>
                                              _handleNoteExitFinished(note.id),
                                          child: NoteCard(
                                            key: ValueKey(
                                              'card_${note.id}',
                                            ), // 🚀 为NoteCard添加key
                                            note: note, // 🚀 直接传递Note对象，避免内部查找
                                            highlightQuery: showSearchSummary
                                                ? searchQuery
                                                : null,
                                            // 卡片里「⋯」菜单的删除先播退出动效
                                            playDeleteExit: () =>
                                                _playNoteExit(note.id),
                                            onEdit: () {
                                              // 🚀 编辑笔记（静默）
                                              _showEditNoteForm(note);
                                            },
                                            onDelete: () {
                                              // 与「⋯」菜单收敛到同一条路径：
                                              // 二次确认 + 行退出 + 原生提示条。
                                              NoteActionsUi.deleteNote(
                                                context: context,
                                                note: note,
                                                playExit: () =>
                                                    _playNoteExit(note.id),
                                                onDeleted: () {
                                                  // 搜索结果不随 provider 通知
                                                  // 变化，要自己摘掉。
                                                  if (_isSearchActive) {
                                                    setState(() {
                                                      _searchResults
                                                          .removeWhere(
                                                        (r) => r.id == note.id,
                                                      );
                                                    });
                                                  }
                                                  _finishNoteDelete(
                                                    note.id,
                                                    Provider.of<AppProvider>(
                                                      context,
                                                      listen: false,
                                                    ),
                                                  );
                                                },
                                              );
                                            },
                                            onPin: () async {
                                              final appProvider =
                                                  Provider.of<AppProvider>(
                                                context,
                                                listen: false,
                                              );
                                              // 🔥 保存切换前的状态
                                              final willPin = !note.isPinned;
                                              await appProvider
                                                  .togglePinStatus(note);
                                              if (context.mounted) {
                                                SnackBarUtils.showSuccess(
                                                  context,
                                                  // 🔥 显示切换后的状态
                                                  willPin
                                                      ? (AppLocalizationsSimple
                                                              .of(
                                                            context,
                                                          )?.pinned ??
                                                          '已置顶')
                                                      : (AppLocalizationsSimple
                                                              .of(
                                                            context,
                                                          )?.unpinned ??
                                                          '已取消置顶'),
                                                );
                                              }
                                            },
                                          ),
                                        ),
                                      );
                                    },
                                  ), // ListView.builder 结束
                          ), // SlidableAutoCloseBehavior 结束
                        ), // RefreshIndicator 结束
                      ), // FadeTransition 结束
                    ), // GestureDetector 结束 - 点击空白处退出搜索

                    // 🧊 不再铺「背景色 → 透明」的底部渐隐层：
                    // 那层铺在列表之上、底栏之下且底部全不透明，会把
                    // BackdropFilter 糊到的内容抹平成纯色，玻璃感被抽空。
                    // iOS / 酷安的做法是让内容直接穿到悬浮胶囊背后，
                    // 由 blur 自己收敛（列表末尾已留 120dp 滚动余量）。

                    // 移除全屏同步覆盖层，改为后台静默同步
                  ],
                ), // Stack 结束
              ), // Expanded 结束
            ],
          ); // Column 结束
        }, // Consumer builder 结束
      ), // Consumer 结束
      // 🧊 底部通栏输入条（flomo 同款）
      bottomNavigationBar: _buildBottomComposerBar(context),
    );
  }

  /// 🧊 底部通栏输入条（flomo 同款）
  ///
  /// 一条横贯底部、悬浮在列表之上的玻璃条，从左到右分三段：
  /// - 左：加号 → 直接进入新建笔记
  /// - 中：点击进入编辑（占位文案提示）
  /// - 右：语音入口（仅在设置里开启语音并配好讯飞密钥后出现）
  ///
  /// 玻璃效果交给 `liquid_glass_renderer` 的 iOS 27 regular 预设：
  /// 倒角折射、frost、glint、暗边都由它算，不再是手搓的半透明叠加。
  /// 因为 `Scaffold.extendBody = true`，列表会从条的下方穿过，
  /// 玻璃才采样得到真实内容。
  Widget _buildBottomComposerBar(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final brightness = isDarkMode ? Brightness.dark : Brightness.light;
    // floating_control_icon
    final iconColor = isDarkMode ? Colors.white : const Color(0xFF2E2E2E);
    // 占位文案：玻璃上要能读清，浅色用黑字、深色用白字
    final hintColor = isDarkMode ? Colors.white : Colors.black;
    const barHeight = 58.0;
    const shapeRadius = 26.0;
    final radius = BorderRadius.circular(shapeRadius);
    // 语音入口只在「设置里开启 + 讯飞密钥填全」后出现：默认配置下不展示，
    // 避免用户点了麦克风却没有任何可用识别引擎（历史 VOICE-001）。
    final speechEnabled = context.select<AppProvider, bool>(
      (provider) => provider.appConfig.speechInputEnabled,
    );

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        child: SizedBox(
          height: barHeight,
          child: LiquidGlassLayer(
            // iOS 27 regular 材质：倒角折射 + frost + glint + 暗边都由预设给出。
            // 58dp 高的条用默认 20/60 的倒角太陡，边缘会把正文糊成明显的放大镜，
            // 收窄到 14/40；tintAmount 0.35 兼顾通透与文字可读性。
            settings: LiquidGlassSettings.ios27Regular(
              brightness: brightness,
              tintAmount: 0.35,
            ).copyWith(
              refractionHeight: 14,
              refractionAmount: 40,
            ),
            defaultAppearance:
                LiquidGlassAppearance.ios27Regular(brightness: brightness),
            child: LiquidGlass(
              shape: const LiquidRoundedSuperellipse(
                borderRadius: shapeRadius,
              ),
              shadows: [
                BoxShadow(
                  color: isDarkMode
                      ? const Color(0x80000000)
                      : const Color(0x26000000),
                  blurRadius: 20,
                  offset: const Offset(0, 6),
                ),
              ],
              child: Material(
                color: Colors.transparent,
                child: Row(
                  children: [
                    // 左：加号 → 新建笔记
                    InkWell(
                      onTap: _showAddNoteForm,
                      borderRadius: radius,
                      splashColor: iconColor.withValues(alpha: 0.12),
                      highlightColor: iconColor.withValues(alpha: 0.06),
                      child: SizedBox(
                        width: barHeight,
                        height: barHeight,
                        child: Icon(
                          Icons.add_rounded,
                          color: iconColor,
                          size: 26,
                        ),
                      ),
                    ),
                    // 中：点击进入编辑
                    Expanded(
                      child: InkWell(
                        onTap: _showAddNoteForm,
                        splashColor: iconColor.withValues(alpha: 0.10),
                        highlightColor: iconColor.withValues(alpha: 0.05),
                        child: Container(
                          height: barHeight,
                          alignment: Alignment.centerLeft,
                          child: Text(
                            AppLocalizationsSimple.of(context)
                                    ?.noteComposerHint ??
                                '记点什么…',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 15,
                              color: hintColor,
                            ),
                          ),
                        ),
                      ),
                    ),
                    // 右：语音（关闭语音输入时不渲染该入口）
                    if (speechEnabled)
                      InkWell(
                        onTap: () => _showAddNoteForm(startWithSpeech: true),
                        borderRadius: radius,
                        splashColor: iconColor.withValues(alpha: 0.12),
                        highlightColor: iconColor.withValues(alpha: 0.06),
                        child: SizedBox(
                          width: barHeight,
                          height: barHeight,
                          child: Icon(
                            Icons.mic_none_rounded,
                            color: iconColor.withValues(alpha: 0.75),
                            size: 22,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSearchSummary(int count) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final l10n = AppLocalizationsSimple.of(context);
    final textColor = isDarkMode
        ? AppTheme.darkTextSecondaryColor
        : AppTheme.textSecondaryColor;
    final accentColor =
        isDarkMode ? AppTheme.primaryLightColor : AppTheme.primaryColor;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Row(
        children: [
          Icon(
            Icons.search_rounded,
            size: ResponsiveUtils.fontScaledIconSize(context, 16),
            color: accentColor,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              l10n?.searchResultsCount(count) ?? '找到 $count 条结果',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: textColor,
                fontSize: ResponsiveUtils.responsiveFontSize(context, 13),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchEmptyState(String query) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final l10n = AppLocalizationsSimple.of(context);
    final textColor =
        isDarkMode ? AppTheme.darkTextPrimaryColor : AppTheme.textPrimaryColor;
    final secondaryTextColor = isDarkMode
        ? AppTheme.darkTextSecondaryColor
        : AppTheme.textSecondaryColor;
    final iconColor =
        isDarkMode ? AppTheme.primaryLightColor : AppTheme.primaryColor;

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: isDarkMode ? 0.14 : 0.08),
                borderRadius: BorderRadius.circular(44),
              ),
              child: Icon(
                Icons.search_off_rounded,
                size: ResponsiveUtils.fontScaledIconSize(context, 36),
                color: iconColor.withValues(alpha: 0.72),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              l10n?.noSearchResults ?? '没有找到相关笔记',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: textColor,
                fontSize: ResponsiveUtils.responsiveFontSize(context, 17),
                fontWeight: FontWeight.w600,
              ),
            ),
            if (query.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                query,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: secondaryTextColor,
                  fontSize: ResponsiveUtils.responsiveFontSize(context, 14),
                  height: 1.4,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSearchLoadingState() {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDarkMode
        ? AppTheme.darkTextSecondaryColor
        : AppTheme.textSecondaryColor;
    final accentColor =
        isDarkMode ? AppTheme.primaryLightColor : AppTheme.primaryColor;

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(
              strokeWidth: 2.6,
              valueColor: AlwaysStoppedAnimation<Color>(accentColor),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            '搜索中...',
            style: TextStyle(
              color: textColor,
              fontSize: ResponsiveUtils.responsiveFontSize(context, 14),
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  // 🚀 构建加载更多指示器
  Widget _buildLoadMoreIndicator(AppProvider appProvider) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDarkMode
        ? AppTheme.darkTextSecondaryColor
        : AppTheme.textSecondaryColor;

    // 如果还有更多数据，显示加载中
    if (appProvider.hasMoreData) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 20),
        alignment: Alignment.center,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(
                  isDarkMode
                      ? AppTheme.primaryLightColor
                      : AppTheme.primaryColor,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              AppLocalizationsSimple.of(context)?.loading ?? '加载中...',
              style: TextStyle(
                fontSize: 13,
                color: textColor,
              ),
            ),
          ],
        ),
      );
    }

    final loadedCount = appProvider.loadedNotesCount;

    // 没有更多数据，显示已加载全部
    if (loadedCount > 10) {
      // 只有笔记数量大于10才显示
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        alignment: Alignment.center,
        child: Text(
          (AppLocalizationsSimple.of(context)?.loadedAll ?? '已加载全部 {count} 条笔记')
              .replaceAll('{count}', '$loadedCount'),
          style: TextStyle(
            fontSize: 12,
            color: textColor.withValues(alpha: 0.6),
          ),
        ),
      );
    }

    return const SizedBox.shrink();
  }
}
