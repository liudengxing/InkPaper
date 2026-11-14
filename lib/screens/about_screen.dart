import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:inkpaper/config/app_config.dart';
import 'package:inkpaper/l10n/app_localizations_simple.dart';
import 'package:inkpaper/services/app_info_service.dart';
import 'package:inkpaper/services/update_check_diagnostics.dart';
import 'package:inkpaper/services/update_check_service.dart';
import 'package:inkpaper/themes/app_theme.dart';
import 'package:inkpaper/widgets/update_dialog.dart';
import 'package:url_launcher/url_launcher.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  Future<void> _launchURL(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 卡片与文字对齐首页列表：白底细灰描边 + 次级灰，不再出现品牌绿
    final isDarkMode = theme.brightness == Brightness.dark;
    final secondaryTextColor = isDarkMode
        ? AppTheme.darkTextSecondaryColor
        : AppTheme.textSecondaryColor;
    final borderColor = isDarkMode
        ? Colors.white.withValues(alpha: 0.06)
        : Colors.black.withValues(alpha: 0.05);
    final cardDecoration = BoxDecoration(
      color: theme.cardColor,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: borderColor, width: 0.5),
    );
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
        title: Text(
          AppLocalizationsSimple.of(context)?.aboutUs ?? '关于 InkPaper',
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w500),
        ),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            // 应用介绍
            Container(
              margin: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              padding: const EdgeInsets.all(24),
              decoration: cardDecoration,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.info_outline,
                        color: secondaryTextColor,
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        AppLocalizationsSimple.of(context)?.aboutInkPaper ??
                            '关于InkPaper',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: secondaryTextColor,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    AppLocalizationsSimple.of(context)?.appIntroduction ??
                        'InkPaper-墨鸣笔记是一款面向个人记录与知识沉淀的 Android 笔记应用。它保留轻量记录的速度，也提供标签、搜索、回顾、备份和同步能力，让零散内容逐步沉淀成可回看的资料库。',
                    style: const TextStyle(
                      fontSize: 15,
                      height: 1.6,
                      color: Color(0xFF666666),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    AppLocalizationsSimple.of(context)?.technicalDetails ??
                        '当前只发布 Android 版本。应用提供富文本式编辑、Markdown 渲染、图片、标签、搜索、提醒、随机回顾、WebDAV 备份、导入导出和可选 AI 功能。',
                    style: const TextStyle(
                      fontSize: 15,
                      height: 1.6,
                      color: Color(0xFF666666),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    AppLocalizationsSimple.of(context)?.securityCommitment ??
                        '笔记优先保存在本机。登录、同步、WebDAV 和 AI 相关配置由你主动设置；自部署服务中的数据由对应服务器保存和管理。',
                    style: const TextStyle(
                      fontSize: 15,
                      height: 1.6,
                      color: Color(0xFF666666),
                    ),
                  ),
                ],
              ),
            ),

            // 核心功能
            Container(
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              padding: const EdgeInsets.all(24),
              decoration: cardDecoration,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.star_outline,
                        color: secondaryTextColor,
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        AppLocalizationsSimple.of(context)?.coreFeaturesTitle ??
                            '核心功能',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: secondaryTextColor,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    AppLocalizationsSimple.of(context)?.appTechDescription ??
                        '这些是当前版本已经开放的主要能力。不同 Memos 服务器版本的接口能力不同，应用会按服务器版本自动适配并尽量降级处理。',
                    style: const TextStyle(
                      fontSize: 15,
                      height: 1.6,
                      color: Color(0xFF666666),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      _buildFeatureTag(
                        context,
                        AppLocalizationsSimple.of(context)
                                ?.memosExclusiveVersion ??
                            'Memos 多版本适配',
                        Icons.verified_outlined,
                      ),
                      _buildFeatureTag(
                        context,
                        '自部署 Memos',
                        Icons.cloud_queue_outlined,
                      ),
                      _buildFeatureTag(
                        context,
                        AppLocalizationsSimple.of(context)?.markdownSupport ??
                            'Markdown支持',
                        Icons.code,
                      ),
                      _buildFeatureTag(
                        context,
                        AppLocalizationsSimple.of(context)
                                ?.intelligentTagSystem ??
                            '层级标签',
                        Icons.local_offer_outlined,
                      ),
                      _buildFeatureTag(
                        context,
                        AppLocalizationsSimple.of(context)?.fullTextSearch ??
                            '全文搜索',
                        Icons.search_outlined,
                      ),
                      _buildFeatureTag(
                        context,
                        AppLocalizationsSimple.of(context)
                                ?.randomReviewFeature ??
                            '随机回顾',
                        Icons.shuffle_outlined,
                      ),
                      _buildFeatureTag(
                        context,
                        AppLocalizationsSimple.of(context)?.dataStatistics ??
                            '数据统计',
                        Icons.analytics_outlined,
                      ),
                      _buildFeatureTag(
                        context,
                        AppLocalizationsSimple.of(context)?.realtimeSync ??
                            '实时同步',
                        Icons.sync_outlined,
                      ),
                      _buildFeatureTag(
                        context,
                        AppLocalizationsSimple.of(context)?.localEncryption ??
                            '本地加密',
                        Icons.security_outlined,
                      ),
                      _buildFeatureTag(
                        context,
                        AppLocalizationsSimple.of(context)?.multiTheme ??
                            '多主题切换',
                        Icons.palette_outlined,
                      ),
                      _buildFeatureTag(
                        context,
                        '移动端和桌面端',
                        Icons.devices_outlined,
                      ),
                      _buildFeatureTag(
                        context,
                        AppLocalizationsSimple.of(context)?.offlineUse ??
                            '离线使用',
                        Icons.offline_bolt_outlined,
                      ),
                      _buildFeatureTag(
                        context,
                        AppLocalizationsSimple.of(context)?.dataExport ??
                            '数据导出',
                        Icons.download_outlined,
                      ),
                      _buildFeatureTag(
                        context,
                        AppLocalizationsSimple.of(context)?.imageManagement ??
                            '图片管理',
                        Icons.image_outlined,
                      ),
                      _buildFeatureTag(
                        context,
                        AppLocalizationsSimple.of(context)?.privateDeployment ??
                            '私有化部署',
                        Icons.cloud_outlined,
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // 联系方式
            Container(
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              padding: const EdgeInsets.all(24),
              decoration: cardDecoration,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.phone_outlined,
                        color: secondaryTextColor,
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        AppLocalizationsSimple.of(context)?.contactUs ?? '联系我们',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: secondaryTextColor,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    AppLocalizationsSimple.of(context)?.contactMessage ??
                        '我们非常重视用户的反馈和建议。如果您有任何问题、意见或合作意向，请随时与我们联系。',
                    style: const TextStyle(
                      fontSize: 15,
                      height: 1.6,
                      color: Color(0xFF666666),
                    ),
                  ),
                  const SizedBox(height: 16),
                  _buildContactItem(
                    context,
                    icon: Icons.email_outlined,
                    label: AppLocalizationsSimple.of(context)?.emailAddress ??
                        '电子邮件',
                    value: AppConfig.supportEmail,
                    onTap: () => context.push('/feedback'),
                  ),
                  const Divider(height: 24),
                  _buildContactItem(
                    context,
                    icon: Icons.code_outlined,
                    label: AppLocalizationsSimple.of(context)?.openSourceRepo ??
                        '开源仓库',
                    value: AppConfig.githubRepo,
                    onTap: () => _launchURL(AppConfig.githubRepo),
                  ),
                  const Divider(height: 24),
                  _buildContactItem(
                    context,
                    icon: Icons.feedback_outlined,
                    label:
                        AppLocalizationsSimple.of(context)?.feedback ?? '意见反馈',
                    value: '问题和建议直达',
                    onTap: () => context.push('/feedback'),
                  ),
                ],
              ),
            ),

            // 底部：版本号 + 检查更新（数据源是 GitHub Release）
            const _UpdateCheckFooter(),
          ],
        ),
      ),
    );
  }

  Widget _buildFeatureTag(BuildContext context, String label, IconData icon) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final fill = isDarkMode
        ? Colors.white.withValues(alpha: 0.06)
        : Colors.black.withValues(alpha: 0.04);
    final textColor = isDarkMode
        ? AppTheme.darkTextSecondaryColor
        : AppTheme.textSecondaryColor;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 14,
            color: textColor,
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: textColor,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContactItem(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String value,
    required VoidCallback onTap,
  }) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final iconColor = isDarkMode
        ? AppTheme.darkTextSecondaryColor
        : AppTheme.textSecondaryColor;
    return InkWell(
      onTap: onTap,
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: isDarkMode
                  ? Colors.white.withValues(alpha: 0.06)
                  : Colors.black.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 20, color: iconColor),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 14,
                    color: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.color
                        ?.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 关于页底部：本地版本号 + 「检查更新」+ 上次检查结论。
///
/// 检查走 Gitee 优先、GitHub 兜底的 `releases/latest`，拿到 tag 与本机版本比
/// 大小；有新版本时弹出统一的更新弹窗 —— 下载进度、取消、重试、拉起系统安装
/// 器都在那个弹窗里完成，不再把用户丢给浏览器。
///
/// 最下面那行是诊断：开屏检查有五道闸（首启、节流、网络失败、版本没变、
/// 点过稍后再说），命中任何一道都静默跳过，用户只会觉得「怎么不提示我」。
/// 把上次结论摆出来，这类问题就不用再靠猜。
class _UpdateCheckFooter extends StatefulWidget {
  const _UpdateCheckFooter();

  @override
  State<_UpdateCheckFooter> createState() => _UpdateCheckFooterState();
}

class _UpdateCheckFooterState extends State<_UpdateCheckFooter> {
  final UpdateCheckService _service = UpdateCheckService();
  bool _checking = false;
  UpdateCheckDiagnostics _diagnostics = const UpdateCheckDiagnostics();

  @override
  void initState() {
    super.initState();
    unawaited(_refreshDiagnostics());
  }

  @override
  void dispose() {
    _service.dispose();
    super.dispose();
  }

  Future<void> _refreshDiagnostics() async {
    final snapshot = await UpdateCheckDiagnostics.load();
    if (!mounted) {
      return;
    }
    setState(() => _diagnostics = snapshot);
  }

  void _showMessage(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _checkForUpdates() async {
    if (_checking) {
      return;
    }
    setState(() => _checking = true);
    try {
      final result = await _service.check();
      // 手动点的这一轮也要留痕，否则诊断里会一直显示上一条旧结论。
      await UpdateCheckDiagnostics.recordSuccess(result, auto: false);
      await _refreshDiagnostics();
      if (!mounted) {
        return;
      }
      if (result.hasUpdate) {
        await showUpdateDialog(
          context,
          result,
          onPostpone: () => unawaited(
            UpdateCheckDiagnostics.recordSkipped(result.latestVersion),
          ),
        );
      } else {
        _showMessage('已是最新版本 v${result.currentVersion}');
      }
    } on UpdateCheckException catch (e) {
      await UpdateCheckDiagnostics.recordFailure(
        e.message,
        auto: false,
        currentVersion: AppInfoService.version,
      );
      await _refreshDiagnostics();
      if (!mounted) {
        return;
      }
      _showMessage('检查更新失败：${e.message}');
    } finally {
      if (mounted) {
        setState(() => _checking = false);
      }
    }
  }

  Future<void> _clearSkipped() async {
    await UpdateCheckDiagnostics.clearSkipped();
    await _refreshDiagnostics();
    if (!mounted) {
      return;
    }
    _showMessage('已恢复提醒，下次检查会重新提示这个版本');
  }

  @override
  Widget build(BuildContext context) {
    final accentColor = Theme.of(context).brightness == Brightness.dark
        ? AppTheme.darkTextSecondaryColor
        : AppTheme.textSecondaryColor;
    final skippedHint = _diagnostics.skippedHint;
    return Container(
      margin: const EdgeInsets.only(bottom: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '版本 ${AppConfig.getFullVersionInfo()}',
            style: const TextStyle(fontSize: 13, color: Color(0xFF999999)),
          ),
          TextButton.icon(
            onPressed: _checking ? null : _checkForUpdates,
            style: TextButton.styleFrom(foregroundColor: accentColor),
            icon: _checking
                ? SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: accentColor,
                    ),
                  )
                : const Icon(Icons.system_update_alt, size: 16),
            label: Text(
              _checking ? '检查中…' : '检查更新',
              style: TextStyle(fontSize: 13, color: accentColor),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              _diagnostics.describe(currentVersion: AppInfoService.version),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11, color: Color(0xFF9E9E9E)),
            ),
          ),
          if (skippedHint != null)
            TextButton(
              onPressed: _clearSkipped,
              style: TextButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                '$skippedHint · 恢复提醒',
                style: const TextStyle(fontSize: 11, color: Color(0xFF9E9E9E)),
              ),
            ),
        ],
      ),
    );
  }
}
