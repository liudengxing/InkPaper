// ============================================================
// DeepSeek 接入配置 · 地址口径回归
//
// 官方文档（api-docs.deepseek.com/zh-cn/）给的 base_url 是
// `https://api.deepseek.com`，请求路径 `/chat/completions`，不带 /v1。
// 这里锁两件事：常量本身的口径，以及存量配置里带 /v1 的老地址会不会
// 被迁移 / 被误判成「自定义服务」。
// ============================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/models/app_config_model.dart';

void main() {
  group('DeepSeek 地址口径', () {
    test('DS-01 默认地址与官方文档一致，不带版本段', () {
      expect(AppConfig.DEEPSEEK_API_URL, 'https://api.deepseek.com');
      expect(AppConfig.DEEPSEEK_API_URL.endsWith('/v1'), isFalse);
    });

    test('DS-02 请求路径拼出来就是文档里的 /chat/completions', () {
      // service 内部是字符串直接拼 `$apiUrl/chat/completions`
      const url = '${AppConfig.DEEPSEEK_API_URL}/chat/completions';
      expect(url, 'https://api.deepseek.com/chat/completions');
    });

    test('DS-03 isDeepSeekApiUrl 认官方地址与历史地址，忽略结尾斜杠', () {
      expect(AppConfig.isDeepSeekApiUrl('https://api.deepseek.com'), isTrue);
      expect(AppConfig.isDeepSeekApiUrl('https://api.deepseek.com/'), isTrue);
      expect(AppConfig.isDeepSeekApiUrl('https://api.deepseek.com/v1'), isTrue);
      expect(
        AppConfig.isDeepSeekApiUrl('https://api.deepseek.com/v1/'),
        isTrue,
      );
      expect(AppConfig.isDeepSeekApiUrl('https://example.com/v1'), isFalse);
      expect(AppConfig.isDeepSeekApiUrl(null), isFalse);
    });
  });

  group('存量配置迁移', () {
    test('DS-04 旧地址 + DeepSeek 预设 → 迁移成官方地址', () {
      final config = AppConfig.fromJson({
        'aiApiUrl': 'https://api.deepseek.com/v1',
        'aiApiPreset': AppConfig.AI_PRESET_DEEPSEEK,
        'aiModel': AppConfig.AI_MODEL_DEEPSEEK,
      });

      expect(config.aiApiUrl, AppConfig.DEEPSEEK_API_URL);
      expect(config.aiApiPreset, AppConfig.AI_PRESET_DEEPSEEK);
    });

    test('DS-05 老配置没有预设字段：带 /v1 仍推断为 DeepSeek，不被踢到自定义', () {
      final config = AppConfig.fromJson({
        'aiApiUrl': 'https://api.deepseek.com/v1',
        'aiModel': 'deepseek-chat',
      });

      expect(config.aiApiPreset, AppConfig.AI_PRESET_DEEPSEEK);
      expect(config.aiApiUrl, AppConfig.DEEPSEEK_API_URL);
      // 顺带确认旧模型名也归一化了
      expect(config.aiModel, AppConfig.AI_MODEL_DEEPSEEK);
    });

    test('DS-06 自定义预设的地址原样保留（哪怕长得像官方地址）', () {
      final config = AppConfig.fromJson({
        'aiApiUrl': 'https://api.deepseek.com/v1',
        'aiApiPreset': AppConfig.AI_PRESET_CUSTOM,
        'aiModel': 'gpt-4o-mini',
      });

      expect(config.aiApiUrl, 'https://api.deepseek.com/v1');
      expect(config.aiApiPreset, AppConfig.AI_PRESET_CUSTOM);
    });

    test('DS-07 已经是新地址时幂等', () {
      final config = AppConfig.fromJson({
        'aiApiUrl': AppConfig.DEEPSEEK_API_URL,
        'aiApiPreset': AppConfig.AI_PRESET_DEEPSEEK,
        'aiModel': AppConfig.AI_MODEL_DEEPSEEK,
      });

      expect(config.aiApiUrl, AppConfig.DEEPSEEK_API_URL);
    });

    test('DS-08 序列化后再反序列化不丢口径', () {
      final config = AppConfig.fromJson({
        'aiApiUrl': AppConfig.DEEPSEEK_API_URL,
        'aiApiPreset': AppConfig.AI_PRESET_DEEPSEEK,
        'aiModel': AppConfig.AI_MODEL_DEEPSEEK_REASONER,
      });
      final roundTrip = AppConfig.fromJson(config.toJson());

      expect(roundTrip.aiApiUrl, AppConfig.DEEPSEEK_API_URL);
      expect(roundTrip.aiApiPreset, AppConfig.AI_PRESET_DEEPSEEK);
      expect(roundTrip.aiModel, AppConfig.AI_MODEL_DEEPSEEK_REASONER);
    });
  });
}
