import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:inkpaper/providers/app_provider.dart';
import 'package:inkpaper/utils/snackbar_utils.dart';
import 'package:provider/provider.dart';

class AccountDeletionScreen extends StatefulWidget {
  const AccountDeletionScreen({super.key});

  @override
  State<AccountDeletionScreen> createState() => _AccountDeletionScreenState();
}

class _AccountDeletionScreenState extends State<AccountDeletionScreen> {
  bool _isClearingLocalData = false;

  bool get _isZh => Localizations.localeOf(context).languageCode == 'zh';

  String get _title => _isZh ? '账号与数据删除' : 'Account and Data Deletion';

  String get _localClearTitle =>
      _isZh ? '删除本机数据' : 'Delete data on this device';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appProvider = context.watch<AppProvider>();
    final user = appProvider.user;
    final serverUrl =
        user?.serverUrl ?? appProvider.appConfig.memosApiUrl ?? '';

    return Scaffold(
      appBar: AppBar(
        title: Text(_title),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          _InfoPanel(
            icon: Icons.verified_user_outlined,
            title: _isZh ? '删除范围说明' : 'Deletion scope',
            body: _isZh
                ? '你可以在这里删除本机笔记、图片缓存、登录凭证和应用设置。Memos、WebDAV、AI 服务中的数据由对应服务保存，需要在相应服务中删除。'
                : 'You can delete local notes, image cache, login credentials, and app settings here. Data stored in Memos, WebDAV, or AI services must be deleted in those services.',
          ),
          const SizedBox(height: 12),
          _SectionCard(
            title: _isZh ? '当前状态' : 'Current status',
            children: [
              _StatusRow(
                label: _isZh ? '登录账号' : 'Account',
                value: user == null
                    ? (_isZh ? '未登录 / 本地模式' : 'Not signed in / local mode')
                    : user.username,
              ),
              _StatusRow(
                label: _isZh ? '服务器' : 'Server',
                value: serverUrl.isEmpty
                    ? (_isZh ? '未连接' : 'Not connected')
                    : serverUrl,
              ),
            ],
          ),
          const SizedBox(height: 12),
          _SectionCard(
            title: _localClearTitle,
            children: [
              Text(
                _isZh
                    ? '删除本机数据会清空设备上的笔记数据库、提醒记录、账号信息和安全凭证。此操作不会删除 Memos、WebDAV、AI 或其他第三方服务中的远端数据。'
                    : 'Deleting local data clears notes, reminder records, account information, and secure credentials on this device. This does not delete remote data stored in Memos, WebDAV, AI, or other third-party services.',
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed:
                    _isClearingLocalData ? null : _confirmAndClearLocalData,
                icon: _isClearingLocalData
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.delete_outline_rounded),
                label: Text(
                  _isClearingLocalData
                      ? (_isZh ? '正在删除...' : 'Deleting...')
                      : _localClearTitle,
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.red.shade600,
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _InfoPanel(
            icon: Icons.info_outline_rounded,
            title: _isZh ? '删除前建议' : 'Before deleting',
            body: _isZh
                ? '如需保留资料，请先在导入导出或 WebDAV 备份中完成备份。删除本机数据后，部分内容可能无法恢复。'
                : 'Export or back up important data before deleting. Some content may not be recoverable after local data deletion.',
          ),
        ],
      ),
    );
  }

  Future<void> _confirmAndClearLocalData() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(_localClearTitle),
        content: Text(
          _isZh
              ? '此操作会删除本机保存的笔记、提醒、登录凭证和应用数据。远端服务器数据不会被删除。确定继续吗？'
              : 'This will delete notes, reminders, login credentials, and app data stored on this device. Remote server data will not be deleted. Continue?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(_isZh ? '取消' : 'Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red.shade600,
              foregroundColor: Colors.white,
            ),
            child: Text(_isZh ? '删除本机数据' : 'Delete local data'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) {
      return;
    }

    setState(() => _isClearingLocalData = true);
    try {
      final appProvider = context.read<AppProvider>();
      final (success, message) = await appProvider.logout(
        force: true,
        keepLocalData: false,
      );
      if (!mounted) {
        return;
      }
      if (success) {
        SnackBarUtils.showSuccess(
          context,
          _isZh ? '本机数据已删除' : 'Local data deleted',
        );
        context.go('/login');
      } else {
        SnackBarUtils.showError(
          context,
          message ?? (_isZh ? '删除失败' : 'Deletion failed'),
        );
      }
    } on Object catch (e) {
      if (mounted) {
        SnackBarUtils.showError(
          context,
          '${_isZh ? '删除失败' : 'Deletion failed'}: $e',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isClearingLocalData = false);
      }
    }
  }
}

class _InfoPanel extends StatelessWidget {
  const _InfoPanel({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.primary;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  body,
                  style: theme.textTheme.bodyMedium?.copyWith(height: 1.55),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.children,
  });

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: theme.dividerColor.withValues(alpha: 0.5),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 88,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.textTheme.bodySmall?.color,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
