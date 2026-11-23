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

  /// 本地视频文件不存在（例如恢复时选择了不恢复视频）。
  bool _localFileMissing = false;

  /// 是否已经初始化完成。初始化前 controller 存在但宽高为 0，不能直接铺开。
  bool _ready = false;

  /// 控制栏是否显示。看视频时它默认 3 秒后自己退场，别一直压着画面。
  bool _controlsVisible = true;
  Timer? _hideControlsTimer;

  /// 双击快进/快退时中间那个短暂的提示（-10 秒 / +10 秒）。
  String? _seekHint;
  Timer? _seekHintTimer;

  /// 最近一次双击的位置，用来判断点的是左半屏还是右半屏。
  Offset? _doubleTapPosition;

  /// 播放倍速，跟控制器保持同步。
  double _playbackSpeed = 1;

  /// 倍速循环档位：微信/B 站都是这几档，够用又不至于难选。
  static const List<double> _speedSteps = [0.5, 0.75, 1, 1.25, 1.5, 2];

  /// 一次双击快进/快退的秒数。
  static const Duration _seekStep = Duration(seconds: 10);

  /// 控制栏自动隐藏前的停留时间。
  static const Duration _controlsLinger = Duration(seconds: 3);

  @override
  void initState() {
    super.initState();
    // 首帧之后再建 controller：要读 Provider 拿服务端地址和 token
    WidgetsBinding.instance.addPostFrameCallback((_) => _initController());
  }

  @override
  void dispose() {
    _hideControlsTimer?.cancel();
    _seekHintTimer?.cancel();
    unawaited(_controller?.dispose());
    super.dispose();
  }

  Future<void> _initController() async {
    try {
      // 本地视频先确认文件在不在：从 WebDAV 恢复时可以选择不下载视频，
      // 正文里的 `file://` 仍指向旧设备路径，这里断得清楚比抛解码错误好懂。
      final path = widget.path;
      if (path.startsWith('file://')) {
        final file = File(path.replaceFirst('file://', ''));
        if (!await file.exists()) {
          if (mounted) {
            setState(() => _localFileMissing = true);
          }
          return;
        }
      }
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
      _scheduleHideControls();
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
      _showControls(); // 暂停了就把控制栏留住，别点完就消失
    } else {
      // 播完再点就从头开始，否则会卡在最后一帧没有反应
      if (_isCompleted(controller.value)) {
        unawaited(controller.seekTo(Duration.zero));
      }
      unawaited(controller.play());
      _scheduleHideControls();
    }
  }

  bool _isCompleted(VideoPlayerValue value) {
    final duration = value.duration;
    return duration > Duration.zero && value.position >= duration;
  }

  /// 点画面本身：只切换控制栏，不暂停 —— 微信、B 站都是这个手感，
  /// 想暂停点左下角那颗按钮，误触不至于打断观看。
  void _toggleControls() {
    if (_controlsVisible) {
      _hideControlsTimer?.cancel();
      setState(() => _controlsVisible = false);
      return;
    }
    _showControls();
  }

  void _showControls() {
    if (!_controlsVisible) {
      setState(() => _controlsVisible = true);
    }
    _scheduleHideControls();
  }

  /// 播放中 3 秒后收起控制栏；暂停或播放结束时一直留着，
  /// 否则用户想继续播还得先把控制栏点出来。
  void _scheduleHideControls() {
    _hideControlsTimer?.cancel();
    final controller = _controller;
    if (controller == null || !controller.value.isPlaying) {
      return;
    }
    _hideControlsTimer = Timer(_controlsLinger, () {
      if (mounted && (_controller?.value.isPlaying ?? false)) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  /// 双击：左半屏退 10 秒、右半屏进 10 秒，中间一小条当播放/暂停。
  void _handleDoubleTap() {
    final controller = _controller;
    final position = _doubleTapPosition;
    if (controller == null || position == null) {
      _togglePlay();
      return;
    }
    final width = MediaQuery.sizeOf(context).width;
    if (position.dx < width * 0.35) {
      unawaited(_seekBy(-_seekStep, controller));
    } else if (position.dx > width * 0.65) {
      unawaited(_seekBy(_seekStep, controller));
    } else {
      _togglePlay();
    }
  }

  Future<void> _seekBy(Duration delta, VideoPlayerController controller) async {
    final duration = controller.value.duration;
    final target = controller.value.position + delta;
    final clamped = target < Duration.zero
        ? Duration.zero
        : (target > duration ? duration : target);
    await controller.seekTo(clamped);
    _showSeekHint(
      delta.isNegative
          ? '-${delta.inSeconds.abs()} 秒'
          : '+${delta.inSeconds} 秒',
    );
  }

  /// 双击后的短暂反馈：中间飘一个数字，700ms 自己消失。
  void _showSeekHint(String text) {
    _seekHintTimer?.cancel();
    if (mounted) {
      setState(() => _seekHint = text);
    }
    _seekHintTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) {
        setState(() => _seekHint = null);
      }
    });
  }

  /// 倍速按档位往下走，到头回到 0.5×。视频笔记大多是听内容，
  /// 1.5×、2× 用得比慢放多，所以默认从 1× 往上进。
  Future<void> _cycleSpeed() async {
    final controller = _controller;
    if (controller == null) {
      return;
    }
    final index = _speedSteps.indexOf(_playbackSpeed);
    final next = _speedSteps[(index < 0 ? 2 : index + 1) % _speedSteps.length];
    await controller.setPlaybackSpeed(next);
    if (!mounted) {
      return;
    }
    setState(() => _playbackSpeed = next);
    _showSeekHint('${_formatSpeed(next)} 倍速');
  }

  Future<void> _replay() async {
    final controller = _controller;
    if (controller == null) {
      return;
    }
    await controller.seekTo(Duration.zero);
    await controller.play();
    _scheduleHideControls();
  }

  static String _formatSpeed(double speed) {
    // 1.00 → 1、1.25 → 1.25、0.50 → 0.5，标签上别出现多余的零
    return speed.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');
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
                      // 单击只切控制栏、双击左右各快进快退 10 秒，
                      // 所以这里不能把「点一下」绑成暂停。
                      behavior: HitTestBehavior.opaque,
                      onTap: _toggleControls,
                      onDoubleTapDown: (details) =>
                          _doubleTapPosition = details.localPosition,
                      onDoubleTap: _handleDoubleTap,
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
            if (controller != null && _ready)
              Positioned.fill(
                child: _buildCenterOverlay(controller),
              ),
            if (_seekHint != null)
              Positioned.fill(
                child: IgnorePointer(
                  child: Center(child: _buildSeekHint(_seekHint!)),
                ),
              ),
            // 关闭键常驻：控制栏自己退场时也不能把退出口藏起来。
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
                child: IgnorePointer(
                  ignoring: !_controlsVisible,
                  child: AnimatedOpacity(
                    opacity: _controlsVisible ? 1 : 0,
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOut,
                    child: _buildControls(controller),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 画面中央的常驻状态：缓冲转圈，播完给一颗重播键。
  Widget _buildCenterOverlay(VideoPlayerController controller) {
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        if (_isCompleted(value) && !value.isPlaying) {
          return Center(
            child: _buildCircleButton(
              icon: Icons.replay_rounded,
              size: 64,
              iconSize: 30,
              onTap: _replay,
            ),
          );
        }
        if (value.isBuffering) {
          return const Center(
            child: SizedBox(
              width: 32,
              height: 32,
              child: CircularProgressIndicator(
                strokeWidth: 2.4,
                color: Colors.white70,
              ),
            ),
          );
        }
        return const SizedBox.shrink();
      },
    );
  }

  /// 双击后的数字反馈：不抢位置，飘在正中就行。
  Widget _buildSeekHint(String text) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Text(
          text,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _buildStatus() {
    if (_localFileMissing) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.cloud_off_outlined,
                size: 48,
                color: Colors.white54,
              ),
              SizedBox(height: 12),
              Text(
                '这段视频不在本机',
                style: TextStyle(color: Colors.white70),
              ),
              SizedBox(height: 6),
              Text(
                '从备份恢复时若选择只恢复图片，视频不会下载到本机',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white38, fontSize: 12),
              ),
            ],
          ),
        ),
      );
    }
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
            padding: EdgeInsets.fromLTRB(4, 16, 8, bottomInset + 6),
            child: Row(
              children: [
                IconButton(
                  onPressed: _togglePlay,
                  tooltip: value.isPlaying ? '暂停' : '播放',
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
                      // 2px 的轨道太细，手指按住基本看不出位置，加到 4px
                      trackHeight: 4,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 7,
                      ),
                      overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 14,
                      ),
                      activeTrackColor: Colors.white,
                      inactiveTrackColor: Colors.white24,
                      thumbColor: Colors.white,
                    ),
                    child: Slider(
                      value: maxMs <= 0 ? 0 : currentMs,
                      max: maxMs <= 0 ? 1 : maxMs,
                      // 拖动时先别让控制栏自己消失
                      onChangeStart: (_) => _hideControlsTimer?.cancel(),
                      onChanged: maxMs <= 0
                          ? null
                          : (next) => controller.seekTo(
                                Duration(milliseconds: next.round()),
                              ),
                      onChangeEnd: (_) => _scheduleHideControls(),
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
                const SizedBox(width: 4),
                // 倍速：点一下换下一档，标签上直接写当前档位
                _buildSpeedButton(),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 倍速按钮：压成一颗小胶囊，跟时间文本同一行，不额外占地方。
  Widget _buildSpeedButton() {
    return Material(
      color: Colors.white.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(11),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _cycleSpeed,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Text(
            '${_formatSpeed(_playbackSpeed)}×',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCircleButton({
    required IconData icon,
    required VoidCallback onTap,
    double size = 44,
    double iconSize = 22,
  }) {
    return Material(
      color: Colors.black.withValues(alpha: 0.42),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon, color: Colors.white, size: iconSize),
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
