import 'package:flutter/foundation.dart';
import 'package:inkpaper/models/app_config_model.dart';
import 'package:inkpaper/services/iflytek_speech_service.dart';
import 'package:permission_handler/permission_handler.dart';

/// 语音转文字服务（**仅讯飞云识别**）。
///
/// 系统自带识别（`speech_to_text`）已整体移除：在部分国产 ROM（例如没有可用
/// `RecognitionService` 的 HyperOS）上，`listen()` 会「静默成功」却永不回调，
/// UI 只能一直挂在「正在聆听」，这正是历史 BLOCKERS `VOICE-001` 的根因面。
/// 现在语音是可选能力：设置里开启并填完讯飞 APPID/APIKey/APISecret 后才可用，
/// 入口显隐由 [AppConfig.speechInputEnabled] 决定。
class SpeechService {
  factory SpeechService() => _instance;
  SpeechService._internal();
  static final SpeechService _instance = SpeechService._internal();

  IflytekSpeechService? _iflytekSpeech;
  bool _isListening = false;
  String _lastRecognizedText = '';
  String? _lastError;

  /// 停止识别时的兜底超时：录音器卡住也不能让界面停在录音态。
  static const Duration _stopTimeout = Duration(seconds: 3);

  bool get isListening => _isListening;

  String get lastRecognizedText => _lastRecognizedText;

  /// 最近一次失败原因（用于界面提示）
  String? get lastError => _lastError;

  /// 当前配置下语音是否可用
  bool isConfigured(AppConfig config) =>
      IflytekSpeechService(config).isConfigured;

  /// 开始识别。只走讯飞实时识别，未开启语音时直接返回 false。
  Future<bool> startListening({
    required AppConfig appConfig,
    Function(String)? onResult,
    Function(String)? onError,
    Function(double)? onSoundLevel,
    Function(String)? onDone,
  }) async {
    if (!appConfig.speechInputEnabled) {
      const message = '语音输入未开启，请到「设置 → AI 设置」里开启并填写讯飞密钥。';
      _lastError = message;
      onError?.call(message);
      return false;
    }

    _lastRecognizedText = '';
    _lastError = null;

    // 上一轮实例持有的 AudioRecorder 需要显式释放，否则每开一次语音就漏一个录音器。
    await _iflytekSpeech?.dispose();
    _iflytekSpeech = IflytekSpeechService(appConfig);

    final started = await _iflytekSpeech!.startListening(
      onResult: (text) {
        _lastRecognizedText = text;
        onResult?.call(text);
      },
      onError: (message) {
        _lastError = message;
        _isListening = false;
        debugPrint('SpeechService: 讯飞识别失败 $message');
        onError?.call(message);
      },
      onSoundLevel: onSoundLevel,
      // 讯飞的 VAD 判停（`vad_eos`）会自己结束这一段，必须转告调用方，
      // 否则界面会停在「正在聆听」等用户手动点停止。
      onDone: (text) {
        _isListening = false;
        onDone?.call(text.trim().isEmpty ? _lastRecognizedText : text);
      },
    );

    _isListening = started;
    return started;
  }

  /// 停止识别并释放麦克风
  Future<void> stopListening() async {
    _isListening = false;
    try {
      await _iflytekSpeech?.stopListening().timeout(_stopTimeout);
    } on Object catch (e) {
      // 卡住也要回到「已停止」，否则按钮会一直显示录音态
      debugPrint('SpeechService: 停止识别失败 $e');
    }
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

  /// 释放资源
  Future<void> dispose() async {
    _isListening = false;
    _lastRecognizedText = '';
    await _iflytekSpeech?.dispose();
    _iflytekSpeech = null;
  }
}
