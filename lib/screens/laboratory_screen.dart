import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:inkpaper/l10n/app_localizations_simple.dart';
import 'package:inkpaper/themes/app_theme.dart';
import 'package:inkpaper/utils/text_style_helper.dart';
import 'package:url_launcher/url_launcher.dart';

/// 实验室
/// 收纳实验性或面向进阶用户的功能入口
class LaboratoryScreen extends StatelessWidget {
  const LaboratoryScreen({super.key});

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
        automaticallyImplyLeading: false,
        leading: IconButton(
          icon: Icon(
            Icons.arrow_back_ios_new,
            color: isDarkMode ? Colors.white : null,
          ),
          onPressed: () => context.pop(),
        ),
        title: Text(
          l10n?.laboratory ?? '实验室',
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
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            l10n?.featureInDevelopment ?? '实验室功能正在重新整理，稳定后会在这里开放。',
            style: AppTextStyles.bodyMedium(
              context,
              color: secondaryTextColor,
            ).copyWith(height: 1.5),
          ),
          const SizedBox(height: 16),

          // Notion 同步
          _buildOptionCard(
            context: context,
            cardColor: cardColor,
            textColor: textColor,
            secondaryTextColor: secondaryTextColor,
            iconColor: iconColor,
            icon: Icons.sync_rounded,
            title: l10n?.notionSync ?? 'Notion 同步',
            description:
                l10n?.notionSyncDescription ?? '将笔记同步到 Notion，支持双向同步和自动同步',
            onTap: () {
              context.push('/settings/notion-settings');
            },
          ),

          const SizedBox(height: 16),

          // Obsidian 同步
          _buildOptionCard(
            context: context,
            cardColor: cardColor,
            textColor: textColor,
            secondaryTextColor: secondaryTextColor,
            iconColor: iconColor,
            icon: Icons.description_rounded,
            title: l10n?.obsidianSync ?? 'Obsidian 数据同步',
            description: l10n?.obsidianSyncDescription ??
                '通过第三方插件连接 Obsidian，具体同步方向、冲突处理和每日笔记能力以插件配置为准',
            onTap: () async {
              final url = Uri.parse(
                'https://github.com/RyoJerryYu/obsidian-memos-sync',
              );
              if (await canLaunchUrl(url)) {
                await launchUrl(url, mode: LaunchMode.externalApplication);
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _buildOptionCard({
    required BuildContext context,
    required Color cardColor,
    required Color textColor,
    required Color secondaryTextColor,
    required Color iconColor,
    required IconData icon,
    required String title,
    required String description,
    required VoidCallback onTap,
  }) =>
      Card(
        color: cardColor,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: Theme.of(context).brightness == Brightness.dark
                ? Colors.white.withValues(alpha: 0.1)
                : Colors.black.withValues(alpha: 0.05),
          ),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: iconColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    icon,
                    color: iconColor,
                    size: 28,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          color: textColor,
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        description,
                        style: TextStyle(
                          color: secondaryTextColor,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  color: secondaryTextColor,
                ),
              ],
            ),
          ),
        ),
      );
}
