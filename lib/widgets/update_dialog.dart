import 'dart:io' show File, Platform;

import 'package:flutter/material.dart';
import 'package:inkpaper/services/apk_install_service.dart';
import 'package:inkpaper/services/update_check_service.dart';
import 'package:inkpaper/services/update_download_service.dart';
import 'package:inkpaper/services/update_installer.dart';
import 'package:inkpaper/themes/app_theme.dart';
import 'package:url_launcher/url_launcher.dart';

/// 弹出版本更新提示，下载进度直接在弹窗里滚动。
///
/// 开屏自动检查与关于页手动检查都走这一个弹窗，弹窗内自己做「下载 → 拉起
/// 系统安装器」，不再把用户丢给浏览器 —— 之前那条链路是：页面底部悄悄显示
/// 一条细进度条，下完弹一个 SnackBar，用户体感就是「下完了什么也没发生」。
///
/// [onPostpone] 在用户点「稍后再说」或直接返回时调用，用来记住「这个版本先
/// 不打扰」，下次启动不再重复弹。
Future<void> showUpdateDialog(
  BuildContext context,
  UpdateCheckResult result, {
  VoidCallback? onPostpone,
}) async {
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _UpdateDialog(result: result, onPostpone: onPostpone),
  );
}

/// 弹窗当前处在哪一步。
enum _UpdatePhase {
  /// 还没开始：展示版本说明与「立即更新」
  prompt,

  /// 正在下载安装包
  downloading,

  /// 下载好了，正在拉起系统安装器
  installing,

  /// 系统安装界面已经弹出来了，后面归用户
  launched,

  /// 下载失败、缺少「安装未知应用」授权、或者安装器拉不起来
  blocked,
}

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog({required this.result, this.onPostpone});

  final UpdateCheckResult result;
  final VoidCallback? onPostpone;

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog>
    with WidgetsBindingObserver {
  final UpdateInstaller _installer = UpdateInstaller();

  _UpdatePhase _phase = _UpdatePhase.prompt;
  UpdateDownloadProgress? _progress;
  String? _error;
  File? _apk;

  /// 刚才是因为缺「安装未知应用」授权被打断的：用户从设置页回来后自动续上。
  bool _awaitingPermission = false;
  bool _postponeNotified = false;

  /// 下载速度（字节/秒），用相邻两次采样的增量平滑出来。
  double? _speed;
  DateTime? _lastSampleAt;
  int _lastSampleBytes = 0;
  DateTime _lastPaintAt = DateTime.fromMillisecondsSinceEpoch(0);

  static const Duration _sampleInterval = Duration(milliseconds: 500);
  static const Duration _paintInterval = Duration(milliseconds: 100);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // 弹窗关掉时不该留一个后台下载继续烧流量。
    _installer.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !_awaitingPermission) {
      return;
    }
    // 从「安装未知应用」设置页回来了，直接用已下好的包装一遍，不用重新下载。
    _awaitingPermission = false;
    final apk = _apk;
    if (apk != null && apk.existsSync()) {
      _installPackage(apk);
    }
  }

  bool get _canInstallInApp =>
      Platform.isAndroid && widget.result.apkDownloadUrl != null;

  void _notifyPostpone() {
    if (_postponeNotified) {
      return;
    }
    _postponeNotified = true;
    widget.onPostpone?.call();
  }

  void _close() {
    if (_phase == _UpdatePhase.prompt) {
      _notifyPostpone();
    }
    Navigator.of(context).pop();
  }

  // ==================== 下载 ====================

  void _estimateSpeed(UpdateDownloadProgress progress) {
    final now = DateTime.now();
    final lastAt = _lastSampleAt;
    if (lastAt != null) {
      final elapsed = now.difference(lastAt).inMilliseconds / 1000.0;
      final delta = progress.received - _lastSampleBytes;
      if (elapsed >= _sampleInterval.inMilliseconds / 1000.0 && delta > 0) {
        final instant = delta / elapsed;
        final previous = _speed;
        _speed = previous == null ? instant : previous * 0.6 + instant * 0.4;
        _lastSampleAt = now;
        _lastSampleBytes = progress.received;
      }
      return;
    }
    _lastSampleAt = now;
    _lastSampleBytes = progress.received;
  }

  void _onProgress(UpdateDownloadProgress progress) {
    _estimateSpeed(progress);
    final now = DateTime.now();
    final finished =
        progress.total != null && progress.received >= progress.total!;
    if (!finished && now.difference(_lastPaintAt) < _paintInterval) {
      return;
    }
    _lastPaintAt = now;
    if (!mounted) {
      return;
    }
    setState(() => _progress = progress);
  }

  Future<void> _startDownload() async {
    setState(() {
      _phase = _UpdatePhase.downloading;
      _error = null;
      _speed = null;
      _lastSampleAt = null;
      _lastSampleBytes = 0;
      _progress = UpdateDownloadProgress(
        received: 0,
        total: widget.result.apkSizeBytes,
      );
    });
    try {
      final file = await _installer.download(
        widget.result,
        onProgress: _onProgress,
      );
      if (!mounted) {
        return;
      }
      _apk = file;
      await _installPackage(file);
    } on UpdateDownloadException catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _phase = _UpdatePhase.blocked;
        _error = e.message;
      });
    }
  }

  // ==================== 安装 ====================

  Future<void> _installPackage(File file) async {
    setState(() {
      _phase = _UpdatePhase.installing;
      _error = null;
    });
    final status = await _installer.install(file);
    if (!mounted) {
      return;
    }
    switch (status) {
      case ApkInstallStatus.started:
        setState(() => _phase = _UpdatePhase.launched);
      case ApkInstallStatus.permissionRequired:
        setState(() {
          _phase = _UpdatePhase.blocked;
          _awaitingPermission = true;
          _error = '需要先允许「安装未知应用」。在打开的设置页里把开关打开，'
              '返回后会自动继续安装，不用重新下载。';
        });
      case ApkInstallStatus.missingFile:
        UpdateInstaller.forgetCache();
        setState(() {
          _phase = _UpdatePhase.blocked;
          _apk = null;
          _error = '安装包被系统清理掉了，重新下载一次即可。';
        });
      case ApkInstallStatus.unsupported:
        setState(() {
          _phase = _UpdatePhase.blocked;
          _error = '当前平台不支持应用内安装，请到发布页下载安装包。';
        });
      case ApkInstallStatus.noInstaller:
        setState(() {
          _phase = _UpdatePhase.blocked;
          _error = '系统里找不到能安装 APK 的应用，请点「浏览器下载」手动安装。';
        });
      case ApkInstallStatus.failed:
        setState(() {
          _phase = _UpdatePhase.blocked;
          _error = '系统安装器没有响应。可以点「重新唤起」，或改用浏览器下载。';
        });
    }
  }

  Future<void> _openInBrowser() async {
    final launched = await launchUrl(
      widget.result.downloadUrl,
      mode: LaunchMode.externalApplication,
    );
    if (!mounted) {
      return;
    }
    if (!launched) {
      setState(() {
        _phase = _UpdatePhase.blocked;
        _error = '没找到能打开链接的浏览器，请手动访问 ${widget.result.downloadUrl}';
      });
    } else if (_phase == _UpdatePhase.prompt) {
      _close();
    }
  }

  void _cancelDownload() {
    _installer.cancel();
    if (!mounted) {
      return;
    }
    setState(() {
      _phase = _UpdatePhase.prompt;
      _progress = null;
      _speed = null;
    });
  }

  // ==================== 文案 ====================

  String get _version => widget.result.latestVersion;

  String get _headerTitle => switch (_phase) {
        _UpdatePhase.prompt || _UpdatePhase.downloading => '发现新版本 v$_version',
        _UpdatePhase.installing => '正在安装 v$_version',
        _UpdatePhase.launched => '已交给系统安装',
        _UpdatePhase.blocked => '更新没能完成',
      };

  String get _headerSubtitle {
    final result = widget.result;
    switch (_phase) {
      case _UpdatePhase.prompt:
        final parts = <String>['当前 v${result.currentVersion}'];
        final size = _formatSize(result.apkSizeBytes);
        if (size != null) {
          parts.add('安装包 $size');
        }
        if (result.sourceLabel.isNotEmpty) {
          parts.add(result.sourceLabel);
        }
        return parts.join(' · ');
      case _UpdatePhase.downloading:
        return '下载完成后会自动打开系统安装界面';
      case _UpdatePhase.installing:
        return '正在打开系统安装界面…';
      case _UpdatePhase.launched:
        return '没看到安装界面的话，点下面的「重新唤起安装器」';
      case _UpdatePhase.blocked:
        return '当前 v${result.currentVersion} → v$_version';
    }
  }

  IconData get _headerIcon => switch (_phase) {
        _UpdatePhase.prompt => Icons.system_update_alt,
        _UpdatePhase.downloading => Icons.downloading,
        _UpdatePhase.installing ||
        _UpdatePhase.launched =>
          Icons.install_mobile,
        _UpdatePhase.blocked => Icons.error_outline,
      };

  String _progressDetail() {
    final progress = _progress;
    if (progress == null) {
      return '正在准备下载…';
    }
    final received = _formatMb(progress.received);
    final total = progress.total;
    final buffer = StringBuffer();
    if (total == null || total <= 0) {
      buffer.write('已下载 $received MB');
    } else {
      buffer.write('$received / ${_formatMb(total)} MB');
    }
    final speed = _speed;
    if (speed != null && speed > 1024) {
      buffer.write(' · ${_formatSpeed(speed)}');
    }
    return buffer.toString();
  }

  static String _formatMb(int bytes) =>
      (bytes / (1024 * 1024)).toStringAsFixed(1);

  static String _formatSpeed(double bytesPerSecond) {
    if (bytesPerSecond < 1024 * 1024) {
      return '${(bytesPerSecond / 1024).toStringAsFixed(0)} KB/s';
    }
    return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }

  static String? _formatSize(int? bytes) {
    if (bytes == null || bytes <= 0) {
      return null;
    }
    return '${_formatMb(bytes)} MB';
  }

  // ==================== UI ====================

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subtle = theme.textTheme.bodySmall?.color?.withValues(alpha: 0.62) ??
        const Color(0xFF888888);
    return PopScope(
      canPop: _phase != _UpdatePhase.downloading &&
          _phase != _UpdatePhase.installing,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop && _phase == _UpdatePhase.prompt) {
          _notifyPostpone();
        }
      },
      child: Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildHeader(subtle),
                const SizedBox(height: 16),
                ..._buildBody(theme, subtle),
                const SizedBox(height: 16),
                _buildActions(theme),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(Color subtle) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppTheme.primaryColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(_headerIcon, color: AppTheme.primaryColor, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _headerTitle,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _headerSubtitle,
                  style: TextStyle(fontSize: 12.5, height: 1.4, color: subtle),
                ),
              ],
            ),
          ),
        ],
      );

  List<Widget> _buildBody(ThemeData theme, Color subtle) {
    switch (_phase) {
      case _UpdatePhase.prompt:
        final notes = widget.result.releaseNotes;
        if (notes.isEmpty) {
          return const [];
        }
        return [
          Text(
            '更新内容',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: subtle,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.primaryColor.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(12),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: SingleChildScrollView(
                child: Text(
                  notes,
                  style: const TextStyle(fontSize: 13, height: 1.55),
                ),
              ),
            ),
          ),
        ];
      case _UpdatePhase.downloading:
        return [_buildProgress(subtle)];
      case _UpdatePhase.installing:
        return const [
          Row(
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 10),
              Text('正在唤出系统安装器…', style: TextStyle(fontSize: 13)),
            ],
          ),
        ];
      case _UpdatePhase.launched:
        return [
          Text(
            '在系统安装界面点「安装」就完成了，装完新版本会自动打开。',
            style: TextStyle(fontSize: 13, height: 1.5, color: subtle),
          ),
        ];
      case _UpdatePhase.blocked:
        return [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.error.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              _error ?? '更新没能完成，请重试。',
              style: TextStyle(
                fontSize: 13,
                height: 1.5,
                color: theme.colorScheme.error,
              ),
            ),
          ),
        ];
    }
  }

  Widget _buildProgress(Color subtle) {
    final fraction = _progress?.fraction;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: fraction,
            minHeight: 8,
            backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.12),
            valueColor: const AlwaysStoppedAnimation<Color>(
              AppTheme.primaryColor,
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: Text(
                _progressDetail(),
                style: TextStyle(fontSize: 12.5, color: subtle),
              ),
            ),
            if (fraction != null)
              Text(
                '${(fraction * 100).round()}%',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.primaryColor,
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildActions(ThemeData theme) {
    switch (_phase) {
      case _UpdatePhase.prompt:
        return Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: _close,
              child: const Text('稍后再说', style: TextStyle(fontSize: 14)),
            ),
            const SizedBox(width: 4),
            FilledButton(
              onPressed: _canInstallInApp ? _startDownload : _openInBrowser,
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.primaryColor,
                foregroundColor: Colors.white,
              ),
              child: Text(
                _canInstallInApp ? '立即更新' : '前往发布页',
                style: const TextStyle(fontSize: 14),
              ),
            ),
          ],
        );
      case _UpdatePhase.downloading:
        return SizedBox(
          width: double.infinity,
          child: TextButton(
            onPressed: _cancelDownload,
            child: const Text('取消下载', style: TextStyle(fontSize: 14)),
          ),
        );
      case _UpdatePhase.installing:
        return const SizedBox.shrink();
      case _UpdatePhase.launched:
        return Wrap(
          alignment: WrapAlignment.end,
          spacing: 4,
          runSpacing: 4,
          children: [
            TextButton(
              onPressed: _close,
              child: const Text('完成', style: TextStyle(fontSize: 14)),
            ),
            TextButton(
              onPressed: _openInBrowser,
              child: const Text('改用浏览器', style: TextStyle(fontSize: 14)),
            ),
            FilledButton(
              onPressed: () {
                final apk = _apk;
                if (apk != null) {
                  _installPackage(apk);
                } else {
                  _startDownload();
                }
              },
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.primaryColor,
                foregroundColor: Colors.white,
              ),
              child: const Text('重新唤起安装器', style: TextStyle(fontSize: 14)),
            ),
          ],
        );
      case _UpdatePhase.blocked:
        final apk = _apk;
        return Wrap(
          alignment: WrapAlignment.end,
          spacing: 4,
          runSpacing: 4,
          children: [
            TextButton(
              onPressed: _close,
              child: const Text('关闭', style: TextStyle(fontSize: 14)),
            ),
            TextButton(
              onPressed: _openInBrowser,
              child: const Text('浏览器下载', style: TextStyle(fontSize: 14)),
            ),
            FilledButton(
              onPressed:
                  apk != null ? () => _installPackage(apk) : _startDownload,
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.primaryColor,
                foregroundColor: Colors.white,
              ),
              child: Text(
                apk != null ? '再试一次' : '重新下载',
                style: const TextStyle(fontSize: 14),
              ),
            ),
          ],
        );
    }
  }
}
