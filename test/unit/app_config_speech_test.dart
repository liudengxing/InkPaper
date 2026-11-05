import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/models/app_config_model.dart';

/// 语音输入是可选能力：只有「设置里开启 + 讯飞三件套填全」才允许出现麦克风入口。
/// 这条判断同时决定首页输入条与编辑器右上角按钮的显隐，回归风险高，单独锁住。
void main() {
  group('AppConfig.speechInputEnabled', () {
    test('默认配置下语音关闭，首页不出现麦克风', () {
      final config = AppConfig();

      expect(config.iflytekSpeechEnabled, isFalse);
      expect(config.speechInputEnabled, isFalse);
    });

    test('只打开开关、没填密钥时仍不可用', () {
      final config = AppConfig(iflytekSpeechEnabled: true);

      expect(config.speechInputEnabled, isFalse);
    });

    test('开关打开且三件套齐全才可用', () {
      final config = AppConfig(
        iflytekSpeechEnabled: true,
        iflytekAppId: 'appid',
        iflytekApiKey: 'apikey',
        iflytekApiSecret: 'apisecret',
      );

      expect(config.speechInputEnabled, isTrue);
    });

    test('空白字符按未填写处理', () {
      final config = AppConfig(
        iflytekSpeechEnabled: true,
        iflytekAppId: 'appid',
        iflytekApiKey: '   ',
        iflytekApiSecret: 'apisecret',
      );

      expect(config.speechInputEnabled, isFalse);
    });

    test('copyWith 关掉开关后立刻不可用', () {
      final enabled = AppConfig(
        iflytekSpeechEnabled: true,
        iflytekAppId: 'appid',
        iflytekApiKey: 'apikey',
        iflytekApiSecret: 'apisecret',
      );

      expect(
        enabled.copyWith(iflytekSpeechEnabled: false).speechInputEnabled,
        isFalse,
      );
    });

    test('旧配置里残留的 system 模式仍可读出，但不影响可用性判断', () {
      final config = AppConfig.fromJson({
        'speechRecognitionMode': AppConfig.SPEECH_MODE_IFLYTEK,
        'iflytekSpeechEnabled': true,
        'iflytekAppId': 'appid',
        'iflytekApiKey': 'apikey',
        'iflytekApiSecret': 'apisecret',
      });

      expect(config.speechInputEnabled, isTrue);

      // 老版本写入的 'system' 只作为字符串保留，不再参与可用性判断
      final legacy = AppConfig.fromJson({'speechRecognitionMode': 'system'});
      expect(legacy.speechRecognitionMode, 'system');
      expect(legacy.speechInputEnabled, isFalse);
    });
  });
}
