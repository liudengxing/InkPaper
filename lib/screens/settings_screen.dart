import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:inkpaper/l10n/app_localizations_simple.dart';
import 'package:inkpaper/themes/app_theme.dart';
import 'package:inkpaper/utils/responsive_utils.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _isZh(BuildContext context) =>
      Localizations.localeOf(context).languageCode == 'zh';

  @override
  Widget build(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final backgroundColor =
        isDarkMode ? AppTheme.darkBackgroundColor : Colors.white;
    final textColor =
        isDarkMode ? AppTheme.darkTextPrimaryColor : AppTheme.textPrimaryColor;
    final l10n = AppLocalizationsSimple.of(context);

    // 移动端: 原有的列表布局
    final maxWidth = ResponsiveUtils.getMaxContentWidth(context);
    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(
        leading: IconButton(
          icon: Icon(
            Icons.close,
            color: isDarkMode ? Colors.white : null,
          ),
          onPressed: () => context.pop(),
        ),
        title: Text(
          l10n?.settings ?? '设置',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w500,
            color: textColor,
          ),
        ),
        elevation: 0,
      ),
      body: Center(
        child: Container(
          constraints: BoxConstraints(
            maxWidth: maxWidth,
          ),
          child: ListView(
            children: [
              // 顶部标语
              Container(
                padding: ResponsiveUtils.responsivePadding(
                  context,
                  vertical: 20,
                  horizontal: 16,
                ),
                // 整句一次排版：前半正常色、后半主题色，允许换行不截断
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: l10n?.waitPatiently ?? '记录是为了',
                        style: TextStyle(color: textColor),
                      ),
                      TextSpan(
                        text: l10n?.poiseToResound ?? '成为更好的自己',
                        style: TextStyle(
                          color: isDarkMode
                              ? AppTheme.primaryLightColor
                              : AppTheme.primaryColor,
                        ),
                      ),
                    ],
                  ),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: ResponsiveUtils.responsiveFontSize(context, 26),
                    fontWeight: FontWeight.w600,
                    height: 1.3,
                  ),
                ),
              ),

              // 账户与连接
              _buildSectionHeader(
                context,
                l10n?.settingsAccountAndConnection ?? '账户与连接',
                isDarkMode,
                textColor,
              ),
              _buildSettingsItem(
                context,
                icon: Icons.account_circle,
                title: _isZh(context) ? '账号与同步' : 'Account & Sync',
                onTap: () => context.push('/account-info'),
              ),

              // 通用设置
              _buildSectionHeader(
                context,
                l10n?.settingsGeneral ?? '通用',
                isDarkMode,
                textColor,
              ),
              _buildSettingsItem(
                context,
                icon: Icons.settings,
                title: l10n?.preferences ?? '偏好设置',
                onTap: () => context.push('/preferences'),
              ),
              _buildSettingsItem(
                context,
                icon: Icons.psychology,
                title: l10n?.aiSettings ?? 'AI 助手',
                onTap: () => context.push('/ai-settings'),
              ),

              // 数据管理
              _buildSectionHeader(
                context,
                l10n?.settingsDataManagement ?? '数据管理',
                isDarkMode,
                textColor,
              ),
              _buildSettingsItem(
                context,
                icon: Icons.import_export,
                title: l10n?.importExport ?? '导入导出',
                onTap: () => context.push('/settings/import-export'),
              ),
              _buildSettingsItem(
                context,
                icon: Icons.cloud_sync,
                title: AppLocalizationsSimple.of(context)?.webdavSync ??
                    'WebDAV 同步',
                onTap: () => context.push('/webdav-settings'),
              ),
              _buildSettingsItem(
                context,
                icon: Icons.drafts_outlined,
                title: '草稿箱',
                onTap: () => context.push('/draft-box'),
              ),
              _buildSettingsItem(
                context,
                icon: Icons.cleaning_services,
                title: l10n?.dataCleanup ?? '数据清理',
                onTap: () => context.push('/data-cleanup'),
              ),

              // 高级
              _buildSectionHeader(
                context,
                l10n?.advancedSettings ?? '高级',
                isDarkMode,
                textColor,
              ),
              _buildSettingsItem(
                context,
                icon: Icons.science,
                title: l10n?.laboratory ?? '实验室',
                onTap: () => context.push('/laboratory'),
              ),

              // 支持
              _buildSectionHeader(
                context,
                l10n?.settingsSupport ?? '支持',
                isDarkMode,
                textColor,
              ),
              _buildSettingsItem(
                context,
                icon: Icons.feedback_rounded,
                title: l10n?.feedback ?? '意见反馈',
                onTap: () => context.push('/feedback'),
              ),
              _buildSettingsItem(
                context,
                icon: Icons.help,
                title: l10n?.help ?? '帮助',
                onTap: () => context.push('/settings/help'),
              ),
              _buildSettingsItem(
                context,
                icon: Icons.info,
                title: l10n?.about ?? '关于',
                onTap: () => context.push('/settings/about'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHeader(
    BuildContext context,
    String title,
    bool isDarkMode,
    Color textColor,
  ) =>
      Padding(
        padding: const EdgeInsets.only(left: 16, right: 16, top: 20, bottom: 4),
        child: Text(
          title,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: isDarkMode ? Colors.grey[400] : Colors.grey[600],
            letterSpacing: 0.5,
          ),
        ),
      );

  Widget _buildSettingsItem(
    BuildContext context, {
    required IconData icon,
    required String title,
    required VoidCallback onTap,
    String? subtitle,
  }) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final iconColor =
        isDarkMode ? AppTheme.darkTextPrimaryColor : Colors.black87;
    final textColor = isDarkMode ? AppTheme.darkTextPrimaryColor : null;
    final arrowColor = isDarkMode ? Colors.grey[400] : Colors.grey;
    final content = Row(
      children: [
        Icon(
          icon,
          size: ResponsiveUtils.responsiveIconSize(context, 24),
          color: iconColor,
        ),
        SizedBox(width: ResponsiveUtils.responsiveSpacing(context, 16)),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: ResponsiveUtils.responsiveFontSize(context, 16),
                  color: textColor,
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: ResponsiveUtils.responsiveFontSize(context, 12),
                    color: isDarkMode ? Colors.grey[400] : Colors.grey[600],
                  ),
                ),
              ],
            ],
          ),
        ),
        Icon(
          Icons.chevron_right,
          color: arrowColor,
          size: ResponsiveUtils.responsiveIconSize(context, 20),
        ),
      ],
    );

    // 移动端: 使用列表样式
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: ResponsiveUtils.responsivePadding(
          context,
          horizontal: 16,
          vertical: 16,
        ),
        child: content,
      ),
    );
  }
}
