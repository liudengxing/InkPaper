import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:inkpaper/providers/app_provider.dart';
import 'package:inkpaper/services/memos_resource_service.dart';
import 'package:inkpaper/utils/attachment_cache.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

/// 全屏视频播放页。
///
/// 只做一件事：把一段视频放出来。不引 chewie —— 这里需要的交互只有
/// 播放/暂停、拖动进度、关闭，自己拼比带一整套皮肤更可控。
///
/// [path] 支持四种来源：
/// - `file:///…` 或绝对路径（本机视频）
/// - `http(s)://…`（外部直链）
/// - `/o/r/<uid>`、`/file/…`（Memos 资源，需要带 token）
class VideoPlayerScreen extends StatefulWidget {
  const VideoPlayerScreen({required this.path, super.key, this.title});

  final String path;
  final String? title;

  static Future<void> open(
    BuildContext context, {
    required String path,
    String? title,
  }) {
    return Navigator.of(context).push(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 180),
        reverseTransitionDuration: const Duration(milliseconds: 150),
        pageBuilder: (context, _, __) => VideoPlayerScreen(
          path: path,
          title: title,
        ),
        transitionsBuilder: (context, animation, _, child) => FadeTransition(
          opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
          child: child,
        ),
      ),
    );
  }

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  VideoPlayerController? _controller;
  Object? _error;

  /// 是否已经初始化完成。初始化前 controller 存在但宽高为 0，不能直接铺开。
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    // 首帧之后再建 controller：要读 Provider 拿服务端地址和 token
    WidgetsBinding.instance.addPostFrameCallback((_) => _initController());
  }

  Future<void> _initController() async {
    try {
      final controller = await _createController();
      await controller.initialize();
      await controller.setLooping(false);
      if (!mounted) {
        unawaited(controller.dispose());
        return;
      }
      setState(() {
        _controller = controller;
        _ready = true;
      });
      await controller.play();
    } on Object catch (e) {
      if (mounted) {
        setState(() => _error = e);
      }
    }
  }

  Future<VideoPlayerController> _createController() async {
    final path = widget.path;
    if (path.startsWith('http://') || path.startsWith('https://')) {
      return VideoPlayerController.networkUrl(Uri.parse(path));
    }

    if (MemosResourceService.isServerResourcePath(path)) {
      final appProvider = Provider.of<AppProvider>(context, listen: false);
      final service = appProvider.resourceService;
      final baseUrl = appProvider.appConfig.lastServerUrl ??
          appProvider.user?.serverUrl ??
          appProvider.appConfig.memosApiUrl ??
          '';
      final url = service?.buildImageUrl(path) ?? '$baseUrl$path';
      final token = appProvider.user?.token;
      return VideoPlayerController.networkUrl(
        Uri.parse(url),
        httpHeaders: token == null
            ? const <String, String>{}
            : <String, String>{'Authorization': 'Bearer $token'},
      );
    }

    // 本地：先看附件缓存有没有离线副本，再退回原路径
    final plain =
        path.startsWith('file://') ? path.replaceFirst('file://', '') : path;
    final cached = AttachmentCache.instance.pathFor(path) ??
        AttachmentCache.instance.pathFor(plain);
    return VideoPlayerController.file(File(cached ?? plain));
  }

  void _togglePlay() {
    final controller = _controller;
    if (controller == null) {
      return;
    }
    if (controller.value.isPlaying) {
      unawaited(controller.pause());
    } else {
      // 播完再点就从头开始，否则会卡在最后一帧没有反应
      if (controller.value.position >= controller.value.duration) {
        unawaited(controller.seekTo(Duration.zero));
      }
      unawaited(controller.play());
    }
  }

  @override
  void dispose() {
    unawaited(_controller?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final padding = MediaQuery.paddingOf(context);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            Positioned.fill(
              child: controller == null || !_ready
                  ? _buildStatus()
                  : GestureDetector(
                      onTap: _togglePlay,
                      child: Center(
                        child: AspectRatio(
                          aspectRatio: controller.value.aspectRatio <= 0
                              ? 16 / 9
                              : controller.value.aspectRatio,
                          child: VideoPlayer(controller),
                        ),
                      ),
                    ),
            ),
            Positioned(
              top: padding.top + 6,
              left: 8,
              child: _buildCircleButton(
                icon: Icons.close_rounded,
                onTap: () => Navigator.of(context).maybePop(),
              ),
            ),
            if (controller != null && _ready)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _buildControls(controller),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatus() {
    final error = _error;
    if (error != null) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.videocam_off_outlined, size: 48, color: Colors.white54),
            SizedBox(height: 12),
            Text('视频无法播放', style: TextStyle(color: Colors.white70)),
          ],
        ),
      );
    }
    return const Center(
      child: CircularProgressIndicator(color: Colors.white),
    );
  }

  Widget _buildControls(VideoPlayerController controller) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final duration = value.duration;
        final position = value.position;
        final maxMs = duration.inMilliseconds.toDouble();
        final currentMs = position.inMilliseconds
            .clamp(0, duration.inMilliseconds)
            .toDouble();
        return DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.transparent, Color(0xCC000000)],
            ),
          ),
          child: Padding(
            padding: EdgeInsets.fromLTRB(4, 16, 12, bottomInset + 6),
            child: Row(
              children: [
                IconButton(
                  onPressed: _togglePlay,
                  icon: Icon(
                    value.isPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 26,
                  ),
                ),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 2,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 6,
                      ),
                      overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 12,
                      ),
                      activeTrackColor: Colors.white,
                      inactiveTrackColor: Colors.white24,
                      thumbColor: Colors.white,
                    ),
                    child: Slider(
                      value: maxMs <= 0 ? 0 : currentMs,
                      max: maxMs <= 0 ? 1 : maxMs,
                      onChanged: maxMs <= 0
                          ? null
                          : (next) => controller.seekTo(
                                Duration(milliseconds: next.round()),
                              ),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  '${_format(position)} / ${_format(duration)}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildCircleButton({
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.black.withValues(alpha: 0.42),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Icon(icon, color: Colors.white, size: 22),
        ),
      ),
    );
  }

  static String _format(Duration duration) {
    final totalSeconds = duration.inSeconds;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }
}
