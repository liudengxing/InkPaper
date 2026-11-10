import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:inkpaper/config/app_config.dart';
import 'package:inkpaper/l10n/app_localizations_simple.dart';
import 'package:inkpaper/services/update_check_service.dart';
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
    final isDesktop = !kIsWeb && (Platform.isMacOS || Platform.isWindows);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: isDesktop
            ? null
            : IconButton(
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
            // 应用信息
            Container(
              margin: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              padding: const EdgeInsets.all(30),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF2C9678), Color(0xFF46B696)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF2C9678).withValues(alpha: 0.2),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Stack(
                children: [
                  // 背景装饰
                  Positioned(
                    top: -20,
                    right: -20,
                    child: Opacity(
                      opacity: 0.1,
                      child: Container(
                        width: 120,
                        height: 120,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),

                  // 内容
                  Column(
                    children: [
                      // Logo
                      Container(
                        width: 80,
                        height: 80,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.15),
                              blurRadius: 12,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Image.asset(
                            'assets/images/logo.png',
                            // A-14：按显示尺寸解码，避免整图进内存
                            cacheWidth:
                                (96 * MediaQuery.devicePixelRatioOf(context))
                                    .round(),
                            fit: BoxFit.contain,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        AppConfig.appName,
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${AppLocalizationsSimple.of(context)?.version ?? '版本'} ${AppConfig.appVersion}',
                        style: const TextStyle(
                          fontSize: 16,
                          color: Colors.white,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        AppLocalizationsSimple.of(context)?.appTagline ??
                            '记录是为了成为更好的自己',
                        style: const TextStyle(
                          fontSize: 15,
                          color: Colors.white,
                          height: 1.6,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // 应用介绍
            Container(
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: theme.cardColor,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 10,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.info_outline,
                        color: theme.primaryColor,
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        AppLocalizationsSimple.of(context)?.aboutInkPaper ??
                            '关于InkPaper',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: theme.primaryColor,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    AppLocalizationsSimple.of(context)?.appIntroduction ??
                        'InkPaper-墨鸣笔记是一款面向个人记录与知识沉淀的跨平台笔记应用。它保留轻量记录的速度，也提供标签、搜索、回顾、备份和同步能力，让零散内容逐步沉淀成可回看的资料库。',
                    style: const TextStyle(
                      fontSize: 15,
                      height: 1.6,
                      color: Color(0xFF666666),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    AppLocalizationsSimple.of(context)?.technicalDetails ??
                        '当前支持 Android、iOS、macOS、Windows 和 Linux。应用提供富文本式编辑、Markdown 渲染、图片、标签、搜索、提醒、随机回顾、WebDAV 备份、导入导出和可选 AI 功能。',
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
              decoration: BoxDecoration(
                color: theme.cardColor,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 10,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.star_outline,
                        color: theme.primaryColor,
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        AppLocalizationsSimple.of(context)?.coreFeaturesTitle ??
                            '核心功能',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: theme.primaryColor,
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
              decoration: BoxDecoration(
                color: theme.cardColor,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 10,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.phone_outlined,
                        color: theme.primaryColor,
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        AppLocalizationsSimple.of(context)?.contactUs ?? '联系我们',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: theme.primaryColor,
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
                    onTap: () => _launchURL('mailto:${AppConfig.supportEmail}'),
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

  Widget _buildFeatureTag(BuildContext context, String label, IconData icon) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Theme.of(context).primaryColor.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 14,
              color: Theme.of(context).primaryColor,
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: Theme.of(context).primaryColor,
              ),
            ),
          ],
        ),
      );

  Widget _buildContactItem(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String value,
    required VoidCallback onTap,
  }) =>
      InkWell(
        onTap: onTap,
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: Theme.of(context).primaryColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                icon,
                size: 20,
                color: Theme.of(context).primaryColor,
              ),
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

/// 关于页底部：本地版本号 + 「检查更新」。
///
/// 检查走 GitHub Release 的 `releases/latest`，拿到 tag 与本机版本比大小；
/// 有新版本时弹出说明，并直接指向 Release 里的 APK。
class _UpdateCheckFooter extends StatefulWidget {
  const _UpdateCheckFooter();

  @override
  State<_UpdateCheckFooter> createState() => _UpdateCheckFooterState();
}

class _UpdateCheckFooterState extends State<_UpdateCheckFooter> {
  final UpdateCheckService _service = UpdateCheckService();
  bool _checking = false;

  @override
  void dispose() {
    _service.dispose();
    super.dispose();
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
      if (!mounted) {
        return;
      }
      if (result.hasUpdate) {
        await _showUpdateDialog(result);
      } else {
        _showMessage('已是最新版本 v${result.currentVersion}');
      }
    } on UpdateCheckException catch (e) {
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

  Future<void> _showUpdateDialog(UpdateCheckResult result) {
    final notes = result.releaseNotes;
    final size = _formatSize(result.apkSizeBytes);
    final published = result.publishedAt;

    return showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('发现新版本 ${result.latestVersion}'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '当前版本 ${result.currentVersion}'
                '${size == null ? '' : ' · 安装包 $size'}',
                style: const TextStyle(fontSize: 13, color: Color(0xFF888888)),
              ),
              if (published != null) ...[
                const SizedBox(height: 4),
                Text(
                  '发布于 ${_formatDate(published)}',
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFF888888),
                  ),
                ),
              ],
              if (notes.isNotEmpty) ...[
                const SizedBox(height: 16),
                const Text(
                  '更新内容',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 240),
                  child: SingleChildScrollView(
                    child: Text(
                      notes,
                      style: const TextStyle(fontSize: 13, height: 1.5),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              _openDownload(result);
            },
            child: Text(result.apkDownloadUrl == null ? '前往发布页' : '下载安装包'),
          ),
        ],
      ),
    );
  }

  Future<void> _openDownload(UpdateCheckResult result) async {
    final uri = result.downloadUrl;
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched && mounted) {
      _showMessage('无法打开链接，请手动访问 $uri');
    }
  }

  static String? _formatSize(int? bytes) {
    if (bytes == null || bytes <= 0) {
      return null;
    }
    final mb = bytes / (1024 * 1024);
    return '${mb.toStringAsFixed(1)} MB';
  }

  static String _formatDate(DateTime time) {
    final local = time.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)}';
  }

  @override
  Widget build(BuildContext context) {
    final primaryColor = Theme.of(context).primaryColor;
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
            icon: _checking
                ? SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: primaryColor,
                    ),
                  )
                : const Icon(Icons.system_update_alt, size: 16),
            label: Text(
              _checking ? '检查中…' : '检查更新',
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
