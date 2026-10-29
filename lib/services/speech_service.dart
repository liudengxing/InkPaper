import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:inkpaper/l10n/app_localizations_simple.dart';
import 'package:inkpaper/models/app_config_model.dart';
import 'package:inkpaper/services/baidu_realtime_speech_service.dart';
import 'package:inkpaper/services/baidu_speech_service.dart';
import 'package:inkpaper/services/iflytek_speech_service.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

/// 语音识别服务
/// 提供本地+云端混合语音转文字功能
///
/// 策略：
/// 1. 优先使用本地识别（免费，实时）
/// 2. 本地不可用时降级到百度云识别（需配置 API Key）
class SpeechService {
  factory SpeechService() => _instance;
  SpeechService._internal();
  static final SpeechService _instance = SpeechService._internal();

  late stt.SpeechToText _speech;
  final BaiduSpeechService _baiduSpeech = BaiduSpeechService();
  final BaiduRealtimeSpeechService _baiduRealtime =
      BaiduRealtimeSpeechService();
  IflytekSpeechService? _iflytekSpeech;

  bool _isInitialized = false;
  bool _isListening = false;
  String _lastRecognizedText = '';

  /// 连续识别：系统一次 listen 结束（静音超时 / 达到时长上限）后自动续听，
  /// 把新一段文本拼在已识别文本后面，长口述不会说一半就断。
  bool _keepListening = false;
  int _restartCount = 0;
  static const int _maxRestarts = 6;
  String _committedText = '';

  /// 本段是否听到过内容：用来区分"说完停顿"和"一直没说话"，
  /// 后者不该无限续听（否则录音状态会一直挂着）。
  bool _segmentHasWords = false;

  String? _lastError;
  String? _activeLocaleId;
  Function(String)? _doneCallback;
  Function(String)? _errorCallback;

  /// 最近一次失败原因（用于弹窗展示具体问题）
  String? get lastError => _lastError;

  /// 实际使用的识别语言，例如 `zh_CN`
  String? get activeLocaleId => _activeLocaleId;

  // 用户偏好设置
  static const String _prefKeyUseCloud = 'speech_use_cloud';
  bool _preferCloudRecognition = false; // 商业化上架默认仅本地识别

  /// 获取是否正在监听
  bool get isListening => _isListening;

  /// 获取是否已初始化
  bool get isInitialized => _isInitialized;

  /// 获取最后识别的文本
  String get lastRecognizedText => _lastRecognizedText;

  /// 是否优先使用云端识别
  bool get preferCloudRecognition => _preferCloudRecognition;

  /// 百度云识别是否已配置
  bool get isBaiduConfigured => _baiduSpeech.isConfigured();

  /// 讯飞云识别是否已配置
  bool isIflytekConfigured(AppConfig config) =>
      IflytekSpeechService(config).isConfigured;

  /// 初始化语音识别服务
  Future<bool> initialize() async {
    try {
      // 加载用户偏好
      final prefs = await SharedPreferences.getInstance();
      _preferCloudRecognition = prefs.getBool(_prefKeyUseCloud) ?? false;

      // 初始化本地语音识别
      _speech = stt.SpeechToText();
      _isInitialized = await _speech.initialize(
        // 以前这里的 onError 是空的，出错时用户只会看到"语音不可用"，
        // 完全不知道是没网、没权限还是设备没有识别服务。
        onError: (error) {
          _lastError = _describeError(error.errorMsg, error.permanent);
          debugPrint('SpeechService: 识别错误 ${error.errorMsg}');
          if (error.permanent) {
            _keepListening = false;
            _errorCallback?.call(_lastError!);
          }
        },
        onStatus: _handleStatus,
      );

      if (_isInitialized) {
        _activeLocaleId = await _resolveLocaleId();
      } else {
        _lastError ??= '设备上没有可用的语音识别服务，可在设置中改用讯飞语音';
      }

      return _isInitialized;
    } on Object catch (e) {
      _lastError = '语音识别初始化失败：$e';
      _isInitialized = false;
      return false;
    }
  }

  /// 系统识别状态变化：自动收尾或无缝续听
  void _handleStatus(String status) {
    final wasListening = _isListening;
    _isListening = status == 'listening';

    if (status != 'done' && status != 'notListening') {
      return;
    }

    // 只有"这一段确实听到了话"才续听：说完停顿会再等 5 秒收尾，
    // 而一直没出声就直接结束，不会把录音状态挂在那里。
    if (_keepListening && _segmentHasWords && _restartCount < _maxRestarts) {
      _restartCount++;
      _committedText = _lastRecognizedText;
      // 等系统释放麦克风再重开，否则部分机型直接返回 busy
      Future<void>.delayed(const Duration(milliseconds: 250), () {
        if (!_keepListening || !_isInitialized) {
          return;
        }
        unawaited(
          _listenLocal(
            onResult: _activeOnResult,
            onSoundLevel: _activeOnSoundLevel,
          ),
        );
      });
      return;
    }

    _keepListening = false;
    if (wasListening || status == 'done') {
      final callback = _doneCallback;
      _doneCallback = null;
      callback?.call(_lastRecognizedText);
    }
  }

  /// 从设备支持的语种里挑一个：优先简体中文，否则用系统默认的第一个。
  ///
  /// 旧实现把 localeId 写死成 `zh_CN`，英文或粤语用户识别率会明显偏低，
  /// 部分机型甚至直接报 `error_language_not_supported`。
  Future<String?> _resolveLocaleId() async {
    try {
      final locales = await _speech.locales();
      if (locales.isEmpty) {
        return null; // 交给系统默认
      }
      final simplified = locales.where(
        (locale) =>
            locale.localeId.toLowerCase() == 'zh_cn' ||
            locale.localeId.toLowerCase().startsWith('zh-hans'),
      );
      if (simplified.isNotEmpty) {
        return simplified.first.localeId;
      }
      final chinese = locales.where(
        (locale) => locale.localeId.toLowerCase().startsWith('zh'),
      );
      if (chinese.isNotEmpty) {
        return chinese.first.localeId;
      }
      return locales.first.localeId;
    } on Object {
      return null;
    }
  }

  Function(String)? _activeOnResult;
  Function(double)? _activeOnSoundLevel;

  /// 真正调用系统识别的入口（含续听时会复用）
  Future<void> _listenLocal({
    Function(String)? onResult,
    Function(double)? onSoundLevel,
    Duration? timeout,
  }) async {
    _activeOnResult = onResult;
    _segmentHasWords = false;
    await _speech.listen(
      onResult: (result) {
        if (result.recognizedWords.trim().isNotEmpty) {
          _segmentHasWords = true;
        }
        final merged = _mergeRecognized(_committedText, result.recognizedWords);
        _lastRecognizedText = merged;
        // 实时回调：中间结果也回调，编辑器里能像微信一样边说边出字
        onResult?.call(merged);
      },
      onSoundLevelChange: (level) {
        if (onSoundLevel == null) {
          return;
        }
        onSoundLevel(level > 0.1 ? level : 0);
      },
      listenOptions: stt.SpeechListenOptions(
        // 单段上限从 30 秒放宽到 60 秒，到点由 _handleStatus 续听，
        // 用户不用因为说长句被硬生生截断而重来。
        listenFor: timeout ?? const Duration(seconds: 60),
        // 停顿 3 秒就断句太急，思考一下就没了；5 秒更接近日常语速
        pauseFor: const Duration(seconds: 5),
        localeId: _activeLocaleId,
      ),
    );
  }

  /// 拼接续听文本：系统每次返回的是"本段"结果，已完成的段要保留。
  String _mergeRecognized(String committed, String incoming) {
    final next = incoming.trim();
    if (committed.isEmpty) {
      return next;
    }
    if (next.isEmpty) {
      return committed;
    }
    if (next.startsWith(committed)) {
      return next;
    }
    return '$committed $next';
  }

  String _describeError(String errorMsg, bool permanent) {
    final suffix = permanent ? '（需重新打开语音识别）' : '';
    switch (errorMsg) {
      case 'error_no_match':
        return '没有识别到语音内容，靠近麦克风再说一次';
      case 'error_speech_timeout':
        return '等待说话超时，请重新开始';
      case 'error_network':
      case 'error_network_timeout':
      case 'error_server':
        return '语音识别需要联网，请检查网络后重试';
      case 'error_busy':
        return '识别服务正忙，稍等一下再试$suffix';
      case 'error_permission':
      case 'error_insufficient_permissions':
        return '缺少麦克风或语音识别权限$suffix';
      case 'error_language_not_supported':
        return '设备没有安装当前语言的识别包，可在系统设置里下载语音数据';
      case 'error_client':
        return '这台设备没有可用的语音识别服务$suffix';
      default:
        return '$errorMsg$suffix';
    }
  }

  /// 设置是否优先使用云端识别
  Future<void> setPreferCloudRecognition(bool prefer) async {
    _preferCloudRecognition = prefer;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefKeyUseCloud, prefer);
  }

  /// 检查麦克风权限
  Future<bool> checkMicrophonePermission() async {
    final status = await Permission.microphone.status;
    return status.isGranted;
  }

  /// 检查权限（兼容性方法）
  Future<bool> checkPermission() async => checkMicrophonePermission();

  /// 请求麦克风权限
  Future<bool> requestMicrophonePermission() async {
    final status = await Permission.microphone.request();
    return status.isGranted;
  }

  /// 请求权限（兼容性方法）
  Future<bool> requestPermission() async => requestMicrophonePermission();

  /// 开始语音识别
  ///
  /// 使用本地 speech_to_text 实时识别
  Future<bool> startListening({
    Function(String)? onResult,
    Function(String)? onError,
    Function(double)? onSoundLevel, // 🎤 音量变化回调
    Duration? timeout,
    BuildContext? context,
    AppConfig? appConfig,
    // 系统识别自动结束（静音 / 到时长上限）时是否自动续听
    bool continuous = true,
    // 识别被系统主动结束时的回调，调用方据此同步"录音中"状态
    Function(String)? onDone,
  }) async {
    try {
      if (appConfig?.speechRecognitionMode == AppConfig.SPEECH_MODE_IFLYTEK) {
        return await _startIflytekListening(
          appConfig: appConfig!,
          onResult: onResult,
          onError: onError,
          onSoundLevel: onSoundLevel,
          context: context,
        );
      }

      // 🎯 使用本地识别（已优化，体验很好）
      debugPrint('SpeechService: 使用本地实时识别');
      // iOS: speech_to_text的initialize()方法会自动触发权限请求
      // 所以不需要提前请求权限，直接初始化即可
      if (!_isInitialized) {
        // 在iOS上，这个调用会触发麦克风和语音识别权限请求
        final success = await initialize();

        if (!success) {
          // 如果初始化失败，提示用户
          if (context != null && context.mounted) {
            _showLocalSpeechFailedDialog(context, onError);
          }
          return false;
        }
      }

      if (!_isInitialized) {
        // 本地识别不可用，提示用户
        if (context != null && context.mounted) {
          _showLocalSpeechFailedDialog(context, onError);
        }
        return false;
      }

      // 检查权限状态
      final available = await _speech.hasPermission;
      if (!available) {
        if (context != null && context.mounted) {
          _showPermissionDeniedDialog(context);
        }
        return false;
      }

      // 重置一次会话的状态：续听次数、已确认文本、结束回调
      _committedText = '';
      _lastRecognizedText = '';
      _restartCount = 0;
      _keepListening = continuous;
      _doneCallback = onDone;
      _errorCallback = onError;
      _activeLocaleId ??= await _resolveLocaleId();

      _activeOnResult = onResult;
      _activeOnSoundLevel = onSoundLevel;
      await _listenLocal(
        onResult: onResult,
        onSoundLevel: onSoundLevel,
        timeout: timeout,
      );

      _isListening = true;
      return true;
    } on Object catch (e) {
      _lastError = e.toString();
      _keepListening = false;
      if (onError != null) {
        onError(_lastError!);
      }

      // 本地识别失败，提示用户
      if (context != null && context.mounted) {
        _showLocalSpeechFailedDialog(context, onError);
      }
      return false;
    }
  }

  Future<bool> _startIflytekListening({
    required AppConfig appConfig,
    Function(String)? onResult,
    Function(String)? onError,
    Function(double)? onSoundLevel,
    BuildContext? context,
  }) async {
    _iflytekSpeech = IflytekSpeechService(appConfig);
    if (!_iflytekSpeech!.isConfigured) {
      const message = '讯飞语音识别未配置完整，请先到 AI 设置里填写 APPID、APIKey 和 APISecret。';
      onError?.call(message);
      if (context != null && context.mounted) {
        _showIflytekNotConfiguredDialog(context);
      }
      return false;
    }

    debugPrint('SpeechService: 使用讯飞实时识别');
    final success = await _iflytekSpeech!.startListening(
      onResult: (text) {
        _lastRecognizedText = text;
        onResult?.call(text);
      },
      onError: onError,
      onSoundLevel: onSoundLevel,
    );
    _isListening = success;
    return success;
  }

  /// 识别音频文件（支持云端识别）
  ///
  /// [audioPath] 音频文件路径
  /// [onResult] 识别成功回调
  /// [onError] 识别失败回调
  /// [context] 用于显示对话框
  Future<bool> recognizeAudioFile({
    required String audioPath,
    Function(String)? onResult,
    Function(String)? onError,
    BuildContext? context,
  }) async {
    try {
      // 检查百度云识别是否已配置
      if (!_baiduSpeech.isConfigured()) {
        if (context != null) {
          _showBaiduNotConfiguredDialog(context);
        }
        if (onError != null) {
          onError('百度语音识别未配置');
        }
        return false;
      }

      // 使用百度云识别
      final result = await _baiduSpeech.recognizeAudioFile(
        audioPath: audioPath,
      );

      if (result != null && result.isNotEmpty) {
        _lastRecognizedText = result;
        if (onResult != null) {
          onResult(result);
        }
        return true;
      } else {
        if (onError != null) {
          onError('识别失败，请重试');
        }
        return false;
      }
    } on Object catch (e) {
      if (onError != null) {
        onError(e.toString());
      }
      return false;
    }
  }

  /// 停止语音识别
  Future<void> stopListening() async {
    try {
      _isListening = false;
      // 用户主动停止：不再续听，也不再回调 onDone（由调用方自己收尾）
      _keepListening = false;
      _doneCallback = null;
      _committedText = '';

      // 停止百度实时识别
      if (_baiduRealtime.isListening) {
        await _baiduRealtime.stopListening();
      }

      if (_iflytekSpeech?.isListening ?? false) {
        await _iflytekSpeech?.stopListening();
      }

      // 停止本地识别
      if (_speech.isListening) {
        await _speech.stop();

        // 等待系统完全释放麦克风权限
        await Future.delayed(const Duration(milliseconds: 100));
      }
    } on Object catch (e) {
      debugPrint('停止语音识别失败: $e');
      _isListening = false;
    }
  }

  /// 取消语音识别
  Future<void> cancelListening() async {
    if (_isListening) {
      if (_iflytekSpeech?.isListening ?? false) {
        await _iflytekSpeech?.stopListening();
      }
      await _speech.cancel();
      _isListening = false;
      _lastRecognizedText = '';
    }
  }

  /// 获取支持的语言列表
  Future<List<String>> getSupportedLanguages() async {
    if (!_isInitialized) {
      await initialize();
    }

    if (_isInitialized) {
      final locales = await _speech.locales();
      return locales.map((locale) => locale.localeId).toList();
    }
    return ['zh-CN', 'en-US'];
  }

  /// 检查设备是否支持语音识别
  Future<bool> isDeviceSupported() async {
    if (!_isInitialized) {
      await initialize();
    }
    return _isInitialized;
  }

  /// 测试语音权限和功能
  Future<Map<String, dynamic>> testSpeechCapabilities() async {
    final result = <String, dynamic>{};

    try {
      // 1. 检查初始化状态
      if (!_isInitialized) {
        await initialize();
      }
      result['initialized'] = _isInitialized;

      // 2. 检查设备支持
      final deviceSupported = await _speech.hasPermission;
      result['deviceSupported'] = deviceSupported;

      // 3. 检查权限状态
      if (Platform.isIOS) {
        final micStatus = await Permission.microphone.status;
        final speechStatus = await Permission.speech.status;
        result['microphonePermission'] = micStatus.toString();
        result['speechPermission'] = speechStatus.toString();
      }

      // 4. 获取可用语言
      final locales = await _speech.locales();
      result['availableLocales'] = locales.map((l) => l.localeId).toList();
      result['hasChineseSupport'] =
          locales.any((l) => l.localeId.startsWith('zh'));

      // 5. 检查当前状态
      result['isListening'] = _isListening;
      result['lastText'] = _lastRecognizedText;
    } on Object catch (e) {
      result['error'] = e.toString();
    }

    return result;
  }

  /// 释放资源
  Future<void> dispose() async {
    try {
      if (_isListening || _speech.isListening) {
        // 🔥 确保完全释放麦克风资源
        await _speech.cancel();
      }
      if (_iflytekSpeech?.isListening ?? false) {
        await _iflytekSpeech?.stopListening();
      }
      _isListening = false;
      _lastRecognizedText = '';
    } on Object catch (e) {
      debugPrint('Failed to release speech resources: $e');
    }
  }

  /// 显示权限被拒绝的对话框
  void _showPermissionDeniedDialog(BuildContext context) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) => AlertDialog(
        title: Row(
          children: [
            const Text('🎤', style: TextStyle(fontSize: 24)),
            const SizedBox(width: 8),
            Text(
              AppLocalizationsSimple.of(context)
                      ?.speechPermissionRequiredTitle ??
                  '需要麦克风权限',
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              AppLocalizationsSimple.of(context)
                      ?.speechPermissionRequiredMessage ??
                  '语音识别功能需要麦克风和语音识别权限。',
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    AppLocalizationsSimple.of(context)?.permissionStepTitle ??
                        '操作步骤：',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    AppLocalizationsSimple.of(context)?.permissionStepSpeech ??
                        '1. 点击"去设置"按钮\n2. 找到"麦克风"和"语音识别"\n3. 开启权限开关\n4. 返回应用重试',
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(AppLocalizationsSimple.of(context)?.cancel ?? '取消'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.of(context).pop();
              await openAppSettings();
            },
            child:
                Text(AppLocalizationsSimple.of(context)?.goToSettings ?? '去设置'),
          ),
        ],
      ),
    );
  }

  /// 显示本地语音识别失败的对话框
  void _showLocalSpeechFailedDialog(
    BuildContext context,
    Function(String)? onError,
  ) {
    showDialog(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Row(
          children: [
            const Text('⚠️', style: TextStyle(fontSize: 24)),
            const SizedBox(width: 8),
            Text(
              AppLocalizationsSimple.of(context)
                      ?.speechRecognitionUnavailable ??
                  '语音识别不可用',
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              AppLocalizationsSimple.of(context)?.localSpeechUnavailable ??
                  '本地语音识别功能暂时不可用。',
            ),
            if (_lastError != null) ...[
              const SizedBox(height: 8),
              Text(
                '具体原因：$_lastError',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.orange[800],
                ),
              ),
            ],
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blue.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    AppLocalizationsSimple.of(context)?.possibleReasons ??
                        '可能的原因：',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    AppLocalizationsSimple.of(context)
                            ?.speechUnavailableReasons ??
                        '• Android: 缺少 Google 服务\n'
                            '• iOS: 系统版本过低\n'
                            '• 网络连接问题',
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
            if (_baiduSpeech.isConfigured()) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border:
                      Border.all(color: Colors.green.withValues(alpha: 0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      AppLocalizationsSimple.of(context)?.suggestion ?? '💡 建议',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      AppLocalizationsSimple.of(context)
                              ?.cloudSpeechSuggestion ??
                          '您可以使用云端语音识别功能（百度语音），识别准确率更高。',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(AppLocalizationsSimple.of(context)?.iKnow ?? '知道了'),
          ),
          if (_baiduSpeech.isConfigured())
            ElevatedButton(
              onPressed: () async {
                Navigator.of(context).pop();
                // 设置优先使用云端识别
                await setPreferCloudRecognition(true);
              },
              child: Text(
                AppLocalizationsSimple.of(context)?.useCloudRecognition ??
                    '使用云端识别',
              ),
            ),
        ],
      ),
    );
  }

  /// 显示百度语音未配置的对话框
  void _showBaiduNotConfiguredDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Row(
          children: [
            const Text('🔧', style: TextStyle(fontSize: 24)),
            const SizedBox(width: 8),
            Text(
              AppLocalizationsSimple.of(context)
                      ?.cloudRecognitionNotConfigured ??
                  '云端识别未配置',
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                AppLocalizationsSimple.of(context)?.baiduSpeechNotConfigured ??
                    '百度语音识别 API 尚未配置。',
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.blue.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  BaiduSpeechService.getSetupInstructions(),
                  style: const TextStyle(fontSize: 11),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(AppLocalizationsSimple.of(context)?.iKnow ?? '知道了'),
          ),
        ],
      ),
    );
  }

  void _showIflytekNotConfiguredDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('讯飞语音识别未配置'),
        content: const Text(
          '请先在 AI 设置里开启讯飞语音识别，并填写 APPID、APIKey 和 APISecret。密钥只保存在本机，调用费用由你的讯飞账号承担。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(AppLocalizationsSimple.of(context)?.confirm ?? '确定'),
          ),
        ],
      ),
    );
  }
}
