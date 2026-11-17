import 'package:flutter/material.dart';
import 'package:inkpaper/l10n/app_localizations_simple.dart';
import 'package:inkpaper/providers/app_provider.dart';
import 'package:inkpaper/services/weread_api_service.dart';
import 'package:inkpaper/services/weread_sync_service.dart';
import 'package:inkpaper/themes/app_theme.dart';
import 'package:inkpaper/utils/logger.dart';
import 'package:inkpaper/utils/text_style_helper.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

/// 微信读书笔记同步（实验室）
///
/// 把微信读书里的划线与想法增量拉到 InkPaper：一条划线一条笔记，id 由
/// bookmarkId 确定性生成，重复同步不会产生副本。
class WeReadSyncScreen extends StatefulWidget {
  const WeReadSyncScreen({super.key});

  @override
  State<WeReadSyncScreen> createState() => _WeReadSyncScreenState();
}

class _WeReadSyncScreenState extends State<WeReadSyncScreen> {
  static const String _apiKeyHelpUrl = 'https://weread.qq.com/r/weread-skills';

  final WeReadSyncService _service = WeReadSyncService();
  final TextEditingController _apiKeyController = TextEditingController();
  final Logger _logger = const Logger('WeReadSyncScreen');

  bool _loading = true;
  bool _keyConfigured = false;
  bool _verifying = false;
  bool _syncing = false;
  bool _autoSync = true;
  bool _syncHighlights = true;
  bool _syncReviews = true;
  bool _syncFinished = true;
  bool _periodReview = true;

  String? _keyError;
  String? _keySuccess;
  DateTime? _lastSyncAt;
  int _trackedBooks = 0;
  int _lastImported = 0;
  int _lastFinished = 0;

  WeReadSyncProgress? _progress;
  String? _syncError;

  @override
  void initState() {
    super.initState();
    _loadState();
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    super.dispose();
  }

  Future<void> _loadState() async {
    final apiKey = await _service.getApiKey();
    final autoSync = await _service.isAutoSyncEnabled();
    final syncHighlights = await _service.isHighlightSyncEnabled();
    final syncReviews = await _service.isReviewSyncEnabled();
    final syncFinished = await _service.isFinishedSyncEnabled();
    final periodReview = await _service.isPeriodReviewEnabled();
    final lastSyncAt = await _service.lastSyncAt();
    final tracked = await _service.trackedBookCount();
    final lastImported = await _service.lastImportedCount();
    final lastFinished = await _service.lastFinishedCount();
    if (!mounted) {
      return;
    }
    setState(() {
      _keyConfigured = apiKey != null && apiKey.trim().isNotEmpty;
      _apiKeyController.text = apiKey ?? '';
      _autoSync = autoSync;
      _syncHighlights = syncHighlights;
      _syncReviews = syncReviews;
      _syncFinished = syncFinished;
      _periodReview = periodReview;
      _lastSyncAt = lastSyncAt;
      _trackedBooks = tracked;
      _lastImported = lastImported;
      _lastFinished = lastFinished;
      _loading = false;
    });
  }

  Future<void> _saveAndVerifyKey() async {
    final key = _apiKeyController.text.trim();
    if (key.isEmpty) {
      setState(() {
        _keyError = '请先填入 API Key';
        _keySuccess = null;
      });
      return;
    }

    setState(() {
      _verifying = true;
      _keyError = null;
      _keySuccess = null;
    });

    try {
      final bookCount = await _service.verifyApiKey(key);
      await _service.saveApiKey(key);
      if (!mounted) {
        return;
      }
      setState(() {
        _keyConfigured = true;
        _keySuccess = bookCount == 0
            ? 'API Key 有效，但微信读书里还没有带笔记的书'
            : 'API Key 有效，检测到 $bookCount 本有笔记的书';
      });
    } on WeReadApiException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _keyError = error.message);
    } on Object catch (error) {
      _logger.warning('校验 API Key 失败', data: {'error': '$error'});
      if (!mounted) {
        return;
      }
      setState(() => _keyError = '校验失败：$error');
    } finally {
      if (mounted) {
        setState(() => _verifying = false);
      }
    }
  }

  Future<void> _runSync() async {
    if (_syncing) {
      return;
    }
    if (!_keyConfigured) {
      setState(() => _keyError = '请先填入并保存 API Key');
      return;
    }
    if (!_syncHighlights && !_syncReviews && !_syncFinished && !_periodReview) {
      _showMessage('所有生成项都关掉了，先在下面打开至少一项');
      return;
    }

    setState(() {
      _syncing = true;
      _syncError = null;
      _progress = const WeReadSyncProgress(booksDone: 0, booksTotal: 0);
    });

    final provider = context.read<AppProvider>();

    try {
      final result = await _service.sync(
        persist: provider.createImportedNotes,
        onProgress: (progress) {
          if (mounted) {
            setState(() => _progress = progress);
          }
        },
      );
      await _loadState();
      if (!mounted) {
        return;
      }
      final failureHint =
          result.failures.isEmpty ? '' : '，${result.failures.length} 本失败';
      _showMessage('${result.summary}$failureHint');
    } on WeReadApiException catch (error) {
      if (mounted) {
        setState(() => _syncError = error.message);
      }
    } on Object catch (error) {
      _logger.error('同步失败', error: error);
      if (mounted) {
        setState(() => _syncError = '同步失败：$error');
      }
    } finally {
      if (mounted) {
        setState(() {
          _syncing = false;
          _progress = null;
        });
      }
    }
  }

  Future<void> _resetSyncState() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('重置同步记录？'),
        content: const Text(
          '只会清空「哪本书同步到哪」的进度，已经导入的笔记不会被删除。'
          '下一次同步会重新比对一遍（已存在的笔记不会重复导入）。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('重置'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    await _service.resetSyncState();
    await _loadState();
    if (mounted) {
      _showMessage('同步记录已重置');
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openApiKeyHelp() async {
    final uri = Uri.parse(_apiKeyHelpUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final backgroundColor =
        isDarkMode ? AppTheme.darkBackgroundColor : Colors.white;
    final textColor =
        isDarkMode ? AppTheme.darkTextPrimaryColor : AppTheme.textPrimaryColor;
    final secondaryTextColor = isDarkMode
        ? AppTheme.darkTextSecondaryColor
        : AppTheme.textSecondaryColor;
    final cardColor = isDarkMode ? AppTheme.darkCardColor : Colors.grey[50]!;
    final iconColor =
        isDarkMode ? AppTheme.primaryLightColor : AppTheme.primaryColor;
    final l10n = AppLocalizationsSimple.of(context);

    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(
        leading: IconButton(
          icon: Icon(
            Icons.arrow_back_ios_new,
            color: isDarkMode ? Colors.white : null,
          ),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text(
          l10n?.wereadSync ?? '微信读书笔记同步',
          style: AppTextStyles.custom(
            context,
            17,
            fontWeight: FontWeight.w600,
            color: textColor,
          ),
        ),
        centerTitle: true,
        elevation: 0,
        backgroundColor: backgroundColor,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                _buildIntro(context, secondaryTextColor),
                const SizedBox(height: 16),
                _buildApiKeyCard(
                  context: context,
                  cardColor: cardColor,
                  textColor: textColor,
                  secondaryTextColor: secondaryTextColor,
                  iconColor: iconColor,
                  isDarkMode: isDarkMode,
                ),
                const SizedBox(height: 16),
                _buildSyncOptionsCard(
                  context: context,
                  cardColor: cardColor,
                  textColor: textColor,
                  secondaryTextColor: secondaryTextColor,
                  iconColor: iconColor,
                  isDarkMode: isDarkMode,
                ),
                const SizedBox(height: 16),
                _buildStatusCard(
                  context: context,
                  cardColor: cardColor,
                  textColor: textColor,
                  secondaryTextColor: secondaryTextColor,
                  iconColor: iconColor,
                ),
                const SizedBox(height: 24),
                Center(
                  child: TextButton(
                    onPressed: _syncing ? null : _resetSyncState,
                    child: Text(
                      '重置同步记录',
                      style: TextStyle(color: secondaryTextColor),
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildIntro(BuildContext context, Color secondaryTextColor) => Text(
        '把微信读书里的划线和想法增量拉进来：一条划线一条笔记，带 '
        '#微信读书 与书名标签。同步用确定性 id 去重，重复跑不会产生副本；'
        '你删掉的笔记也不会被下一次同步复活。\n\n'
        '下面每一项都能单独开关，关掉的项同步时不请求、也不生成；重新打开后'
        '会自动补上，已经导入过的不会重复。\n\n'
        '读完的书另外生成一条「读完档案」：封面、读完时间、阅读天数、'
        '累计阅读时长。阅读天数按「开始阅读 → 读完」的自然日跨度算，'
        '所以起止日期会一起写出来。\n\n'
        '实验性功能：走的是微信读书对外开放的接口，可能随时变更或失效；'
        'API Key 只存在本机安全存储，不经过任何第三方服务器。',
        style: AppTextStyles.bodyMedium(
          context,
          color: secondaryTextColor,
        ).copyWith(height: 1.6),
      );

  Widget _buildApiKeyCard({
    required BuildContext context,
    required Color cardColor,
    required Color textColor,
    required Color secondaryTextColor,
    required Color iconColor,
    required bool isDarkMode,
  }) =>
      _SectionCard(
        cardColor: cardColor,
        isDarkMode: isDarkMode,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.key_rounded, size: 20, color: iconColor),
                const SizedBox(width: 8),
                Text(
                  'API Key',
                  style: TextStyle(
                    color: textColor,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                if (_keyConfigured)
                  Row(
                    children: [
                      Icon(
                        Icons.check_circle_rounded,
                        size: 16,
                        color: iconColor,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '已保存',
                        style: TextStyle(color: iconColor, fontSize: 13),
                      ),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _apiKeyController,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              style: TextStyle(color: textColor, fontSize: 14),
              decoration: InputDecoration(
                hintText: 'wrk-xxxxxxxx',
                hintStyle: TextStyle(
                  color: secondaryTextColor.withValues(alpha: 0.6),
                ),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 12,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(
                    color: isDarkMode
                        ? Colors.white.withValues(alpha: 0.16)
                        : Colors.black.withValues(alpha: 0.12),
                  ),
                ),
              ),
            ),
            if (_keyError != null) ...[
              const SizedBox(height: 8),
              _buildHint(_keyError!, const Color(0xFFE5484D)),
            ],
            if (_keySuccess != null) ...[
              const SizedBox(height: 8),
              _buildHint(_keySuccess!, iconColor),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton(
                  onPressed: _verifying ? null : _saveAndVerifyKey,
                  style: FilledButton.styleFrom(
                    backgroundColor: iconColor,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 10,
                    ),
                  ),
                  child: _verifying
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text('保存并验证'),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: _openApiKeyHelp,
                  child: Text(
                    '如何获取',
                    style: TextStyle(color: iconColor, fontSize: 13),
                  ),
                ),
              ],
            ),
          ],
        ),
      );

  Widget _buildSyncOptionsCard({
    required BuildContext context,
    required Color cardColor,
    required Color textColor,
    required Color secondaryTextColor,
    required Color iconColor,
    required bool isDarkMode,
  }) {
    final dividerColor = isDarkMode
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.06);
    return _SectionCard(
      cardColor: cardColor,
      isDarkMode: isDarkMode,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _autoSync,
            activeThumbColor: iconColor,
            title: Text(
              '开 App 时自动同步',
              style: TextStyle(
                color: textColor,
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
            ),
            subtitle: Text(
              '6 小时内不重复请求，只新增不覆盖',
              style: TextStyle(color: secondaryTextColor, fontSize: 12.5),
            ),
            onChanged: (value) async {
              setState(() => _autoSync = value);
              await _service.setAutoSyncEnabled(value);
            },
          ),
          Divider(height: 1, color: dividerColor),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _syncHighlights,
            activeThumbColor: iconColor,
            title: Text(
              '同步划线',
              style: TextStyle(
                color: textColor,
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
            ),
            subtitle: Text(
              '书里划过的原文，一条划线生成一条笔记',
              style: TextStyle(color: secondaryTextColor, fontSize: 12.5),
            ),
            onChanged: (value) async {
              setState(() => _syncHighlights = value);
              await _service.setHighlightSyncEnabled(value);
            },
          ),
          Divider(height: 1, color: dividerColor),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _syncReviews,
            activeThumbColor: iconColor,
            title: Text(
              '同步笔记（想法 / 点评）',
              style: TextStyle(
                color: textColor,
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
            ),
            subtitle: Text(
              '对划线写的想法、整本书评和章节点评，关掉划线时单独成条',
              style: TextStyle(color: secondaryTextColor, fontSize: 12.5),
            ),
            onChanged: (value) async {
              setState(() => _syncReviews = value);
              await _service.setReviewSyncEnabled(value);
            },
          ),
          Divider(height: 1, color: dividerColor),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _syncFinished,
            activeThumbColor: iconColor,
            title: Text(
              '同步阅读完成情况',
              style: TextStyle(
                color: textColor,
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
            ),
            subtitle: Text(
              '读完的书生成一条档案笔记：封面、读完时间、阅读天数',
              style: TextStyle(color: secondaryTextColor, fontSize: 12.5),
            ),
            onChanged: (value) async {
              setState(() => _syncFinished = value);
              await _service.setFinishedSyncEnabled(value);
            },
          ),
          Divider(height: 1, color: dividerColor),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _periodReview,
            activeThumbColor: iconColor,
            title: Text(
              '同步每周和每月回顾',
              style: TextStyle(
                color: textColor,
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
            ),
            subtitle: Text(
              '上一周 / 上个月的阅读情况各生成一条笔记，没读的那期不生成',
              style: TextStyle(color: secondaryTextColor, fontSize: 12.5),
            ),
            onChanged: (value) async {
              setState(() => _periodReview = value);
              await _service.setPeriodReviewEnabled(value);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildStatusCard({
    required BuildContext context,
    required Color cardColor,
    required Color textColor,
    required Color secondaryTextColor,
    required Color iconColor,
  }) =>
      _SectionCard(
        cardColor: cardColor,
        isDarkMode: Theme.of(context).brightness == Brightness.dark,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.sync_rounded, size: 20, color: iconColor),
                const SizedBox(width: 8),
                Text(
                  '同步状态',
                  style: TextStyle(
                    color: textColor,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _buildStatusRow('上次同步', _formatLastSync(), secondaryTextColor),
            _buildStatusRow(
              '覆盖范围',
              _trackedBooks == 0 ? '还没有同步过' : '$_trackedBooks 本书有变更记录',
              secondaryTextColor,
            ),
            _buildStatusRow(
              '上次新增',
              _lastImported == 0 && _lastFinished == 0
                  ? '—'
                  : [
                      if (_lastImported > _lastFinished)
                        '${_lastImported - _lastFinished} 条笔记',
                      if (_lastFinished > 0) '$_lastFinished 本读完档案',
                    ].join(' · '),
              secondaryTextColor,
            ),
            if (_syncing) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(
                value:
                    (_progress?.booksTotal ?? 0) == 0 ? null : _progress!.ratio,
                minHeight: 4,
                backgroundColor: iconColor.withValues(alpha: 0.12),
                valueColor: AlwaysStoppedAnimation<Color>(iconColor),
              ),
              const SizedBox(height: 8),
              _buildHint(_progressText(), secondaryTextColor),
            ],
            if (_syncError != null) ...[
              const SizedBox(height: 12),
              _buildHint(_syncError!, const Color(0xFFE5484D)),
            ],
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _syncing ? null : _runSync,
                style: FilledButton.styleFrom(
                  backgroundColor: iconColor,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                icon: _syncing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.download_rounded, size: 18),
                label: Text(_syncing ? '同步中…' : '立即同步'),
              ),
            ),
          ],
        ),
      );

  Widget _buildStatusRow(String label, String value, Color color) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 76,
              child: Text(
                label,
                style: TextStyle(color: color, fontSize: 13),
              ),
            ),
            Expanded(
              child: Text(
                value,
                style: TextStyle(color: color, fontSize: 13),
              ),
            ),
          ],
        ),
      );

  Widget _buildHint(String text, Color color) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded, size: 14, color: color),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: color, fontSize: 12.5, height: 1.4),
            ),
          ),
        ],
      );

  String _progressText() {
    final progress = _progress;
    final isFinishedPhase = progress?.phase == WeReadSyncPhase.finished;
    if (progress?.phase == WeReadSyncPhase.periodReview) {
      return '正在整理阅读回顾…';
    }
    if (progress == null || progress.booksTotal == 0) {
      return isFinishedPhase ? '正在读取读完书籍…' : '正在拉取笔记本列表…';
    }
    final title = progress.currentBookTitle;
    final base = '${progress.booksDone}/${progress.booksTotal}';
    final action = isFinishedPhase ? '正在整理读完档案' : '正在处理';
    return title == null || title.isEmpty
        ? '$action $base'
        : '$action $base · 《$title》';
  }

  String _formatLastSync() {
    final last = _lastSyncAt;
    if (last == null) {
      return '从未同步';
    }
    final now = DateTime.now();
    final diff = now.difference(last);
    if (diff.inMinutes < 1) {
      return '刚刚';
    }
    if (diff.inHours < 1) {
      return '${diff.inMinutes} 分钟前';
    }
    if (diff.inDays < 1) {
      return '${diff.inHours} 小时前';
    }
    if (diff.inDays < 30) {
      return '${diff.inDays} 天前';
    }
    String two(int value) => value.toString().padLeft(2, '0');
    return '${last.year}-${two(last.month)}-${two(last.day)} '
        '${two(last.hour)}:${two(last.minute)}';
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.child,
    required this.cardColor,
    required this.isDarkMode,
    this.padding = const EdgeInsets.all(16),
  });

  final Widget child;
  final Color cardColor;
  final bool isDarkMode;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Container(
        padding: padding,
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isDarkMode
                ? Colors.white.withValues(alpha: 0.1)
                : Colors.black.withValues(alpha: 0.05),
          ),
        ),
        child: child,
      );
}
